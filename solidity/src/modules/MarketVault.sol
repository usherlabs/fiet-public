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
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IMarketVault} from "../interfaces/IMarketVault.sol";

abstract contract MarketVault is IMarketVault {
    using CurrencySettler for Currency;

    error InsufficientLiquidityToTake();
    error InsufficientLiquidityToSettle();
    error InvalidAmount();
    error InvalidSender();

    IPoolManager public immutable vaultPoolManager;

    constructor(IPoolManager _poolManager) {
        vaultPoolManager = _poolManager;
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
            revert InsufficientLiquidityToTake();
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
     * @param marketId The market ID for tracking purposes
     * @param lccToken The LCC token contract that will receive the underlying asset
     * @param amount The maximum amount of underlying asset to attempt to take from the vault
     * @return The actual amount of underlying asset that was taken and confirmed to the LCC
     */
    function _tryTakeUnderlyingFromVaultToLCC(bytes32 marketId, ILCC lccToken, uint256 amount)
        internal
        returns (uint256)
    {
        Currency uaCurrency = Currency.wrap(lccToken.underlyingAsset());

        // Attempt to take the underlying asset from vault to the LCC contract address
        uint256 amountTaken = _tryTakeUnderlyingFromVaultToRecipient(uaCurrency, address(lccToken), amount);

        // If we successfully took any amount, notify the LCC contract about the new balance
        // This allows the LCC to track market-specific liquidity and process settlement queues
        if (amountTaken > 0) {
            lccToken.confirmTake(marketId, amountTaken, false);
        }

        return amountTaken;
    }

    /**
     * @dev Take underlying asset from the vault to an LCC and confirm the take
     * @notice This function will revert if there is insufficient liquidity in the vault.
     *         It takes the full requested amount from the vault, transfers it to the LCC contract,
     *         and notifies the LCC about the new balance. The LCC may process its settlement queue
     *         if shouldProcessQueue is true.
     * @param marketId The market ID for tracking and settlement queue processing
     * @param lccToken The LCC token contract that will receive the underlying asset
     * @param amount The exact amount of underlying asset to take from the vault (must be > 0)
     * @param shouldProcessQueue Whether the LCC should process its settlement queue after confirming the take
     * @custom:reverts InvalidAmount If amount is zero
     * @custom:reverts InsufficientLiquidityToTake If the vault doesn't have enough liquidity to fulfill the request
     */
    function _takeUnderlyingFromVaultToLCC(bytes32 marketId, ILCC lccToken, uint256 amount, bool shouldProcessQueue)
        internal
    {
        if (amount == 0) {
            revert InvalidAmount();
        }

        Currency uaCurrency = Currency.wrap(lccToken.underlyingAsset());

        // Take the underlying asset from vault to the LCC contract address
        // This will revert if insufficient liquidity is available
        _takeUnderlyingFromVaultToRecipient(uaCurrency, address(lccToken), amount);

        // Notify the LCC contract about the new balance and optionally process settlement queue
        // When shouldProcessQueue is true, this triggers settlement of pending user unwrap requests
        lccToken.confirmTake(marketId, amount, shouldProcessQueue);
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
            revert InsufficientLiquidityToSettle();
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
     * @dev Settle underlying asset to the vault from an LCC
     * @notice This function prepares the LCC for settlement (authorizing the transfer) and then
     *         settles the underlying asset from the LCC contract to the vault. The LCC must have
     *         sufficient underlying asset balance to fulfill the settlement.
     * @param lccToken The LCC token contract that holds the underlying asset
     * @param amount The amount of underlying asset to settle from the LCC to the vault
     * @custom:reverts InsufficientLiquidityToSettle If the LCC doesn't have enough underlying asset balance
     */
    function _settleUnderlyingToVaultFromLCC(ILCC lccToken, uint256 amount) internal {
        // Prepare the LCC for settlement - this authorizes the MarketVault to transfer
        // the underlying asset from the LCC contract. This also reduces the LCC's uaSupply.
        lccToken.prepareSettle(amount);

        Currency uaCurrency = Currency.wrap(lccToken.underlyingAsset());
        address sender = address(lccToken);

        // Settle the underlying asset from the LCC contract to the vault
        // This transfers ERC20 tokens and mints claim tokens to the vault
        _settleUnderlyingToVaultFromSender(uaCurrency, sender, amount);
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
        _settleObligationsForLCC(lccToken0, marketId);
        _settleObligationsForLCC(lccToken1, marketId);
    }

    /**
     * @dev Try to settle pending settlement obligations for a specific LCC in a market
     * @notice This function checks if there are pending settlement obligations (deficits) for
     *         users who tried to unwrap LCC tokens but encountered insufficient liquidity. If
     *         there are pending obligations and the vault has available liquidity, it transfers
     *         the liquidity from the vault to the LCC and triggers settlement queue processing.
     *         This is a best-effort operation that settles as much as possible with available liquidity.
     * @param lccToken The LCC token contract to settle obligations for
     * @param marketId The market ID to check for pending settlements
     */
    function _settleObligationsForLCC(ILCC lccToken, bytes32 marketId) internal {
        // Check how much total pending settlement deficit exists for this LCC in this market
        uint256 totalPendingSettlement = IMarketLiquidity(address(lccToken)).getMarketTotalSettlementDeficit(marketId);
        if (totalPendingSettlement == 0) return; // No pending settlements to fulfill

        // Check how much underlying liquidity is available in the vault for this LCC's underlying asset
        Currency uaCurrency = Currency.wrap(lccToken.underlyingAsset());
        uint256 availableLiquidity = inMarketBalanceOf(uaCurrency);

        // Calculate how much we can actually settle (limited by available liquidity)
        uint256 amountToSettle = Math.min(totalPendingSettlement, availableLiquidity);
        if (amountToSettle == 0) return; // No liquidity available to fulfill obligations

        // Transfer liquidity from vault to LCC and process settlement queue
        // This will trigger settlement of pending user unwrap requests
        _takeUnderlyingFromVaultToLCC(marketId, lccToken, amountToSettle, true);
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
            revert InvalidSender();
        }

        // Decode the callback data to extract sender, currencies, and balance delta
        CallbackData memory callbackData = abi.decode(data, (CallbackData));

        // Extract the balance deltas for both currencies
        // Negative values indicate tokens need to be taken from the vault
        // Positive values indicate tokens need to be settled to the vault
        (int128 amount0, int128 amount1) = (callbackData.balanceDelta.amount0(), callbackData.balanceDelta.amount1());

        // Handle negative delta for currency0: take underlying tokens from vault to sender
        if (amount0 < 0) {
            _takeUnderlyingFromVaultToRecipient(callbackData.currency0, callbackData.sender, uint256(int256(-amount0)));
        }

        // Handle negative delta for currency1: take underlying tokens from vault to sender
        if (amount1 < 0) {
            _takeUnderlyingFromVaultToRecipient(callbackData.currency1, callbackData.sender, uint256(int256(-amount1)));
        }

        // Handle positive delta for currency0: settle underlying tokens from sender to vault
        if (amount0 > 0) {
            _settleUnderlyingToVaultFromSender(callbackData.currency0, address(this), uint256(int256(amount0)));
        }

        // Handle positive delta for currency1: settle underlying tokens from sender to vault
        if (amount1 > 0) {
            _settleUnderlyingToVaultFromSender(callbackData.currency1, address(this), uint256(int256(amount1)));
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
    function _modifyVaultLiquidity(address currency0, address currency1, BalanceDelta balanceDelta) internal {
        vaultPoolManager.unlock(
            abi.encode(CallbackData(msg.sender, Currency.wrap(currency0), Currency.wrap(currency1), balanceDelta))
        );
    }

    // Best practice: be explicit about intent
    // TODO: Do we wnat to do anything here?
    receive() external payable {
        // Handle plain ETH transfers
    }
}
