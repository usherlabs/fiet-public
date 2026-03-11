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
 * @notice Direct-core reaction layer for canonical market vaults.
 * @dev This module sits between sequencing (`MarketFactory`) and generic vault primitives (`MarketVault`).
 *      Method names are intentionally broad while remaining contract-scoped to this vault.
 */
abstract contract VaultCoreActionHandler is MarketVault, IVaultCoreActionHandler {
    constructor(address _marketFactory) MarketVault(_marketFactory) {}

    /// @dev Derived vaults provide the bound core pool key for lane resolution.
    function _corePoolKey() internal view virtual returns (PoolKey memory);

    /**
     * @inheritdoc IVaultCoreActionHandler
     */
    function handleAddLiquidity(uint256 wrappedAmount0, uint256 wrappedAmount1) external virtual onlyFactory {
        PoolKey memory key = _corePoolKey();
        ILCC lccToken0 = ILCC(Currency.unwrap(key.currency0));
        ILCC lccToken1 = ILCC(Currency.unwrap(key.currency1));

        if (wrappedAmount0 > 0) {
            _settleUnderlyingToVaultFromHub(lccToken0, wrappedAmount0);
        }
        if (wrappedAmount1 > 0) {
            _settleUnderlyingToVaultFromHub(lccToken1, wrappedAmount1);
        }

        // New core liquidity can unlock queued settlement fulfilment.
        _settleObligations(key);
    }

    /**
     * @inheritdoc IVaultCoreActionHandler
     */
    function handleSwap(address lccTokenIn, uint256 wrappedAmountIn) external virtual onlyFactory {
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

        if (wrappedAmountIn > 0) {
            _settleUnderlyingToVaultFromHub(ILCC(lccTokenIn), wrappedAmountIn);
        }

        _settleObligationsForLCC(ILCC(lccTokenIn));
    }
}

