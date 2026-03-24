// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {LiquidityHub} from "../../src/LiquidityHub.sol";
import {LiquidityCommitmentCertificate} from "../../src/LCC.sol";
import {MockOracleHelper} from "./mocks/MockOracleHelper.sol";
import {MockERC20Transferable} from "./mocks/MockERC20Transferable.sol";
import {Bounds} from "../../src/libraries/Bounds.sol";
import {LCCFactoryLinkedLib} from "../../src/libraries/LCCFactoryLib.sol";
import {LiquidityHubLinkedLib} from "../../src/libraries/LiquidityHubLinkedLib.sol";

/// @notice Micro-harness for HUB-05 (balance-backed reserves) under callback-style flows.
///
/// @dev `LiquidityHub.confirmTake` is intentionally NOT `nonReentrant` and relies on a balance-backed invariant:
///      reserve accounting must never exceed actual Hub underlying balance.
///      This harness forces `confirmTake` to be reachable from within the unwrap call chain:
///      `unwrap` -> `useMarketLiquidity` (factory callback) -> `confirmTake`.
contract LiquidityHubConfirmTakeCallbackEchidnaTest {
    LiquidityHub internal hub;
    LiquidityCommitmentCertificate internal lccNative;

    LiquidityHubConfirmTakeCallback_Holder internal holder;

    // Fuzz-controlled desired reserve increase during callback.
    uint256 internal requestedTake;

    // Track that callback path occurred.
    bool internal callbackSeen;

    // Track that Hub queue settlement path was exercised.
    bool internal hubQueueSeen;

    // Track that this harness attempted to process the Hub's queue explicitly.
    bool internal settlementAttempted;

    // Fuzz-controlled mode bits for how `useMarketLiquidity` behaves.
    //
    // bit0: safe confirmTake first (otherwise unsafe first)
    // bit1: attempt a second "unsafe" confirmTake
    // bit2: attempt a second "safe" confirmTake (slack-limited)
    // bit3: attempt a queue-settling confirmTake (takes up to queue size, slack-limited)
    uint8 internal callbackMode;

    function _deployLinkedLib() internal {
        bytes32 saltLcc = keccak256("echidna.LCCFactoryLinkedLib");
        bytes32 saltLh = keccak256("echidna.LiquidityHubLinkedLib");
        bytes memory initLcc = type(LCCFactoryLinkedLib).creationCode;
        bytes memory initLh = type(LiquidityHubLinkedLib).creationCode;
        address expectedLcc = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), saltLcc, keccak256(initLcc)))))
        );
        address expectedLh = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), saltLh, keccak256(initLh)))))
        );
        address lcc;
        address lhl;
        assembly {
            lcc := create2(0, add(initLcc, 0x20), mload(initLcc), saltLcc)
            lhl := create2(0, add(initLh, 0x20), mload(initLh), saltLh)
        }
        require(lcc != address(0), "LCCFactoryLinkedLib deploy failed");
        require(lhl != address(0), "LiquidityHubLinkedLib deploy failed");
        require(lcc == expectedLcc, "LCCFactoryLinkedLib addr mismatch");
        require(lhl == expectedLh, "LiquidityHubLinkedLib addr mismatch");
    }

    function _initIssuers() internal view returns (address[] memory issuers) {
        issuers = new address[](1);
        issuers[0] = address(this);
    }

    function _createInitNativeMarket(
        bytes memory marketRef,
        bytes32 marketId,
        string memory name,
        address[] memory issuers
    ) internal returns (LiquidityCommitmentCertificate nativeLcc) {
        // Non-native underlying must be a contract because metadata helpers may call `decimals()`.
        MockERC20Transferable other = new MockERC20Transferable();
        (address l0, address l1) = hub.createLCCPair(marketRef, address(0), address(other), name, issuers);
        hub.initialize(l0, l1, marketId, marketRef);
        address underlying0 = hub.getUnderlying(l0);
        nativeLcc = LiquidityCommitmentCertificate(underlying0 == address(0) ? l0 : l1);
    }

    constructor() {
        _deployLinkedLib();

        MockOracleHelper oracleHelper = new MockOracleHelper(address(0xB0B));
        hub = new LiquidityHub(address(oracleHelper), "Ether", "ETH", 18, address(this));

        // Factory + issuer setup.
        hub.setFactory(address(this), true);
        hub.setBoundLevel(address(hub), Bounds.BOUND_EXEMPT);

        address[] memory issuers = _initIssuers();
        lccNative =
            _createInitNativeMarket(abi.encodePacked(address(this), bytes1(0xC0)), bytes32(uint256(12)), "CT", issuers);

        holder = new LiquidityHubConfirmTakeCallback_Holder();

        // Default to a small take request.
        requestedTake = 1;
        callbackMode = 0;
    }

    /// @notice Factory callback used by `LiquidityHubLib.unwrapInternalLogic`.
    /// @dev We simulate a MarketVault->Hub callback by invoking `confirmTake` from within this callback.
    function useMarketLiquidity(address, bytes32, uint256 amount) external returns (uint256 used) {
        if (msg.sender != address(hub)) revert();
        callbackSeen = true;

        // Snapshot balance-backed slack once. Every "safe" call is clamped by slack so the harness does not
        // accidentally fabricate reserves itself (HUB-05 should still catch any protocol bug).
        uint256 reserve = hub.reserveOfUnderlying(address(lccNative));
        uint256 bal = address(hub).balance;
        uint256 slack = bal > reserve ? (bal - reserve) : 0;

        // Derive call ordering/behaviour from mode bits.
        bool safeFirst = (callbackMode & 0x01) != 0;
        bool repeatUnsafe = (callbackMode & 0x02) != 0;
        bool repeatSafe = (callbackMode & 0x04) != 0;
        bool tryQueueSettle = (callbackMode & 0x08) != 0;

        // Define three candidate amounts:
        // - unsafeTake: fuzz-chosen request (may revert)
        // - safeTake: slack-limited by current unwrap's amount
        // - queueTake: slack-limited by Hub's current queue size (if any)
        uint256 unsafeTake = requestedTake;

        uint256 safeTake = amount;
        if (safeTake > slack) safeTake = slack;

        uint256 queueTake = 0;
        uint256 q = hub.settleQueue(address(lccNative), address(hub));
        if (q != 0) {
            hubQueueSeen = true;
            queueTake = q;
            if (queueTake > slack) queueTake = slack;
        }

        // Always use low-level calls so unwrap can proceed regardless of revert.
        if (safeFirst) {
            if (safeTake > 0) {
                (bool okS0,) = address(hub)
                    .call(
                        abi.encodeWithSignature(
                            "confirmTake(address,uint256,bool)", address(lccNative), safeTake, false
                        )
                    );
                okS0; // ignore
            }
            if (unsafeTake > 0) {
                (bool okU0,) = address(hub)
                    .call(
                        abi.encodeWithSignature(
                            "confirmTake(address,uint256,bool)", address(lccNative), unsafeTake, false
                        )
                    );
                okU0; // ignore
            }
        } else {
            if (unsafeTake > 0) {
                (bool okU0,) = address(hub)
                    .call(
                        abi.encodeWithSignature(
                            "confirmTake(address,uint256,bool)", address(lccNative), unsafeTake, false
                        )
                    );
                okU0; // ignore
            }
            if (safeTake > 0) {
                (bool okS0,) = address(hub)
                    .call(
                        abi.encodeWithSignature(
                            "confirmTake(address,uint256,bool)", address(lccNative), safeTake, false
                        )
                    );
                okS0; // ignore
            }
        }

        // Optional stress calls (ordering intentionally variable).
        if (repeatUnsafe && unsafeTake > 0) {
            (bool okU1,) = address(hub)
                .call(
                    abi.encodeWithSignature("confirmTake(address,uint256,bool)", address(lccNative), unsafeTake, false)
                );
            okU1; // ignore
        }
        if (repeatSafe && safeTake > 0) {
            (bool okS1,) = address(hub)
                .call(abi.encodeWithSignature("confirmTake(address,uint256,bool)", address(lccNative), safeTake, false));
            okS1; // ignore
        }
        if (tryQueueSettle && queueTake > 0) {
            (bool okQ,) = address(hub)
                .call(
                    abi.encodeWithSignature("confirmTake(address,uint256,bool)", address(lccNative), queueTake, false)
                );
            okQ; // ignore
        }

        // This harness simulates "no market liquidity actually used for immediate unwrap".
        return 0;
    }

    // -------------------------------------------------------------------------
    // Actions
    // -------------------------------------------------------------------------

    /// @notice Fund the Hub with raw ETH (increases actual balance but not reserves).
    // forge-lint: disable-next-line(mixed-case-function)
    function action_donate_eth_to_hub() external payable {
        if (msg.value == 0) return;
        (bool ok,) = address(hub).call{value: msg.value}("");
        ok;
    }

    /// @notice Set the requested `confirmTake` amount used inside the callback.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_set_requested_take(uint256 amt) external {
        requestedTake = amt % 1e24;
    }

    /// @notice Set callback behaviour knobs (bitfield).
    // forge-lint: disable-next-line(mixed-case-function)
    function action_set_callback_mode(uint8 mode) external {
        callbackMode = mode;
    }

    /// @notice Seed Hub reserves via a native wrap (increases both reserve and hub balance).
    /// @dev Useful to make `processSettlementFor` and "safe" confirmTake paths more reachable.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_wrap_native_to_reserve() external payable {
        if (msg.value == 0) return;
        uint256 v = msg.value;
        if (v > 10 ether) v = 10 ether;
        (bool ok,) =
            address(hub).call{value: v}(abi.encodeWithSignature("wrap(address,uint256)", address(lccNative), v));
        ok; // ignore
    }

    /// @notice Mint market-derived LCC to the holder so it can call unwrap (and trigger the callback path).
    // forge-lint: disable-next-line(mixed-case-function)
    function action_issue_to_holder(uint256 amount) external {
        uint256 amt = (amount % 1e24) + 1;
        hub.issue(address(lccNative), address(holder), amt);
    }

    /// @notice Create a queued settlement claim for the Hub itself.
    /// @dev This is the scenario `confirmTake` is designed to service ("best-effort settle Hub queue").
    ///      We do it by unwrapping market-derived LCC while market liquidity is 0, queueing the shortfall to `address(hub)`.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_seed_hub_queue(uint256 amount) external {
        uint256 amt = (amount % 1e18) + 1; // keep small-ish

        // Ensure this harness has market-derived balance to unwrap.
        hub.issue(address(lccNative), address(this), amt);

        // Unwrap and queue shortfall to the Hub. Use low-level call so reverts don't abort the fuzz sequence.
        (bool ok,) = address(hub)
            .call(
                abi.encodeWithSignature(
                    "unwrapTo(address,address,address,uint256)", address(lccNative), address(this), address(hub), amt
                )
            );
        ok; // ignore
    }

    /// @notice More adversarial seeding: create a large Hub-owned queue by repeated unwrap attempts.
    /// @dev Keeps loop bounds constant to remain Echidna-friendly.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_seed_hub_queue_large(uint256 amount) external {
        // Bound per-iteration size and number of iterations.
        uint256 base = (amount % 1e20) + 1; // up to 1e20
        uint256 iters = ((amount >> 8) % 3) + 1; // 1..3

        for (uint256 i = 0; i < iters; i++) {
            // Mint market-derived to this harness then unwrap to queue to the Hub.
            uint256 a = base + i;
            hub.issue(address(lccNative), address(this), a);
            (bool ok,) = address(hub)
                .call(
                    abi.encodeWithSignature(
                        "unwrapTo(address,address,address,uint256)", address(lccNative), address(this), address(hub), a
                    )
                );
            ok; // ignore
        }

        if (hub.settleQueue(address(lccNative), address(hub)) != 0) {
            hubQueueSeen = true;
        }
    }

    /// @notice Attempt to process Hub settlement explicitly (clears Hub-owned queue if reserves exist).
    // forge-lint: disable-next-line(mixed-case-function)
    function action_process_hub_settlement(uint256 maxAmount) external {
        settlementAttempted = true;
        uint256 amt = (maxAmount % 1e24) + 1;
        (bool ok,) = address(hub)
            .call(
                abi.encodeWithSignature(
                    "processSettlementFor(address,address,uint256)", address(lccNative), address(hub), amt
                )
            );
        ok; // ignore
    }

    /// @notice Trigger unwrap from the holder, forcing the `useMarketLiquidity` callback path.
    /// @dev Uses low-level call so a revert doesn't abort the sequence (we care about post-state safety).
    // forge-lint: disable-next-line(mixed-case-function)
    function action_holder_unwrap(uint256 amount) external {
        uint256 bal = lccNative.balanceOf(address(holder));
        if (bal == 0) return;
        uint256 amt = (amount % bal) + 1;
        holder.unwrapToQueue(address(hub), address(lccNative), amt);
    }

    // -------------------------------------------------------------------------
    // Properties
    // -------------------------------------------------------------------------

    /// @dev HUB-05: reserve accounting must be <= actual underlying balance held by the hub.
    ///      For native underlying, this is `reserve <= address(hub).balance`.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_hub05_reserve_never_exceeds_hub_balance() external view returns (bool) {
        uint256 reserve = hub.reserveOfUnderlying(address(lccNative));
        return reserve <= address(hub).balance;
    }

    // Optional informational property (non-failing): callback should be reachable in this harness.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_hub05_callback_seen_or_not() external view returns (bool) {
        callbackSeen; // ignored; keep as a debuggable state hook
        return true;
    }

    // Non-failing reachability hook.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_hub05_hub_queue_seen_or_not() external view returns (bool) {
        hubQueueSeen;
        return true;
    }

    // Non-failing reachability hook.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_hub05_settlement_attempted_or_not() external view returns (bool) {
        settlementAttempted;
        return true;
    }
}

contract LiquidityHubConfirmTakeCallback_Holder {
    function unwrapToQueue(address hub, address lcc, uint256 amount) external returns (bool ok) {
        (ok,) = hub.call(
            abi.encodeWithSignature(
                "unwrapTo(address,address,address,uint256)", lcc, address(this), address(this), amount
            )
        );
    }
}

