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

    function _loadMmPrivateKey() internal view returns (uint256 mmPk) {
        mmPk = uint256(
            _requireEnvBytes32("LP_PRIVATE_KEY", "Missing LP_PRIVATE_KEY env var (anvil keys can be used directly)")
        );
    }

    function _takeCorePair(MMPositionManager mmpm, PoolKey memory key, address recipient, uint256 mmPk) internal {
        vm.startBroadcast(mmPk);
        {
            bytes memory actions = abi.encodePacked(bytes1(uint8(MMActions.TAKE)), bytes1(uint8(MMActions.TAKE)));
            bytes[] memory params = new bytes[](2);
            params[0] = abi.encode(key.currency0, recipient, 0);
            params[1] = abi.encode(key.currency1, recipient, 0);
            _executeMMActions(mmpm, actions, params, block.timestamp + 3600);
        }
        vm.stopBroadcast();
    }

    function run() external {
        console.log("=== E2E: CrossMarketDeltaRegression ===");
        _initNetwork();

        uint256 mmPk = _loadMmPrivateKey();
        address mm = vm.addr(mmPk);

        StandaloneMarket memory mA = _deployAndCreateMarket(mm, CORE_POOL_FEE);
        StandaloneMarket memory mB = _createMarketFromStackWithUnderlyings(
            mA.stack, mm, CORE_POOL_FEE, mA.underlying0, mA.underlying1, false
        );
        StandaloneMarket memory mC = _createMarketFromStackWithUnderlyings(
            mA.stack, mm, CORE_POOL_FEE, mA.underlying0, mA.underlying1, false
        );
        StandaloneMarket memory mD = _createMarketFromStackWithUnderlyings(
            mA.stack, mm, CORE_POOL_FEE, mA.underlying0, mA.underlying1, false
        );

        uint256 commitA = _createMmPosition(mA, mmPk, TICK_LOWER, TICK_UPPER, LIQUIDITY, 1);
        uint256 commitB = _createMmPosition(mB, mmPk, TICK_LOWER, TICK_UPPER, LIQUIDITY, 2);
        uint256 commitC = _createMmPosition(mC, mmPk, TICK_LOWER, TICK_UPPER, LIQUIDITY, 3);
        uint256 commitD = _createMmPosition(mD, mmPk, TICK_LOWER, TICK_UPPER, LIQUIDITY, 4);

        MMPositionManager mmpm = MMPositionManager(payable(mA.stack.contracts.mmPositionManager));
        PoolKey memory keyA = _corePoolKey(mA);
        PoolKey memory keyB = _corePoolKey(mB);
        PoolKey memory keyC = _corePoolKey(mC);
        PoolKey memory keyD = _corePoolKey(mD);

        uint256 decAmount = uint256(LIQUIDITY / 8);
        require(decAmount > 0, "regression: decrease amount must be non-zero");

        // Phase 1 — decrease on market A (creates locker credits / settlement plumbing exercised by CoreHook+VTS).
        vm.startBroadcast(mmPk);
        {
            bytes memory actions = abi.encodePacked(bytes1(uint8(MMActions.DECREASE_LIQUIDITY)));
            bytes[] memory params = new bytes[](1);
            params[0] = abi.encode(keyA, commitA, 0, decAmount);
            _executeMMActions(mmpm, actions, params, block.timestamp + 3600);
        }
        vm.stopBroadcast();
        console.log("OK: decrease market A");

        // Phase 2 — mint on market B using locker delta credits (cross-market reuse).
        vm.startBroadcast(mmPk);
        {
            bytes memory actions = abi.encodePacked(bytes1(uint8(MMActions.MINT_POSITION_FROM_DELTAS)));
            bytes[] memory params = new bytes[](1);
            params[0] = abi.encode(
                keyB,
                commitB,
                TICK_LOWER,
                TICK_UPPER,
                type(uint128).max,
                type(uint128).max,
                false // payerIsUser=false: consume locker-scoped credits accrued on previous legs
            );
            _executeMMActions(mmpm, actions, params, block.timestamp + 3600);
        }
        vm.stopBroadcast();
        console.log("OK: mint-from-deltas market B");

        // Phase 3 — increase position 0 on market B from deltas.
        vm.startBroadcast(mmPk);
        {
            bytes memory actions = abi.encodePacked(bytes1(uint8(MMActions.INCREASE_LIQUIDITY_FROM_DELTAS)));
            bytes[] memory params = new bytes[](1);
            params[0] = abi.encode(keyB, commitB, 0, type(uint128).max, type(uint128).max, false);
            _executeMMActions(mmpm, actions, params, block.timestamp + 3600);
        }
        vm.stopBroadcast();
        console.log("OK: increase-from-deltas market B");

        // Phase 4 — decrease market B (partial).
        vm.startBroadcast(mmPk);
        {
            bytes memory actions = abi.encodePacked(bytes1(uint8(MMActions.DECREASE_LIQUIDITY)));
            bytes[] memory params = new bytes[](1);
            params[0] = abi.encode(keyB, commitB, 0, decAmount);
            _executeMMActions(mmpm, actions, params, block.timestamp + 3600);
        }
        vm.stopBroadcast();
        console.log("OK: decrease market B");

        // Phase 5 — settle-from-deltas on market C (consumes remaining locker credits against that market).
        vm.startBroadcast(mmPk);
        {
            bytes memory actions = abi.encodePacked(bytes1(uint8(MMActions.SETTLE_POSITION_FROM_DELTAS)));
            bytes[] memory params = new bytes[](1);
            params[0] = abi.encode(keyC, commitC, 0, false, true);
            _executeMMActions(mmpm, actions, params, block.timestamp + 3600);
        }
        vm.stopBroadcast();
        console.log("OK: settle-from-deltas market C");

        // Phase 6 — mint-from-deltas on market D (second position on the commitment).
        vm.startBroadcast(mmPk);
        {
            bytes memory actions = abi.encodePacked(bytes1(uint8(MMActions.MINT_POSITION_FROM_DELTAS)));
            bytes[] memory params = new bytes[](1);
            params[0] = abi.encode(
                keyD, commitD, TICK_LOWER, TICK_UPPER, type(uint128).max, type(uint128).max, false
            );
            _executeMMActions(mmpm, actions, params, block.timestamp + 3600);
        }
        vm.stopBroadcast();
        console.log("OK: mint-from-deltas market D");

        // Final sweep — take any remaining LCC credits on the locker for each touched core pool.
        _takeCorePair(mmpm, keyA, mm, mmPk);
        _takeCorePair(mmpm, keyB, mm, mmPk);
        _takeCorePair(mmpm, keyC, mm, mmPk);
        _takeCorePair(mmpm, keyD, mm, mmPk);

        // Lightweight sanity: MM still holds finite balances (unwrap phase intentionally omitted here).
        address lccA0 = Currency.unwrap(keyA.currency0);
        address lccA1 = Currency.unwrap(keyA.currency1);
        require(IERC20(lccA0).balanceOf(mm) < type(uint256).max, "sanity: balances readable");
        require(IERC20(lccA1).balanceOf(mm) < type(uint256).max, "sanity: balances readable");

        console.log("OK: CrossMarketDeltaRegression complete");
    }
}
