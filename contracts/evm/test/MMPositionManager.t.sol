// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

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
import {MarketTestBase} from "./base/MarketTestBase.sol";
import {MMPositionManager} from "../src/MMPositionManager.sol";
import {MMActionAdapter as MMA} from "./libraries/MMActionAdapter.sol";
import {MarketMakerTestBase} from "./base/MMTestBase.sol";
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
import {Errors} from "../src/libraries/Errors.sol";
import {ActionConstants} from "v4-periphery/src/libraries/ActionConstants.sol";

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

    function testCanWrapAndUnwrapNativeAsset() public {
        // NOTE: Following Uniswap v4 PositionManager pattern, wrap/unwrap are now simple
        // WETH9 deposit/withdraw operations without delta accounting.
        // The wrap/unwrap operations are handled by MMPositionManager which inherits NativeWrapper.
        // Settlement happens via the standard settle/take flow.

        uint256 wrapAmount = 1 ether;

        // Deal ETH to MMPositionManager
        deal(address(mmPositionManager), wrapAmount);

        // Get WETH balance before wrap
        uint256 wethBalanceBefore = weth9.balanceOf(address(mmPositionManager));

        // Wrap native ETH to WETH via MMPositionManager's NativeWrapper
        // This is a simple WETH9.deposit() call - no delta accounting
        vm.startPrank(address(mmPositionManager));
        MMPositionManager(payable(mmPositionManager)).WETH9().deposit{value: wrapAmount}();
        vm.stopPrank();

        // Get WETH balance after wrap
        uint256 wethBalanceAfter = weth9.balanceOf(address(mmPositionManager));

        // Validate: WETH balance should increase by wrap amount
        assertEq(wethBalanceAfter - wethBalanceBefore, wrapAmount, "WETH balance should increase by wrap amount");

        // Unwrap WETH to native ETH
        vm.startPrank(address(mmPositionManager));
        MMPositionManager(payable(mmPositionManager)).WETH9().withdraw(wrapAmount);
        vm.stopPrank();

        // Get WETH balance after unwrap
        uint256 wethBalanceAfterUnwrap = weth9.balanceOf(address(mmPositionManager));

        // Validate: WETH balance should be back to original
        assertEq(wethBalanceAfterUnwrap, wethBalanceBefore, "WETH balance should be back to original");
    }

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
            marketFactory,
            abi.encodeWithSelector(IMarketFactory.bounds.selector, address(mmPositionManager)),
            abi.encode(true)
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

    function testCanCheckpointWithCommitment() public {
        // get the default market configuration so we can tweak it
        LiquiditySignal memory renewSignal = liquiditySignal;

        bytes memory liquiditySignalBytes = abi.encode(liquiditySignal);
        ModifyLiquidityParams memory liquidityParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)});

        // Setup committed position using helper
        (uint256 tokenId,,,) = _setupCommittedPosition(
            positionManager,
            corePoolKey,
            liquiditySignalBytes,
            liquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );
        uint256 positionIndex = 0;
        address advancer = renewSignal.mmState.advancer;

        // checkpoint with commitment backing check
        bytes memory unbackedLiquiditySignal = abi.encode(renewSignal);

        vm.mockCall(
            address(signalManager),
            abi.encodeWithSelector(
                bytes4(keccak256("verifyLiquiditySignal(bytes,bool)")), unbackedLiquiditySignal, true
            ),
            abi.encode(true, 10)
        );

        // get liquidity in position 0
        (Position memory positionBeforeCheckpoint,) = vtsOrchestrator.getPosition(tokenId, positionIndex);
        console.log("positionLiquidityBeforeCheckpoint", uint256(positionBeforeCheckpoint.liquidity));

        // need to inflate the value of issuedusd to be greater than the signalusd by 20%
        vm.mockCall(
            address(oracleHelper),
            abi.encodeWithSelector(IOracleHelper.getPricesForLccPair.selector),
            abi.encode(50000000000, 50000000000)
        );

        // Checkpoint with commitment backing check (liquiditySignal provided means withCommitment = true)
        // Call directly through CheckpointEntrypoints which uses msg.sender for validation
        vm.prank(advancer);
        positionManager.checkpoint(tokenId, positionIndex, unbackedLiquiditySignal);

        // get liquidity in position 0
        (Position memory positionAfterCheckpoint,) = vtsOrchestrator.getPosition(tokenId, positionIndex);
        console.log("positionLiquidityAfterCheckpoint", uint256(positionAfterCheckpoint.liquidity));
    }

    function test_modifyLiquidities_revertsWhenDeadlinePassed() public {
        uint256 pastDeadline = block.timestamp - 1;
        vm.expectRevert(abi.encodeWithSelector(Errors.DeadlinePassed.selector, pastDeadline));
        positionManager.modifyLiquidities(hex"", pastDeadline);
    }

    function test_modifyLiquiditiesWithoutUnlock_revertsOnUnsupportedUtilityAction() public {
        uint256 unknownAction = 0xFE;
        bytes memory actions = abi.encodePacked(uint8(unknownAction));
        bytes[] memory params = new bytes[](1);
        params[0] = hex"";
        vm.expectRevert(abi.encodeWithSelector(Errors.UnsupportedAction.selector, unknownAction));
        positionManager.modifyLiquiditiesWithoutUnlock(actions, params);
    }

    function test_tokenURI_revertsWhenCommitmentDescriptorNotSet() public {
        MMPositionManager broken = new MMPositionManager(
            address(manager),
            address(liquidityHub),
            address(vtsOrchestrator),
            address(0),
            weth9,
            permit2,
            address(0xBEEF) // unused for this test
        );
        vm.expectRevert(Errors.CommitmentDescriptorNotSet.selector);
        broken.tokenURI(1);
    }

    function test_wrapNative_amountGtAvailableCredit_revertsInsufficientBalance() public {
        // Create less native credit than requested by sending smaller msg.value.
        MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](1);
        prepared[0] = MMA.prepareWrapNative(1 ether);

        (bytes memory actionsBytes, bytes[] memory params) = MMA.concatPrepared(prepared);
        // value sent = 0.5 ether, but amount requested = 1 ether.
        vm.expectRevert(abi.encodeWithSelector(Errors.InsufficientBalance.selector, 0.5 ether, 1 ether));
        positionManager.modifyLiquiditiesWithoutUnlock{value: 0.5 ether}(actionsBytes, params);
    }

    function test_wrapNative_amountZero_wrapsAllValue_andIsTakeableAsWeth() public {
        address recipient = makeAddr("recipient");

        MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](2);
        prepared[0] = MMA.prepareWrapNative(0); // wrap max available credit
        prepared[1] = MMA.prepareTake(Currency.wrap(address(weth9)), recipient, 0); // take all WETH

        // Send 1 ether to create native credit for the batch.
        MMA.execute(positionManager, prepared, 1 ether);

        assertEq(weth9.balanceOf(recipient), 1 ether);
    }

    function test_unwrapNative_payerIsUser_amountZero_unwrapsAllUserWeth_andIsTakeableAsEth() public {
        address user = makeAddr("user");

        // Give user WETH and approve MMPM via standard allowance.
        vm.deal(user, 2 ether);
        vm.prank(user);
        weth9.deposit{value: 1 ether}();
        vm.prank(user);
        weth9.approve(address(positionManager), type(uint256).max);

        uint256 ethBefore = user.balance;

        MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](2);
        prepared[0] = MMA.prepareUnwrapNative(0, true); // amount=0 => unwrap all payer WETH
        prepared[1] = MMA.prepareTake(CurrencyLibrary.ADDRESS_ZERO, user, 0); // withdraw all credited ETH

        vm.prank(user);
        MMA.execute(positionManager, prepared);

        assertEq(user.balance, ethBefore + 1 ether);
    }

    function test_unwrapNative_fromDeltas_amountZero_unwrapsAllDeltaWeth_andIsTakeableAsEth() public {
        address user = makeAddr("user");

        // First, create WETH delta credit for the locker by wrapping native in-batch.
        MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](3);
        prepared[0] = MMA.prepareWrapNative(1 ether);
        prepared[1] = MMA.prepareUnwrapNative(0, false); // amount=0 => unwrap max from delta
        prepared[2] = MMA.prepareTake(CurrencyLibrary.ADDRESS_ZERO, user, 0);

        uint256 ethBefore = user.balance;
        MMA.execute(positionManager, prepared, 1 ether);
        assertEq(user.balance, ethBefore + 1 ether);
    }

    function test_unwrapLcc_payerIsUser_requestedLessThanBalance_clampsToRequested() public {
        address user = makeAddr("user");

        // Ensure user is treated as non-protocol.
        vm.mockCall(marketFactory, abi.encodeWithSelector(IMarketFactory.bounds.selector, user), abi.encode(false));

        MockERC20 underlyingAsset = MockERC20(lcc0.underlying());
        underlyingAsset.mint(user, 1000);

        vm.startPrank(user);
        underlyingAsset.approve(address(liquidityHub), 1000);
        ILiquidityHub(liquidityHub).wrap(address(lcc0), 1000);
        lcc0.approve(address(positionManager), type(uint256).max);
        vm.stopPrank();

        uint256 requested = 400;
        uint256 underlyingBefore = underlyingAsset.balanceOf(user);

        vm.prank(user);
        MMA.unwrapLcc(positionManager, address(lcc0), requested, user, true);

        assertEq(lcc0.balanceOf(user), 600);
        assertEq(underlyingAsset.balanceOf(user), underlyingBefore + requested);
    }

    function test_unwrapLcc_fromDeltas_toThis_syncsUnderlying_andIsTakeable() public {
        // Put LCC balance onto MMPM, sync it as credit to the locker, then unwrap from deltas to address(this).
        address lccAddr = address(lcc0);
        Currency lccCurrency = Currency.wrap(lccAddr);
        MockERC20 underlying = MockERC20(lcc0.underlying());
        Currency underlyingCurrency = Currency.wrap(address(underlying));

        // Mint LCC to this test contract via hub wrap.
        underlying.mint(address(this), 500);
        underlying.approve(address(liquidityHub), 500);
        ILiquidityHub(liquidityHub).wrap(lccAddr, 500);

        // Transfer LCC to MMPM and sync it as credit.
        lcc0.transfer(address(positionManager), 500);

        address recipient = makeAddr("recipient");

        MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](3);
        prepared[0] = MMA.prepareSync(lccCurrency);
        // Use ActionConstants.ADDRESS_THIS so BaseActionsRouter maps it to the MMPM address.
        prepared[1] = MMA.prepareUnwrapLcc(lccAddr, 0, ActionConstants.ADDRESS_THIS, false);
        prepared[2] = MMA.prepareTake(underlyingCurrency, recipient, 0); // consume underlying credit and move tokens out

        MMA.execute(positionManager, prepared);

        assertEq(underlying.balanceOf(recipient), 500);
    }

    function test_checkpointAndTransferFrom_revertWhilePoolManagerUnlocked() public {
        // Set up a committed position to mint a tokenId.
        (uint256 tokenId,,,) = _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)}),
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        // While PoolManager is unlocked, both checkpoint() and transferFrom() must revert.
        UnlockCaller caller = new UnlockCaller();

        vm.expectRevert(Errors.PoolManagerMustBeLocked.selector);
        caller.checkpointWhileUnlocked(manager, positionManager, tokenId, 0);

        vm.expectRevert(Errors.PoolManagerMustBeLocked.selector);
        caller.transferFromWhileUnlocked(manager, positionManager, address(this), makeAddr("to"), tokenId);
    }
}

/// @dev Helper to call MMPM functions while PoolManager is in an unlocked state.
contract UnlockCaller {
    MMPositionManager internal targetMmpm;
    uint256 internal tokenId;
    uint256 internal positionIndex;

    address internal transferFromFrom;
    address internal transferFromTo;

    bool internal doCheckpoint;
    bool internal doTransferFrom;

    function checkpointWhileUnlocked(
        IPoolManager poolManager,
        MMPositionManager mmpm,
        uint256 _tokenId,
        uint256 _positionIndex
    ) external {
        targetMmpm = mmpm;
        tokenId = _tokenId;
        positionIndex = _positionIndex;
        doCheckpoint = true;
        doTransferFrom = false;
        poolManager.unlock(hex"");
    }

    function transferFromWhileUnlocked(
        IPoolManager poolManager,
        MMPositionManager mmpm,
        address from,
        address to,
        uint256 _tokenId
    ) external {
        targetMmpm = mmpm;
        transferFromFrom = from;
        transferFromTo = to;
        tokenId = _tokenId;
        doCheckpoint = false;
        doTransferFrom = true;
        poolManager.unlock(hex"");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        if (doCheckpoint) {
            targetMmpm.checkpoint(tokenId, positionIndex);
        }
        if (doTransferFrom) {
            targetMmpm.transferFrom(transferFromFrom, transferFromTo, tokenId);
        }
        return "";
    }
}
