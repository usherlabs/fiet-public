// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {MarketVTSConfiguration} from "../types/VTS.sol";

interface IVTSAdmin {
    event VTSConfigSet(bytes32 indexed marketId, MarketVTSConfiguration newConfig);
    event VRLProofHandlersRegistered(address indexed signalManager, address indexed settlementObserver);

    /// @notice Set the market VTS configuration
    /// @param corePoolId The core pool ID
    /// @param vtsConfiguration The VTS configuration to set
    function setMarketVTSConfiguration(PoolId corePoolId, MarketVTSConfiguration memory vtsConfiguration) external;

    /// @notice Register VRL proof handlers used by commitment and settlement paths
    /// @param signalManager The VRL signal manager address
    /// @param settlementObserver The VRL settlement observer address
    function registerVRLProofHandlers(address signalManager, address settlementObserver) external;
}
