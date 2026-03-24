// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {LiquidityHub} from "../../src/LiquidityHub.sol";
import {LiquidityCommitmentCertificate} from "../../src/LCC.sol";
import {MockOracleHelper} from "./mocks/MockOracleHelper.sol";
import {MockERC20Transferable} from "./mocks/MockERC20Transferable.sol";
import {Bounds} from "../../src/libraries/Bounds.sol";
import {LCCFactoryLinkedLib} from "../../src/libraries/LCCFactoryLib.sol";
import {LiquidityHubLinkedLib} from "../../src/libraries/LiquidityHubLinkedLib.sol";

/// @notice Echidna harness for wrapWith + queue/transfer semantics (Domain conversion).
contract LiquidityHubWrapWithQueueEchidnaTest {
    LiquidityHub internal hub;
    LiquidityCommitmentCertificate internal lccNative;
    LiquidityCommitmentCertificate internal lccNative2;

    // WRAPWITH-CONS-01 tracking.
    bool internal wrapWithChecked;
    bool internal lastWrapWithOk;

    // WRAPWITH-QUEUE-01 tracking.
    bool internal wrapWithQueueChecked;
    bool internal lastWrapWithQueueOk;

    // LCC-02 tracking.
    bool internal lcc02Checked;
    bool internal lastLcc02Ok;

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

        MockOracleHelper oracleHelper = new MockOracleHelper(address(0xB0B));
        hub = new LiquidityHub(address(oracleHelper), "Ether", "ETH", 18, address(this));

        hub.setFactory(address(this), true);
        // Allow LCC transfers into the Hub (needed for wrapWith which pulls backing LCC via transferFrom).
        hub.setBoundLevel(address(hub), Bounds.BOUND_EXEMPT);

        address[] memory issuers = _initIssuers();

        lccNative = _createInitNativeMarket(abi.encodePacked(address(this)), bytes32(uint256(1)), "TEST", issuers);
        lccNative2 = _createInitNativeMarket(
            abi.encodePacked(address(this), bytes1(0x02)), bytes32(uint256(2)), "TESTB", issuers
        );
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
        if (msg.sender != address(hub)) revert();
        return 0;
    }

    // -------------------------------------------------------------------------
    // Actions
    // -------------------------------------------------------------------------

    /// @notice WRAPWITH-CONS-01: wrapWith must be domain-preserving (no net minting / no reserve fabrication).
    /// @dev Converts between two native-backed LCCs that share the same underlying.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_wrapWith_conserve(uint256 amount, bool dir) external {
        uint256 amt = amount % 1e24;
        if (amt == 0) amt = 1;

        LiquidityCommitmentCertificate target = dir ? lccNative2 : lccNative;
        LiquidityCommitmentCertificate backing = dir ? lccNative : lccNative2;

        // Keep this check deterministic: only run when there are no pre-existing hub queues for either LCC.
        if (hub.totalQueued(address(target)) != 0) return;
        if (hub.totalQueued(address(backing)) != 0) return;

        // Ensure we have enough backing LCC to convert. Use issuer mint (Domain B) to top up deterministically.
        if (backing.balanceOf(address(this)) < amt) {
            hub.issue(address(backing), address(this), amt - backing.balanceOf(address(this)));
        }

        // Approve Hub to pull backing LCC.
        backing.approve(address(hub), type(uint256).max);

        uint256 preSumSupply = lccNative.totalSupply() + lccNative2.totalSupply();
        uint256 preReserve = hub.reserveOfUnderlying(address(lccNative));
        uint256 preHubEth = address(hub).balance;
        uint256 preQueueBacking = hub.totalQueued(address(backing));

        hub.wrapWith(address(target), address(backing), amt);

        uint256 postSumSupply = lccNative.totalSupply() + lccNative2.totalSupply();
        uint256 postReserve = hub.reserveOfUnderlying(address(lccNative));
        uint256 postHubEth = address(hub).balance;
        uint256 postQueueBacking = hub.totalQueued(address(backing));

        bool ok = true;
        ok = ok && (postReserve == preReserve);
        ok = ok && (postHubEth == preHubEth);
        ok = ok && (postSumSupply - preSumSupply == postQueueBacking - preQueueBacking);

        wrapWithChecked = true;
        lastWrapWithOk = ok;
    }

    /// @notice Helper action: attempt to process settlement for a recipient.
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
        ok;
    }

    /// @notice WRAPWITH-QUEUE-01: pre-existing Hub queues must not cause double-counting during wrapWith netting.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_wrapWith_existing_queue_netting(uint256 seedAmount, uint256 netAmount, bool dir) external payable {
        LiquidityCommitmentCertificate target = dir ? lccNative2 : lccNative;
        LiquidityCommitmentCertificate backing = dir ? lccNative : lccNative2;

        if (hub.totalQueued(address(target)) != 0) return;
        if (hub.totalQueued(address(backing)) != 0) return;

        if (msg.value > 0) {
            uint256 topUp = msg.value;
            if (topUp > 1 ether) topUp = 1 ether;
            hub.wrap{value: topUp}(address(lccNative), topUp);
        }

        uint256 reserve = hub.reserveOfUnderlying(address(lccNative));
        if (reserve == 0) return;

        uint256 seed = (seedAmount % 1000) + 1;
        if (seed > reserve) return;

        hub.issue(address(backing), address(this), seed);
        backing.approve(address(hub), type(uint256).max);

        hub.wrapWith(address(target), address(backing), seed);

        if (hub.settleQueue(address(backing), address(hub)) != seed) return;
        if (hub.totalQueued(address(backing)) != seed) return;

        uint256 amt = (netAmount % seed) + 1;
        hub.issue(address(backing), address(this), amt);

        uint256 sumSupplyBefore = backing.totalSupply() + target.totalSupply();

        hub.wrapWith(address(target), address(backing), amt);

        bool ok = true;
        ok = ok && (hub.settleQueue(address(backing), address(hub)) == seed);
        ok = ok && (hub.totalQueued(address(backing)) == seed);
        ok = ok && (backing.totalSupply() + target.totalSupply() == sumSupplyBefore);

        uint256 supplyBackingBeforeSettle = backing.totalSupply();
        hub.processSettlementFor(address(backing), address(hub), amt);

        ok = ok && (hub.settleQueue(address(backing), address(hub)) == seed - amt);
        ok = ok && (hub.totalQueued(address(backing)) == seed - amt);
        ok = ok && (backing.totalSupply() == supplyBackingBeforeSettle);

        wrapWithQueueChecked = true;
        lastWrapWithQueueOk = ok;
    }

    /// @notice LCC-02: queued settlement must be annulled on non-protocol -> protocol transfers.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_lcc02_transfer_annuls_queue(uint256 totalAmount, uint256 queueAmount) external {
        LiquidityHubWrapWithQueue_Holder holder = new LiquidityHubWrapWithQueue_Holder();

        uint256 total = (totalAmount % 1000) + 2;
        uint256 q = (queueAmount % (total - 1)) + 1;

        uint256 totalQueued0 = hub.totalQueued(address(lccNative));

        hub.issue(address(lccNative), address(holder), total);

        if (!holder.unwrapToQueue(address(hub), address(lccNative), q)) return;

        uint256 queueAfter = hub.settleQueue(address(lccNative), address(holder));
        uint256 totalQueuedAfter = hub.totalQueued(address(lccNative));
        if (queueAfter != q) return;
        if (totalQueuedAfter != totalQueued0 + q) return;

        if (!holder.transfer(address(lccNative), address(hub), total)) return;

        bool ok = true;
        ok = ok && (hub.settleQueue(address(lccNative), address(holder)) == 0);
        ok = ok && (hub.totalQueued(address(lccNative)) == totalQueued0);

        lcc02Checked = true;
        lastLcc02Ok = ok;
    }

    /// @notice Donate raw ETH into the Hub without touching reserve accounting.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_donate_eth_to_hub() external payable {
        if (msg.value == 0) return;
        (bool ok,) = address(hub).call{value: msg.value}("");
        if (!ok) return;
    }

    /// @notice HUB-05 surface: attempt to increase Hub reserve via `confirmTake`.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_confirm_take(uint256 amount) external {
        uint256 amt = amount % 1e24;
        if (amt == 0) return;
        (bool ok,) = address(hub)
            .call(abi.encodeWithSignature("confirmTake(address,uint256,bool)", address(lccNative), amt, false));
        ok;
    }

    // -------------------------------------------------------------------------
    // Properties
    // -------------------------------------------------------------------------

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
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_hub05_reserve_never_exceeds_hub_balance() external view returns (bool) {
        uint256 reserve = hub.reserveOfUnderlying(address(lccNative));
        return reserve <= address(hub).balance;
    }
}

/// @dev Non-protocol holder used to make transfer/queue invariants reachable regardless of harness state.
contract LiquidityHubWrapWithQueue_Holder {
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
