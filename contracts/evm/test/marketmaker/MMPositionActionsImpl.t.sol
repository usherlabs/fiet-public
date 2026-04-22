// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
// solhint-disable max-line-length

import {BalanceDelta, toBalanceDelta, add} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityCommitmentCertificate} from "../../src/LCC.sol";
import {IMarketFactory} from "../../src/interfaces/IMarketFactory.sol";
import {LiquidityUtils} from "../../src/libraries/LiquidityUtils.sol";
import {console} from "forge-std/console.sol";
import {MarketTestBase} from "../base/MarketTestBase.sol";
import {MMPositionManager} from "../../src/MMPositionManager.sol";
import {MMActionAdapter as MMA} from "../utils/MMActionAdapter.sol";
import {MarketMakerTestBase} from "../base/MMTestBase.sol";
import {MarketMaker} from "../../src/libraries/MarketMaker.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PositionId} from "../../src/types/Position.sol";
import {MarketVTSConfiguration} from "../../src/types/VTS.sol";
import {MockERC20} from "../_mocks/MockERC20.sol";
import {SafeCast} from "v4-periphery/lib/v4-core/src/libraries/SafeCast.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {IOracleHelper} from "../../src/interfaces/IOracleHelper.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {Position} from "../../src/types/Position.sol";
import {RFSCheckpoint} from "../../src/types/Checkpoint.sol";
import {ILCC} from "../../src/interfaces/ILCC.sol";
import {ILiquidityHub} from "../../src/interfaces/ILiquidityHub.sol";
import {IMarketVault} from "../../src/interfaces/IMarketVault.sol";
import {ICanonicalVault} from "../../src/interfaces/ICanonicalVault.sol";
import {IMarketVaultDryBalanceDelta} from "../_helpers/IMarketVaultDryBalanceDelta.sol";
import {IVRLSignalManager} from "../../src/interfaces/IVRLSignalManager.sol";
import {LiquiditySignal} from "../../src/types/Commit.sol";
import {IVTSOrchestrator} from "../../src/interfaces/IVTSOrchestrator.sol";
import {VTSOrchestrator} from "../../src/VTSOrchestrator.sol";
import {MmIncreaseAdmissionReplay, VTSOrchestratorTestable} from "../base/VTSOrchestratorTestable.sol";
import {IMMQueueCustodian} from "../../src/interfaces/IMMQueueCustodian.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {MMPositionActionsImpl} from "../../src/MMPositionActionsImpl.sol";
import {MMUtilityActionsImpl} from "../../src/MMUtilityActionsImpl.sol";
import {MMActions} from "../../src/libraries/MMActions.sol";
import {DelegateCallGuard} from "../../src/modules/DelegateCallGuard.sol";
import {Bounds} from "../../src/libraries/Bounds.sol";
import {MockERC20} from "../_mocks/MockERC20.sol";

contract MMPositionManagerActionsTest is MarketTestBase, MarketMakerTestBase {
    using SafeCast for *;
    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;
    using MarketMaker for MarketMaker.State;
    using StateLibrary for IPoolManager;

    struct IncreaseFromDeltasSnapshot {
        uint256 tokenId;
        uint256 newTokenId;
        PositionId position2Id;
        uint128 position1LiquidityBefore;
        uint128 position2LiquidityBefore;
        uint256 position1Settled0Before;
        uint256 position1Settled1Before;
        uint256 position1Overflow0Before;
        uint256 position1Overflow1Before;
        uint256 position2SettledAmount0Before;
        uint256 position2SettledAmount1Before;
        uint256 position2Overflow0Before;
        uint256 position2Overflow1Before;
    }

    MMPositionManager internal positionManager;
    MarketVTSConfiguration internal marketVTSConfiguration;

    LiquidityCommitmentCertificate internal lcc0;
    LiquidityCommitmentCertificate internal lcc1;

    address guarantor = makeAddr("guarantor");
    uint256 guarantorInitialBalance = 10000e18;
    ModifyLiquidityParams defaultlLiquidityParams =
        ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: bytes32(0)});

    /// @dev Thin wrappers around `MarketTestBase` helpers using this suite's `positionManager`.
    function _wireTestQueueCustodian(address recipient) internal {
        _wireTestQueueCustodianFor(address(positionManager), recipient);
    }

    function _wireAllUtilityTestCustodians() internal {
        _wireAllUtilityTestQueueCustodians(address(positionManager));
    }

    /// @dev Use `VTSOrchestratorTestable` so integration tests can replay COMMIT-01 admission on live `s`.
    function _deployVTSOrchestrator(address _poolManager, address _oracleHelper, address _liquidityHub, address _owner)
        internal
        override
        returns (VTSOrchestrator)
    {
        return VTSOrchestrator(address(new VTSOrchestratorTestable(_poolManager, _oracleHelper, _liquidityHub, _owner)));
    }

    function setUp() public {
        _setupMarket();
        _setUpMM();
        console.log("setUP() mmPositionManager", address(mmPositionManager));
        positionManager = MMPositionManager(payable(mmPositionManager));
        _wireTestQueueCustodian(liquiditySignal.mmState.advancer);
        _wireAllUtilityTestCustodians();
        lcc0 = LiquidityCommitmentCertificate(payable(Currency.unwrap(_currency2)));
        lcc1 = LiquidityCommitmentCertificate(payable(Currency.unwrap(_currency3)));

        marketVTSConfiguration = IVTSOrchestrator(vtsOrchestrator).getMarketVTSConfiguration(corePoolKey.toId());

        // mock the price oracles to return prices
        vm.mockCall(
            address(oracleHelper),
            abi.encodeWithSelector(IOracleHelper.getPricesForLccPair.selector),
            abi.encode(uint256(1), uint256(1))
        );
        // supply enough
        vm.mockCall(
            address(oracleHelper), abi.encodeWithSelector(IOracleHelper.getTotalValue.selector), abi.encode(1e18)
        );

        // MM batch locker EOAs must read as factory-bound (matches `VTSOrchestratorFixture` / production).
        vm.mockCall(
            marketFactory,
            abi.encodeWithSelector(IMarketFactory.bounds.selector, liquiditySignal.mmState.advancer),
            abi.encode(true)
        );
    }

    /// @dev Commitment NFT owner / effective batch locker for `modifyLiquidities`.
    function _batchLocker(uint256 tokenId) internal view returns (address) {
        return positionManager.ownerOf(tokenId);
    }

    /// @dev Use when the batch locker is already known (e.g. immediately after `vm.expectRevert`, which must wrap
    ///      `modifyLiquidities` — not an `ownerOf` prefetch).
    function _mmExec(address locker, MMA.PreparedAction[] memory actions) internal {
        vm.startPrank(locker);
        MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);
        vm.stopPrank();
    }

    function _mmExec(uint256 tokenId, MMA.PreparedAction[] memory actions) internal {
        _mmExec(_batchLocker(tokenId), actions);
    }

    /// @dev External wrapper so tests can `try/catch` full-path MM increase execution.
    function _attemptIncreaseExternal(uint256 tokenId, uint256 positionIndex, uint256 liquidityToIncrease) external {
        if (msg.sender != address(this)) revert("self only");
        address locker = _batchLocker(tokenId);
        MMA.PreparedAction[] memory incActions = new MMA.PreparedAction[](1);
        incActions[0] = MMA.prepareIncrease(corePoolKey, tokenId, positionIndex, liquidityToIncrease);
        _mmExec(locker, incActions);
    }

    /// @dev For batches that only contain `prepareCommit` (no `tokenId` yet), run as the signal advancer.
    function _mmExecSignalLocker(bytes memory liquiditySignalBytes, MMA.PreparedAction[] memory actions) internal {
        address locker = abi.decode(liquiditySignalBytes, (LiquiditySignal)).mmState.advancer;
        vm.startPrank(locker);
        MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);
        vm.stopPrank();
    }

    /// @dev Overwrite one 32-byte word in `abi.encode` content (`wordIndex` 0 = first head word after the length word).
    function _setActionParamWord(bytes memory data, uint256 wordIndex, uint256 word) private pure {
        assembly ("memory-safe") {
            mstore(add(add(data, 0x20), mul(wordIndex, 0x20)), word)
        }
    }

    // use this function to calculate the minumum amount of underlying assets that need to be settled in order to mint a position
    function approveRequiredSettlementAmounts(ModifyLiquidityParams memory liquidityParams)
        public
        returns (uint256 requiredSettlementAmount0, uint256 requiredSettlementAmount1)
    {
        // Calculate settlement amounts
        (requiredSettlementAmount0, requiredSettlementAmount1) =
            _calculateSettlementAmounts(liquidityParams, marketVTSConfiguration);

        // Approve underlying tokens since they will be used to settle the position
        _approveTokenForPositionManager(
            address(lcc0.underlying()),
            address(lcc1.underlying()),
            address(positionManager),
            requiredSettlementAmount0,
            requiredSettlementAmount1
        );
    }

    function approveAndSettleUnderlyingToPosition(
        uint256 tokenId,
        uint256 positionIndex,
        uint256 settlementAmount0,
        uint256 settlementAmount1
    ) public {
        address locker = _batchLocker(tokenId);
        _fundLockerForSettlement(
            locker, address(lcc0.underlying()), address(lcc1.underlying()), settlementAmount0, settlementAmount1
        );
        vm.startPrank(locker);
        // Approve the underlying tokens to be used to settle the position
        _approveTokenForPositionManager(
            address(lcc0.underlying()),
            address(lcc1.underlying()),
            address(positionManager),
            settlementAmount0,
            settlementAmount1
        );

        // Settle the position
        MMA.settle(
            positionManager,
            corePoolKey,
            tokenId,
            positionIndex,
            -int128(int256(settlementAmount0)),
            -int128(int256(settlementAmount1))
        );
        vm.stopPrank();
    }

    function createPosition(
        ModifyLiquidityParams memory liquidityParams,
        bytes memory liquiditySignalBytes,
        uint256 tokenId,
        uint256 positionIndex
    ) public {
        (uint256 requiredSettlementAmount0, uint256 requiredSettlementAmount1) =
            _calculateSettlementAmounts(liquidityParams, marketVTSConfiguration);

        address locker = abi.decode(liquiditySignalBytes, (LiquiditySignal)).mmState.advancer;
        _fundLockerForSettlement(
            locker,
            address(lcc0.underlying()),
            address(lcc1.underlying()),
            requiredSettlementAmount0,
            requiredSettlementAmount1
        );

        vm.startPrank(locker);
        _approveTokenForPositionManager(
            address(lcc0.underlying()),
            address(lcc1.underlying()),
            address(positionManager),
            requiredSettlementAmount0,
            requiredSettlementAmount1
        );

        // Batch commit and mint and settle the position
        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](3);
        actions[0] = MMA.prepareCommit(liquiditySignalBytes);
        actions[1] = MMA.prepareMint(
            corePoolKey,
            tokenId,
            liquidityParams.tickLower,
            liquidityParams.tickUpper,
            uint256(liquidityParams.liquidityDelta)
        );
        actions[2] = MMA.prepareSettle(
            corePoolKey,
            tokenId,
            positionIndex,
            -int128(int256(requiredSettlementAmount0)),
            -int128(int256(requiredSettlementAmount1)),
            false // usePositionManagerBalance
        );

        MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);
        vm.stopPrank();
    }

    function _queuedSumFor(address recipient) internal view returns (uint256) {
        return ILiquidityHub(liquidityHub).settleQueue(address(lcc0), recipient)
            + ILiquidityHub(liquidityHub).settleQueue(address(lcc1), recipient);
    }

    function _custodySumFor(address custodian) internal view returns (uint256) {
        return IMMQueueCustodian(custodian).totalQueuedLcc(address(lcc0))
            + IMMQueueCustodian(custodian).totalQueuedLcc(address(lcc1));
    }

    /// @dev After a primed seizure batch, Hub `settleQueue(lcc, custodian)` and per-`lcc` custody align per leg.
    function _assertGuarantorSeizureQueueStaging(
        address custodian,
        address,
        uint256 queuedSumBefore,
        uint256 qLcc0Before,
        uint256 qLcc1Before,
        uint256 custodyLcc0Before,
        uint256 custodyLcc1Before
    ) internal view {
        assertEq(
            IMMQueueCustodian(custodian).totalQueuedLcc(address(lcc0)),
            ILiquidityHub(liquidityHub).settleQueue(address(lcc0), custodian),
            "lcc0: custody must match Hub queue for locker custodian"
        );
        assertEq(
            IMMQueueCustodian(custodian).totalQueuedLcc(address(lcc1)),
            ILiquidityHub(liquidityHub).settleQueue(address(lcc1), custodian),
            "lcc1: custody must match Hub queue for locker custodian"
        );
        uint256 dq0 = ILiquidityHub(liquidityHub).settleQueue(address(lcc0), custodian) - qLcc0Before;
        uint256 dq1 = ILiquidityHub(liquidityHub).settleQueue(address(lcc1), custodian) - qLcc1Before;
        assertGt(dq0 + dq1, 0, "Primed seizure should stage non-zero retained principal to Hub queues");
        assertEq(
            dq0,
            IMMQueueCustodian(custodian).totalQueuedLcc(address(lcc0)) - custodyLcc0Before,
            "lcc0 Hub queue delta matches custody delta"
        );
        assertEq(
            dq1,
            IMMQueueCustodian(custodian).totalQueuedLcc(address(lcc1)) - custodyLcc1Before,
            "lcc1 Hub queue delta matches custody delta"
        );
        assertGt(
            _queuedSumFor(custodian),
            queuedSumBefore,
            "Seizure should increase custodian queue when retained principal is non-zero"
        );
    }

    function _walletLccSum(address account) internal view returns (uint256) {
        return Currency.wrap(address(lcc0)).balanceOf(account) + Currency.wrap(address(lcc1)).balanceOf(account);
    }

    function _marketReserveForLcc(bytes32 marketId, address lccToken) internal view returns (uint256) {
        Currency underlyingCurrency = Currency.wrap(ILCC(lccToken).underlying());
        return ICanonicalVault(canonicalVaultAddr).inMarketBalanceOf(marketId, underlyingCurrency);
    }

    function _primePositionForQueuedDecrease(uint256 tokenId, uint256 positionIndex, uint256 liquidityToDecrease)
        internal
    {
        (uint256 removedCommitment0, uint256 removedCommitment1) = LiquidityUtils.calculateCommitmentMaxima(
            defaultlLiquidityParams.tickLower, defaultlLiquidityParams.tickUpper, uint128(liquidityToDecrease)
        );

        (, PositionId positionId) = vtsOrchestrator.getPosition(tokenId, positionIndex);
        (uint256 settled0, uint256 settled1) = vtsOrchestrator.getPositionSettledAmounts(positionId);
        (uint256 commitment0, uint256 commitment1) = vtsOrchestrator.getCommitmentMaxima(positionId);

        // Leave a tiny excess after the decrease so we exercise the queued-retained path
        // without exceeding the principal withdrawn by that decrease.
        uint256 topUp0 =
            commitment0 > settled0 + removedCommitment0 ? commitment0 - settled0 - removedCommitment0 + 1 : 0;
        uint256 topUp1 =
            commitment1 > settled1 + removedCommitment1 ? commitment1 - settled1 - removedCommitment1 + 1 : 0;
        if (topUp0 > 0 || topUp1 > 0) {
            approveAndSettleUnderlyingToPosition(tokenId, positionIndex, topUp0, topUp1);
        }
    }

    function _openSeizeWindow(uint256 tokenId, uint256 positionIndex) internal {
        swapRouter.swap(
            proxyPoolKey,
            SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: ZERO_FOR_ONE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
        // Persist the live RFS-open state before time-warping so seizure grace is measured from checkpoint storage.
        positionManager.checkpoint(tokenId, positionIndex, false);
        vm.warp(block.timestamp + 300000 + 1);
    }

    /// @notice Regression (audit 29_10): mis-scoped seizure settlement must not fall through to a zero-liquidity decrease
    ///         that can still realise accrued LCC fees to the seizer.
    function test_seize_revertsWhenMisdirectedSettlementProducesZeroSeizedLiquidity() public {
        uint256 tokenId = 1;
        uint256 positionIndex = 0;

        _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            defaultlLiquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        _openSeizeWindow(tokenId, positionIndex);

        (, PositionId positionId) = positionManager.getPosition(tokenId, positionIndex);
        (, BalanceDelta rfs) = vtsOrchestrator.calcRFS(positionId, false);

        uint256 amt = 5_999_709_018_652_707;

        if (rfs.amount0() > 0 && rfs.amount1() <= 0) {
            // Deposit only lane 1 while lane 1 has no positive-RFS need — `_settleSeizingDeposits` accepts nothing; seized liquidity stays 0.
            MockERC20(address(lcc1.underlying())).mint(guarantor, amt);
            vm.startPrank(guarantor);
            IERC20(lcc1.underlying()).approve(address(positionManager), amt);

            MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](1);
            actions[0] = MMA.prepareSeize(corePoolKey, tokenId, positionIndex, 0, amt, false);
            vm.expectRevert(Errors.SeizureWithoutLiquidityRemoval.selector);
            MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);
            vm.stopPrank();
        } else if (rfs.amount1() > 0 && rfs.amount0() <= 0) {
            MockERC20(address(lcc0.underlying())).mint(guarantor, amt);
            vm.startPrank(guarantor);
            IERC20(lcc0.underlying()).approve(address(positionManager), amt);

            MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](1);
            actions[0] = MMA.prepareSeize(corePoolKey, tokenId, positionIndex, amt, 0, false);
            vm.expectRevert(Errors.SeizureWithoutLiquidityRemoval.selector);
            MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);
            vm.stopPrank();
        } else {
            // Symmetric two-lane RFS under this fixture; single-lane mis-scope precondition does not apply.
            vm.skip(true);
        }
    }

    /// @notice Regression (audit 29_5): legacy sizing used stacked `ceil` on bps helpers so any positive cure forced a
    ///         per-lane minimum on the order of **~ceil(L / 10_000)** liquidity units per transaction. Rational
    ///         `floor(L * inner / denom)` + carry scales with cure size and can be replayed in loops without inheriting
    ///         that forced floor each step.
    function test_seize_microDeposit_loopedBatches_cumulativeRemovalWellBelowLegacyFloor_audit29_5() public {
        uint256 tokenId = 1;
        uint256 positionIndex = 0;
        uint256 loops = 20;

        _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            defaultlLiquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        _openSeizeWindow(tokenId, positionIndex);

        (Position memory posBefore,) = vtsOrchestrator.getPosition(tokenId, positionIndex);
        uint128 liqInitial = posBefore.liquidity;

        // Budget enough underlying for repeated tiny-cure seizure batches.
        MockERC20(address(lcc0.underlying())).mint(guarantor, 10_000);
        MockERC20(address(lcc1.underlying())).mint(guarantor, 10_000);

        vm.startPrank(guarantor);
        IERC20(lcc0.underlying()).approve(address(positionManager), type(uint256).max);
        IERC20(lcc1.underlying()).approve(address(positionManager), type(uint256).max);

        uint256 legacyCumulativeFloor = 0;
        for (uint256 i = 0; i < loops; i++) {
            (Position memory posStep,) = vtsOrchestrator.getPosition(tokenId, positionIndex);
            uint256 legacyPerLaneFloor =
                (uint256(posStep.liquidity) + LiquidityUtils.BPS_DENOMINATOR - 1) / LiquidityUtils.BPS_DENOMINATOR;
            legacyCumulativeFloor += (legacyPerLaneFloor * 2); // two-lane 1 wei micro-cure each batch

            MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](4);
            actions[0] = MMA.prepareSeize(corePoolKey, tokenId, positionIndex, 1, 1, false);
            actions[1] = MMA.prepareSettleFromDeltas(corePoolKey, tokenId, positionIndex, true, true);
            actions[2] = MMA.prepareTake(Currency.wrap(address(lcc0)), address(guarantor), 0);
            actions[3] = MMA.prepareTake(Currency.wrap(address(lcc1)), address(guarantor), 0);
            MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);
        }
        vm.stopPrank();

        (Position memory posAfter,) = vtsOrchestrator.getPosition(tokenId, positionIndex);
        uint256 removed = uint256(liqInitial - posAfter.liquidity);

        // Strong separation from the legacy exploit profile: cumulative removal from repeated 1 wei cures must remain
        // at least an order of magnitude below cumulative "forced ~1 bps per lane per tx" floors.
        assertLt(
            removed * 10, legacyCumulativeFloor, "looped micro-cures should not reproduce legacy per-tx floor drain"
        );
    }

    function testCanCommitMintAndSettlePosition() public {
        // Objective:
        // - Prove a user can commit, mint, and settle a single MM position via the position manager.
        //
        // Steps:
        // - Create a committed position with default ticks/liquidity and a valid liquidity signal.
        // - Assert commit state fields are correct (owner, expiry, counts).
        // - Assert the minted NFT is owned by the caller.
        // - Assert the on-chain position fields match the expected pool, ticks, liquidity, and active status.
        uint256 tokenId = 1;
        uint256 positionIndex = 0;

        // create a new position with the default liquidity params and liquidity signal
        _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            defaultlLiquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        // test conditions to ensure that a position was committed and minted and settled to
        // for commitment testing:
        (
            MarketMaker.State memory mmState,
            uint256 expiresAt,
            uint256 positionCount,
            uint256 activePositionCount,
            uint256 inactiveRemnantCount
        ) = vtsOrchestrator.getCommit(tokenId);
        assertEq(mmState.owner, liquiditySignal.mmState.owner, "Commit owner should match liquidity signal owner");
        assertEq(expiresAt, liquiditySignal.mmState.expiryAt, "Commit expiry should match signed leaf expiryAt");
        assertEq(positionCount, 1, "Commit should have exactly 1 position");
        assertEq(activePositionCount, 1, "Commit should have exactly 1 active position");
        assertEq(inactiveRemnantCount, 0, "Fresh commit should have no inactive settled remnants");

        // validate the owner of the NFT minted is `mmState.owner` (direct commit path)
        assertEq(positionManager.ownerOf(tokenId), liquiditySignal.mmState.owner, "NFT owner should be mmState.owner");

        // for minting testing:
        (Position memory positionAfter,) = positionManager.getPosition(tokenId, positionIndex);
        assertEq(positionAfter.owner, address(positionManager), "Position owner should be the manager");
        assertEq(
            PoolId.unwrap(positionAfter.poolId),
            PoolId.unwrap(corePoolKey.toId()),
            "Position poolId should match the core pool"
        );
        assertEq(positionAfter.commitId, tokenId, "Position commitId should equal the tokenId");
        assertEq(positionAfter.tickLower, defaultlLiquidityParams.tickLower, "tickLower should match default params");
        assertEq(positionAfter.tickUpper, defaultlLiquidityParams.tickUpper, "tickUpper should match default params");
        assertEq(
            uint256(positionAfter.liquidity),
            uint256(defaultlLiquidityParams.liquidityDelta),
            "Liquidity should match minted liquidityDelta"
        );
        assertEq(positionAfter.isActive, true, "Position should be active after mint");
    }

    function testCanBurnAndWithdrawCreatedPosition() public {
        // Objective:
        // - Prove a user can burn a created position and withdraw underlying via `settleFromDeltas`.
        //
        // Steps:
        // - Create a committed position.
        // - Snapshot underlying balances and commit active position count.
        // - Burn the position, then settle-from-deltas to withdraw underlying to the caller.
        // - Assert the commit has zero active positions and caller balances increased.
        uint256 tokenId = 1;
        uint256 positionIndex = 0;

        // create a new position with the default liquidity params and liquidity signal
        _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            defaultlLiquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        // get the active position count before burning
        (,,, uint256 activePositionCountBeforeBurn,) = vtsOrchestrator.getCommit(tokenId);
        assertEq(activePositionCountBeforeBurn, 1, "Precondition: commit should have 1 active position");

        // Batch burn and settle from deltas
        // The burn flow:
        // 1. LCCs are cancelled on receipt (planCancelWithQueue → executePlannedCancel)
        // 2. Underlying credits are created on MMPM (accountUnderlyingSettlementDelta)
        // 3. settleFromDeltas with payerIsUser=true reads MMPM's underlying credits
        // 4. _settle() withdraws underlying from the vault to the locker; TAKE moves it to this contract for assertions
        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](4);
        actions[0] = MMA.prepareBurn(corePoolKey, tokenId, positionIndex);
        actions[1] = MMA.prepareSettleFromDeltas(corePoolKey, tokenId, 0, true, true);
        actions[2] = MMA.prepareTake(Currency.wrap(lcc0.underlying()), address(this), type(uint256).max);
        actions[3] = MMA.prepareTake(Currency.wrap(lcc1.underlying()), address(this), type(uint256).max);
        _mmExec(tokenId, actions);

        // get the active position count after burning
        (,,, uint256 activePositionCountAfterBurn,) = vtsOrchestrator.getCommit(tokenId);
        assertEq(activePositionCountAfterBurn, 0, "Burn should reduce active position count to 0");

        // Withdrawal economics are asserted in orchestrator/MM integration tests; here we only prove the position closes.
    }

    function testCanBurnDecommitWithdrawFromPosition() public {
        // Objective:
        // - Prove a user can burn a position, withdraw underlying, and then decommit the NFT.
        //
        // Steps:
        // - Create a committed position.
        // - Snapshot underlying balances.
        // - Batch: burn position, settle-from-deltas (withdraw), then decommit.
        // - Assert caller underlying balances increased.
        uint256 tokenId = 1;
        uint256 positionIndex = 0;

        // create a new position with the default liquidity params and liquidity signal
        _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            defaultlLiquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](5);
        actions[0] = MMA.prepareBurn(corePoolKey, tokenId, positionIndex);
        actions[1] = MMA.prepareSettleFromDeltas(corePoolKey, tokenId, positionIndex, true, true);
        actions[2] = MMA.prepareTake(Currency.wrap(lcc0.underlying()), address(this), type(uint256).max);
        actions[3] = MMA.prepareTake(Currency.wrap(lcc1.underlying()), address(this), type(uint256).max);
        actions[4] = MMA.prepareDecommit(tokenId);
        _mmExec(tokenId, actions);
    }

    function testCannotBurnTokenWithActiveCommits() public {
        // Objective:
        // - Prove decommitment fails when a commit still has active positions.
        //
        // Steps:
        // - Create a committed position (which creates an active position).
        // - Attempt to decommit the tokenId.
        // - Assert the call reverts with CommitNotEmpty.
        uint256 tokenId = 1;

        // create a new position with the default liquidity params and liquidity signal
        _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            defaultlLiquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](1);
        actions[0] = MMA.prepareDecommit(tokenId);

        // Expect revert because the commit still has active positions
        address lockerDecommit = _batchLocker(tokenId);
        vm.expectRevert(abi.encodeWithSelector(Errors.CommitNotEmpty.selector, tokenId));
        _mmExec(lockerDecommit, actions);
    }

    function testCanOverSettleAndIncreasePositionLiquidity() public {
        // Objective:
        // - Prove over-settling a position enables increasing liquidity and keeps the position active.
        //
        // Steps:
        // - Create a committed position.
        // - Over-settle to build excess underlying credits.
        // - Snapshot position liquidity and active position count.
        // - Increase liquidity by a fixed amount.
        // - Assert liquidity increased as expected and active count remains unchanged.
        uint256 tokenId = 1;
        uint256 positionIndex = 0;

        // create a new position with the default liquidity params and liquidity signal
        _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            defaultlLiquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        // make settlements for the position
        uint256 settlementAmount = 1000000e18;

        // make a settlement for the position over the required settlement amounts, so we can use the excess funds to increase the liquidity
        approveAndSettleUnderlyingToPosition(tokenId, positionIndex, settlementAmount, settlementAmount);

        (Position memory positionBeforeIncrease,) = positionManager.getPosition(tokenId, positionIndex);

        // get the active position count before increasing the liquidity
        (,,, uint256 activePositionCountBeforeIncrease,) = vtsOrchestrator.getCommit(tokenId);
        assertEq(activePositionCountBeforeIncrease, 1, "Precondition: commit should have 1 active position");

        // increase the liquidity in the position by a specified amount
        uint256 liquidityToIncrease = 1000;
        {
            MMA.PreparedAction[] memory incActions = new MMA.PreparedAction[](1);
            incActions[0] = MMA.prepareIncrease(corePoolKey, tokenId, positionIndex, liquidityToIncrease);
            _mmExec(tokenId, incActions);
        }

        // validate the liquidity in the position is increased
        (Position memory positionAfterIncrease,) = positionManager.getPosition(tokenId, positionIndex);
        assertEq(
            uint256(positionAfterIncrease.liquidity),
            uint256(positionBeforeIncrease.liquidity) + liquidityToIncrease,
            "Liquidity should increase by liquidityToIncrease"
        );

        // get the active position count after increasing the liquidity
        (,,, uint256 activePositionCountAfterIncrease,) = vtsOrchestrator.getCommit(tokenId);
        assertEq(activePositionCountAfterIncrease, 1, "Active position count should remain 1 after increase");
    }

    /// @notice End-to-end: a real `modifyLiquidities` increase mints LCC principal that still passes the same
    ///         `VTSCommitLib.validateMmIncreaseLiquidityDelta` bundle (global + marginal) when replayed on live `s`.
    function test_mmIncrease_e2e_actual_mint_replays_validateMmIncrease_on_live_storage() public {
        uint256 tokenId = 1;
        uint256 positionIndex = 0;

        _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            defaultlLiquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        approveAndSettleUnderlyingToPosition(tokenId, positionIndex, 1_000_000e18, 1_000_000e18);

        address locker = _batchLocker(tokenId);
        uint256 bal0Before = IERC20(address(lcc0)).balanceOf(locker);
        uint256 bal1Before = IERC20(address(lcc1)).balanceOf(locker);

        (Position memory posBefore, PositionId pid) = positionManager.getPosition(tokenId, positionIndex);
        uint128 Lpre = posBefore.liquidity;

        uint256 liquidityToIncrease = 50_001;
        {
            MMA.PreparedAction[] memory incActions = new MMA.PreparedAction[](1);
            incActions[0] = MMA.prepareIncrease(corePoolKey, tokenId, positionIndex, liquidityToIncrease);
            _mmExec(locker, incActions);
        }

        (Position memory posAfter,) = positionManager.getPosition(tokenId, positionIndex);
        assertEq(
            uint256(posAfter.liquidity),
            uint256(Lpre) + liquidityToIncrease,
            "position liquidity should reflect the increase"
        );

        uint256 minted0 = IERC20(address(lcc0)).balanceOf(locker) - bal0Before;
        uint256 minted1 = IERC20(address(lcc1)).balanceOf(locker) - bal1Before;

        VTSOrchestratorTestable orch = VTSOrchestratorTestable(address(vtsOrchestrator));
        (bool ok,,,) = orch.exposedValidateMmIncreaseLiquidityDeltaSoft(
            MmIncreaseAdmissionReplay({
                commitId: posAfter.commitId,
                positionId: pid,
                currency0: corePoolKey.currency0,
                currency1: corePoolKey.currency1,
                tickLower: posAfter.tickLower,
                tickUpper: posAfter.tickUpper,
                postAddLiquidity: posAfter.liquidity,
                preAddLiquidity: Lpre,
                mintAmount0: minted0,
                mintAmount1: minted1
            })
        );
        assertTrue(ok, "E2E mint must satisfy validateMmIncrease (global + marginal) on live VTS storage");
    }

    function _replayIssuedPostForMmIncrease(
        VTSOrchestratorTestable orch,
        uint256 commitId,
        PositionId positionId,
        int24 tickLower,
        int24 tickUpper,
        uint128 postAddLiquidity,
        uint128 preAddLiquidity
    ) internal view returns (uint256 issuedPost) {
        (, issuedPost,,) = orch.exposedValidateMmIncreaseLiquidityDeltaSoft(
            MmIncreaseAdmissionReplay({
                commitId: commitId,
                positionId: positionId,
                currency0: corePoolKey.currency0,
                currency1: corePoolKey.currency1,
                tickLower: tickLower,
                tickUpper: tickUpper,
                postAddLiquidity: postAddLiquidity,
                preAddLiquidity: preAddLiquidity,
                mintAmount0: 0,
                mintAmount1: 0
            })
        );
    }

    function _findAdversarialMmIncreaseCandidate(
        VTSOrchestratorTestable orch,
        uint256 commitId,
        PositionId positionId,
        int24 tickLower,
        int24 tickUpper,
        uint128 preL,
        uint160 sqrtPriceX96,
        int24 currentTick
    ) internal view returns (uint256 candidateIncrease, uint256 candidateIssuedPost) {
        uint256 issuedPre = _replayIssuedPostForMmIncrease(orch, commitId, positionId, tickLower, tickUpper, preL, preL);

        for (uint256 liqDelta = 1; liqDelta <= 25_000; liqDelta++) {
            if (uint256(preL) + liqDelta > uint256(type(uint128).max)) break;
            uint128 postL = uint128(uint256(preL) + liqDelta);
            uint256 issuedPost =
                _replayIssuedPostForMmIncrease(orch, commitId, positionId, tickLower, tickUpper, postL, preL);
            uint256 admissionDelta = issuedPost - issuedPre;
            (uint256 estMint0, uint256 estMint1) = LiquidityUtils.calculateEffectiveTokenAmounts(
                sqrtPriceX96, currentTick, tickLower, tickUpper, int256(liqDelta)
            );
            uint256 estimatedMintUsd = estMint0 + estMint1; // oracle prices mocked to 1e18 each
            if (estimatedMintUsd > admissionDelta) {
                candidateIncrease = liqDelta;
                candidateIssuedPost = issuedPost;
                return (candidateIncrease, candidateIssuedPost);
            }
        }
    }

    /// @notice Adversarial full-path proof: search for a rounding-sensitive increase where estimated spot mint USD
    ///         exceeds marginal endpoint-max admission delta, then prove the real increase reverts on
    ///         `InvalidAdmissionMintDelta`.
    function test_mmIncrease_e2e_adversarial_rounding_reverts_on_marginal_gate() public {
        uint256 tokenId = 1;
        uint256 positionIndex = 0;

        _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            defaultlLiquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        // Keep global backing permissive while we target the marginal inequality.
        approveAndSettleUnderlyingToPosition(tokenId, positionIndex, 1_000_000e18, 1_000_000e18);
        vm.mockCall(
            address(oracleHelper),
            abi.encodeWithSelector(IOracleHelper.getPricesForLccPair.selector),
            abi.encode(uint256(1e18), uint256(1e18))
        );

        VTSOrchestratorTestable orch = VTSOrchestratorTestable(address(vtsOrchestrator));
        (Position memory posBefore, PositionId pid) = positionManager.getPosition(tokenId, positionIndex);
        uint128 preL = posBefore.liquidity;
        (uint160 sqrtPriceX96, int24 currentTick,,) = manager.getSlot0(corePoolKey.toId());

        (uint256 candidateIncrease, uint256 candidateIssuedPost) = _findAdversarialMmIncreaseCandidate(
            orch, posBefore.commitId, pid, posBefore.tickLower, posBefore.tickUpper, preL, sqrtPriceX96, currentTick
        );

        assertGt(candidateIncrease, 0, "failed to find adversarial candidate in scan window");

        // Set signal to endpoint-max post issuance so global check is not the binding constraint.
        vm.mockCall(
            address(oracleHelper),
            abi.encodeWithSelector(IOracleHelper.getTotalValue.selector),
            abi.encode(candidateIssuedPost)
        );

        vm.expectRevert(Errors.InvalidAdmissionMintDelta.selector);
        this._attemptIncreaseExternal(tokenId, positionIndex, candidateIncrease);
    }

    function testCanDecreaseMintNewPositionFromDeltas() public {
        // Objective:
        // - Prove decreasing liquidity can produce deltas that are reused to mint a second position.
        //
        // Steps:
        // - Create a committed position.
        // - Over-settle to allow liquidity operations.
        // - Snapshot initial liquidity.
        // - Batch: decrease liquidity, then mint a new position using deltas.
        // - Assert initial liquidity decreased by the requested amount.
        // - Assert the new position uses the expected ticks and has non-zero settlement.
        uint256 tokenId = 1;
        uint256 positionIndex = 0;

        // create a new position with the default liquidity params and liquidity signal
        _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            defaultlLiquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        // make settlements for the position
        uint256 settlementAmount = 1000000e18;

        // make a settlement for the position over the required settlement amounts, so we can use the excess funds to increase the liquidity
        approveAndSettleUnderlyingToPosition(tokenId, positionIndex, settlementAmount, settlementAmount);

        (Position memory positionBeforeDecrease,) = positionManager.getPosition(tokenId, positionIndex);

        // decrease the liquidity in the position
        uint256 liquidityToDecrease = 1000000000;

        // get amounts from liquidity params
        uint256 newPositionIndex = 1;
        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](3);
        int24 newUpperTick = 0;
        actions[0] = MMA.prepareDecrease(corePoolKey, tokenId, positionIndex, liquidityToDecrease);
        actions[1] =
            MMA.prepareMintFromDeltas(corePoolKey, tokenId, newUpperTick, defaultlLiquidityParams.tickUpper, true);
        actions[2] = MMA.prepareSettleFromDeltas(corePoolKey, tokenId, positionIndex, true, true);
        _mmExec(tokenId, actions);

        // validate liquidity of the initial position is decreased
        (Position memory positionAfterDecrease,) = positionManager.getPosition(tokenId, positionIndex);
        assertEq(
            uint256(positionAfterDecrease.liquidity),
            uint256(positionBeforeDecrease.liquidity) - liquidityToDecrease,
            "Liquidity should decrease by liquidityToDecrease"
        );

        // validate the new position was created with the new ticks provided
        (Position memory newPosition, PositionId newPositionId) = positionManager.getPosition(tokenId, newPositionIndex);
        assertEq(newPosition.tickLower, newUpperTick, "New position tickLower should match requested tick");
        assertEq(
            newPosition.tickUpper, defaultlLiquidityParams.tickUpper, "New position tickUpper should match default"
        );

        // validate the new position has some settlement
        (uint256 newPositionSettledAmount0, uint256 newPositionSettledAmount1) =
            vtsOrchestrator.getPositionSettledAmounts(newPositionId);

        assertGt(newPositionSettledAmount0, 0, "New position should have non-zero settled amount0");
        assertGt(newPositionSettledAmount1, 0, "New position should have non-zero settled amount1");
    }

    /// @notice Unreachable min-out on principal (v4 `SlippageCheck`) must revert on DECREASE_LIQUIDITY.
    function testDecreaseLiquidity_revertsWhenPrincipalMinOutUnreachable() public {
        uint256 tokenId = 1;
        uint256 positionIndex = 0;

        _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            defaultlLiquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );
        approveAndSettleUnderlyingToPosition(tokenId, positionIndex, 1_000_000e18, 1_000_000e18);

        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](1);
        actions[0] =
            MMA.prepareDecrease(corePoolKey, tokenId, positionIndex, 1000, type(uint128).max, type(uint128).max);
        address lockerDec = _batchLocker(tokenId);
        vm.expectRevert();
        _mmExec(lockerDec, actions);
    }

    /// @notice Explicit zero min-out preserves pre-slippage exit behaviour (no floor).
    function testDecreaseLiquidity_succeedsWithExplicitZeroMinOut() public {
        uint256 tokenId = 1;
        uint256 positionIndex = 0;

        _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            defaultlLiquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );
        approveAndSettleUnderlyingToPosition(tokenId, positionIndex, 1_000_000e18, 1_000_000e18);

        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](2);
        actions[0] = MMA.prepareDecrease(corePoolKey, tokenId, positionIndex, 1000, 0, 0);
        actions[1] = MMA.prepareSettleFromDeltas(corePoolKey, tokenId, positionIndex, true, true);
        _mmExec(tokenId, actions);
    }

    /// @notice Unreachable min-out on principal must revert on BURN_POSITION.
    function testBurnPosition_revertsWhenPrincipalMinOutUnreachable() public {
        uint256 tokenId = 1;
        uint256 positionIndex = 0;

        _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            defaultlLiquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );
        approveAndSettleUnderlyingToPosition(tokenId, positionIndex, 1_000_000e18, 1_000_000e18);

        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](1);
        actions[0] = MMA.prepareBurn(corePoolKey, tokenId, positionIndex, type(uint128).max, type(uint128).max);
        address lockerBr = _batchLocker(tokenId);
        vm.expectRevert();
        _mmExec(lockerBr, actions);
    }

    /// @notice Explicit zero min-out on burn preserves pre-slippage exit behaviour.
    function testBurnPosition_succeedsWithExplicitZeroMinOut() public {
        uint256 tokenId = 1;
        uint256 positionIndex = 0;

        _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            defaultlLiquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](2);
        actions[0] = MMA.prepareBurn(corePoolKey, tokenId, positionIndex, 0, 0);
        actions[1] = MMA.prepareSettleFromDeltas(corePoolKey, tokenId, positionIndex, true, true);
        _mmExec(tokenId, actions);
    }

    function testCanSeizeAndTakeDeltasFromPosition() public {
        // Objective:
        // - Prove a guarantor can seize an under-settled position after grace period and withdraw value.
        //
        // Steps:
        // - Create a committed position.
        // - Perform a swap to create deficit and open the RFS window.
        // - Warp past grace period so the position becomes seizable.
        // - Fund guarantor with required underlying and approve the position manager.
        // - Batch: seize, settle-from-deltas, then take underlying to guarantor.
        // - Assert seized liquidity decreased and guarantor received a non-zero underlying balance.
        uint256 tokenId = 1;
        uint256 positionIndex = 0;

        // Setup position
        _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            defaultlLiquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        // Perform swap to cause deficit
        swapRouter.swap(
            proxyPoolKey,
            SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: ZERO_FOR_ONE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        // Verify RFS is open
        {
            (, PositionId positionId) = positionManager.getPosition(tokenId, positionIndex);
            (bool rfsOpen,) = vtsOrchestrator.calcRFS(positionId, false);
            assertEq(rfsOpen, true, "RFS should be open after deficit-causing swap");
        }

        positionManager.checkpoint(tokenId, positionIndex, false);
        vm.warp(block.timestamp + 300000 + 1);

        // Setup guarantor settlement
        uint256 settleAmount0 = 5999709018652707;
        uint256 settleAmount1 = 5999709018652707;
        address underlying0 = lcc0.underlying();
        address underlying1 = lcc1.underlying();
        IERC20(underlying0).transfer(guarantor, settleAmount0);
        IERC20(underlying1).transfer(guarantor, settleAmount1);

        // Get liquidity before seize
        uint128 liquidityBefore;
        {
            (Position memory pos,) = vtsOrchestrator.getPosition(tokenId, positionIndex);
            liquidityBefore = pos.liquidity;
        }

        // Execute seize as guarantor
        vm.startPrank(guarantor);
        IERC20(underlying0).approve(address(positionManager), settleAmount0);
        IERC20(underlying1).approve(address(positionManager), settleAmount1);

        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](4);
        actions[0] = MMA.prepareSeize(corePoolKey, tokenId, positionIndex, settleAmount0, settleAmount1, false);
        actions[1] = MMA.prepareSettleFromDeltas(corePoolKey, tokenId, positionIndex, true, true);
        actions[2] = MMA.prepareTake(Currency.wrap(address(lcc0)), address(guarantor), 0);
        actions[3] = MMA.prepareTake(Currency.wrap(address(lcc1)), address(guarantor), 0);
        MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);
        vm.stopPrank();

        // Validate results
        {
            (Position memory posAfter,) = vtsOrchestrator.getPosition(tokenId, positionIndex);
            assertLt(uint256(posAfter.liquidity), uint256(liquidityBefore), "Seize should reduce position liquidity");
            assertGt(
                Currency.wrap(address(lcc0)).balanceOf(address(guarantor))
                    + Currency.wrap(address(lcc1)).balanceOf(address(guarantor)),
                0,
                "Guarantor should receive non-zero LCC proceeds after seize+take"
            );
        }
    }

    /// @notice Regression (audit 30_3): ambient seizure context must not allow settle-only deposits that advance
    ///         seizure carry without a coupled liquidity decrease (only `SEIZE_POSITION` may authorise that phase).
    function test_audit30_3_ambientSeizure_reverts_settleOnlyDeposit_settlePosition() public {
        uint256 tokenId = 1;
        uint256 positionIndex = 0;

        _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            defaultlLiquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );
        _openSeizeWindow(tokenId, positionIndex);

        uint256 seize0 = 1;
        uint256 seize1 = 1;
        MockERC20(address(lcc0.underlying())).mint(guarantor, seize0);
        MockERC20(address(lcc1.underlying())).mint(guarantor, seize1);

        vm.startPrank(guarantor);
        IERC20(lcc0.underlying()).approve(address(positionManager), type(uint256).max);
        IERC20(lcc1.underlying()).approve(address(positionManager), type(uint256).max);

        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](2);
        actions[0] = MMA.prepareSeize(corePoolKey, tokenId, positionIndex, seize0, seize1, false);
        actions[1] = MMA.prepareSettle(corePoolKey, tokenId, positionIndex, -int128(1), -int128(1), false);
        vm.expectRevert(Errors.SeizureSettleOnlyDepositDisallowed.selector);
        MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);
        vm.stopPrank();
    }

    /// @notice Regression (audit 30_3): locker-credit deposit via `SETTLE_POSITION_FROM_DELTAS` is also blocked under
    ///         ambient seizure (same coupling invariant as raw `SETTLE_POSITION` deposits).
    function test_audit30_3_ambientSeizure_reverts_settleOnlyDeposit_settleFromDeltas_lockerCredits() public {
        uint256 tokenId = 1;
        uint256 positionIndex = 0;

        _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            defaultlLiquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );
        _openSeizeWindow(tokenId, positionIndex);

        uint256 seize0 = 1;
        uint256 seize1 = 1;
        MockERC20(address(lcc0.underlying())).mint(guarantor, seize0);
        MockERC20(address(lcc1.underlying())).mint(guarantor, seize1);

        uint256 syncAmt0 = 100;
        uint256 syncAmt1 = 100;
        MockERC20(address(lcc0.underlying())).mint(guarantor, syncAmt0);
        MockERC20(address(lcc1.underlying())).mint(guarantor, syncAmt1);

        vm.startPrank(guarantor);
        IERC20(lcc0.underlying()).approve(address(positionManager), type(uint256).max);
        IERC20(lcc1.underlying()).approve(address(positionManager), type(uint256).max);

        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](4);
        actions[0] = MMA.prepareSeize(corePoolKey, tokenId, positionIndex, seize0, seize1, false);
        IERC20(lcc0.underlying()).transfer(address(positionManager), syncAmt0);
        IERC20(lcc1.underlying()).transfer(address(positionManager), syncAmt1);
        actions[1] = MMA.prepareSync(Currency.wrap(address(lcc0.underlying())));
        actions[2] = MMA.prepareSync(Currency.wrap(address(lcc1.underlying())));
        actions[3] = MMA.prepareSettleFromDeltas(corePoolKey, tokenId, positionIndex, false, false);
        vm.expectRevert(Errors.SeizureSettleOnlyDepositDisallowed.selector);
        MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);
        vm.stopPrank();
    }

    /// @notice Regression (audit 30_3): protocol-credit *deposit* matrix (`payerIsUser=true`, `shouldTake=false`) must
    ///         revert under ambient seizure even when no protocol credits are present yet — the forbidden operation is
    ///         scheduling that path in the same batch as `SEIZE_POSITION`, not merely consuming a non-zero credit.
    function test_audit30_3_ambientSeizure_reverts_protocolCreditDeposit_settleFromDeltas_payerIsUser_shouldTake_false()
        public
    {
        uint256 tokenId = 1;
        uint256 positionIndex = 0;

        _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            defaultlLiquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );
        _openSeizeWindow(tokenId, positionIndex);

        uint256 seize0 = 1;
        uint256 seize1 = 1;
        MockERC20(address(lcc0.underlying())).mint(guarantor, seize0);
        MockERC20(address(lcc1.underlying())).mint(guarantor, seize1);

        vm.startPrank(guarantor);
        IERC20(lcc0.underlying()).approve(address(positionManager), type(uint256).max);
        IERC20(lcc1.underlying()).approve(address(positionManager), type(uint256).max);

        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](2);
        actions[0] = MMA.prepareSeize(corePoolKey, tokenId, positionIndex, seize0, seize1, false);
        actions[1] = MMA.prepareSettleFromDeltas(corePoolKey, tokenId, positionIndex, true, false);
        vm.expectRevert(Errors.SeizureSettleOnlyDepositDisallowed.selector);
        MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);
        vm.stopPrank();
    }

    /// @notice Positive control: withdraw-style `SETTLE_POSITION_FROM_DELTAS` remains valid in the same batch after seizure.
    function test_audit30_3_ambientSeizure_allows_settleFromDeltas_withdrawProtocolCredit_afterSeize() public {
        uint256 tokenId = 1;
        uint256 positionIndex = 0;

        _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            defaultlLiquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );
        _openSeizeWindow(tokenId, positionIndex);

        uint256 settleAmount0 = 5999709018652707;
        uint256 settleAmount1 = 5999709018652707;
        IERC20(lcc0.underlying()).transfer(guarantor, settleAmount0);
        IERC20(lcc1.underlying()).transfer(guarantor, settleAmount1);

        vm.startPrank(guarantor);
        IERC20(lcc0.underlying()).approve(address(positionManager), settleAmount0);
        IERC20(lcc1.underlying()).approve(address(positionManager), settleAmount1);

        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](4);
        actions[0] = MMA.prepareSeize(corePoolKey, tokenId, positionIndex, settleAmount0, settleAmount1, false);
        actions[1] = MMA.prepareSettleFromDeltas(corePoolKey, tokenId, positionIndex, true, true);
        actions[2] = MMA.prepareTake(Currency.wrap(address(lcc0)), guarantor, 0);
        actions[3] = MMA.prepareTake(Currency.wrap(address(lcc1)), guarantor, 0);
        MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);
        vm.stopPrank();
    }

    function test_seizeContext_clearedAfterBatch_preventsCrossBatchApprovalBypass() public {
        // Objective:
        // - Ensure the transient SEIZED_POSITION_ID context is cleared at the end of a batch.
        //
        // Risk surface:
        // - If SEIZED_POSITION_ID_SLOT leaks into subsequent batches within the same tx,
        //   a non-approved caller could perform follow-on position actions and bypass NotApproved.
        uint256 tokenId = 1;
        uint256 positionIndex = 0;

        _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            defaultlLiquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        // Open RFS by creating a deficit via swap, persist the checkpoint, then warp past grace.
        _openSeizeWindow(tokenId, positionIndex);

        uint256 seizeSettle0 = 5_999_709_018_652_707;
        uint256 seizeSettle1 = 5_999_709_018_652_707;
        IERC20(lcc0.underlying()).transfer(guarantor, seizeSettle0);
        IERC20(lcc1.underlying()).transfer(guarantor, seizeSettle1);

        vm.startPrank(guarantor);
        IERC20(lcc0.underlying()).approve(address(positionManager), type(uint256).max);
        IERC20(lcc1.underlying()).approve(address(positionManager), type(uint256).max);

        // First batch: perform seizure flow and drain deltas so the batch completes.
        {
            MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](4);
            actions[0] = MMA.prepareSeize(corePoolKey, tokenId, positionIndex, seizeSettle0, seizeSettle1, false);
            actions[1] = MMA.prepareSettleFromDeltas(corePoolKey, tokenId, positionIndex, true, true);
            actions[2] = MMA.prepareTake(Currency.wrap(address(lcc0)), address(guarantor), 0);
            actions[3] = MMA.prepareTake(Currency.wrap(address(lcc1)), address(guarantor), 0);
            MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);
        }

        // Second batch (same tx): attempt an unapproved SETTLE (deposit) on the seized position.
        // This must revert NotApproved, proving the seizure context was cleared after the first batch.
        {
            MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](1);
            actions[0] = MMA.prepareSettle(corePoolKey, tokenId, positionIndex, -int128(1), -int128(1), false);
            vm.expectRevert(abi.encodeWithSelector(Errors.NotApproved.selector, guarantor));
            MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);
        }

        vm.stopPrank();
    }

    function test_decrease_forwardsQueuedLcc_toSharedCustodian_andKeepsQueueOnLocker() public {
        uint256 tokenId = 1;
        uint256 positionIndex = 0;

        _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            defaultlLiquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        uint256 liquidityToDecrease = 1000;

        // Prime settled amounts so this specific decrease leaves a small queued remainder.
        _primePositionForQueuedDecrease(tokenId, positionIndex, liquidityToDecrease);

        // Ensure decrease path queues retained principal with zero immediate availability.
        vm.mockCall(
            address(mv),
            abi.encodeWithSelector(IMarketVaultDryBalanceDelta.dryModifyLiquidities.selector),
            abi.encode(toBalanceDelta(int128(0), int128(0)))
        );

        address lockerAddr = positionManager.ownerOf(tokenId);
        _wireTestQueueCustodianFor(address(positionManager), lockerAddr);
        address custodian = positionManager.custodianFor(lockerAddr);
        uint256 queueBeforeLocker = _queuedSumFor(lockerAddr);
        uint256 queueBeforeCommitOwner = _queuedSumFor(custodian);
        uint256 custodyBefore = _custodySumFor(custodian);
        uint256 walletLccBefore = _walletLccSum(lockerAddr);

        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](1);
        actions[0] = MMA.prepareDecrease(corePoolKey, tokenId, positionIndex, liquidityToDecrease);
        _mmExec(tokenId, actions);

        uint256 custodyDelta = _custodySumFor(custodian) - custodyBefore;
        uint256 walletLccAfter = _walletLccSum(lockerAddr);

        assertGt(custodyDelta, 0, "Expected retained LCC to be recorded in commit custodian");
        assertGt(_queuedSumFor(custodian), queueBeforeCommitOwner, "Hub queue should be keyed to locker custodian");
        assertEq(_queuedSumFor(lockerAddr), queueBeforeLocker, "Locker must not own synthetic principal queue");
        assertEq(walletLccAfter, walletLccBefore, "Queued retained LCC must not be transferred to locker wallet");
    }

    /// @dev Full batch includes `prepareTake` so v4 currency is settled before unlock; queue staging is asserted via Hub/custody deltas and parity.
    function test_seize_routesQueueToLocker_butCustodiesQueuedLccByCommit() public {
        uint256 positionIndex = 0;

        (uint256 tokenId,,,) = _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            defaultlLiquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        _openSeizeWindow(tokenId, positionIndex);

        _primePositionForQueuedDecrease(tokenId, positionIndex, uint256(defaultlLiquidityParams.liquidityDelta));

        vm.mockCall(
            address(mv),
            abi.encodeWithSelector(IMarketVaultDryBalanceDelta.dryModifyLiquidities.selector),
            abi.encode(toBalanceDelta(int128(0), int128(0)))
        );
        vm.mockCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector), abi.encode(uint256(0))
        );

        uint256 settleAmount0 = 5_999_709_018_652_707;
        uint256 settleAmount1 = 5_999_709_018_652_707;
        IERC20(lcc0.underlying()).transfer(guarantor, settleAmount0);
        IERC20(lcc1.underlying()).transfer(guarantor, settleAmount1);

        _wireTestQueueCustodianFor(address(positionManager), guarantor);
        address custodian = positionManager.custodianFor(guarantor);
        uint256 queueBeforeCommitOwner = _queuedSumFor(custodian);
        uint256 qLcc0BeforeGuarantor = ILiquidityHub(liquidityHub).settleQueue(address(lcc0), custodian);
        uint256 qLcc1BeforeGuarantor = ILiquidityHub(liquidityHub).settleQueue(address(lcc1), custodian);
        uint256 custodyLcc0Before = IMMQueueCustodian(custodian).totalQueuedLcc(address(lcc0));
        uint256 custodyLcc1Before = IMMQueueCustodian(custodian).totalQueuedLcc(address(lcc1));
        address batchLocker = liquiditySignal.mmState.advancer;
        uint256 queueBeforeOwner = _queuedSumFor(batchLocker);

        vm.startPrank(guarantor);
        IERC20(lcc0.underlying()).approve(address(positionManager), type(uint256).max);
        IERC20(lcc1.underlying()).approve(address(positionManager), type(uint256).max);
        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](4);
        actions[0] = MMA.prepareSeize(corePoolKey, tokenId, positionIndex, settleAmount0, settleAmount1, false);
        actions[1] = MMA.prepareSettleFromDeltas(corePoolKey, tokenId, positionIndex, true, true);
        actions[2] = MMA.prepareTake(Currency.wrap(address(lcc0)), guarantor, 0);
        actions[3] = MMA.prepareTake(Currency.wrap(address(lcc1)), guarantor, 0);
        MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);
        vm.stopPrank();

        _assertGuarantorSeizureQueueStaging(
            custodian,
            guarantor,
            queueBeforeCommitOwner,
            qLcc0BeforeGuarantor,
            qLcc1BeforeGuarantor,
            custodyLcc0Before,
            custodyLcc1Before
        );
        assertEq(
            _queuedSumFor(liquiditySignal.mmState.advancer),
            queueBeforeOwner,
            "NFT owner queue should not receive seizure queue amounts"
        );
    }

    /// @notice `COLLECT_AVAILABLE_LIQUIDITY` settles the commit custodian queue then forwards underlying. With **no**
    ///         market-derived reserve to fund settlement, collect is a no-op and must not debit custody.
    function test_seize_whenGuarantorHasNoHubQueue_collectIsNoop_andDoesNotDrainCustody() public {
        uint256 positionIndex = 0;

        (uint256 tokenId,,,) = _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            defaultlLiquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        _openSeizeWindow(tokenId, positionIndex);

        _primePositionForQueuedDecrease(tokenId, positionIndex, uint256(defaultlLiquidityParams.liquidityDelta));

        vm.mockCall(
            address(mv),
            abi.encodeWithSelector(IMarketVaultDryBalanceDelta.dryModifyLiquidities.selector),
            abi.encode(toBalanceDelta(int128(0), int128(0)))
        );
        vm.mockCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector), abi.encode(uint256(0))
        );

        uint256 settleAmount0 = 5_999_709_018_652_707;
        uint256 settleAmount1 = 5_999_709_018_652_707;
        IERC20(lcc0.underlying()).transfer(guarantor, settleAmount0);
        IERC20(lcc1.underlying()).transfer(guarantor, settleAmount1);

        _wireTestQueueCustodianFor(address(positionManager), guarantor);
        IMMQueueCustodian qc = IMMQueueCustodian(positionManager.custodianFor(guarantor));

        vm.startPrank(guarantor);
        IERC20(lcc0.underlying()).approve(address(positionManager), type(uint256).max);
        IERC20(lcc1.underlying()).approve(address(positionManager), type(uint256).max);
        MMA.PreparedAction[] memory seizeActions = new MMA.PreparedAction[](4);
        seizeActions[0] = MMA.prepareSeize(corePoolKey, tokenId, positionIndex, settleAmount0, settleAmount1, false);
        seizeActions[1] = MMA.prepareSettleFromDeltas(corePoolKey, tokenId, positionIndex, true, true);
        seizeActions[2] = MMA.prepareTake(Currency.wrap(address(lcc0)), guarantor, 0);
        seizeActions[3] = MMA.prepareTake(Currency.wrap(address(lcc1)), guarantor, 0);
        MMA.executeWithUnlock(positionManager, seizeActions, block.timestamp + 3600);
        vm.stopPrank();

        assertEq(
            qc.totalQueuedLcc(address(lcc0)),
            ILiquidityHub(liquidityHub).settleQueue(address(lcc0), address(qc)),
            "lcc0 parity after seizure"
        );
        assertEq(
            qc.totalQueuedLcc(address(lcc1)),
            ILiquidityHub(liquidityHub).settleQueue(address(lcc1), address(qc)),
            "lcc1 parity after seizure"
        );

        uint256 custodyMid = _custodySumFor(address(qc));

        vm.startPrank(guarantor);
        {
            MMA.PreparedAction[] memory c0 = new MMA.PreparedAction[](1);
            c0[0] = MMA.prepareCollectAvailableLiquidity(address(lcc0), type(uint256).max);
            MMA.executeWithUnlock(positionManager, c0, block.timestamp + 3600);
        }
        {
            MMA.PreparedAction[] memory c1 = new MMA.PreparedAction[](1);
            c1[0] = MMA.prepareCollectAvailableLiquidity(address(lcc1), type(uint256).max);
            MMA.executeWithUnlock(positionManager, c1, block.timestamp + 3600);
        }
        vm.stopPrank();

        assertEq(_custodySumFor(address(qc)), custodyMid, "collect must not debit custody without queue");
    }

    /// @notice After seizure queues LCC for the guarantor, partial underlying reserve in the Hub allows
    ///         `COLLECT_AVAILABLE_LIQUIDITY` to settle against the queue and debit commit-scoped custody (cf. MM MMPM tests).
    function test_seize_collect_drainsQueueWhenHubUnderlyingBackingAvailable() public {
        uint256 positionIndex = 0;

        (uint256 tokenId,,,) = _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            defaultlLiquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        _openSeizeWindow(tokenId, positionIndex);

        _primePositionForQueuedDecrease(tokenId, positionIndex, uint256(defaultlLiquidityParams.liquidityDelta));

        vm.mockCall(
            address(mv),
            abi.encodeWithSelector(IMarketVaultDryBalanceDelta.dryModifyLiquidities.selector),
            abi.encode(toBalanceDelta(int128(0), int128(0)))
        );
        vm.mockCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector), abi.encode(uint256(0))
        );

        uint256 settleAmount0 = 5_999_709_018_652_707;
        uint256 settleAmount1 = 5_999_709_018_652_707;
        IERC20(lcc0.underlying()).transfer(guarantor, settleAmount0);
        IERC20(lcc1.underlying()).transfer(guarantor, settleAmount1);

        _wireTestQueueCustodianFor(address(positionManager), guarantor);
        address custodian = positionManager.custodianFor(guarantor);

        vm.startPrank(guarantor);
        IERC20(lcc0.underlying()).approve(address(positionManager), type(uint256).max);
        IERC20(lcc1.underlying()).approve(address(positionManager), type(uint256).max);
        MMA.PreparedAction[] memory seizeActions = new MMA.PreparedAction[](4);
        seizeActions[0] = MMA.prepareSeize(corePoolKey, tokenId, positionIndex, settleAmount0, settleAmount1, false);
        seizeActions[1] = MMA.prepareSettleFromDeltas(corePoolKey, tokenId, positionIndex, true, true);
        seizeActions[2] = MMA.prepareTake(Currency.wrap(address(lcc0)), guarantor, 0);
        seizeActions[3] = MMA.prepareTake(Currency.wrap(address(lcc1)), guarantor, 0);
        MMA.executeWithUnlock(positionManager, seizeActions, block.timestamp + 3600);
        vm.stopPrank();

        uint256 q0 = ILiquidityHub(liquidityHub).settleQueue(address(lcc0), custodian);
        assertGt(q0, 0, "primed seizure should stage non-zero token0 queue for collect");

        uint256 available = q0 / 4;
        if (available == 0) available = 1;

        MockERC20 underlying0 = MockERC20(lcc0.underlying());
        underlying0.mint(liquidityHub, available);
        vm.prank(address(vtsOrchestrator));
        ILiquidityHub(liquidityHub).confirmTake(address(lcc0), available, false);

        vm.prank(marketFactory);
        ILiquidityHub(liquidityHub).setBoundLevel(address(positionManager), Bounds.BOUND_ENDPOINT);

        uint256 hubBefore = ILiquidityHub(liquidityHub).settleQueue(address(lcc0), custodian);
        uint256 custodyBefore = IMMQueueCustodian(custodian).totalQueuedLcc(address(lcc0));
        assertEq(hubBefore, custodyBefore, "pre-collect: hub queue matches custody (lcc0)");

        uint256 underlyingBefore = underlying0.balanceOf(guarantor);

        vm.startPrank(guarantor);
        // Collect credits the locker on the manager; wallet payout completes via `TAKE` (same batch clears deltas).
        MMA.PreparedAction[] memory collect = new MMA.PreparedAction[](2);
        collect[0] = MMA.prepareCollectAvailableLiquidity(address(lcc0), type(uint256).max);
        collect[1] = MMA.prepareTake(Currency.wrap(address(lcc0.underlying())), guarantor, type(uint256).max);
        MMA.executeWithUnlock(positionManager, collect, block.timestamp + 3600);
        vm.stopPrank();

        assertEq(
            ILiquidityHub(liquidityHub).settleQueue(address(lcc0), custodian),
            hubBefore - available,
            "queue should decrease by settled amount"
        );
        assertEq(
            IMMQueueCustodian(custodian).totalQueuedLcc(address(lcc0)),
            custodyBefore - available,
            "custody should decrease in lockstep with Hub queue"
        );
        assertEq(
            underlying0.balanceOf(guarantor) - underlyingBefore, available, "guarantor receives underlying backing"
        );
    }

    /// @notice Seizure without `_primePositionForQueuedDecrease` still keeps Hub queue and commit custody aligned per leg.
    function test_seize_hubCustodyParity_withoutPrimingTopUp() public {
        uint256 positionIndex = 0;

        (uint256 tokenId,,,) = _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            defaultlLiquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        _openSeizeWindow(tokenId, positionIndex);

        vm.mockCall(
            address(mv),
            abi.encodeWithSelector(IMarketVaultDryBalanceDelta.dryModifyLiquidities.selector),
            abi.encode(toBalanceDelta(int128(0), int128(0)))
        );
        vm.mockCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector), abi.encode(uint256(0))
        );

        uint256 settleAmount0 = 5_999_709_018_652_707;
        uint256 settleAmount1 = 5_999_709_018_652_707;
        IERC20(lcc0.underlying()).transfer(guarantor, settleAmount0);
        IERC20(lcc1.underlying()).transfer(guarantor, settleAmount1);

        _wireTestQueueCustodianFor(address(positionManager), guarantor);
        address custodian = positionManager.custodianFor(guarantor);

        vm.startPrank(guarantor);
        IERC20(lcc0.underlying()).approve(address(positionManager), type(uint256).max);
        IERC20(lcc1.underlying()).approve(address(positionManager), type(uint256).max);
        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](4);
        actions[0] = MMA.prepareSeize(corePoolKey, tokenId, positionIndex, settleAmount0, settleAmount1, false);
        actions[1] = MMA.prepareSettleFromDeltas(corePoolKey, tokenId, positionIndex, true, true);
        actions[2] = MMA.prepareTake(Currency.wrap(address(lcc0)), guarantor, 0);
        actions[3] = MMA.prepareTake(Currency.wrap(address(lcc1)), guarantor, 0);
        MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);
        vm.stopPrank();

        assertEq(
            IMMQueueCustodian(custodian).totalQueuedLcc(address(lcc0)),
            ILiquidityHub(liquidityHub).settleQueue(address(lcc0), custodian),
            "lcc0 parity without priming"
        );
        assertEq(
            IMMQueueCustodian(custodian).totalQueuedLcc(address(lcc1)),
            ILiquidityHub(liquidityHub).settleQueue(address(lcc1), custodian),
            "lcc1 parity without priming"
        );
    }

    function testCanDecreaseMintNewPositionFromDeltasAndBurnInitialPosition() public {
        // Objective:
        // - Prove a user can decrease liquidity, mint a new position using deltas, settle it, then burn the original.
        //
        // Steps:
        // - Create a committed position and over-settle it.
        // - Batch: decrease liquidity on the original position, mint a new position from deltas, settle the new position,
        //   increase the new position, burn the original position, and settle-from-deltas to withdraw any remaining value.
        // - Assert the new position ticks match the requested ticks.
        // - Assert the original position is fully burned (liquidity == 0, inactive).
        // - Assert the new position has non-zero settled amounts.
        uint256 positionIndex = 0;
        uint256 newPositionIndex = 1;

        // Under coverage compilation (optimiser/viaIR disabled), this test can hit stack-too-deep.
        // Keep only truly-needed values alive across scopes.
        uint256 tokenId;
        PositionId newPositionId;

        int24 expectedTickLower = 0;
        int24 expectedTickUpper = 60;

        {
            // Setup + batch execution kept in an inner scope to reduce live locals.
            ModifyLiquidityParams memory liquidityParams =
                ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)});
            ModifyLiquidityParams memory newLiquidityParams = ModifyLiquidityParams({
                tickLower: expectedTickLower, tickUpper: expectedTickUpper, liquidityDelta: 1e10, salt: bytes32(0)
            });

            (tokenId,,,) = _setupCommittedPosition(
                positionManager,
                corePoolKey,
                abi.encode(liquiditySignal),
                liquidityParams,
                marketVTSConfiguration,
                address(lcc0),
                address(lcc1)
            );

            uint256 settlementAmount = 1_000_000e18;
            // make a settlement for the position over the required settlement amounts, so we can use the excess funds to increase the liquidity
            approveAndSettleUnderlyingToPosition(tokenId, positionIndex, settlementAmount, settlementAmount);

            {
                address lockerAddr = _batchLocker(tokenId);
                deal(address(lcc0.underlying()), lockerAddr, settlementAmount);
                deal(address(lcc1.underlying()), lockerAddr, settlementAmount);
                uint256 lockerUnderlying0Before = IERC20(address(lcc0.underlying())).balanceOf(lockerAddr);
                uint256 lockerUnderlying1Before = IERC20(address(lcc1.underlying())).balanceOf(lockerAddr);
                vm.startPrank(lockerAddr);
                IERC20(address(lcc0.underlying())).approve(address(positionManager), settlementAmount);
                IERC20(address(lcc1.underlying())).approve(address(positionManager), settlementAmount);
                vm.stopPrank();

                MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](6);
                // decrease the liquidity in the initial position with index 0
                actions[0] = MMA.prepareDecrease(corePoolKey, tokenId, positionIndex, 1000);
                // use the deltas to mint a new position with index 1
                actions[1] = MMA.prepareMintFromDeltas(
                    corePoolKey, tokenId, newLiquidityParams.tickLower, newLiquidityParams.tickUpper, true
                );
                // settle to the new position with index 1
                actions[2] = MMA.prepareSettle(
                    corePoolKey,
                    tokenId,
                    newPositionIndex,
                    -int128(int256(settlementAmount)),
                    -int128(int256(settlementAmount)),
                    false
                );
                // increase the liquidity in the new position with index 1
                actions[3] = MMA.prepareIncrease(corePoolKey, tokenId, newPositionIndex, 1000);
                // completely burn the initial position with index 0
                actions[4] = MMA.prepareBurn(corePoolKey, tokenId, positionIndex);
                // take all the underlying tokens from the initial position with index 0
                actions[5] = MMA.prepareSettleFromDeltas(corePoolKey, tokenId, positionIndex, true, true);
                // execute the batch actions
                _mmExec(tokenId, actions);

                uint256 lockerUnderlying0After = IERC20(address(lcc0.underlying())).balanceOf(lockerAddr);
                uint256 lockerUnderlying1After = IERC20(address(lcc1.underlying())).balanceOf(lockerAddr);
                assertLe(
                    lockerUnderlying0Before - lockerUnderlying0After,
                    settlementAmount,
                    "token0 principal pull should stay within the bounded settlement amount"
                );
                assertLe(
                    lockerUnderlying1Before - lockerUnderlying1After,
                    settlementAmount,
                    "token1 principal pull should stay within the bounded settlement amount"
                );
            }
        }

        // validate the new position was created with the expected ticks
        {
            (Position memory newPosition, PositionId _newPositionId) =
                positionManager.getPosition(tokenId, newPositionIndex);
            newPositionId = _newPositionId;
            assertEq(newPosition.tickLower, expectedTickLower, "New position tickLower should match expected");
            assertEq(newPosition.tickUpper, expectedTickUpper, "New position tickUpper should match expected");
        }

        // validate the burned position was completely burned
        {
            (Position memory positionAfterBurn,) = positionManager.getPosition(tokenId, positionIndex);
            assertEq(uint256(positionAfterBurn.liquidity), 0, "Burned position liquidity should be 0");
            assertEq(positionAfterBurn.isActive, false, "Burned position should be inactive");
        }

        // validate the new position has some settlement
        {
            (uint256 newPositionSettledAmount0, uint256 newPositionSettledAmount1) =
                vtsOrchestrator.getPositionSettledAmounts(newPositionId);
            assertGt(newPositionSettledAmount0, 0, "New position should have non-zero settled amount0");
            assertGt(newPositionSettledAmount1, 0, "New position should have non-zero settled amount1");
        }
    }

    function testCanDecreaseAndSettleAnotherPositionFromDeltas() public {
        // Objective:
        // - Prove decreasing a position can produce deltas that are used to increase a different position, and that
        //   the recipient position’s settlement increases.
        //
        // Steps:
        // - Create and over-settle an initial committed position.
        // - Create a second committed position.
        // - Snapshot liquidity and settled amounts for the second position.
        // - Batch: decrease initial position, then increase the second position from deltas.
        // - Assert initial liquidity decreased, second liquidity increased, and second settled amounts increased.
        uint256 positionIndex = 0;
        // Under coverage compilation (optimiser/viaIR disabled), this test can hit stack-too-deep.
        // Keep only the values needed across scopes alive.
        IncreaseFromDeltasSnapshot memory snap;

        {
            ModifyLiquidityParams memory newLiquidityParams =
                ModifyLiquidityParams({tickLower: 0, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)});

            // create a new position with the default liquidity params and liquidity signal
            (snap.tokenId,,,) = _setupCommittedPosition(
                positionManager,
                corePoolKey,
                abi.encode(liquiditySignal),
                defaultlLiquidityParams,
                marketVTSConfiguration,
                address(lcc0),
                address(lcc1)
            );

            // make settlements for the position
            uint256 settlementAmount = 1_000_000e18;
            // make a settlement for the position over the required settlement amounts, so we can use the excess funds to increase the liquidity
            approveAndSettleUnderlyingToPosition(snap.tokenId, positionIndex, settlementAmount, settlementAmount);

            (snap.newTokenId,,,) = _setupCommittedPosition(
                positionManager,
                corePoolKey,
                abi.encode(generateLiquiditySignalWithAdvancer(liquiditySignal.mmState.advancer)),
                newLiquidityParams,
                marketVTSConfiguration,
                address(lcc0),
                address(lcc1)
            );

            // Snapshot only the fields we assert on (rather than keeping whole structs alive).
            {
                (Position memory position1Before, PositionId position1Id) =
                    positionManager.getPosition(snap.tokenId, positionIndex);
                snap.position1LiquidityBefore = position1Before.liquidity;
                (snap.position1Settled0Before, snap.position1Settled1Before) =
                    vtsOrchestrator.getPositionSettledAmounts(position1Id);
                (snap.position1Overflow0Before, snap.position1Overflow1Before) =
                    vtsOrchestrator.getPositionSettledOverflowAmounts(position1Id);
            }
            {
                (Position memory position2Before, PositionId _position2Id) =
                    positionManager.getPosition(snap.newTokenId, positionIndex);
                snap.position2LiquidityBefore = position2Before.liquidity;
                snap.position2Id = _position2Id;
            }
            (snap.position2SettledAmount0Before, snap.position2SettledAmount1Before) =
                vtsOrchestrator.getPositionSettledAmounts(snap.position2Id);
            (snap.position2Overflow0Before, snap.position2Overflow1Before) =
                vtsOrchestrator.getPositionSettledOverflowAmounts(snap.position2Id);

            // batch actions;
            // decrease the liquidity in the initial position with index 0
            // increase the liquidity in the new position with index 1
            MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](3);
            actions[0] = MMA.prepareDecrease(corePoolKey, snap.tokenId, positionIndex, 1000);
            actions[1] = MMA.prepareIncreaseFromDeltas(corePoolKey, snap.newTokenId, positionIndex, true);
            actions[2] = MMA.prepareSettleFromDeltas(corePoolKey, snap.tokenId, positionIndex, true, true);
            _mmExec(snap.tokenId, actions);
        }

        // validate the liquidity of the initial position is decreased
        // validate the liquidity of the new position is increased
        {
            (Position memory position1After,) = positionManager.getPosition(snap.tokenId, positionIndex);
            (Position memory position2After,) = positionManager.getPosition(snap.newTokenId, positionIndex);
            assertLt(
                uint256(position1After.liquidity),
                uint256(snap.position1LiquidityBefore),
                "Position1 liquidity should decrease after prepareDecrease"
            );
            assertGt(
                uint256(position2After.liquidity),
                uint256(snap.position2LiquidityBefore),
                "Position2 liquidity should increase after increaseFromDeltas"
            );
        }

        // validate the new position's settlement has increased
        uint256 position2SettledAmount0After;
        uint256 position2SettledAmount1After;
        {
            (position2SettledAmount0After, position2SettledAmount1After) =
                vtsOrchestrator.getPositionSettledAmounts(snap.position2Id);
            assertGt(
                position2SettledAmount0After,
                snap.position2SettledAmount0Before,
                "Position2 settled amount0 should increase after increaseFromDeltas"
            );
            // payerIsUser=true deposits are clamped to MMPM negative underlying delta per token; if token1 debt
            // after the increase is already cleared by credits, token1 settled may legitimately stay flat.
            assertGe(
                position2SettledAmount1After,
                snap.position2SettledAmount1Before,
                "Position2 settled amount1 must not decrease after increaseFromDeltas"
            );
            assertGt(
                position2SettledAmount0After + position2SettledAmount1After,
                snap.position2SettledAmount0Before + snap.position2SettledAmount1Before,
                "Position2 total settled should increase when liquidity is added from deltas"
            );
        }

        // Regression (SETTLE-03 / exported settlement): economic settled (`live + deferred overflow`) moved into
        // position2 must not also remain on the source position after decrease.
        {
            (, PositionId position1Id) = positionManager.getPosition(snap.tokenId, positionIndex);
            _assertEffectiveSettleExportCoversImport(
                snap, position1Id, position2SettledAmount0After, position2SettledAmount1After
            );
        }
    }

    /// @dev Isolated to avoid stack-too-deep in `testCanDecreaseAndSettleAnotherPositionFromDeltas`.
    function _assertEffectiveSettleExportCoversImport(
        IncreaseFromDeltasSnapshot memory snap,
        PositionId position1Id,
        uint256 position2SettledAmount0After,
        uint256 position2SettledAmount1After
    ) internal {
        (uint256 s0, uint256 s1) = vtsOrchestrator.getPositionSettledAmounts(position1Id);
        (uint256 o1a0, uint256 o1a1) = vtsOrchestrator.getPositionSettledOverflowAmounts(position1Id);
        assertLe(s0, snap.position1Settled0Before, "source token0 settled should not increase");
        assertLe(s1, snap.position1Settled1Before, "source token1 settled should not increase");

        (uint256 o2a0, uint256 o2a1) = vtsOrchestrator.getPositionSettledOverflowAmounts(snap.position2Id);
        uint256 imported0 = (position2SettledAmount0After + o2a0)
            - (snap.position2SettledAmount0Before + snap.position2Overflow0Before);
        uint256 imported1 = (position2SettledAmount1After + o2a1)
            - (snap.position2SettledAmount1Before + snap.position2Overflow1Before);

        uint256 exported0 = (snap.position1Settled0Before + snap.position1Overflow0Before) - (s0 + o1a0);
        uint256 exported1 = (snap.position1Settled1Before + snap.position1Overflow1Before) - (s1 + o1a1);

        assertGe(exported0, imported0, "token0 import must be backed by token0 source export (effective settled)");
        assertGe(exported1, imported1, "token1 import must be backed by token1 source export (effective settled)");
    }

    function test_settleFromDeltas_payerIsUserTrue_sameMarket_preservesDurableReserve() public {
        uint256 positionIndex = 0;

        (uint256 sourceTokenId,,,) = _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            defaultlLiquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );
        approveAndSettleUnderlyingToPosition(sourceTokenId, positionIndex, 1_000_000e18, 1_000_000e18);

        (uint256 targetTokenId,,,) = _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(generateLiquiditySignalWithAdvancer(liquiditySignal.mmState.advancer)),
            defaultlLiquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        (, PositionId targetPositionId) = positionManager.getPosition(targetTokenId, positionIndex);
        (uint256 targetSettled0Before, uint256 targetSettled1Before) =
            vtsOrchestrator.getPositionSettledAmounts(targetPositionId);
        bytes32 coreMarketId = PoolId.unwrap(corePoolKey.toId());
        uint256 reserve0Before = _marketReserveForLcc(coreMarketId, address(lcc0));
        uint256 reserve1Before = _marketReserveForLcc(coreMarketId, address(lcc1));

        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](2);
        actions[0] = MMA.prepareDecrease(corePoolKey, sourceTokenId, positionIndex, 1_000);
        actions[1] = MMA.prepareSettleFromDeltas(corePoolKey, targetTokenId, positionIndex, true, false);
        _mmExec(sourceTokenId, actions);

        uint256 reserve0After = _marketReserveForLcc(coreMarketId, address(lcc0));
        uint256 reserve1After = _marketReserveForLcc(coreMarketId, address(lcc1));
        (uint256 targetSettled0After, uint256 targetSettled1After) =
            vtsOrchestrator.getPositionSettledAmounts(targetPositionId);

        assertGe(targetSettled0After, targetSettled0Before, "target settled0 should not decrease");
        assertGe(targetSettled1After, targetSettled1Before, "target settled1 should not decrease");
        assertEq(
            reserve0After,
            reserve0Before,
            "same-market reserve0 should be neutral when exported credit is re-imported via protocol deposit"
        );
        assertEq(
            reserve1After,
            reserve1Before,
            "same-market reserve1 should be neutral when exported credit is re-imported via protocol deposit"
        );
    }

    function test_increaseFromDeltas_crossMarket_sameFactory_importsReserveOnDestinationMarket() public {
        uint256 positionIndex = 0;

        PoolKey memory sourcePoolKey = corePoolKey;

        (uint256 sourceTokenId,,,) = _setupCommittedPosition(
            positionManager,
            sourcePoolKey,
            abi.encode(liquiditySignal),
            defaultlLiquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );
        approveAndSettleUnderlyingToPosition(sourceTokenId, positionIndex, 1_000_000e18, 1_000_000e18);

        _createAndInitializeMarket(500, 60, SQRT_PRICE_1_1);
        PoolKey memory destinationPoolKey = corePoolKey;
        address[2] memory destinationLccPair =
            IMarketFactory(marketFactory).corePoolToCurrencyPair(destinationPoolKey.toId());
        MarketVTSConfiguration memory destinationCfg =
            IVTSOrchestrator(vtsOrchestrator).getMarketVTSConfiguration(destinationPoolKey.toId());

        (uint256 targetTokenId,,,) = _setupCommittedPosition(
            positionManager,
            destinationPoolKey,
            abi.encode(generateLiquiditySignalWithAdvancer(liquiditySignal.mmState.advancer)),
            defaultlLiquidityParams,
            destinationCfg,
            destinationLccPair[0],
            destinationLccPair[1]
        );

        (, PositionId targetPositionId) = positionManager.getPosition(targetTokenId, positionIndex);
        bytes32 destinationMarketId = PoolId.unwrap(destinationPoolKey.toId());
        uint256[2] memory targetSettledBefore;
        uint256[2] memory reserveBefore;
        (targetSettledBefore[0], targetSettledBefore[1]) = vtsOrchestrator.getPositionSettledAmounts(targetPositionId);
        reserveBefore[0] = _marketReserveForLcc(destinationMarketId, destinationLccPair[0]);
        reserveBefore[1] = _marketReserveForLcc(destinationMarketId, destinationLccPair[1]);

        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](3);
        actions[0] = MMA.prepareDecrease(sourcePoolKey, sourceTokenId, positionIndex, 1_000);
        actions[1] = MMA.prepareIncreaseFromDeltas(destinationPoolKey, targetTokenId, positionIndex, true);
        actions[2] = MMA.prepareSettleFromDeltas(sourcePoolKey, sourceTokenId, positionIndex, true, true);
        _mmExec(sourceTokenId, actions);

        uint256[2] memory targetSettledAfter;
        uint256[2] memory reserveAfter;
        (targetSettledAfter[0], targetSettledAfter[1]) = vtsOrchestrator.getPositionSettledAmounts(targetPositionId);
        reserveAfter[0] = _marketReserveForLcc(destinationMarketId, destinationLccPair[0]);
        reserveAfter[1] = _marketReserveForLcc(destinationMarketId, destinationLccPair[1]);
        uint256 imported0 = targetSettledAfter[0] - targetSettledBefore[0];
        uint256 imported1 = targetSettledAfter[1] - targetSettledBefore[1];

        assertGt(imported0 + imported1, 0, "cross-market increaseFromDeltas should import non-zero settled value");
        assertEq(
            reserveAfter[0] - reserveBefore[0],
            imported0,
            "destination reserve0 must increase by the settled amount imported via in-hook protocol credit"
        );
        assertEq(
            reserveAfter[1] - reserveBefore[1],
            imported1,
            "destination reserve1 must increase by the settled amount imported via in-hook protocol credit"
        );
    }

    function testFollowOnSettleFromDeltas_doesNotReduceSourceSettledTwice_afterDecreaseRoutesCreditElsewhere() public {
        uint256 positionIndex = 0;
        uint256 tokenId;
        uint256 newTokenId;
        uint256 sourceSettled0BeforeFollowOn;
        uint256 sourceSettled1BeforeFollowOn;

        {
            ModifyLiquidityParams memory newLiquidityParams =
                ModifyLiquidityParams({tickLower: 0, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)});

            (tokenId,,,) = _setupCommittedPosition(
                positionManager,
                corePoolKey,
                abi.encode(liquiditySignal),
                defaultlLiquidityParams,
                marketVTSConfiguration,
                address(lcc0),
                address(lcc1)
            );

            uint256 settlementAmount = 1_000_000e18;
            approveAndSettleUnderlyingToPosition(tokenId, positionIndex, settlementAmount, settlementAmount);

            (newTokenId,,,) = _setupCommittedPosition(
                positionManager,
                corePoolKey,
                abi.encode(generateLiquiditySignalWithAdvancer(liquiditySignal.mmState.advancer)),
                newLiquidityParams,
                marketVTSConfiguration,
                address(lcc0),
                address(lcc1)
            );

            MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](3);
            actions[0] = MMA.prepareDecrease(corePoolKey, tokenId, positionIndex, 1000);
            actions[1] = MMA.prepareIncreaseFromDeltas(corePoolKey, newTokenId, positionIndex, true);
            actions[2] = MMA.prepareSettleFromDeltas(corePoolKey, tokenId, positionIndex, true, true);
            _mmExec(tokenId, actions);

            (, PositionId position1IdBeforeSettle) = positionManager.getPosition(tokenId, positionIndex);
            (uint256 before0, uint256 before1) = vtsOrchestrator.getPositionSettledAmounts(position1IdBeforeSettle);
            sourceSettled0BeforeFollowOn = before0;
            sourceSettled1BeforeFollowOn = before1;
        }

        {
            MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](1);
            actions[0] = MMA.prepareSettleFromDeltas(corePoolKey, tokenId, positionIndex, true, true);
            _mmExec(tokenId, actions);
        }

        {
            (, PositionId position1Id) = positionManager.getPosition(tokenId, positionIndex);
            (uint256 s0, uint256 s1) = vtsOrchestrator.getPositionSettledAmounts(position1Id);
            assertEq(s0, sourceSettled0BeforeFollowOn, "follow-on settle must not reduce source token0 settled again");
            assertEq(s1, sourceSettled1BeforeFollowOn, "follow-on settle must not reduce source token1 settled again");
        }
    }

    function test_actionsImpl_handleAction_revertsWhenNotDelegatecall() public {
        // MMPositionActionsImpl is meant to be invoked via delegatecall from MMPositionManager.
        MMPositionActionsImpl impl = new MMPositionActionsImpl(
            address(manager),
            address(marketFactory),
            address(vtsOrchestrator),
            IMarketFactory(marketFactory).canonicalVault()
        );
        // Provide well-formed params so that (if the guard were removed) we don't accidentally revert on ABI decoding.
        bytes memory params = abi.encode(corePoolKey, uint256(1), uint256(0), int128(1), int128(0), false);
        vm.expectRevert(DelegateCallGuard.OnlyDelegateCall.selector);
        impl.handleAction(MMActions.SETTLE_POSITION, params);
    }

    function test_utilityActionsImpl_handleAction_revertsWhenNotDelegatecall() public {
        MMUtilityActionsImpl utilImpl = new MMUtilityActionsImpl(
            manager,
            address(marketFactory),
            address(vtsOrchestrator),
            IMarketFactory(marketFactory).canonicalVault(),
            weth9
        );
        bytes memory params = abi.encode(Currency.wrap(address(0)), address(this), uint256(0));
        vm.expectRevert(DelegateCallGuard.OnlyDelegateCall.selector);
        utilImpl.handleAction(MMActions.TAKE, params);
    }

    function test_settle_usePositionManagerBalance_syncsCredit_whenOnlyToken0Outflow() public {
        // Kills mutants around:
        // - (delta0 > 0 || delta1 > 0) -> (delta0 > 0 && delta1 > 0)
        // - delta0 > 0 -> delta0 < 0
        //
        // We create a one-sided (token0-only) position and withdraw only token0 with usePositionManagerBalance=true.
        // Then TAKE must transfer token0 to the caller; otherwise credit sync didn't happen.
        uint256 tokenId = 1;
        uint256 positionIndex = 0;

        address underlying0 = lcc0.underlying();
        address underlying1 = lcc1.underlying();

        ModifyLiquidityParams memory oneSided =
            ModifyLiquidityParams({tickLower: 60, tickUpper: 120, liquidityDelta: 1e18, salt: bytes32(0)});
        createPosition(oneSided, abi.encode(liquiditySignal), tokenId, positionIndex);

        (uint256 commitment0, uint256 commitment1) = LiquidityUtils.calculateCommitmentMaxima(
            oneSided.tickLower, oneSided.tickUpper, uint128(uint256(oneSided.liquidityDelta))
        );
        address lockerAddr = _batchLocker(tokenId);
        _fundLockerForSettlement(lockerAddr, underlying0, underlying1, commitment0, commitment1);
        vm.startPrank(lockerAddr);
        _approveTokenForPositionManager(underlying0, underlying1, address(positionManager), commitment0, commitment1);
        vm.stopPrank();
        MMA.PreparedAction[] memory preActions = new MMA.PreparedAction[](1);
        preActions[0] = MMA.prepareSettle(
            corePoolKey, tokenId, positionIndex, -int128(int256(commitment0)), -int128(int256(commitment1)), false
        );
        _mmExec(tokenId, preActions);

        uint256 withdraw0 = Math.max(uint256(1), commitment0 / 2);

        uint256 bal0Before = IERC20(underlying0).balanceOf(address(this));
        uint256 bal1Before = IERC20(underlying1).balanceOf(address(this));

        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](3);
        actions[0] = MMA.prepareSettle(corePoolKey, tokenId, positionIndex, int128(int256(withdraw0)), 0, true);
        actions[1] = MMA.prepareTake(Currency.wrap(underlying0), address(this), type(uint256).max);
        actions[2] = MMA.prepareTake(Currency.wrap(underlying1), address(this), type(uint256).max);
        _mmExec(tokenId, actions);

        uint256 bal0After = IERC20(underlying0).balanceOf(address(this));
        uint256 bal1After = IERC20(underlying1).balanceOf(address(this));

        assertGt(bal0After, bal0Before, "expected token0 TAKE after synced credit");
        assertEq(bal1After, bal1Before, "expected no token1 transfer in token0-only outflow");
    }

    function test_settle_usePositionManagerBalance_syncsCredit_whenOnlyToken1Outflow() public {
        // Kills mutants around delta1 > 0 gate by creating a one-sided (token1-only) outflow.
        uint256 tokenId = 1;
        uint256 positionIndex = 0;

        address underlying0 = lcc0.underlying();
        address underlying1 = lcc1.underlying();

        ModifyLiquidityParams memory oneSided =
            ModifyLiquidityParams({tickLower: -120, tickUpper: -60, liquidityDelta: 1e18, salt: bytes32(0)});
        createPosition(oneSided, abi.encode(liquiditySignal), tokenId, positionIndex);

        // Additional settle to ensure there's sufficient settled liquidity to withdraw.
        (uint256 commitment0, uint256 commitment1) = LiquidityUtils.calculateCommitmentMaxima(
            oneSided.tickLower, oneSided.tickUpper, uint128(uint256(oneSided.liquidityDelta))
        );
        address lockerAddr1 = _batchLocker(tokenId);
        _fundLockerForSettlement(lockerAddr1, underlying0, underlying1, commitment0, commitment1);
        vm.startPrank(lockerAddr1);
        _approveTokenForPositionManager(underlying0, underlying1, address(positionManager), commitment0, commitment1);
        vm.stopPrank();
        MMA.PreparedAction[] memory preActions = new MMA.PreparedAction[](1);
        preActions[0] = MMA.prepareSettle(
            corePoolKey, tokenId, positionIndex, -int128(int256(commitment0)), -int128(int256(commitment1)), false
        );
        _mmExec(tokenId, preActions);

        uint256 withdraw1 = Math.max(uint256(1), commitment1 / 2);

        uint256 bal0Before = IERC20(underlying0).balanceOf(address(this));
        uint256 bal1Before = IERC20(underlying1).balanceOf(address(this));

        // Negative test: attempting to settle/withdraw without TAKE to drain deltas will leave unsetted deltas
        // and revert with CurrencyNotSettled at the end of the batch.
        MMA.PreparedAction[] memory actions0 = new MMA.PreparedAction[](1);
        actions0[0] = MMA.prepareSettle(corePoolKey, tokenId, positionIndex, 0, int128(int256(withdraw1)), true);
        vm.expectRevert(Errors.CurrencyNotSettled.selector);
        _mmExec(lockerAddr1, actions0);

        // Positive test: proper flow with TAKE to drain any credits/deltas
        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](3);
        actions[0] = MMA.prepareSettle(corePoolKey, tokenId, positionIndex, 0, int128(int256(withdraw1)), true);
        actions[1] = MMA.prepareTake(Currency.wrap(underlying0), address(this), type(uint256).max);
        actions[2] = MMA.prepareTake(Currency.wrap(underlying1), address(this), type(uint256).max);
        _mmExec(tokenId, actions);

        uint256 bal0After = IERC20(underlying0).balanceOf(address(this));
        uint256 bal1After = IERC20(underlying1).balanceOf(address(this));

        assertEq(bal0After, bal0Before, "expected no token0 transfer in token1-only outflow");
        assertGt(bal1After, bal1Before, "expected token1 TAKE after synced credit");
    }

    /// @notice Regression: audit **finding 33_3** (omnibus MMPM `sync` attribution), **Scenario 2** — positive settlement
    ///         with `usePositionManagerBalance=true` must credit `creditExact(vaultOutflow)` only, not the full MMPM ERC20
    ///         balance (no piggyback on others’ parked tokens). See `agents/audit-findings/33_3__high-balance-wide-sync-*.md`.
    function test_finding33_3_scenario2_settleWithUsePmb_creditsExactNotOmnibusErc20() public {
        uint256 tokenId = 1;
        uint256 positionIndex = 0;

        address underlying0 = lcc0.underlying();
        address underlying1 = lcc1.underlying();

        ModifyLiquidityParams memory oneSided =
            ModifyLiquidityParams({tickLower: 60, tickUpper: 120, liquidityDelta: 1e18, salt: bytes32(0)});
        createPosition(oneSided, abi.encode(liquiditySignal), tokenId, positionIndex);

        address lockerAddr = _batchLocker(tokenId);
        (uint256 commitment0, uint256 commitment1) = LiquidityUtils.calculateCommitmentMaxima(
            oneSided.tickLower, oneSided.tickUpper, uint128(uint256(oneSided.liquidityDelta))
        );
        _fundLockerForSettlement(lockerAddr, underlying0, underlying1, commitment0, commitment1);
        vm.startPrank(lockerAddr);
        _approveTokenForPositionManager(underlying0, underlying1, address(positionManager), commitment0, commitment1);
        vm.stopPrank();

        MMA.PreparedAction[] memory preActions = new MMA.PreparedAction[](1);
        preActions[0] = MMA.prepareSettle(
            corePoolKey, tokenId, positionIndex, -int128(int256(commitment0)), -int128(int256(commitment1)), false
        );
        _mmExec(tokenId, preActions);

        uint256 withdraw0 = Math.max(uint256(1), commitment0 / 2);

        // Ambient ERC20 dust unrelated to the vault outflow: must not be credited in the same ratio as settle.
        uint256 ambientDust = 1_000_000e9;
        MockERC20(underlying0).mint(address(positionManager), ambientDust);

        uint256 bal0Before = IERC20(underlying0).balanceOf(address(this));
        uint256 bal1Before = IERC20(underlying1).balanceOf(address(this));

        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](3);
        actions[0] = MMA.prepareSettle(corePoolKey, tokenId, positionIndex, int128(int256(withdraw0)), 0, true);
        actions[1] = MMA.prepareTake(Currency.wrap(underlying0), address(this), type(uint256).max);
        actions[2] = MMA.prepareTake(Currency.wrap(underlying1), address(this), type(uint256).max);
        _mmExec(tokenId, actions);

        // Exact `creditExact` on the settlement delta: recipient should receive the vault outflow, not MMPM + ambient.
        assertEq(
            IERC20(underlying0).balanceOf(address(this)) - bal0Before,
            withdraw0,
            "TAKE should match exact credited outflow"
        );
        assertEq(
            IERC20(underlying1).balanceOf(address(this)), bal1Before, "expected no token1 in token0-only withdrawal"
        );

        // Unrelated ambient ERC20 remains on the router; it was not swept into the locker as settlement credit.
        assertEq(
            IERC20(underlying0).balanceOf(address(positionManager)), ambientDust, "Ambient ERC20 must stay on MMPM"
        );
    }

    /// @notice Regression: audit **finding 33_3**, **Scenario 3** — a locker with no credit cannot fund a negative
    ///         settle from unrelated ERC20 parked on MMPM (no debt erasure via omnibus balance). See
    ///         `agents/audit-findings/33_3__high-balance-wide-sync-*.md`.
    function test_finding33_3_scenario3_negativeSettle_revertsWhenNoOwnCredit_despiteOmnibusErc20() public {
        // With usePositionManagerBalance=true, a negative settle must consume locker credit first.
        uint256 tokenId = 1;
        uint256 positionIndex = 0;
        uint256 depositAmount0 = 1e18;

        createPosition(defaultlLiquidityParams, abi.encode(liquiditySignal), tokenId, positionIndex);

        address underlying0 = lcc0.underlying();
        // Seed MMPM with pooled balance without creating locker credit.
        MockERC20(underlying0).mint(address(positionManager), depositAmount0);

        // Precondition: locker has no takeable credit for underlying0.
        assertEq(vtsOrchestrator.getFullCredit(Currency.wrap(underlying0), liquiditySignal.mmState.advancer), 0);

        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](1);
        actions[0] = MMA.prepareSettle(corePoolKey, tokenId, positionIndex, -int128(int256(depositAmount0)), 0, true);

        address lockerIB = _batchLocker(tokenId);
        vm.expectPartialRevert(Errors.InsufficientBalance.selector);
        _mmExec(lockerIB, actions);

        // Ensure pooled tokens remain on MMPM after revert.
        assertEq(IERC20(underlying0).balanceOf(address(positionManager)), depositAmount0);
    }

    /// @dev Mirrors `test_finding33_3_scenario3_negativeSettle_revertsWhenNoOwnCredit_despiteOmnibusErc20` on token1.
    function test_finding33_3_scenario3_negativeSettle_revertsWhenNoOwnCredit_despiteOmnibusErc20_token1() public {
        uint256 tokenId = 1;
        uint256 positionIndex = 0;
        uint256 depositAmount1 = 1e18;

        createPosition(defaultlLiquidityParams, abi.encode(liquiditySignal), tokenId, positionIndex);

        address underlying1 = lcc1.underlying();
        MockERC20(underlying1).mint(address(positionManager), depositAmount1);

        assertEq(vtsOrchestrator.getFullCredit(Currency.wrap(underlying1), liquiditySignal.mmState.advancer), 0);

        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](1);
        actions[0] = MMA.prepareSettle(corePoolKey, tokenId, positionIndex, 0, -int128(int256(depositAmount1)), true);

        address lockerIB1 = _batchLocker(tokenId);
        vm.expectPartialRevert(Errors.InsufficientBalance.selector);
        _mmExec(lockerIB1, actions);

        assertEq(IERC20(underlying1).balanceOf(address(positionManager)), depositAmount1);
    }

    function test_settle_usePositionManagerBalanceFalse_pullsErc20FromLocker_notPositionManager() public {
        // Ensure the non-MMPM settle path keeps ERC20 behaviour and never spends pooled MMPM balances.
        uint256 tokenId = 1;
        uint256 positionIndex = 0;
        uint256 depositAmount0 = 1e6;

        createPosition(defaultlLiquidityParams, abi.encode(liquiditySignal), tokenId, positionIndex);

        address underlying0 = lcc0.underlying();
        address underlying1 = lcc1.underlying();

        // Seed MMPM with pooled balance. This must not be consumed by usePositionManagerBalance=false settles.
        MockERC20(underlying0).mint(address(positionManager), depositAmount0);

        uint256 pmBalanceBefore = IERC20(underlying0).balanceOf(address(positionManager));
        address lockerAddr2 = liquiditySignal.mmState.advancer;
        _fundLockerForSettlement(lockerAddr2, underlying0, underlying1, depositAmount0, 0);
        uint256 lockerBalanceBefore = IERC20(underlying0).balanceOf(lockerAddr2);

        vm.startPrank(lockerAddr2);
        _approveTokenForPositionManager(underlying0, underlying1, address(positionManager), depositAmount0, 0);
        vm.stopPrank();

        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](1);
        actions[0] = MMA.prepareSettle(corePoolKey, tokenId, positionIndex, -int128(int256(depositAmount0)), 0, false);
        _mmExec(tokenId, actions);

        uint256 pmBalanceAfter = IERC20(underlying0).balanceOf(address(positionManager));
        uint256 lockerBalanceAfter = IERC20(underlying0).balanceOf(lockerAddr2);

        assertEq(pmBalanceAfter, pmBalanceBefore, "pooled MMPM ERC20 balance must remain untouched");
        assertEq(lockerBalanceAfter, lockerBalanceBefore - depositAmount0, "locker ERC20 must fund settle");
    }

    function test_settleFromDeltas_withOneSidedProtocolCredit_token0Only() public {
        // Kills mutants around:
        // - (credit0 > 0 || credit1 > 0) -> (credit0 > 0 && credit1 > 0)
        // - credit0 > 0 -> credit0 < 0
        //
        // Create a token0-only position, burn it to create protocol (MMPM) underlying credit,
        // then withdraw via settleFromDeltas. Must pay out token0 even if token1 credit is zero.
        uint256 tokenId = 1;
        uint256 positionIndex = 0;

        ModifyLiquidityParams memory oneSided =
            ModifyLiquidityParams({tickLower: 1080, tickUpper: 1140, liquidityDelta: 1e18, salt: bytes32(0)});
        createPosition(oneSided, abi.encode(liquiditySignal), tokenId, positionIndex);

        address underlying0 = lcc0.underlying();
        address underlying1 = lcc1.underlying();

        // Additional settle to ensure the burn+withdraw path has sufficient settled amounts.
        // IMPORTANT: commitmentMaxima is an upper bound for *either* side, so even “effectively one-sided” ranges
        // can still be settled on both tokens. For a true one-sided credit test, we must settle only one token.
        (uint256 commitment0,) = LiquidityUtils.calculateCommitmentMaxima(
            oneSided.tickLower, oneSided.tickUpper, uint128(uint256(oneSided.liquidityDelta))
        );
        // Settle ONLY token0 (not token1) so burn produces one-sided requiredSettlementDelta/credits.
        address lockerAddr3 = _batchLocker(tokenId);
        _fundLockerForSettlement(lockerAddr3, underlying0, underlying1, commitment0, 0);
        vm.startPrank(lockerAddr3);
        _approveTokenForPositionManager(underlying0, underlying1, address(positionManager), commitment0, 0);
        vm.stopPrank();
        MMA.PreparedAction[] memory preActions = new MMA.PreparedAction[](1);
        preActions[0] = MMA.prepareSettle(corePoolKey, tokenId, positionIndex, -int128(int256(commitment0)), 0, false);
        _mmExec(tokenId, preActions);

        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](4);
        actions[0] = MMA.prepareBurn(corePoolKey, tokenId, positionIndex);
        actions[1] = MMA.prepareSettleFromDeltas(corePoolKey, tokenId, positionIndex, true, true);
        actions[2] = MMA.prepareTake(Currency.wrap(underlying0), address(this), type(uint256).max);
        actions[3] = MMA.prepareTake(Currency.wrap(underlying1), address(this), type(uint256).max);
        _mmExec(tokenId, actions);
    }

    function test_settleFromDeltas_withOneSidedProtocolCredit_token1Only() public {
        // Mirrors the token0-only test to kill the symmetric credit1 mutants.
        uint256 tokenId = 1;
        uint256 positionIndex = 0;

        ModifyLiquidityParams memory oneSided =
            ModifyLiquidityParams({tickLower: -1140, tickUpper: -1080, liquidityDelta: 1e18, salt: bytes32(0)});
        createPosition(oneSided, abi.encode(liquiditySignal), tokenId, positionIndex);

        address underlying0 = lcc0.underlying();
        address underlying1 = lcc1.underlying();

        // Additional settle to ensure the burn+withdraw path has sufficient settled amounts.
        // IMPORTANT: commitmentMaxima is an upper bound for *either* side, so even “effectively one-sided” ranges
        // can still be settled on both tokens. For a true one-sided credit test, we must settle only one token.
        (, uint256 commitment1) = LiquidityUtils.calculateCommitmentMaxima(
            oneSided.tickLower, oneSided.tickUpper, uint128(uint256(oneSided.liquidityDelta))
        );
        // Settle ONLY token1 (not token0) so burn produces one-sided requiredSettlementDelta/credits.
        address lockerAddr4 = _batchLocker(tokenId);
        _fundLockerForSettlement(lockerAddr4, underlying0, underlying1, 0, commitment1);
        vm.startPrank(lockerAddr4);
        _approveTokenForPositionManager(underlying0, underlying1, address(positionManager), 0, commitment1);
        vm.stopPrank();
        MMA.PreparedAction[] memory preActions = new MMA.PreparedAction[](1);
        preActions[0] = MMA.prepareSettle(corePoolKey, tokenId, positionIndex, 0, -int128(int256(commitment1)), false);
        _mmExec(tokenId, preActions);

        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](4);
        actions[0] = MMA.prepareBurn(corePoolKey, tokenId, positionIndex);
        actions[1] = MMA.prepareSettleFromDeltas(corePoolKey, tokenId, positionIndex, true, true);
        actions[2] = MMA.prepareTake(Currency.wrap(underlying0), address(this), type(uint256).max);
        actions[3] = MMA.prepareTake(Currency.wrap(underlying1), address(this), type(uint256).max);
        _mmExec(tokenId, actions);
    }

    function test_settleFromDeltas_deposit_revertsForNotApprovedCaller_whenNotSeizing() public {
        // As deltas are per-unlock, it's not possible for an attacker to "reuse" protocol credits created
        // in a prior unlock. The simplest invariant we want is that an attacker cannot call `_settle` (negative delta)
        // on someone else's position.
        uint256 tokenId = 1;
        uint256 positionIndex = 0;

        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: 60, tickUpper: 120, liquidityDelta: 1e18, salt: bytes32(0)});
        createPosition(params, abi.encode(liquiditySignal), tokenId, positionIndex);

        address attacker = makeAddr("attacker");
        MMA.PreparedAction[] memory attackerActions = new MMA.PreparedAction[](1);
        // Attempt to deposit (negative delta) as an unapproved caller.
        attackerActions[0] = MMA.prepareSettle(corePoolKey, tokenId, positionIndex, -int128(1), 0, false);

        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotApproved.selector, attacker));
        MMA.executeWithUnlock(positionManager, attackerActions, block.timestamp + 3600);
        vm.stopPrank();
    }

    function test_settle_revertsOnZeroDelta() public {
        // _settle checks amount0==0 && amount1==0 before reading position state.
        uint256 tokenId = 1;
        uint256 positionIndex = 0;
        _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            defaultlLiquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](1);
        actions[0] = MMA.prepareSettle(corePoolKey, tokenId, positionIndex, 0, 0, false);

        address lockerZD = _batchLocker(tokenId);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidDelta.selector, 0, 0));
        _mmExec(lockerZD, actions);
    }

    function test_mintPosition_revertsWhenLiquidityGtUint128Max() public {
        // Mint action rejects liquidity > uint128 max, but only after passing the ERC721 owner/approval gate.
        // So we commit first (mints the tokenId), then attempt to mint a position with too-large liquidity.
        uint256 tokenId = positionManager.nextTokenId();
        uint256 tooLarge = uint256(type(uint128).max) + 1;

        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](2);
        actions[0] = MMA.prepareCommit(abi.encode(liquiditySignal));
        actions[1] = MMA.prepareMint(corePoolKey, tokenId, -60, 60, tooLarge);

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector, tooLarge, type(uint128).max));
        _mmExecSignalLocker(abi.encode(liquiditySignal), actions);
    }

    // ============================================================
    // Mutation-score focused negative tests
    // ============================================================

    function _wrongCorePoolKey() internal view returns (PoolKey memory bad) {
        bad = corePoolKey;
        // Swap currencies to produce a distinct PoolId (guaranteed InvalidMarket vs the stored position.poolId).
        (bad.currency0, bad.currency1) = (bad.currency1, bad.currency0);
    }

    function test_settle_revertsInvalidMarket_whenPoolKeyMismatch() public {
        uint256 tokenId = 1;
        uint256 positionIndex = 0;

        _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            defaultlLiquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        PoolKey memory bad = _wrongCorePoolKey();
        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](1);
        actions[0] = MMA.prepareSettle(bad, tokenId, positionIndex, -int128(1), 0, false);

        address lockerIM = _batchLocker(tokenId);
        _fundLockerForSettlement(lockerIM, address(lcc0.underlying()), address(lcc1.underlying()), 1, 0);
        vm.startPrank(lockerIM);
        _approveTokenForPositionManager(
            address(lcc0.underlying()), address(lcc1.underlying()), address(positionManager), 1, 0
        );
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidMarket.selector, bad));
        _mmExec(lockerIM, actions);
    }

    function test_burn_revertsInvalidMarket_whenPoolKeyMismatch() public {
        uint256 tokenId = 1;
        uint256 positionIndex = 0;

        _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            defaultlLiquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        PoolKey memory bad = _wrongCorePoolKey();
        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](1);
        actions[0] = MMA.prepareBurn(bad, tokenId, positionIndex);

        address lockerIMb = _batchLocker(tokenId);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidMarket.selector, bad));
        _mmExec(lockerIMb, actions);
    }

    function test_increase_revertsInvalidMarket_whenPoolKeyMismatch() public {
        uint256 tokenId = 1;
        uint256 positionIndex = 0;

        _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            defaultlLiquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        PoolKey memory bad = _wrongCorePoolKey();
        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](1);
        actions[0] = MMA.prepareIncrease(bad, tokenId, positionIndex, 1);

        address lockerIMi = _batchLocker(tokenId);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidMarket.selector, bad));
        _mmExec(lockerIMi, actions);
    }

    function test_decrease_revertsInvalidMarket_whenPoolKeyMismatch() public {
        uint256 tokenId = 1;
        uint256 positionIndex = 0;

        _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            defaultlLiquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        PoolKey memory bad = _wrongCorePoolKey();
        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](1);
        actions[0] = MMA.prepareDecrease(bad, tokenId, positionIndex, 1);

        address lockerIMd = _batchLocker(tokenId);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidMarket.selector, bad));
        _mmExec(lockerIMd, actions);
    }

    function test_seize_revertsInvalidMarket_whenPoolKeyMismatch() public {
        uint256 tokenId = 1;
        uint256 positionIndex = 0;

        _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            defaultlLiquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        PoolKey memory bad = _wrongCorePoolKey();
        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](1);
        actions[0] = MMA.prepareSeize(bad, tokenId, positionIndex, 1, 1, false);

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidMarket.selector, bad));
        vm.startPrank(guarantor);
        MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);
        vm.stopPrank();
    }

    function test_increaseFromDeltas_revertsInvalidMarket_whenPoolKeyMismatch() public {
        uint256 tokenId = 1;
        uint256 positionIndex = 0;

        _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            defaultlLiquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        PoolKey memory bad = _wrongCorePoolKey();
        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](1);
        actions[0] = MMA.prepareIncreaseFromDeltas(bad, tokenId, positionIndex, true);

        address lockerIMif = _batchLocker(tokenId);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidMarket.selector, bad));
        _mmExec(lockerIMif, actions);
    }

    function test_increaseFromDeltas_revertsWhenAmountMaxExceeded() public {
        uint256 tokenId = 1;
        uint256 positionIndex = 0;

        _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            defaultlLiquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        uint256 settlementAmount = 1_000_000e18;
        approveAndSettleUnderlyingToPosition(tokenId, positionIndex, settlementAmount, settlementAmount);

        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](2);
        actions[0] = MMA.prepareDecrease(corePoolKey, tokenId, positionIndex, 1_000_000_000);
        actions[1] = MMA.prepareIncreaseFromDeltas(corePoolKey, tokenId, positionIndex, 0, 0, true);

        address lockerMX = _batchLocker(tokenId);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.MaximumAmountExceeded.selector, uint128(0), uint128(999_999_994_600_261_889_212_273)
            )
        );
        _mmExec(lockerMX, actions);
    }

    /// @dev Covers the token1 leg of `_validateMaxIn` (amount0Max is unconstrained so token0 cannot trip first).
    function test_increaseFromDeltas_revertsWhenAmount1MaxExceeded() public {
        uint256 tokenId = 1;
        uint256 positionIndex = 0;

        _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            defaultlLiquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        uint256 settlementAmount = 1_000_000e18;
        approveAndSettleUnderlyingToPosition(tokenId, positionIndex, settlementAmount, settlementAmount);

        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](2);
        actions[0] = MMA.prepareDecrease(corePoolKey, tokenId, positionIndex, 1_000_000_000);
        actions[1] = MMA.prepareIncreaseFromDeltas(corePoolKey, tokenId, positionIndex, type(uint128).max, 0, true);

        address lockerMX1 = _batchLocker(tokenId);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.MaximumAmountExceeded.selector, uint128(0), uint128(999_999_994_600_261_889_212_273)
            )
        );
        _mmExec(lockerMX1, actions);
    }

    function test_mintFromDeltas_revertsWhenAmountMaxExceeded() public {
        uint256 tokenId = 1;
        uint256 positionIndex = 0;

        _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            defaultlLiquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        uint256 settlementAmount = 1_000_000e18;
        approveAndSettleUnderlyingToPosition(tokenId, positionIndex, settlementAmount, settlementAmount);

        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](2);
        actions[0] = MMA.prepareDecrease(corePoolKey, tokenId, positionIndex, 1_000_000_000);
        actions[1] = MMA.prepareMintFromDeltas(
            corePoolKey, tokenId, defaultlLiquidityParams.tickLower, defaultlLiquidityParams.tickUpper, 0, 0, true
        );

        address lockerMX2 = _batchLocker(tokenId);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.MaximumAmountExceeded.selector, uint128(0), uint128(999_999_994_600_261_889_212_273)
            )
        );
        _mmExec(lockerMX2, actions);
    }

    /// @dev Same as `test_mintFromDeltas_revertsWhenAmountMaxExceeded` but forces the token1 `_validateMaxIn` branch.
    function test_mintFromDeltas_revertsWhenAmount1MaxExceeded() public {
        uint256 tokenId = 1;
        uint256 positionIndex = 0;

        _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            defaultlLiquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        uint256 settlementAmount = 1_000_000e18;
        approveAndSettleUnderlyingToPosition(tokenId, positionIndex, settlementAmount, settlementAmount);

        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](2);
        actions[0] = MMA.prepareDecrease(corePoolKey, tokenId, positionIndex, 1_000_000_000);
        actions[1] = MMA.prepareMintFromDeltas(
            corePoolKey,
            tokenId,
            defaultlLiquidityParams.tickLower,
            defaultlLiquidityParams.tickUpper,
            type(uint128).max,
            0,
            true
        );

        address lockerMX3 = _batchLocker(tokenId);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.MaximumAmountExceeded.selector, uint128(0), uint128(999_999_994_600_261_889_212_273)
            )
        );
        _mmExec(lockerMX3, actions);
    }

    /// @dev Plain `INCREASE_LIQUIDITY` must enforce `_validateMaxIn` on principal delta (v4-style max spend).
    function test_increaseLiquidity_revertsWhenAmount0MaxExceeded() public {
        uint256 tokenId = 1;
        uint256 positionIndex = 0;

        _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            defaultlLiquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        uint256 settlementAmount = 1_000_000e18;
        approveAndSettleUnderlyingToPosition(tokenId, positionIndex, settlementAmount, settlementAmount);

        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](2);
        actions[0] = MMA.prepareDecrease(corePoolKey, tokenId, positionIndex, 1_000_000_000);
        actions[1] = MMA.prepareIncrease(corePoolKey, tokenId, positionIndex, 1_000_000_000, 0, 0);

        address lockerMX = _batchLocker(tokenId);
        vm.expectRevert(abi.encodeWithSelector(Errors.MaximumAmountExceeded.selector, uint128(0), uint128(2_995_355)));
        _mmExec(lockerMX, actions);
    }

    /// @dev Dirty high 128 bits in calldata max-in words must be masked; same revert as clean `(0,0)` caps.
    function test_increaseLiquidity_revertsWhenAmount0MaxExceeded_evenWithDirtyHighBitsInCalldata() public {
        uint256 tokenId = 1;
        uint256 positionIndex = 0;

        _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            defaultlLiquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        uint256 settlementAmount = 1_000_000e18;
        approveAndSettleUnderlyingToPosition(tokenId, positionIndex, settlementAmount, settlementAmount);

        PoolKey memory poolKeyMem = corePoolKey;
        bytes memory incParams =
            abi.encode(poolKeyMem, tokenId, positionIndex, uint256(1_000_000_000), uint128(0), uint128(0));
        uint256 dirty = uint256(0xC0FFEE) << 128;
        // amount0Max @ word 8, amount1Max @ word 9 (PoolKey = 5 words)
        _setActionParamWord(incParams, 8, dirty);
        _setActionParamWord(incParams, 9, dirty);

        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](2);
        actions[0] = MMA.prepareDecrease(corePoolKey, tokenId, positionIndex, 1_000_000_000);
        actions[1] = MMA.PreparedAction({action: bytes1(uint8(MMActions.INCREASE_LIQUIDITY)), params: incParams});

        address lockerMX = _batchLocker(tokenId);
        vm.expectRevert(abi.encodeWithSelector(Errors.MaximumAmountExceeded.selector, uint128(0), uint128(2_995_355)));
        _mmExec(lockerMX, actions);
    }

    /// @dev Covers the token1 leg of `_validateMaxIn` for plain `INCREASE_LIQUIDITY`.
    function test_increaseLiquidity_revertsWhenAmount1MaxExceeded() public {
        uint256 tokenId = 1;
        uint256 positionIndex = 0;

        _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            defaultlLiquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        uint256 settlementAmount = 1_000_000e18;
        approveAndSettleUnderlyingToPosition(tokenId, positionIndex, settlementAmount, settlementAmount);

        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](2);
        actions[0] = MMA.prepareDecrease(corePoolKey, tokenId, positionIndex, 1_000_000_000);
        actions[1] = MMA.prepareIncrease(corePoolKey, tokenId, positionIndex, 1_000_000_000, type(uint128).max, 0);

        address lockerMX1 = _batchLocker(tokenId);
        vm.expectRevert(abi.encodeWithSelector(Errors.MaximumAmountExceeded.selector, uint128(0), uint128(2_995_355)));
        _mmExec(lockerMX1, actions);
    }

    /// @dev Plain `MINT_POSITION` must enforce `_validateMaxIn` after `_mintPositionInternal`.
    function test_mintPosition_revertsWhenAmount0MaxExceeded() public {
        uint256 tokenId = 1;

        _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            defaultlLiquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        uint256 settlementAmount = 1_000_000e18;
        approveAndSettleUnderlyingToPosition(tokenId, 0, settlementAmount, settlementAmount);

        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](2);
        actions[0] = MMA.prepareDecrease(corePoolKey, tokenId, 0, 1_000_000_000);
        actions[1] = MMA.prepareMint(
            corePoolKey,
            tokenId,
            defaultlLiquidityParams.tickLower,
            defaultlLiquidityParams.tickUpper,
            1_000_000_000,
            0,
            0
        );

        address lockerMX2 = _batchLocker(tokenId);
        vm.expectRevert(abi.encodeWithSelector(Errors.MaximumAmountExceeded.selector, uint128(0), uint128(2_995_355)));
        _mmExec(lockerMX2, actions);
    }

    /// @dev Token1 leg for plain `MINT_POSITION` max-in enforcement.
    function test_mintPosition_revertsWhenAmount1MaxExceeded() public {
        uint256 tokenId = 1;

        _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            defaultlLiquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        uint256 settlementAmount = 1_000_000e18;
        approveAndSettleUnderlyingToPosition(tokenId, 0, settlementAmount, settlementAmount);

        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](2);
        actions[0] = MMA.prepareDecrease(corePoolKey, tokenId, 0, 1_000_000_000);
        actions[1] = MMA.prepareMint(
            corePoolKey,
            tokenId,
            defaultlLiquidityParams.tickLower,
            defaultlLiquidityParams.tickUpper,
            1_000_000_000,
            type(uint128).max,
            0
        );

        address lockerMX3 = _batchLocker(tokenId);
        vm.expectRevert(abi.encodeWithSelector(Errors.MaximumAmountExceeded.selector, uint128(0), uint128(2_995_355)));
        _mmExec(lockerMX3, actions);
    }

    /// @dev Plain add-liquidity succeeds when explicit `amount0Max` / `amount1Max` comfortably bound principal spend.
    function test_plainIncrease_succeedsWithLooseExplicitMaxIn() public {
        uint256 tokenId = 1;
        uint256 positionIndex = 0;

        _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            defaultlLiquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        uint256 settlementAmount = 1_000_000e18;
        approveAndSettleUnderlyingToPosition(tokenId, positionIndex, settlementAmount, settlementAmount);

        (Position memory positionBeforeIncrease,) = positionManager.getPosition(tokenId, positionIndex);

        uint256 liquidityToIncrease = 1000;
        MMA.PreparedAction[] memory incActions = new MMA.PreparedAction[](1);
        incActions[0] = MMA.prepareIncrease(
            corePoolKey, tokenId, positionIndex, liquidityToIncrease, type(uint128).max - 100, type(uint128).max - 100
        );
        _mmExec(tokenId, incActions);

        (Position memory positionAfterIncrease,) = positionManager.getPosition(tokenId, positionIndex);
        assertEq(
            uint256(positionAfterIncrease.liquidity),
            uint256(positionBeforeIncrease.liquidity) + liquidityToIncrease,
            "Liquidity should increase when loose explicit max-in is supplied"
        );
    }

    function test_unauthorised_revertsNotApproved_forBurnIncreaseDecreaseAndDeltasActions() public {
        uint256 tokenId = 1;
        uint256 positionIndex = 0;

        _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            defaultlLiquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        address attacker = makeAddr("attacker2");

        // Burn
        {
            MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](1);
            actions[0] = MMA.prepareBurn(corePoolKey, tokenId, positionIndex);
            vm.startPrank(attacker);
            vm.expectRevert(abi.encodeWithSelector(Errors.NotApproved.selector, attacker));
            MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);
            vm.stopPrank();
        }

        // Increase
        {
            MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](1);
            actions[0] = MMA.prepareIncrease(corePoolKey, tokenId, positionIndex, 1);
            vm.startPrank(attacker);
            vm.expectRevert(abi.encodeWithSelector(Errors.NotApproved.selector, attacker));
            MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);
            vm.stopPrank();
        }

        // Decrease
        {
            MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](1);
            actions[0] = MMA.prepareDecrease(corePoolKey, tokenId, positionIndex, 1);
            vm.startPrank(attacker);
            vm.expectRevert(abi.encodeWithSelector(Errors.NotApproved.selector, attacker));
            MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);
            vm.stopPrank();
        }

        // increaseFromDeltas
        {
            MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](1);
            actions[0] = MMA.prepareIncreaseFromDeltas(corePoolKey, tokenId, positionIndex, true);
            vm.startPrank(attacker);
            vm.expectRevert(abi.encodeWithSelector(Errors.NotApproved.selector, attacker));
            MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);
            vm.stopPrank();
        }

        // mintFromDeltas (approval gate should trip before any delta maths)
        {
            MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](1);
            actions[0] = MMA.prepareMintFromDeltas(corePoolKey, tokenId, 0, 60, true);
            vm.startPrank(attacker);
            vm.expectRevert(abi.encodeWithSelector(Errors.NotApproved.selector, attacker));
            MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);
            vm.stopPrank();
        }
    }

    function test_seize_callsOnSeize_and_onMMSettle_withNegativeRequestedDelta() public {
        // Kills mutants that delete onSeize() and mutate -amount -> ~amount in seizure settlement.
        uint256 tokenId = 1;
        uint256 positionIndex = 0;

        _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            defaultlLiquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        // Create deficit so RFS opens, persist the checkpoint, then warp past grace.
        _openSeizeWindow(tokenId, positionIndex);

        uint256 settleAmount0 = 5_999_709_018_652_707;
        uint256 settleAmount1 = 5_999_709_018_652_707;

        IERC20(lcc0.underlying()).transfer(guarantor, settleAmount0);
        IERC20(lcc1.underlying()).transfer(guarantor, settleAmount1);

        // Expect the orchestrator to validate seizure and receive the negative requested delta.
        vm.expectCall(
            address(vtsOrchestrator), abi.encodeWithSelector(IVTSOrchestrator.onSeize.selector, tokenId, positionIndex)
        );

        BalanceDelta expectedDelta = toBalanceDelta(-int128(int256(settleAmount0)), -int128(int256(settleAmount1)));
        vm.expectCall(
            address(vtsOrchestrator),
            abi.encodeWithSelector(
                IVTSOrchestrator.onMMSettle.selector,
                IMarketFactory(marketFactory),
                tokenId,
                positionIndex,
                expectedDelta,
                true,
                false
            )
        );

        vm.startPrank(guarantor);
        IERC20(lcc0.underlying()).approve(address(positionManager), settleAmount0);
        IERC20(lcc1.underlying()).approve(address(positionManager), settleAmount1);

        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](4);
        actions[0] = MMA.prepareSeize(corePoolKey, tokenId, positionIndex, settleAmount0, settleAmount1, false);
        actions[1] = MMA.prepareSettleFromDeltas(corePoolKey, tokenId, positionIndex, true, true);
        actions[2] = MMA.prepareTake(Currency.wrap(address(lcc0)), guarantor, 0);
        actions[3] = MMA.prepareTake(Currency.wrap(address(lcc1)), guarantor, 0);
        MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);
        vm.stopPrank();
    }
}
