// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IMarketVault} from "../../src/interfaces/IMarketVault.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {VaultSettlementIntent} from "../../src/types/VTS.sol";

contract MockCanonicalVaultRef {
    address public immutable marketFactory;

    constructor(address _marketFactory) {
        marketFactory = _marketFactory;
    }
}

/// @title MockMarketVault
/// @notice Mock vault for onMMSettle testing
contract MockMarketVault is IMarketVault {
    BalanceDelta public availableLiquidity;
    mapping(Currency => uint256) public balances;
    /// @dev Cumulative amounts passed to `increaseLiquidityReserve` (for settlement / reserve regression tests).
    mapping(address => uint256) public totalLiquidityReserveIncreases;
    address internal immutable canonical;

    /// @param canonicalOverride If zero, deploys `MockCanonicalVaultRef` with `marketFactory == address(this)` (legacy
    ///        harness behaviour). If non-zero, uses that address as `canonicalVault()` (for shared-factory tests).
    constructor(address canonicalOverride) {
        if (canonicalOverride == address(0)) {
            canonical = address(new MockCanonicalVaultRef(address(this)));
        } else {
            canonical = canonicalOverride;
        }
    }

    function marketId() external pure returns (bytes32) {
        return bytes32(0);
    }

    function canonicalVault() external view returns (address) {
        return canonical;
    }

    function setAvailableLiquidity(int128 amount0, int128 amount1) external {
        availableLiquidity = toBalanceDelta(amount0, amount1);
    }

    function dryModifyLiquidities(BalanceDelta balanceDelta) public view returns (BalanceDelta) {
        // Return min of requested and available for each token
        int128 a0 = balanceDelta.amount0() > availableLiquidity.amount0()
            ? availableLiquidity.amount0()
            : balanceDelta.amount0();
        int128 a1 = balanceDelta.amount1() > availableLiquidity.amount1()
            ? availableLiquidity.amount1()
            : balanceDelta.amount1();
        return toBalanceDelta(a0, a1);
    }

    function dryModifyLiquidities(VaultSettlementIntent calldata settlementIntent)
        external
        view
        override
        returns (BalanceDelta)
    {
        return dryModifyLiquidities(settlementIntent.requestedDelta);
    }

    function modifyLiquidities(BalanceDelta) external pure override {
        // No-op for testing
    }

    function modifyLiquidities(VaultSettlementIntent calldata) external pure override {
        // No-op for testing
    }

    function tryModifyLiquidities(BalanceDelta balanceDelta) external view override returns (BalanceDelta) {
        return dryModifyLiquidities(balanceDelta);
    }

    function tryModifyLiquidities(VaultSettlementIntent calldata settlementIntent)
        external
        view
        override
        returns (BalanceDelta)
    {
        return dryModifyLiquidities(settlementIntent.requestedDelta);
    }

    function tryModifyLiquiditiesWithRecipient(BalanceDelta balanceDelta, address)
        external
        view
        override
        returns (BalanceDelta)
    {
        return dryModifyLiquidities(balanceDelta);
    }

    function tryModifyLiquiditiesWithRecipient(VaultSettlementIntent calldata settlementIntent, address)
        external
        view
        override
        returns (BalanceDelta)
    {
        return dryModifyLiquidities(settlementIntent.requestedDelta);
    }

    function inMarketBalanceOf(Currency currency) external view override returns (uint256) {
        return balances[currency];
    }

    function lccs() external pure override returns (address lccToken0, address lccToken1) {
        return (address(0), address(0));
    }

    function decreaseLiquidityReserve(Currency, uint256) external pure {}

    function increaseLiquidityReserve(Currency currency, uint256 amount) external {
        if (amount == 0) return;
        totalLiquidityReserveIncreases[Currency.unwrap(currency)] += amount;
    }
}

