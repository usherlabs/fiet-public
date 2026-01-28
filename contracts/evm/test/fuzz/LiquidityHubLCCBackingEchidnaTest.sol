// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {LiquidityHub} from "../../src/LiquidityHub.sol";
import {LiquidityCommitmentCertificate} from "../../src/LCC.sol";
import {MockOracleHelper} from "./mocks/MockOracleHelper.sol";
import {MockERC20Metadata} from "./mocks/MockERC20Metadata.sol";
import {Bounds} from "../../src/libraries/Bounds.sol";
import {LCCFactoryLinkedLib} from "../../src/libraries/LCCFactoryLib.sol";

/// @notice Echidna harness for LiquidityHub/LCC backing invariants (Domains A/B + wrapWith + transfer semantics).
///
/// Increment 0 (Domain A only):
/// - Create a real `LiquidityHub` + real LCC pair.
/// - Identify the native-asset LCC (underlying == address(0)).
/// - Fuzz `LiquidityHub.wrap(lccNative, msg.value)` and check:
///   - directSupply(lccNative) == reserveOfUnderlying(lccNative)
///   - lccNative.totalSupply() == directSupply(lccNative)
/// - Sanity check "no free mint": direct calls to `LCC.mint` from non-hub must fail.
///
/// Next increments:
/// - Add Domain B: `LiquidityHub.issue` (issuer-gated) and bucket constraints.
/// - Add wrapWith conversion and conservation checks.
contract LiquidityHubLCCBackingEchidnaTest {
    // Must match `--solc-args --libraries ...` in `scripts/echidna.sh`.
    address internal constant LCC_FACTORY_LINKED_LIB = 0xE2B5401952dC4c9059b7eDE3a1742bF2BC17EBAd;

    LiquidityHub internal hub;
    LiquidityCommitmentCertificate internal lccNative;
    LiquidityCommitmentCertificate internal lccNative2;
    address internal lccUninitialised;

    bool internal lastDirectMintOk;
    bool internal lastDirectBurnOk;
    bool internal lastNonIssuerIssueOk;
    bool internal lastUninitialisedLccIssueOk;
    bool internal lastInvalidLccIssueOk;

    LiquidityHubLCCBacking_NonIssuer internal nonIssuer;

    // HUB-A-DELTA-01 tracking: record whether the last attempted native wrap satisfied exact 1:1 deltas.
    bool internal wrapChecked;
    bool internal lastWrapOk;

    // HUB-B-DELTA-01 tracking: record whether the last attempted issuer mint satisfied exact Domain-B deltas.
    bool internal issueChecked;
    bool internal lastIssueOk;

    // HUB-B-QUEUE-01 tracking: record whether the last attempted unwrap-with-shortfall correctly queued.
    bool internal queueChecked;
    bool internal lastQueueOk;

    // WRAPWITH-CONS-01 tracking: record whether the last attempted wrapWith conserved supply/reserves/queue semantics.
    bool internal wrapWithChecked;
    bool internal lastWrapWithOk;

    // WRAPWITH-QUEUE-01 tracking: record whether wrapWith behaves correctly when a pre-existing Hub queue exists
    // for the backing LCC (lazy-claim netting + no double-burn during settlement).
    bool internal wrapWithQueueChecked;
    bool internal lastWrapWithQueueOk;

    // LCC-02 tracking: record whether non-protocol -> protocol transfers annul queued settlement before bucket decrement.
    bool internal lcc02Checked;
    bool internal lastLcc02Ok;

    // HUB-05: reserve accounting must never exceed actual Hub holdings.
    // (We don't need tracking booleans here; we assert it as a global always-on property.)

    struct Snapshot {
        uint256 totalSupply;
        uint256 directSupply;
        uint256 reserve;
        uint256 hubEth;
        uint256 bal;
        uint256 wrapped;
        uint256 market;
    }

    function _initIssuers() internal view returns (address[] memory issuers) {
        issuers = new address[](1);
        issuers[0] = address(this);
    }

    function _createInitNativeMarket(
        bytes memory marketRef,
        bytes32 marketId,
        string memory marketName,
        address[] memory issuers
    ) internal returns (LiquidityCommitmentCertificate nativeLcc) {
        // Non-native underlying must be a contract because metadata helpers may call `decimals()`.
        MockERC20Metadata other = new MockERC20Metadata();
        (address l0, address l1) = hub.createLCCPair(marketRef, address(0), address(other), marketName, issuers);
        hub.initialize(l0, l1, marketId, marketRef);
        address underlying0 = hub.getUnderlying(l0);
        nativeLcc = LiquidityCommitmentCertificate(underlying0 == address(0) ? l0 : l1);
    }

    function _createUninitialisedNative(bytes memory marketRef, string memory marketName, address[] memory issuers)
        internal
        returns (address uninitialisedNative)
    {
        MockERC20Metadata other = new MockERC20Metadata();
        (address u0, address u1) = hub.createLCCPair(marketRef, address(0), address(other), marketName, issuers);
        address underlying0 = hub.getUnderlying(u0);
        uninitialisedNative = underlying0 == address(0) ? u0 : u1;
    }

    function _deployLinkedLib() internal {
        // Deploy the linked library via CREATE2 from Echidna's harness address (deterministic).
        // The address is pinned via solc linking and must match `LCC_FACTORY_LINKED_LIB`.
        bytes32 salt = keccak256("echidna.LCCFactoryLinkedLib");
        bytes memory libInitCode = type(LCCFactoryLinkedLib).creationCode;
        address lib;
        assembly {
            lib := create2(0, add(libInitCode, 0x20), mload(libInitCode), salt)
        }
        require(lib != address(0), "LCCFactoryLinkedLib deploy failed");
        require(lib == LCC_FACTORY_LINKED_LIB, "LCCFactoryLinkedLib addr mismatch");
    }

    constructor() {
        _deployLinkedLib();

        // Deploy Hub with harness as owner so we can register this harness as a factory.
        MockOracleHelper oracleHelper = new MockOracleHelper(address(0xB0B));
        hub = new LiquidityHub(address(oracleHelper), "Ether", "ETH", 18, address(this));

        hub.setFactory(address(this), true);
        // Allow LCC transfers into the Hub (needed for wrapWith which pulls backing LCC via transferFrom).
        hub.setBoundLevel(address(hub), Bounds.BOUND_EXEMPT);

        // Register this harness as an issuer so we can exercise Domain B (`LiquidityHub.issue`) in later actions.
        address[] memory issuers = _initIssuers();

        // Create + initialize markets (Hub requires initialize() for LCCs to become "valid").
        lccNative = _createInitNativeMarket(abi.encodePacked(address(this)), bytes32(uint256(1)), "TEST", issuers);
        lccNative2 = _createInitNativeMarket(
            abi.encodePacked(address(this), bytes1(0x02)), bytes32(uint256(2)), "TESTB", issuers
        );

        // Create an additional LCC pair but DO NOT initialize it (must be rejected by issuer-only paths).
        lccUninitialised = _createUninitialisedNative(abi.encodePacked(address(this), bytes1(0x01)), "TEST2", issuers);

        nonIssuer = new LiquidityHubLCCBacking_NonIssuer();

        // Prime at least one Domain-B issuance so the invariant isn't vacuous if Echidna never calls `action_issue_market`.
        {
            uint256 amt = 1;
            Snapshot memory pre = _snapshot();
            hub.issue(address(lccNative), address(this), amt);
            Snapshot memory post = _snapshot();
            issueChecked = true;
            lastIssueOk = _issueDeltaOk(pre, post, amt);
        }
    }

    /// @dev LiquidityHubLib unwrap path calls `IMarketFactory(market.factory).useMarketLiquidity(...)`.
    ///      In this harness, we intentionally simulate "no market liquidity" by returning 0.
    ///      This allows us to test queue semantics deterministically.
    function useMarketLiquidity(
        address,
        /*underlyingAsset*/
        bytes32,
        /*marketId*/
        uint256 /*amount*/
    )
        external
        view
        returns (uint256 used)
    {
        // Only the Hub should ever call the factory for liquidity.
        if (msg.sender != address(hub)) revert();
        return 0;
    }

    function _snapshot() internal view returns (Snapshot memory s) {
        s.totalSupply = lccNative.totalSupply();
        s.directSupply = hub.directSupply(address(lccNative));
        s.reserve = hub.reserveOfUnderlying(address(lccNative));
        s.hubEth = address(hub).balance;
        s.bal = lccNative.balanceOf(address(this));
        (s.wrapped, s.market) = lccNative.balancesOf(address(this));
    }

    function _wrapDeltaOk(Snapshot memory pre, Snapshot memory post, uint256 amt) internal pure returns (bool) {
        // HUB-A-DELTA-01: exact 1:1 deltas for native wrap (Domain A).
        // - directSupply and reserve must increase by amount
        // - totalSupply and recipient balance must increase by amount
        // - recipient wrapped bucket must increase by amount
        // - recipient marketDerived bucket must not change
        // - hub ETH balance must increase by amount
        return post.directSupply == pre.directSupply + amt && post.reserve == pre.reserve + amt
            && post.totalSupply == pre.totalSupply + amt && post.bal == pre.bal + amt
            && post.wrapped == pre.wrapped + amt && post.market == pre.market && post.hubEth == pre.hubEth + amt;
    }

    function _issueDeltaOk(Snapshot memory pre, Snapshot memory post, uint256 amt) internal pure returns (bool) {
        // HUB-B-DELTA-01: exact deltas for issuer mint (Domain B).
        // - totalSupply and recipient balance must increase by amount
        // - recipient marketDerived bucket must increase by amount
        // - directSupply, reserves, hub ETH and recipient wrapped bucket must not change
        return post.totalSupply == pre.totalSupply + amt && post.bal == pre.bal + amt && post.market == pre.market + amt
            && post.directSupply == pre.directSupply && post.reserve == pre.reserve && post.hubEth == pre.hubEth
            && post.wrapped == pre.wrapped;
    }

    // -------------------------------------------------------------------------
    // Actions
    // -------------------------------------------------------------------------

    /// @notice Domain A action: wrap native ETH into LCC.
    /// @dev Echidna chooses `msg.value` (bounded by `maxValue` in config). We treat it as the wrap amount.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_wrap_native() external payable {
        // Mark checked even for zero-value calls so the invariant cannot pass purely due to never being exercised.
        // (Wrapping 0 should be a no-op, and we expect the delta check to succeed.)
        if (msg.value == 0) {
            wrapChecked = true;
            lastWrapOk = true;
            return;
        }
        Snapshot memory pre = _snapshot();
        hub.wrap{value: msg.value}(address(lccNative), msg.value);
        Snapshot memory post = _snapshot();
        wrapChecked = true;
        lastWrapOk = _wrapDeltaOk(pre, post, msg.value);
    }

    /// @notice Attempt a "free mint" by calling LCC.mint directly (should always fail).
    // forge-lint: disable-next-line(mixed-case-function)
    function action_try_direct_mint(uint256 amount) external {
        uint256 amt = (amount % 1e24) + 1;
        (bool ok,) =
            address(lccNative).call(abi.encodeWithSignature("mint(address,uint256,uint256)", address(this), amt, 0));
        lastDirectMintOk = ok;
    }

    /// @notice Domain B action: issuer-gated mint of market-derived LCC (no Hub reserves backing).
    // forge-lint: disable-next-line(mixed-case-function)
    function action_issue_market(uint256 amount) external {
        uint256 amt = (amount % 1e24) + 1;
        Snapshot memory pre = _snapshot();
        hub.issue(address(lccNative), address(this), amt);
        Snapshot memory post = _snapshot();
        issueChecked = true;
        lastIssueOk = _issueDeltaOk(pre, post, amt);
    }

    /// @notice Attempt a "free burn" by calling LCC.burn directly (should always fail).
    // forge-lint: disable-next-line(mixed-case-function)
    function action_try_direct_burn(uint256 amount) external {
        uint256 bal = lccNative.balanceOf(address(this));
        if (bal == 0) return;
        uint256 amt = (amount % bal) + 1;
        (bool ok,) =
            address(lccNative).call(abi.encodeWithSignature("burn(address,uint256,uint256)", address(this), 0, amt));
        lastDirectBurnOk = ok;
    }

    /// @notice Attempt Domain B issuance from a non-issuer address (should always fail).
    // forge-lint: disable-next-line(mixed-case-function)
    function action_try_issue_from_non_issuer(uint256 amount) external {
        uint256 amt = (amount % 1e24) + 1;
        lastNonIssuerIssueOk = nonIssuer.tryIssue(address(hub), address(lccNative), address(this), amt);
    }

    /// @notice VALID-LCC-01: issuer-only paths must reject an LCC that hasn't been initialised.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_try_issue_on_uninitialised_lcc(uint256 amount) external {
        uint256 amt = (amount % 1e24) + 1;
        (bool ok,) = address(hub)
            .call(abi.encodeWithSignature("issue(address,address,uint256)", lccUninitialised, address(this), amt));
        lastUninitialisedLccIssueOk = ok;
    }

    /// @notice VALID-LCC-01: issuer-only paths must reject an invalid/non-LCC address.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_try_issue_on_invalid_lcc(uint256 amount) external {
        uint256 amt = (amount % 1e24) + 1;
        address bogus = address(0xdead);
        (bool ok,) =
            address(hub).call(abi.encodeWithSignature("issue(address,address,uint256)", bogus, address(this), amt));
        lastInvalidLccIssueOk = ok;
    }

    /// @notice HUB-B-QUEUE-01: if we attempt to unwrap more than directSupply and there is no market liquidity,
    ///         the shortfall must be queued via settleQueue/totalQueued.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_unwrap_with_shortfall(uint256 amount) external {
        // Ensure we have some market-derived balance to unwrap against.
        (, uint256 marketDerived) = lccNative.balancesOf(address(this));
        if (marketDerived == 0) {
            // mint a small market-derived amount so unwrap can proceed
            hub.issue(address(lccNative), address(this), 1);
            marketDerived = 1;
        }

        (uint256 wrapped, uint256 market) = lccNative.balancesOf(address(this));
        uint256 total = wrapped + market;
        if (total == 0) {
            // Ensure we have a balance to unwrap.
            hub.issue(address(lccNative), address(this), 1);
            (wrapped, market) = lccNative.balancesOf(address(this));
            total = wrapped + market;
        }

        uint256 preDirect = hub.directSupply(address(lccNative));
        uint256 preReserve = hub.reserveOfUnderlying(address(lccNative));
        uint256 preQueue = hub.settleQueue(address(lccNative), address(this));
        uint256 preTotalQueued = hub.totalQueued(address(lccNative));

        // Choose an amount that is > preDirect (so we force a queue), and <= total (so unwrap doesn't revert).
        if (total <= preDirect) {
            // Increase market-derived balance until we can force a shortfall deterministically.
            uint256 need = (preDirect - total) + 1;
            hub.issue(address(lccNative), address(this), need);
            (wrapped, market) = lccNative.balancesOf(address(this));
            total = wrapped + market;
        }
        uint256 maxExtra = total - preDirect;
        uint256 amt = (amount % maxExtra) + preDirect + 1;

        // With no market liquidity, direct unwrapped is min(amt, preDirect) and the remainder must be queued.
        uint256 directUnwrapped = preDirect < amt ? preDirect : amt;
        uint256 expectedQueued = amt - directUnwrapped;

        hub.unwrapTo(address(lccNative), address(this), address(this), amt);

        uint256 postQueue = hub.settleQueue(address(lccNative), address(this));
        uint256 postTotalQueued = hub.totalQueued(address(lccNative));
        uint256 postReserve = hub.reserveOfUnderlying(address(lccNative));

        bool ok = true;
        ok = ok && (postQueue == preQueue + expectedQueued);
        ok = ok && (postTotalQueued == preTotalQueued + expectedQueued);
        // Reserve must not be fabricated; it should only ever decrease by what was actually paid out (directUnwrapped here).
        ok = ok && (postReserve == preReserve - directUnwrapped);
        ok = ok && (postReserve <= address(hub).balance);

        queueChecked = true;
        lastQueueOk = ok;
    }

    /// @notice WRAPWITH-CONS-01: wrapWith must be domain-preserving (no net minting / no reserve fabrication).
    /// @dev Converts between two native-backed LCCs that share the same underlying.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_wrapWith_conserve(uint256 amount, bool dir) external {
        uint256 amt = amount % 1e24;
        if (amt == 0) amt = 1;

        LiquidityCommitmentCertificate target = dir ? lccNative2 : lccNative;
        LiquidityCommitmentCertificate backing = dir ? lccNative : lccNative2;

        // Keep this check deterministic: only run when there are no pre-existing hub queues for either LCC.
        // Otherwise `wrapWith` may net against queues during the `transferFrom` into the Hub and/or during Step 0/2,
        // and the expected supply-vs-queue deltas become ambiguous without modelling more of the queue system.
        if (hub.totalQueued(address(target)) != 0) return;
        if (hub.totalQueued(address(backing)) != 0) return;

        // Ensure we have enough backing LCC to convert. Use issuer mint (Domain B) to top up deterministically.
        if (backing.balanceOf(address(this)) < amt) {
            hub.issue(address(backing), address(this), amt - backing.balanceOf(address(this)));
        }

        // Approve Hub to pull backing LCC.
        // (safe even if already approved)
        backing.approve(address(hub), type(uint256).max);

        uint256 preSumSupply = lccNative.totalSupply() + lccNative2.totalSupply();
        uint256 preReserve = hub.reserveOfUnderlying(address(lccNative)); // both share the same underlying (native)
        uint256 preHubEth = address(hub).balance;
        uint256 preQueueBacking = hub.totalQueued(address(backing));

        hub.wrapWith(address(target), address(backing), amt);

        uint256 postSumSupply = lccNative.totalSupply() + lccNative2.totalSupply();
        uint256 postReserve = hub.reserveOfUnderlying(address(lccNative));
        uint256 postHubEth = address(hub).balance;
        uint256 postQueueBacking = hub.totalQueued(address(backing));

        // Conservation (WRAPWITH-CONS-01):
        // - No underlying should be fabricated: reserves and hub ETH balance unchanged.
        // - If wrapWith cannot immediately materialize underlying (no market liquidity in this harness),
        //   the shortfall is represented as queued settlement on the backing LCC (Hub recipient),
        //   and total supply across both LCCs can temporarily increase by exactly that queued amount
        //   (the deferred burn will occur when the queue is processed).
        bool ok = true;
        ok = ok && (postReserve == preReserve);
        ok = ok && (postHubEth == preHubEth);
        ok = ok && (postSumSupply - preSumSupply == postQueueBacking - preQueueBacking);

        wrapWithChecked = true;
        lastWrapWithOk = ok;
    }

    /// @notice Helper action: attempt to process settlement for a recipient.
    /// @dev This exists to make queue-dependent invariants more reachable (e.g. allowing `wrapWith_conserve` to run
    ///      after earlier sequences introduced queued settlement). Uses a low-level call so reverts don't abort the run.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_process_settlement(bool useNative2, bool forHub, uint256 maxAmount) external {
        LiquidityCommitmentCertificate lcc = useNative2 ? lccNative2 : lccNative;
        address recipient = forHub ? address(hub) : address(this);
        uint256 amt = maxAmount % 1e24;
        if (amt == 0) amt = 1;
        (bool ok,) = address(hub)
            .call(
                abi.encodeWithSignature("processSettlementFor(address,address,uint256)", address(lcc), recipient, amt)
            );
        ok; // ignore success/revert; subsequent properties observe queue/reserve safety
    }

    /// @notice WRAPWITH-QUEUE-01: when the Hub already has a queue for the backing LCC, wrapWith Step 2 must
    ///         "lazy-claim" netting (without mutating the queue), and later settlement must NOT double-burn.
    /// @dev We create a pre-existing Hub queue for `backing` within this action (from a clean state), then
    ///      perform a second wrapWith that should net against it, and finally process settlement to ensure the
    ///      netted portion is not burned again.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_wrapWith_existing_queue_netting(uint256 seedAmount, uint256 netAmount, bool dir) external payable {
        LiquidityCommitmentCertificate target = dir ? lccNative2 : lccNative;
        LiquidityCommitmentCertificate backing = dir ? lccNative : lccNative2;

        // Require a clean queue state so the expected deltas are unambiguous.
        if (hub.totalQueued(address(target)) != 0) return;
        if (hub.totalQueued(address(backing)) != 0) return;

        // Ensure the Hub has some reserve so `processSettlementFor` can actually settle
        // (it clamps settlement by reserveOfUnderlying).
        // Reserve starts at 0 in the harness; we can seed it by doing a small native wrap here.
        if (msg.value > 0) {
            uint256 topUp = msg.value;
            // Avoid huge wraps; we only need a small reserve for settlement clamping.
            if (topUp > 1 ether) topUp = 1 ether;
            hub.wrap{value: topUp}(address(lccNative), topUp);
        }

        // Need some available reserve so processSettlementFor can actually settle (it clamps to available reserves).
        // Reserve is shared across both native-backed LCCs (same underlying), so use lccNative as canonical.
        uint256 reserve = hub.reserveOfUnderlying(address(lccNative));
        if (reserve == 0) return;

        uint256 seed = (seedAmount % 1000) + 1; // small and deterministic
        if (seed > reserve) return;

        // ---------------------------------------------------------------------
        // Step A: create a pre-existing Hub queue for `backing` by performing wrapWith when no queue exists.
        // With no market liquidity in this harness, Step 3 will queue the full amount to the Hub.
        // ---------------------------------------------------------------------
        hub.issue(address(backing), address(this), seed); // market-derived only
        backing.approve(address(hub), type(uint256).max);

        hub.wrapWith(address(target), address(backing), seed);

        if (hub.settleQueue(address(backing), address(hub)) != seed) return;
        if (hub.totalQueued(address(backing)) != seed) return;

        // ---------------------------------------------------------------------
        // Step B: perform a second wrapWith that should net against the existing Hub queue via Step 2.
        // This should NOT mutate settleQueue/totalQueued at net time.
        // ---------------------------------------------------------------------
        uint256 amt = (netAmount % seed) + 1; // ensure 1..seed

        // Top up backing balance as market-derived only.
        hub.issue(address(backing), address(this), amt);

        uint256 sumSupplyBefore = backing.totalSupply() + target.totalSupply();

        hub.wrapWith(address(target), address(backing), amt);

        // Queue must not change due to Step 2 lazy-claim netting.
        bool ok = true;
        ok = ok && (hub.settleQueue(address(backing), address(hub)) == seed);
        ok = ok && (hub.totalQueued(address(backing)) == seed);

        // Netting must conserve total supply across the pair (for the netted portion).
        ok = ok && (backing.totalSupply() + target.totalSupply() == sumSupplyBefore);

        // ---------------------------------------------------------------------
        // Step C: process Hub settlement for the netted portion and ensure it does NOT burn again.
        // In the Hub settlement path, `claimed` is decremented first and only the remainder is burned.
        // If Step 2 netting was accounted for correctly, settling `amt` should not reduce backing totalSupply further.
        // ---------------------------------------------------------------------
        uint256 supplyBackingBeforeSettle = backing.totalSupply();

        hub.processSettlementFor(address(backing), address(hub), amt);

        ok = ok && (hub.settleQueue(address(backing), address(hub)) == seed - amt);
        ok = ok && (hub.totalQueued(address(backing)) == seed - amt);
        ok = ok && (backing.totalSupply() == supplyBackingBeforeSettle); // no double-burn

        wrapWithQueueChecked = true;
        lastWrapWithQueueOk = ok;
    }

    /// @notice LCC-02: for non-protocol -> protocol transfers, queued settlement ownership must be annulled
    ///         before bucket decrement to prevent "bleeding" into the queue.
    /// @dev We create a queue entry for this harness without burning (market liquidity is 0 here), then transfer
    ///      the full balance into the Hub (protocol-bound). The transfer must annul the queued portion.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_lcc02_transfer_annuls_queue(uint256 totalAmount, uint256 queueAmount) external {
        // Use a fresh non-protocol holder to make this invariant reachable regardless of prior harness state.
        LiquidityHubLCCBacking_Holder holder = new LiquidityHubLCCBacking_Holder();

        uint256 total = (totalAmount % 1000) + 2; // small, >= 2
        uint256 q = (queueAmount % (total - 1)) + 1; // 1..total-1

        uint256 totalQueued0 = hub.totalQueued(address(lccNative));

        // Mint market-derived balance to the holder.
        hub.issue(address(lccNative), address(holder), total);

        // Create a queued settlement claim for the holder.
        if (!holder.unwrapToQueue(address(hub), address(lccNative), q)) return;

        uint256 queueAfter = hub.settleQueue(address(lccNative), address(holder));
        uint256 totalQueuedAfter = hub.totalQueued(address(lccNative));
        if (queueAfter != q) return;
        if (totalQueuedAfter != totalQueued0 + q) return;

        // Transfer full balance to protocol-bound hub; transfer must annul queued portion.
        if (!holder.transfer(address(lccNative), address(hub), total)) return;

        bool ok = true;
        ok = ok && (hub.settleQueue(address(lccNative), address(holder)) == 0);
        ok = ok && (hub.totalQueued(address(lccNative)) == totalQueued0);

        lcc02Checked = true;
        lastLcc02Ok = ok;
    }

    /// @notice Donate raw ETH into the Hub without touching reserve accounting.
    /// @dev `LiquidityHub` has a payable `receive()`; this lets Echidna explore states where
    ///      actual Hub balance is higher than `reserveOfUnderlying`.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_donate_eth_to_hub() external payable {
        if (msg.value == 0) return;
        (bool ok,) = address(hub).call{value: msg.value}("");
        if (!ok) return;
    }

    /// @notice HUB-05 surface: attempt to increase Hub reserve via `confirmTake`.
    /// @dev Uses low-level call so reverts don't end the whole fuzz sequence.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_confirm_take(uint256 amount) external {
        uint256 amt = amount % 1e24;
        if (amt == 0) return;
        (bool ok,) = address(hub)
            .call(abi.encodeWithSignature("confirmTake(address,uint256,bool)", address(lccNative), amt, false));
        ok; // ignore success/revert; property checks global reserve safety
    }

    // -------------------------------------------------------------------------
    // Properties
    // -------------------------------------------------------------------------

    /// @dev Bucket decomposition (single-holder harness): totalSupply should equal wrapped+marketDerived buckets.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_totalSupply_equals_wrapped_plus_marketDerived() external view returns (bool) {
        // This harness is not necessarily the sole holder once `wrapWith` is exercised (Hub can hold balances).
        // For a non-protocol holder, bucket sums must match ERC20 balance.
        (uint256 wrapped, uint256 marketDerived) = lccNative.balancesOf(address(this));
        return lccNative.balanceOf(address(this)) == (wrapped + marketDerived);
    }

    /// @dev Domain A bookkeeping (single-holder regime): hub-level `directSupply` must match this holder's wrapped bucket.
    ///      This can become a false positive once other addresses (e.g., the Hub via `wrapWith` or protocol transfers)
    ///      hold balances, because `directSupply` is global while `balancesOf(this)` is per-holder.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_directSupply_equals_wrapped_bucket() external view returns (bool) {
        // Only assert this identity while the Hub is not holding any balance for this LCC.
        // (Hub balances are BOUND_EXEMPT and do not participate in holder bucket accounting.)
        if (lccNative.balanceOf(address(hub)) != 0) return true;
        (uint256 wrapped,) = lccNative.balancesOf(address(this));
        return hub.directSupply(address(lccNative)) == wrapped;
    }

    // NOTE: We intentionally do not assert a global identity like `marketDerived == totalSupply - directSupply` here.
    // Once protocol endpoints (e.g., the Hub) hold balances, bucket-exempt accounting treats those balances as "wrapped",
    // so that identity can be false even when the protocol is behaving correctly.

    /// @dev No “free mint”: only the hub can call `LCC.mint`.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_no_free_mint() external view returns (bool) {
        return lastDirectMintOk == false;
    }

    /// @dev No “free burn”: only the hub can call `LCC.burn`.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_no_free_burn() external view returns (bool) {
        return lastDirectBurnOk == false;
    }

    /// @dev Domain B issuance must be issuer-gated.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_issue_is_issuer_gated() external view returns (bool) {
        return lastNonIssuerIssueOk == false;
    }

    /// @dev VALID-LCC-01: issuer-only issue must reject uninitialised LCCs.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_issue_rejects_uninitialised_lcc() external view returns (bool) {
        return lastUninitialisedLccIssueOk == false;
    }

    /// @dev VALID-LCC-01: issuer-only issue must reject invalid/non-LCC addresses.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_issue_rejects_invalid_lcc() external view returns (bool) {
        return lastInvalidLccIssueOk == false;
    }

    /// @dev HUB-A-DELTA-01: every successful native wrap must satisfy exact 1:1 backing deltas.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_wrap_native_is_1_to_1() external view returns (bool) {
        return !wrapChecked || lastWrapOk;
    }

    /// @dev HUB-B-DELTA-01: every successful issuer mint must not touch Hub reserves/directSupply and must mint market-derived 1:1.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_issue_market_is_market_derived_only() external view returns (bool) {
        return !issueChecked || lastIssueOk;
    }

    /// @dev HUB-B-QUEUE-01: shortfalls must be represented in the settlement queue (and reserves must not be fabricated).
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_unwrap_shortfall_is_queued() external view returns (bool) {
        return !queueChecked || lastQueueOk;
    }

    /// @dev WRAPWITH-CONS-01: wrapWith must conserve supply across LCCs and not fabricate Hub reserves.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_wrapWith_conserves() external view returns (bool) {
        return !wrapWithChecked || lastWrapWithOk;
    }

    /// @dev WRAPWITH-QUEUE-01: pre-existing Hub queues must not cause double-counting during wrapWith netting.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_wrapWith_queue_netting_no_double_burn() external view returns (bool) {
        return !wrapWithQueueChecked || lastWrapWithQueueOk;
    }

    /// @dev LCC-02: queued settlement must be annulled on non-protocol -> protocol transfers.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_lcc02_annuls_queue_on_protocol_transfer() external view returns (bool) {
        return !lcc02Checked || lastLcc02Ok;
    }

    /// @dev HUB-05: reserves cannot be fabricated; reserve accounting must be <= actual Hub holdings.
    ///      For the native underlying, this is simply reserve <= address(hub).balance.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_hub05_reserve_never_exceeds_hub_balance() external view returns (bool) {
        uint256 reserve = hub.reserveOfUnderlying(address(lccNative));
        return reserve <= address(hub).balance;
    }
}

/// @dev Separate contract so we can make calls with a non-issuer `msg.sender`.
contract LiquidityHubLCCBacking_NonIssuer {
    /// @notice Attempt issuer-only mint from a non-issuer address.
    /// @return ok True if the call unexpectedly succeeds.
    function tryIssue(address hub, address lcc, address to, uint256 amount) external returns (bool ok) {
        (ok,) = hub.call(abi.encodeWithSignature("issue(address,address,uint256)", lcc, to, amount));
    }
}

/// @dev Non-protocol holder used to make transfer/queue invariants reachable regardless of harness state.
contract LiquidityHubLCCBacking_Holder {
    function unwrapToQueue(address hub, address lcc, uint256 amount) external returns (bool ok) {
        (ok,) = hub.call(
            abi.encodeWithSignature(
                "unwrapTo(address,address,address,uint256)", lcc, address(this), address(this), amount
            )
        );
    }

    function transfer(address token, address to, uint256 amount) external returns (bool ok) {
        (ok,) = token.call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
    }
}

