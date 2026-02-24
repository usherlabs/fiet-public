// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IMarketVault} from "../../src/interfaces/IMarketVault.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title MockMarketVault
/// @notice Mock vault for onMMSettle testing
contract MockMarketVault is IMarketVault {
    BalanceDelta public availableLiquidity;
    BalanceDelta public coreAvailableLiquidity;
    bool public hasCoreAvailableLiquidity;
    mapping(Currency => uint256) public balances;

    function setAvailableLiquidity(int128 amount0, int128 amount1) external {
        availableLiquidity = toBalanceDelta(amount0, amount1);
    }

    function setCoreAvailableLiquidity(int128 amount0, int128 amount1) external {
        coreAvailableLiquidity = toBalanceDelta(amount0, amount1);
        hasCoreAvailableLiquidity = true;
    }

    function clearCoreAvailableLiquidity() external {
        hasCoreAvailableLiquidity = false;
    }

    function dryModifyLiquidities(BalanceDelta requested) public view returns (BalanceDelta) {
        // Return min of requested and available for each token
        int128 a0 =
            requested.amount0() > availableLiquidity.amount0() ? availableLiquidity.amount0() : requested.amount0();
        int128 a1 =
            requested.amount1() > availableLiquidity.amount1() ? availableLiquidity.amount1() : requested.amount1();
        return toBalanceDelta(a0, a1);
    }

    function modifyLiquidities(BalanceDelta) external pure override {
        // No-op for testing
    }

    function modifyLiquiditiesCore(BalanceDelta) external pure override {
        // No-op for testing
    }

    function tryModifyLiquidities(BalanceDelta balanceDelta) external view override returns (BalanceDelta) {
        return dryModifyLiquidities(balanceDelta);
    }

    function tryModifyLiquiditiesCore(BalanceDelta balanceDelta) external view override returns (BalanceDelta) {
        return dryModifyLiquiditiesCore(balanceDelta);
    }

    function tryModifyLiquiditiesWithRecipient(BalanceDelta balanceDelta, address)
        external
        view
        override
        returns (BalanceDelta)
    {
        return dryModifyLiquidities(balanceDelta);
    }

    function tryModifyLiquiditiesCoreWithRecipient(BalanceDelta balanceDelta, address)
        external
        view
        override
        returns (BalanceDelta)
    {
        return dryModifyLiquiditiesCore(balanceDelta);
    }

    function dryModifyLiquiditiesCore(BalanceDelta requested) public view override returns (BalanceDelta) {
        if (!hasCoreAvailableLiquidity) {
            return dryModifyLiquidities(requested);
        }
        int128 a0 = requested.amount0() > coreAvailableLiquidity.amount0()
            ? coreAvailableLiquidity.amount0()
            : requested.amount0();
        int128 a1 = requested.amount1() > coreAvailableLiquidity.amount1()
            ? coreAvailableLiquidity.amount1()
            : requested.amount1();
        return toBalanceDelta(a0, a1);
    }

    function inMarketBalanceOf(Currency currency) external view override returns (uint256) {
        return balances[currency];
    }

    function lccs() external pure override returns (address lccToken0, address lccToken1) {
        return (address(0), address(0));
    }
}

