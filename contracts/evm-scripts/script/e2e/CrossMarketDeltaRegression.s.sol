// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * E2E: Cross-market delta / produced-credit regression
 *
 * Goal:
 * - Deploy one stack and four markets that **share the same underlying asset pair** (distinct LCCs per market).
 * - Drive a multi-step MM journey that intentionally crosses markets:
 *   1) partial decrease on market A,
 *   2) mint-from-deltas on market B,
 *   3) increase-from-deltas on market B,
 *   4) partial decrease on market B,
 *   5) settle-from-deltas on market C,
 *   6) mint-from-deltas on market D,
 *   then sweep locker credits with TAKEs so the batch finality gate succeeds.
 *
 * Env:
 * - LP_PRIVATE_KEY: MM actor (same as other MM E2E scripts)
 * - PRIVATE_KEY: deployer (via `_getDeployerPrivateKey()` in `E2EBase`)
 */

import {MME2EBase} from "./base/MME2EBase.sol";

import {console} from "forge-std/Script.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MMPositionManager} from "src/MMPositionManager.sol";
import {MMActions} from "src/libraries/MMActions.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

contract CrossMarketDeltaRegressionE2E is MME2EBase {
    uint24 internal constant CORE_POOL_FEE = 3000;
    int24 internal constant TICK_LOWER = -60;
    int24 internal constant TICK_UPPER = 60;
    uint128 internal constant LIQUIDITY = 1e10;

    /// @dev Must match `_buildBatchActions` / `_buildBatchParams` length (single source of truth).
    uint256 internal constant BATCH_LEN = 20;

    MMPositionManager internal s_mmpm;
    PoolKey internal s_keyA;
    PoolKey internal s_keyB;
    PoolKey internal s_keyC;
    PoolKey internal s_keyD;
    uint256 internal s_commitA;
    uint256 internal s_commitB;
    uint256 internal s_commitC;
    uint256 internal s_commitD;
    uint256 internal s_decAmount;

    /// @dev Snapshot of MM LCC wallet balances on market A before the atomic batch (for non-tautological postchecks).
    uint256 internal s_preMmLccA0;
    uint256 internal s_preMmLccA1;

    function _loadMmPrivateKey() internal view returns (uint256 mmPk) {
        mmPk = uint256(
            _requireEnvBytes32("LP_PRIVATE_KEY", "Missing LP_PRIVATE_KEY env var (anvil keys can be used directly)")
        );
    }

    function _prepareCrossMarketBatch(address mm, uint256 mmPk) internal {
        StandaloneMarket memory mA = _deployAndCreateMarket(mm, CORE_POOL_FEE);

        s_mmpm = MMPositionManager(payable(mA.stack.contracts.mmPositionManager));
        s_keyA = _corePoolKey(mA);
        s_commitA = _createMmPosition(mA, mmPk, TICK_LOWER, TICK_UPPER, LIQUIDITY);

        StandaloneMarket memory nextMarket = _createMarketFromStackWithUnderlyings(
            mA.stack, mm, CORE_POOL_FEE, mA.underlying0, mA.underlying1, false
        );
        s_keyB = _corePoolKey(nextMarket);
        s_commitB = _createMmPosition(nextMarket, mmPk, TICK_LOWER, TICK_UPPER, LIQUIDITY);

        nextMarket = _createMarketFromStackWithUnderlyings(
            mA.stack, mm, CORE_POOL_FEE, mA.underlying0, mA.underlying1, false
        );
        s_keyC = _corePoolKey(nextMarket);
        s_commitC = _createMmPosition(nextMarket, mmPk, TICK_LOWER, TICK_UPPER, LIQUIDITY);

        nextMarket = _createMarketFromStackWithUnderlyings(
            mA.stack, mm, CORE_POOL_FEE, mA.underlying0, mA.underlying1, false
        );
        s_keyD = _corePoolKey(nextMarket);
        s_commitD = _createMmPosition(nextMarket, mmPk, TICK_LOWER, TICK_UPPER, LIQUIDITY);

        s_decAmount = uint256(LIQUIDITY / 8);
        require(s_decAmount > 0, "regression: decrease amount must be non-zero");
    }

    /// @notice Runs the cross-market MM atomic batch (must call `_prepareCrossMarketBatch` in the same script run first).
    /// @param recipient Locker credit sweep recipient for trailing `TAKE` actions (same as MM in `_runScenario`).
    /// @param mmPk MM private key (broadcast signer).
    function runCrossMarketAtomicBatch(address recipient, uint256 mmPk) external {
        require(address(s_mmpm) != address(0), "CrossMarket: call _prepareCrossMarketBatch first");
        require(recipient != address(0), "CrossMarket: recipient is zero");
        vm.startBroadcast(mmPk);
        {
            bytes memory actions = _buildBatchActions();
            bytes[] memory params = _buildBatchParams(recipient);
            require(actions.length == BATCH_LEN, "CrossMarket: actions length mismatch");
            require(params.length == BATCH_LEN, "CrossMarket: params length mismatch");
            _executeMMActions(s_mmpm, actions, params, block.timestamp + 3600);
        }
        vm.stopBroadcast();
    }

    function _buildBatchActions() internal pure returns (bytes memory actions) {
        actions = new bytes(BATCH_LEN);
        actions[0] = bytes1(uint8(MMActions.DECREASE_LIQUIDITY));
        actions[1] = bytes1(uint8(MMActions.SETTLE_POSITION));
        actions[2] = bytes1(uint8(MMActions.MINT_POSITION_FROM_DELTAS));
        actions[3] = bytes1(uint8(MMActions.DECREASE_LIQUIDITY));
        actions[4] = bytes1(uint8(MMActions.SETTLE_POSITION));
        actions[5] = bytes1(uint8(MMActions.INCREASE_LIQUIDITY_FROM_DELTAS));
        actions[6] = bytes1(uint8(MMActions.DECREASE_LIQUIDITY));
        actions[7] = bytes1(uint8(MMActions.SETTLE_POSITION));
        actions[8] = bytes1(uint8(MMActions.SETTLE_POSITION_FROM_DELTAS));
        actions[9] = bytes1(uint8(MMActions.DECREASE_LIQUIDITY));
        actions[10] = bytes1(uint8(MMActions.SETTLE_POSITION));
        actions[11] = bytes1(uint8(MMActions.MINT_POSITION_FROM_DELTAS));
        actions[12] = bytes1(uint8(MMActions.TAKE));
        actions[13] = bytes1(uint8(MMActions.TAKE));
        actions[14] = bytes1(uint8(MMActions.TAKE));
        actions[15] = bytes1(uint8(MMActions.TAKE));
        actions[16] = bytes1(uint8(MMActions.TAKE));
        actions[17] = bytes1(uint8(MMActions.TAKE));
        actions[18] = bytes1(uint8(MMActions.TAKE));
        actions[19] = bytes1(uint8(MMActions.TAKE));
    }

    function _buildBatchParams(address recipient)
        internal
        view
        returns (bytes[] memory params)
    {
        params = new bytes[](BATCH_LEN);
        params[0] = _param0();
        params[1] = _param1();
        params[2] = _param2();
        params[3] = _param3();
        params[4] = _param4();
        params[5] = _param5();
        params[6] = _param6();
        params[7] = _param7();
        params[8] = _param8();
        params[9] = _param9();
        params[10] = _param10();
        params[11] = _param11();
        params[12] = _takeParam(s_keyA.currency0, recipient);
        params[13] = _takeParam(s_keyA.currency1, recipient);
        params[14] = _takeParam(s_keyB.currency0, recipient);
        params[15] = _takeParam(s_keyB.currency1, recipient);
        params[16] = _takeParam(s_keyC.currency0, recipient);
        params[17] = _takeParam(s_keyC.currency1, recipient);
        params[18] = _takeParam(s_keyD.currency0, recipient);
        params[19] = _takeParam(s_keyD.currency1, recipient);
    }

    function _param0() internal view returns (bytes memory) {
        return abi.encode(s_keyA, s_commitA, 0, s_decAmount);
    }

    function _param1() internal view returns (bytes memory) {
        return abi.encode(s_keyA, s_commitA, 0, type(int128).max, type(int128).max, true);
    }

    function _param2() internal view returns (bytes memory) {
        return abi.encode(s_keyB, s_commitB, TICK_LOWER, TICK_UPPER, type(uint128).max, type(uint128).max, false);
    }

    function _param3() internal view returns (bytes memory) {
        return abi.encode(s_keyB, s_commitB, 0, s_decAmount);
    }

    function _param4() internal view returns (bytes memory) {
        return abi.encode(s_keyB, s_commitB, 0, type(int128).max, type(int128).max, true);
    }

    function _param5() internal view returns (bytes memory) {
        return abi.encode(s_keyB, s_commitB, 0, type(uint128).max, type(uint128).max, false);
    }

    function _param6() internal view returns (bytes memory) {
        return abi.encode(s_keyB, s_commitB, 0, s_decAmount);
    }

    function _param7() internal view returns (bytes memory) {
        return abi.encode(s_keyB, s_commitB, 0, type(int128).max, type(int128).max, true);
    }

    function _param8() internal view returns (bytes memory) {
        return abi.encode(s_keyC, s_commitC, 0, false, false);
    }

    function _param9() internal view returns (bytes memory) {
        return abi.encode(s_keyC, s_commitC, 0, s_decAmount);
    }

    function _param10() internal view returns (bytes memory) {
        return abi.encode(s_keyC, s_commitC, 0, type(int128).max, type(int128).max, true);
    }

    function _param11() internal view returns (bytes memory) {
        return abi.encode(s_keyD, s_commitD, TICK_LOWER, TICK_UPPER, type(uint128).max, type(uint128).max, false);
    }

    function _takeParam(Currency lane, address recipient) internal pure returns (bytes memory) {
        return abi.encode(lane, recipient, 0);
    }

    /// @dev Asserts the batch actually moved durable MM wallet state (not merely that `balanceOf` did not revert).
    function _assertCrossMarketBatchPostState(address mm) internal view {
        address lccA0 = Currency.unwrap(s_keyA.currency0);
        address lccA1 = Currency.unwrap(s_keyA.currency1);
        uint256 postA0 = IERC20(lccA0).balanceOf(mm);
        uint256 postA1 = IERC20(lccA1).balanceOf(mm);
        require(
            postA0 != s_preMmLccA0 || postA1 != s_preMmLccA1,
            "regression: batch did not change market A LCC balances (unexpected no-op)"
        );
    }

    function _runScenario() internal {
        _initNetwork();
        uint256 mmPk = _loadMmPrivateKey();
        address mm = vm.addr(mmPk);
        _prepareCrossMarketBatch(mm, mmPk);

        address lccA0 = Currency.unwrap(s_keyA.currency0);
        address lccA1 = Currency.unwrap(s_keyA.currency1);
        s_preMmLccA0 = IERC20(lccA0).balanceOf(mm);
        s_preMmLccA1 = IERC20(lccA1).balanceOf(mm);

        this.runCrossMarketAtomicBatch(mm, mmPk);
        console.log("OK: cross-market atomic batch");
        _assertCrossMarketBatchPostState(mm);
    }

    /// @notice Entrypoint for `forge script`: deploy stack, run cross-market scenario, assert postconditions.
    function run() external {
        console.log("=== E2E: CrossMarketDeltaRegression ===");
        _runScenario();
        console.log("OK: CrossMarketDeltaRegression complete");
    }
}
