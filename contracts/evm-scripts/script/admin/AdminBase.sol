// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {OracleDeploymentBook} from "../base/OracleDeploymentBook.sol";

interface IGlobalConfigProxyCall {
    function proxyCall(address target, bytes calldata data) external returns (bytes memory result);
}

interface IMarketFactoryAddresses {
    function vtsOrchestrator() external view returns (address);
    function oracleHelper() external view returns (address);
    function liquidityHub() external view returns (address);
}

interface IVTSOrchestratorAddresses {
    function signalManager() external view returns (address);
    function settlementObserver() external view returns (address);
}

abstract contract AdminBase is OracleDeploymentBook {
    string internal networkName;

    address internal globalConfig;
    address internal marketFactory;

    // Derived (via MarketFactory/VTSOrchestrator getters)
    address internal vtsOrchestrator;
    address internal oracleHelper;
    address internal liquidityHub;
    address internal signalManager;
    address internal settlementObserver;

    function _loadAdminAddresses() internal {
        networkName = vm.envString("NETWORK");
        _setFilename(networkName);

        globalConfig = readAddress("globalConfig");
        marketFactory = readAddress("marketFactory");

        // Derive the rest from MarketFactory + VTSOrchestrator getters (deployments file may not include them).
        vtsOrchestrator = IMarketFactoryAddresses(marketFactory).vtsOrchestrator();
        oracleHelper = IMarketFactoryAddresses(marketFactory).oracleHelper();
        liquidityHub = IMarketFactoryAddresses(marketFactory).liquidityHub();

        signalManager = IVTSOrchestratorAddresses(vtsOrchestrator).signalManager();
        settlementObserver = IVTSOrchestratorAddresses(vtsOrchestrator).settlementObserver();
    }

    function _proxyCall(address target, bytes memory data) internal returns (bytes memory) {
        return IGlobalConfigProxyCall(globalConfig).proxyCall(target, data);
    }
}

