// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {VTSOrchestratorFixture} from "./base/VTSOrchestratorFixture.sol";
import {IVTSOrchestrator} from "../src/interfaces/IVTSOrchestrator.sol";
import {VTSOrchestrator} from "../src/VTSOrchestrator.sol";
import {LiquiditySignal} from "../src/types/Commit.sol";
import {IMarketVault} from "../src/interfaces/IMarketVault.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {RFSCheckpoint} from "../src/types/Checkpoint.sol";

/**
 * @dev Malicious signal-manager implementation used via `vm.etch` onto the deployed `signalManager` address.
 *
 * Purpose: kill `nonReentrant`-removal mutants on VTSOrchestrator entrypoints (notably `checkpoint`).
 */
contract ReentrantSignalManagerForMutation {
    error Reentered();

    address internal immutable target;

    // 0 = none, 6 = checkpoint
    uint8 internal kind;

    uint256 internal commitId;
    uint256 internal positionIndex;

    constructor(address target_) {
        target = target_;
    }

    function armCheckpoint(uint256 _commitId, uint256 _positionIndex) external {
        kind = 6;
        commitId = _commitId;
        positionIndex = _positionIndex;
    }

    function verifyLiquiditySignal(
        address,
        bytes memory liquiditySignal,
        bool /*revertOnInvalid*/
    )
        external
        returns (bool, uint256)
    {
        uint8 k = kind;
        if (k != 0) {
            kind = 0;
            (bool ok,) = _reenter(k, liquiditySignal);
            if (ok) revert Reentered();
        }
        LiquiditySignal memory sig = abi.decode(liquiditySignal, (LiquiditySignal));
        return (true, sig.mmState.expiryAt - block.timestamp);
    }

    function _reenter(
        uint8 k,
        bytes memory /*liquiditySignal*/
    )
        internal
        returns (bool ok, bytes memory data)
    {
        if (k == 6) {
            // Re-enter checkpoint in "no commitment checks" mode to avoid requiring any additional proof validation.
            return
                target.call(abi.encodeWithSelector(VTSOrchestrator.checkpoint.selector, commitId, positionIndex, false));
        }
        return (false, bytes(""));
    }

    // --- unused surface (stubs; never invoked by these tests) ---
    function getVerifier() external pure returns (address) {
        return address(0);
    }

    function mmNonce(address) external pure returns (uint256) {
        return 0;
    }

    function submitAuthNonce(address) external pure returns (uint256) {
        return 0;
    }

    function submitter() external pure returns (address) {
        return address(0xBEEF);
    }

    function setVerifier(address) external {}

    function verifyLiquiditySignalRelayed(
        address,
        uint256,
        bytes memory liquiditySignal,
        uint256,
        uint256,
        bytes memory,
        bool
    ) external view returns (bool, uint256) {
        LiquiditySignal memory sig = abi.decode(liquiditySignal, (LiquiditySignal));
        return (true, sig.mmState.expiryAt - block.timestamp);
    }
}

/**
 * @notice Mutation hardening tests for VTSOrchestrator.
 */
contract VTSOrchestratorMutationHardeningTest is VTSOrchestratorFixture {
    function _etchReentrantSignalManager() internal returns (ReentrantSignalManagerForMutation impl) {
        impl = new ReentrantSignalManagerForMutation(address(vtsOrchestrator));
        vm.etch(address(signalManager), address(impl).code);
    }

    function _s() internal view returns (ReentrantSignalManagerForMutation) {
        return ReentrantSignalManagerForMutation(address(signalManager));
    }

    // Confirms checkpoint is re-entrancy-protected when signal verification runs: with the guard
    // in place the re-entry fails and the outer call succeeds; if the guard is removed the
    // re-entry succeeds and the signal manager reverts, killing the mutant.
    function test_checkpoint_revertsIfNonReentrantRemoved_viaSignalManagerReentry() public {
        // Kills survivor:
        // - VTSOrchestrator.checkpoint(... ) external nonReentrant -> external
        _etchReentrantSignalManager();

        // Create a committed position (commitId + position 0) without arming re-entry.
        (uint256 commitId,,,) = _createCommittedPosition();

        // Arm re-entry on checkpoint: if nonReentrant is removed, the re-entry succeeds and signal manager reverts.
        _s().armCheckpoint(commitId, 0);

        // Trigger signal verification by running checkpoint with backing checks enabled.
        // The signal manager re-enters checkpoint in the simplest mode (withCommitment=false).
        address advancer = liquiditySignal.mmState.advancer;
        vm.prank(advancer);
        vm.recordLogs();
        unlockCaller.run(
            address(vtsOrchestrator), abi.encodeWithSelector(VTSOrchestrator.checkpoint.selector, commitId, 0, true)
        );

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 topic0 = keccak256("Checkpointed(uint256,uint256,(uint8,uint256,uint256,uint256,uint256),bool)");
        bool found = false;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics.length == 0 || entries[i].topics[0] != topic0) continue;
            (
                uint256 loggedCommitId,
                uint256 loggedPositionIndex,
                RFSCheckpoint memory checkpoint,
                bool withCommitment
            ) = abi.decode(entries[i].data, (uint256, uint256, RFSCheckpoint, bool));
            if (loggedCommitId == commitId && loggedPositionIndex == 0 && withCommitment) {
                found = true;
                // Use checkpoint data to ensure the decode is exercised.
                assertTrue(checkpoint.openMask <= 3, "checkpoint data should be present");
                break;
            }
        }
        assertTrue(found, "missing Checkpointed event for commitId/positionIndex");
    }
}

