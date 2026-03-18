// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {VTSStorage, MarketVTSConfiguration} from "../types/VTS.sol";
import {IVRLSignalManager} from "../interfaces/IVRLSignalManager.sol";
import {IVRLSettlementObserver} from "../interfaces/IVRLSettlementObserver.sol";
import {IVTSAdmin} from "../interfaces/IVTSAdmin.sol";
import {Errors} from "../libraries/Errors.sol";

abstract contract VTSAdmin is IVTSAdmin {
    using PoolIdLibrary for PoolId;

    IVRLSettlementObserver public settlementObserver;
    IVRLSignalManager public signalManager;

    modifier onlyOwnerAdmin() {
        _checkOwner();
        _;
    }

    modifier onlyIfVRLHandlersRegistered() {
        _onlyIfVRLHandlersRegistered();
        _;
    }

    function _checkOwner() internal view virtual;
    function _vtsStorage() internal view virtual returns (VTSStorage storage);
    function _assertValidMarketVTSConfiguration(MarketVTSConfiguration memory cfg) internal pure virtual;

    function _onlyIfVRLHandlersRegistered() internal view {
        if (address(signalManager) == address(0) || address(settlementObserver) == address(0)) {
            revert Errors.InvalidAddress(address(0));
        }
    }

    function registerVRLProofHandlers(address _signalManager, address _settlementObserver)
        external
        override
        onlyOwnerAdmin
    {
        if (_signalManager == address(0)) revert Errors.InvalidAddress(_signalManager);
        if (_settlementObserver == address(0)) revert Errors.InvalidAddress(_settlementObserver);

        if (IVRLSignalManager(_signalManager).submitter() != address(this)) revert Errors.InvalidSender();
        if (IVRLSettlementObserver(_settlementObserver).submitter() != address(this)) revert Errors.InvalidSender();

        signalManager = IVRLSignalManager(_signalManager);
        settlementObserver = IVRLSettlementObserver(_settlementObserver);
        emit VRLProofHandlersRegistered(_signalManager, _settlementObserver);
    }

    function setMarketVTSConfiguration(PoolId corePoolId, MarketVTSConfiguration memory vtsConfiguration)
        external
        override
        onlyOwnerAdmin
    {
        _assertValidMarketVTSConfiguration(vtsConfiguration);
        _vtsStorage().pools[corePoolId].vtsConfig = vtsConfiguration;
        emit VTSConfigSet(PoolId.unwrap(corePoolId), vtsConfiguration);
    }
}
