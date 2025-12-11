// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/// @title IResilientOracle
/// @notice Interface for Venus Protocol's ResilientOracle
/// @dev Full implementation: oracle-scripts/oracle/contracts/ResilientOracle.sol
/// @dev Venus Protocol: https://github.com/VenusProtocol/oracle
interface IResilientOracle {
    enum OracleRole {
        MAIN,
        PIVOT,
        FALLBACK
    }

    struct TokenConfig {
        /// @notice asset address
        address asset;
        /// @notice `oracles` stores the oracles based on their role in the following order:
        /// [main, pivot, fallback],
        /// It can be indexed with the corresponding enum OracleRole value
        address[3] oracles;
        /// @notice `enableFlagsForOracles` stores the enabled state
        /// for each oracle in the same order as `oracles`
        bool[3] enableFlagsForOracles;
        /// @notice `cachingEnabled` is a flag that indicates whether the asset price should be cached
        bool cachingEnabled;
    }

    /// @notice Gets price of an asset
    /// @param asset Asset address
    /// @return price USD price in 18 decimals
    function getPrice(address asset) external view returns (uint256);

    /// @notice Gets price of the underlying asset for a given vToken
    /// @param vToken vToken address (LCC address in our case)
    /// @return price USD price in 18 decimals
    function getUnderlyingPrice(address vToken) external view returns (uint256);

    /// @notice Gets token configuration for an asset
    /// @param asset Asset address
    /// @return tokenConfig The token configuration
    function getTokenConfig(address asset) external view returns (TokenConfig memory);

    /// @notice Gets oracle address and enabled status
    /// @param asset Asset address
    /// @param role Oracle role
    /// @return oracle Oracle address
    /// @return enabled Whether oracle is enabled
    function getOracle(address asset, OracleRole role) external view returns (address oracle, bool enabled);

    /// @notice Updates the cached price for an asset
    /// @param asset Asset address
    function updateAssetPrice(address asset) external;

    /// @notice Paused state
    function paused() external view returns (bool);
}
