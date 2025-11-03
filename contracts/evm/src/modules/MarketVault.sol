// SPDX-License-Identifier: MIT
/**
 * @title MarketVault
 * @notice Abstract contract providing vault functionality for managing liquidity in Uniswap V4 pools.
 *         The MarketVault is typically tied to a ProxyHook that manages liquidity through a PoolManager.
 *
 *         Core Responsibilities:
 *         - Managing underlying asset liquidity stored in the PoolManager via ERC-6909 claim tokens
 *         - Settling underlying assets to/from LCC (Liquidity Commitment Certificate) contracts
 *         - Fulfilling pending settlement obligations for users who attempted to unwrap LCC tokens
 *         - Handling balance deltas during PoolManager unlock operations
 *
 *         Key Concepts:
 *         - "Settle": Transfer ERC20 tokens to PoolManager and mint ERC-6909 claim tokens (deposit)
 *         - "Take": Burn ERC-6909 claim tokens and transfer ERC20 tokens from PoolManager (withdraw)
 *         - "Obligations": Pending settlement deficits that occur when users try to unwrap LCC tokens
 *                          but insufficient liquidity is available
 */
pragma solidity ^0.8.20;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {ILCC} from "../interfaces/ILCC.sol";
import {IMarketLiquidity} from "../interfaces/IMarketLiquidity.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IMarketVault} from "../interfaces/IMarketVault.sol";
import {IMarketFactory} from "../interfaces/IMarketFactory.sol";
import {LiquidityUtils} from "../libraries/LiquidityUtils.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {ILiquidityHub} from "../interfaces/ILiquidityHub.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Errors} from "../libraries/Errors.sol";

abstract contract MarketVault is IMarketVault {
    using CurrencySettler for Currency;
    using SafeERC20 for ILCC;

    event SwapDeficit(PoolId indexed poolId, address indexed lccToken, address deficitRecipient, uint256 deficitAmount);

    IPoolManager public immutable vaultPoolManager;
    IMarketFactory public immutable marketFactory;
    ILiquidityHub public immutable liquidityHub;
    address public immutable mmPositionManager;

    constructor(address _poolManager, address _marketFactory) {
        vaultPoolManager = IPoolManager(_poolManager);
        marketFactory = IMarketFactory(_marketFactory);
        liquidityHub = marketFactory.liquidityHub();
        mmPositionManager = marketFactory.mmPositionManager();
    }

    // Market tracking state variables
    bytes32[] public knownMarkets; // List of known markets that have been registered
    mapping(bytes32 => bool) public isMarketKnown; // Quick lookup to check if a market has been registered
    mapping(bytes32 => uint256) public marketLiquidityReserves; // Market-specific underlying liquidity reserves

    // Events for market tracking
    event MarketRegistered(bytes32 indexed marketId);
    event MarketLiquidityAdded(bytes32 indexed marketId, uint256 amount);
    event MarketLiquidityUsed(bytes32 indexed marketId, uint256 amount);
    event LiquidityAddedToVault(address indexed sender, address indexed from, address indexed currency, uint256 amount);
    event LiquidityTakenFromVault(
        address indexed sender, address indexed recipient, address indexed currency, uint256 amount
    );

    /**
     * @dev Callback data structure for PoolManager unlock operations
     * @notice Contains the necessary information to process balance deltas during unlock callbacks
     * @param sender The address initiating the liquidity modification
     * @param currency0 The first currency in the pair
     * @param currency1 The second currency in the pair
     * @param balanceDelta The balance delta representing the change in liquidity for both currencies
     */
    struct CallbackData {
        address sender;
        Currency currency0;
        Currency currency1;
        BalanceDelta balanceDelta;
    }

    modifier onlyProtocolBounds() {
        // authorises calls from protocol bounds (ie. MarketFactory, LiquidityHub, MMPositionManager, etc.)
        // if (!marketFactory.bounds(msg.sender)) {
        //     revert InvalidSender();
        // }
        // Being explicit witn these bounds to prevent leaks.
        if (msg.sender != (address(marketFactory)) && msg.sender != (address(mmPositionManager))) {
            revert Errors.InvalidSender();
        }
        _;
    }

    function _underlying() internal view virtual returns (Currency currency0, Currency currency1);

    function _lccs() internal view virtual returns (ILCC lccToken0, ILCC lccToken1);

    function _marketId() internal view virtual returns (bytes32);

    /**
     * @dev Get the balance of a token in the MarketVault
     * @param currency The currency in market vault
     * @return The balance of the currency in the market vault
     */
    function inMarketBalanceOf(Currency currency) public view returns (uint256) {
        return vaultPoolManager.balanceOf(address(this), currency.toId());
    }

    /**
     * @dev Take underlying asset from the vault to the recipient address
     * @notice This function will revert if there is insufficient liquidity in the vault.
     *         It burns ERC-6909 claim tokens to release underlying ERC20 tokens and transfers them to the recipient.
     * @param underlyingCurrency The currency (underlying asset) to take from the vault
     * @param recipient The address that will receive the underlying asset
     * @param amount The amount of underlying asset to take from the vault
     * @custom:reverts InsufficientLiquidityToTake If the vault doesn't have enough liquidity to fulfill the request
     */
    function _takeUnderlyingFromVaultToRecipient(Currency underlyingCurrency, address recipient, uint256 amount)
        internal
    {
        // Verify that the vault has sufficient liquidity to fulfill the request
        uint256 availableLiquidity = inMarketBalanceOf(underlyingCurrency);
        if (availableLiquidity < amount) {
            revert Errors.InsufficientLiquidityToTake();
        }

        // Burn ERC-6909 claim tokens to release the underlying ERC20 tokens from the PoolManager
        // This reduces the vault's claim on the PoolManager's balance
        underlyingCurrency.settle(
            vaultPoolManager,
            address(this),
            amount,
            true // burn = true: burn ERC-6909 Claim Tokens
        );

        // Transfer the released ERC20 tokens from PoolManager to the recipient
        // This claims the actual underlying tokens (not claim tokens)
        underlyingCurrency.take(
            vaultPoolManager,
            recipient,
            amount,
            false // mint = false: claim ERC20 tokens (not mint claim tokens)
        );

        emit LiquidityTakenFromVault(msg.sender, recipient, Currency.unwrap(underlyingCurrency), amount);
    }

    /**
     * @dev Try to take as much underlying asset as possible from the vault to the recipient
     * @notice This is a non-reverting version that takes only what's available.
     *         If the requested amount exceeds available liquidity, it takes the maximum available.
     *         Use this when partial fulfillment is acceptable (e.g., best-effort operations).
     * @param underlyingCurrency The currency (underlying asset) to take from the vault
     * @param recipient The address that will receive the underlying asset
     * @param amount The maximum amount of underlying asset to attempt to take from the vault
     * @return The actual amount of underlying asset that was taken (may be less than requested)
     */
    function _tryTakeUnderlyingFromVaultToRecipient(Currency underlyingCurrency, address recipient, uint256 amount)
        internal
        returns (uint256)
    {
        // Check available liquidity and take the minimum of requested amount and available amount
        uint256 availableLiquidity = inMarketBalanceOf(underlyingCurrency);
        uint256 amountToTake = Math.min(availableLiquidity, amount);

        // Only proceed if there's something to take
        if (amountToTake > 0) {
            _takeUnderlyingFromVaultToRecipient(underlyingCurrency, recipient, amountToTake);
        }

        return amountToTake;
    }

    /**
     * @dev Try to take underlying asset from the vault to an LCC and confirm the take
     * @notice This is a non-reverting version that attempts to fulfill pending settlements.
     *         It takes available liquidity from the vault and transfers it to the LCC contract,
     *         then notifies the LCC about the new balance via confirmTake.
     *         Used when partial fulfillment is acceptable (e.g., fulfilling deficit settlements).
     * @param lccToken The LCC token contract that will receive the underlying asset
     * @param amount The maximum amount of underlying asset to attempt to take from the vault
     * @return The actual amount of underlying asset that was taken and confirmed to the LCC
     */
    function _tryTakeUnderlyingFromVaultToHub(ILCC lccToken, uint256 amount, bool shouldEmit)
        internal
        returns (uint256)
    {
        Currency uaCurrency = Currency.wrap(lccToken.underlying());

        // Attempt to take the underlying asset from vault to the Hub contract address
        uint256 amountTaken = _tryTakeUnderlyingFromVaultToRecipient(uaCurrency, address(liquidityHub), amount);

        // If we successfully took any amount, notify the LCC contract about the new balance
        // This allows the LCC to track market-specific liquidity and process settlement queues
        if (amountTaken > 0) {
            liquidityHub.confirmTake(address(lccToken), amountTaken, shouldEmit);
        }

        return amountTaken;
    }

    /**
     * @dev Take underlying asset from the vault to an LCC and confirm the take
     * @notice This function will revert if there is insufficient liquidity in the vault.
     *         It takes the full requested amount from the vault, transfers it to the LCC contract,
     *         and notifies the LiquidityHub about the new balance. The LiquidityHub will emit
     *         a LiquidityAvailable event if shouldEmit is true.
     * @param lccToken The LCC token contract that will receive the underlying asset
     * @param amount The exact amount of underlying asset to take from the vault (must be > 0)
     * @param shouldEmit Whether to emit LiquidityAvailable event after confirming the take
     * @custom:reverts InvalidAmount If amount is zero
     * @custom:reverts InsufficientLiquidityToTake If the vault doesn't have enough liquidity to fulfill the request
     */
    function _takeUnderlyingFromVaultToHub(ILCC lccToken, uint256 amount, bool shouldEmit) internal {
        if (amount == 0) {
            revert Errors.InvalidAmount(0, 0);
        }

        Currency uaCurrency = Currency.wrap(lccToken.underlying());

        // Take the underlying asset from vault to the Hub contract address
        // This will revert if insufficient liquidity is available
        _takeUnderlyingFromVaultToRecipient(uaCurrency, address(liquidityHub), amount);

        // Notify the LiquidityHub about the new balance and optionally emit event
        liquidityHub.confirmTake(address(lccToken), amount, shouldEmit);
    }

    /**
     * @dev Settle underlying asset to the vault from the Hub
     * @notice For ERC20: Hub approves MarketVault and we pull from Hub. For native: Hub transfers ETH to MarketVault and we settle from self.
     */
    function _settleUnderlyingToVaultFromHub(ILCC lccToken, uint256 amount) internal {
        liquidityHub.prepareSettle(address(lccToken), amount);

        Currency uaCurrency = Currency.wrap(lccToken.underlying());
        // CurrencySettler handles transfer of native ETH from address(this), assuming LiquidityHub conducts native transfer to this first.
        _settleUnderlyingToVaultFromSender(uaCurrency, address(liquidityHub), amount);
    }

    /**
     * @dev Settle underlying asset to the vault from a sender
     * @notice This function transfers ERC20 tokens from the sender to the PoolManager and mints
     *         ERC-6909 claim tokens to the vault. The claim tokens represent the vault's claim
     *         on the underlying tokens held by the PoolManager.
     * @param underlyingCurrency The currency (underlying asset) to settle to the vault
     * @param sender The address that owns the underlying asset and is settling it to the vault
     * @param amount The amount of underlying asset to settle to the vault
     * @custom:reverts InsufficientLiquidityToSettle If the sender doesn't have enough balance
     */
    function _settleUnderlyingToVaultFromSender(Currency underlyingCurrency, address sender, uint256 amount) internal {
        // Validate that the sender has sufficient balance to settle
        uint256 senderBalance = underlyingCurrency.balanceOf(sender);
        if (senderBalance < amount) {
            revert Errors.InsufficientLiquidityToSettle();
        }

        // Transfer ERC20 tokens from sender to the PoolManager
        // This moves the actual underlying tokens into the PoolManager's custody
        underlyingCurrency.settle(
            vaultPoolManager,
            sender,
            amount,
            false // burn = false: transfer ERC20 tokens (not burn ERC-6909 claim tokens)
        );

        // Mint ERC-6909 claim tokens to the vault representing its claim on the deposited tokens
        // These claim tokens can later be burned to "take" (retrieve) the underlying tokens
        underlyingCurrency.take(
            vaultPoolManager,
            address(this),
            amount,
            true // mint = true: mint ERC-6909 Claim Tokens to the vault
        );

        emit LiquidityAddedToVault(msg.sender, sender, Currency.unwrap(underlyingCurrency), amount);
    }

    /**
     * @dev Settle pending obligations for both tokens in a market
     * @notice This function attempts to fulfill pending settlement obligations for users who
     *         attempted to unwrap LCC tokens but encountered insufficient liquidity. It processes
     *         both LCC tokens (currency0 and currency1) in the market, transferring available
     *         liquidity from the vault to the LCCs to settle outstanding deficits.
     *         Called when new liquidity is deposited into the market (e.g., via Core Swap,
     *         MM settle, or DirectLP operations).
     * @param corePoolKey The core pool key identifying the market
     */
    function _settleObligations(PoolKey memory corePoolKey) internal {
        bytes32 marketId = PoolId.unwrap(corePoolKey.toId());
        ILCC lccToken0 = ILCC(Currency.unwrap(corePoolKey.currency0));
        ILCC lccToken1 = ILCC(Currency.unwrap(corePoolKey.currency1));

        // Attempt to settle obligations for both tokens in the market
        _settleObligationsForLCC(lccToken0);
        _settleObligationsForLCC(lccToken1);
    }

    /**
     * @dev Try to settle pending settlement obligations for a specific LCC
     * @notice This function checks if there are pending settlement obligations (queued amounts) for
     *         users who tried to unwrap LCC tokens but encountered insufficient liquidity. If
     *         there are pending obligations and the vault has available liquidity, it transfers
     *         the liquidity from the vault to the Hub and triggers settlement processing.
     *         This is a best-effort operation that settles as much as possible with available liquidity.
     * @param lccToken The LCC token contract to settle obligations for
     */
    function _settleObligationsForLCC(ILCC lccToken) internal {
        // Check how much total pending settlement is queued for this LCC
        uint256 totalPendingSettlement = liquidityHub.totalQueued(address(lccToken));
        if (totalPendingSettlement == 0) return; // No pending settlements to fulfill

        // Check how much underlying liquidity is available in the vault for this LCC's underlying asset
        Currency uaCurrency = Currency.wrap(lccToken.underlying());
        uint256 availableLiquidity = inMarketBalanceOf(uaCurrency);

        // Calculate how much we can actually settle (limited by available liquidity)
        uint256 amountToSettle = Math.min(totalPendingSettlement, availableLiquidity);
        if (amountToSettle == 0) return; // No liquidity available to fulfill obligations

        // Transfer liquidity from vault to Hub and emit event
        // This will trigger LiquidityAvailable event if shouldEmit is true
        _takeUnderlyingFromVaultToHub(lccToken, amountToSettle, true);
    }

    /**
     * @dev Cancel an LCC token amount, handling deficit scenarios when insufficient liquidity is available
     * @notice This function cancels LCC tokens for a given amount, but may only partially fulfill
     *         the cancellation if the vault has insufficient underlying liquidity. When the requested
     *         amount exceeds available liquidity, it cancels what's available and handles the deficit
     *         by transferring the deficit amount to the deficit recipient (if provided).
     *
     *         The deficit scenario occurs when a swap operation requires more liquidity than is
     *         currently available in the vault. The ProxyHook will have already taken the full
     *         LCC amount from the PoolManager, so the deficit represents the shortfall that needs
     *         to be handled separately.
     * @param key The pool key identifying the market
     * @param lccToken The LCC token contract to cancel
     * @param amount The amount of LCC tokens requested to be cancelled
     * @param deficitRecipient The address to receive any deficit amount (if insufficient liquidity)
     * @return amountToCancel The actual amount of LCC tokens that were cancelled (may be less than requested)
     * @custom:note If deficitRecipient is address(0) but deficitAmount > 0, the excess will accumulate.
     *              This indicates that prior swap amount restrictions were broken, which should never happen.
     */
    function _cancelLCCWithDeficit(PoolId poolId, ILCC lccToken, uint256 amount, address deficitRecipient)
        internal
        returns (uint256 amountToCancel)
    {
        uint256 deficitAmount = 0;
        uint256 available = inMarketBalanceOf(Currency.wrap(lccToken.underlying()));
        if (amount > available) {
            amountToCancel = available; // amount to cancel becomes what ever is in custody.
            deficitAmount = amount - available; // deficit amount becomes the difference between the amount to cancel and the amount in custody.
        } else {
            amountToCancel = amount;
        }

        liquidityHub.cancel(address(lccToken), amountToCancel); // we only cancel what native asset we distribute via the swap mechanism.

        if (deficitAmount > 0 && deficitRecipient != address(0)) {
            // ? The MarketVault will have already taken the full LCC amount from the PoolManager.
            lccToken.safeTransfer(deficitRecipient, deficitAmount);
            emit SwapDeficit(poolId, address(lccToken), deficitRecipient, deficitAmount);
        }
        // Note: If deficit recipient is not specified, but a deficit > 0, then excess will accumulate.
        // However, this means prior swap amount restriction in Proxy Hook must therefore be broken. This should never happen.
    }

    /**
     * @dev Unlock callback function called by the PoolManager during unlock operations
     * @notice This callback is invoked by the PoolManager when the vault needs to handle balance deltas.
     *         It processes positive deltas (incoming tokens) by settling them to the vault, and
     *         negative deltas (outgoing tokens) by taking them from the vault. This is used to
     *         synchronize the vault's liquidity with the PoolManager's balance changes.
     * @param data Encoded CallbackData containing sender, currencies, and balance delta
     * @return Empty bytes array (required by callback interface)
     * @custom:reverts InvalidSender If the caller is not the vaultPoolManager
     * @custom:reverts InsufficientLiquidityToTake If negative deltas exceed available vault liquidity
     * @custom:reverts InsufficientLiquidityToSettle If positive deltas require more than available balance
     */
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(vaultPoolManager)) {
            revert Errors.InvalidSender();
        }

        // Decode the callback data to extract sender, currencies, and balance delta
        CallbackData memory callbackData = abi.decode(data, (CallbackData));

        // Extract the balance deltas for both currencies
        // Negative values indicate tokens need to be taken from the vault
        // Positive values indicate tokens need to be settled to the vault
        (int128 amount0, int128 amount1) = (callbackData.balanceDelta.amount0(), callbackData.balanceDelta.amount1());

        // Handle negative delta for currency0: take underlying tokens from vault to sender
        if (amount0 < 0) {
            _takeUnderlyingFromVaultToRecipient(
                callbackData.currency0, callbackData.sender, LiquidityUtils.safeInt128ToUint256(amount0)
            );
        }

        // Handle negative delta for currency1: take underlying tokens from vault to sender
        if (amount1 < 0) {
            _takeUnderlyingFromVaultToRecipient(
                callbackData.currency1, callbackData.sender, LiquidityUtils.safeInt128ToUint256(amount1)
            );
        }

        // Handle positive delta for currency0: settle underlying tokens from sender to vault
        if (amount0 > 0) {
            _settleUnderlyingToVaultFromSender(
                callbackData.currency0, address(this), LiquidityUtils.safeInt128ToUint256(amount0)
            );
        }

        // Handle positive delta for currency1: settle underlying tokens from sender to vault
        if (amount1 > 0) {
            _settleUnderlyingToVaultFromSender(
                callbackData.currency1, address(this), LiquidityUtils.safeInt128ToUint256(amount1)
            );
        }

        return "";
    }

    /**
     * @dev Manually unlock the PoolManager and modify vault liquidity
     * @notice This function initiates a manual liquidity modification operation by unlocking the
     *         PoolManager and providing callback data. The actual liquidity changes are handled
     *         in the unlockCallback function. This is used for operations that need to modify
     *         the vault's liquidity state (e.g., adding liquidity via direct LP operations).
     * @param currency0 The first currency address
     * @param currency1 The second currency address
     * @param balanceDelta The balance delta representing the desired liquidity changes
     */
    function _modifyVaultLiquidity(Currency currency0, Currency currency1, BalanceDelta balanceDelta) internal {
        vaultPoolManager.unlock(abi.encode(CallbackData(msg.sender, (currency0), (currency1), balanceDelta)));
    }

    /**
     * @dev This function is called by the MMPositionManager to add liquidity directly to the vault
     * @param balanceDelta The balance delta of the currency0 and currency1
     * @notice Derive the ProxyHook address from the Pool Id, assumes the (LCC underlying) currencies for the Proxy Pool.
     */
    function modifyLiquidities(BalanceDelta balanceDelta) external onlyProtocolBounds {
        (Currency currency0, Currency currency1) = _underlying();
        (ILCC lccToken0, ILCC lccToken1) = _lccs();
        _modifyVaultLiquidity(currency0, currency1, balanceDelta);
        // if there was an addition, then settle the obligations to the lcc tokens
        if (balanceDelta.amount0() > 0) {
            _settleObligationsForLCC(lccToken0);
        }
        if (balanceDelta.amount1() > 0) {
            _settleObligationsForLCC(lccToken1);
        }
    }

    function tryModifyLiquidities(BalanceDelta balanceDelta) external onlyProtocolBounds returns (BalanceDelta) {
        (Currency currency0, Currency currency1) = _underlying();
        (ILCC lccToken0, ILCC lccToken1) = _lccs();
        bytes32 marketId = _marketId();

        int128 delta0 = balanceDelta.amount0();
        int128 delta1 = balanceDelta.amount1();

        // Track actual amounts withdrawn/added
        int128 actualDelta0 = delta0;
        int128 actualDelta1 = delta1;

        // Handle withdrawals (negative deltas) - only withdraw what's available
        if (delta0 < 0) {
            uint256 requested0 = LiquidityUtils.safeInt128ToUint256(delta0);
            uint256 available0 = inMarketBalanceOf(currency0);
            uint256 amount0 = Math.min(requested0, available0);
            // If we can't fulfill the full withdrawal, adjust the delta to what we can actually withdraw
            if (amount0 < requested0) {
                actualDelta0 = -SafeCast.toInt128(amount0);
            }
        }

        if (delta1 < 0) {
            uint256 requested1 = LiquidityUtils.safeInt128ToUint256(delta1);
            uint256 available1 = inMarketBalanceOf(currency1);
            uint256 amount1 = Math.min(requested1, available1);
            // If we can't fulfill the full withdrawal, adjust the delta to what we can actually withdraw
            if (amount1 < requested1) {
                actualDelta1 = -SafeCast.toInt128(amount1);
            }
        }

        // Only proceed with modifyVaultLiquidity if:
        // 1. We have deposits (positive deltas) - proceed normally
        // 2. We have withdrawals but sufficient balance available - proceed with adjusted deltas
        // 3. For withdrawals, if we don't have enough, we still proceed with what we can withdraw
        BalanceDelta usedDelta = toBalanceDelta(actualDelta0, actualDelta1);
        _modifyVaultLiquidity(currency0, currency1, usedDelta);

        // If there was an addition (deposit), then settle the obligations to the lcc tokens
        if (delta0 > 0) {
            _settleObligationsForLCC(lccToken0);
        }
        if (delta1 > 0) {
            _settleObligationsForLCC(lccToken1);
        }

        return usedDelta;
    }

    // Best practice: be explicit about intent
    // Only executes on plain transaction (no selector) (ie. poolManager or WETH9 transfer of assets) to the MarketVault.
    // Mostly used to prevent accidental transfers to the vault.
    receive() external payable {
        // Handle plain ETH transfers
    }
}
