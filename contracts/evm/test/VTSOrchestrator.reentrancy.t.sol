// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {VTSOrchestratorFixture} from "./base/VTSOrchestratorFixture.sol";
import {VTSOrchestrator} from "../src/VTSOrchestrator.sol";
import {LiquiditySignal} from "../src/types/Commit.sol";
import {IMarketVault} from "../src/interfaces/IMarketVault.sol";
import {IOracleHelper} from "../src/interfaces/IOracleHelper.sol";
import {IVRLSettlementObserver} from "../src/interfaces/IVRLSettlementObserver.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/**
 * @dev Malicious signal-manager implementation used via `vm.etch` onto the deployed `signalManager` address.
 *
 * Critical constraint: storing the *entire* reentry calldata blob in storage is extremely gas heavy, since the
 * liquidity signal bytes are large. Instead we store a small "mode" + a few scalar params and reconstruct the
 * reentrant call inside `verifyLiquiditySignal(...)`.
 *
 * Reentrancy premise:
 * - `VTSCommitLib.commitSignal` / `renewSignal` / `checkpointWithCommitment` all call
 *     `signalManager.verifyLiquiditySignal(address,bytes,bool)`
 * - We re-enter various `VTSOrchestrator` entrypoints during that external call.
 * - If the target entrypoint’s `nonReentrant` is removed by mutation, the re-entry succeeds and we revert with
 *   `Reentered()` to kill the mutant deterministically.
 */
contract ReentrantSignalManager {
    error Reentered();

    address internal immutable target;

    // 0 = none, 1 = commitSignal, 2 = extendGracePeriod, 3 = onMMSettle, 4 = onSeize, 5 = renewSignal, 6 = checkpoint
    uint8 internal kind;

    uint256 internal commitId;
    uint256 internal positionIndex;

    // extendGracePeriod params
    PoolKey internal poolKey;
    uint8 internal settlementTokenIndex;
    uint32 internal verifierIndex;

    // onMMSettle params
    address internal marketVault;
    Currency internal lccCurrency0;
    Currency internal lccCurrency1;

    constructor(address target_) {
        target = target_;
    }

    function armCommitSignal() external {
        kind = 1;
    }

    function armExtendGracePeriod(
        PoolKey calldata key,
        uint256 _commitId,
        uint256 _positionIndex,
        uint8 _settlementTokenIndex,
        uint32 _verifierIndex
    ) external {
        kind = 2;
        poolKey = key;
        commitId = _commitId;
        positionIndex = _positionIndex;
        settlementTokenIndex = _settlementTokenIndex;
        verifierIndex = _verifierIndex;
    }

    function armOnMMSettle(PoolKey calldata key, address vault, uint256 _commitId, uint256 _positionIndex) external {
        kind = 3;
        poolKey = key;
        marketVault = vault;
        commitId = _commitId;
        positionIndex = _positionIndex;
    }

    function armOnSeize(uint256 _commitId, uint256 _positionIndex) external {
        kind = 4;
        commitId = _commitId;
        positionIndex = _positionIndex;
    }

    function armRenewSignal(uint256 _commitId) external {
        kind = 5;
        commitId = _commitId;
    }

    function armCheckpoint(uint256 _commitId, uint256 _positionIndex) external {
        kind = 6;
        commitId = _commitId;
        positionIndex = _positionIndex;
    }

    function armOnMMSettleWithLccCurrencies(
        PoolKey calldata key,
        address vault,
        uint256 _commitId,
        uint256 _positionIndex,
        Currency _lccCurrency0,
        Currency _lccCurrency1
    ) external {
        kind = 3;
        poolKey = key;
        marketVault = vault;
        commitId = _commitId;
        positionIndex = _positionIndex;
        lccCurrency0 = _lccCurrency0;
        lccCurrency1 = _lccCurrency1;
    }

    // sender-bound bytes overload (reverting version) used by VTSCommitLib
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
        return (true, 3600);
    }

    function _reenter(uint8 k, bytes memory liquiditySignal) internal returns (bool ok, bytes memory data) {
        if (k == 1) {
            LiquiditySignal memory sig = abi.decode(liquiditySignal, (LiquiditySignal));
            return target.call(
                abi.encodeWithSelector(VTSOrchestrator.commitSignal.selector, sig.mmState.owner, liquiditySignal)
            );
        }
        if (k == 2) {
            return target.call(
                abi.encodeWithSelector(
                    VTSOrchestrator.extendGracePeriod.selector,
                    poolKey,
                    commitId,
                    positionIndex,
                    settlementTokenIndex,
                    verifierIndex,
                    bytes("")
                )
            );
        }
        if (k == 3) {
            BalanceDelta amountDelta = toBalanceDelta(0, 0);
            return target.call(
                abi.encodeWithSelector(
                    VTSOrchestrator.onMMSettle.selector,
                    IMarketVault(marketVault),
                    commitId,
                    positionIndex,
                    lccCurrency0,
                    lccCurrency1,
                    amountDelta,
                    false
                )
            );
        }
        if (k == 4) {
            return target.call(abi.encodeWithSelector(VTSOrchestrator.onSeize.selector, commitId, positionIndex));
        }
        if (k == 5) {
            // Re-enter renewSignal itself.
            LiquiditySignal memory sig = abi.decode(liquiditySignal, (LiquiditySignal));
            return target.call(
                abi.encodeWithSelector(
                    bytes4(keccak256("renewSignal(address,uint256,bytes)")),
                    sig.mmState.advancer,
                    commitId,
                    liquiditySignal
                )
            );
        }
        if (k == 6) {
            // Re-enter checkpoint in "no commitment checks" mode to avoid requiring any additional proof validation.
            // Note: checkpoint's `sender` argument is not coupled to msg.sender, and is unused when withCommitment=false.
            return
                target.call(abi.encodeWithSelector(VTSOrchestrator.checkpoint.selector, commitId, positionIndex, false));
        }
        return (false, bytes(""));
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
    function setTrustedCaller(address, bool) external {}
}

contract VTSOrchestratorReentrancyTest is VTSOrchestratorFixture {
    function _etchReentrantSignalManager() internal returns (ReentrantSignalManager impl) {
        impl = new ReentrantSignalManager(address(vtsOrchestrator));
        vm.etch(address(signalManager), address(impl).code);
    }

    function _s() internal view returns (ReentrantSignalManager) {
        return ReentrantSignalManager(address(signalManager));
    }

    function test_commitSignal_revertsIfNonReentrantRemoved_viaSignalManagerReentry() public {
        _etchReentrantSignalManager();
        _s().armCommitSignal();

        bytes memory signalBytes = abi.encode(liquiditySignal);

        // Must run inside unlock context for commitSignal (onlyIfPoolManagerUnlocked).
        bytes memory out = unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(VTSOrchestrator.commitSignal.selector, liquiditySignal.mmState.owner, signalBytes)
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
                address(vtsOrchestrator),
                abi.encodeWithSelector(
                    VTSOrchestrator.commitSignal.selector, liquiditySignal.mmState.owner, signalBytes
                )
            ),
            (uint256)
        );
        assertEq(commitId, 1, "expected first commitId");

        // Target the `renewSignal` entrypoint itself: if its `nonReentrant` is removed, the re-entry succeeds and
        // the signal manager reverts with `Reentered()` to kill the mutant.
        _s().armRenewSignal(commitId);

        // Renew should succeed under correct nonReentrant behaviour.
        unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(
                bytes4(keccak256("renewSignal(address,uint256,bytes)")),
                liquiditySignal.mmState.advancer,
                commitId,
                signalBytes
            )
        );
    }

    function test_checkpoint_withCommitment_revertsIfNonReentrantRemoved_viaSignalManagerReentry() public {
        _etchReentrantSignalManager();

        // Create a committed position (commitId + position 0) without arming re-entry.
        (uint256 commitId,,,) = _createCommittedPosition();

        // withCommitment=true triggers backing checks inside checkpointWithCommitment.
        address advancer = liquiditySignal.mmState.advancer;

        // Re-enter `checkpoint` itself in the simplest mode (withCommitment=false) to deterministically kill
        // the `checkpoint` nonReentrant removal mutant without relying on any other entrypoint behaviour.
        _s().armCheckpoint(commitId, 0);

        vm.prank(advancer);
        unlockCaller.run(
            address(vtsOrchestrator), abi.encodeWithSelector(VTSOrchestrator.checkpoint.selector, commitId, 0, true)
        );
    }

    function test_extendGracePeriod_revertsIfNonReentrantRemoved_viaSignalManagerReentry() public {
        _etchReentrantSignalManager();

        (uint256 commitId,,,) = _createCommittedPosition();

        // Settlement proof verification is view; just force it to succeed.
        vm.mockCall(
            address(settlementObserver),
            abi.encodeWithSelector(
                IVRLSettlementObserver.verifySettlementProof.selector, corePoolKey, uint8(0), uint32(0), bytes(""), true
            ),
            abi.encode(true)
        );

        _s().armExtendGracePeriod(corePoolKey, commitId, 0, 0, 0);

        bytes memory signalBytes = abi.encode(liquiditySignal);
        unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(
                bytes4(keccak256("renewSignal(address,uint256,bytes)")),
                liquiditySignal.mmState.advancer,
                commitId,
                signalBytes
            )
        );
    }

    function test_onMMSettle_revertsIfNonReentrantRemoved_viaSignalManagerReentry() public {
        _etchReentrantSignalManager();

        (uint256 commitId,,,) = _createCommittedPosition();

        // IMPORTANT: onMMSettle expects LCC currencies (not underlying pool currencies).
        // If we pass underlying currencies here, the re-entrant call can fail for unrelated reasons and the mutant survives.
        _s().armOnMMSettleWithLccCurrencies(corePoolKey, address(proxyHook), commitId, 0, lccCurrency0, lccCurrency1);

        bytes memory signalBytes = abi.encode(liquiditySignal);
        unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(
                bytes4(keccak256("renewSignal(address,uint256,bytes)")),
                liquiditySignal.mmState.advancer,
                commitId,
                signalBytes
            )
        );
    }

    function test_onSeize_revertsIfNonReentrantRemoved_viaSignalManagerReentry() public {
        _etchReentrantSignalManager();

        (uint256 commitId,,,) = _createCommittedPosition();

        // Make the position immediately seizable by creating a commitment deficit.
        bytes memory signalBytes = abi.encode(liquiditySignal);
        vm.mockCall(
            address(oracleHelper),
            abi.encodeWithSelector(IOracleHelper.getPricesForLccPair.selector),
            abi.encode(uint256(1e18), uint256(1e18))
        );
        vm.mockCall(
            address(oracleHelper), abi.encodeWithSelector(IOracleHelper.getTotalValue.selector), abi.encode(uint256(0))
        );

        address advancer = liquiditySignal.mmState.advancer;
        vm.prank(advancer);
        unlockCaller.run(
            address(vtsOrchestrator), abi.encodeWithSelector(VTSOrchestrator.checkpoint.selector, commitId, 0, true)
        );

        _s().armOnSeize(commitId, 0);

        unlockCaller.run(
            address(vtsOrchestrator),
            abi.encodeWithSelector(
                bytes4(keccak256("renewSignal(address,uint256,bytes)")),
                liquiditySignal.mmState.advancer,
                commitId,
                signalBytes
            )
        );
    }
}

