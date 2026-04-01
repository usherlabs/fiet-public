// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {PausableVTS} from "../../../src/modules/PausableVTS.sol";
import {VTSStorage} from "../../../src/types/VTS.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

/// @notice Echidna harness for PAUSE-01 global/pool pause guards.
contract PAUSE01 {
    uint256 internal constant MAX_VACUOUS_ATTEMPTS = 12;

    PausableHarness internal h;
    uint256 internal attempts;
    uint256 internal checks;
    bool internal allOk = true;
    bool internal sawBlocked;
    bool internal sawUnblocked;
    bool internal sawActive;
    bool internal sawInactive;

    constructor() {
        h = new PausableHarness();
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function action_pause_01_entrypoints_guarded(
        bool globalPaused,
        bool poolPaused,
        uint256 poolSeed,
        bool activeSettlement
    ) external {
        unchecked {
            attempts++;
        }
        PoolId poolId = PoolId.wrap(bytes32(poolSeed));

        h.configurePause(poolId, globalPaused, poolPaused);

        bool proc = h.tryProcessPosition(poolId);
        bool swap = h.tryAfterCoreSwap(poolId);
        bool settle = h.trySettlePositionGrowths(poolId, activeSettlement);

        bool blockedPool = globalPaused || poolPaused;
        bool expectedProcSwap = !blockedPool;
        bool expectedSettle = activeSettlement ? !blockedPool : !globalPaused;

        checks++;
        if (blockedPool || globalPaused) sawBlocked = true;
        if (!blockedPool && !globalPaused) sawUnblocked = true;
        if (activeSettlement) sawActive = true;
        else sawInactive = true;
        allOk = allOk && proc == expectedProcSwap && swap == expectedProcSwap && settle == expectedSettle;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_pause_01_guards_hold() external view returns (bool) {
        if (checks == 0 || !sawBlocked || !sawUnblocked || !sawActive || !sawInactive) {
            return attempts < MAX_VACUOUS_ATTEMPTS;
        }
        return allOk;
    }
}

contract PausableHarness is PausableVTS {
    VTSStorage internal s;

    constructor() Ownable(msg.sender) {}

    function _vtsStorage() internal view override returns (VTSStorage storage) {
        return s;
    }

    function configurePause(PoolId poolId, bool globalPaused, bool poolPaused) external {
        this.setGlobalPause(globalPaused);
        if (poolPaused) {
            if (!s.pools[poolId].isPaused) this.pausePool(poolId);
        } else if (s.pools[poolId].isPaused) {
            this.unpausePool(poolId);
        }
    }

    function processPosition(PoolId poolId) external view notPoolPaused(poolId) {}

    function afterCoreSwap(PoolId poolId) external view notPoolPaused(poolId) {}

    function settlePositionGrowths(PoolId poolId, bool isActivePosition) external view {
        if (isActivePosition) {
            _notPoolPaused(poolId);
        } else {
            _notGlobalPaused();
        }
    }

    function tryProcessPosition(PoolId poolId) external returns (bool ok) {
        try this.processPosition(poolId) {
            ok = true;
        } catch {
            ok = false;
        }
    }

    function tryAfterCoreSwap(PoolId poolId) external returns (bool ok) {
        try this.afterCoreSwap(poolId) {
            ok = true;
        } catch {
            ok = false;
        }
    }

    function trySettlePositionGrowths(PoolId poolId, bool isActivePosition) external returns (bool ok) {
        try this.settlePositionGrowths(poolId, isActivePosition) {
            ok = true;
        } catch {
            ok = false;
        }
    }
}

