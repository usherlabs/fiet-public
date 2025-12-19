// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "forge-std/Test.sol";
// solhint-disable max-line-length

import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityCommitmentCertificate} from "../src/LCC.sol";
import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";
import {LiquidityUtils} from "../src/libraries/LiquidityUtils.sol";
import {console} from "forge-std/console.sol";
import {MarketTestBase} from "./modules/MarketTestBase.sol";
import {MMPositionManager} from "../src/MMPositionManager.sol";
import {MMActionAdapter as MMA} from "./libraries/MMActionAdapter.sol";
import {MarketMakerTestBase} from "./modules/MMTestBase.sol";
import {MarketMaker} from "../src/libraries/MarketMaker.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PositionId} from "../src/types/Position.sol";
import {MarketVTSConfiguration} from "../src/types/VTS.sol";
import {MockERC20} from "./_mocks/MockERC20.sol";
import {SafeCast} from "v4-periphery/lib/v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {IOracleHelper} from "../src/interfaces/IOracleHelper.sol";
import {Position} from "../src/types/Position.sol";
import {RFSCheckpoint} from "../src/types/Checkpoint.sol";
import {ILCC} from "../src/interfaces/ILCC.sol";
import {LiquiditySignal} from "../src/types/Commit.sol";
import {ILiquidityHub} from "../src/interfaces/ILiquidityHub.sol";

contract MMPositionManagerTest is MarketTestBase, MarketMakerTestBase {
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

    function setUp() public {
        _setupMarket();
        _setUpMM();

        console.log("setUP() mmPositionManager", address(mmPositionManager));

        positionManager = MMPositionManager(payable(mmPositionManager));
        lcc0 = LiquidityCommitmentCertificate(payable(Currency.unwrap(_currency2)));
        lcc1 = LiquidityCommitmentCertificate(payable(Currency.unwrap(_currency3)));

        marketVTSConfiguration = vtsOrchestrator.getMarketVTSConfiguration(corePoolKey.toId());

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

    function test_canRenewSignal() public {
        // get the default market confiration so we can tweak it
        bytes memory liquiditySignal = abi.encode(liquiditySignal);
        ModifyLiquidityParams memory liquidityParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)});

        // Setup committed position using helper
        (uint256 tokenId,,,) = _setupCommittedPosition(
            positionManager,
            corePoolKey,
            liquiditySignal,
            liquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        (, uint256 expiresAtPrevious,,) = vtsOrchestrator.getCommit(tokenId);

        // renew the signal
        uint256 newTimestamp = 1000;
        vm.warp(newTimestamp);
        MMA.renew(positionManager, tokenId, abi.encode(renewSignal));

        (, uint256 expiresAtAfter,,) = vtsOrchestrator.getCommit(tokenId);

        console.log("expiresAtPrevious", expiresAtPrevious);
        console.log("expiresAtAfter", expiresAtAfter);

        // validate the expiry is updated
        assertEq(expiresAtAfter + 1, newTimestamp + expiresAtPrevious);
    }

    // function testCanWrapAndUnwrapNativeAsset() public {
    //     // NOTE: Following Uniswap v4 PositionManager pattern, wrap/unwrap are now simple
    //     // WETH9 deposit/withdraw operations without delta accounting.
    //     // The wrap/unwrap operations are handled by MMPositionManager which inherits NativeWrapper.
    //     // Settlement happens via the standard settle/take flow.

    //     uint256 wrapAmount = 1 ether;

    //     // Deal ETH to MMPositionManager
    //     deal(address(mmPositionManager), wrapAmount);

    //     // Get WETH balance before wrap
    //     uint256 wethBalanceBefore = weth9.balanceOf(address(mmPositionManager));

    //     // Wrap native ETH to WETH via MMPositionManager's NativeWrapper
    //     // This is a simple WETH9.deposit() call - no delta accounting
    //     vm.prank(address(mmPositionManager));
    //     MMPositionManager(payable(mmPositionManager)).WETH9().deposit{value: wrapAmount}();

    //     // Get WETH balance after wrap
    //     uint256 wethBalanceAfter = weth9.balanceOf(address(mmPositionManager));

    //     // Validate: WETH balance should increase by wrap amount
    //     assertEq(wethBalanceAfter - wethBalanceBefore, wrapAmount, "WETH balance should increase by wrap amount");

    //     // Unwrap WETH to native ETH
    //     vm.prank(address(mmPositionManager));
    //     MMPositionManager(payable(mmPositionManager)).WETH9().withdraw(wrapAmount);

    //     // Get WETH balance after unwrap
    //     uint256 wethBalanceAfterUnwrap = weth9.balanceOf(address(mmPositionManager));

    //     // Validate: WETH balance should be back to original
    //     assertEq(wethBalanceAfterUnwrap, wethBalanceBefore, "WETH balance should be back to original");
    // }

    function testCanExtendGracePeriod() public {
        // get the default market confiration so we can tweak it
        bytes memory liquiditySignal = abi.encode(liquiditySignal);
        ModifyLiquidityParams memory liquidityParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)});

        // Setup committed position using helper
        (uint256 tokenId,,,) = _setupCommittedPosition(
            positionManager,
            corePoolKey,
            liquiditySignal,
            liquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );
        uint256 positionIndex = 0;

        // extend the grace period of the commitment
        bytes memory settlementProof = abi.encode(1);
        uint8 settlementTokenIndex0 = 0;
        uint8 settlementTokenIndex1 = 1;
        uint32 verifierIndex = 0;

        // mock the call made to the settlement observer to verify the settlement proof
        vm.mockCall(
            address(settlementObserver),
            abi.encodeWithSelector(settlementObserver.verifySettlementProof.selector),
            abi.encode(true)
        );

        PositionId positionId = vtsOrchestrator.getPositionId(tokenId, positionIndex);

        // get the checkpoint of the position
        RFSCheckpoint memory checkpointBefore = vtsOrchestrator.positionToCheckpoint(positionId);

        // extend the grace period of both tokens in the market
        MMA.extendGracePeriod(
            positionManager, corePoolKey, tokenId, positionIndex, settlementTokenIndex0, verifierIndex, settlementProof
        );
        MMA.extendGracePeriod(
            positionManager, corePoolKey, tokenId, positionIndex, settlementTokenIndex1, verifierIndex, settlementProof
        );

        // validate the extension
        RFSCheckpoint memory checkpointAfter = vtsOrchestrator.positionToCheckpoint(positionId);
        vtsOrchestrator.positionToCheckpoint(positionId);

        console.log("gracePeriodExtension0Before", checkpointBefore.gracePeriodExtension0);
        console.log("gracePeriodExtension1Before", checkpointBefore.gracePeriodExtension1);
        console.log("gracePeriodExtension0After", checkpointAfter.gracePeriodExtension0);
        console.log("gracePeriodExtension1After", checkpointAfter.gracePeriodExtension1);
        assertGt(checkpointAfter.gracePeriodExtension0, checkpointBefore.gracePeriodExtension0);
        assertGt(checkpointAfter.gracePeriodExtension1, checkpointBefore.gracePeriodExtension1);
    }

    function testCanUnwrapLcc() public {
        address user = makeAddr("user");
        uint256 amount = 1000;
        // Use lcc0 directly - verify it matches lccToken0 from MarketTestBase
        address lccTokenAddress = address(lcc0);
        // Verify addresses match (they should both be from _currency2)
        assertEq(lccTokenAddress, lccToken0, "lcc0 and lccToken0 should match");

        // Mock user as non-protocol so it accumulates LCC balance when tokens are transferred to it
        vm.mockCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.bounds.selector, address(user)), abi.encode(false)
        );

        // Mock mmPositionManager as protocol so it skips bucket accounting when tokens are transferred/burned to/from it
        vm.mockCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.bounds.selector, address(mmPositionManager)), abi.encode(true)
        );

        // wrap some lcc tokens
        MockERC20 underlyingAsset = MockERC20(lcc0.underlying());
        // mint the underlying asset to the user
        underlyingAsset.mint(user, amount);
        // approve the liquidity hub to spend(move) the underlying asset
        // hub then spends(moves) underlying assets to itself
        // and then gives LCC tokens to the user
        vm.startPrank(user);
        underlyingAsset.approve(address(liquidityHub), amount);
        ILiquidityHub(liquidityHub).wrap(lccTokenAddress, amount);
        vm.stopPrank();

        // validate lcc balance of the user
        assertEq(lcc0.balanceOf(user), amount);

        // unwrap lcc using the position manager
        // approve position manager to spend the lcc (must be approved by the user, not the test contract)
        vm.startPrank(user);
        lcc0.approve(address(positionManager), amount);
        vm.stopPrank();

        // Verify the approval was set correctly (check outside of prank to ensure it persists)
        uint256 allowance = lcc0.allowance(user, address(positionManager));
        assertEq(allowance, amount, "Approval should be set before unwrap");

        // lcc0.balancesOf(user);

        vm.prank(user);
        MMA.unwrapLcc(positionManager, lccTokenAddress, amount, user, true);

        // validate lcc balance of the user
        assertEq(lcc0.balanceOf(user), 0);

        // validate underlying balance of the user
        assertEq(underlyingAsset.balanceOf(user), amount);
    }

    // function testCanCheckpointWithCommitment() public {
    //     // get the default market configuration so we can tweak it
    //     LiquiditySignal memory renewSignal = liquiditySignal;

    //     bytes memory liquiditySignalBytes = abi.encode(liquiditySignal);
    //     ModifyLiquidityParams memory liquidityParams =
    //         ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)});

    //     // Setup committed position using helper
    //     (uint256 tokenId,,,) = _setupCommittedPosition(
    //         positionManager,
    //         corePoolKey,
    //         liquiditySignalBytes,
    //         liquidityParams,
    //         marketVTSConfiguration,
    //         address(lcc0),
    //         address(lcc1)
    //     );
    //     // uint256 positionIndex = 0;
    //     // address advancer = renewSignal.mmState.advancer;

    //     // // checkpoint with commitment backing check
    //     // bytes memory unbackedLiquiditySignal = abi.encode(renewSignal);

    //     // vm.mockCall(
    //     //     address(signalManager),
    //     //     abi.encodeWithSelector(
    //     //         bytes4(keccak256("verifyLiquiditySignal(bytes,bool)")), unbackedLiquiditySignal, true
    //     //     ),
    //     //     abi.encode(true, 10)
    //     // );

    //     // // get liquidity in position 0
    //     // (Position memory positionBeforeCheckpoint,) = vtsOrchestrator.getPosition(tokenId, positionIndex);
    //     // console.log("positionLiquidityBeforeCheckpoint", uint256(positionBeforeCheckpoint.liquidity));

    //     // // need to inflate the value of issuedusd to be greater than the signalusd by 20%
    //     // vm.mockCall(
    //     //     address(oracleHelper),
    //     //     abi.encodeWithSelector(IOracleHelper.getPricesForLccPair.selector),
    //     //     abi.encode(50000000000, 50000000000)
    //     // );

    //     // // Checkpoint with commitment backing check (liquiditySignal provided means withCommitment = true)
    //     // // Call directly through CheckpointEntrypoints which uses msg.sender for validation
    //     // vm.prank(advancer);
    //     // positionManager.checkpoint(tokenId, positionIndex, unbackedLiquiditySignal);

    //     // // get liquidity in position 0
    //     // (Position memory positionAfterCheckpoint,) = vtsOrchestrator.getPosition(tokenId, positionIndex);
    //     // console.log("positionLiquidityAfterCheckpoint", uint256(positionAfterCheckpoint.liquidity));
    // }
}
