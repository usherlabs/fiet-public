// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.26;

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
    // Default (canonical) CREATE3 factory address used by upstream tooling.
    // For fresh devnets (eg, Nitro), you may instead deploy a CREATE3Factory and set
    // `CREATE3_FACTORY=<deployed address>` when running scripts.
    address internal constant DEFAULT_CREATE3_FACTORY = 0x9fBB3DF7C40Da2e5A0dE984fFE2CCB7C47cd0ABf;
    uint256 internal constant ARBITRUM_SEPOLIA_CHAIN_ID = 421614;
    address internal constant DEFAULT_CREATE3_FACTORY_ARBITRUM_SEPOLIA = 0x0EC3715467915Cbd7355A6B111510e4a09D9ccC0;
    ICREATE3Factory internal create3;

    string internal version;

    constructor(string memory version_) {
        version = version_;
        address factory;
        try vm.envAddress("CREATE3_FACTORY") returns (address a) {
            factory = a;
        } catch {
            factory = (block.chainid == ARBITRUM_SEPOLIA_CHAIN_ID)
                ? DEFAULT_CREATE3_FACTORY_ARBITRUM_SEPOLIA
                : DEFAULT_CREATE3_FACTORY;
        }
        create3 = ICREATE3Factory(factory);
    }

    /// @dev Loads the deployer private key from the PRIVATE_KEY environment variable
    function _getDeployerPrivateKey() internal view returns (uint256) {
        return uint256(vm.envBytes32("PRIVATE_KEY"));
    }

    /// @dev Derives the deployer address from the PRIVATE_KEY environment variable
    function _getDeployer() internal view returns (address) {
        return vm.addr(_getDeployerPrivateKey());
    }

    function getCreate3Contract(string memory name) internal view virtual returns (address) {
        return create3.getDeployed(_getDeployer(), getCreate3ContractSalt(name));
    }

    function getCreate3Contract(string memory name, string memory _version) internal view virtual returns (address) {
        return create3.getDeployed(_getDeployer(), getCreate3ContractSalt(name, _version));
    }

    function getCreate3ContractSalt(string memory name) internal view virtual returns (bytes32) {
        return keccak256(bytes(_buildCreate3SaltSeed(name, version)));
    }

    function getCreate3ContractSalt(string memory name, string memory _version)
        internal
        view
        virtual
        returns (bytes32)
    {
        return keccak256(bytes(_buildCreate3SaltSeed(name, _version)));
    }

    /// @dev Builds the CREATE3 salt seed from contract name, version, and optional CREATE3_SALT env suffix.
    ///      This preserves unique salts per contract name while allowing deterministic namespace rotation.
    function _buildCreate3SaltSeed(string memory name, string memory _version) internal view returns (string memory) {
        string memory baseSeed = string.concat(name, "-v", _version);
        // Use envOr to avoid noisy vm.envString reverts when CREATE3_SALT is intentionally unset.
        string memory envSaltSuffix = vm.envOr("CREATE3_SALT", string(""));
        if (bytes(envSaltSuffix).length > 0) {
            return string.concat(baseSeed, "-", envSaltSuffix);
        }
        return baseSeed;
    }

    /// @dev Fail-fast sanity check for CREATE3 factory wiring.
    function _assertCreate3FactoryDeployed() internal view {
        require(address(create3) != address(0), "CREATE3: factory is zero address");
        require(address(create3).code.length > 0, "CREATE3: factory has no code (set CREATE3_FACTORY or run setup-create3)");
    }

    function getCreate3SaltFromEnv(string memory name) internal view virtual returns (bytes32) {
        bytes32 salt = vm.envBytes32(string.concat("SALT_", name));
        return salt;
    }

    function getCreate3ContractFromEnvSalt(string memory name) internal view virtual returns (address) {
        bytes32 salt = vm.envBytes32(string.concat("SALT_", name));

        return create3.getDeployed(_getDeployer(), salt);
    }
}
