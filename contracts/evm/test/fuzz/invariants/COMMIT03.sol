// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {VTSCommitLibHarness} from "../../libraries/harnesses/VTSCommitLibHarness.sol";
import {IVRLSignalManager} from "../../../src/interfaces/IVRLSignalManager.sol";
import {IOracleHelper} from "../../../src/interfaces/IOracleHelper.sol";
import {LiquiditySignal} from "../../../src/types/Commit.sol";
import {MarketMaker} from "../../../src/libraries/MarketMaker.sol";

/// @dev Minimal mock that always verifies and returns leaf TTL — signal verification
///      is not the concern of this harness; advancer binding is.
contract COMMIT03SignalManager is IVRLSignalManager {
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
        return address(0);
    }
    function setVerifier(address) external {}

    function verifyLiquiditySignal(address, bytes memory liquiditySignal, bool) external view returns (bool, uint256) {
        LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
        return (true, signal.mmState.expiryAt - block.timestamp);
    }

    function verifyLiquiditySignalRelayed(
        address,
        uint256,
        bytes memory liquiditySignal,
        uint256,
        uint256,
        bytes memory,
        bool
    ) external view returns (bool, uint256) {
        LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
        return (true, signal.mmState.expiryAt - block.timestamp);
    }
}

/// @dev Minimal oracle so commit/renew admission (`getTotalValue`) succeeds for empty reserve lists in this harness.
contract COMMIT03Oracle is IOracleHelper {
    function oracle() external pure returns (address) {
        return address(0);
    }

    function tickerHashToAsset(bytes32) external pure returns (address) {
        return address(0);
    }

    function registerTicker(string calldata, address) external pure {}

    function getAssetByTicker(string calldata) external pure returns (address) {
        return address(0x1);
    }

    function getPriceByTicker(string calldata) external pure returns (uint256) {
        return 1e18;
    }

    function validateMarketOracles(address, address) external pure {}

    function getTotalValue(string[] memory, uint256[] memory) external pure returns (uint256) {
        return 0;
    }

    function getPriceForLcc(address) external pure returns (uint256) {
        return 1e18;
    }

    function getPricesForLccPair(address, address) external pure returns (uint256, uint256) {
        return (1e18, 1e18);
    }
}

/// @dev Actor contract so we can call `renewSignal` from a specific `msg.sender`.
contract COMMIT03Actor {
    function tryRenewSignal(
        VTSCommitLibHarness harness,
        IVRLSignalManager sigMgr,
        IOracleHelper oracle_,
        uint256 commitId,
        bytes memory sig
    ) external returns (bool) {
        (bool ok,) = address(harness)
            .call(
                abi.encodeWithSignature(
                    "renewSignal(address,address,uint256,bytes)", address(sigMgr), address(oracle_), commitId, sig
                )
            );
        return ok;
    }
}

/// @notice fuzz harness for COMMIT-03: "Advancer" binding for checkpoint-with-commitment.
/// @dev Statement:
///   - The new signal's owner must match the stored commit owner.
///   - The sender must equal mmState.advancer.
///   - These are enforced by VTSCommitLib._renewSignalInternal which reverts Errors.InvalidSender().
///
/// Properties tested:
///   1. Valid renewal (correct owner + sender == advancer) succeeds
///   2. Owner-hijack renewal (different owner in signal) always reverts
///   3. Non-advancer renewal (sender != advancer) always reverts
///   4. Advancer can be rotated via valid renewal and subsequent renewals respect the new advancer
contract COMMIT03 {
    VTSCommitLibHarness internal harness;
    COMMIT03SignalManager internal sigMgr;
    COMMIT03Oracle internal admissionOracle;

    address internal constant MM_OWNER = address(0xAA);
    address internal constant ADVANCER_A = address(0xBB);
    address internal constant ADVANCER_B = address(0xCC);
    address internal constant HIJACKER = address(0xDD);
    address internal constant RANDOM_SENDER = address(0xEE);

    COMMIT03Actor internal advancerActorA;
    COMMIT03Actor internal advancerActorB;
    COMMIT03Actor internal hijackerActor;
    COMMIT03Actor internal randomActor;

    uint256 internal commitId;
    address internal currentAdvancer;

    // Action/result: valid renewal succeeds.
    bool internal checkedValidRenewal;
    bool internal lastValidRenewalOk;

    // Action/result: owner-hijack reverts.
    bool internal checkedOwnerHijack;
    bool internal lastOwnerHijackOk;

    // Action/result: non-advancer reverts.
    bool internal checkedNonAdvancer;
    bool internal lastNonAdvancerOk;

    // Action/result: advancer rotation works.
    bool internal checkedRotation;
    bool internal lastRotationOk;

    constructor() {
        harness = new VTSCommitLibHarness();
        sigMgr = new COMMIT03SignalManager();
        admissionOracle = new COMMIT03Oracle();

        // Deploy actor contracts at specific addresses via CREATE to act as different senders.
        advancerActorA = new COMMIT03Actor();
        advancerActorB = new COMMIT03Actor();
        hijackerActor = new COMMIT03Actor();
        randomActor = new COMMIT03Actor();

        // Create initial commit: owner = MM_OWNER, advancer = address(advancerActorA).
        // The harness's commitSignal uses msg.sender for VRL validation but the mock always passes.
        // The commit stores mmState.owner and mmState.advancer from the signal.
        commitId = harness.commitSignal(
            IVRLSignalManager(address(sigMgr)),
            address(advancerActorA),
            IOracleHelper(address(admissionOracle)),
            _makeSignal(MM_OWNER, address(advancerActorA))
        );
        currentAdvancer = address(advancerActorA);

        _seedAll();
    }

    function _seedAll() internal {
        // Seed valid renewal: advancerActorA renews with correct owner.
        bool ok = advancerActorA.tryRenewSignal(
            harness,
            IVRLSignalManager(address(sigMgr)),
            IOracleHelper(address(admissionOracle)),
            commitId,
            _makeSignal(MM_OWNER, address(advancerActorA))
        );
        checkedValidRenewal = true;
        lastValidRenewalOk = ok;

        // Seed owner-hijack: advancerActorA tries to renew with HIJACKER as owner.
        ok = advancerActorA.tryRenewSignal(
            harness,
            IVRLSignalManager(address(sigMgr)),
            IOracleHelper(address(admissionOracle)),
            commitId,
            _makeSignal(HIJACKER, address(advancerActorA))
        );
        checkedOwnerHijack = true;
        lastOwnerHijackOk = !ok;

        // Seed non-advancer: randomActor tries to renew but signal says advancer = advancerActorA.
        // Since sender (randomActor) != signal.advancer (advancerActorA), this must revert.
        ok = randomActor.tryRenewSignal(
            harness,
            IVRLSignalManager(address(sigMgr)),
            IOracleHelper(address(admissionOracle)),
            commitId,
            _makeSignal(MM_OWNER, address(advancerActorA))
        );
        checkedNonAdvancer = true;
        lastNonAdvancerOk = !ok;

        _rotateAdvancerAndCheck();
    }

    // ================================================================
    // Actions — valid renewal
    // ================================================================

    /// @dev Valid renewal from current advancer with correct owner must succeed.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_commit_03_valid_renewal() external {
        COMMIT03Actor currentActor = _actorForAdvancer();
        bool ok = currentActor.tryRenewSignal(
            harness,
            IVRLSignalManager(address(sigMgr)),
            IOracleHelper(address(admissionOracle)),
            commitId,
            _makeSignal(MM_OWNER, currentAdvancer)
        );
        checkedValidRenewal = true;
        lastValidRenewalOk = ok;
    }

    // ================================================================
    // Actions — owner-hijack (must revert)
    // ================================================================

    /// @dev Renewal with a different owner in the signal must revert.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_commit_03_owner_hijack() external {
        COMMIT03Actor currentActor = _actorForAdvancer();
        bool ok = currentActor.tryRenewSignal(
            harness,
            IVRLSignalManager(address(sigMgr)),
            IOracleHelper(address(admissionOracle)),
            commitId,
            _makeSignal(HIJACKER, currentAdvancer)
        );
        checkedOwnerHijack = true;
        lastOwnerHijackOk = !ok;
    }

    // ================================================================
    // Actions — non-advancer sender (must revert)
    // ================================================================

    /// @dev Renewal from a sender that does not match signal.advancer must revert.
    ///      Here randomActor sends but the signal says advancer = currentAdvancer.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_commit_03_non_advancer_sender() external {
        bool ok = randomActor.tryRenewSignal(
            harness,
            IVRLSignalManager(address(sigMgr)),
            IOracleHelper(address(admissionOracle)),
            commitId,
            _makeSignal(MM_OWNER, currentAdvancer)
        );
        checkedNonAdvancer = true;
        lastNonAdvancerOk = !ok;
    }

    /// @dev hijackerActor sends but signal says advancer = currentAdvancer.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_commit_03_another_non_advancer() external {
        bool ok = hijackerActor.tryRenewSignal(
            harness,
            IVRLSignalManager(address(sigMgr)),
            IOracleHelper(address(admissionOracle)),
            commitId,
            _makeSignal(MM_OWNER, currentAdvancer)
        );
        checkedNonAdvancer = true;
        lastNonAdvancerOk = !ok;
    }

    // ================================================================
    // Actions — advancer rotation
    // ================================================================

    /// @dev The current advancer rotates to a new advancer. The new advancer
    ///      must then be the only one who can renew.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_commit_03_rotate_advancer() external {
        _rotateAdvancerAndCheck();
    }

    function _rotateAdvancerAndCheck() internal {
        address newAdvancer =
            currentAdvancer == address(advancerActorA) ? address(advancerActorB) : address(advancerActorA);

        COMMIT03Actor oldActor = _actorForAdvancer();
        COMMIT03Actor newActor = newAdvancer == address(advancerActorA) ? advancerActorA : advancerActorB;
        checkedRotation = true;
        bool ok = newActor.tryRenewSignal(
            harness,
            IVRLSignalManager(address(sigMgr)),
            IOracleHelper(address(admissionOracle)),
            commitId,
            _makeSignal(MM_OWNER, newAdvancer)
        );
        if (!ok) {
            lastRotationOk = false;
            return;
        }

        currentAdvancer = newAdvancer;

        // After rotation, the OLD advancer must be rejected.
        bool oldOk = oldActor.tryRenewSignal(
            harness,
            IVRLSignalManager(address(sigMgr)),
            IOracleHelper(address(admissionOracle)),
            commitId,
            _makeSignal(MM_OWNER, currentAdvancer)
        );

        // New advancer must succeed.
        bool newOk = newActor.tryRenewSignal(
            harness,
            IVRLSignalManager(address(sigMgr)),
            IOracleHelper(address(admissionOracle)),
            commitId,
            _makeSignal(MM_OWNER, currentAdvancer)
        );

        lastRotationOk = !oldOk && newOk;
    }

    // ================================================================
    // Properties
    // ================================================================

    /// @dev Valid renewal (correct owner + sender == advancer) must always succeed.
    // forge-lint: disable-next-line(mixed-case-function)
    function fuzz_commit_03_valid_renewal_succeeds() external view returns (bool) {
        return !checkedValidRenewal || lastValidRenewalOk;
    }

    /// @dev Renewal with changed owner must always revert.
    // forge-lint: disable-next-line(mixed-case-function)
    function fuzz_commit_03_owner_hijack_reverts() external view returns (bool) {
        return !checkedOwnerHijack || lastOwnerHijackOk;
    }

    /// @dev Renewal from non-advancer sender must always revert.
    // forge-lint: disable-next-line(mixed-case-function)
    function fuzz_commit_03_non_advancer_reverts() external view returns (bool) {
        return !checkedNonAdvancer || lastNonAdvancerOk;
    }

    /// @dev After advancer rotation, old advancer is rejected and new advancer succeeds.
    // forge-lint: disable-next-line(mixed-case-function)
    function fuzz_commit_03_rotation_respects_new_advancer() external view returns (bool) {
        return !checkedRotation || lastRotationOk;
    }

    // ================================================================
    // Helpers
    // ================================================================

    function _actorForAdvancer() internal view returns (COMMIT03Actor) {
        if (currentAdvancer == address(advancerActorA)) return advancerActorA;
        return advancerActorB;
    }

    function _makeSignal(address owner, address adv) internal pure returns (bytes memory) {
        MarketMaker.Reserve[] memory reserves = new MarketMaker.Reserve[](0);
        MarketMaker.State memory mmState = MarketMaker.State({
            owner: owner,
            reserves: reserves,
            sourceState: "",
            prover: "",
            nonce: "",
            advancer: adv,
            expiryAt: type(uint256).max
        });
        LiquiditySignal memory sig = LiquiditySignal({
            nonce: 1,
            rootHash: bytes32(0),
            rootHashSignature: "",
            merkleProof: new bytes32[](0),
            mmState: mmState,
            mmSignature: ""
        });
        return abi.encode(sig);
    }
}
