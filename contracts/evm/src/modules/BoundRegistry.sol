// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IBoundRegistry} from "../interfaces/IBoundRegistry.sol";
import {Bounds} from "../libraries/Bounds.sol";
import {Errors} from "../libraries/Errors.sol";

/**
 * @title BoundRegistry
 * @notice Abstract registry for protocol-bound endpoints (per-factory namespace).
 */
abstract contract BoundRegistry is IBoundRegistry {
    // Bound levels: _boundLevel[factory][who] -> 0 = none, 1 = transfer endpoint, 2 = bucket-exempt endpoint.
    mapping(address => mapping(address => uint8)) internal _boundLevel;

    event BoundLevelUpdated(address indexed factory, address indexed who, uint8 level);

    /// @notice Resolve the market id + factory for a given LCC (implemented by child).
    function _lccMarket(address lcc) internal view virtual returns (bytes32 id, address factory);

    /// @notice Returns the bound level for `who` in a specific factory namespace.
    function boundLevel(address factory, address who) public view returns (uint8) {
        return _boundLevel[factory][who];
    }

    /// @notice Returns the bound levels for two addresses in a specific factory namespace.
    function boundLevels(address factory, address a, address b) public view returns (uint8 levelA, uint8 levelB) {
        return (_boundLevel[factory][a], _boundLevel[factory][b]);
    }

    /// @notice Returns the bound level for `who` scoped to the factory of `lcc`.
    /// @dev If the LCC is not initialised (market id == 0), treat as unbound.
    function boundLevelOfLcc(address lcc, address who) public view returns (uint8) {
        (bytes32 id, address factory) = _lccMarket(lcc);
        if (id == bytes32(0)) return Bounds.BOUND_NONE;
        return _boundLevel[factory][who];
    }

    /// @notice Returns bound levels for two addresses scoped to the factory of `lcc`.
    /// @dev If the LCC is not initialised (market id == 0), both are treated as unbound.
    function boundLevelsOfLcc(address lcc, address a, address b) public view returns (uint8 levelA, uint8 levelB) {
        (bytes32 id, address factory) = _lccMarket(lcc);
        if (id == bytes32(0)) return (Bounds.BOUND_NONE, Bounds.BOUND_NONE);
        return (_boundLevel[factory][a], _boundLevel[factory][b]);
    }

    /// @dev Internal setter with validation + event emission.
    function _setBoundLevel(address factory, address who, uint8 level) internal {
        if (level > Bounds.BOUND_EXEMPT) {
            revert Errors.InvalidAmount(level, Bounds.BOUND_EXEMPT);
        }
        _boundLevel[factory][who] = level;
        emit BoundLevelUpdated(factory, who, level);
    }

    /// @notice External setter (authorisation enforced by implementing contract).
    function setBoundLevel(address who, uint8 level) external virtual;

    /// @notice Batch external setter (authorisation enforced by implementing contract).
    function setBoundLevels(address[] calldata who, uint8 level) external virtual;
}
