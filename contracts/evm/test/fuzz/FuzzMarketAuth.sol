// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {AUTH01_01A_02} from "./invariants/AUTH01_01A_02.sol";
import {MKT01_02} from "./invariants/MKT01_02.sol";
import {MKT03_06} from "./invariants/MKT03_06.sol";
import {MKT05} from "./invariants/MKT05.sol";
import {SIG01_02} from "./invariants/SIG01_02.sol";

/// @notice Composed Medusa module for repo-owned signal, market, and auth fuzz harnesses.
abstract contract FuzzMarketAuth {
    AUTH01_01A_02 internal childAUTH01_01A_02;
    MKT01_02 internal childMKT01_02;
    MKT03_06 internal childMKT03_06;
    MKT05 internal childMKT05;
    SIG01_02 internal childSIG01_02;

    constructor() {
        childAUTH01_01A_02 = new AUTH01_01A_02();
        childMKT01_02 = new MKT01_02();
        childMKT03_06 = new MKT03_06();
        childMKT05 = new MKT05();
        childSIG01_02 = new SIG01_02();
    }

    function action_auth_01_owner_or_approved_required(bool approved, uint256 positionId, bool seizeContext) external {
        childAUTH01_01A_02.action_auth_01_owner_or_approved_required(approved, positionId, seizeContext);
    }

    function action_auth_01a_seizing_context_scoped(uint256 seizedId, uint256 queriedId) external {
        childAUTH01_01A_02.action_auth_01a_seizing_context_scoped(seizedId, queriedId);
    }

    function action_auth_01a_batch_clear(uint256 seizedId) external {
        childAUTH01_01A_02.action_auth_01a_batch_clear(seizedId);
    }

    function action_auth_02_transfer_blocked_mid_batch(bool poolManagerLocked, uint256 tokenId) external {
        childAUTH01_01A_02.action_auth_02_transfer_blocked_mid_batch(poolManagerLocked, tokenId);
    }

    function fuzz_auth_01_01a_02_hold() external view returns (bool) {
        return childAUTH01_01A_02.fuzz_auth_01_01a_02_hold();
    }

    function action_mkt_01_proxy_rejects_add_liquidity(int24 tickLower, int24 tickUpper, int256 liquidityDelta)
        external
    {
        childMKT01_02.action_mkt_01_proxy_rejects_add_liquidity(tickLower, tickUpper, liquidityDelta);
    }

    function action_mkt_02_core_pool_key_write_once(address c0, address c1) external {
        childMKT01_02.action_mkt_02_core_pool_key_write_once(c0, c1);
    }

    function fuzz_mkt_01_proxy_rejects_add_liquidity() external view returns (bool) {
        return childMKT01_02.fuzz_mkt_01_proxy_rejects_add_liquidity();
    }

    function fuzz_mkt_02_core_pool_key_write_once() external view returns (bool) {
        return childMKT01_02.fuzz_mkt_02_core_pool_key_write_once();
    }

    function action_mkt_03_core_pool_unique(bytes32 corePoolId, address c0, address c1) external {
        childMKT03_06.action_mkt_03_core_pool_unique(corePoolId, c0, c1);
    }

    function action_mkt_06_core_order_canonical(bytes32 corePoolId, address c0, address c1) external {
        childMKT03_06.action_mkt_06_core_order_canonical(corePoolId, c0, c1);
    }

    function fuzz_mkt_03_core_pool_unique() external view returns (bool) {
        return childMKT03_06.fuzz_mkt_03_core_pool_unique();
    }

    function fuzz_mkt_06_core_order_canonical() external view returns (bool) {
        return childMKT03_06.fuzz_mkt_06_core_order_canonical();
    }

    function action_proxy_beforeSwap_exactInput(bool zeroForOne, uint96 amountInRaw) external {
        childMKT05.action_proxy_beforeSwap_exactInput(zeroForOne, amountInRaw);
    }

    function action_proxy_beforeSwap_exactOutput(bool zeroForOne, uint96 amountOutRaw) external {
        childMKT05.action_proxy_beforeSwap_exactOutput(zeroForOne, amountOutRaw);
    }

    function fuzz_mkt05_live_amountToSwap_is_zero() external view returns (bool) {
        return childMKT05.fuzz_mkt05_live_amountToSwap_is_zero();
    }

    function fuzz_mkt05_live_smoke() external view returns (bool) {
        return childMKT05.fuzz_mkt05_live_smoke();
    }

    function action_sig_01_valid_signal(uint256 delta) external {
        childSIG01_02.action_sig_01_valid_signal(delta);
    }

    function action_sig_01_stale_nonce(uint256 offset) external {
        childSIG01_02.action_sig_01_stale_nonce(offset);
    }

    function action_sig_02_invalid_proof_reverts() external {
        childSIG01_02.action_sig_02_invalid_proof_reverts();
    }

    function action_sig_02_invalid_proof_no_revert() external {
        childSIG01_02.action_sig_02_invalid_proof_no_revert();
    }

    function fuzz_sig_01_nonce_never_decreases() external view returns (bool) {
        return childSIG01_02.fuzz_sig_01_nonce_never_decreases();
    }

    function fuzz_sig_01_valid_signal_succeeds() external view returns (bool) {
        return childSIG01_02.fuzz_sig_01_valid_signal_succeeds();
    }

    function fuzz_sig_01_stale_nonce_reverts() external view returns (bool) {
        return childSIG01_02.fuzz_sig_01_stale_nonce_reverts();
    }

    function fuzz_sig_02_invalid_proof_reverts() external view returns (bool) {
        return childSIG01_02.fuzz_sig_02_invalid_proof_reverts();
    }

    function fuzz_sig_02_invalid_proof_returns_false() external view returns (bool) {
        return childSIG01_02.fuzz_sig_02_invalid_proof_returns_false();
    }
}
