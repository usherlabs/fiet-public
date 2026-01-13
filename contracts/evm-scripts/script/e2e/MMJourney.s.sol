// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * E2E: MMPositionManager (step 1)
 *
 * Goal:
 * - Create a single MM position: commit → mint → settle.
 * - Perform one large swap in each direction (0->1, then 1->0) to accrue fees.
 *
 * Env:
 * - LP_PRIVATE_KEY (MM actor)
 * - PRIVATE_KEY (deployer; used as taker for swaps)
 */

import {E2EBase} from "./base/E2EBase.sol";

import {console} from "forge-std/Script.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Token} from "../setup/MockERC20.s.sol";
import {MMPositionManager} from "src/MMPositionManager.sol";
import {MMActionAdapter} from "evm-test/utils/MMActionAdapter.sol";
import {IVTSOrchestrator} from "src/interfaces/IVTSOrchestrator.sol";
import {ILCC} from "src/interfaces/ILCC.sol";
import {LiquidityUtils} from "src/libraries/LiquidityUtils.sol";
import {MarketVTSConfiguration} from "src/types/VTS.sol";
import {ILiquidityHub} from "src/interfaces/ILiquidityHub.sol";

contract MMJourneyE2E is E2EBase {
    using BalanceDeltaLibrary for BalanceDelta;

    uint24 internal constant CORE_POOL_FEE = 3000; // non-zero so fee collection is meaningful
    uint128 internal constant LIQUIDITY = 1e10;
    int24 internal constant TICK_LOWER = -60;
    int24 internal constant TICK_UPPER = 60;
    uint256 internal constant WRAP_FOR_SWAPS = 50_000e18;
    uint128 internal constant BIG_SWAP_AMOUNT_IN = 5_000e18;
    // Keep this as int256 to preserve the exact runtime casting behavior below (int256->int128 / int256->uint256).
    int256 internal constant RFS_OVERSETTLE_MULTIPLIER = 1_000_000e18;

    function run() external {
        // Select network + configure Foundry broadcast context (fork/rpc).
        _initNetwork();

        // MM actor private key (the market maker / position owner).
        uint256 mmPk = uint256(vm.envBytes32("LP_PRIVATE_KEY"));
        // Derived MM EOA address from the private key.
        address mm = vm.addr(mmPk);

        // Deploy shared “core” stack (PoolManager + system contracts).
        CoreDeployment memory d = _deployCoreContracts();
        // Create a market for the MM with a non-zero pool fee (so swaps can accrue fees).
        StandaloneMarket memory m = _createMarket(d, mm, CORE_POOL_FEE);

        // Create the MM committed position (commit → mint → settle) and return its commitId.
        uint256 commitId = _createPosition(m, mmPk);

        // Taker private key (used to execute swaps against the pool).
        uint256 takerPk = _getDeployerPrivateKey();
        // Perform two big swaps (0->1 then 1->0) to generate fee accrual on both sides.
        _swapBothDirections(m, takerPk);
        // “Poke” the position to realize/withdraw fee credits as LCCs, returning amounts taken for each side.
        (uint256 feeLcc0, uint256 feeLcc1) = _pokePosition(m, mmPk, commitId);
        // Log fee amount taken as LCC0.
        console.log("poke feeLcc0:", feeLcc0);
        // Log fee amount taken as LCC1.
        console.log("poke feeLcc1:", feeLcc1);
        // Close RFS (if needed), then burn + withdraw-from-deltas + decommit, and TAKE any remaining LCC credits.
        _closeRfsBurnDecommitAndTakeAllLccs(m, mmPk, commitId);
        // Unwrap all LCC balances back to underlying and assert 1:1 underlying deltas.
        _unwrapAllLccsAndAssert(m, mmPk);
    }

    function _createPosition(StandaloneMarket memory m, uint256 mmPk) internal returns (uint256 commitId) {
        address mm = vm.addr(mmPk);

        MMPositionManager mmpm = MMPositionManager(payable(m.stack.contracts.mmPositionManager));
        IVTSOrchestrator vts = IVTSOrchestrator(m.stack.contracts.vtsOrchestrator);

        PoolKey memory corePoolKey = _corePoolKey(m);
        MarketVTSConfiguration memory vtsCfg = vts.getMarketVTSConfiguration(corePoolKey.toId());

        // MM commits + mints + settles.
        bytes memory liquiditySignalBytes = _buildSingleLeafLiquiditySignal(mmPk, 1);

        (uint256 c0, uint256 c1) = LiquidityUtils.calculateCommitmentMaxima(TICK_LOWER, TICK_UPPER, LIQUIDITY);
        (uint256 settle0, uint256 settle1) =
            LiquidityUtils.getBaseSettlementAmounts(c0, c1, vtsCfg.token0.baseVTSRate, vtsCfg.token1.baseVTSRate);

        commitId = mmpm.nextTokenId();

        vm.startBroadcast(mmPk);
        // Ensure MM has enough underlying to settle.
        Token(m.underlying0).mint(mm, settle0);
        Token(m.underlying1).mint(mm, settle1);
        IERC20(m.underlying0).approve(address(mmpm), settle0);
        IERC20(m.underlying1).approve(address(mmpm), settle1);
        {
            MMActionAdapter.PreparedAction[] memory acts = new MMActionAdapter.PreparedAction[](3);
            acts[0] = MMActionAdapter.prepareCommit(liquiditySignalBytes);
            acts[1] = MMActionAdapter.prepareMint(corePoolKey, commitId, TICK_LOWER, TICK_UPPER, LIQUIDITY);
            acts[2] = MMActionAdapter.prepareSettle(
                corePoolKey,
                commitId,
                0,
                -int128(int256(settle0)),
                -int128(int256(settle1)),
                false // usePositionManagerBalance
            );
            MMActionAdapter.executeWithUnlock(mmpm, acts, block.timestamp + 3600);
        }
        vm.stopBroadcast();
        require(mmpm.ownerOf(commitId) == mm, "mmpm: commit NFT owner mismatch");

        console.log("OK: position created");
        console.log("commitId:", commitId);
    }

    function _swapBothDirections(StandaloneMarket memory m, uint256 takerPk) internal {
        address taker = vm.addr(takerPk);

        // Fund taker and wrap underlying -> LCC so taker can trade core pool currencies.
        vm.startBroadcast(takerPk);
        Token(m.underlying0).mint(taker, WRAP_FOR_SWAPS);
        Token(m.underlying1).mint(taker, WRAP_FOR_SWAPS);
        _wrapAndMintLccPair(ILiquidityHub(m.stack.contracts.liquidityHub), m, taker, WRAP_FOR_SWAPS);
        vm.stopBroadcast();

        // One large swap in each direction.
        _swapExactInputSingle(m, takerPk, true, BIG_SWAP_AMOUNT_IN, 0); // 0 -> 1
        _swapExactInputSingle(m, takerPk, false, BIG_SWAP_AMOUNT_IN, 0); // 1 -> 0

        console.log("OK: swaps complete");
    }

    /// @dev Fee “poke”: no-op increase (0) to touch the position, then TAKE both pool currencies to wallet.
    function _pokePosition(StandaloneMarket memory m, uint256 mmPk, uint256 commitId)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        address mm = vm.addr(mmPk);
        PoolKey memory corePoolKey = _corePoolKey(m);

        address lcc0 = Currency.unwrap(corePoolKey.currency0);
        address lcc1 = Currency.unwrap(corePoolKey.currency1);
        address underlying0 = ILCC(lcc0).underlying();
        address underlying1 = ILCC(lcc1).underlying();

        uint256 lcc0Before = IERC20(lcc0).balanceOf(mm);
        uint256 lcc1Before = IERC20(lcc1).balanceOf(mm);
        uint256 underlying0Before = IERC20(underlying0).balanceOf(mm);
        uint256 underlying1Before = IERC20(underlying1).balanceOf(mm);

        vm.startBroadcast(mmPk);
        {
            MMPositionManager mmpm = MMPositionManager(payable(m.stack.contracts.mmPositionManager));
            MMActionAdapter.PreparedAction[] memory acts = new MMActionAdapter.PreparedAction[](3);
            acts[0] = MMActionAdapter.prepareIncrease(corePoolKey, commitId, 0, 0);
            acts[1] = MMActionAdapter.prepareTake(corePoolKey.currency0, mm, 0);
            acts[2] = MMActionAdapter.prepareTake(corePoolKey.currency1, mm, 0);
            MMActionAdapter.executeWithUnlock(mmpm, acts, block.timestamp + 3600);
        }
        vm.stopBroadcast();

        uint256 lcc0After = IERC20(lcc0).balanceOf(mm);
        uint256 lcc1After = IERC20(lcc1).balanceOf(mm);
        uint256 underlying0After = IERC20(underlying0).balanceOf(mm);
        uint256 underlying1After = IERC20(underlying1).balanceOf(mm);

        amount0 = lcc0After - lcc0Before;
        amount1 = lcc1After - lcc1Before;
        require(amount0 > 0 || amount1 > 0, "poke: expected some LCC change");

        console.log("OK: position poked");
        console.log("fee lcc0 taken:", amount0);
        console.log("fee lcc1 taken:", amount1);
        // Underlyings shouldn't change here (we only took LCCs), but leaving it as a sanity check.
        console.log("underlying0 delta:", underlying0After - underlying0Before);
        console.log("underlying1 delta:", underlying1After - underlying1Before);
    }

    /// @dev Close RFS (so burn can succeed), then burn → withdraw-from-deltas → decommit, and TAKE any LCC credits.
    function _closeRfsBurnDecommitAndTakeAllLccs(StandaloneMarket memory m, uint256 mmPk, uint256 commitId) internal {
        address mm = vm.addr(mmPk);
        PoolKey memory corePoolKey = _corePoolKey(m);

        IVTSOrchestrator vts = IVTSOrchestrator(m.stack.contracts.vtsOrchestrator);
        (, bool rfsOpen, BalanceDelta rfsDelta) = vts.calcRFS(commitId, 0, false);
        int128 d0 = rfsDelta.amount0();
        int128 d1 = rfsDelta.amount1();

        console.log("rfsOpen:", rfsOpen);
        console.log("rfsDelta0:", d0);
        console.log("rfsDelta1:", d1);

        // IMPORTANT: keep these casts exactly as-is (the journey relies on this working on this stack).
        // If delta > 0, settlement is required; we deposit with negative amounts.
        int128 settle0 = d0 > 0 ? (-d0 * int128(RFS_OVERSETTLE_MULTIPLIER)) : int128(0);
        int128 settle1 = d1 > 0 ? (-d1 * int128(RFS_OVERSETTLE_MULTIPLIER)) : int128(0);

        uint256 fund0 = d0 > 0 ? (uint256(uint128(d0)) * uint256(RFS_OVERSETTLE_MULTIPLIER)) : 0;
        uint256 fund1 = d1 > 0 ? (uint256(uint128(d1)) * uint256(RFS_OVERSETTLE_MULTIPLIER)) : 0;

        vm.startBroadcast(mmPk);
        {
            MMPositionManager mmpm = MMPositionManager(payable(m.stack.contracts.mmPositionManager));

            if (fund0 > 0) {
                Token(m.underlying0).mint(mm, fund0);
                IERC20(m.underlying0).approve(address(mmpm), fund0);
            }
            if (fund1 > 0) {
                Token(m.underlying1).mint(mm, fund1);
                IERC20(m.underlying1).approve(address(mmpm), fund1);
            }

            MMActionAdapter.PreparedAction[] memory acts = new MMActionAdapter.PreparedAction[](1);
            acts[0] = MMActionAdapter.prepareSettle(
                corePoolKey,
                commitId,
                0,
                settle0,
                settle1,
                false // usePositionManagerBalance
            );
            MMActionAdapter.executeWithUnlock(mmpm, acts, block.timestamp + 3600);
        }
        vm.stopBroadcast();

        // Must be closed before burn (decrease path requires requireClosedRfS=true).
        vts.calcRFS(commitId, 0, true);

        vm.startBroadcast(mmPk);
        {
            MMPositionManager mmpm = MMPositionManager(payable(m.stack.contracts.mmPositionManager));
            MMActionAdapter.PreparedAction[] memory acts = new MMActionAdapter.PreparedAction[](5);
            acts[0] = MMActionAdapter.prepareBurn(corePoolKey, commitId, 0);
            acts[1] = MMActionAdapter.prepareSettleFromDeltas(corePoolKey, commitId, 0, true, true);
            acts[2] = MMActionAdapter.prepareDecommit(commitId);
            acts[3] = MMActionAdapter.prepareTake(corePoolKey.currency0, mm, 0);
            acts[4] = MMActionAdapter.prepareTake(corePoolKey.currency1, mm, 0);
            MMActionAdapter.executeWithUnlock(mmpm, acts, block.timestamp + 3600);
        }
        vm.stopBroadcast();

        console.log("OK: closed RFS + burned + withdrew-from-deltas + decommitted");
    }

    /// @dev Unwraps all LCC balances held by the MM back to the underlying tokens.
    ///      Asserts that the amount of LCC consumed equals the underlying balance delta (1:1).
    function _unwrapAllLccsAndAssert(StandaloneMarket memory m, uint256 mmPk) internal {
        address mm = vm.addr(mmPk);
        PoolKey memory corePoolKey = _corePoolKey(m);

        address lcc0 = Currency.unwrap(corePoolKey.currency0);
        address lcc1 = Currency.unwrap(corePoolKey.currency1);
        address underlying0 = ILCC(lcc0).underlying();
        address underlying1 = ILCC(lcc1).underlying();

        uint256 lcc0Before = IERC20(lcc0).balanceOf(mm);
        uint256 lcc1Before = IERC20(lcc1).balanceOf(mm);
        uint256 underlying0Before = IERC20(underlying0).balanceOf(mm);
        uint256 underlying1Before = IERC20(underlying1).balanceOf(mm);

        vm.startBroadcast(mmPk);
        {
            MMPositionManager mmpm = MMPositionManager(payable(m.stack.contracts.mmPositionManager));

            // UNWRAP_LCC(payerIsUser=true) pulls LCC from the MM via transferFrom.
            // Approve exactly what we currently hold.
            IERC20(lcc0).approve(address(mmpm), lcc0Before);
            IERC20(lcc1).approve(address(mmpm), lcc1Before);

            MMActionAdapter.PreparedAction[] memory acts = new MMActionAdapter.PreparedAction[](2);
            // amount=0 means unwrap-all for payerIsUser=true (see MMPositionManager::_unwrapLccFromUser).
            acts[0] = MMActionAdapter.prepareUnwrapLcc(lcc0, 0, mm, true);
            acts[1] = MMActionAdapter.prepareUnwrapLcc(lcc1, 0, mm, true);
            MMActionAdapter.executeWithUnlock(mmpm, acts, block.timestamp + 3600);
        }
        vm.stopBroadcast();

        uint256 lcc0After = IERC20(lcc0).balanceOf(mm);
        uint256 lcc1After = IERC20(lcc1).balanceOf(mm);
        uint256 underlying0After = IERC20(underlying0).balanceOf(mm);
        uint256 underlying1After = IERC20(underlying1).balanceOf(mm);

        uint256 lcc0Spent = lcc0Before - lcc0After;
        uint256 lcc1Spent = lcc1Before - lcc1After;
        uint256 underlying0Delta = underlying0After - underlying0Before;
        uint256 underlying1Delta = underlying1After - underlying1Before;

        console.log("unwrap spent lcc0:", lcc0Spent);
        console.log("unwrap spent lcc1:", lcc1Spent);
        console.log("unwrap underlying0 delta:", underlying0Delta);
        console.log("unwrap underlying1 delta:", underlying1Delta);

        require(underlying0Delta == lcc0Spent, "unwrap0: underlying != lcc spent");
        require(underlying1Delta == lcc1Spent, "unwrap1: underlying != lcc spent");
    }
}

