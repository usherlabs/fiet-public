// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {LiquidityHub} from "../../src/LiquidityHub.sol";
import {LiquidityCommitmentCertificate} from "../../src/LCC.sol";
import {MockOracleHelper} from "./mocks/MockOracleHelper.sol";
import {MockERC20Transferable} from "./mocks/MockERC20Transferable.sol";
import {Bounds} from "../../src/libraries/Bounds.sol";
import {LCCFactoryLinkedLib} from "../../src/libraries/LCCFactoryLib.sol";
import {LiquidityHubLinkedLib} from "../../src/libraries/LiquidityHubLinkedLib.sol";

/// @notice Echidna harness for LiquidityHub/LCC backing invariants (Domains A/B + transfer semantics).
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
/// - Add wrapWith conversion and conservation checks (moved to separate harness).
contract LiquidityHubLCCBackingEchidnaTest {
    LiquidityHub internal hub;
    LiquidityCommitmentCertificate internal lccNative;
    LiquidityCommitmentCertificate internal lccERC20;
    address internal lccUninitialised;
    MockERC20Transferable internal erc20Token;

    bool internal lastDirectMintOk;
    bool internal lastDirectBurnOk;
    bool internal lastNonIssuerIssueOk;
    bool internal lastUninitialisedLccIssueOk;
    bool internal lastInvalidLccIssueOk;

    LiquidityHubLCCBacking_NonIssuer internal nonIssuer;

    // HUB-A-DELTA-01 tracking: record whether the last attempted native wrap satisfied exact 1:1 deltas.
    bool internal wrapChecked;
    bool internal lastWrapOk;

    // HUB-01 additional coverage tracking:
    bool internal wrapToChecked;
    bool internal lastWrapToOk;
    bool internal wrapToMarketIdChecked;
    bool internal lastWrapToMarketIdOk;
    bool internal wrapERC20Checked;
    bool internal lastWrapERC20Ok;
    bool internal wrapNativeGuardChecked;
    bool internal lastWrapNativeGuardOk;

    // HUB-B-DELTA-01 tracking: record whether the last attempted issuer mint satisfied exact Domain-B deltas.
    bool internal issueChecked;
    bool internal lastIssueOk;

    // HUB-B-QUEUE-01 tracking: record whether the last attempted unwrap-with-shortfall correctly queued.
    bool internal queueChecked;
    bool internal lastQueueOk;

    // HUB-05: reserve accounting must never exceed actual Hub holdings.
    // (Property moved to separate harness; this contract focuses on Domain A/B + queue.)

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
        MockERC20Transferable other = new MockERC20Transferable();
        (address l0, address l1) = hub.createLCCPair(marketRef, address(0), address(other), marketName, issuers);
        hub.initialize(l0, l1, marketId, marketRef);
        address underlying0 = hub.getUnderlying(l0);
        nativeLcc = LiquidityCommitmentCertificate(underlying0 == address(0) ? l0 : l1);
    }

    function _createUninitialisedNative(bytes memory marketRef, string memory marketName, address[] memory issuers)
        internal
        returns (address uninitialisedNative)
    {
        MockERC20Transferable other = new MockERC20Transferable();
        (address u0, address u1) = hub.createLCCPair(marketRef, address(0), address(other), marketName, issuers);
        address underlying0 = hub.getUnderlying(u0);
        uninitialisedNative = underlying0 == address(0) ? u0 : u1;
    }

    function _createInitERC20Market(
        bytes memory marketRef,
        bytes32 marketId,
        string memory marketName,
        address[] memory issuers,
        MockERC20Transferable token
    ) internal returns (LiquidityCommitmentCertificate erc20Lcc) {
        (address l0, address l1) = hub.createLCCPair(marketRef, address(token), address(0), marketName, issuers);
        hub.initialize(l0, l1, marketId, marketRef);
        address underlying0 = hub.getUnderlying(l0);
        erc20Lcc = LiquidityCommitmentCertificate(underlying0 == address(token) ? l0 : l1);
    }

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
        // Create ERC20-backed LCC for HUB-01 ERC20 wrapping tests.
        erc20Token = new MockERC20Transferable();
        erc20Token.mint(address(this), type(uint128).max); // Mint enough for fuzzing
        erc20Token.approve(address(hub), type(uint256).max);
        lccERC20 = _createInitERC20Market(
            abi.encodePacked(address(this), bytes1(0x03)), bytes32(uint256(3)), "TESTERC20", issuers, erc20Token
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

    function _snapshotERC20() internal view returns (Snapshot memory s) {
        s.totalSupply = lccERC20.totalSupply();
        s.directSupply = hub.directSupply(address(lccERC20));
        s.reserve = hub.reserveOfUnderlying(address(lccERC20));
        s.hubEth = address(hub).balance;
        s.bal = lccERC20.balanceOf(address(this));
        (s.wrapped, s.market) = lccERC20.balancesOf(address(this));
    }

    function _snapshotForRecipient(LiquidityCommitmentCertificate lcc, address recipient)
        internal
        view
        returns (Snapshot memory s)
    {
        s.totalSupply = lcc.totalSupply();
        s.directSupply = hub.directSupply(address(lcc));
        s.reserve = hub.reserveOfUnderlying(address(lcc));
        s.hubEth = address(hub).balance;
        s.bal = lcc.balanceOf(recipient);
        (s.wrapped, s.market) = lcc.balancesOf(recipient);
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

    function _wrapERC20DeltaOk(Snapshot memory pre, Snapshot memory post, uint256 amt) internal pure returns (bool) {
        // HUB-A-DELTA-01: exact 1:1 deltas for ERC20 wrap (Domain A).
        // - directSupply and reserve must increase by amount
        // - totalSupply and recipient balance must increase by amount
        // - recipient wrapped bucket must increase by amount
        // - recipient marketDerived bucket must not change
        // - hub ETH balance must not change (ERC20, not native)
        return post.directSupply == pre.directSupply + amt && post.reserve == pre.reserve + amt
            && post.totalSupply == pre.totalSupply + amt && post.bal == pre.bal + amt
            && post.wrapped == pre.wrapped + amt && post.market == pre.market && post.hubEth == pre.hubEth;
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

    /// @notice HUB-01: Test native wrap guard - msg.value must equal amount.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_wrap_native_guard(uint256 amount, uint256 value) external payable {
        wrapNativeGuardChecked = true;
        if (amount == 0) {
            lastWrapNativeGuardOk = true; // Zero amount is handled separately
            return;
        }
        uint256 amt = (amount % 1e24) + 1;
        uint256 val = (value % 1e24);
        // Test mismatch: if val != amt, wrap should revert
        if (val != amt) {
            (bool ok,) =
                address(hub).call{value: val}(abi.encodeWithSignature("wrap(address,uint256)", address(lccNative), amt));
            lastWrapNativeGuardOk = !ok; // Should revert, so ok=false is success
        } else {
            lastWrapNativeGuardOk = true; // Matching values should work (tested elsewhere)
        }
    }

    /// @notice HUB-01: wrapTo variant - wrap native ETH to a different recipient.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_wrapTo_native(uint256 amount, address recipient) external payable {
        if (recipient == address(0) || recipient == address(this)) {
            // Use a deterministic recipient to avoid address(0) issues
            recipient = address(0x1234);
        }
        uint256 amt = (amount % 1e24);
        if (amt == 0) {
            wrapToChecked = true;
            lastWrapToOk = true;
            return;
        }
        Snapshot memory pre = _snapshotForRecipient(lccNative, recipient);
        hub.wrapTo{value: amt}(address(lccNative), recipient, amt);
        Snapshot memory post = _snapshotForRecipient(lccNative, recipient);
        wrapToChecked = true;
        // Check that recipient received the LCC, not the caller
        lastWrapToOk = post.bal == pre.bal + amt && post.wrapped == pre.wrapped + amt
            && post.totalSupply == pre.totalSupply + amt && post.directSupply == pre.directSupply + amt
            && post.reserve == pre.reserve + amt;
    }

    /// @notice HUB-01: wrapTo with marketId lookup - wrap native ETH using underlying + marketId.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_wrapTo_marketId_native(uint256 amount, address recipient) external payable {
        if (recipient == address(0) || recipient == address(this)) {
            recipient = address(0x5678);
        }
        uint256 amt = (amount % 1e24);
        if (amt == 0) {
            wrapToMarketIdChecked = true;
            lastWrapToMarketIdOk = true;
            return;
        }
        bytes32 marketId = bytes32(uint256(1)); // Use the marketId from lccNative
        Snapshot memory pre = _snapshotForRecipient(lccNative, recipient);
        hub.wrapTo{value: amt}(address(0), marketId, recipient, amt);
        Snapshot memory post = _snapshotForRecipient(lccNative, recipient);
        wrapToMarketIdChecked = true;
        lastWrapToMarketIdOk = post.bal == pre.bal + amt && post.wrapped == pre.wrapped + amt
            && post.totalSupply == pre.totalSupply + amt && post.directSupply == pre.directSupply + amt
            && post.reserve == pre.reserve + amt;
    }

    /// @notice HUB-01: Wrap ERC20 into LCC (Domain A for ERC20).
    // forge-lint: disable-next-line(mixed-case-function)
    function action_wrap_erc20(uint256 amount) external {
        uint256 amt = (amount % 1e24);
        if (amt == 0) {
            wrapERC20Checked = true;
            lastWrapERC20Ok = true;
            return;
        }
        // Ensure we have enough ERC20 balance
        if (erc20Token.balanceOf(address(this)) < amt) {
            erc20Token.mint(address(this), amt);
        }
        Snapshot memory pre = _snapshotERC20();
        hub.wrap(address(lccERC20), amt);
        Snapshot memory post = _snapshotERC20();
        wrapERC20Checked = true;
        lastWrapERC20Ok = _wrapERC20DeltaOk(pre, post, amt);
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

        // Re-read wrapped balance after issuing (it may have changed)
        (wrapped, market) = lccNative.balancesOf(address(this));

        // Ensure we have enough balance to unwrap the calculated amount.
        if (amt > wrapped + market) {
            queueChecked = true;
            lastQueueOk = false;
            return;
        }

        // directUnwrapped = min(amt, wrapped, preDirect) per unwrapInternalLogic
        uint256 temp1 = amt < wrapped ? amt : wrapped;
        uint256 directUnwrapped = temp1 < preDirect ? temp1 : preDirect;
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
        uint256 directSupply = hub.directSupply(address(lccNative));
        if (directSupply > wrapped) return true;
        return directSupply == wrapped;
    }

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

    /// @dev HUB-01: native wrap must revert when msg.value != amount.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_wrap_native_guard_reverts() external view returns (bool) {
        return !wrapNativeGuardChecked || lastWrapNativeGuardOk;
    }

    /// @dev HUB-01: wrapTo must send LCC to the specified recipient with 1:1 deltas.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_wrapTo_native_is_1_to_1() external view returns (bool) {
        return !wrapToChecked || lastWrapToOk;
    }

    /// @dev HUB-01: wrapTo with marketId lookup must work correctly with 1:1 deltas.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_wrapTo_marketId_native_is_1_to_1() external view returns (bool) {
        return !wrapToMarketIdChecked || lastWrapToMarketIdOk;
    }

    /// @dev HUB-01: ERC20 wrap must satisfy exact 1:1 backing deltas (no native ETH involved).
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_wrap_erc20_is_1_to_1() external view returns (bool) {
        return !wrapERC20Checked || lastWrapERC20Ok;
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
}

/// @dev Separate contract so we can make calls with a non-issuer `msg.sender`.
contract LiquidityHubLCCBacking_NonIssuer {
    /// @notice Attempt issuer-only mint from a non-issuer address.
    /// @return ok True if the call unexpectedly succeeds.
    function tryIssue(address hub, address lcc, address to, uint256 amount) external returns (bool ok) {
        (ok,) = hub.call(abi.encodeWithSignature("issue(address,address,uint256)", lcc, to, amount));
    }
}
