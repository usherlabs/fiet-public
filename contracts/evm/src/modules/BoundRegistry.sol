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

    function _lccMarket(address lcc) internal view virtual returns (bytes32 id, address factory);

    function boundLevel(address factory, address who) external view returns (uint8) {
        return _boundLevel[factory][who];
    }

    function boundLevels(address factory, address a, address b) external view returns (uint8 levelA, uint8 levelB) {
        return (_boundLevel[factory][a], _boundLevel[factory][b]);
    }

    function boundLevelOfLcc(address lcc, address who) external view returns (uint8) {
        (bytes32 id, address factory) = _lccMarket(lcc);
        if (id == bytes32(0)) return Bounds.BOUND_NONE;
        return _boundLevel[factory][who];
    }

    function boundLevelsOfLcc(address lcc, address a, address b) external view returns (uint8 levelA, uint8 levelB) {
        (bytes32 id, address factory) = _lccMarket(lcc);
        if (id == bytes32(0)) return (Bounds.BOUND_NONE, Bounds.BOUND_NONE);
        return (_boundLevel[factory][a], _boundLevel[factory][b]);
    }

    function _setBoundLevel(address factory, address who, uint8 level) internal {
        if (level > Bounds.BOUND_EXEMPT) {
            revert Errors.InvalidAmount(level, Bounds.BOUND_EXEMPT);
        }
        _boundLevel[factory][who] = level;
        emit BoundLevelUpdated(factory, who, level);
    }

    function setBoundLevel(address who, uint8 level) external virtual;

    function setBoundLevels(address[] calldata who, uint8 level) external virtual;
}
