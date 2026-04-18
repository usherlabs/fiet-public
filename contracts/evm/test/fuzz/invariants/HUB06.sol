// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {LiquidityHub} from "../../../src/LiquidityHub.sol";
import {LiquidityCommitmentCertificate} from "../../../src/LCC.sol";
import {MockOracleHelper} from "../mocks/MockOracleHelper.sol";
import {MockERC20Transferable} from "../mocks/MockERC20Transferable.sol";
import {Bounds} from "../../../src/libraries/Bounds.sol";
import {FuzzLinkedLibs} from "../base/FuzzLinkedLibs.sol";

/// @notice fuzz harness for HUB-06: prepareSettle must preserve direct-liquidity accounting consistency.
/// @dev "Preparing direct liquidity for vault settlement must reduce both
///      reserveOfUnderlying[underlying].direct and directSupply[lcc] by the same amount."
///
/// Properties tested:
///   1. After prepareSettle, both counters decrease by exactly the requested amount (model consistency)
///   2. prepareSettle(0) always reverts
///   3. prepareSettle(amount > min(reserveDirect, directSupply)) always reverts
///   4. directSupply never exceeds reserveOfUnderlying.direct (always-on drift check)
contract HUB06 {
    uint256 internal constant MAX_AMOUNT = 1e24;

    LiquidityHub internal hub;
    LiquidityCommitmentCertificate internal lcc;
    MockERC20Transferable internal underlying;

    // Harness-side models.
    uint256 internal modelDirectSupply;
    uint256 internal modelReserveDirect;

    // Action/result: prepareSettle decrements both counters correctly.
    bool internal checkedSettle;
    bool internal lastSettleOk;

    // Action/result: zero-amount guard.
    bool internal checkedZeroGuard;
    bool internal lastZeroGuardOk;

    // Action/result: over-limit guard.
    bool internal checkedOverLimitGuard;
    bool internal lastOverLimitGuardOk;

    // ================================================================
    // Constructor
    // ================================================================

    constructor() {
        FuzzLinkedLibs.deployLCCFactoryLinkedLib();
        FuzzLinkedLibs.deployLiquidityHubLinkedLib();

        MockOracleHelper oracleHelper = new MockOracleHelper(address(0));
        hub = new LiquidityHub(address(oracleHelper), "Ether", "ETH", 18, address(0), address(this));
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

        // Approve hub to pull ERC20 underlying for wrap.
        underlying.approve(address(hub), type(uint256).max);

        _seedAll();
    }

    function _seedAll() internal {
        // Wrap 100 units to build both directSupply and reserveDirect.
        uint256 wrapAmt = 100;
        underlying.mint(address(this), wrapAmt);
        hub.wrap(address(lcc), wrapAmt);
        modelDirectSupply = wrapAmt;
        modelReserveDirect = wrapAmt;

        // Seed zero-amount guard.
        (bool ok,) =
            address(hub).call(abi.encodeWithSignature("prepareSettle(address,uint256)", address(lcc), uint256(0)));
        checkedZeroGuard = true;
        lastZeroGuardOk = !ok;

        // Seed over-limit guard: try to settle more than available.
        ok = _tryPrepareSettle(wrapAmt + 1);
        checkedOverLimitGuard = true;
        lastOverLimitGuardOk = !ok;

        // Seed valid prepareSettle: settle 10 units.
        uint256 settleAmt = 10;
        (uint256 directBefore,) = hub.reserveOfUnderlyingTuple(address(lcc));
        uint256 dsBefore = hub.directSupply(address(lcc));

        hub.prepareSettle(address(lcc), settleAmt);

        (uint256 directAfter,) = hub.reserveOfUnderlyingTuple(address(lcc));
        uint256 dsAfter = hub.directSupply(address(lcc));

        checkedSettle = true;
        lastSettleOk = (directBefore - directAfter == settleAmt) && (dsBefore - dsAfter == settleAmt);

        modelDirectSupply -= settleAmt;
        modelReserveDirect -= settleAmt;
    }

    function _tryPrepareSettle(uint256 amount) internal returns (bool ok) {
        (ok,) = address(hub).call(abi.encodeWithSignature("prepareSettle(address,uint256)", address(lcc), amount));
    }

    /// @dev No-liquidity factory callback.
    function useMarketLiquidity(address, bytes32, uint256) external view returns (uint256) {
        if (msg.sender != address(hub)) revert();
        return 0;
    }

    // ================================================================
    // Actions
    // ================================================================

    /// @dev Wrap ERC20 to build directSupply and reserveDirect.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_hub_06_wrap(uint256 amount) external {
        uint256 amt = (amount % MAX_AMOUNT) + 1;
        underlying.mint(address(this), amt);
        hub.wrap(address(lcc), amt);
        modelDirectSupply += amt;
        modelReserveDirect += amt;
    }

    /// @dev Valid prepareSettle: verify both counters decrease by the same amount.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_hub_06_prepare_settle(uint256 amount) external {
        uint256 ds = hub.directSupply(address(lcc));
        (uint256 rd,) = hub.reserveOfUnderlyingTuple(address(lcc));
        uint256 maxSettleable = ds < rd ? ds : rd;
        if (maxSettleable == 0) return;

        uint256 amt = (amount % maxSettleable) + 1;

        (uint256 rdBefore,) = hub.reserveOfUnderlyingTuple(address(lcc));
        uint256 dsBefore = hub.directSupply(address(lcc));

        hub.prepareSettle(address(lcc), amt);

        (uint256 rdAfter,) = hub.reserveOfUnderlyingTuple(address(lcc));
        uint256 dsAfter = hub.directSupply(address(lcc));

        bool ok = (rdBefore - rdAfter == amt) && (dsBefore - dsAfter == amt);

        modelDirectSupply -= amt;
        modelReserveDirect -= amt;

        checkedSettle = true;
        lastSettleOk = ok;
    }

    /// @dev Zero-amount guard.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_hub_06_prepare_settle_zero() external {
        bool ok = _tryPrepareSettle(0);
        checkedZeroGuard = true;
        lastZeroGuardOk = !ok;
    }

    /// @dev Over-limit guard: amount exceeding min(reserveDirect, directSupply) must revert.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_hub_06_prepare_settle_over_limit(uint256 delta) external {
        uint256 ds = hub.directSupply(address(lcc));
        (uint256 rd,) = hub.reserveOfUnderlyingTuple(address(lcc));
        uint256 maxSettleable = ds < rd ? ds : rd;
        uint256 excess = (delta % MAX_AMOUNT) + 1;

        bool ok = _tryPrepareSettle(maxSettleable + excess);
        checkedOverLimitGuard = true;
        lastOverLimitGuardOk = !ok;
    }

    // ================================================================
    // Properties — always-on
    // ================================================================

    /// @dev directSupply must match our independently tracked model.
    // forge-lint: disable-next-line(mixed-case-function)
    function fuzz_hub_06_direct_supply_matches_model() external view returns (bool) {
        return hub.directSupply(address(lcc)) == modelDirectSupply;
    }

    /// @dev reserveOfUnderlying.direct must match our independently tracked model.
    // forge-lint: disable-next-line(mixed-case-function)
    function fuzz_hub_06_reserve_direct_matches_model() external view returns (bool) {
        (uint256 rd,) = hub.reserveOfUnderlyingTuple(address(lcc));
        return rd == modelReserveDirect;
    }

    // ================================================================
    // Properties — action/result
    // ================================================================

    /// @dev prepareSettle must decrement both counters by exactly the requested amount.
    // forge-lint: disable-next-line(mixed-case-function)
    function fuzz_hub_06_prepare_settle_decrements_both() external view returns (bool) {
        return !checkedSettle || lastSettleOk;
    }

    /// @dev prepareSettle(0) must always revert.
    // forge-lint: disable-next-line(mixed-case-function)
    function fuzz_hub_06_zero_amount_reverts() external view returns (bool) {
        return !checkedZeroGuard || lastZeroGuardOk;
    }

    /// @dev prepareSettle(amount > min(reserveDirect, directSupply)) must always revert.
    // forge-lint: disable-next-line(mixed-case-function)
    function fuzz_hub_06_over_limit_reverts() external view returns (bool) {
        return !checkedOverLimitGuard || lastOverLimitGuardOk;
    }
}
