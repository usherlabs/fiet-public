// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
// solhint-disable max-line-length

import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {LiquidityCommitmentCertificate} from "../src/LCC.sol";
import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";
import {LiquidityUtils} from "../src/libraries/LiquidityUtils.sol";
import {console} from "forge-std/console.sol";
import {MarketTestBase} from "./base/MarketTestBase.sol";
import {MMPositionManager} from "../src/MMPositionManager.sol";
import {MMActionAdapter as MMA} from "./utils/MMActionAdapter.sol";
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
import {IMarketVault} from "../src/interfaces/IMarketVault.sol";
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

    // Mirror MMPositionManager events so we can vm.expectEmit() them.
    event SignalCommitted(uint256 tokenId);
    event SignalDecommitted(uint256 tokenId, uint256 positionCount);
    event LiquidityAvailable(address indexed lcc, address underlyingAsset, uint256 amount, bytes32 marketId);
    event SettlementQueued(address indexed lcc, address indexed recipient, uint256 amount);

    struct AfterSwapPhase1Params {
        uint256 tokenId;
        uint256 positionIndex;
        address recipient;
        Currency lcc0Currency;
        uint256 requiredSettlementAmount0;
        uint256 requiredSettlementAmount1;
        uint256 amountToDecrease;
    }

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

    /// @notice Mutation-killer: proves COMMIT_SIGNAL emits `SignalCommitted(tokenId)` (event deletion should fail).
    /// @dev Uses `nextTokenId()` to predict the tokenId that should be emitted.
    function test_commitSignal_emitsSignalCommitted() public {
        bytes memory liquiditySignalBytes = abi.encode(liquiditySignal);
        uint256 expectedTokenId = positionManager.nextTokenId();

        MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](1);
        prepared[0] = MMA.prepareCommit(liquiditySignalBytes);

        vm.expectEmit(true, false, false, true);
        emit SignalCommitted(expectedTokenId);
        MMA.executeWithUnlock(positionManager, prepared, block.timestamp + 3600);

        assertEq(positionManager.ownerOf(expectedTokenId), address(this), "commit should mint NFT to expected owner");
    }

    /// @notice Mutation-killer: proves DECOMMIT_SIGNAL emits `SignalDecommitted(tokenId, positionCount)` and burns the NFT.
    /// @dev We commit without minting any positions, so `positionCount == 0` deterministically.
    function test_decommitSignal_emitsSignalDecommitted() public {
        bytes memory liquiditySignalBytes = abi.encode(liquiditySignal);
        uint256 tokenId = positionManager.nextTokenId();

        // Commit only (no positions minted) then decommit.
        MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](1);
        prepared[0] = MMA.prepareCommit(liquiditySignalBytes);
        MMA.executeWithUnlock(positionManager, prepared, block.timestamp + 3600);

        // Decommit the signal
        prepared = new MMA.PreparedAction[](1);
        prepared[0] = MMA.prepareDecommit(tokenId);

        // positionCount should be 0 for a fresh commit with no minted positions.
        vm.expectEmit(true, false, false, true);
        emit SignalDecommitted(tokenId, 0);
        MMA.executeWithUnlock(positionManager, prepared, block.timestamp + 3600);

        // Token is burned; ownerOf should revert.
        vm.expectRevert();
        positionManager.ownerOf(tokenId);
    }

    /// @notice Proves RENEW_SIGNAL updates the commitment without creating a new NFT.
    /// @dev Verifies the expiry is correctly extended by the new signal.
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

    /// @notice Proves UNWRAP_LCC with payerIsUser=true unwraps all payer LCC balance.
    /// @dev Practical tip: verify unwrap == balance to prove no partial unwrap.
    function test_unwrapLcc_payerIsUser_requestedGreaterThanBalance_unwrapsAllBalance() public {
        address user = makeAddr("user");

        // Ensure user is treated as non-protocol.
        vm.mockCall(marketFactory, abi.encodeWithSelector(IMarketFactory.bounds.selector, user), abi.encode(false));

        MockERC20 underlyingAsset = MockERC20(lcc0.underlying());
        uint256 balance = 400;
        underlyingAsset.mint(user, balance);

        vm.startPrank(user);
        underlyingAsset.approve(address(liquidityHub), balance);
        ILiquidityHub(liquidityHub).wrap(address(lcc0), balance);
        lcc0.approve(address(positionManager), type(uint256).max);
        vm.stopPrank();

        uint256 requested = balance + 1;
        uint256 underlyingBefore = underlyingAsset.balanceOf(user);

        vm.prank(user);
        MMA.unwrapLcc(positionManager, address(lcc0), requested, user, true);

        assertEq(lcc0.balanceOf(user), 0, "request > balance should unwrap all payer LCC");
        assertEq(
            underlyingAsset.balanceOf(user),
            underlyingBefore + balance,
            "request > balance should transfer exactly payer balance worth of underlying"
        );
    }

    /// @notice Mutation-killer: validates the unwrap accounting is `afterBal - beforeBal` (not `+ beforeBal`).
    /// @dev Recipient starts with a non-zero underlying balance so the delta calculation is observable.
    function test_unwrapLcc_payerIsUser_recipientHasPreBalance_correctlyMeasuresDelta() public {
        address user = makeAddr("user");
        address recipient = makeAddr("recipient");

        vm.mockCall(marketFactory, abi.encodeWithSelector(IMarketFactory.bounds.selector, user), abi.encode(false));
        vm.mockCall(marketFactory, abi.encodeWithSelector(IMarketFactory.bounds.selector, recipient), abi.encode(false));

        MockERC20 underlyingAsset = MockERC20(lcc0.underlying());
        uint256 amount = 500;

        // Give the recipient a pre-existing underlying balance so we can assert delta precisely.
        underlyingAsset.mint(recipient, 123);
        uint256 beforeRecipient = underlyingAsset.balanceOf(recipient);

        underlyingAsset.mint(user, amount);
        vm.startPrank(user);
        underlyingAsset.approve(address(liquidityHub), amount);
        ILiquidityHub(liquidityHub).wrap(address(lcc0), amount);
        lcc0.approve(address(positionManager), type(uint256).max);
        vm.stopPrank();

        vm.prank(user);
        MMA.unwrapLcc(positionManager, address(lcc0), amount, recipient, true);

        assertEq(
            underlyingAsset.balanceOf(recipient) - beforeRecipient,
            amount,
            "unwrap should increase recipient underlying by exactly amount"
        );
    }

    /// @notice Mutation-killer: if `unwrapped == 0`, MMPM must not sync any underlying credit.
    /// @dev Practical tip: verify “no sync happened” by immediately doing a `TAKE` and asserting it moves nothing.
    function test_unwrapLcc_payerIsUser_toThis_unwrappedZero_doesNotSyncExistingUnderlyingCredit() public {
        address user = makeAddr("user");

        // User has zero LCC; request > 0 ensures toUnwrap=0 and unwrapped=0.
        vm.mockCall(marketFactory, abi.encodeWithSelector(IMarketFactory.bounds.selector, user), abi.encode(false));

        MockERC20 underlying = MockERC20(lcc0.underlying());
        Currency underlyingCurrency = Currency.wrap(address(underlying));

        // Pre-fund MMPM with underlying, but do NOT sync it.
        uint256 seeded = 777;
        underlying.mint(address(positionManager), seeded);

        uint256 userBefore = underlying.balanceOf(user);
        uint256 pmBefore = underlying.balanceOf(address(positionManager));

        MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](2);
        prepared[0] = MMA.prepareUnwrapLcc(address(lcc0), 1, ActionConstants.ADDRESS_THIS, true);
        prepared[1] = MMA.prepareTake(underlyingCurrency, user, 0);

        vm.prank(user);
        MMA.execute(positionManager, prepared);

        // Correct behaviour: no unwrap occurred, so no sync should happen, so TAKE should move nothing.
        assertEq(underlying.balanceOf(user), userBefore, "unwrapped==0 should not create takeable underlying credit");
        assertEq(
            underlying.balanceOf(address(positionManager)),
            pmBefore,
            "unwrapped==0 should not transfer underlying out of MMPM via TAKE"
        );
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
        // Reuse the real actions impl from the already-deployed PositionManager so the constructor succeeds.
        // This test is about `commitmentDescriptor`, not delegation.
        MMPositionManager broken = new MMPositionManager(
            address(manager),
            address(liquidityHub),
            address(vtsOrchestrator),
            address(0),
            weth9,
            permit2,
            positionManager.actionsImpl()
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

    /// @notice Mutation-killer: amount < available credit should NOT revert, and should only wrap the requested amount.
    /// @dev Practical tip: validate both the wrapped portion and the remaining native credit via follow-up `TAKE`s.
    function test_wrapNative_amountLtAvailableCredit_wrapsExactAmount_and_allowsTakingRemainderAsEth_practicalTip()
        public
    {
        address wethRecipient = makeAddr("wethRecipient");
        address ethRecipient = makeAddr("ethRecipient");

        MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](3);
        prepared[0] = MMA.prepareWrapNative(1 ether); // request less than provided credit
        prepared[1] = MMA.prepareTake(Currency.wrap(address(weth9)), wethRecipient, 0); // should take exactly 1 WETH
        prepared[2] = MMA.prepareTake(CurrencyLibrary.ADDRESS_ZERO, ethRecipient, 0); // consume remaining native credit

        uint256 ethBefore = ethRecipient.balance;
        // Third param is msg.value
        MMA.execute(positionManager, prepared, 2 ether);

        assertEq(weth9.balanceOf(wethRecipient), 1 ether, "should take exactly wrapped WETH amount");
        assertEq(ethRecipient.balance - ethBefore, 1 ether, "should take the remaining native credit as ETH");
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

    /// @notice Mutation-killer: when `settleQueue(lcc, sender) == 0`, COLLECT_AVAILABLE_LIQUIDITY must be a no-op.
    function test_collectAvailableLiquidity_whenQueuedIsZero_isNoop() public {
        MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](1);
        address recipient = makeAddr("recipient");
        uint256 lcc0BalanceBefore = lcc0.balanceOf(address(this));
        prepared[0] = MMA.prepareCollectAvailableLiquidity(address(lcc0), 0);
        assertEq(
            ILiquidityHub(liquidityHub).settleQueue(address(lcc0), recipient),
            0,
            "precondition: recipient should have no queued settlement"
        );
        MMA.execute(positionManager, prepared);
        assertEq(lcc0.balanceOf(address(this)), lcc0BalanceBefore, "no-op collect should not change LCC balances");
    }

    /// @notice Mutation-killer: when `settleQueue(lcc, sender) > 0`, COLLECT_AVAILABLE_LIQUIDITY must process settlement.
    /// @dev We create a real queued settlement entry, then ensure it is cleared and underlying is received.
    function test_collectAvailableLiquidity_whenQueuedPositive_processesSettlementToSender() public {
        address user = makeAddr("user");
        address lccAddr = address(lcc0);
        MockERC20 underlying = MockERC20(lcc0.underlying());

        // Key objective: ensure the unwrap MUST queue (no direct/wrapped balance available).
        // Use a fresh `user` address (no wrapped/direct LCC) and give it ONLY market-derived LCC.
        // Treat MarketFactory as protocol-bound so transfers from it mint market-derived bucket to `user`.
        vm.mockCall(
            marketFactory,
            abi.encodeWithSelector(IMarketFactory.bounds.selector, address(marketFactory)),
            abi.encode(true)
        );

        // Give MMPositionManager LCC by transferring from a protocol-bound address.
        uint256 amount = 250;
        underlying.mint(address(marketFactory), amount);
        vm.startPrank(address(marketFactory));
        underlying.approve(address(liquidityHub), amount);
        ILiquidityHub(liquidityHub).wrap(lccAddr, amount);
        vm.stopPrank();

        // Force unwrap to queue (no market liquidity available).
        vm.mockCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector), abi.encode(uint256(0))
        );

        vm.prank(address(vtsOrchestrator));
        ILiquidityHub(liquidityHub)
            .planCancelWithQueue(lccAddr, address(marketFactory), address(positionManager), amount, amount, user);

        vm.prank(address(marketFactory));
        ILCC(lccAddr).transfer(address(positionManager), amount);

        // Create a queue entry for `user` - using planCancelWithQueue.
        assertEq(
            ILiquidityHub(liquidityHub).settleQueue(lccAddr, user),
            amount,
            "precondition: sender should have queued settlement after unwrap shortfall"
        );

        // Make underlying reserves available so settlement can actually be processed.
        underlying.mint(address(liquidityHub), amount);
        vm.prank(address(vtsOrchestrator));
        vm.expectEmit(true, true, true, true);
        emit LiquidityAvailable(lccAddr, address(underlying), amount, PoolId.unwrap(corePoolKey.toId()));
        ILiquidityHub(liquidityHub).confirmTake(lccAddr, amount, true); // emit LiquidityAvailable event

        uint256 beforeUnderlying = underlying.balanceOf(user);

        MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](1);
        prepared[0] = MMA.prepareCollectAvailableLiquidity(lccAddr, type(uint256).max);
        vm.prank(user);
        MMA.executeWithUnlock(positionManager, prepared, block.timestamp + 3600);

        assertEq(ILiquidityHub(liquidityHub).settleQueue(lccAddr, user), 0, "collect should clear sender's queue entry");
        assertEq(
            underlying.balanceOf(user) - beforeUnderlying, amount, "collect should transfer queued underlying to sender"
        );
    }

    /// @notice Mutation-killer: when `recipient == address(this)`, COLLECT_AVAILABLE_LIQUIDITY must sync underlying credit.
    /// @dev Practical tip: verify the sync by immediately doing a `TAKE(underlying)` to an external recipient.
    function test_collectAvailableLiquidity_noSwap() public {
        address recipient = makeAddr("recipient");
        address lcc0Addr = address(lcc0);
        MockERC20 underlying0 = MockERC20(lcc0.underlying());

        Currency lcc1Currency = Currency.wrap(address(lcc1));

        // Ensure MMPM is treated as protocol-bound (mirrors production deployment via MarketFactory initial bounds).
        vm.mockCall(
            marketFactory,
            abi.encodeWithSelector(IMarketFactory.bounds.selector, address(positionManager)),
            abi.encode(true)
        );

        uint256 lcc1BalanceBefore = lcc1Currency.balanceOfSelf();

        uint256 amount;
        {
            // ------------------------------------------------------------
            // Protocol-accurate preparation:
            // - Create a committed MM position.
            // - Force MarketVault available liquidity to zero.
            // - Decrease liquidity via MMPM, which should planCancelWithQueue (VTSPositionLib) and create a settleQueue entry.
            // ------------------------------------------------------------
            ModifyLiquidityParams memory liquidityParams =
                ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)});

            (uint256 tokenId,, uint256 requiredSettlementAmount0, uint256 requiredSettlementAmount1) = _setupCommittedPosition(
                positionManager,
                corePoolKey,
                abi.encode(liquiditySignal),
                liquidityParams,
                marketVTSConfiguration,
                address(lcc0),
                address(lcc1)
            );
            amount = requiredSettlementAmount0;

            (,, uint256 commitPositionCount,) = positionManager.commitOf(tokenId);
            uint256 positionIndex = commitPositionCount - 1;

            // Allow `recipient` (locker) to call decrease on this position.
            positionManager.approve(recipient, tokenId);

            // Force MarketVault to report zero available liquidity so cancellation must queue.
            vm.mockCall(
                address(mv),
                abi.encodeWithSelector(IMarketVault.dryModifyLiquidities.selector),
                abi.encode(toBalanceDelta(0, 0))
            );

            // Force "no market liquidity" to make behaviour deterministic (no direct settlement).
            vm.mockCall(
                marketFactory,
                abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector),
                abi.encode(uint256(0))
            );

            // Phase 1 (protocol prep, within unlock):
            // - DECREASE triggers planCancelWithQueue and queues settlement for the locker (recipient).
            uint256 amountToDecrease = uint256(liquidityParams.liquidityDelta);
            MMA.PreparedAction[] memory setup = new MMA.PreparedAction[](2);
            setup[0] = MMA.prepareDecrease(corePoolKey, tokenId, positionIndex, amountToDecrease);
            setup[1] = MMA.prepareSettle(
                corePoolKey,
                tokenId,
                positionIndex,
                requiredSettlementAmount0.toInt128(),
                requiredSettlementAmount1.toInt128(),
                false
            );

            vm.prank(recipient);
            MMA.executeWithUnlock(positionManager, setup, block.timestamp + 3600);
        }

        assertEq(
            ILiquidityHub(liquidityHub).settleQueue(lcc0Addr, address(positionManager)),
            0,
            "precondition: MMPM does NOT get assigned the queue, the recipient does."
        );
        assertEq(
            ILiquidityHub(liquidityHub).settleQueue(lcc0Addr, recipient),
            amount,
            "precondition: recipient should have queued settlement after unwrap shortfall"
        );

        // Make underlying reserves available so settlement can actually be processed.
        underlying0.mint(address(liquidityHub), amount);
        vm.prank(address(vtsOrchestrator)); // prank as an issuer - it's marketvault in production
        ILiquidityHub(liquidityHub).confirmTake(lcc0Addr, amount, false);

        assertGe(
            ILiquidityHub(liquidityHub).reserveOfUnderlying(lcc0Addr), amount, "take should accrue to LCC reserves"
        );

        uint256 recipientBefore = underlying0.balanceOf(recipient);

        // Practical tip: validate sync happened by immediately doing a TAKE of the underlying.
        {
            MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](1);
            prepared[0] = MMA.prepareCollectAvailableLiquidity(lcc0Addr, type(uint256).max);

            vm.prank(recipient);
            MMA.execute(positionManager, prepared);
        }

        uint256 lcc1BalanceAfter = lcc1Currency.balanceOfSelf();

        assertEq(
            underlying0.balanceOf(recipient) - recipientBefore,
            amount,
            "collect(recipient=this) should sync credit so TAKE transfers queued underlying"
        );

        assertEq(lcc1BalanceAfter, lcc1BalanceBefore, "lcc1 balance should not change - no fees collected");
    }

    /// @notice Control case (no swap / no fees): queued principal is consumed by collect and there are no fee LCCs to take.
    function test_collectAvailableLiquidity_afterSwap() public {
        address recipient = makeAddr("recipient");
        address lcc0Addr = address(lcc0);
        address lcc1Addr = address(lcc1);
        MockERC20 underlying0 = MockERC20(lcc0.underlying());

        // Ensure MMPM is treated as protocol-bound (mirrors production deployment via MarketFactory initial bounds).
        vm.mockCall(
            marketFactory,
            abi.encodeWithSelector(IMarketFactory.bounds.selector, address(positionManager)),
            abi.encode(true)
        );

        uint256 recipientLcc0Before;
        uint256 recipientLcc0FeeAfterTake;
        uint256 lcc1BalanceBefore;
        uint256 amount;
        uint256 settled1;
        {
            AfterSwapPhase1Params memory p;

            // ------------------------------------------------------------
            // Protocol-accurate preparation:
            // - Create a committed MM position.
            // - Force MarketVault available liquidity to zero.
            // - Decrease liquidity via MMPM, which should planCancelWithQueue (VTSPositionLib) and create a settleQueue entry.
            // ------------------------------------------------------------
            ModifyLiquidityParams memory liquidityParams =
                ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: bytes32(0)});

            (p.tokenId,, p.requiredSettlementAmount0, p.requiredSettlementAmount1) = _setupCommittedPosition(
                positionManager,
                corePoolKey,
                abi.encode(liquiditySignal),
                liquidityParams,
                marketVTSConfiguration,
                address(lcc0),
                address(lcc1)
            );
            (,, uint256 commitPositionCount,) = positionManager.commitOf(p.tokenId);
            p.positionIndex = commitPositionCount - 1;

            _swapAccrueFeesViaSwap(underlying0, lcc0Addr, 1e18);

            {
                Currency lcc1Currency = Currency.wrap(lcc1Addr);
                lcc1BalanceBefore = lcc1Currency.balanceOfSelf();
            }

            recipientLcc0Before = IERC20(lcc0Addr).balanceOf(recipient);

            // Allow `recipient` (locker) to call decrease on this position.
            positionManager.approve(recipient, p.tokenId);

            // Phase 1 (protocol prep, within unlock):
            // - SETTLE closes RFS so the position can be decreased.
            // - DECREASE triggers planCancelWithQueue and queues settlement for the locker (recipient).
            // - DECREASE credits the locker with only the *fee* slice of LCC inflows (queued principal is excluded by impl logic).
            // - We then TAKE that fee credit to `recipient` inside the same unlock session, ensuring no dangling deltas.
            p.recipient = recipient;
            p.lcc0Currency = Currency.wrap(lcc0Addr);
            p.amountToDecrease = 1e18; // matches liquidityDelta used in setup

            (amount, settled1) = _afterSwapPhase1(p);
        }
        assertEq(
            ILiquidityHub(liquidityHub).settleQueue(lcc0Addr, address(positionManager)),
            0,
            "precondition: MMPM does NOT get assigned the queue, the recipient does."
        );
        assertEq(
            ILiquidityHub(liquidityHub).settleQueue(lcc0Addr, recipient),
            amount,
            "precondition: recipient should have queued settlement after unwrap shortfall"
        );
        // Optional: symmetry check on the token1 side (helps catch currency mixups).
        assertEq(
            ILiquidityHub(liquidityHub).settleQueue(lcc1Addr, recipient),
            settled1,
            "precondition: recipient lcc1 queue should match settledToken1"
        );

        // Assert: fee LCC0 was takeable (non-zero) and did NOT drain the queued principal held by MMPM.
        recipientLcc0FeeAfterTake = IERC20(lcc0Addr).balanceOf(recipient) - recipientLcc0Before;
        assertGt(recipientLcc0FeeAfterTake, 0, "expected non-zero LCC0 fees to be takeable after swap");
        assertGe(
            IERC20(lcc0Addr).balanceOf(address(positionManager)),
            amount,
            "MMPM must still hold >= queued principal LCC0 after fee TAKE"
        );

        // Make underlying reserves available so settlement can actually be processed.
        underlying0.mint(address(liquidityHub), amount);
        vm.prank(address(vtsOrchestrator)); // prank as an issuer - it's marketvault in production
        ILiquidityHub(liquidityHub).confirmTake(lcc0Addr, amount, false);

        assertGe(
            ILiquidityHub(liquidityHub).reserveOfUnderlying(lcc0Addr), amount, "take should accrue to LCC reserves"
        );

        uint256 recipientBefore = underlying0.balanceOf(recipient);

        // Practical tip: validate sync happened by immediately doing a TAKE of the underlying.
        {
            MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](1);
            prepared[0] = MMA.prepareCollectAvailableLiquidity(lcc0Addr, type(uint256).max);

            vm.prank(recipient);
            MMA.execute(positionManager, prepared);
        }

        uint256 lcc1BalanceAfter;
        {
            Currency lcc1Currency = Currency.wrap(lcc1Addr);
            lcc1BalanceAfter = lcc1Currency.balanceOfSelf();
        }
        uint256 recipientLcc0AfterCollect = IERC20(lcc0Addr).balanceOf(recipient);

        assertEq(
            underlying0.balanceOf(recipient) - recipientBefore,
            amount,
            "collect(recipient=this) should sync credit so TAKE transfers queued underlying"
        );

        // The queued principal LCC was transferred in and burned to pay out underlying; fee LCC should remain.
        assertEq(
            recipientLcc0AfterCollect - recipientLcc0Before,
            recipientLcc0FeeAfterTake,
            "queued principal should be consumed by collect; only fee-derived LCC should remain"
        );

        assertEq(lcc1BalanceAfter, lcc1BalanceBefore, "lcc1 balance should not change - no fees collected");
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

    /*** INTERNAL FUNCTIONS FOR test_collectAvailableLiquidity_afterSwap ***/

    function _afterSwapPhase1(AfterSwapPhase1Params memory p) internal returns (uint256 amount, uint256 settled1) {
        // Force MarketVault to report zero available liquidity so cancellation must queue.
        vm.mockCall(
            address(mv),
            abi.encodeWithSelector(IMarketVault.dryModifyLiquidities.selector),
            abi.encode(toBalanceDelta(0, 0))
        );

        // Force "no market liquidity" to make behaviour deterministic (no direct settlement).
        vm.mockCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector), abi.encode(uint256(0))
        );

        // Settle exactly the current RfS requirement (after the swap), otherwise decrease reverts with RFSOpenForPosition.
        PositionId positionId = positionManager.getPositionId(p.tokenId, p.positionIndex);
        (bool rfsOpen, BalanceDelta rfsDelta) = vtsOrchestrator.calcRFS(positionId, false);
        assertTrue(rfsOpen, "precondition: swap should open RFS");

        // Ensure we push above 0 + the base VTS required.
        int128 settle0 =
            rfsDelta.amount0() > 0 ? -rfsDelta.amount0() - SafeCast.toInt128(p.requiredSettlementAmount0) : int128(0);
        int128 settle1Local =
            rfsDelta.amount1() > 0 ? -rfsDelta.amount1() - SafeCast.toInt128(p.requiredSettlementAmount1) : int128(0);
        uint256 pay0 = LiquidityUtils.safeInt128ToUint256(settle0);
        uint256 pay1 = LiquidityUtils.safeInt128ToUint256(settle1Local);

        MMA.PreparedAction[] memory setup = new MMA.PreparedAction[](3);
        setup[0] = MMA.prepareSettle(corePoolKey, p.tokenId, p.positionIndex, settle0, settle1Local, false);
        setup[1] = MMA.prepareDecrease(corePoolKey, p.tokenId, p.positionIndex, p.amountToDecrease);
        // Fee-only take: if fees accrued, this transfers only the fee portion (not the queued principal).
        setup[2] = MMA.prepareTake(p.lcc0Currency, p.recipient, 0);

        vm.startPrank(p.recipient);
        // Fund exactly what we’re going to deposit for settlement (avoids underflow + avoids over-settling into a later withdrawal/queue).
        if (pay0 > 0) {
            MockERC20(lcc0.underlying()).mint(p.recipient, pay0);
            MockERC20(lcc0.underlying()).approve(address(positionManager), pay0);
        }
        if (pay1 > 0) {
            MockERC20(lcc1.underlying()).mint(p.recipient, pay1);
            MockERC20(lcc1.underlying()).approve(address(positionManager), pay1);
        }
        MMA.executeWithUnlock(positionManager, setup, block.timestamp + 3600);
        vm.stopPrank();

        // getPositionSettledAmounts returns (token0, token1). We are asserting the queue for LCC0 (token0).
        (uint256 settled0, uint256 settled1Out) = vtsOrchestrator.getPositionSettledAmounts(positionId);
        return (settled0, settled1Out);
    }

    function _swapAccrueFeesViaSwap(MockERC20 underlying0, address lcc0Addr, uint256 swapAmount) internal {
        // ------------------------------------------------------------
        // Create fees on the core pool before decreasing:
        // - Perform an exact-input swap in a single direction so fees accrue on only the input token (LCC0).
        // - This lets us assert that only fee-derived LCCs are takeable, not queued principal LCCs.
        // ------------------------------------------------------------
        underlying0.mint(address(this), swapAmount);
        underlying0.approve(address(liquidityHub), swapAmount);
        ILiquidityHub(liquidityHub).wrap(lcc0Addr, swapAmount);
        // Safety: ensure swap router can pull LCC0 from this test contract.
        IERC20(lcc0Addr).approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            corePoolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(swapAmount), sqrtPriceLimitX96: ZERO_FOR_ONE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
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
