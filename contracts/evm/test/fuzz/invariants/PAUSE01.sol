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
    uint256 internal procSwapAttempts;
    uint256 internal procSwapChecks;
    bool internal procSwapAllOk = true;
    uint256 internal activeSettleAttempts;
    uint256 internal activeSettleChecks;
    bool internal activeSettleAllOk = true;
    uint256 internal inactiveSettleAttempts;
    uint256 internal inactiveSettleChecks;
    bool internal inactiveSettleAllOk = true;

    constructor() {
        h = new PausableHarness();
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function action_pause_01_proc_swap_guarded(bool globalPaused, bool poolPaused, uint256 poolSeed) external {
        unchecked {
            procSwapAttempts++;
        }
        (globalPaused, poolPaused) = _pauseCase(procSwapAttempts, globalPaused, poolPaused);
        PoolId poolId = PoolId.wrap(bytes32(poolSeed));

        h.configurePause(poolId, globalPaused, poolPaused);

        bool proc = h.tryProcessPosition(poolId);
        bool swap = h.tryAfterCoreSwap(poolId);

        bool blockedPool = globalPaused || poolPaused;
        bool expectedProcSwap = !blockedPool;

        procSwapChecks++;
        procSwapAllOk = procSwapAllOk && proc == expectedProcSwap && swap == expectedProcSwap;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function action_pause_01_active_settle_guarded(bool globalPaused, bool poolPaused, uint256 poolSeed) external {
        unchecked {
            activeSettleAttempts++;
        }
        (globalPaused, poolPaused) = _pauseCase(activeSettleAttempts, globalPaused, poolPaused);
        PoolId poolId = PoolId.wrap(bytes32(poolSeed));

        h.configurePause(poolId, globalPaused, poolPaused);

        bool settle = h.trySettlePositionGrowths(poolId, true);
        bool expectedSettle = !(globalPaused || poolPaused);

        activeSettleChecks++;
        activeSettleAllOk = activeSettleAllOk && settle == expectedSettle;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function action_pause_01_inactive_settle_guarded(bool globalPaused, bool poolPaused, uint256 poolSeed) external {
        unchecked {
            inactiveSettleAttempts++;
        }
        (globalPaused, poolPaused) = _pauseCase(inactiveSettleAttempts, globalPaused, poolPaused);
        PoolId poolId = PoolId.wrap(bytes32(poolSeed));

        h.configurePause(poolId, globalPaused, poolPaused);

        bool settle = h.trySettlePositionGrowths(poolId, false);
        bool expectedSettle = !globalPaused;

        inactiveSettleChecks++;
        inactiveSettleAllOk = inactiveSettleAllOk && settle == expectedSettle;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_pause_01_proc_swap_guards_hold() external view returns (bool) {
        if (procSwapChecks == 0) {
            return procSwapAttempts < MAX_VACUOUS_ATTEMPTS;
        }
        return procSwapAllOk;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_pause_01_active_settle_guard_holds() external view returns (bool) {
        if (activeSettleChecks == 0) {
            return activeSettleAttempts < MAX_VACUOUS_ATTEMPTS;
        }
        return activeSettleAllOk;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_pause_01_inactive_settle_guard_holds() external view returns (bool) {
        if (inactiveSettleChecks == 0) {
            return inactiveSettleAttempts < MAX_VACUOUS_ATTEMPTS;
        }
        return inactiveSettleAllOk;
    }

    function _pauseCase(uint256 attempt, bool globalPaused, bool poolPaused) internal pure returns (bool, bool) {
        uint256 mode = (attempt - 1) % 3;
        if (mode == 0) {
            return (false, false);
        }
        if (mode == 1) {
            return (false, true);
        }
        globalPaused = true;
        poolPaused = false;
        return (globalPaused, poolPaused);
    }
}

contract PausableHarness is PausableVTS {
    VTSStorage internal s;

    constructor() Ownable(msg.sender) {}

    function _vtsStorage() internal view override returns (VTSStorage storage) {
        return s;
    }

    function configurePause(PoolId poolId, bool globalPaused, bool poolPaused) external {
        s.isPaused = globalPaused;
        if (poolPaused) {
            s.pools[poolId].isPaused = true;
        } else if (s.pools[poolId].isPaused) {
            s.pools[poolId].isPaused = false;
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

