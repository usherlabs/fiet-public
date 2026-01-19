// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * @title IBoundRegistry
 * @notice Interface for per-factory protocol-bound registry.
 */
interface IBoundRegistry {
    event BoundLevelSet(address indexed factory, address indexed who, uint8 level);

    /**
     * @notice Returns the bound level for an address within a factory namespace.
     * @dev 0 = not an endpoint, 1 = transfer endpoint, 2 = bucket-exempt endpoint.
     */
    function boundLevel(address factory, address who) external view returns (uint8);

    /**
     * @notice Returns bound levels for a pair of addresses within a factory namespace.
     */
    function boundLevels(address factory, address a, address b) external view returns (uint8 levelA, uint8 levelB);

    /**
     * @notice Returns the bound level for an address in the LCC's factory namespace.
     */
    function boundLevelOfLcc(address lcc, address who) external view returns (uint8);

    /**
     * @notice Returns bound levels for a pair of addresses in the LCC's factory namespace.
     */
    function boundLevelsOfLcc(address lcc, address a, address b) external view returns (uint8 levelA, uint8 levelB);

    /**
     * @notice Sets a bound level for a single address within the caller's factory namespace (factory only).
     */
    function setBoundLevel(address who, uint8 level) external;

    /**
     * @notice Sets a bound level for multiple addresses within the caller's factory namespace (factory only).
     */
    function setBoundLevels(address[] calldata who, uint8 level) external;
}
