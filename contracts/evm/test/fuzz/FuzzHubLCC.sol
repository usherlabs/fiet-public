// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {HUB01} from "./invariants/HUB01.sol";
import {HUB02} from "./invariants/HUB02.sol";
import {HUB03} from "./invariants/HUB03.sol";
import {HUB04} from "./invariants/HUB04.sol";
import {HUB05} from "./invariants/HUB05.sol";
import {HUB06} from "./invariants/HUB06.sol";
import {LCC01} from "./invariants/LCC01.sol";
import {LCC02} from "./invariants/LCC02.sol";
import {LCC03} from "./invariants/LCC03.sol";
import {LCCBacking01} from "./invariants/LCCBacking01.sol";
import {MKT04_04A} from "./invariants/MKT04_04A.sol";
import {LiquidityHubWrapWithFuzzTest} from "./LiquidityHubWrapWithFuzzTest.sol";
import {LiquidityHubWrapWithQueueFuzzTest} from "./LiquidityHubWrapWithQueueFuzzTest.sol";
import {LiquidityHubConfirmTakeCallbackFuzzTest} from "./LiquidityHubConfirmTakeCallbackFuzzTest.sol";

/// @notice Composed Medusa module for repo-owned Hub/LCC fuzz harnesses.
abstract contract FuzzHubLCC {
    HUB01 internal childHUB01;
    HUB02 internal childHUB02;
    HUB03 internal childHUB03;
    HUB04 internal childHUB04;
    HUB05 internal childHUB05;
    HUB06 internal childHUB06;
    LCC01 internal childLCC01;
    LCC02 internal childLCC02;
    LCC03 internal childLCC03;
    LCCBacking01 internal childLCCBacking01;
    MKT04_04A internal childMKT04_04A;
    LiquidityHubWrapWithFuzzTest internal childLiquidityHubWrapWithFuzzTest;
    LiquidityHubWrapWithQueueFuzzTest internal childLiquidityHubWrapWithQueueFuzzTest;
    LiquidityHubConfirmTakeCallbackFuzzTest internal childLiquidityHubConfirmTakeCallbackFuzzTest;

    constructor() {
        childHUB01 = new HUB01();
        childHUB02 = new HUB02();
        childHUB03 = new HUB03();
        childHUB04 = new HUB04();
        childHUB05 = new HUB05();
        childHUB06 = new HUB06();
        childLCC01 = new LCC01();
        childLCC02 = new LCC02();
        childLCC03 = new LCC03();
        childLCCBacking01 = new LCCBacking01();
        childMKT04_04A = new MKT04_04A();
        childLiquidityHubWrapWithFuzzTest = new LiquidityHubWrapWithFuzzTest();
        childLiquidityHubWrapWithQueueFuzzTest = new LiquidityHubWrapWithQueueFuzzTest();
        childLiquidityHubConfirmTakeCallbackFuzzTest = new LiquidityHubConfirmTakeCallbackFuzzTest();
    }

    function action_hub_01_wrap_native(uint256 amount) external payable {
        childHUB01.action_hub_01_wrap_native{value: msg.value}(amount);
    }

    function action_hub_01_wrapTo_native(uint256 amount) external payable {
        childHUB01.action_hub_01_wrapTo_native{value: msg.value}(amount);
    }

    function action_hub_01_wrap_erc20(uint256 amount) external {
        childHUB01.action_hub_01_wrap_erc20(amount);
    }

    function action_hub_01_wrapTo_erc20(uint256 amount) external {
        childHUB01.action_hub_01_wrapTo_erc20(amount);
    }

    function action_hub_01_wrap_erc20_by_marketId(uint256 amount) external {
        childHUB01.action_hub_01_wrap_erc20_by_marketId(amount);
    }

    function action_hub_01_native_guard_mismatch(uint256 amount, uint256 valueDelta) external payable {
        childHUB01.action_hub_01_native_guard_mismatch{value: msg.value}(amount, valueDelta);
    }

    function action_hub_01_erc20_guard_nonzero_value(uint256 amount) external payable {
        childHUB01.action_hub_01_erc20_guard_nonzero_value{value: msg.value}(amount);
    }

    function fuzz_hub_01_direct_supply_native_matches_model() external view returns (bool) {
        return childHUB01.fuzz_hub_01_direct_supply_native_matches_model();
    }

    function fuzz_hub_01_direct_supply_erc20_matches_model() external view returns (bool) {
        return childHUB01.fuzz_hub_01_direct_supply_erc20_matches_model();
    }

    function fuzz_hub_01_reserve_native_matches_model() external view returns (bool) {
        return childHUB01.fuzz_hub_01_reserve_native_matches_model();
    }

    function fuzz_hub_01_reserve_erc20_matches_model() external view returns (bool) {
        return childHUB01.fuzz_hub_01_reserve_erc20_matches_model();
    }

    function fuzz_hub_01_total_supply_native_matches_model() external view returns (bool) {
        return childHUB01.fuzz_hub_01_total_supply_native_matches_model();
    }

    function fuzz_hub_01_total_supply_erc20_matches_model() external view returns (bool) {
        return childHUB01.fuzz_hub_01_total_supply_erc20_matches_model();
    }

    function fuzz_hub_01_hub_eth_balance_covers_native_reserve() external view returns (bool) {
        return childHUB01.fuzz_hub_01_hub_eth_balance_covers_native_reserve();
    }

    function fuzz_hub_01_hub_erc20_balance_covers_erc20_reserve() external view returns (bool) {
        return childHUB01.fuzz_hub_01_hub_erc20_balance_covers_erc20_reserve();
    }

    function fuzz_hub_01_native_wrap_is_one_to_one() external view returns (bool) {
        return childHUB01.fuzz_hub_01_native_wrap_is_one_to_one();
    }

    function fuzz_hub_01_erc20_wrap_is_one_to_one() external view returns (bool) {
        return childHUB01.fuzz_hub_01_erc20_wrap_is_one_to_one();
    }

    function fuzz_hub_01_native_guard_rejects_mismatch() external view returns (bool) {
        return childHUB01.fuzz_hub_01_native_guard_rejects_mismatch();
    }

    function fuzz_hub_01_erc20_guard_rejects_value() external view returns (bool) {
        return childHUB01.fuzz_hub_01_erc20_guard_rejects_value();
    }

    function action_hub_02_issue(uint256 amount) external {
        childHUB02.action_hub_02_issue(amount);
    }

    function action_hub_02_wrap_direct(uint256 amount) external {
        childHUB02.action_hub_02_wrap_direct(amount);
    }

    function action_hub_02_set_market_liquidity_bps(uint16 bps) external {
        childHUB02.action_hub_02_set_market_liquidity_bps(bps);
    }

    function action_hub_02_process_settlement(uint256 amount) external {
        childHUB02.action_hub_02_process_settlement(amount);
    }

    function action_hub_02_unwrap(uint256 amount) external {
        childHUB02.action_hub_02_unwrap(amount);
    }

    function action_hub_02_unwrap_zero() external {
        childHUB02.action_hub_02_unwrap_zero();
    }

    function action_hub_02_unwrap_over_balance(uint256 delta) external {
        childHUB02.action_hub_02_unwrap_over_balance(delta);
    }

    function fuzz_hub_02_holder_queue_matches_model() external view returns (bool) {
        return childHUB02.fuzz_hub_02_holder_queue_matches_model();
    }

    function fuzz_hub_02_total_queued_matches_model() external view returns (bool) {
        return childHUB02.fuzz_hub_02_total_queued_matches_model();
    }

    function fuzz_hub_02_zero_amount_reverts() external view returns (bool) {
        return childHUB02.fuzz_hub_02_zero_amount_reverts();
    }

    function fuzz_hub_02_over_balance_reverts() external view returns (bool) {
        return childHUB02.fuzz_hub_02_over_balance_reverts();
    }

    function fuzz_hub_02_unwrap_decomposition_holds() external view returns (bool) {
        return childHUB02.fuzz_hub_02_unwrap_decomposition_holds();
    }

    function fuzz_hub_02_balance_decreases_by_paidout() external view returns (bool) {
        return childHUB02.fuzz_hub_02_balance_decreases_by_paidout();
    }

    function action_hub_03_issue_invalid_lcc(uint256 amount) external {
        childHUB03.action_hub_03_issue_invalid_lcc(amount);
    }

    function action_hub_03_cancel_invalid_lcc(uint256 amount) external {
        childHUB03.action_hub_03_cancel_invalid_lcc(amount);
    }

    function action_hub_03_non_issuer_issue(uint256 amount) external {
        childHUB03.action_hub_03_non_issuer_issue(amount);
    }

    function action_hub_03_non_issuer_cancel(uint256 amount) external {
        childHUB03.action_hub_03_non_issuer_cancel(amount);
    }

    function action_hub_03_non_issuer_confirmTake(uint256 amount) external {
        childHUB03.action_hub_03_non_issuer_confirmTake(amount);
    }

    function action_hub_03_valid_issuer_issue(uint256 amount) external {
        childHUB03.action_hub_03_valid_issuer_issue(amount);
    }

    function action_hub_03_valid_issuer_cancel(uint256 amount) external {
        childHUB03.action_hub_03_valid_issuer_cancel(amount);
    }

    function fuzz_hub_03_invalid_lcc_always_reverts() external view returns (bool) {
        return childHUB03.fuzz_hub_03_invalid_lcc_always_reverts();
    }

    function fuzz_hub_03_non_issuer_always_reverts() external view returns (bool) {
        return childHUB03.fuzz_hub_03_non_issuer_always_reverts();
    }

    function fuzz_hub_03_valid_issuer_succeeds() external view returns (bool) {
        return childHUB03.fuzz_hub_03_valid_issuer_succeeds();
    }

    function action_hub_04_same_market_a(bool flip) external {
        childHUB04.action_hub_04_same_market_a(flip);
    }

    function action_hub_04_same_market_b(bool flip) external {
        childHUB04.action_hub_04_same_market_b(flip);
    }

    function action_hub_04_cross_factory(uint8 combo) external {
        childHUB04.action_hub_04_cross_factory(combo);
    }

    function action_hub_04_non_lcc(bool useValidFirst) external {
        childHUB04.action_hub_04_non_lcc(useValidFirst);
    }

    function fuzz_hub_04_same_market_resolves() external view returns (bool) {
        return childHUB04.fuzz_hub_04_same_market_resolves();
    }

    function fuzz_hub_04_cross_factory_reverts() external view returns (bool) {
        return childHUB04.fuzz_hub_04_cross_factory_reverts();
    }

    function fuzz_hub_04_non_lcc_reverts() external view returns (bool) {
        return childHUB04.fuzz_hub_04_non_lcc_reverts();
    }

    function action_hub_05_fund_erc20(uint256 amount) external {
        childHUB05.action_hub_05_fund_erc20(amount);
    }

    function action_hub_05_fund_native() external payable {
        childHUB05.action_hub_05_fund_native{value: msg.value}();
    }

    function action_hub_05_wrap_erc20(uint256 amount) external {
        childHUB05.action_hub_05_wrap_erc20(amount);
    }

    function action_hub_05_set_callback_take(uint256 amount) external {
        childHUB05.action_hub_05_set_callback_take(amount);
    }

    function action_hub_05_trigger_callback_via_unwrap(uint256 amount) external {
        childHUB05.action_hub_05_trigger_callback_via_unwrap(amount);
    }

    function action_hub_05_valid_confirmTake(uint256 amount) external {
        childHUB05.action_hub_05_valid_confirmTake(amount);
    }

    function action_hub_05_valid_confirmTake_native() external payable {
        childHUB05.action_hub_05_valid_confirmTake_native{value: msg.value}();
    }

    function action_hub_05_over_balance_confirmTake(uint256 delta) external {
        childHUB05.action_hub_05_over_balance_confirmTake(delta);
    }

    function fuzz_hub_05_erc20_reserve_never_exceeds_balance() external view returns (bool) {
        return childHUB05.fuzz_hub_05_erc20_reserve_never_exceeds_balance();
    }

    function fuzz_hub_05_native_reserve_never_exceeds_balance() external view returns (bool) {
        return childHUB05.fuzz_hub_05_native_reserve_never_exceeds_balance();
    }

    function fuzz_hub_05_callback_path_reached_when_expected() external view returns (bool) {
        return childHUB05.fuzz_hub_05_callback_path_reached_when_expected();
    }

    function fuzz_hub_05_valid_take_increments_correctly() external view returns (bool) {
        return childHUB05.fuzz_hub_05_valid_take_increments_correctly();
    }

    function fuzz_hub_05_over_balance_take_reverts() external view returns (bool) {
        return childHUB05.fuzz_hub_05_over_balance_take_reverts();
    }

    function action_hub_06_wrap(uint256 amount) external {
        childHUB06.action_hub_06_wrap(amount);
    }

    function action_hub_06_prepare_settle(uint256 amount) external {
        childHUB06.action_hub_06_prepare_settle(amount);
    }

    function action_hub_06_prepare_settle_zero() external {
        childHUB06.action_hub_06_prepare_settle_zero();
    }

    function action_hub_06_prepare_settle_over_limit(uint256 delta) external {
        childHUB06.action_hub_06_prepare_settle_over_limit(delta);
    }

    function fuzz_hub_06_direct_supply_matches_model() external view returns (bool) {
        return childHUB06.fuzz_hub_06_direct_supply_matches_model();
    }

    function fuzz_hub_06_reserve_direct_matches_model() external view returns (bool) {
        return childHUB06.fuzz_hub_06_reserve_direct_matches_model();
    }

    function fuzz_hub_06_prepare_settle_decrements_both() external view returns (bool) {
        return childHUB06.fuzz_hub_06_prepare_settle_decrements_both();
    }

    function fuzz_hub_06_zero_amount_reverts() external view returns (bool) {
        return childHUB06.fuzz_hub_06_zero_amount_reverts();
    }

    function fuzz_hub_06_over_limit_reverts() external view returns (bool) {
        return childHUB06.fuzz_hub_06_over_limit_reverts();
    }

    function action_lcc_01_seed_user(uint256 amount) external {
        childLCC01.action_lcc_01_seed_user(amount);
    }

    function action_lcc_01_seed_endpoint(uint256 amount) external {
        childLCC01.action_lcc_01_seed_endpoint(amount);
    }

    function action_lcc_01_transfer_user_to_user(uint256 amount) external {
        childLCC01.action_lcc_01_transfer_user_to_user(amount);
    }

    function action_lcc_01_transfer_user_to_endpoint(uint256 amount) external {
        childLCC01.action_lcc_01_transfer_user_to_endpoint(amount);
    }

    function action_lcc_01_transfer_user_to_exempt(uint256 amount) external {
        childLCC01.action_lcc_01_transfer_user_to_exempt(amount);
    }

    function action_lcc_01_transfer_endpoint_to_user(uint256 amount) external {
        childLCC01.action_lcc_01_transfer_endpoint_to_user(amount);
    }

    function action_lcc_01_transfer_endpoint_to_endpoint(uint256 amount) external {
        childLCC01.action_lcc_01_transfer_endpoint_to_endpoint(amount);
    }

    function action_lcc_01_transfer_from_user_to_user(uint256 amount) external {
        childLCC01.action_lcc_01_transfer_from_user_to_user(amount);
    }

    function action_lcc_01_transfer_from_user_to_endpoint(uint256 amount) external {
        childLCC01.action_lcc_01_transfer_from_user_to_endpoint(amount);
    }

    function fuzz_lcc_01_user_to_user_blocked() external view returns (bool) {
        return childLCC01.fuzz_lcc_01_user_to_user_blocked();
    }

    function fuzz_lcc_01_approved_user_to_user_blocked() external view returns (bool) {
        return childLCC01.fuzz_lcc_01_approved_user_to_user_blocked();
    }

    function fuzz_lcc_01_user_to_endpoint_allowed() external view returns (bool) {
        return childLCC01.fuzz_lcc_01_user_to_endpoint_allowed();
    }

    function fuzz_lcc_01_user_to_exempt_allowed() external view returns (bool) {
        return childLCC01.fuzz_lcc_01_user_to_exempt_allowed();
    }

    function fuzz_lcc_01_endpoint_to_user_allowed() external view returns (bool) {
        return childLCC01.fuzz_lcc_01_endpoint_to_user_allowed();
    }

    function fuzz_lcc_01_endpoint_to_endpoint_allowed() external view returns (bool) {
        return childLCC01.fuzz_lcc_01_endpoint_to_endpoint_allowed();
    }

    function fuzz_lcc_01_approved_user_to_endpoint_allowed() external view returns (bool) {
        return childLCC01.fuzz_lcc_01_approved_user_to_endpoint_allowed();
    }

    function action_lcc_02_issue_to_holder(uint256 amount) external {
        childLCC02.action_lcc_02_issue_to_holder(amount);
    }

    function action_lcc_02_queue_settlement(uint256 amount) external {
        childLCC02.action_lcc_02_queue_settlement(amount);
    }

    function action_lcc_02_process_settlement(uint256 amount) external {
        childLCC02.action_lcc_02_process_settlement(amount);
    }

    function action_lcc_02_transfer_to_protocol(uint256 amount) external {
        childLCC02.action_lcc_02_transfer_to_protocol(amount);
    }

    function action_lcc_02_transfer_to_endpoint(uint256 amount) external {
        childLCC02.action_lcc_02_transfer_to_endpoint(amount);
    }

    function fuzz_lcc_02_bucket_sum_equals_balance() external view returns (bool) {
        return childLCC02.fuzz_lcc_02_bucket_sum_equals_balance();
    }

    function fuzz_lcc_02_queue_matches_model() external view returns (bool) {
        return childLCC02.fuzz_lcc_02_queue_matches_model();
    }

    function fuzz_lcc_02_transfer_annuls_queue_correctly() external view returns (bool) {
        return childLCC02.fuzz_lcc_02_transfer_annuls_queue_correctly();
    }

    function action_lcc03_no_active_sync(uint96 wrappedAmountRaw, bool useNative) external {
        childLCC03.action_lcc03_no_active_sync(wrappedAmountRaw, useNative);
    }

    function action_lcc03_revert_on_currency_mismatch(address other) external {
        childLCC03.action_lcc03_revert_on_currency_mismatch(other);
    }

    function action_lcc03_revert_on_unpaid_transfer(uint96 syncedRaw, uint96 extraRaw) external {
        childLCC03.action_lcc03_revert_on_unpaid_transfer(syncedRaw, extraRaw);
    }

    function action_lcc03_revert_on_invalid_snapshot(uint96 syncedRaw, uint96 balRaw) external {
        childLCC03.action_lcc03_revert_on_invalid_snapshot(syncedRaw, balRaw);
    }

    function action_lcc03_restore_sync_after_nested(bool nestedNative) external {
        childLCC03.action_lcc03_restore_sync_after_nested(nestedNative);
    }

    function fuzz_lcc_03_sync_windows_hold() external view returns (bool) {
        return childLCC03.fuzz_lcc_03_sync_windows_hold();
    }

    function fuzz_lcc_03_revert_guards_hold() external view returns (bool) {
        return childLCC03.fuzz_lcc_03_revert_guards_hold();
    }

    function fuzz_lcc_03_smoke() external view returns (bool) {
        return childLCC03.fuzz_lcc_03_smoke();
    }

    function action_lcc_backing_01_try_direct_mint(uint256 amount) external {
        childLCCBacking01.action_lcc_backing_01_try_direct_mint(amount);
    }

    function action_lcc_backing_01_try_direct_burn(uint256 amount) external {
        childLCCBacking01.action_lcc_backing_01_try_direct_burn(amount);
    }

    function action_lcc_backing_01_wrap(uint256 amount) external {
        childLCCBacking01.action_lcc_backing_01_wrap(amount);
    }

    function action_lcc_backing_01_issue(uint256 amount) external {
        childLCCBacking01.action_lcc_backing_01_issue(amount);
    }

    function action_lcc_backing_01_cancel(uint256 amount) external {
        childLCCBacking01.action_lcc_backing_01_cancel(amount);
    }

    function action_lcc_backing_01_queue_settlement_claim(uint256 amount) external {
        childLCCBacking01.action_lcc_backing_01_queue_settlement_claim(amount);
    }

    function action_lcc_backing_01_confirm_take(uint256 amount) external {
        childLCCBacking01.action_lcc_backing_01_confirm_take(amount);
    }

    function action_lcc_backing_01_process_settlement(uint256 amount) external {
        childLCCBacking01.action_lcc_backing_01_process_settlement(amount);
    }

    function action_lcc_backing_01_wrapwith(uint256 amount, bool towardB) external {
        childLCCBacking01.action_lcc_backing_01_wrapwith(amount, towardB);
    }

    function action_lcc_backing_01_set_oracle_prices(uint256 p0, uint256 p1) external {
        childLCCBacking01.action_lcc_backing_01_set_oracle_prices(p0, p1);
    }

    function action_lcc_backing_01_set_vrl_signal(uint256 signalUsd) external {
        childLCCBacking01.action_lcc_backing_01_set_vrl_signal(signalUsd);
    }

    function action_lcc_backing_01_set_position_settled(uint256 settled0, uint256 settled1) external {
        childLCCBacking01.action_lcc_backing_01_set_position_settled(settled0, settled1);
    }

    function action_lcc_backing_01_validate_commitment_gate(
        uint160 _sqrtPriceX96,
        int24 _currentTick,
        int24 _tickLower,
        int24 _tickUpper,
        int256 _liquidityDelta
    ) external {
        childLCCBacking01.action_lcc_backing_01_validate_commitment_gate(
            _sqrtPriceX96, _currentTick, _tickLower, _tickUpper, _liquidityDelta
        );
    }

    function fuzz_lcc_backing_01_no_unauthorised_mint() external view returns (bool) {
        return childLCCBacking01.fuzz_lcc_backing_01_no_unauthorised_mint();
    }

    function fuzz_lcc_backing_01_no_unauthorised_burn() external view returns (bool) {
        return childLCCBacking01.fuzz_lcc_backing_01_no_unauthorised_burn();
    }

    function fuzz_lcc_backing_01_total_supply_matches_model() external view returns (bool) {
        return childLCCBacking01.fuzz_lcc_backing_01_total_supply_matches_model();
    }

    function fuzz_lcc_backing_01_direct_reserve_matches_wrapped() external view returns (bool) {
        return childLCCBacking01.fuzz_lcc_backing_01_direct_reserve_matches_wrapped();
    }

    function fuzz_lcc_backing_01_holder_balances_match_model() external view returns (bool) {
        return childLCCBacking01.fuzz_lcc_backing_01_holder_balances_match_model();
    }

    function fuzz_lcc_backing_01_reserve_tuple_matches_model() external view returns (bool) {
        return childLCCBacking01.fuzz_lcc_backing_01_reserve_tuple_matches_model();
    }

    function fuzz_lcc_backing_01_settle_queue_matches_model() external view returns (bool) {
        return childLCCBacking01.fuzz_lcc_backing_01_settle_queue_matches_model();
    }

    function fuzz_lcc_backing_01_wrapwith_conserves_backing() external view returns (bool) {
        return childLCCBacking01.fuzz_lcc_backing_01_wrapwith_conserves_backing();
    }

    function fuzz_lcc_backing_01_commitment_gate_consistent() external view returns (bool) {
        return childLCCBacking01.fuzz_lcc_backing_01_commitment_gate_consistent();
    }

    function fuzz_lcc_backing_01_commitment_gate_boundary() external view returns (bool) {
        return childLCCBacking01.fuzz_lcc_backing_01_commitment_gate_boundary();
    }

    function action_mkt_04_factory_and_issuer_gating(uint96 amountRaw) external {
        childMKT04_04A.action_mkt_04_factory_and_issuer_gating(amountRaw);
    }

    function action_mkt_04a_bound_lifecycle(address who) external {
        childMKT04_04A.action_mkt_04a_bound_lifecycle(who);
    }

    function fuzz_mkt_04_factory_and_issuer_gating() external view returns (bool) {
        return childMKT04_04A.fuzz_mkt_04_factory_and_issuer_gating();
    }

    function fuzz_mkt_04a_bound_lifecycle() external view returns (bool) {
        return childMKT04_04A.fuzz_mkt_04a_bound_lifecycle();
    }

    function action_seed_reserve() external payable {
        childLiquidityHubWrapWithFuzzTest.action_seed_reserve{value: msg.value}();
    }

    function action_wrapWith_conserve_clean(uint256 amount, bool dir) external {
        childLiquidityHubWrapWithFuzzTest.action_wrapWith_conserve_clean(amount, dir);
    }

    function action_wrapWith_queue_netting(uint256 seedAmount, uint256 netAmount, bool dir) external {
        childLiquidityHubWrapWithFuzzTest.action_wrapWith_queue_netting(seedAmount, netAmount, dir);
    }

    function fuzz_wrapWith_conserves_clean() external view returns (bool) {
        return childLiquidityHubWrapWithFuzzTest.fuzz_wrapWith_conserves_clean();
    }

    function childLiquidityHubWrapWithFuzzTest_fuzz_wrapWith_queue_netting_no_double_burn()
        external
        view
        returns (bool)
    {
        return childLiquidityHubWrapWithFuzzTest.fuzz_wrapWith_queue_netting_no_double_burn();
    }

    function childLiquidityHubWrapWithFuzzTest_fuzz_hub05_reserve_never_exceeds_hub_balance()
        external
        view
        returns (bool)
    {
        return childLiquidityHubWrapWithFuzzTest.fuzz_hub05_reserve_never_exceeds_hub_balance();
    }

    function action_wrapWith_conserve(uint256 amount, bool dir) external {
        childLiquidityHubWrapWithQueueFuzzTest.action_wrapWith_conserve(amount, dir);
    }

    function action_process_settlement(bool useNative2, bool forHub, uint256 maxAmount) external {
        childLiquidityHubWrapWithQueueFuzzTest.action_process_settlement(useNative2, forHub, maxAmount);
    }

    function action_wrapWith_existing_queue_netting(uint256 seedAmount, uint256 netAmount, bool dir) external payable {
        childLiquidityHubWrapWithQueueFuzzTest.action_wrapWith_existing_queue_netting{
            value: msg.value
        }(seedAmount, netAmount, dir);
    }

    function action_lcc02_transfer_annuls_queue(uint256 totalAmount, uint256 queueAmount) external {
        childLiquidityHubWrapWithQueueFuzzTest.action_lcc02_transfer_annuls_queue(totalAmount, queueAmount);
    }

    function childLiquidityHubWrapWithQueueFuzzTest_action_donate_eth_to_hub() external payable {
        childLiquidityHubWrapWithQueueFuzzTest.action_donate_eth_to_hub{value: msg.value}();
    }

    function action_confirm_take(uint256 amount) external {
        childLiquidityHubWrapWithQueueFuzzTest.action_confirm_take(amount);
    }

    function fuzz_wrapWith_conserves() external view returns (bool) {
        return childLiquidityHubWrapWithQueueFuzzTest.fuzz_wrapWith_conserves();
    }

    function childLiquidityHubWrapWithQueueFuzzTest_fuzz_wrapWith_queue_netting_no_double_burn()
        external
        view
        returns (bool)
    {
        return childLiquidityHubWrapWithQueueFuzzTest.fuzz_wrapWith_queue_netting_no_double_burn();
    }

    function fuzz_lcc02_annuls_queue_on_protocol_transfer() external view returns (bool) {
        return childLiquidityHubWrapWithQueueFuzzTest.fuzz_lcc02_annuls_queue_on_protocol_transfer();
    }

    function childLiquidityHubWrapWithQueueFuzzTest_fuzz_hub05_reserve_never_exceeds_hub_balance()
        external
        view
        returns (bool)
    {
        return childLiquidityHubWrapWithQueueFuzzTest.fuzz_hub05_reserve_never_exceeds_hub_balance();
    }

    function childLiquidityHubConfirmTakeCallbackFuzzTest_action_donate_eth_to_hub() external payable {
        childLiquidityHubConfirmTakeCallbackFuzzTest.action_donate_eth_to_hub{value: msg.value}();
    }

    function action_set_requested_take(uint256 amt) external {
        childLiquidityHubConfirmTakeCallbackFuzzTest.action_set_requested_take(amt);
    }

    function action_set_callback_mode(uint8 mode) external {
        childLiquidityHubConfirmTakeCallbackFuzzTest.action_set_callback_mode(mode);
    }

    function action_wrap_native_to_reserve() external payable {
        childLiquidityHubConfirmTakeCallbackFuzzTest.action_wrap_native_to_reserve{value: msg.value}();
    }

    function action_issue_to_holder(uint256 amount) external {
        childLiquidityHubConfirmTakeCallbackFuzzTest.action_issue_to_holder(amount);
    }

    function action_seed_hub_queue(uint256 amount) external {
        childLiquidityHubConfirmTakeCallbackFuzzTest.action_seed_hub_queue(amount);
    }

    function action_seed_hub_queue_large(uint256 amount) external {
        childLiquidityHubConfirmTakeCallbackFuzzTest.action_seed_hub_queue_large(amount);
    }

    function action_process_hub_settlement(uint256 maxAmount) external {
        childLiquidityHubConfirmTakeCallbackFuzzTest.action_process_hub_settlement(maxAmount);
    }

    function action_holder_unwrap(uint256 amount) external {
        childLiquidityHubConfirmTakeCallbackFuzzTest.action_holder_unwrap(amount);
    }

    function childLiquidityHubConfirmTakeCallbackFuzzTest_fuzz_hub05_reserve_never_exceeds_hub_balance()
        external
        view
        returns (bool)
    {
        return childLiquidityHubConfirmTakeCallbackFuzzTest.fuzz_hub05_reserve_never_exceeds_hub_balance();
    }

    function fuzz_hub05_callback_seen_or_not() external view returns (bool) {
        return childLiquidityHubConfirmTakeCallbackFuzzTest.fuzz_hub05_callback_seen_or_not();
    }

    function fuzz_hub05_hub_queue_seen_or_not() external view returns (bool) {
        return childLiquidityHubConfirmTakeCallbackFuzzTest.fuzz_hub05_hub_queue_seen_or_not();
    }

    function fuzz_hub05_settlement_attempted_or_not() external view returns (bool) {
        return childLiquidityHubConfirmTakeCallbackFuzzTest.fuzz_hub05_settlement_attempted_or_not();
    }
}
