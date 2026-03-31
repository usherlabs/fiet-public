// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {LiquidityHub} from "../../../src/LiquidityHub.sol";
import {LiquidityCommitmentCertificate} from "../../../src/LCC.sol";
import {VTSCommitLib} from "../../../src/libraries/VTSCommitLib.sol";
import {PositionId} from "../../../src/types/Position.sol";
import {MockOracleHelper} from "../mocks/MockOracleHelper.sol";
import {MockERC20Transferable} from "../mocks/MockERC20Transferable.sol";
import {VTSCommitLibHarness} from "../../libraries/harnesses/VTSCommitLibHarness.sol";
import {Bounds} from "../../../src/libraries/Bounds.sol";
import {EchidnaLinkedLibs} from "../base/EchidnaLinkedLibs.sol";
import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice Incremental Echidna harness for `LCC-BACKING-01`.
/// @dev Milestone 1 proves direct unauthorised mint/burn into `LCC` cannot succeed.
///      Milestone 2 adds a tracked market so we can model the two basic mint surfaces
///      already reachable here: wrapped (hub-reserved) supply and issuer-created market supply.
contract LCCBacking01 {
    uint256 internal constant INITIAL_MARKET_BALANCE = 1e18;
    uint256 internal constant MAX_ACTION_AMOUNT = 1e24;

    // Dummy currencies for VRL commitment gate evaluation (oracle mock ignores addresses).
    address internal constant COMMITMENT_LCC0 = address(0x1000000000000000000000000000000000000001);
    address internal constant COMMITMENT_LCC1 = address(0x1000000000000000000000000000000000000002);
    uint256 internal constant COMMIT_ID = 1;

    // ----- Core protocol objects under test -----
    LiquidityHub internal hub;
    LiquidityCommitmentCertificate internal lccNative;
    LiquidityCommitmentCertificate internal lccTracked;
    LiquidityCommitmentCertificate internal lccConvA;
    LiquidityCommitmentCertificate internal lccConvB;
    MockERC20Transferable internal trackedUnderlying;
    MockERC20Transferable internal conversionUnderlying;
    LCCBacking01Holder internal queueHolder;

    // ----- Milestone 1: direct unauthorised call results -----
    bool internal lastDirectMintOk;
    bool internal lastDirectBurnOk;

    // ----- Milestone 2/3: harness-side model for tracked market -----
    uint256 internal expectedWrapped;
    uint256 internal expectedMarketDerived;
    uint256 internal expectedHolderMarketDerived;
    uint256 internal expectedHolderQueued;
    uint256 internal expectedMarketReserve;

    // ----- VRL commitment backing gate (issuedUsd <= settledUsd + signalUsd) -----
    MockOracleHelper internal commitOracle;
    VTSCommitLibHarness internal commitHarness;
    PositionId internal commitPositionId;

    // Harness-side model variables (independently tracked, not read from library).
    uint256 internal vrlSignalUsd;
    uint256 internal positionSettled0;
    uint256 internal positionSettled1;

    // Liquidity-shape inputs (stored so the always-on property can re-evaluate).
    uint160 internal sqrtPriceX96;
    int24 internal currentTick;
    int24 internal tickLower;
    int24 internal tickUpper;
    int256 internal liquidityDelta;

    // Action/result cache for the dual-mode commitment gate check.
    bool internal commitGateChecked;
    bool internal commitGateLastOk;

    // ================================================================
    // Helpers
    // ================================================================

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
        MockERC20Transferable other = new MockERC20Transferable();
        (address l0, address l1) = hub.createLCCPair(marketRef, address(0), address(other), marketName, issuers);
        hub.initialize(l0, l1, marketId, marketRef);
        address underlying0 = hub.getUnderlying(l0);
        nativeLcc = LiquidityCommitmentCertificate(underlying0 == address(0) ? l0 : l1);
    }

    function _createInitTrackedMarket(
        bytes memory marketRef,
        bytes32 marketId,
        string memory marketName,
        address[] memory issuers
    ) internal returns (LiquidityCommitmentCertificate trackedLcc) {
        trackedUnderlying = new MockERC20Transferable();
        MockERC20Transferable other = new MockERC20Transferable();
        (address l0, address l1) =
            hub.createLCCPair(marketRef, address(trackedUnderlying), address(other), marketName, issuers);
        hub.initialize(l0, l1, marketId, marketRef);
        address underlying0 = hub.getUnderlying(l0);
        trackedLcc = LiquidityCommitmentCertificate(underlying0 == address(trackedUnderlying) ? l0 : l1);
    }

    function _createInitConversionMarket(
        bytes memory marketRef,
        bytes32 marketId,
        string memory marketName,
        address[] memory issuers
    ) internal returns (LiquidityCommitmentCertificate conversionLcc) {
        MockERC20Transferable other = new MockERC20Transferable();
        (address l0, address l1) =
            hub.createLCCPair(marketRef, address(conversionUnderlying), address(other), marketName, issuers);
        hub.initialize(l0, l1, marketId, marketRef);
        address underlying0 = hub.getUnderlying(l0);
        conversionLcc = LiquidityCommitmentCertificate(underlying0 == address(conversionUnderlying) ? l0 : l1);
    }

    function _boundAmount(uint256 amount) internal pure returns (uint256) {
        return (amount % MAX_ACTION_AMOUNT) + 1;
    }

    function _checkDirectMint(uint256 amt) internal returns (bool ok) {
        (ok,) = address(lccNative).call(abi.encodeWithSignature("mint(address,uint256,uint256)", address(this), amt, 0));
    }

    function _checkDirectBurn(uint256 amt) internal returns (bool ok) {
        (ok,) = address(lccNative).call(abi.encodeWithSignature("burn(address,uint256,uint256)", address(this), 0, amt));
    }

    // ================================================================
    // VRL commitment gate helpers
    // ================================================================

    function _normalisePositionShape(
        uint160 _sqrtPriceX96,
        int24 _currentTick,
        int24 _tickLower,
        int24 _tickUpper,
        int256 _liquidityDelta
    ) internal pure returns (uint160 sp, int24 ct, int24 tl, int24 tu, int256 ld) {
        sp = _sqrtPriceX96;
        if (sp <= TickMath.MIN_SQRT_PRICE) sp = TickMath.MIN_SQRT_PRICE + 1;
        if (sp >= TickMath.MAX_SQRT_PRICE) sp = TickMath.MAX_SQRT_PRICE - 1;

        tl = _tickLower;
        tu = _tickUpper;
        ct = _currentTick;
        if (tl < TickMath.MIN_TICK) tl = TickMath.MIN_TICK;
        if (tu > TickMath.MAX_TICK) tu = TickMath.MAX_TICK;
        if (ct < TickMath.MIN_TICK) ct = TickMath.MIN_TICK;
        if (ct > TickMath.MAX_TICK) ct = TickMath.MAX_TICK;
        if (tl >= tu) {
            tl = -60;
            tu = 60;
        }

        uint256 absL;
        if (_liquidityDelta == type(int256).min) {
            absL = 1;
        } else {
            int256 v = _liquidityDelta < 0 ? -_liquidityDelta : _liquidityDelta;
            absL = uint256(v);
        }
        ld = int256((absL % 1e18) + 1);
    }

    function _setPositionShape(
        uint160 _sqrtPriceX96,
        int24 _currentTick,
        int24 _tickLower,
        int24 _tickUpper,
        int256 _liquidityDelta
    ) internal {
        (sqrtPriceX96, currentTick, tickLower, tickUpper, liquidityDelta) = _normalisePositionShape(
            _sqrtPriceX96, _currentTick, _tickLower, _tickUpper, _liquidityDelta
        );
    }

    /// @dev Builds the LiquidityDeltaParams from current stored position shape.
    function _buildLiquidityDeltaParams() internal view returns (VTSCommitLib.LiquidityDeltaParams memory p) {
        p = VTSCommitLib.LiquidityDeltaParams({
            currency0: Currency.wrap(COMMITMENT_LCC0),
            currency1: Currency.wrap(COMMITMENT_LCC1),
            sqrtPriceX96: sqrtPriceX96,
            currentTick: currentTick,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: liquidityDelta
        });
    }

    /// @dev Dual-mode commitment gate check (mirrors VTSCommit01SigBackingEchidnaTest).
    ///      Returns true when the library's soft-mode and hard-mode results are consistent
    ///      AND the returned signal value matches our independently tracked model variable.
    function _evaluateCommitmentGate() internal view returns (bool ok) {
        VTSCommitLib.LiquidityDeltaParams memory p = _buildLiquidityDeltaParams();

        // --- Soft mode: non-reverting, get all returned values ---
        bool success;
        uint256 issuedUsd;
        uint256 settledUsd;
        uint256 signalUsd;

        try commitHarness.validateLiquidityDelta(commitOracle, COMMIT_ID, commitPositionId, p, false) returns (
            bool sOk, uint256 iUsd, uint256 stUsd, uint256 siUsd
        ) {
            success = sOk;
            issuedUsd = iUsd;
            settledUsd = stUsd;
            signalUsd = siUsd;
        } catch {
            return false;
        }

        // Non-tautological check 1: the library's returned signal value must equal
        // the oracle mock value we independently track.  This verifies the library
        // correctly reads commit state → reserves → oracle.getTotalValue().
        if (signalUsd != vrlSignalUsd) return false;

        // Self-consistency: library's success flag must match its own returned values.
        // This catches arithmetic bugs (overflow / rounding) inside the library.
        bool shouldPass = issuedUsd <= (settledUsd + signalUsd);
        if (success != shouldPass) return false;

        // --- Hard mode: reverting mode must agree with soft mode ---
        bool hardReverted;
        try commitHarness.validateLiquidityDelta(commitOracle, COMMIT_ID, commitPositionId, p, true) {
            hardReverted = false;
        } catch {
            hardReverted = true;
        }
        if (hardReverted == success) return false;

        return true;
    }

    /// @dev Always-on view-mode evaluation using stored position shape and the independent model.
    ///      Checks a strictly non-tautological boundary condition: if our model says
    ///      backing == 0, the library must say success == false.
    function _evaluateCommitmentGateBoundary() internal view returns (bool ok) {
        VTSCommitLib.LiquidityDeltaParams memory p = _buildLiquidityDeltaParams();

        bool success;
        uint256 issuedUsd;
        uint256 signalUsd;

        try commitHarness.validateLiquidityDelta(commitOracle, COMMIT_ID, commitPositionId, p, false) returns (
            bool sOk, uint256 iUsd, uint256, uint256 siUsd
        ) {
            success = sOk;
            issuedUsd = iUsd;
            signalUsd = siUsd;
        } catch {
            return false;
        }

        // Signal must match our model.
        if (signalUsd != vrlSignalUsd) return false;

        // When issuedUsd == 0 (degenerate shape), any success value is fine — skip further checks.
        if (issuedUsd == 0) return true;

        // Non-tautological boundary: zero backing must reject positive issuance.
        if (vrlSignalUsd == 0 && positionSettled0 == 0 && positionSettled1 == 0) {
            return !success;
        }

        // Non-tautological boundary: if signal alone covers issuance, gate must accept.
        if (signalUsd >= issuedUsd) {
            return success;
        }

        return true;
    }

    // ================================================================
    // Constructor
    // ================================================================

    constructor() {
        EchidnaLinkedLibs.deployLCCFactoryLinkedLib();
        EchidnaLinkedLibs.deployLiquidityHubLinkedLib();
        EchidnaLinkedLibs.deployVTSCommitLib();

        MockOracleHelper oracleHelper = new MockOracleHelper(address(0xB0B));
        hub = new LiquidityHub(address(oracleHelper), "Ether", "ETH", 18, address(this));
        hub.setFactory(address(this), true);
        hub.setBoundLevel(address(hub), Bounds.BOUND_EXEMPT);

        address[] memory issuers = _initIssuers();
        lccNative = _createInitNativeMarket(abi.encodePacked(address(this)), bytes32(uint256(1)), "TEST", issuers);
        lccTracked = _createInitTrackedMarket(
            abi.encodePacked(address(this), bytes1(0x01)), bytes32(uint256(2)), "TRACK", issuers
        );
        conversionUnderlying = new MockERC20Transferable();
        lccConvA = _createInitConversionMarket(
            abi.encodePacked(address(this), bytes1(0x02)), bytes32(uint256(3)), "CONV_A", issuers
        );
        lccConvB = _createInitConversionMarket(
            abi.encodePacked(address(this), bytes1(0x03)), bytes32(uint256(4)), "CONV_B", issuers
        );
        queueHolder = new LCCBacking01Holder();

        hub.issue(address(lccNative), address(this), INITIAL_MARKET_BALANCE);
        lastDirectMintOk = _checkDirectMint(1);
        lastDirectBurnOk = _checkDirectBurn(1);

        trackedUnderlying.approve(address(hub), type(uint256).max);
        hub.issue(address(lccTracked), address(this), INITIAL_MARKET_BALANCE);
        expectedMarketDerived = INITIAL_MARKET_BALANCE;

        // VRL commitment gate harness (same pattern as VTSCommit01SigBackingEchidnaTest).
        commitOracle = new MockOracleHelper(address(0));
        commitOracle.setPrices(1e18, 1e18);
        vrlSignalUsd = 1e36;
        commitOracle.setTotalValue(vrlSignalUsd);

        commitHarness = new VTSCommitLibHarness();
        commitPositionId = PositionId.wrap(keccak256("echidna.lcc-backing-01.commitment"));
        commitHarness.setCommitExpiresAt(COMMIT_ID, block.timestamp + 365 days);

        _setPositionShape(uint160(1) << 96, 0, -60, 60, 1);

        commitGateChecked = true;
        commitGateLastOk = _evaluateCommitmentGate();
    }

    /// @dev Deterministic no-liquidity factory callback for market-derived unwrap paths.
    function useMarketLiquidity(address, bytes32, uint256) external view returns (uint256 used) {
        if (msg.sender != address(hub)) revert();
        return 0;
    }

    // ================================================================
    // Actions — onlyHub guard (unauthorised mint/burn)
    // ================================================================

    // forge-lint: disable-next-line(mixed-case-function)
    function action_lcc_backing_01_try_direct_mint(uint256 amount) external {
        uint256 amt = _boundAmount(amount);
        lastDirectMintOk = _checkDirectMint(amt);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function action_lcc_backing_01_try_direct_burn(uint256 amount) external {
        uint256 bal = lccNative.balanceOf(address(this));
        if (bal == 0) return;

        uint256 amt = (amount % bal) + 1;
        lastDirectBurnOk = _checkDirectBurn(amt);
    }

    // ================================================================
    // Actions — wrap / issue / cancel (hub-reserved and market-derived supply)
    // ================================================================

    // forge-lint: disable-next-line(mixed-case-function)
    function action_lcc_backing_01_wrap(uint256 amount) external {
        uint256 amt = _boundAmount(amount);
        trackedUnderlying.mint(address(this), amt);
        hub.wrap(address(lccTracked), amt);
        expectedWrapped += amt;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function action_lcc_backing_01_issue(uint256 amount) external {
        uint256 amt = _boundAmount(amount);
        hub.issue(address(lccTracked), address(this), amt);
        expectedMarketDerived += amt;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function action_lcc_backing_01_cancel(uint256 amount) external {
        (, uint256 marketDerived) = lccTracked.balancesOf(address(this));
        if (marketDerived == 0) return;

        uint256 amt = (amount % marketDerived) + 1;
        hub.cancel(address(lccTracked), address(this), amt);
        expectedMarketDerived -= amt;
    }

    // ================================================================
    // Actions — settlement queue (unwrapTo queue, confirmTake, processSettlementFor)
    // ================================================================

    // forge-lint: disable-next-line(mixed-case-function)
    function action_lcc_backing_01_queue_settlement_claim(uint256 amount) external {
        uint256 amt = _boundAmount(amount);
        hub.issue(address(lccTracked), address(queueHolder), amt);
        expectedHolderMarketDerived += amt;
        if (queueHolder.unwrapToQueue(address(hub), address(lccTracked), amt)) {
            expectedHolderQueued += amt;
        }
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function action_lcc_backing_01_confirm_take(uint256 amount) external {
        uint256 amt = _boundAmount(amount);
        trackedUnderlying.mint(address(hub), amt);
        hub.confirmTake(address(lccTracked), amt, false);
        expectedMarketReserve += amt;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function action_lcc_backing_01_process_settlement(uint256 amount) external {
        uint256 queuedBefore = hub.settleQueue(address(lccTracked), address(queueHolder));
        if (queuedBefore == 0) return;
        (, uint256 marketReserve) = hub.reserveOfUnderlyingTuple(address(lccTracked));
        if (marketReserve == 0) return;

        uint256 maxAmount = (amount % queuedBefore) + 1;
        hub.processSettlementFor(address(lccTracked), address(queueHolder), maxAmount);

        uint256 queuedAfter = hub.settleQueue(address(lccTracked), address(queueHolder));
        uint256 settled = queuedBefore - queuedAfter;
        expectedHolderQueued -= settled;
        expectedHolderMarketDerived -= settled;
        expectedMarketReserve -= settled;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function action_lcc_backing_01_wrapwith(uint256 amount, bool towardB) external {
        LiquidityCommitmentCertificate target = towardB ? lccConvB : lccConvA;
        LiquidityCommitmentCertificate backing = towardB ? lccConvA : lccConvB;

        if (hub.totalQueued(address(target)) != 0) return;
        if (hub.totalQueued(address(backing)) != 0) return;

        uint256 amt = _boundAmount(amount);
        LCCBacking01Holder holder = new LCCBacking01Holder();

        hub.issue(address(backing), address(holder), amt);
        holder.approve(address(backing), address(hub));
        holder.wrapWith(address(hub), address(target), address(backing), amt);
    }

    // ================================================================
    // Actions — VRL commitment backing gate (oracle prices, signal, settled, position shape)
    // ================================================================

    // forge-lint: disable-next-line(mixed-case-function)
    function action_lcc_backing_01_set_oracle_prices(uint256 p0, uint256 p1) external {
        uint256 c0 = p0 == 0 ? 1 : (p0 > 1e30 ? 1e30 : p0);
        uint256 c1 = p1 == 0 ? 1 : (p1 > 1e30 ? 1e30 : p1);
        commitOracle.setPrices(c0, c1);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function action_lcc_backing_01_set_vrl_signal(uint256 signalUsd) external {
        vrlSignalUsd = signalUsd > 1e36 ? 1e36 : signalUsd;
        commitOracle.setTotalValue(vrlSignalUsd);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function action_lcc_backing_01_set_position_settled(uint256 settled0, uint256 settled1) external {
        uint256 a0 = settled0 > 1e36 ? 1e36 : settled0;
        uint256 a1 = settled1 > 1e36 ? 1e36 : settled1;
        positionSettled0 = a0;
        positionSettled1 = a1;
        commitHarness.setPositionSettled(commitPositionId, a0, a1);
    }

    /// @dev Mutate position shape + execute the dual-mode commitment gate check.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_lcc_backing_01_validate_commitment_gate(
        uint160 _sqrtPriceX96,
        int24 _currentTick,
        int24 _tickLower,
        int24 _tickUpper,
        int256 _liquidityDelta
    ) external {
        _setPositionShape(_sqrtPriceX96, _currentTick, _tickLower, _tickUpper, _liquidityDelta);
        commitGateChecked = true;
        commitGateLastOk = _evaluateCommitmentGate();
    }

    // ================================================================
    // Properties — onlyHub guard
    // ================================================================

    /// @dev No account other than the Hub may mint directly on LCC.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_lcc_backing_01_no_unauthorised_mint() external view returns (bool) {
        return lastDirectMintOk == false;
    }

    /// @dev No account other than the Hub may burn directly on LCC.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_lcc_backing_01_no_unauthorised_burn() external view returns (bool) {
        return lastDirectBurnOk == false;
    }

    // ================================================================
    // Properties — wrap / issue / cancel supply model
    // ================================================================

    /// @dev Total LCC supply must equal the harness model of wrapped + market-derived supply.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_lcc_backing_01_total_supply_matches_model() external view returns (bool) {
        return lccTracked.totalSupply() == expectedWrapped + expectedMarketDerived + expectedHolderMarketDerived;
    }

    /// @dev Hub direct reserve must match exactly the total underlying deposited via wrap.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_lcc_backing_01_direct_reserve_matches_wrapped() external view returns (bool) {
        (uint256 directReserve,) = hub.reserveOfUnderlyingTuple(address(lccTracked));
        return directReserve == expectedWrapped;
    }

    /// @dev Per-holder wrapped/market-derived bucket split must match the harness model.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_lcc_backing_01_holder_balances_match_model() external view returns (bool) {
        (uint256 wrapped, uint256 marketDerived) = lccTracked.balancesOf(address(this));
        return wrapped == expectedWrapped && marketDerived == expectedMarketDerived;
    }

    // ================================================================
    // Properties — settlement queue and reserve accounting
    // ================================================================

    /// @dev Hub reserve tuple must reflect direct wraps and explicit market reserve funding.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_lcc_backing_01_reserve_tuple_matches_model() external view returns (bool) {
        (uint256 directReserve, uint256 marketReserve) = hub.reserveOfUnderlyingTuple(address(lccTracked));
        return directReserve == expectedWrapped && marketReserve == expectedMarketReserve;
    }

    /// @dev Queued external claims stay represented as both queue debt and holder market-derived balance.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_lcc_backing_01_settle_queue_matches_model() external view returns (bool) {
        if (hub.settleQueue(address(lccTracked), address(queueHolder)) != expectedHolderQueued) return false;
        if (hub.totalQueued(address(lccTracked)) != expectedHolderQueued) return false;
        if (hub.queueOfUnderlying(address(lccTracked)) != expectedHolderQueued) return false;

        (uint256 wrapped, uint256 marketDerived) = lccTracked.balancesOf(address(queueHolder));
        return wrapped == 0 && marketDerived == expectedHolderMarketDerived;
    }

    /// @dev wrapWith conversion-pair supply must always be fully represented as Hub-held LCC or queue debt.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_lcc_backing_01_wrapwith_conserves_backing() external view returns (bool) {
        uint256 totalSupply = lccConvA.totalSupply() + lccConvB.totalSupply();
        uint256 hubHeld = lccConvA.balanceOf(address(hub)) + lccConvB.balanceOf(address(hub));
        uint256 totalQueued = hub.totalQueued(address(lccConvA)) + hub.totalQueued(address(lccConvB));
        (uint256 directReserve, uint256 marketReserve) = hub.reserveOfUnderlyingTuple(address(lccConvA));
        return totalSupply == hubHeld + totalQueued && directReserve == 0 && marketReserve == 0;
    }

    // ================================================================
    // Properties — VRL commitment backing gate
    // ================================================================

    /// @dev Action/result gate: validateLiquidityDelta soft + hard modes must be consistent
    ///      and the returned signal value must match our independently tracked VRL signal.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_lcc_backing_01_commitment_gate_consistent() external view returns (bool) {
        return !commitGateChecked || commitGateLastOk;
    }

    /// @dev Always-on boundary: with zero backing our model predicts rejection,
    ///      and with sufficient VRL signal our model predicts acceptance.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_lcc_backing_01_commitment_gate_boundary() external view returns (bool) {
        return _evaluateCommitmentGateBoundary();
    }
}

contract LCCBacking01Holder {
    function approve(address token, address spender) external {
        token.call(abi.encodeWithSignature("approve(address,uint256)", spender, type(uint256).max));
    }

    function unwrapToQueue(address hub, address lcc, uint256 amount) external returns (bool ok) {
        (ok,) = hub.call(
            abi.encodeWithSignature(
                "unwrapTo(address,address,address,uint256)", lcc, address(this), address(this), amount
            )
        );
    }

    function wrapWith(address hub, address target, address backing, uint256 amount) external returns (bool ok) {
        (ok,) = hub.call(abi.encodeWithSignature("wrapWith(address,address,uint256)", target, backing, amount));
    }
}
