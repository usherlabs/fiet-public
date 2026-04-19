// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {SETTLE01} from "./invariants/SETTLE01.sol";
import {SETTLE02} from "./invariants/SETTLE02.sol";

/// @notice Composed Medusa module for repo-owned MM-settle fuzz harnesses.
abstract contract FuzzMMSettle {
    SETTLE01 internal childSETTLE01;
    SETTLE02 internal childSETTLE02;

    constructor() {
        childSETTLE01 = new SETTLE01();
        childSETTLE02 = new SETTLE02();
    }

    function action_withdraw_rfs_open_must_revert(
        uint256 commitmentMax0,
        uint256 commitmentMax1,
        uint256 settled0,
        uint256 settled1,
        uint256 amount0,
        uint256 amount1
    ) external {
        childSETTLE01.action_withdraw_rfs_open_must_revert(
            commitmentMax0, commitmentMax1, settled0, settled1, amount0, amount1
        );
    }

    function action_withdraw_rfs_closed_must_succeed(
        uint256 commitmentMax0,
        uint256 commitmentMax1,
        uint256 amount0,
        uint256 amount1
    ) external {
        childSETTLE01.action_withdraw_rfs_closed_must_succeed(commitmentMax0, commitmentMax1, amount0, amount1);
    }

    function fuzz_settle_01_withdraw_reverts_when_rfs_open() external view returns (bool) {
        return childSETTLE01.fuzz_settle_01_withdraw_reverts_when_rfs_open();
    }

    function fuzz_settle_01_aux_closed_withdraw_preserves_accounting_bounds() external view returns (bool) {
        return childSETTLE01.fuzz_settle_01_aux_closed_withdraw_preserves_accounting_bounds();
    }

    function action_settle02_seizing_deposit_clamp(
        uint256 commitmentMax0,
        uint256 commitmentMax1,
        uint256 settled0,
        uint256 settled1,
        uint256 requestedDeposit0,
        uint256 requestedDeposit1
    ) external {
        childSETTLE02.action_settle02_seizing_deposit_clamp(
            commitmentMax0, commitmentMax1, settled0, settled1, requestedDeposit0, requestedDeposit1
        );
    }

    function action_settle02_seizing_withdraw_clamp(
        uint256 required0Raw,
        uint256 required1Raw,
        uint256 requestedWithdraw0,
        uint256 requestedWithdraw1
    ) external {
        childSETTLE02.action_settle02_seizing_withdraw_clamp(
            required0Raw, required1Raw, requestedWithdraw0, requestedWithdraw1
        );
    }

    function fuzz_settle_02_seizing_clamps_hold() external view returns (bool) {
        return childSETTLE02.fuzz_settle_02_seizing_clamps_hold();
    }

    function fuzz_settle_02_smoke() external view returns (bool) {
        return childSETTLE02.fuzz_settle_02_smoke();
    }
}
