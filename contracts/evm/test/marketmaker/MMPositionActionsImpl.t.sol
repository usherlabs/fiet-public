// SPDX-License-Identifier: MIT
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
import {IVRLSignalManager} from "../../src/interfaces/IVRLSignalManager.sol";
import {LiquiditySignal} from "../../src/types/Commit.sol";
import {IVTSOrchestrator} from "../../src/interfaces/IVTSOrchestrator.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {MMPositionActionsImpl} from "../../src/MMPositionActionsImpl.sol";
import {MMActions} from "../../src/libraries/MMActions.sol";
import {DelegateCallGuard} from "../../src/modules/DelegateCallGuard.sol";

contract MMPositionManagerActionsTest is MarketTestBase, MarketMakerTestBase {
    using SafeCast for *;
    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;
    using MarketMaker for MarketMaker.State;
    using StateLibrary for IPoolManager;

    MMPositionManager internal positionManager;
    MarketVTSConfiguration internal marketVTSConfiguration;

    LiquidityCommitmentCertificate internal lcc0;
    LiquidityCommitmentCertificate internal lcc1;

    address guarantor = makeAddr("guarantor");
    uint256 guarantorInitialBalance = 10000e18;
    ModifyLiquidityParams defaultlLiquidityParams =
        ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: bytes32(0)});

    function setUp() public {
        _setupMarket();
        _setUpMM();
        console.log("setUP() mmPositionManager", address(mmPositionManager));
        positionManager = MMPositionManager(payable(mmPositionManager));
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
    }

    function createPosition(
        ModifyLiquidityParams memory liquidityParams,
        bytes memory liquiditySignalBytes,
        uint256 tokenId,
        uint256 positionIndex
    ) public {
        // Approve the required settlement amounts to be taken by the manager
        (uint256 requiredSettlementAmount0, uint256 requiredSettlementAmount1) =
            approveRequiredSettlementAmounts(liquidityParams);

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

        // Use modifyLiquidities which handles unlocking automatically
        MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);
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
        (MarketMaker.State memory mmState, uint256 expiresAt, uint256 positionCount, uint256 activePositionCount) =
            vtsOrchestrator.getCommit(tokenId);
        assertEq(mmState.owner, liquiditySignal.mmState.owner, "Commit owner should match liquidity signal owner");
        assertEq(expiresAt, block.timestamp + 3600, "Commit expiry should be now + 1 hour");
        assertEq(positionCount, 1, "Commit should have exactly 1 position");
        assertEq(activePositionCount, 1, "Commit should have exactly 1 active position");

        // validate the owner of the NFT minted is the caller of the function
        assertEq(positionManager.ownerOf(tokenId), address(this), "NFT owner should be the test contract");

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

        // get underlying asset balance before burning a position
        uint256 token0BalanceBefore = Currency.wrap(lcc0.underlying()).balanceOf(address(this));
        uint256 token1BalanceBefore = Currency.wrap(lcc1.underlying()).balanceOf(address(this));

        // get the active position count before burning
        (,,, uint256 activePositionCountBeforeBurn) = vtsOrchestrator.getCommit(tokenId);
        assertEq(activePositionCountBeforeBurn, 1, "Precondition: commit should have 1 active position");

        // Batch burn and settle from deltas
        // The burn flow:
        // 1. LCCs are cancelled on receipt (planCancelWithQueue → executePlannedCancel)
        // 2. Underlying credits are created on MMPM (accountUnderlyingSettlementDelta)
        // 3. settleFromDeltas with payerIsUser=true reads MMPM's underlying credits
        // 4. _settle() withdraws underlying from the vault to the user
        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](2);
        actions[0] = MMA.prepareBurn(corePoolKey, tokenId, positionIndex);
        actions[1] = MMA.prepareSettleFromDeltas(corePoolKey, tokenId, 0, true, true);
        MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);

        // get the active position count after burning
        (,,, uint256 activePositionCountAfterBurn) = vtsOrchestrator.getCommit(tokenId);
        assertEq(activePositionCountAfterBurn, 0, "Burn should reduce active position count to 0");

        // get the underlying asset balance after burning a position
        uint256 token0BalanceAfter = Currency.wrap(lcc0.underlying()).balanceOf(address(this));
        uint256 token1BalanceAfter = Currency.wrap(lcc1.underlying()).balanceOf(address(this));

        console.log("token0BalanceBefore", token0BalanceBefore);
        console.log("token0BalanceAfter ", token0BalanceAfter);
        console.log("token1BalanceBefore", token1BalanceBefore);
        console.log("token1BalanceAfter ", token1BalanceAfter);

        // validate the underlying tokens were redeemed and thus the balance of the caller has increased
        assertGt(token0BalanceAfter, token0BalanceBefore, "Caller should receive underlying0 after burn+settle");
        assertGt(token1BalanceAfter, token1BalanceBefore, "Caller should receive underlying1 after burn+settle");
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

        // get underlying asset balance before decommitment
        uint256 token0BalanceBefore = Currency.wrap(lcc0.underlying()).balanceOf(address(this));
        uint256 token1BalanceBefore = Currency.wrap(lcc1.underlying()).balanceOf(address(this));

        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](3);
        actions[0] = MMA.prepareBurn(corePoolKey, tokenId, positionIndex);
        actions[1] = MMA.prepareSettleFromDeltas(corePoolKey, tokenId, positionIndex, true, true);
        actions[2] = MMA.prepareDecommit(tokenId);
        MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);

        // get underlying asset balance after decommitment
        uint256 token0BalanceAfter = Currency.wrap(lcc0.underlying()).balanceOf(address(this));
        uint256 token1BalanceAfter = Currency.wrap(lcc1.underlying()).balanceOf(address(this));

        // Validate the underlying tokens were redeemed and thus the balance of the caller has increased
        assertGt(token0BalanceAfter, token0BalanceBefore, "Caller should receive underlying0 after burn+withdraw");
        assertGt(token1BalanceAfter, token1BalanceBefore, "Caller should receive underlying1 after burn+withdraw");
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
        vm.expectRevert(abi.encodeWithSelector(Errors.CommitNotEmpty.selector, tokenId));
        MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);
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
        (,,, uint256 activePositionCountBeforeIncrease) = vtsOrchestrator.getCommit(tokenId);
        assertEq(activePositionCountBeforeIncrease, 1, "Precondition: commit should have 1 active position");

        // increase the liquidity in the position by a specified amount
        uint256 liquidityToIncrease = 1000;
        MMA.increase(positionManager, corePoolKey, tokenId, positionIndex, liquidityToIncrease);

        // validate the liquidity in the position is increased
        (Position memory positionAfterIncrease,) = positionManager.getPosition(tokenId, positionIndex);
        assertEq(
            uint256(positionAfterIncrease.liquidity),
            uint256(positionBeforeIncrease.liquidity) + liquidityToIncrease,
            "Liquidity should increase by liquidityToIncrease"
        );

        // get the active position count after increasing the liquidity
        (,,, uint256 activePositionCountAfterIncrease) = vtsOrchestrator.getCommit(tokenId);
        assertEq(activePositionCountAfterIncrease, 1, "Active position count should remain 1 after increase");
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
        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](2);
        int24 newUpperTick = 0;
        actions[0] = MMA.prepareDecrease(corePoolKey, tokenId, positionIndex, liquidityToDecrease);
        actions[1] =
            MMA.prepareMintFromDeltas(corePoolKey, tokenId, newUpperTick, defaultlLiquidityParams.tickUpper, true);
        MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);

        // validate liquidity of the initial position is decreased
        (Position memory positionAfterDecrease, PositionId newPositionId) =
            positionManager.getPosition(tokenId, positionIndex);
        assertEq(
            uint256(positionAfterDecrease.liquidity),
            uint256(positionBeforeDecrease.liquidity) - liquidityToDecrease,
            "Liquidity should decrease by liquidityToDecrease"
        );

        // validate the new position was created with the new ticks provided
        (Position memory newPosition,) = positionManager.getPosition(tokenId, newPositionIndex);
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

        vm.warp(block.timestamp + 300000 + 1);

        // Setup guarantor settlement
        uint256 settleAmount0 = 5999709018652707;
        uint256 settleAmount1 = 5999709018652707;
        IERC20(lcc0.underlying()).transfer(guarantor, settleAmount0);
        IERC20(lcc1.underlying()).transfer(guarantor, settleAmount1);

        // Get liquidity before seize
        uint128 liquidityBefore;
        {
            (Position memory pos,) = vtsOrchestrator.getPosition(tokenId, positionIndex);
            liquidityBefore = pos.liquidity;
        }

        // Execute seize as guarantor
        vm.startPrank(guarantor);
        IERC20(lcc0.underlying()).approve(address(positionManager), settleAmount0);
        IERC20(lcc1.underlying()).approve(address(positionManager), settleAmount1);

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
                Currency.wrap(address(lcc0)).balanceOf(address(guarantor)),
                0,
                "Guarantor should receive non-zero proceeds after seize+take"
            );
        }
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

            // approve underlying tokens for settlement to a newly minted position
            _approveTokenForPositionManager(
                address(lcc0.underlying()),
                address(lcc1.underlying()),
                address(positionManager),
                settlementAmount,
                settlementAmount
            );

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
            MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);
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
        uint256 tokenId;
        uint256 newTokenId;
        PositionId position2Id;
        uint128 position1LiquidityBefore;
        uint128 position2LiquidityBefore;
        uint256 position2SettledAmount0Before;
        uint256 position2SettledAmount1Before;

        {
            ModifyLiquidityParams memory newLiquidityParams =
                ModifyLiquidityParams({tickLower: 0, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)});

            // create a new position with the default liquidity params and liquidity signal
            (tokenId,,,) = _setupCommittedPosition(
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
            approveAndSettleUnderlyingToPosition(tokenId, positionIndex, settlementAmount, settlementAmount);

            (newTokenId,,,) = _setupCommittedPosition(
                positionManager,
                corePoolKey,
                abi.encode(renewSignal),
                newLiquidityParams,
                marketVTSConfiguration,
                address(lcc0),
                address(lcc1)
            );

            // Snapshot only the fields we assert on (rather than keeping whole structs alive).
            {
                (Position memory position1Before,) = positionManager.getPosition(tokenId, positionIndex);
                position1LiquidityBefore = position1Before.liquidity;
            }
            {
                (Position memory position2Before, PositionId _position2Id) =
                    positionManager.getPosition(newTokenId, positionIndex);
                position2LiquidityBefore = position2Before.liquidity;
                position2Id = _position2Id;
            }
            (position2SettledAmount0Before, position2SettledAmount1Before) =
                vtsOrchestrator.getPositionSettledAmounts(position2Id);

            // batch actions;
            // decrease the liquidity in the initial position with index 0
            // increase the liquidity in the new position with index 1
            MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](2);
            actions[0] = MMA.prepareDecrease(corePoolKey, tokenId, positionIndex, 1000);
            actions[1] = MMA.prepareIncreaseFromDeltas(corePoolKey, newTokenId, positionIndex, true);
            MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);
        }

        // validate the liquidity of the initial position is decreased
        // validate the liquidity of the new position is increased
        {
            (Position memory position1After,) = positionManager.getPosition(tokenId, positionIndex);
            (Position memory position2After,) = positionManager.getPosition(newTokenId, positionIndex);
            assertLt(
                uint256(position1After.liquidity),
                uint256(position1LiquidityBefore),
                "Position1 liquidity should decrease after prepareDecrease"
            );
            assertGt(
                uint256(position2After.liquidity),
                uint256(position2LiquidityBefore),
                "Position2 liquidity should increase after increaseFromDeltas"
            );
        }

        // validate the new position's settlement has increased
        {
            (uint256 position2SettledAmount0After, uint256 position2SettledAmount1After) =
                vtsOrchestrator.getPositionSettledAmounts(position2Id);
            assertGt(
                position2SettledAmount0After,
                position2SettledAmount0Before,
                "Position2 settled amount0 should increase after increaseFromDeltas"
            );
            assertGt(
                position2SettledAmount1After,
                position2SettledAmount1Before,
                "Position2 settled amount1 should increase after increaseFromDeltas"
            );
        }
    }

    function test_actionsImpl_handleAction_revertsWhenNotDelegatecall() public {
        // MMPositionActionsImpl is meant to be invoked via delegatecall from MMPositionManager.
        MMPositionActionsImpl impl =
            new MMPositionActionsImpl(address(manager), address(liquidityHub), address(vtsOrchestrator));
        // Provide well-formed params so that (if the guard were removed) we don't accidentally revert on ABI decoding.
        bytes memory params = abi.encode(corePoolKey, uint256(1), uint256(0), int128(1), int128(0), false);
        vm.expectRevert(DelegateCallGuard.OnlyDelegateCall.selector);
        impl.handleAction(MMActions.SETTLE_POSITION, params);
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
        // Approve underlying tokens since they will be used to settle the position
        _approveTokenForPositionManager(underlying0, underlying1, address(positionManager), commitment0, commitment1);
        MMA.PreparedAction[] memory preActions = new MMA.PreparedAction[](1);
        preActions[0] = MMA.prepareSettle(
            corePoolKey, tokenId, positionIndex, -int128(int256(commitment0)), -int128(int256(commitment1)), false
        );
        MMA.executeWithUnlock(positionManager, preActions, block.timestamp + 3600);

        uint256 withdraw0 = Math.max(uint256(1), commitment0 / 2);

        uint256 bal0Before = IERC20(underlying0).balanceOf(address(this));
        uint256 bal1Before = IERC20(underlying1).balanceOf(address(this));

        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](3);
        actions[0] = MMA.prepareSettle(corePoolKey, tokenId, positionIndex, int128(int256(withdraw0)), 0, true);
        actions[1] = MMA.prepareTake(Currency.wrap(underlying0), address(this), 0);
        actions[2] = MMA.prepareTake(Currency.wrap(underlying1), address(this), 0);
        MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);

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
        _approveTokenForPositionManager(underlying0, underlying1, address(positionManager), commitment0, commitment1);
        MMA.PreparedAction[] memory preActions = new MMA.PreparedAction[](1);
        preActions[0] = MMA.prepareSettle(
            corePoolKey, tokenId, positionIndex, -int128(int256(commitment0)), -int128(int256(commitment1)), false
        );
        MMA.executeWithUnlock(positionManager, preActions, block.timestamp + 3600);

        uint256 withdraw1 = Math.max(uint256(1), commitment1 / 2);

        uint256 bal0Before = IERC20(underlying0).balanceOf(address(this));
        uint256 bal1Before = IERC20(underlying1).balanceOf(address(this));

        // Negative test: attempting to settle/withdraw without TAKE to drain deltas will leave unsetted deltas
        // and revert with CurrencyNotSettled at the end of the batch.
        MMA.PreparedAction[] memory actions0 = new MMA.PreparedAction[](1);
        actions0[0] = MMA.prepareSettle(corePoolKey, tokenId, positionIndex, 0, int128(int256(withdraw1)), true);
        vm.expectRevert(Errors.CurrencyNotSettled.selector);
        MMA.executeWithUnlock(positionManager, actions0, block.timestamp + 3600);

        // Positive test: proper flow with TAKE to drain any credits/deltas
        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](3);
        actions[0] = MMA.prepareSettle(corePoolKey, tokenId, positionIndex, 0, int128(int256(withdraw1)), true);
        actions[1] = MMA.prepareTake(Currency.wrap(underlying0), address(this), 0);
        actions[2] = MMA.prepareTake(Currency.wrap(underlying1), address(this), 0);
        MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);

        uint256 bal0After = IERC20(underlying0).balanceOf(address(this));
        uint256 bal1After = IERC20(underlying1).balanceOf(address(this));

        assertEq(bal0After, bal0Before, "expected no token0 transfer in token1-only outflow");
        assertGt(bal1After, bal1Before, "expected token1 TAKE after synced credit");
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

        (uint256 requiredSettlementAmount0, uint256 requiredSettlementAmount1) =
            _calculateSettlementAmounts(oneSided, marketVTSConfiguration);

        // Additional settle to ensure the burn+withdraw path has sufficient settled amounts.
        // IMPORTANT: commitmentMaxima is an upper bound for *either* side, so even “effectively one-sided” ranges
        // can still be settled on both tokens. For a true one-sided credit test, we must settle only one token.
        (uint256 commitment0,) = LiquidityUtils.calculateCommitmentMaxima(
            oneSided.tickLower, oneSided.tickUpper, uint128(uint256(oneSided.liquidityDelta))
        );
        // Settle ONLY token0 (not token1) so burn produces one-sided requiredSettlementDelta/credits.
        _approveTokenForPositionManager(underlying0, underlying1, address(positionManager), commitment0, 0);
        MMA.PreparedAction[] memory preActions = new MMA.PreparedAction[](1);
        preActions[0] = MMA.prepareSettle(corePoolKey, tokenId, positionIndex, -int128(int256(commitment0)), 0, false);
        MMA.executeWithUnlock(positionManager, preActions, block.timestamp + 3600);

        uint256 bal0Before = IERC20(underlying0).balanceOf(address(this));
        uint256 bal1Before = IERC20(underlying1).balanceOf(address(this));

        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](4);
        actions[0] = MMA.prepareBurn(corePoolKey, tokenId, positionIndex);
        actions[1] = MMA.prepareSettleFromDeltas(corePoolKey, tokenId, positionIndex, true, true);
        // Drain any incidental credits to satisfy _afterBatch().
        actions[2] = MMA.prepareTake(Currency.wrap(underlying0), address(this), 0);
        actions[3] = MMA.prepareTake(Currency.wrap(underlying1), address(this), 0);
        MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);

        uint256 bal0After = IERC20(underlying0).balanceOf(address(this));
        uint256 bal1After = IERC20(underlying1).balanceOf(address(this));

        assertGt(
            bal0After, bal0Before + requiredSettlementAmount0, "expected token0 payout from one-sided protocol credit"
        );
        assertEq(bal1After, bal1Before + requiredSettlementAmount1, "expected no token1 payout from token0-only credit");
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

        (uint256 requiredSettlementAmount0, uint256 requiredSettlementAmount1) =
            _calculateSettlementAmounts(oneSided, marketVTSConfiguration);

        // Additional settle to ensure the burn+withdraw path has sufficient settled amounts.
        // IMPORTANT: commitmentMaxima is an upper bound for *either* side, so even “effectively one-sided” ranges
        // can still be settled on both tokens. For a true one-sided credit test, we must settle only one token.
        (, uint256 commitment1) = LiquidityUtils.calculateCommitmentMaxima(
            oneSided.tickLower, oneSided.tickUpper, uint128(uint256(oneSided.liquidityDelta))
        );
        // Settle ONLY token1 (not token0) so burn produces one-sided requiredSettlementDelta/credits.
        _approveTokenForPositionManager(underlying0, underlying1, address(positionManager), 0, commitment1);
        MMA.PreparedAction[] memory preActions = new MMA.PreparedAction[](1);
        preActions[0] = MMA.prepareSettle(corePoolKey, tokenId, positionIndex, 0, -int128(int256(commitment1)), false);
        MMA.executeWithUnlock(positionManager, preActions, block.timestamp + 3600);

        uint256 bal0Before = IERC20(underlying0).balanceOf(address(this));
        uint256 bal1Before = IERC20(underlying1).balanceOf(address(this));

        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](4);
        actions[0] = MMA.prepareBurn(corePoolKey, tokenId, positionIndex);
        actions[1] = MMA.prepareSettleFromDeltas(corePoolKey, tokenId, positionIndex, true, true);
        actions[2] = MMA.prepareTake(Currency.wrap(underlying0), address(this), 0);
        actions[3] = MMA.prepareTake(Currency.wrap(underlying1), address(this), 0);
        MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);

        uint256 bal0After = IERC20(underlying0).balanceOf(address(this));
        uint256 bal1After = IERC20(underlying1).balanceOf(address(this));

        assertEq(bal0After, bal0Before + requiredSettlementAmount0, "expected no token0 payout from token1-only credit");
        assertGt(
            bal1After, bal1Before + requiredSettlementAmount1, "expected token1 payout from one-sided protocol credit"
        );
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
        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](1);
        actions[0] = MMA.prepareSettle(corePoolKey, 1, 0, 0, 0, false);

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidDelta.selector, 0, 0));
        MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);
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
        MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);
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

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidMarket.selector, bad));
        MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);
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

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidMarket.selector, bad));
        MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);
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

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidMarket.selector, bad));
        MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);
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

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidMarket.selector, bad));
        MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);
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

        vm.prank(guarantor);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidMarket.selector, bad));
        MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);
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

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidMarket.selector, bad));
        MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);
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

        // Create deficit so RFS opens.
        swapRouter.swap(
            proxyPoolKey,
            SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: ZERO_FOR_ONE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        vm.warp(block.timestamp + 300000 + 1);

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
                mv,
                tokenId,
                positionIndex,
                corePoolKey.currency0,
                corePoolKey.currency1,
                expectedDelta,
                true
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
