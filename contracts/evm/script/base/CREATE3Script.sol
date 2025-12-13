// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.26;

import "forge-std/Script.sol";

import {CREATE3} from "solmate/src/utils/CREATE3.sol";

/// @title Factory for deploying contracts to deterministic addresses via CREATE3
/// @author zefram.eth
/// @notice Enables deploying contracts using CREATE3. Each deployer (msg.sender) has
/// its own namespace for deployed addresses.
interface ICREATE3Factory {
    /// @notice Deploys a contract using CREATE3
    /// @dev The provided salt is hashed together with msg.sender to generate the final salt
    /// @param salt The deployer-specific salt for determining the deployed contract's address
    /// @param creationCode The creation code of the contract to deploy
    /// @return deployed The address of the deployed contract
    function deploy(bytes32 salt, bytes memory creationCode) external payable returns (address deployed);

    /// @notice Predicts the address of a deployed contract
    /// @dev The provided salt is hashed together with the deployer address to generate the final salt
    /// @param deployer The deployer account that will call deploy()
    /// @param salt The deployer-specific salt for determining the deployed contract's address
    /// @return deployed The address of the contract that will be deployed
    function getDeployed(address deployer, bytes32 salt) external view returns (address deployed);
}

/// @title Factory for deploying contracts to deterministic addresses via CREATE3
/// @author zefram.eth
/// @notice Enables deploying contracts using CREATE3. Each deployer (msg.sender) has
/// its own namespace for deployed addresses.
/// @dev Reference: https://github.com/ZeframLou/create3-factory/blob/main/src/CREATE3Factory.sol
contract CREATE3Factory is ICREATE3Factory {
    /// @inheritdoc	ICREATE3Factory
    function deploy(bytes32 salt, bytes memory creationCode) external payable override returns (address deployed) {
        // hash salt with the deployer address to give each deployer its own namespace
        salt = keccak256(abi.encodePacked(msg.sender, salt));
        return CREATE3.deploy(salt, creationCode, msg.value);
    }

    /// @inheritdoc	ICREATE3Factory
    function getDeployed(address deployer, bytes32 salt) external view override returns (address deployed) {
        // hash salt with the deployer address to give each deployer its own namespace
        salt = keccak256(abi.encodePacked(deployer, salt));
        return CREATE3.getDeployed(salt);
    }
}

/// @dev Reference: https://github.com/Bunniapp/bunni-v2/blob/main/script/base/CREATE3Script.sol
abstract contract CREATE3Script is Script {
    CREATE3Factory internal constant create3 = CREATE3Factory(0x9fBB3DF7C40Da2e5A0dE984fFE2CCB7C47cd0ABf);

    string internal version;

    constructor(string memory version_) {
        version = version_;
    }

    function getCreate3Contract(string memory name) internal view virtual returns (address) {
        address deployer = vm.envAddress("DEPLOYER");

        return create3.getDeployed(deployer, getCreate3ContractSalt(name));
    }

    function getCreate3Contract(string memory name, string memory _version) internal view virtual returns (address) {
        address deployer = vm.envAddress("DEPLOYER");

        return create3.getDeployed(deployer, getCreate3ContractSalt(name, _version));
    }

    function getCreate3ContractSalt(string memory name) internal view virtual returns (bytes32) {
        return keccak256(bytes(string.concat(name, "-v", version)));
    }

    function getCreate3ContractSalt(string memory name, string memory _version)
        internal
        view
        virtual
        returns (bytes32)
    {
        return keccak256(bytes(string.concat(name, "-v", _version)));
    }

    function getCreate3SaltFromEnv(string memory name) internal view virtual returns (bytes32) {
        bytes32 salt = vm.envBytes32(string.concat("SALT_", name));
        return salt;
    }

    function getCreate3ContractFromEnvSalt(string memory name) internal view virtual returns (address) {
        address deployer = vm.envAddress("DEPLOYER");
        bytes32 salt = vm.envBytes32(string.concat("SALT_", name));

        return create3.getDeployed(deployer, salt);
    }
}
