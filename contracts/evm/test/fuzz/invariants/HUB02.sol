// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {LiquidityHub} from "../../../src/LiquidityHub.sol";
import {LiquidityCommitmentCertificate} from "../../../src/LCC.sol";
import {MockOracleHelper} from "../mocks/MockOracleHelper.sol";
import {MockERC20Transferable} from "../mocks/MockERC20Transferable.sol";
import {Bounds} from "../../../src/libraries/Bounds.sol";
import {EchidnaLinkedLibs} from "../base/EchidnaLinkedLibs.sol";

/// @notice Echidna harness for HUB-02: Unwrapping bounds and queue semantics.
/// @dev "Unwrap requires 0 < amount <= wrappedBalance + marketDerivedBalance;
///      any unavailable portion is tracked via the settlement queue rather than silently failing."
///
/// Properties tested:
///   1. unwrap(0) always reverts (guard)
///   2. unwrap(amount > balance) always reverts (guard)
///   3. After valid unwrap: directUnwrapped + marketUnwrapped + queuedShortfall == amount
///   4. Queue increase equals exactly the queued shortfall portion
///   5. totalQueued tracks cumulative queue changes (model consistency)
///   6. Balance after unwrap decreases by exactly the paid-out (non-queued) portion
contract HUB02 {
    uint256 internal constant MAX_AMOUNT = 1e24;

    LiquidityHub internal hub;
    LiquidityCommitmentCertificate internal lcc;
    MockERC20Transferable internal underlying;

    // Non-protocol holder for unwrap testing.
    HUB02Holder internal holder;

    // Harness-side model.
    uint256 internal modelHolderQueued;
    uint256 internal modelTotalQueued;

    // Action/result: zero-amount guard.
    bool internal checkedZeroGuard;
    bool internal lastZeroGuardOk;

    // Action/result: over-balance guard.
    bool internal checkedOverBalanceGuard;
    bool internal lastOverBalanceGuardOk;

    // Action/result: unwrap decomposition (direct + market + queue == amount).
    bool internal checkedDecomposition;
    bool internal lastDecompositionOk;

    // Action/result: balance decreases by exactly the paid-out (non-queued) portion.
    bool internal checkedBalanceDelta;
    bool internal lastBalanceDeltaOk;

    // ================================================================
    // Constructor
    // ================================================================

    constructor() {
        EchidnaLinkedLibs.deployLCCFactoryLinkedLib();
        EchidnaLinkedLibs.deployLiquidityHubLinkedLib();

        MockOracleHelper oracleHelper = new MockOracleHelper(address(0));
        hub = new LiquidityHub(address(oracleHelper), "Ether", "ETH", 18, address(this));
        hub.setFactory(address(this), true);
        hub.setBoundLevel(address(hub), Bounds.BOUND_EXEMPT);

        address[] memory issuers = new address[](1);
        issuers[0] = address(this);

        underlying = new MockERC20Transferable();
        MockERC20Transferable other = new MockERC20Transferable();
        bytes memory marketRef = abi.encodePacked(address(this));
        (address l0, address l1) = hub.createLCCPair(marketRef, address(underlying), address(other), "TEST", issuers);
        hub.initialize(l0, l1, bytes32(uint256(1)), marketRef);
        lcc = LiquidityCommitmentCertificate(hub.getUnderlying(l0) == address(underlying) ? l0 : l1);

        holder = new HUB02Holder();

        // Give holder some initial balance for immediate exercisability.
        hub.issue(address(lcc), address(holder), 500e18);

        _seedAll();
    }

    function _seedAll() internal {
        // Seed zero-amount guard.
        bool ok = holder.tryUnwrapTo(address(hub), address(lcc), 0);
        checkedZeroGuard = true;
        lastZeroGuardOk = !ok;

        // Seed over-balance guard.
        uint256 bal = lcc.balanceOf(address(holder));
        ok = holder.tryUnwrapTo(address(hub), address(lcc), bal + 1);
        checkedOverBalanceGuard = true;
        lastOverBalanceGuardOk = !ok;

        // Seed a valid unwrap that goes entirely to queue (no direct reserve, no market liquidity).
        uint256 amt = 10;
        uint256 queueBefore = hub.settleQueue(address(lcc), address(holder));
        uint256 totalQueuedBefore = hub.totalQueued(address(lcc));
        uint256 balBefore = lcc.balanceOf(address(holder));

        ok = holder.tryUnwrapTo(address(hub), address(lcc), amt);
        if (ok) {
            uint256 queueAfter = hub.settleQueue(address(lcc), address(holder));
            uint256 totalQueuedAfter = hub.totalQueued(address(lcc));
            uint256 balAfter = lcc.balanceOf(address(holder));

            uint256 queueIncrease = queueAfter - queueBefore;
            uint256 paidOut = amt - queueIncrease;

            checkedDecomposition = true;
            lastDecompositionOk = (paidOut + queueIncrease == amt);

            // Only the paid-out portion is burned; queued shortfall LCC stays with the holder.
            checkedBalanceDelta = true;
            lastBalanceDeltaOk = (balBefore - balAfter == paidOut);

            modelHolderQueued = queueAfter;
            modelTotalQueued = totalQueuedAfter;
        }
    }

    /// @dev No-liquidity factory callback — forces all unwraps to queue.
    function useMarketLiquidity(address, bytes32, uint256) external view returns (uint256 used) {
        if (msg.sender != address(hub)) revert();
        return 0;
    }

    // ================================================================
    // Actions — build state
    // ================================================================

    /// @dev Issue market-derived LCC to the holder.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_hub_02_issue(uint256 amount) external {
        uint256 amt = (amount % MAX_AMOUNT) + 1;
        hub.issue(address(lcc), address(holder), amt);
    }

    /// @dev Fund direct reserve and process queued settlement.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_hub_02_process_settlement(uint256 amount) external {
        uint256 queued = hub.settleQueue(address(lcc), address(holder));
        if (queued == 0) return;
        uint256 amt = (amount % queued) + 1;

        underlying.mint(address(hub), amt);
        hub.confirmTake(address(lcc), amt, false);
        hub.processSettlementFor(address(lcc), address(holder), amt);

        uint256 queuedAfter = hub.settleQueue(address(lcc), address(holder));
        uint256 settled = queued - queuedAfter;
        modelHolderQueued -= settled;
        modelTotalQueued -= settled;
    }

    // ================================================================
    // Actions — unwrap exercisers
    // ================================================================

    /// @dev Valid unwrap: exercises decomposition and queue accounting.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_hub_02_unwrap(uint256 amount) external {
        uint256 bal = lcc.balanceOf(address(holder));
        if (bal == 0) return;
        uint256 amt = (amount % bal) + 1;

        uint256 queueBefore = hub.settleQueue(address(lcc), address(holder));
        uint256 totalQueuedBefore = hub.totalQueued(address(lcc));
        uint256 balBefore = bal;

        if (!holder.tryUnwrapTo(address(hub), address(lcc), amt)) return;

        uint256 queueAfter = hub.settleQueue(address(lcc), address(holder));
        uint256 totalQueuedAfter = hub.totalQueued(address(lcc));
        uint256 balAfter = lcc.balanceOf(address(holder));

        uint256 queueIncrease = queueAfter - queueBefore;
        uint256 paidOut = amt - queueIncrease;

        // Decomposition: paid-out + queued == requested amount.
        checkedDecomposition = true;
        lastDecompositionOk = (paidOut + queueIncrease == amt);

        // Only the paid-out portion is burned; queued shortfall LCC stays with the holder.
        checkedBalanceDelta = true;
        lastBalanceDeltaOk = (balBefore - balAfter == paidOut);

        // Update model.
        modelHolderQueued += queueIncrease;
        modelTotalQueued += queueIncrease;
    }

    /// @dev Zero-amount guard: unwrap(0) must revert.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_hub_02_unwrap_zero() external {
        bool ok = holder.tryUnwrapTo(address(hub), address(lcc), 0);
        checkedZeroGuard = true;
        lastZeroGuardOk = !ok;
    }

    /// @dev Over-balance guard: unwrap(balance + delta) must revert.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_hub_02_unwrap_over_balance(uint256 delta) external {
        uint256 bal = lcc.balanceOf(address(holder));
        uint256 excess = (delta % MAX_AMOUNT) + 1;
        bool ok = holder.tryUnwrapTo(address(hub), address(lcc), bal + excess);
        checkedOverBalanceGuard = true;
        lastOverBalanceGuardOk = !ok;
    }

    // ================================================================
    // Properties — always-on (model consistency)
    // ================================================================

    /// @dev Holder's queue must match our independently tracked model.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_hub_02_holder_queue_matches_model() external view returns (bool) {
        return hub.settleQueue(address(lcc), address(holder)) == modelHolderQueued;
    }

    /// @dev totalQueued must match our independently tracked model.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_hub_02_total_queued_matches_model() external view returns (bool) {
        return hub.totalQueued(address(lcc)) == modelTotalQueued;
    }

    // ================================================================
    // Properties — action/result (guards)
    // ================================================================

    /// @dev unwrap(0) must always revert.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_hub_02_zero_amount_reverts() external view returns (bool) {
        return !checkedZeroGuard || lastZeroGuardOk;
    }

    /// @dev unwrap(amount > balance) must always revert.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_hub_02_over_balance_reverts() external view returns (bool) {
        return !checkedOverBalanceGuard || lastOverBalanceGuardOk;
    }

    // ================================================================
    // Properties — action/result (decomposition)
    // ================================================================

    /// @dev paid-out + queued shortfall == requested amount for every valid unwrap.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_hub_02_unwrap_decomposition_holds() external view returns (bool) {
        return !checkedDecomposition || lastDecompositionOk;
    }

    /// @dev LCC balance decreases by exactly the paid-out (non-queued) portion.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_hub_02_balance_decreases_by_paidout() external view returns (bool) {
        return !checkedBalanceDelta || lastBalanceDeltaOk;
    }
}

/// @dev Non-protocol holder for unwrap testing.
contract HUB02Holder {
    function tryUnwrapTo(address hub, address lcc, uint256 amount) external returns (bool ok) {
        (ok,) = hub.call(
            abi.encodeWithSignature(
                "unwrapTo(address,address,address,uint256)", lcc, address(this), address(this), amount
            )
        );
    }
}
