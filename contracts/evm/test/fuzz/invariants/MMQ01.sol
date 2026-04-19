// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FuzzMMQ01} from "../FuzzMMQ01.sol";

/// @notice Echidna harness for the MM queue custody guard: when `tokenId > 0`, immediate non-fee LCC after fee netting
///         (`nonFee`) must cover the Hub-queued principal slice (`qCommitted == custodyForward`) or `InsufficientBalance`
///         reverts. Valid fuzz regions assume principal-bounded queue staging (**SETTLE-03**); `nonFee < custodyForward`
///         is an underfunded / inconsistent-coupling region, not ordinary slippage tolerance economics.
/// @dev Thin wrapper around `FuzzMMQ01` so existing `just echidna-mmq-01` / `contract MMQ01` workflows stay stable.
///      Medusa uses `FuzzEntry` in `medusa.json` instead (no linked-library prepare).
contract MMQ01 is FuzzMMQ01 {}
