// SPDX-License-Identifier: MIT
// it is typically tied to a proxy hook that is managing liquidity through a pool manager
// outlines market vault functionality for the proxy hook
// this is used to manage the liquidity of the vault and the underlying assets
// it is also used to settle debts owed to the LCCs
// it is also used to take and settle underlying assets to and from the LCCs

pragma solidity ^0.8.20;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {LiquidityCommitmentCertificate} from "../LCC.sol";
import {LiquidityUtils} from "../libraries/LiquidityUtils.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {console} from "forge-std/console.sol";

abstract contract MarketVault {
    using CurrencySettler for Currency;

    error InsufficientLiquidity();
    error InsufficientBalance();
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
        Currency currency0;
        Currency currency1;
        uint256 amount1;
        uint256 amount0;
    }

    /**
     * @dev Take asset from the vault to the recipient address
     * @param uaCurrency The underlying asset of the LCC
     * @param recipient The recipient of the underlying asset
     * @param amount The amount of the underlying asset to take from the vault
     */
    function _takeAssetFromVault(Currency uaCurrency, address recipient, uint256 amount) internal {
        // verify that the vault/proxy hook has enough liquidity to take for the underlying asset
        uint256 availableLiquidity = vaultPoolManager.balanceOf(address(this), uaCurrency.toId());
        if (availableLiquidity < amount) {
            revert InsufficientLiquidity();
        }
        // Burn some claim tokens from the pool manager in order to release the underlying liquidity for use
        uaCurrency.settle(
            vaultPoolManager,
            address(this),
            amount,
            true // `burn` = `true` i.e. we're  burning ERC-6909 Claim Tokens
        );
        // take from the vault to the recipient address
        uaCurrency.take(
            vaultPoolManager,
            recipient,
            amount,
            false // mint` = `true` i.e. we're  claiming erc20
        );
        emit LiquidityTakenFromVault(msg.sender, recipient, Currency.unwrap(uaCurrency), amount);
    }

    /**
     * @dev Take asset from the vault to the recipient address
     * @param uaCurrency The underlying asset of the LCC
     * @param recipient The recipient of the underlying asset
     * @param amount The amount of the underlying asset to take from the vault
     *
     */
    function _tryTakeAssetFromVault(Currency uaCurrency, address recipient, uint256 amount)
        internal
        returns (uint256)
    {
        // verify that the vault/proxy hook has enough liquidity to take for the underlying asset
        uint256 availableLiquidity = vaultPoolManager.balanceOf(address(this), uaCurrency.toId());
        uint256 amountToTake = Math.min(availableLiquidity, amount);
        // Take all the available liquidity from the vault for the underlying asset
        _takeAssetFromVault(uaCurrency, recipient, amountToTake);
        // return the amount of the underlying asset that was taken from the vault
        return amountToTake;
    }

    /**
     * @dev Settle asset to the vault
     * @param uaCurrency The underlying asset of the LCC
     * @param owner The owner of the underlying asset
     * @param amount The amount of the underlying asset to settle to the vault
     */
    function _settleAssetToVault(Currency uaCurrency, address owner, uint256 amount) internal {
        // validate that the owner has enough balance of underlying token to take from
        // uint256 ownerBalance = uaCurrency.balanceOf(owner);
        // if (ownerBalance < amount) {
        //     revert InsufficientBalance();
        // }
        // settle the asset to the vault
        uaCurrency.settle(
            vaultPoolManager,
            owner,
            amount,
            false // `burn` = `false` i.e. we're actually transferring tokens, not burning ERC-6909 Claim Tokens
        );

        // Mint claim tokens for the vault for the amount we just deposited into it
        // burning these tokens will enable us to 'take liquidity from the vault
        uaCurrency.take(
            vaultPoolManager,
            address(this),
            amount,
            true // `mint` = `true` i.e. we're minting claim tokens for the vault, equivalent to money we just deposited to the PM
        );

        emit LiquidityAddedToVault(msg.sender, owner, Currency.unwrap(uaCurrency), amount);
    }

    /**
     * @dev Take asset from the vault to the LCC
     * @param lccToken The LCC token
     * @param amount The amount of the underlying asset to take from the vault
     * @return The deficit of the underlying asset that was taken from the vault i.e how much we were unable to take from the vault
     */
    function _tryTakeFromVaultToLCC(LiquidityCommitmentCertificate lccToken, uint256 amount)
        internal
        returns (uint256)
    {
        Currency uaCurrency = Currency.wrap(lccToken.underlyingAsset());
        // Take the asset from the vault to the LCC
        uint256 amountTaken = _tryTakeAssetFromVault(uaCurrency, address(lccToken), amount);
        // Confirm the take of the underlying liquidity to the LCC to let the LCC know about the new balance
        if (amountTaken > 0) {
            lccToken.confirmTake(amountTaken);
        }
        // Calculate the deficit of the underlying asset that was taken from the vault i.e how much we were unable to take from the vault
        uint256 deficit = amount - amountTaken;

        return deficit;
    }

    /**
     * @dev Take asset from the vault to the LCC
     * @param lccToken The LCC token
     * @param amount The amount of the underlying asset to take from the vault
     */
    function _takeFromVaultToLCC(LiquidityCommitmentCertificate lccToken, uint256 amount) internal {
        if (amount == 0) revert InvalidAmount();
        Currency uaCurrency = Currency.wrap(lccToken.underlyingAsset());
        // Take the asset from the vault to the LCC
        _takeAssetFromVault(uaCurrency, address(lccToken), amount);
        // Confirm the take of the underlying liquidity to the LCC to let the LCC know about the new balance
        lccToken.confirmTake(amount);
    }

    /**
     * @dev Settle asset from the LCC to the vault
     * @param lccToken The LCC token
     * @param amount The amount of the underlying asset to settle from the LCC to the vault
     */
    function _settleFromLCCToVault(LiquidityCommitmentCertificate lccToken, uint256 amount) internal {
        // Prepare the settle of the LCC to the vault,
        // this authorizes us to transfer from
        lccToken.prepareSettle(amount);

        // Get the underlying asset of the LCC
        Currency uaCurrency = Currency.wrap(lccToken.underlyingAsset());

        // Get the amount of the underlying asset that is being settled to the vault
        // Settle the asset to the vault
        _settleAssetToVault(uaCurrency, address(lccToken), amount);
    }

    /**
     * @dev Settle debts from the vault to the LCC
     * @param corePoolKey The core pool key
     */
    function _settleVaultDebtsToLCC(PoolKey memory corePoolKey) internal {
        bytes32 marketId = PoolId.unwrap(corePoolKey.toId());
        // Get both LCC tokens for this market
        LiquidityCommitmentCertificate lccToken0 =
            LiquidityCommitmentCertificate(payable(Currency.unwrap(corePoolKey.currency0)));
        LiquidityCommitmentCertificate lccToken1 =
            LiquidityCommitmentCertificate(payable(Currency.unwrap(corePoolKey.currency1)));

        // Try to settle debts for both tokens
        _trySettleDebtsForLCC(lccToken0, marketId);
        _trySettleDebtsForLCC(lccToken1, marketId);
    }

    /**
     * @dev Try to settle debts owed to the LCC if any
     * @param lccToken The LCC token
     * @param marketId The market ID
     */
    function _trySettleDebtsForLCC(LiquidityCommitmentCertificate lccToken, bytes32 marketId) internal {
        // Check how much debt this LCC has for this market
        uint256 totalDebt = lccToken.getMarketTotalDebt(marketId);
        if (totalDebt == 0) return; // No debt to settle

        // Check how much liquidity ProxyHook has available
        Currency uaCurrency = Currency.wrap(lccToken.underlyingAsset());
        uint256 availableLiquidity = vaultPoolManager.balanceOf(address(this), uaCurrency.toId());

        // Calculate how much we can settle
        uint256 amountToSettle = Math.min(totalDebt, availableLiquidity);
        if (amountToSettle == 0) return; // No liquidity available

        // Move liquidity from PoolManager to LCC (this triggers debt processing)
        _takeFromVaultToLCC(lccToken, amountToSettle);
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
        CallbackData memory callbackData = abi.decode(data, (CallbackData));

        // Settle `amount` of each currency from the the vault
        _settleAssetToVault(callbackData.currency0, address(this), callbackData.amount0);
        _settleAssetToVault(callbackData.currency1, address(this), callbackData.amount1);

        return "";
    }

    /**
     * @dev Manually add liquidity to the vault by first unlocking the pool manager then settling the removed funds
     * @param currency0 The currency 0
     * @param currency1 The currency 1
     * @param amount0 The amount of currency 0
     * @param amount1 The amount of currency 1
     */
    function _addLiquidityToVault(address currency0, address currency1, uint256 amount0, uint256 amount1) internal {
        vaultPoolManager.unlock(
            abi.encode(CallbackData(Currency.wrap(currency0), Currency.wrap(currency1), amount0, amount1))
        );
    }
}
