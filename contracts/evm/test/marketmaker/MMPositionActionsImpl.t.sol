// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
// solhint-disable max-line-length

import {BalanceDelta, toBalanceDelta, add} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityCommitmentCertificate} from "../../src/LCC.sol";
import {IMarketFactory} from "../../src/interfaces/IMarketFactory.sol";
import {LiquidityUtils} from "../../src/libraries/LiquidityUtils.sol";
import {console} from "forge-std/console.sol";
import {MarketTestBase} from "../modules/MarketTestBase.sol";
import {MMPositionManager} from "../../src/MMPositionManager.sol";
import {MMActionAdapter as MMA} from "../libraries/MMActionAdapter.sol";
import {MarketMakerTestBase} from "../modules/MMTestBase.sol";
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

        // approve the lccs to the mmPositionManager to be able to route tokens to the pool manager
        // lcc0.approve(address(mmPositionManager), Constants.MAX_UINT256);
        // lcc1.approve(address(mmPositionManager), Constants.MAX_UINT256);
        // Mock the proxyHookToCurrencyPair function in order to make this caller appear to be an issuer
        // when deploying the factory the mmposiiton manager will be provided and thus whitelsited
        // but since we are mocking the factory, we need to mock a way to return the mmposition manager as an issuer
        address[2] memory mockCurrencies = [address(lcc0.underlying()), address(lcc1.underlying())];
        vm.mockCall(
            marketFactory,
            abi.encodeWithSelector(IMarketFactory.proxyHookToCurrencyPair.selector, address(mmPositionManager)),
            abi.encode(mockCurrencies)
        );
        // mock the factory to return the right core hook
        vm.mockCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.coreToProxy.selector), abi.encode(proxyPoolKey.toId())
        );
        // mock the factory to return the right proxy hook
        vm.mockCall(marketFactory, abi.encodeWithSelector(IMarketFactory.proxyToHook.selector), abi.encode(proxyHook));

        // mock liquidityHub.getFactory to return the mocked marketFactory
        vm.mockCall(
            liquidityHub,
            abi.encodeWithSelector(ILiquidityHub.getFactory.selector, address(lcc0), address(lcc1)),
            abi.encode(marketFactory)
        );

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
        _approveForPositionManager(
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
        IERC20(lcc0.underlying()).approve(address(positionManager), settlementAmount0);
        IERC20(lcc1.underlying()).approve(address(positionManager), settlementAmount1);

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
        uint256 tokenId = 1;
        uint256 positionIndex = 0;

        // create a new position with the default liquidity params and liquidity signal
        createPosition(defaultlLiquidityParams, abi.encode(liquiditySignal), tokenId, positionIndex);

        // test conditions to ensure that a position was committed and minted and settled to
        // for commitment testing:
        (MarketMaker.State memory mmState, uint256 expiresAt, uint256 positionCount, uint256 activePositionCount) =
            vtsOrchestrator.getCommit(tokenId);
        assertEq(mmState.owner, liquiditySignal.mmState.owner);
        assertEq(expiresAt, block.timestamp + 3600);
        assertEq(positionCount, 1);
        assertEq(activePositionCount, 1);

        // validate the owner of the NFT minted is the caller of the function
        assertEq(positionManager.ownerOf(tokenId), address(this));

        // for minting testing:
        (Position memory positionAfter, PositionId positionId) = positionManager.getPosition(tokenId, positionIndex);
        assertEq(positionAfter.owner, address(positionManager));
        assertEq(PoolId.unwrap(positionAfter.poolId), PoolId.unwrap(corePoolKey.toId()));
        assertEq(positionAfter.commitId, tokenId);
        assertEq(positionAfter.tickLower, defaultlLiquidityParams.tickLower);
        assertEq(positionAfter.tickUpper, defaultlLiquidityParams.tickUpper);
        assertEq(uint256(positionAfter.liquidity), uint256(defaultlLiquidityParams.liquidityDelta));
        assertEq(positionAfter.isActive, true);
    }

    function testCanBurnAndWithdrawCreatedPosition() public {
        uint256 tokenId = 1;
        uint256 positionIndex = 0;

        // create a new position with the default liquidity params and liquidity signal
        createPosition(defaultlLiquidityParams, abi.encode(liquiditySignal), tokenId, positionIndex);

        // get underlying asset balance before burning a position
        uint256 token0BalanceBefore = Currency.wrap(lcc0.underlying()).balanceOf(address(this));
        uint256 token1BalanceBefore = Currency.wrap(lcc1.underlying()).balanceOf(address(this));

        // get the active position count before burning
        (,,, uint256 activePositionCountBeforeBurn) = vtsOrchestrator.getCommit(tokenId);
        assertEq(activePositionCountBeforeBurn, 1);

        // Batch burn and settle from deltas
        // The burn flow:
        // 1. LCCs are cancelled on receipt (planCancelWithQueue → executePlannedCancel)
        // 2. Underlying credits are created on MMPM (accountUnderlyingSettlementDeltaChange)
        // 3. settleFromDeltas with payerIsUser=true reads MMPM's underlying credits
        // 4. _settle() withdraws underlying from the vault to the user
        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](2);
        actions[0] = MMA.prepareBurn(corePoolKey, tokenId, positionIndex);
        actions[1] = MMA.prepareSettleFromDeltas(corePoolKey, tokenId, 0, true, true);
        MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);

        // get the active position count after burning
        (,,, uint256 activePositionCountAfterBurn) = vtsOrchestrator.getCommit(tokenId);
        assertEq(activePositionCountAfterBurn, 0);

        // get the underlying asset balance after burning a position
        uint256 token0BalanceAfter = Currency.wrap(lcc0.underlying()).balanceOf(address(this));
        uint256 token1BalanceAfter = Currency.wrap(lcc1.underlying()).balanceOf(address(this));

        console.log("token0BalanceBefore", token0BalanceBefore);
        console.log("token0BalanceAfter ", token0BalanceAfter);
        console.log("token1BalanceBefore", token1BalanceBefore);
        console.log("token1BalanceAfter ", token1BalanceAfter);

        // validate the underlying tokens were redeemed and thus the balance of the caller has increased
        assertGt(token0BalanceAfter, token0BalanceBefore);
        assertGt(token1BalanceAfter, token1BalanceBefore);
    }

    function testCanBurnDecommitWithdrawFromPosition() public {
        uint256 tokenId = 1;
        uint256 positionIndex = 0;

        // create a new position with the default liquidity params and liquidity signal
        createPosition(defaultlLiquidityParams, abi.encode(liquiditySignal), tokenId, positionIndex);

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
        assertGt(token0BalanceAfter, token0BalanceBefore);
        assertGt(token1BalanceAfter, token1BalanceBefore);
    }

    function testCanOverSettleAndIncreasePositionLiquidity() public {
        uint256 tokenId = 1;
        uint256 positionIndex = 0;

        // create a new position with the default liquidity params and liquidity signal
        createPosition(defaultlLiquidityParams, abi.encode(liquiditySignal), tokenId, positionIndex);

        // make settlements for the position
        uint256 settlementAmount = 1000000e18;

        // make a settlement for the position over the required settlement amounts, so we can use the excess funds to increase the liquidity
        approveAndSettleUnderlyingToPosition(tokenId, positionIndex, settlementAmount, settlementAmount);

        (Position memory positionBeforeIncrease,) = positionManager.getPosition(tokenId, positionIndex);

        // get the active position count before increasing the liquidity
        (,,, uint256 activePositionCountBeforeIncrease) = vtsOrchestrator.getCommit(tokenId);
        assertEq(activePositionCountBeforeIncrease, 1);

        // increase the liquidity in the position by a specified amount
        uint256 liquidityToIncrease = 1000;
        MMA.increase(
            positionManager,
            corePoolKey,
            tokenId,
            positionIndex,
            defaultlLiquidityParams.tickLower,
            defaultlLiquidityParams.tickUpper,
            liquidityToIncrease
        );

        // validate the liquidity in the position is increased
        (Position memory positionAfterIncrease,) = positionManager.getPosition(tokenId, positionIndex);
        assertEq(
            uint256(positionAfterIncrease.liquidity), uint256(positionBeforeIncrease.liquidity) + liquidityToIncrease
        );

        // get the active position count after increasing the liquidity
        (,,, uint256 activePositionCountAfterIncrease) = vtsOrchestrator.getCommit(tokenId);
        assertEq(activePositionCountAfterIncrease, 1);
    }

    function testCanDecreaseMintNewPositionFromDeltas() public {
        uint256 tokenId = 1;
        uint256 positionIndex = 0;

        // create a new position with the default liquidity params and liquidity signal
        createPosition(defaultlLiquidityParams, abi.encode(liquiditySignal), tokenId, positionIndex);

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
            uint256(positionAfterDecrease.liquidity), uint256(positionBeforeDecrease.liquidity) - liquidityToDecrease
        );

        // validate the new position was created with the new ticks provided
        (Position memory newPosition,) = positionManager.getPosition(tokenId, newPositionIndex);
        assertEq(newPosition.tickLower, newUpperTick);
        assertEq(newPosition.tickUpper, defaultlLiquidityParams.tickUpper);

        // validate the new position has some settlement
        (uint256 newPositionSettledAmount0, uint256 newPositionSettledAmount1) =
            vtsOrchestrator.getPositionSettledAmounts(newPositionId);

        assertGt(newPositionSettledAmount0, 0);
        assertGt(newPositionSettledAmount1, 0);
    }

    function testCanSeizeAndTakeDeltasFromPosition() public {
        uint256 tokenId = 1;
        uint256 positionIndex = 0;

        // create a new position with the default liquidity params and liquidity signal
        createPosition(defaultlLiquidityParams, abi.encode(liquiditySignal), tokenId, positionIndex);
        (, PositionId positionId) = positionManager.getPosition(tokenId, positionIndex);

        // perform a swap in order to drain some liquidity from the pool and cause a deficit for the market maker
        // forcing their position to be open for RFS
        swapRouter.swap(
            proxyPoolKey,
            SwapParams({zeroForOne: true, amountSpecified: -1e25, sqrtPriceLimitX96: ZERO_FOR_ONE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        // Now check if RFS is open (should be if deficit > settled)
        (bool rfsOpen,) = vtsOrchestrator.calcRFS(positionId, false);
        assertEq(rfsOpen, true);

        // log the positions deficit amounts
        (uint256 settledAmount0, uint256 settledAmount1) = vtsOrchestrator.getPositionSettledAmounts(positionId);
        console.log("settledAmount0", settledAmount0);
        console.log("settledAmount1", settledAmount1);

        // advance timestamp to after grace period elapsed
        vm.warp(block.timestamp + 300000 + 1);

        // approve the position manager to spend the underlying assets
        uint256 settleAmount0 = 5999709018652707;
        uint256 settleAmount1 = 5999709018652707;

        // transfer enough underlying assets to the guarantor to settle the position
        IERC20(lcc0.underlying()).transfer(guarantor, settleAmount0);
        IERC20(lcc1.underlying()).transfer(guarantor, settleAmount1);

        // act as the guarantor and settle and sieze some parts the position
        vm.startPrank(guarantor);
        IERC20(lcc0.underlying()).approve(address(positionManager), settleAmount0);
        IERC20(lcc1.underlying()).approve(address(positionManager), settleAmount1);

        // get position liquidity
        (Position memory positionBeforeSeize,) = vtsOrchestrator.getPosition(tokenId, positionIndex);

        assertEq(Currency.wrap(address(lcc0)).balanceOf(address(guarantor)), 0);

        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](3);
        actions[0] = MMA.prepareSeize(corePoolKey, tokenId, positionIndex, settleAmount0, settleAmount1, false);
        actions[1] = MMA.prepareSettleFromDeltas(corePoolKey, tokenId, positionIndex, true, true); //take
        actions[2] = MMA.prepareTake(Currency.wrap(address(lcc0)), address(guarantor), 0); // collect all lcc fees
        // Use modifyLiquidities which handles unlocking automatically
        (bytes memory actionsBytes, bytes[] memory params) = MMA.concatPrepared(actions);
        bytes memory unlockData = abi.encode(actionsBytes, params);
        positionManager.modifyLiquidities(unlockData, block.timestamp + 3600);

        vm.stopPrank();

        // validate liquidity was taken from the original position
        (Position memory positionAfterSeize,) = vtsOrchestrator.getPosition(tokenId, positionIndex);

        // validate some liquidity was taken from the original position
        assertLt(uint256(positionAfterSeize.liquidity), uint256(positionBeforeSeize.liquidity));
        // validate some lcc balance as fees
        assertGt(Currency.wrap(address(lcc0)).balanceOf(address(guarantor)), 0);
    }
}
