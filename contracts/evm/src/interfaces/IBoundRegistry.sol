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
     * @dev 0 = none, 1 = transfer endpoint (bucket-tracked), 2 = bucket-exempt endpoint, 3 = DEX ingress sink.
     *      At the registry layer, `BOUND_EXEMPT` and `BOUND_DEX` are immutable once set and may only be first-assigned
     *      from `BOUND_NONE`; `BOUND_NONE` <-> `BOUND_ENDPOINT` is the only mutable admin path. Any market-specific
     *      `MarketFactory` is expected to hardcode the stronger policy that EXEMPT/DEX only arise from setup /
     *      integration paths, and those factory contracts are trusted for that policy.
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
     * @dev Reverts `Errors.InvalidBoundLevelTransition` on disallowed transitions (immutable EXEMPT/DEX or assigning them
     *      after the first `BOUND_NONE` state).
     */
    function setBoundLevel(address who, uint8 level) external;

    /**
     * @notice Sets a bound level for multiple addresses within the caller's factory namespace (factory only).
     * @dev Same transition rules as `setBoundLevel`.
     */
    function setBoundLevels(address[] calldata who, uint8 level) external;
}
