// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

/// @dev Standalone overload slice so tests can take `dryModifyLiquidities(BalanceDelta).selector` without
///      colliding with `dryModifyLiquidities(VaultSettlementIntent)` on `IMarketVault`.
interface IMarketVaultDryBalanceDelta {
    function dryModifyLiquidities(BalanceDelta balanceDelta) external view returns (BalanceDelta);
}
