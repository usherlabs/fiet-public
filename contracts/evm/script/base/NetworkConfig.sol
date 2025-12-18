// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {FileHelper} from "./FileHelper.sol";
import {SepoliaConstants} from "../constants/ArbitrumSepolia.sol";
import {ArbitrumConstants} from "../constants/Arbitrum.sol";
import {EthSepoliaConstants} from "../constants/EthSepolia.sol";

/**
 * @title NetworkConfig
 * @notice Base abstract contract for network configuration management
 * @dev Provides a unified way to load network-specific constants across all scripts
 */
abstract contract NetworkConfig is FileHelper {
    struct Config {
        address poolManager;
        address positionManager;
        address create2Deployer;
        address permit2;
        address universalRouter;
        address stateView;
    }

    string public networkName;
    Config public config;

    /**
     * @dev Initialises network configuration based on NETWORK environment variable
     * @notice Sets networkName and loads all network-specific constants into config struct
     * @notice Also sets the filename for FileHelper operations
     */
    function _initNetwork() internal {
        // Read network name from environment with fallback to "sepolia"
        try vm.envString("NETWORK") returns (string memory envNetworkName) {
            networkName = envNetworkName;
        } catch {
            networkName = "sepolia";
        }

        // Set filename for FileHelper operations
        _setFilename(networkName);

        // Load network-specific constants
        bytes32 networkHash = keccak256(bytes(networkName));

        if (networkHash == keccak256(bytes("sepolia"))) {
            config = Config({
                poolManager: SepoliaConstants.POOL_MANAGER,
                positionManager: SepoliaConstants.POSITION_MANAGER,
                create2Deployer: SepoliaConstants.DEPLOYER_CREATE2,
                permit2: SepoliaConstants.PERMIT2,
                universalRouter: SepoliaConstants.UNIVERSAL_ROUTER,
                stateView: SepoliaConstants.STATE_VIEW
            });
        } else if (networkHash == keccak256(bytes("arbitrum"))) {
            config = Config({
                poolManager: ArbitrumConstants.POOL_MANAGER,
                positionManager: ArbitrumConstants.POSITION_MANAGER,
                create2Deployer: ArbitrumConstants.DEPLOYER_CREATE2,
                permit2: ArbitrumConstants.PERMIT2,
                universalRouter: ArbitrumConstants.UNIVERSAL_ROUTER,
                stateView: ArbitrumConstants.STATE_VIEW
            });
        } else if (networkHash == keccak256(bytes("ethsepolia"))) {
            config = Config({
                poolManager: EthSepoliaConstants.POOL_MANAGER,
                positionManager: EthSepoliaConstants.POSITION_MANAGER,
                create2Deployer: EthSepoliaConstants.DEPLOYER_CREATE2,
                permit2: EthSepoliaConstants.PERMIT2,
                universalRouter: EthSepoliaConstants.UNIVERSAL_ROUTER,
                stateView: EthSepoliaConstants.STATE_VIEW
            });
        } else {
            revert("Unsupported network");
        }
    }
}

