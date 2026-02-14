// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {LiquidityHub} from "../../src/LiquidityHub.sol";
import {LiquidityCommitmentCertificate} from "../../src/LCC.sol";
import {MockOracleHelper} from "./mocks/MockOracleHelper.sol";
import {MockERC20Transferable} from "./mocks/MockERC20Transferable.sol";
import {Bounds} from "../../src/libraries/Bounds.sol";
import {LCCFactoryLinkedLib} from "../../src/libraries/LCCFactoryLib.sol";

/// @notice Micro-harness focused on `LiquidityHub.wrapWith` invariants (Domain conversion).
/// @dev This isolates `wrapWith` behaviour from the larger Hub/LCC backing harness so expectations stay deterministic.
contract LiquidityHubWrapWithEchidnaTest {
    // Must match `foundry.toml` profile `echidna` hard-link for `LCCFactoryLinkedLib`.
    address internal constant LCC_FACTORY_LINKED_LIB = 0xE2B5401952dC4c9059b7eDE3a1742bF2BC17EBAd;

    LiquidityHub internal hub;
    LiquidityCommitmentCertificate internal lccA;
    LiquidityCommitmentCertificate internal lccB;

    bool internal checkedConserve;
    bool internal lastConserveOk;

    bool internal checkedNetting;
    bool internal lastNettingOk;

    function _deployLinkedLib() internal {
        bytes32 salt = keccak256("echidna.LCCFactoryLinkedLib");
        bytes memory libInitCode = type(LCCFactoryLinkedLib).creationCode;
        address lib;
        assembly {
            lib := create2(0, add(libInitCode, 0x20), mload(libInitCode), salt)
        }
        require(lib != address(0), "LCCFactoryLinkedLib deploy failed");
        require(lib == LCC_FACTORY_LINKED_LIB, "LCCFactoryLinkedLib addr mismatch");
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

        // Harness as factory + issuer so we can create markets and mint market-derived balances for holders.
        hub.setFactory(address(this), true);
        hub.setBoundLevel(address(hub), Bounds.BOUND_EXEMPT);

        address[] memory issuers = _initIssuers();
        lccA =
            _createInitNativeMarket(abi.encodePacked(address(this), bytes1(0xA0)), bytes32(uint256(10)), "A", issuers);
        lccB =
            _createInitNativeMarket(abi.encodePacked(address(this), bytes1(0xB0)), bytes32(uint256(11)), "B", issuers);
    }

    /// @dev Simulate "no market liquidity" deterministically.
    function useMarketLiquidity(address, bytes32, uint256) external view returns (uint256 used) {
        if (msg.sender != address(hub)) revert();
        return 0;
    }

    // -------------------------------------------------------------------------
    // Actions
    // -------------------------------------------------------------------------

    /// @notice Seed Hub ETH reserve by wrapping native into `lccA`.
    /// @dev This is needed so Hub queue settlement can be processed (it clamps by reserveOfUnderlying).
    // forge-lint: disable-next-line(mixed-case-function)
    function action_seed_reserve() external payable {
        if (msg.value == 0) return;
        hub.wrap{value: msg.value}(address(lccA), msg.value);
    }

    /// @notice WRAPWITH-CONS-01: from a clean queue state, `wrapWith` must conserve supply vs queued shortfall.
    /// @dev Uses a fresh non-protocol holder each time to avoid cross-action queue interactions.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_wrapWith_conserve_clean(uint256 amount, bool dir) external {
        checkedConserve = true;
        lastConserveOk = true;

        LiquidityCommitmentCertificate target = dir ? lccB : lccA;
        LiquidityCommitmentCertificate backing = dir ? lccA : lccB;

        // Require globally clean queue state for determinism.
        if (hub.totalQueued(address(target)) != 0) return;
        if (hub.totalQueued(address(backing)) != 0) return;

        uint256 amt = (amount % 1e24) + 1;

        LiquidityHubWrapWith_Holder holder = new LiquidityHubWrapWith_Holder();

        // Mint backing as market-derived only.
        hub.issue(address(backing), address(holder), amt);

        // Approve and execute wrapWith as the holder.
        holder.approve(address(backing), address(hub));

        uint256 preSumSupply = lccA.totalSupply() + lccB.totalSupply();
        uint256 preReserve = hub.reserveOfUnderlying(address(lccA)); // shared native reserve
        uint256 preHubEth = address(hub).balance;
        uint256 preQueueBacking = hub.totalQueued(address(backing));

        bool okCall = holder.wrapWith(address(hub), address(target), address(backing), amt);
        if (!okCall) {
            lastConserveOk = false;
            return;
        }

        uint256 postSumSupply = lccA.totalSupply() + lccB.totalSupply();
        uint256 postReserve = hub.reserveOfUnderlying(address(lccA));
        uint256 postHubEth = address(hub).balance;
        uint256 postQueueBacking = hub.totalQueued(address(backing));

        bool ok = true;
        ok = ok && (postReserve == preReserve);
        ok = ok && (postHubEth == preHubEth);
        ok = ok && (postSumSupply - preSumSupply == postQueueBacking - preQueueBacking);

        lastConserveOk = ok;
    }

    /// @notice WRAPWITH-QUEUE-01: Step-2 netting must not double-burn on later settlement.
    /// @dev This reproduces the intended netting path in a minimal harness:
    ///      1) Create a Hub queue on `backing` by doing wrapWith(seed)
    ///      2) Do wrapWith(net) which should net against the queue without mutating it
    ///      3) Process settlement for Hub and ensure netting isn't burned again
    // forge-lint: disable-next-line(mixed-case-function)
    function action_wrapWith_queue_netting(uint256 seedAmount, uint256 netAmount, bool dir) external {
        checkedNetting = true;
        lastNettingOk = true;

        LiquidityCommitmentCertificate target = dir ? lccB : lccA;
        LiquidityCommitmentCertificate backing = dir ? lccA : lccB;

        // Require globally clean queue state for determinism.
        if (hub.totalQueued(address(target)) != 0) return;
        if (hub.totalQueued(address(backing)) != 0) return;

        // Need some reserve to process settlement for the Hub queue (clamped by reserve).
        uint256 reserve = hub.reserveOfUnderlying(address(lccA));
        if (reserve == 0) return;

        uint256 seed = (seedAmount % 1000) + 1;
        if (seed > reserve) seed = reserve;
        if (seed == 0) return;

        uint256 net = (netAmount % seed) + 1;

        LiquidityHubWrapWith_Holder holder = new LiquidityHubWrapWith_Holder();

        // Step A: create Hub queue for `backing` via wrapWith(seed)
        hub.issue(address(backing), address(holder), seed);
        holder.approve(address(backing), address(hub));
        if (!holder.wrapWith(address(hub), address(target), address(backing), seed)) {
            lastNettingOk = false;
            return;
        }

        if (hub.settleQueue(address(backing), address(hub)) != seed) return;
        if (hub.totalQueued(address(backing)) != seed) return;

        // Step B: netting wrapWith(net)
        hub.issue(address(backing), address(holder), net);
        uint256 sumSupplyBefore = backing.totalSupply() + target.totalSupply();
        if (!holder.wrapWith(address(hub), address(target), address(backing), net)) {
            lastNettingOk = false;
            return;
        }

        bool ok = true;
        ok = ok && (hub.settleQueue(address(backing), address(hub)) == seed);
        ok = ok && (hub.totalQueued(address(backing)) == seed);
        ok = ok && (backing.totalSupply() + target.totalSupply() == sumSupplyBefore);

        // Step C: settlement should not burn the netted portion again
        uint256 supplyBackingBeforeSettle = backing.totalSupply();
        hub.processSettlementFor(address(backing), address(hub), net);
        ok = ok && (hub.settleQueue(address(backing), address(hub)) == seed - net);
        ok = ok && (hub.totalQueued(address(backing)) == seed - net);
        ok = ok && (backing.totalSupply() == supplyBackingBeforeSettle);

        lastNettingOk = ok;
    }

    // -------------------------------------------------------------------------
    // Properties (property-mode compatibility)
    // -------------------------------------------------------------------------

    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_wrapWith_conserves_clean() external view returns (bool) {
        return !checkedConserve || lastConserveOk;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_wrapWith_queue_netting_no_double_burn() external view returns (bool) {
        return !checkedNetting || lastNettingOk;
    }

    // Always-on safety: reserve accounting for native must be <= actual hub ETH.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_hub05_reserve_never_exceeds_hub_balance() external view returns (bool) {
        uint256 reserve = hub.reserveOfUnderlying(address(lccA));
        return reserve <= address(hub).balance;
    }
}

/// @dev Non-protocol holder used to isolate queue side effects.
contract LiquidityHubWrapWith_Holder {
    function approve(address token, address spender) external {
        // best-effort approve (ignore failure)
        token.call(abi.encodeWithSignature("approve(address,uint256)", spender, type(uint256).max));
    }

    function wrapWith(address hub, address target, address backing, uint256 amount) external returns (bool ok) {
        (ok,) = hub.call(abi.encodeWithSignature("wrapWith(address,address,uint256)", target, backing, amount));
    }
}

