// SPDX-License-Identifier: MIT
// it is typically tied to a proxy hook that is managing liquidity through a pool manager
// outlines market vault functionality for the proxy hook
// this is used to manage the liquidity of the vault and the underlying assets
// it is also used to pay for pending settlements owed to the LCCs
// it is also used to take and settle underlying assets to and from the LCCs

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
import {console} from "forge-std/console.sol";

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
    bytes32[] public knownMarkets; // List of known markets
    mapping(bytes32 => bool) public isMarketKnown; // Quick lookup for market existence
    mapping(bytes32 => uint256) public marketLiquidityReserves; // Market-specific underlying liquidity

    // Events for market tracking
    event MarketRegistered(bytes32 indexed marketId);
    event MarketLiquidityAdded(bytes32 indexed marketId, uint256 amount);
    event MarketLiquidityUsed(bytes32 indexed marketId, uint256 amount);
    event LiquidityAddedToVault(address indexed sender, address indexed from, address indexed currency, uint256 amount);
    event LiquidityTakenFromVault(
        address indexed sender, address indexed recipient, address indexed currency, uint256 amount
    );

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
     * @dev Take asset from the vault to the recipient address. Will revert if there is not enough liquidity in the vault.
     * @param assetCurrency The underlying asset of the LCC
     * @param recipient The recipient of the underlying asset
     * @param amount The amount of the underlying asset to take from the vault
     */
    function _takeAssetFromVault(Currency assetCurrency, address recipient, uint256 amount) internal {
        // verify that the vault/proxy hook has enough liquidity to take for the underlying asset
        uint256 availableLiquidity = inMarketBalanceOf(assetCurrency);
        if (availableLiquidity < amount) {
            revert InsufficientLiquidityToTake();
        }
        // Burn some claim tokens from the pool manager in order to release the underlying liquidity for use
        assetCurrency.settle(
            vaultPoolManager,
            address(this),
            amount,
            true // `burn` = `true` i.e. we're  burning ERC-6909 Claim Tokens
        );
        // take from the vault to the recipient address
        assetCurrency.take(
            vaultPoolManager,
            recipient,
            amount,
            false // mint` = `true` i.e. we're  claiming erc20
        );
        emit LiquidityTakenFromVault(msg.sender, recipient, Currency.unwrap(assetCurrency), amount);
    }

    /**
     * @dev Take as much asset as possible from the vault to the recipient address
     * @param assetCurrency The underlying asset of the LCC
     * @param recipient The recipient of the underlying asset
     * @param amount The amount of the underlying asset to take from the vault
     *
     */
    function _tryTakeAssetFromVault(Currency assetCurrency, address recipient, uint256 amount)
        internal
        returns (uint256)
    {
        // verify that the vault/proxy hook has enough liquidity to take for the underlying asset
        uint256 availableLiquidity = inMarketBalanceOf(assetCurrency);
        uint256 amountToTake = Math.min(availableLiquidity, amount);
        // Take all the available liquidity from the vault for the underlying asset
        _takeAssetFromVault(assetCurrency, recipient, amountToTake);
        // return the amount of the underlying asset that was taken from the vault
        return amountToTake;
    }

    /**
     * @dev Take as much underlyingasset as possible from the vault to the LCC
     * @param lccToken The LCC token
     * @param amount The amount of the underlying asset to take from the vault
     * @return The amount of the underlying asset that was taken from the vault
     */
    function _tryTakeFromVaultToLCC(bytes32 marketId, ILCC lccToken, uint256 amount) internal returns (uint256) {
        Currency uaCurrency = Currency.wrap(lccToken.underlyingAsset());
        // Take the asset from the vault to the LCC
        uint256 amountTaken = _tryTakeAssetFromVault(uaCurrency, address(lccToken), amount);
        // Confirm the take of the underlying liquidity to the LCC to let the LCC know about the new balance
        if (amountTaken > 0) {
            lccToken.confirmTake(marketId, amountTaken, false);
        }
        return amountTaken;
    }

    /**
     * @dev Take asset from the vault to the LCC. Will revert if there is not enough liquidity in the vault.
     * @param lccToken The LCC token
     * @param amount The amount of the underlying asset to take from the vault
     */
    function _takeFromVaultAndSettle(bytes32 marketId, ILCC lccToken, uint256 amount, bool shouldProcessQueue)
        internal
    {
        if (amount == 0) revert InvalidAmount();
        Currency uaCurrency = Currency.wrap(lccToken.underlyingAsset());
        // Take the asset from the vault to the LCC
        _takeAssetFromVault(uaCurrency, address(lccToken), amount);
        // Confirm the take of the underlying liquidity to the LCC to let the LCC know about the new balance
        lccToken.confirmTake(marketId, amount, shouldProcessQueue);
    }

    /**
     * @dev Settle asset to the vault. Will revert if there is not enough liquidity in the sender settling to the vault.
     * @param assetCurrency The underlying asset of the LCC
     * @param sender The owner of the underlying asset sending to the vault
     * @param amount The amount of the underlying asset to settle to the vault
     */
    function _settleAssetToVault(Currency assetCurrency, address sender, uint256 amount) internal {
        // validate that the owner has enough balance of underlying token to take from
        uint256 ownerBalance = assetCurrency.balanceOf(sender);
        if (ownerBalance < amount) {
            revert InsufficientLiquidityToSettle();
        }

        // settle the asset to the vault
        assetCurrency.settle(
            vaultPoolManager,
            sender,
            amount,
            false // `burn` = `false` i.e. we're actually transferring tokens, not burning ERC-6909 Claim Tokens
        );

        // Mint claim tokens for the vault for the amount we just deposited into it
        // burning these tokens will enable us to 'take liquidity from the vault
        assetCurrency.take(
            vaultPoolManager,
            address(this),
            amount,
            true // `mint` = `true` i.e. we're minting claim tokens for the vault, equivalent to money we just deposited to the PM
        );

        emit LiquidityAddedToVault(msg.sender, sender, Currency.unwrap(assetCurrency), amount);
    }

    /**
     * @dev Settle asset from the LCC to the vault
     * @param lccToken The LCC token
     * @param amount The amount of the underlying asset to settle from the LCC to the vault
     */
    function _settleFromLCCToVault(ILCC lccToken, uint256 amount) internal {
        // Prepare the settle of the LCC to the vault,
        // this authorizes us to transfer from
        lccToken.prepareSettle(amount);

        // Get the underlying asset of the LCC
        Currency uaCurrency = Currency.wrap(lccToken.underlyingAsset());

        address sender = address(lccToken);

        // Get the amount of the underlying asset that is being settled to the vault
        // Settle the asset to the vault
        _settleAssetToVault(uaCurrency, sender, amount);
    }

    /**
     * @dev Fill Pending settlements of users who tried to unwrap with insufficient liquidity
     * @dev Called by MarketVault when new underyling asset liquidity is deposited into the Market via LCCs - ie. via Core Swap, MM settle, and DirectLP
     * @param corePoolKey The core pool key
     */
    function _settleObligations(PoolKey memory corePoolKey) internal {
        bytes32 marketId = PoolId.unwrap(corePoolKey.toId());
        // Get both LCC tokens for this market
        ILCC lccToken0 = ILCC(Currency.unwrap(corePoolKey.currency0));
        ILCC lccToken1 = ILCC(Currency.unwrap(corePoolKey.currency1));
        // Try to fill pending settlements for both tokens
        _settleObligationsForLCC(lccToken0, marketId);
        _settleObligationsForLCC(lccToken1, marketId);
    }

    /**
     * @dev Try to settle pending settlement obligations via LCCs if any deficit is available
     * @param lccToken The LCC token
     * @param marketId The market ID
     */
    function _settleObligationsForLCC(ILCC lccToken, bytes32 marketId) internal {
        // Check how much pending settlements this LCC has for this market
        uint256 totalPendingSettlement = IMarketLiquidity(address(lccToken)).getMarketTotalSettlementDeficit(marketId);
        if (totalPendingSettlement == 0) return; // No pending settlements to fill

        // Check how much liquidity ProxyHook has available
        Currency uaCurrency = Currency.wrap(lccToken.underlyingAsset());
        uint256 availableLiquidity = inMarketBalanceOf(uaCurrency);

        // Calculate how much we can settle
        uint256 amountToSettle = Math.min(totalPendingSettlement, availableLiquidity);
        if (amountToSettle == 0) return; // No liquidity available

        // Move liquidity from PoolManager to LCC (this triggers settlement process)
        // Pass shouldProcessQueue = true to process the settlement queue after taking to LCC.
        _takeFromVaultAndSettle(marketId, lccToken, amountToSettle, true);
    }

    /**
     * @dev Unlock callback function,  can only be called by the pool manager, it is called by the pool manager when we want to add liquidity to it
     * @param data The data that was passed to the call to unlock
     * @return The data that was passed to the call to unlock
     */
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(vaultPoolManager)) {
            revert InvalidSender();
        }
        // decode the callback data to determine the important parameters
        CallbackData memory callbackData = abi.decode(data, (CallbackData));
        // get the amount0 and amount1 from the balance delta
        (int128 amount0, int128 amount1) = (callbackData.balanceDelta.amount0(), callbackData.balanceDelta.amount1());

        // if the delta of amount0 is negative, then we need to take equivalent tokens from the vault
        if (amount0 < 0) {
            // take asset from vault
            // ? This function will fail if the amounts provided are greater than the available liquidity in the vault. This is purposeful. Callers must ensure they have sufficient liquidity in the vault.
            _takeAssetFromVault(callbackData.currency0, callbackData.sender, uint256(int256(-amount0)));
        }
        // if the delta of amount1 is negative, then we need to take equivalent tokens from the vault
        if (amount1 < 0) {
            // take asset from vault
            _takeAssetFromVault(callbackData.currency1, callbackData.sender, uint256(int256(-amount1)));
        }
        // if the delta of amount0 is positive, then we need to settle equivalent tokens to the vault
        if (amount0 > 0) {
            // settle asset to vault
            _settleAssetToVault(callbackData.currency0, address(this), uint256(int256(amount0)));
        }
        // if the delta of amount1 is positive, then we need to settle equivalent tokens to the vault
        if (amount1 > 0) {
            // settle asset to vault
            _settleAssetToVault(callbackData.currency1, address(this), uint256(int256(amount1)));
        }

        return "";
    }

    /**
     * @dev Manually add liquidity to the vault by first unlocking the pool manager then settling the removed funds
     * @param currency0 The currency 0
     * @param currency1 The currency 1
     * @param balanceDelta The balance delta of the currency 0 and currency 1
     */
    function _modifyVaultLiquidity(address currency0, address currency1, BalanceDelta balanceDelta) internal {
        vaultPoolManager.unlock(
            abi.encode(CallbackData(msg.sender, Currency.wrap(currency0), Currency.wrap(currency1), balanceDelta))
        );
    }
}
