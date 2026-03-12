// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ILCC} from "../interfaces/ILCC.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {MarketVault} from "./MarketVault.sol";
import {IVaultCoreActionHandler} from "../interfaces/IVaultCoreActionHandler.sol";
import {Errors} from "../libraries/Errors.sol";
import {CoreActionFlag} from "../libraries/CoreActionFlag.sol";

/**
 * @title VaultCoreActionHandler
 * @notice Ingress/direct-core reaction layer for canonical market vaults.
 * @dev This module sits between factory coordination and generic vault primitives (`MarketVault`).
 */
abstract contract VaultCoreActionHandler is MarketVault, IVaultCoreActionHandler {
    constructor(address _marketFactory) MarketVault(_marketFactory) {}

    /// @dev Derived vaults provide the bound core hook address for direct-action gating.
    function _coreHook() internal view virtual returns (address);

    modifier onlyCoreHook() {
        if (msg.sender != _coreHook()) {
            revert Errors.InvalidSender();
        }
        _;
    }

    /// @dev Derived vaults provide the bound core pool key for lane resolution.
    function _corePoolKey() internal view virtual returns (PoolKey memory);

    /**
     * @inheritdoc IVaultCoreActionHandler
     */
    function handleIngress(address lcc, uint256 wrappedAmount) external virtual onlyFactory {
        if (wrappedAmount == 0) {
            return;
        }
        PoolKey memory key = _corePoolKey();
        address lcc0 = Currency.unwrap(key.currency0);
        address lcc1 = Currency.unwrap(key.currency1);
        if (lcc != lcc0 && lcc != lcc1) {
            revert Errors.InvalidSender();
        }
        _settleUnderlyingToVaultFromHub(ILCC(lcc), wrappedAmount);
    }

    /**
     * @inheritdoc IVaultCoreActionHandler
     */
    function handleAddLiquidity() external virtual onlyCoreHook {
        // Proxy-routed swaps call into core pool internally; those paths must never run direct-action follow-up.
        if (!CoreActionFlag.isDirectCoreAction()) {
            return;
        }
        PoolKey memory key = _corePoolKey();
        // New core liquidity can unlock queued settlement fulfilment.
        _settleObligations(key);
    }

    /**
     * @inheritdoc IVaultCoreActionHandler
     */
    function handleSwap(address lccTokenIn) external virtual onlyCoreHook {
        // Proxy-routed swaps call into core pool internally; those paths must never run direct-action settlement.
        if (!CoreActionFlag.isDirectCoreAction()) {
            return;
        }

        PoolKey memory key = _corePoolKey();
        address lcc0 = Currency.unwrap(key.currency0);
        address lcc1 = Currency.unwrap(key.currency1);
        if (lccTokenIn != lcc0 && lccTokenIn != lcc1) {
            revert Errors.InvalidSender();
        }

        _settleObligationsForLCC(ILCC(lccTokenIn));
    }
}

