// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {VTSOrchestratorFixture} from "./base/VTSOrchestratorFixture.sol";
import {VTSOrchestrator} from "../src/VTSOrchestrator.sol";
import {LiquiditySignal} from "../src/types/Commit.sol";

/**
 * @dev Malicious signal-manager implementation used via `vm.etch` onto the deployed `signalManager` address.
 *
 * Reentrancy premise:
 * - `VTSCommitLib.commitSignal` and `VTSCommitLib.renewSignal` both make an external call to:
 *     `signalManager.verifyLiquiditySignal(bytes,bool)`
 * - `VTSCommitLib.checkpointWithCommitment` also makes that external call.
 *
 * We attempt to re-enter `VTSOrchestrator.commitSignal` during that external call. If the outer entrypoint’s
 * `nonReentrant` is removed by mutation, the re-entry succeeds and we revert with `Reentered()` to kill the mutant.
 */
contract ReentrantSignalManager {
    error Reentered();

    address internal immutable target;
    bool internal armed;

    constructor(address target_) {
        target = target_;
    }

    function arm() external {
        armed = true;
    }

    // bytes overload (reverting version) used by VTSCommitLib
    function verifyLiquiditySignal(
        bytes memory liquiditySignal,
        bool /*revertOnInvalid*/
    )
        external
        returns (bool, uint256)
    {
        if (armed) {
            armed = false;
            (bool ok,) = target.call(abi.encodeWithSelector(VTSOrchestrator.commitSignal.selector, liquiditySignal));
            if (ok) revert Reentered();
        }
        return (true, 3600);
    }

    // --- Unused IVRLSignalManager surface (stubs; never invoked by these tests) ---
    function getVerifier() external pure returns (address) {
        return address(0);
    }

    function signalExpiryInSeconds() external pure returns (uint256) {
        return 3600;
    }

    function mmNonce(address) external pure returns (uint256) {
        return 0;
    }

    function setVerifier(address) external {}
    function setSignalExpiryInSeconds(uint256) external {}

    function verifyLiquiditySignal(bytes memory) external pure returns (bool, uint256) {
        return (true, 3600);
    }

    function verifyLiquiditySignal(LiquiditySignal memory) external pure returns (bool, uint256) {
        return (true, 3600);
    }
}

contract VTSOrchestratorReentrancyTest is VTSOrchestratorFixture {
    function _etchReentrantSignalManager() internal returns (ReentrantSignalManager impl) {
        impl = new ReentrantSignalManager(address(vtsOrchestrator));
        vm.etch(address(signalManager), address(impl).code);
    }

    function _armEtchedSignalManager() internal {
        (bool ok,) = address(signalManager).call(abi.encodeWithSignature("arm()"));
        require(ok, "arm() failed");
    }

    function test_commitSignal_revertsIfNonReentrantRemoved_viaSignalManagerReentry() public {
        _etchReentrantSignalManager();
        _armEtchedSignalManager();

        bytes memory signalBytes = abi.encode(liquiditySignal);

        // Must run inside unlock context for commitSignal (onlyIfPoolManagerUnlocked).
        bytes memory out = unlockCaller.run(
            address(vtsOrchestrator), abi.encodeWithSelector(VTSOrchestrator.commitSignal.selector, signalBytes)
        );
        uint256 commitId = abi.decode(out, (uint256));
        assertEq(commitId, 1, "outer commitSignal should still succeed and return first commitId");
    }

    function test_renewSignal_revertsIfNonReentrantRemoved_viaSignalManagerReentry() public {
        _etchReentrantSignalManager();

        bytes memory signalBytes = abi.encode(liquiditySignal);

        // Create a commit without arming re-entry.
        uint256 commitId = abi.decode(
            unlockCaller.run(
                address(vtsOrchestrator), abi.encodeWithSelector(VTSOrchestrator.commitSignal.selector, signalBytes)
            ),
            (uint256)
        );
        assertEq(commitId, 1, "expected first commitId");

        _armEtchedSignalManager();

        // Renew should succeed under correct nonReentrant behaviour.
        unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(VTSOrchestrator.renewSignal.selector, commitId, signalBytes)
        );
    }

    function test_checkpoint_withCommitment_revertsIfNonReentrantRemoved_viaSignalManagerReentry() public {
        _etchReentrantSignalManager();

        // Create a committed position (commitId + position 0) without arming re-entry.
        (uint256 commitId,,,) = _createCommittedPosition();

        _armEtchedSignalManager();

        // withCommitment=true triggers signal verification (external call) inside checkpointWithCommitment.
        address advancer = liquiditySignal.mmState.advancer;
        bytes memory signalBytes = abi.encode(liquiditySignal);

        vm.prank(advancer);
        unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(VTSOrchestrator.checkpoint.selector, advancer, commitId, 0, signalBytes, true)
        );
    }
}

