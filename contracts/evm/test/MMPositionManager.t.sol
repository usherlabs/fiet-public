// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
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
import {VTSOrchestratorTestable} from "./base/VTSOrchestratorTestable.sol";
import {VTSOrchestrator} from "../src/VTSOrchestrator.sol";
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
import {IMMQueueCustodian} from "../src/interfaces/IMMQueueCustodian.sol";
import {IMarketVault} from "../src/interfaces/IMarketVault.sol";
import {IMarketVaultDryBalanceDelta} from "./_helpers/IMarketVaultDryBalanceDelta.sol";
import {Errors} from "../src/libraries/Errors.sol";
import {MMActions} from "../src/libraries/MMActions.sol";
import {Bounds} from "../src/libraries/Bounds.sol";
import {ActionConstants} from "v4-periphery/src/libraries/ActionConstants.sol";
import {MockCommitmentDescriptor} from "./_mocks/MockCommitmentDescriptor.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

/// @title MMPMTwoExternalCallsRouter
/// @notice Two separate external calls to `modifyLiquiditiesWithoutUnlock` in one transaction (not `multicall` delegatecall).
contract MMPMTwoExternalCallsRouter {
    /// @dev First call sends 0 ETH; second forwards the router’s entire `msg.value` to MMPM (funded wrap path).
    function zeroThenFundedWrapTake(
        MMPositionManager mmpm,
        bytes memory actionsEmpty,
        bytes[] memory paramsEmpty,
        bytes memory wrapActions,
        bytes[] memory wrapParams
    ) external payable {
        mmpm.modifyLiquiditiesWithoutUnlock(actionsEmpty, paramsEmpty);
        mmpm.modifyLiquiditiesWithoutUnlock{value: msg.value}(wrapActions, wrapParams);
    }

    /// @dev Two funded batches (1 ETH + 1 ETH); each leg wraps only its own attachment when balance-delta accounting is correct.
    function twoFundedWrapTake(
        MMPositionManager mmpm,
        bytes memory wrapActions,
        bytes[] memory wrapParamsFirst,
        bytes[] memory wrapParamsSecond
    ) external payable {
        require(msg.value == 2 ether, "twoFundedWrapTake: expected 2 ether");
        mmpm.modifyLiquiditiesWithoutUnlock{value: 1 ether}(wrapActions, wrapParamsFirst);
        mmpm.modifyLiquiditiesWithoutUnlock{value: 1 ether}(wrapActions, wrapParamsSecond);
    }
}

contract MMPositionManagerTest is MarketTestBase, MarketMakerTestBase {
    using SafeCast for *;
    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;
    using MarketMaker for MarketMaker.State;
    using StateLibrary for IPoolManager;
    using stdStorage for StdStorage;

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

    StdStorage internal _store;
    uint256 internal _scratchTokenId;

    function _inactiveRemnantCount(uint256 tokenId) internal view returns (uint256) {
        (,,,, uint256 cnt) = vtsOrchestrator.getCommit(tokenId);
        return cnt;
    }

    function _getPositionEffectiveSettledAmounts(PositionId positionId) internal view returns (uint256, uint256) {
        return VTSOrchestratorTestable(address(vtsOrchestrator)).getPositionEffectiveSettledAmounts(positionId);
    }

    function _getPositionLiveSettledAmounts(PositionId positionId) internal view returns (uint256, uint256) {
        (,, uint256 settled0, uint256 settled1,,,,) =
            VTSOrchestratorTestable(address(vtsOrchestrator)).getPositionAccounting(positionId);
        return (settled0, settled1);
    }

    function _assertQueuedUtilityPair(
        IMMQueueCustodian qc,
        address lccAddr,
        address beneficiaryA,
        address beneficiaryB,
        uint256 expectedA,
        uint256 expectedB
    ) internal {
        assertEq(qc.queued(0, lccAddr, beneficiaryA), expectedA);
        assertEq(qc.queued(0, lccAddr, beneficiaryB), expectedB);
    }

    /// @dev Thin wrappers around `MarketTestBase` helpers using this suite's `positionManager`.
    function _wireTestQueueCustodian(address recipient) internal {
        _wireTestQueueCustodianFor(address(positionManager), recipient);
    }

    function _wireAllUtilityTestCustodians() internal {
        _wireAllUtilityTestQueueCustodians(address(positionManager));
    }

    function _mintUnderlyingForPositiveSettle(address payer, int128 settle0, int128 settle1) internal {
        uint256 pay0 = LiquidityUtils.safeInt128ToUint256(settle0);
        uint256 pay1 = LiquidityUtils.safeInt128ToUint256(settle1);
        if (pay0 > 0) {
            MockERC20(lcc0.underlying()).mint(payer, pay0);
            vm.prank(payer);
            MockERC20(lcc0.underlying()).approve(address(positionManager), pay0);
        }
        if (pay1 > 0) {
            MockERC20(lcc1.underlying()).mint(payer, pay1);
            vm.prank(payer);
            MockERC20(lcc1.underlying()).approve(address(positionManager), pay1);
        }
    }

    function _executeSettleAndAssertLockerUnderlyingGain(
        address locker,
        uint256 tokenId,
        uint256 positionIndex,
        uint256 expectedGain0,
        uint256 expectedGain1
    ) internal {
        uint256 lockerUnderlying0Before = MockERC20(lcc0.underlying()).balanceOf(locker);
        uint256 lockerUnderlying1Before = MockERC20(lcc1.underlying()).balanceOf(locker);

        MMA.PreparedAction[] memory drain = new MMA.PreparedAction[](1);
        drain[0] = MMA.prepareSettle(
            corePoolKey,
            tokenId,
            positionIndex,
            SafeCast.toInt128(expectedGain0),
            SafeCast.toInt128(expectedGain1),
            false
        );
        _executeWithUnlockLiquidity(drain, block.timestamp + 3600);

        assertEq(
            MockERC20(lcc0.underlying()).balanceOf(locker) - lockerUnderlying0Before,
            expectedGain0,
            "expired inactive remnant should remain withdrawable for token0"
        );
        assertEq(
            MockERC20(lcc1.underlying()).balanceOf(locker) - lockerUnderlying1Before,
            expectedGain1,
            "expired inactive remnant should remain withdrawable for token1"
        );
    }

    struct AfterSwapPhase1Params {
        uint256 tokenId;
        uint256 positionIndex;
        address recipient;
        Currency lcc0Currency;
        uint256 requiredSettlementAmount0;
        uint256 requiredSettlementAmount1;
        uint256 amountToDecrease;
    }

    struct PriceShapedScenario {
        uint256 tokenId;
        PositionId positionId;
        uint256 positionIndex;
        uint256 requiredSettlementAmount0;
        uint256 requiredSettlementAmount1;
    }

    struct OutOfRangeDecreaseParams {
        uint256 tokenId;
        uint256 positionIndex;
        PositionId positionId;
        uint256 requiredSettlementAmount0;
        uint256 requiredSettlementAmount1;
        uint256 amountToDecrease;
    }

    function _deployVTSOrchestrator(address _poolManager, address _oracleHelper, address _liquidityHub, address _owner)
        internal
        override
        returns (VTSOrchestrator)
    {
        return new VTSOrchestratorTestable(_poolManager, _oracleHelper, _liquidityHub, _owner);
    }

    function setUp() public {
        _setupMarket();
        _setUpMM();
        // Fresh direct commit requires `msgSender() == mmState.owner`; renew requires `msgSender() == mmState.advancer`.

        console.log("setUP() mmPositionManager", address(mmPositionManager));

        positionManager = MMPositionManager(payable(mmPositionManager));
        _wireTestQueueCustodian(liquiditySignal.mmState.advancer);
        _wireAllUtilityTestCustodians();
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
        {
            string[] memory tickers = new string[](2);
            tickers[0] = "BTC";
            tickers[1] = "USDT";
            uint256[] memory amounts = new uint256[](2);
            amounts[0] = 1e20;
            amounts[1] = 5e18;
            vm.mockCall(
                address(oracleHelper),
                abi.encodeWithSelector(IOracleHelper.getTotalValue.selector, tickers, amounts),
                abi.encode(1e18)
            );
        }

        // VTS / factory-bound routing: MM locker EOAs must be treated like the bound `MMPositionManager` endpoint.
        vm.mockCall(
            marketFactory,
            abi.encodeWithSelector(IMarketFactory.bounds.selector, liquiditySignal.mmState.advancer),
            abi.encode(true)
        );
        vm.mockCall(
            marketFactory,
            abi.encodeWithSelector(IMarketFactory.bounds.selector, renewSignal.mmState.advancer),
            abi.encode(true)
        );

        _permitMMPMForAdvancer(liquiditySignal.mmState.advancer);
        _permitMMPMForAdvancer(renewSignal.mmState.advancer);
    }

    function _permitMMPMForAdvancer(address adv) internal {
        address u0 = lcc0.underlying();
        address u1 = lcc1.underlying();
        if (u0 != address(0)) deal(u0, adv, 1e40);
        if (u1 != address(0)) deal(u1, adv, 1e40);
        vm.deal(adv, 1e22);
        vm.startPrank(adv);
        IERC20(address(lcc0)).approve(address(permit2), type(uint256).max);
        IERC20(address(lcc1)).approve(address(permit2), type(uint256).max);
        if (u0 != address(0)) IERC20(u0).approve(address(permit2), type(uint256).max);
        if (u1 != address(0)) IERC20(u1).approve(address(permit2), type(uint256).max);
        IAllowanceTransfer(permit2)
            .approve(address(lcc0), address(positionManager), type(uint160).max, type(uint48).max);
        IAllowanceTransfer(permit2)
            .approve(address(lcc1), address(positionManager), type(uint160).max, type(uint48).max);
        if (u0 != address(0)) {
            IAllowanceTransfer(permit2).approve(u0, address(positionManager), type(uint160).max, type(uint48).max);
        }
        if (u1 != address(0)) {
            IAllowanceTransfer(permit2).approve(u1, address(positionManager), type(uint160).max, type(uint48).max);
        }
        vm.stopPrank();
    }

    function _executeWithUnlockLiquidity(MMA.PreparedAction[] memory prepared, uint256 deadline) internal {
        vm.prank(liquiditySignal.mmState.advancer);
        MMA.executeWithUnlock(positionManager, prepared, deadline);
    }

    function _executeWithUnlockAs(address who, MMA.PreparedAction[] memory prepared, uint256 deadline) internal {
        vm.prank(who);
        MMA.executeWithUnlock(positionManager, prepared, deadline);
    }

    function _executeLiquidity(MMA.PreparedAction[] memory prepared) internal {
        vm.prank(liquiditySignal.mmState.advancer);
        MMA.execute(positionManager, prepared);
    }

    function _executeLiquidityValue(MMA.PreparedAction[] memory prepared, uint256 value) internal {
        vm.prank(liquiditySignal.mmState.advancer);
        MMA.execute(positionManager, prepared, value);
    }

    function _executeLiquidityAs(address who, MMA.PreparedAction[] memory prepared) internal {
        vm.prank(who);
        MMA.execute(positionManager, prepared);
    }

    function _executeLiquidityValueAs(address who, MMA.PreparedAction[] memory prepared, uint256 value) internal {
        vm.prank(who);
        MMA.execute(positionManager, prepared, value);
    }

    function _runRenewLiquidity(uint256 tokenId, bytes memory data) internal {
        vm.prank(liquiditySignal.mmState.advancer);
        MMA.renew(positionManager, tokenId, data);
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
        _executeWithUnlockLiquidity(prepared, block.timestamp + 3600);

        assertEq(
            positionManager.ownerOf(expectedTokenId),
            liquiditySignal.mmState.owner,
            "commit should mint NFT to mmState.owner"
        );
    }

    function test_commitSignal_forwardsFactoryAndSignalToVtsOrchestrator() public {
        bytes memory liquiditySignalBytes = abi.encode(liquiditySignal);
        uint256 expectedTokenId = positionManager.nextTokenId();

        vm.expectCall(
            address(vtsOrchestrator),
            abi.encodeWithSelector(
                bytes4(keccak256("commitSignal(address,bytes)")), IMarketFactory(marketFactory), liquiditySignalBytes
            )
        );

        MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](1);
        prepared[0] = MMA.prepareCommit(liquiditySignalBytes);
        _executeWithUnlockLiquidity(prepared, block.timestamp + 3600);

        assertEq(
            positionManager.ownerOf(expectedTokenId),
            liquiditySignal.mmState.owner,
            "commit should mint NFT to mmState.owner"
        );
    }

    /// @notice Direct fresh commit reverts when the batch locker is not `mmState.owner`.
    function test_commitSignal_reverts_whenLockerNotOwner() public {
        LiquiditySignal memory sig = liquiditySignal;
        sig.mmState.owner = makeAddr("differentOwner");
        bytes memory liquiditySignalBytes = abi.encode(sig);

        MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](1);
        prepared[0] = MMA.prepareCommit(liquiditySignalBytes);

        vm.expectRevert(Errors.InvalidSender.selector);
        vm.prank(liquiditySignal.mmState.advancer);
        MMA.executeWithUnlock(positionManager, prepared, block.timestamp + 3600);
    }

    /// @notice Relayed fresh commit requires `msgSender()` to match the NFT recipient (relay `sender`, or owner if zero).
    function test_commitSignal_revertsWhenRelayCommitmentLockerNotMsgSender() public {
        bytes memory liquiditySignalBytes = abi.encode(liquiditySignal);
        bytes memory relayParams =
            abi.encode(block.timestamp + 3600, uint256(0), bytes(""), makeAddr("signedOtherLocker"));
        MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](1);
        prepared[0] = MMA.PreparedAction({
            action: bytes1(uint8(MMActions.COMMIT_SIGNAL)), params: abi.encode(liquiditySignalBytes, relayParams)
        });

        vm.expectRevert(Errors.InvalidSender.selector);
        vm.prank(liquiditySignal.mmState.advancer);
        MMA.executeWithUnlock(positionManager, prepared, block.timestamp + 3600);
    }

    /// @notice Mutation-killer: proves DECOMMIT_SIGNAL emits `SignalDecommitted(tokenId, positionCount)` and burns the NFT.
    /// @dev We commit without minting any positions, so `positionCount == 0` deterministically.
    function test_decommitSignal_emitsSignalDecommitted() public {
        bytes memory liquiditySignalBytes = abi.encode(liquiditySignal);
        uint256 tokenId = positionManager.nextTokenId();

        // Commit only (no positions minted) then decommit.
        MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](1);
        prepared[0] = MMA.prepareCommit(liquiditySignalBytes);
        _executeWithUnlockLiquidity(prepared, block.timestamp + 3600);

        // Decommit the signal
        prepared = new MMA.PreparedAction[](1);
        prepared[0] = MMA.prepareDecommit(tokenId);

        // positionCount should be 0 for a fresh commit with no minted positions.
        vm.expectEmit(true, false, false, true);
        emit SignalDecommitted(tokenId, 0);
        _executeWithUnlockLiquidity(prepared, block.timestamp + 3600);

        // Token is burned; ownerOf should revert.
        vm.expectRevert();
        positionManager.ownerOf(tokenId);
    }

    function test_decommitSignal_revertsForNonOwnerNonApproved() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        bytes memory liquiditySignalBytes = abi.encode(liquiditySignal);
        uint256 tokenId = positionManager.nextTokenId();

        // COMMIT_SIGNAL mints to the locker (here: this test contract). Transfer custody to Alice for the access check.
        MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](1);
        prepared[0] = MMA.prepareCommit(liquiditySignalBytes);
        _executeWithUnlockLiquidity(prepared, block.timestamp + 3600);
        assertEq(positionManager.ownerOf(tokenId), liquiditySignal.mmState.owner, "commit mints NFT to mmState.owner");
        vm.prank(liquiditySignal.mmState.owner);
        positionManager.transferFrom(liquiditySignal.mmState.owner, alice, tokenId);
        assertEq(positionManager.ownerOf(tokenId), alice);

        // Bob is not approved/owner.
        prepared = new MMA.PreparedAction[](1);
        prepared[0] = MMA.prepareDecommit(tokenId);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotApproved.selector, bob));
        vm.prank(bob);
        MMA.executeWithUnlock(positionManager, prepared, block.timestamp + 3600);
    }

    /// @notice Proves RENEW_SIGNAL updates the commitment without creating a new NFT.
    /// @dev Verifies the expiry is correctly extended by the new signal.
    function test_canRenewSignal() public {
        // get the default market confiration so we can tweak it
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

        // renew the signal
        uint256 newTimestamp = 1000;
        vm.warp(newTimestamp);
        // Renewal requires sender == mmState.advancer, and owner must remain immutable.
        LiquiditySignal memory sameOwnerRenew = liquiditySignal;
        sameOwnerRenew.nonce += 1;
        sameOwnerRenew.mmState.expiryAt = block.timestamp + 5_000;
        _runRenewLiquidity(tokenId, abi.encode(sameOwnerRenew));

        (, uint256 expiresAtAfter,,,) = vtsOrchestrator.getCommit(tokenId);

        assertEq(expiresAtAfter, newTimestamp + 5_000, "renewal should set expiresAt from the renewed leaf expiryAt");
    }

    function test_renewSignal_forwardsFactoryTokenIdAndSignalToVtsOrchestrator() public {
        bytes memory liquiditySignalBytes = abi.encode(liquiditySignal);
        uint256 tokenId = positionManager.nextTokenId();

        MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](1);
        prepared[0] = MMA.prepareCommit(liquiditySignalBytes);
        _executeWithUnlockLiquidity(prepared, block.timestamp + 3600);

        LiquiditySignal memory sameOwnerRenew = liquiditySignal;
        sameOwnerRenew.nonce += 1;
        bytes memory renewBytes = abi.encode(sameOwnerRenew);

        vm.expectCall(
            address(vtsOrchestrator),
            abi.encodeWithSelector(
                bytes4(keccak256("renewSignal(address,uint256,bytes)")),
                IMarketFactory(marketFactory),
                tokenId,
                renewBytes
            )
        );
        _runRenewLiquidity(tokenId, renewBytes);
    }

    /// @notice Direct renew reverts when the batch locker is not `mmState.advancer` (VRL proof principal for renew).
    function test_renewSignal_reverts_whenLockerNotAdvancer() public {
        bytes memory liquiditySignalBytes = abi.encode(liquiditySignal);
        uint256 tokenId = positionManager.nextTokenId();

        MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](1);
        prepared[0] = MMA.prepareCommit(liquiditySignalBytes);
        _executeWithUnlockLiquidity(prepared, block.timestamp + 3600);

        LiquiditySignal memory sameOwnerRenew = liquiditySignal;
        sameOwnerRenew.nonce += 1;
        bytes memory renewBytes = abi.encode(sameOwnerRenew);

        vm.expectRevert(Errors.InvalidSender.selector);
        vm.prank(makeAddr("notAdvancer"));
        MMA.renew(positionManager, tokenId, renewBytes);
    }

    /// @notice ERC-721 custody does not substitute for advancer: NFT holder must still be the batch locker advancer for direct renew.
    function test_renewSignal_reverts_whenCommitmentNftOwnerNotAdvancer() public {
        bytes memory liquiditySignalBytes = abi.encode(liquiditySignal);
        uint256 tokenId = positionManager.nextTokenId();

        MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](1);
        prepared[0] = MMA.prepareCommit(liquiditySignalBytes);
        _executeWithUnlockLiquidity(prepared, block.timestamp + 3600);

        address alice = makeAddr("aliceCustody");
        vm.prank(liquiditySignal.mmState.owner);
        positionManager.transferFrom(liquiditySignal.mmState.owner, alice, tokenId);

        LiquiditySignal memory sameOwnerRenew = liquiditySignal;
        sameOwnerRenew.nonce += 1;
        bytes memory renewBytes = abi.encode(sameOwnerRenew);

        vm.expectRevert(Errors.InvalidSender.selector);
        vm.prank(alice);
        MMA.renew(positionManager, tokenId, renewBytes);
    }

    /// @notice Relayed renew with legacy `relaySender == 0` requires the batch locker to be `mmState.advancer`.
    function test_renewSignal_relayed_reverts_whenLockerNotAdvancer_legacyZeroSender() public {
        bytes memory liquiditySignalBytes = abi.encode(liquiditySignal);
        uint256 tokenId = positionManager.nextTokenId();

        MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](1);
        prepared[0] = MMA.prepareCommit(liquiditySignalBytes);
        _executeWithUnlockLiquidity(prepared, block.timestamp + 3600);

        LiquiditySignal memory sameOwnerRenew = liquiditySignal;
        sameOwnerRenew.nonce += 1;
        bytes memory relayParams = abi.encode(block.timestamp + 3600, uint256(0), bytes(""), address(0));
        prepared = new MMA.PreparedAction[](1);
        prepared[0] = MMA.PreparedAction({
            action: bytes1(uint8(MMActions.RENEW_SIGNAL)),
            params: abi.encode(tokenId, abi.encode(sameOwnerRenew), relayParams)
        });

        vm.expectRevert(Errors.InvalidSender.selector);
        vm.prank(makeAddr("notAdvancer"));
        MMA.executeWithUnlock(positionManager, prepared, block.timestamp + 3600);
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
        uint32 verifierIndex = 0;

        // mock the call made to the settlement observer to verify the settlement proof
        vm.mockCall(
            address(settlementObserver),
            abi.encodeWithSelector(settlementObserver.verifySettlementProof.selector),
            abi.encode(true)
        );

        PositionId positionId = vtsOrchestrator.getPositionId(tokenId, positionIndex);

        // Open a live settlement lane, then persist that checkpoint state before requesting a grace extension.
        swapRouter.swap(
            proxyPoolKey,
            SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: ZERO_FOR_ONE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
        positionManager.checkpoint(tokenId, positionIndex, false);

        // get the checkpoint of the position
        RFSCheckpoint memory checkpointBefore = vtsOrchestrator.positionToCheckpoint(positionId);

        // extend the grace period of the open settlement lane (batch must run as the MM locker)
        MMA.PreparedAction[] memory extendPrepared = new MMA.PreparedAction[](1);
        extendPrepared[0] = MMA.prepareExtendGracePeriod(
            corePoolKey, tokenId, positionIndex, settlementTokenIndex0, verifierIndex, settlementProof
        );
        _executeWithUnlockLiquidity(extendPrepared, block.timestamp + 3600);

        // validate the extension
        RFSCheckpoint memory checkpointAfter = vtsOrchestrator.positionToCheckpoint(positionId);
        vtsOrchestrator.positionToCheckpoint(positionId);

        console.log("gracePeriodExtension0Before", checkpointBefore.gracePeriodExtension0);
        console.log("gracePeriodExtension1Before", checkpointBefore.gracePeriodExtension1);
        console.log("gracePeriodExtension0After", checkpointAfter.gracePeriodExtension0);
        console.log("gracePeriodExtension1After", checkpointAfter.gracePeriodExtension1);
        assertGt(checkpointAfter.gracePeriodExtension0, checkpointBefore.gracePeriodExtension0);
    }

    function test_extendGracePeriod_revertsForNonOwnerNonApproved() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        // Create the commitment under the test contract (which is fully funded/approved in setUp),
        // then transfer the NFT to Alice so Bob is a clean non-owner / non-approved caller.
        (uint256 tokenId,,,) = _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)}),
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );
        vm.prank(liquiditySignal.mmState.advancer);
        positionManager.transferFrom(liquiditySignal.mmState.advancer, alice, tokenId);

        // Make proof verification succeed (but it should not be reached for Bob).
        vm.mockCall(
            address(settlementObserver),
            abi.encodeWithSelector(settlementObserver.verifySettlementProof.selector),
            abi.encode(true)
        );

        MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](1);
        prepared[0] = MMA.prepareExtendGracePeriod(corePoolKey, tokenId, 0, 0, 0, abi.encode(1));

        vm.expectRevert(abi.encodeWithSelector(Errors.NotApproved.selector, bob));
        vm.prank(bob);
        MMA.executeWithUnlock(positionManager, prepared, block.timestamp + 3600);
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

        vm.mockCall(marketFactory, abi.encodeWithSelector(IMarketFactory.bounds.selector, user), abi.encode(false));

        MockERC20 underlyingAsset = MockERC20(lcc0.underlying());
        uint256 amount = 500;

        // Locker/recipient starts with pre-existing underlying so delta measurement is observable.
        underlyingAsset.mint(user, 123);
        uint256 beforeRecipient = underlyingAsset.balanceOf(user);

        underlyingAsset.mint(user, amount);
        vm.startPrank(user);
        underlyingAsset.approve(address(liquidityHub), amount);
        ILiquidityHub(liquidityHub).wrap(address(lcc0), amount);
        lcc0.approve(address(positionManager), type(uint256).max);
        vm.stopPrank();

        vm.prank(user);
        MMA.unwrapLcc(positionManager, address(lcc0), amount, user, true);

        assertEq(
            underlyingAsset.balanceOf(user) - beforeRecipient,
            amount,
            "unwrap should increase recipient underlying by exactly amount"
        );
    }

    /// @dev UNWRAP_LCC payout recipient must be the locker or MMPM only.
    function test_unwrapLcc_payerIsUser_thirdPartyRecipient_reverts() public {
        address user = makeAddr("user");
        address eve = makeAddr("eve");

        vm.mockCall(marketFactory, abi.encodeWithSelector(IMarketFactory.bounds.selector, user), abi.encode(false));

        MockERC20 underlyingAsset = MockERC20(lcc0.underlying());
        uint256 amount = 100;

        underlyingAsset.mint(user, amount);
        vm.startPrank(user);
        underlyingAsset.approve(address(liquidityHub), amount);
        ILiquidityHub(liquidityHub).wrap(address(lcc0), amount);
        lcc0.approve(address(positionManager), type(uint256).max);
        vm.stopPrank();

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotApproved.selector, eve));
        MMA.unwrapLcc(positionManager, address(lcc0), amount, eve, true);
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

        _executeLiquidityAs(user, prepared);

        // Correct behaviour: no unwrap occurred, so no sync should happen, so TAKE should move nothing.
        assertEq(underlying.balanceOf(user), userBefore, "unwrapped==0 should not create takeable underlying credit");
        assertEq(
            underlying.balanceOf(address(positionManager)),
            pmBefore,
            "unwrapped==0 should not transfer underlying out of MMPM via TAKE"
        );
    }

    /// @notice Mutation-killer: if `unwrapped > 0` and recipient is `address(this)`, MMPM must sync credit.
    /// @dev Validates that a follow-up TAKE transfers the unwrapped amount to the caller.
    function test_unwrapLcc_payerIsUser_toThis_unwrappedPositive_syncsUnderlying_andIsTakeable() public {
        address user = makeAddr("user");

        vm.mockCall(marketFactory, abi.encodeWithSelector(IMarketFactory.bounds.selector, user), abi.encode(false));

        MockERC20 underlying = MockERC20(lcc0.underlying());
        Currency underlyingCurrency = Currency.wrap(address(underlying));
        uint256 amount = 500;

        underlying.mint(user, amount);
        vm.startPrank(user);
        underlying.approve(address(liquidityHub), amount);
        ILiquidityHub(liquidityHub).wrap(address(lcc0), amount);
        lcc0.approve(address(positionManager), type(uint256).max);
        vm.stopPrank();

        uint256 userBefore = underlying.balanceOf(user);

        MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](2);
        prepared[0] = MMA.prepareUnwrapLcc(address(lcc0), amount, ActionConstants.ADDRESS_THIS, true);
        prepared[1] = MMA.prepareTake(underlyingCurrency, user, 0);

        _executeLiquidityAs(user, prepared);

        assertEq(
            underlying.balanceOf(user), userBefore + amount, "unwrapped > 0 should sync underlying credit for TAKE"
        );
    }

    /// @notice Native-backed unwrap-to-self should only credit the exact ETH received from Hub.
    /// @dev Regression guard: ambient ETH on MMPM must never be auto-credited during LCC unwrap sync.
    function test_unwrapLcc_nativeToThis_creditsExactHubPayout_only() public {
        address recipient = makeAddr("recipient");
        uint256 amount = 500;
        uint256 ambient = 2 ether;
        MockERC20 underlying = MockERC20(lcc0.underlying());
        Currency lccCurrency = Currency.wrap(address(lcc0));

        // Put LCC on MMPM, then sync locker credit from MMPM balance.
        underlying.mint(address(this), amount);
        underlying.approve(address(liquidityHub), amount);
        ILiquidityHub(liquidityHub).wrap(address(lcc0), amount);
        lcc0.transfer(address(positionManager), amount);

        // Replace Hub runtime with a deterministic native payout mock.
        MockNativeUnwrapHubPayer hubPayer = new MockNativeUnwrapHubPayer();
        vm.etch(liquidityHub, address(hubPayer).code);
        vm.deal(liquidityHub, 5 ether);

        // Force this unwrap path to treat lcc0 as native-backed.
        vm.mockCall(address(lcc0), abi.encodeWithSelector(ILCC.underlying.selector), abi.encode(address(0)));

        // Seed ambient ETH that must remain untouched by native unwrap crediting.
        vm.deal(address(positionManager), ambient);
        uint256 recipientBefore = recipient.balance;

        MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](3);
        prepared[0] = MMA.prepareSync(lccCurrency);
        prepared[1] = MMA.prepareUnwrapLcc(address(lcc0), amount, ActionConstants.ADDRESS_THIS, false);
        prepared[2] = MMA.prepareTake(CurrencyLibrary.ADDRESS_ZERO, recipient, 0);
        _executeLiquidity(prepared);

        assertEq(recipient.balance - recipientBefore, 1 ether, "should credit and take only Hub native payout");
        assertEq(address(positionManager).balance, ambient, "ambient ETH must not be auto-credited");
    }

    /// @notice Native-backed `UNWRAP_LCC` pays ETH to MMPM first; locker receives ETH only via `TAKE`, not during Hub `unwrap`.
    /// @dev Regression: payable locker `receive()` must not run during custodian-forwarded Hub `unwrap` (queue snapshot / custody forward window).
    function test_unwrapLcc_nativeBacked_payableLocker_receivesEthOnlyOnTake() public {
        PayableLockerUnwrapHelper locker = new PayableLockerUnwrapHelper();
        _wireTestQueueCustodian(address(locker));
        uint256 amount = 500;
        MockERC20 underlying = MockERC20(lcc0.underlying());
        Currency lccCurrency = Currency.wrap(address(lcc0));

        underlying.mint(address(this), amount);
        underlying.approve(address(liquidityHub), amount);
        ILiquidityHub(liquidityHub).wrap(address(lcc0), amount);
        lcc0.transfer(address(positionManager), amount);

        MockNativeUnwrapHubPayer hubPayer = new MockNativeUnwrapHubPayer();
        vm.etch(liquidityHub, address(hubPayer).code);
        vm.deal(liquidityHub, 5 ether);

        vm.mockCall(address(lcc0), abi.encodeWithSelector(ILCC.underlying.selector), abi.encode(address(0)));

        MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](3);
        prepared[0] = MMA.prepareSync(lccCurrency);
        prepared[1] = MMA.prepareUnwrapLcc(address(lcc0), amount, address(locker), false);
        prepared[2] = MMA.prepareTake(CurrencyLibrary.ADDRESS_ZERO, address(locker), 0);
        (bytes memory actions, bytes[] memory params) = MMA.concatPrepared(prepared);

        locker.execute(positionManager, actions, params);

        assertEq(locker.ethReceiveCalls(), 1, "ETH must be delivered in one TAKE, not during Hub unwrap");
        assertEq(address(locker).balance, 1 ether);
    }

    /// @notice If ETH reached the locker during Hub unwrap, `receive()` could run `LCC.transfer(hub, …)` while MMPM still
    ///         held queue/custody invariants open. Native unwrap must pay MMPM first so this only runs on `TAKE`.
    function test_unwrapLcc_nativeBacked_maliciousLocker_receiveTransfersLccToHub_onlyAfterTake() public {
        PayableLockerMaliciousLccTransfer locker = new PayableLockerMaliciousLccTransfer(address(lcc0), liquidityHub);
        _wireTestQueueCustodian(address(locker));
        uint256 amount = 500;
        MockERC20 underlying = MockERC20(lcc0.underlying());
        Currency lccCurrency = Currency.wrap(address(lcc0));

        // Dust LCC on the locker so `receive()` performs a real protocol-bound transfer (not a no-op).
        underlying.mint(address(this), amount + 1);
        underlying.approve(address(liquidityHub), amount + 1);
        ILiquidityHub(liquidityHub).wrap(address(lcc0), amount);
        lcc0.transfer(liquidityHub, 1);
        vm.prank(liquidityHub);
        lcc0.transfer(address(locker), 1);

        underlying.approve(address(liquidityHub), amount);
        ILiquidityHub(liquidityHub).wrap(address(lcc0), amount);
        lcc0.transfer(address(positionManager), amount);

        MockNativeUnwrapHubPayer hubPayer = new MockNativeUnwrapHubPayer();
        vm.etch(liquidityHub, address(hubPayer).code);
        vm.deal(liquidityHub, 5 ether);

        vm.mockCall(address(lcc0), abi.encodeWithSelector(ILCC.underlying.selector), abi.encode(address(0)));

        MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](3);
        prepared[0] = MMA.prepareSync(lccCurrency);
        prepared[1] = MMA.prepareUnwrapLcc(address(lcc0), amount, address(locker), false);
        prepared[2] = MMA.prepareTake(CurrencyLibrary.ADDRESS_ZERO, address(locker), 0);
        (bytes memory actions, bytes[] memory params) = MMA.concatPrepared(prepared);
        locker.execute(positionManager, actions, params);

        assertEq(locker.ethReceiveCalls(), 1, "ETH must not hit locker until TAKE");
        assertEq(address(locker).balance, 1 ether);
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

        // Renew then checkpoint with commitment backing check.
        // Note: checkpoint-with-commitment reads stored signal state; the signal bytes are no longer required.
        bytes memory unbackedLiquiditySignal = abi.encode(renewSignal);
        vm.mockCall(
            address(signalManager),
            abi.encodeWithSelector(
                bytes4(keccak256("verifyLiquiditySignal(address,bytes,bool)")), advancer, unbackedLiquiditySignal, true
            ),
            abi.encode(true, 10)
        );
        _runRenewLiquidity(tokenId, unbackedLiquiditySignal);

        // get liquidity in position 0
        (Position memory positionBeforeCheckpoint,) = vtsOrchestrator.getPosition(tokenId, positionIndex);
        console.log("positionLiquidityBeforeCheckpoint", uint256(positionBeforeCheckpoint.liquidity));

        // need to inflate the value of issuedusd to be greater than the signalusd by 20%
        vm.mockCall(
            address(oracleHelper),
            abi.encodeWithSelector(IOracleHelper.getPricesForLccPair.selector),
            abi.encode(50000000000, 50000000000)
        );

        // Checkpoint with commitment backing check
        vm.prank(advancer);
        positionManager.checkpoint(tokenId, positionIndex, true);

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

    /// @notice Mutation-killer: CHECKPOINT action must route to VTSOrchestrator.checkpoint (not revert UnsupportedAction).
    function test_actionCheckpoint_withoutCommitment_callsVtsOrchestrator() public {
        // Set up a committed position to ensure tokenId/positionIndex exist.
        (uint256 tokenId,,,) = _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)}),
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](1);
        prepared[0] = MMA.prepareCheckpoint(tokenId, 0, bytes(""));

        // For modifyLiquiditiesWithoutUnlock, the locker is the direct caller (this test contract).
        vm.expectCall(
            address(vtsOrchestrator), abi.encodeWithSignature("checkpoint(uint256,uint256,bool)", tokenId, 0, false)
        );
        _executeLiquidity(prepared);
    }

    /// @notice Mutation-killer: unsupported commitment-range actions must revert UnsupportedAction (not try to decode EXTEND_GRACE_PERIOD params).
    function test_modifyLiquiditiesWithoutUnlock_unsupportedCommitmentAction_revertsUnsupportedAction() public {
        uint256 unknownCommitmentAction = 0x25; // in [0x20, 0x40) but not implemented
        bytes memory actions = abi.encodePacked(uint8(unknownCommitmentAction));
        bytes[] memory params = new bytes[](1);
        params[0] = hex"";

        vm.expectRevert(abi.encodeWithSelector(Errors.UnsupportedAction.selector, unknownCommitmentAction));
        positionManager.modifyLiquiditiesWithoutUnlock(actions, params);
    }

    /// @dev Utility namespace gap between `SYNC` (0x45) and the next reserved range.
    function test_modifyLiquiditiesWithoutUnlock_utilityGap0x46_revertsUnsupportedAction() public {
        uint256 unknownUtilityAction = 0x46;
        bytes memory actions = abi.encodePacked(uint8(unknownUtilityAction));
        bytes[] memory params = new bytes[](1);
        params[0] = hex"";

        vm.expectRevert(abi.encodeWithSelector(Errors.UnsupportedAction.selector, unknownUtilityAction));
        positionManager.modifyLiquiditiesWithoutUnlock(actions, params);
    }

    function test_constructor_reverts_whenQueueCustodianFactoryZero() public {
        address cv = IMarketFactory(marketFactory).canonicalVault();
        address desc = address(new MockCommitmentDescriptor("ipfs://x/"));
        address actionsImplAddr = positionManager.actionsImpl();
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
        new MMPositionManager(
            MMPositionManager.MMPositionManagerInit({
                poolManager: manager,
                marketFactory: address(marketFactory),
                vtsOrchestrator: address(vtsOrchestrator),
                canonicalCustody: cv,
                descriptor: desc,
                weth9: weth9,
                permit2: permit2,
                actionsImpl: actionsImplAddr,
                queueCustodianFactory: address(0)
            })
        );
    }

    function test_tokenURI_revertsWhenCommitmentDescriptorNotSet() public {
        // Reuse the real actions impl from the already-deployed PositionManager so the constructor succeeds.
        // This test is about `commitmentDescriptor`, not delegation.
        MMPositionManager broken = new MMPositionManager(
            MMPositionManager.MMPositionManagerInit({
                poolManager: manager,
                marketFactory: address(marketFactory),
                vtsOrchestrator: address(vtsOrchestrator),
                canonicalCustody: IMarketFactory(marketFactory).canonicalVault(),
                descriptor: address(0),
                weth9: weth9,
                permit2: permit2,
                actionsImpl: positionManager.actionsImpl(),
                queueCustodianFactory: queueCustodianFactory
            })
        );
        vm.expectRevert(Errors.CommitmentDescriptorNotSet.selector);
        broken.tokenURI(1);
    }

    function test_constructor_setsCommitmentDescriptor() public {
        MockCommitmentDescriptor desc = new MockCommitmentDescriptor("ipfs://mock/");

        MMPositionManager fresh = new MMPositionManager(
            MMPositionManager.MMPositionManagerInit({
                poolManager: manager,
                marketFactory: address(marketFactory),
                vtsOrchestrator: address(vtsOrchestrator),
                canonicalCustody: IMarketFactory(marketFactory).canonicalVault(),
                descriptor: address(desc),
                weth9: weth9,
                permit2: permit2,
                actionsImpl: positionManager.actionsImpl(),
                queueCustodianFactory: queueCustodianFactory
            })
        );

        assertEq(fresh.commitmentDescriptor(), address(desc), "constructor should set commitmentDescriptor");
    }

    function test_tokenURI_returnsDescriptorValue_whenDescriptorSet() public {
        MockCommitmentDescriptor desc = new MockCommitmentDescriptor("ipfs://mock/");

        MMPositionManager fresh = new MMPositionManager(
            MMPositionManager.MMPositionManagerInit({
                poolManager: manager,
                marketFactory: address(marketFactory),
                vtsOrchestrator: address(vtsOrchestrator),
                canonicalCustody: IMarketFactory(marketFactory).canonicalVault(),
                descriptor: address(desc),
                weth9: weth9,
                permit2: permit2,
                actionsImpl: positionManager.actionsImpl(),
                queueCustodianFactory: queueCustodianFactory
            })
        );

        assertEq(fresh.tokenURI(123), "ipfs://mock/123", "tokenURI should delegate to descriptor when set");
    }

    /// @notice Mutation-killer: when SYNC creates delta credit and we do not TAKE it, _afterBatch must revert CurrencyNotSettled.
    /// @dev This kills the mutant that deletes `_afterBatch()` in modifyLiquiditiesWithoutUnlock.
    function test_modifyLiquiditiesWithoutUnlock_revertsIfDeltasRemain_afterSync() public {
        // Pre-fund MMPM with some ERC20 balance so SYNC will establish delta credit.
        MockERC20 underlying = MockERC20(lcc0.underlying());
        underlying.mint(address(positionManager), 123);

        MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](1);
        prepared[0] = MMA.prepareSync(Currency.wrap(address(underlying)));

        vm.expectRevert(Errors.CurrencyNotSettled.selector);
        _executeLiquidity(prepared);
    }

    function test_modifyLiquiditiesWithoutUnlock_revertsWhenSyncNativeRequested() public {
        MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](1);
        prepared[0] = MMA.prepareSync(CurrencyLibrary.ADDRESS_ZERO);

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
        _executeLiquidity(prepared);
    }

    /// @notice Unauthorised EOAs cannot fabricate locker credit via `sync` (marketFactory-bound caller check).
    function test_vtsOrchestrator_sync_revertsWhenCallerNotProtocolBound() public {
        address attacker = makeAddr("syncAttacker");
        MockERC20 underlying = MockERC20(lcc0.underlying());
        underlying.mint(address(positionManager), 1e18);

        vm.prank(attacker);
        vm.expectRevert(Errors.InvalidSender.selector);
        vtsOrchestrator.sync(
            IMarketFactory(marketFactory), Currency.wrap(address(underlying)), address(positionManager), attacker
        );
    }

    /// @notice Native TAKE with recipient = MMPM would net delta without transferring ETH, stranding funds (no native SYNC).
    function test_take_native_toMmpm_reverts() public {
        MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](1);
        prepared[0] = MMA.prepareTake(CurrencyLibrary.ADDRESS_ZERO, address(positionManager), 0);

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(positionManager)));
        _executeLiquidityValue(prepared, 1 ether);
    }

    /// @notice Native TAKE to `ProxyHook` must revert: the hook rejects plain ETH (`receive`) so funds cannot strand unaccounted.
    /// @dev `Currency.transfer` wraps a failed native send as `NativeTransferFailed` (bubbled); we only assert revert, not the wrapper.
    function test_take_native_toProxyHook_reverts() public {
        MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](1);
        prepared[0] = MMA.prepareTake(CurrencyLibrary.ADDRESS_ZERO, address(proxyHook), 0);

        vm.expectRevert();
        _executeLiquidityValue(prepared, 1 ether);
    }

    function test_wrapNative_ignoresAmbientEthBalance_andCreditsOnlyMsgValue() public {
        // Seed ambient ETH that should not be auto-credited to the locker.
        vm.deal(address(positionManager), 5 ether);

        MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](2);
        prepared[0] = MMA.prepareWrapNative(1 ether);
        prepared[1] = MMA.prepareTake(Currency.wrap(address(weth9)), address(this), 0);

        uint256 wethBefore = weth9.balanceOf(address(this));
        _executeLiquidityValue(prepared, 1 ether);
        assertEq(weth9.balanceOf(address(this)) - wethBefore, 1 ether, "only msg.value should be credited");
    }

    /// @notice Regression: one outer ETH on `multicall` must not be re-credited on each inner `delegatecall` batch.
    /// @dev First leg wraps + `TAKE`s WETH (consumes the single native credit). Second identical leg would mint another
    ///      1 WETH if each batch re-applied the same outer `msg.value` to delta.
    function test_multicall_outerEth_notDoubleCreditedAcrossInnerBatches() public {
        address recipient = makeAddr("mcRecipient");

        MMA.PreparedAction[] memory wrapLeg = new MMA.PreparedAction[](2);
        wrapLeg[0] = MMA.prepareWrapNative(0);
        wrapLeg[1] = MMA.prepareTake(Currency.wrap(address(weth9)), recipient, 0);
        (bytes memory wrapActions, bytes[] memory wrapParams) = MMA.concatPrepared(wrapLeg);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(MMPositionManager.modifyLiquiditiesWithoutUnlock, (wrapActions, wrapParams));
        calls[1] = abi.encodeCall(MMPositionManager.modifyLiquiditiesWithoutUnlock, (wrapActions, wrapParams));

        vm.prank(liquiditySignal.mmState.advancer);
        positionManager.multicall{value: 1 ether}(calls);

        assertEq(weth9.balanceOf(recipient), 1 ether, "outer msg.value must credit once across multicall");
    }

    /// @notice Integration: two top-level MMPM calls in one tx — empty first batch, then funded `WRAP_NATIVE(0)` + WETH `TAKE`.
    /// @dev Regression for native balance-delta crediting (smart-account / router composition); locker is the router contract.
    function test_twoTopLevelCalls_sameTx_zeroThenFunded_recipientGetsOnlySecondAttachmentAsWeth() public {
        address recipient = makeAddr("twoExtRecipient");
        MMPMTwoExternalCallsRouter router = new MMPMTwoExternalCallsRouter();
        vm.deal(address(router), 1 ether);

        bytes memory emptyActions;
        bytes[] memory emptyParams = new bytes[](0);

        MMA.PreparedAction[] memory wrapLeg = new MMA.PreparedAction[](2);
        wrapLeg[0] = MMA.prepareWrapNative(0);
        wrapLeg[1] = MMA.prepareTake(Currency.wrap(address(weth9)), recipient, 0);
        (bytes memory wrapActions, bytes[] memory wrapParams) = MMA.concatPrepared(wrapLeg);

        MMPMTwoExternalCallsRouter(payable(address(router)))
        .zeroThenFundedWrapTake{value: 1 ether}(positionManager, emptyActions, emptyParams, wrapActions, wrapParams);

        assertEq(weth9.balanceOf(recipient), 1 ether, "only second-call ETH should wrap to WETH");
    }

    /// @notice Integration: two funded top-level batches in one tx — each 1 ETH should wrap exactly once per recipient.
    function test_twoTopLevelCalls_sameTx_twoFunded_eachRecipientGetsOneWeth() public {
        address recipientA = makeAddr("twoFundedA");
        address recipientB = makeAddr("twoFundedB");
        MMPMTwoExternalCallsRouter router = new MMPMTwoExternalCallsRouter();
        vm.deal(address(router), 2 ether);

        MMA.PreparedAction[] memory legA = new MMA.PreparedAction[](2);
        legA[0] = MMA.prepareWrapNative(0);
        legA[1] = MMA.prepareTake(Currency.wrap(address(weth9)), recipientA, 0);
        (bytes memory wrapActions, bytes[] memory paramsA) = MMA.concatPrepared(legA);

        MMA.PreparedAction[] memory legB = new MMA.PreparedAction[](2);
        legB[0] = MMA.prepareWrapNative(0);
        legB[1] = MMA.prepareTake(Currency.wrap(address(weth9)), recipientB, 0);
        (, bytes[] memory paramsB) = MMA.concatPrepared(legB);

        MMPMTwoExternalCallsRouter(payable(address(router)))
        .twoFundedWrapTake{value: 2 ether}(positionManager, wrapActions, paramsA, paramsB);

        assertEq(weth9.balanceOf(recipientA), 1 ether, "first batch should wrap only its 1 ETH");
        assertEq(weth9.balanceOf(recipientB), 1 ether, "second batch should wrap only its 1 ETH");
    }

    function test_unwrapNative_ignoresAmbientEthBalance_andCreditsOnlyUnwrappedAmount() public {
        address user = makeAddr("user");
        vm.deal(address(positionManager), 3 ether); // ambient ETH should not be auto-credited

        vm.deal(user, 2 ether);
        vm.prank(user);
        weth9.deposit{value: 1 ether}();
        vm.prank(user);
        weth9.approve(address(positionManager), type(uint256).max);

        MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](2);
        prepared[0] = MMA.prepareUnwrapNative(1 ether, true);
        prepared[1] = MMA.prepareTake(CurrencyLibrary.ADDRESS_ZERO, user, 1 ether);

        uint256 ethBefore = user.balance;
        _executeLiquidityAs(user, prepared);
        assertEq(user.balance - ethBefore, 1 ether, "only unwrapped amount should be credited");
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
        _executeLiquidityValue(prepared, 1 ether);

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
        _executeLiquidityValue(prepared, 2 ether);

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

        _executeLiquidityAs(user, prepared);

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
        _executeLiquidityValue(prepared, 1 ether);
        assertEq(user.balance, ethBefore + 1 ether);
    }

    function test_unwrapNative_fromDeltas_amountLtAvailable_unwrapsExactAmount_andLeavesRemainder() public {
        address ethRecipient = makeAddr("ethRecipient");
        address wethRecipient = makeAddr("wethRecipient");

        // Create WETH delta credit, then unwrap only part of it.
        MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](4);
        prepared[0] = MMA.prepareWrapNative(1 ether);
        prepared[1] = MMA.prepareUnwrapNative(0.4 ether, false); // unwrap partial from delta
        prepared[2] = MMA.prepareTake(CurrencyLibrary.ADDRESS_ZERO, ethRecipient, 0); // take unwrapped ETH
        prepared[3] = MMA.prepareTake(Currency.wrap(address(weth9)), wethRecipient, 0); // take remaining WETH

        uint256 ethBefore = ethRecipient.balance;
        _executeLiquidityValue(prepared, 1 ether);

        assertEq(ethRecipient.balance - ethBefore, 0.4 ether, "should unwrap only requested ETH");
        assertEq(weth9.balanceOf(wethRecipient), 0.6 ether, "should retain remaining WETH credit");
    }

    function test_unwrapNative_fromDeltas_amountGtAvailableCredit_revertsInsufficientBalance() public {
        MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](2);
        prepared[0] = MMA.prepareWrapNative(0.5 ether);
        prepared[1] = MMA.prepareUnwrapNative(1 ether, false);

        vm.expectRevert(abi.encodeWithSelector(Errors.InsufficientBalance.selector, 0.5 ether, 1 ether));
        _executeLiquidityValue(prepared, 0.5 ether);
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

    /// @notice Mutation-killer: requested == 0 must unwrap the payer's full LCC balance (not clamp to 0).
    function test_unwrapLcc_payerIsUser_requestedZero_unwrapsAllBalance() public {
        address user = makeAddr("user");

        vm.mockCall(marketFactory, abi.encodeWithSelector(IMarketFactory.bounds.selector, user), abi.encode(false));

        MockERC20 underlyingAsset = MockERC20(lcc0.underlying());
        uint256 balance = 777;
        underlyingAsset.mint(user, balance);

        vm.startPrank(user);
        underlyingAsset.approve(address(liquidityHub), balance);
        ILiquidityHub(liquidityHub).wrap(address(lcc0), balance);
        lcc0.approve(address(positionManager), type(uint256).max);
        vm.stopPrank();

        uint256 underlyingBefore = underlyingAsset.balanceOf(user);

        vm.prank(user);
        MMA.unwrapLcc(positionManager, address(lcc0), 0, user, true);

        assertEq(lcc0.balanceOf(user), 0, "requested==0 should unwrap full payer LCC balance");
        assertEq(
            underlyingAsset.balanceOf(user), underlyingBefore + balance, "underlying should increase by full balance"
        );
    }

    /// @notice Mutation-killer: when payerIsUser=false and there is no LCC delta credit, unwrap must not sync existing underlying balance.
    /// @dev Targets deltas-unwrap mutants that accidentally sync credit even when `unwrapped == 0`.
    function test_unwrapLcc_fromDeltas_toThis_whenTakeReturnsZero_doesNotSyncUnderlyingCredit() public {
        address user = makeAddr("user");
        MockERC20 underlying = MockERC20(lcc0.underlying());
        Currency underlyingCurrency = Currency.wrap(address(underlying));

        // Seed MMPM with underlying, but do not sync it as credit.
        uint256 seeded = 555;
        underlying.mint(address(positionManager), seeded);

        MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](2);
        // No SYNC for LCC currency => vtsOrchestrator.take(lccCurrency, ...) should return 0.
        prepared[0] = MMA.prepareUnwrapLcc(address(lcc0), 1, ActionConstants.ADDRESS_THIS, false);
        // If the unwrap path incorrectly syncs underlying, this TAKE would leak the seeded underlying.
        prepared[1] = MMA.prepareTake(underlyingCurrency, user, 0);

        uint256 userBefore = underlying.balanceOf(user);
        uint256 pmBefore = underlying.balanceOf(address(positionManager));

        _executeLiquidityAs(user, prepared);

        assertEq(underlying.balanceOf(user), userBefore, "no unwrap => no underlying credit should be created");
        assertEq(
            underlying.balanceOf(address(positionManager)),
            pmBefore,
            "no unwrap => MMPM underlying should remain unchanged"
        );
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

        _executeLiquidity(prepared);

        assertEq(underlying.balanceOf(recipient), 500);
    }

    /// @notice When directSupply is zero and the caller holds only wrapped LCC, unwrap cannot queue: external queues are
    ///         market-derived claims only; wrapped shortfall reverts (`InvalidAmount`).
    /// @dev MMPM must remain `BOUND_ENDPOINT` so bucket splits are preserved for market-derived unwrap paths.
    function test_unwrapLcc_fromDeltas_mmpmBoundEndpoint_wrappedOnly_zeroDirectSupply_reverts() public {
        address user = makeAddr("user");
        address locker = makeAddr("locker");

        address lccAddr = address(lcc0);
        MockERC20 underlying = MockERC20(lcc0.underlying());
        uint256 amount = 500;

        vm.prank(marketFactory);
        ILiquidityHub(liquidityHub).setBoundLevel(address(positionManager), Bounds.BOUND_NONE);
        vm.prank(marketFactory);
        ILiquidityHub(liquidityHub).setBoundLevel(address(positionManager), Bounds.BOUND_ENDPOINT);

        underlying.mint(user, amount);
        vm.startPrank(user);
        underlying.approve(address(liquidityHub), amount);
        ILiquidityHub(liquidityHub).wrap(lccAddr, amount);
        lcc0.transfer(address(positionManager), amount);
        vm.stopPrank();

        _setDirectSupply(lccAddr, 0);

        vm.mockCallRevert(
            marketFactory,
            abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector),
            abi.encodeWithSignature("Error(string)", "useMarketLiquidity called")
        );

        MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](2);
        prepared[0] = MMA.prepareSync(Currency.wrap(lccAddr));
        prepared[1] = MMA.prepareUnwrapLcc(lccAddr, amount, locker, false);

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector, amount, uint256(0)));
        _executeLiquidityAs(locker, prepared);

        assertEq(ILiquidityHub(liquidityHub).settleQueue(lccAddr, positionManager.custodianFor(locker)), 0);
        assertEq(IMMQueueCustodian(positionManager.custodianFor(locker)).queued(0, lccAddr, locker), 0);
    }

    /// @dev HUB-02 / HUB-02A (custodian queue headroom): with queue encumbering the locker, a second identical unwrap must not increase the queue
    ///      (market-derived shortfall path; wrapped-only cannot queue).
    function test_unwrapLcc_fromDeltas_mmpmBoundEndpoint_secondIdenticalUnwrap_doesNotIncreaseQueue() public {
        address locker = makeAddr("lockerQueueEncumber");

        address lccAddr = address(lcc0);
        MockERC20 underlying = MockERC20(lcc0.underlying());
        uint256 amount = 500;

        vm.prank(marketFactory);
        ILiquidityHub(liquidityHub).setBoundLevel(address(positionManager), Bounds.BOUND_NONE);
        vm.prank(marketFactory);
        ILiquidityHub(liquidityHub).setBoundLevel(address(positionManager), Bounds.BOUND_ENDPOINT);

        underlying.mint(address(liquidityHub), amount);
        vm.prank(address(vtsOrchestrator));
        ILiquidityHub(liquidityHub).confirmTake(lccAddr, amount, false);

        _setDirectSupply(lccAddr, 0);

        lcc0.transfer(liquidityHub, amount);
        vm.prank(liquidityHub);
        lcc0.transfer(address(positionManager), amount);

        vm.mockCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector), abi.encode(uint256(0))
        );

        MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](2);
        prepared[0] = MMA.prepareSync(Currency.wrap(lccAddr));
        prepared[1] = MMA.prepareUnwrapLcc(lccAddr, amount, locker, false);

        _executeLiquidityAs(locker, prepared);
        assertEq(ILiquidityHub(liquidityHub).settleQueue(lccAddr, positionManager.custodianFor(locker)), amount);

        _executeLiquidityAs(locker, prepared);
        assertEq(
            ILiquidityHub(liquidityHub).settleQueue(lccAddr, positionManager.custodianFor(locker)),
            amount,
            "second batch must not add to queue without new unencumbered LCC"
        );
    }

    /// @notice With outstanding queue fully backed in custodian and zero live LCC on the custodian, Hub admission headroom is
    ///         zero; a direct custodian `unwrap` must revert with `InvalidAmount(amount, 0)` (explicit failure mode).
    function test_unwrapLcc_fromDeltas_outstandingQueue_zeroLiveBalance_onMmpm_revertsInvalidAmount() public {
        address locker = makeAddr("lockerZeroHeadroomExplicitRevert");
        address lccAddr = address(lcc0);
        MockERC20 underlying = MockERC20(lcc0.underlying());
        uint256 amount = 500;

        vm.prank(marketFactory);
        ILiquidityHub(liquidityHub).setBoundLevel(address(positionManager), Bounds.BOUND_NONE);
        vm.prank(marketFactory);
        ILiquidityHub(liquidityHub).setBoundLevel(address(positionManager), Bounds.BOUND_ENDPOINT);

        underlying.mint(address(liquidityHub), amount);
        vm.prank(address(vtsOrchestrator));
        ILiquidityHub(liquidityHub).confirmTake(lccAddr, amount, false);

        _setDirectSupply(lccAddr, 0);

        lcc0.transfer(liquidityHub, amount);
        vm.prank(liquidityHub);
        lcc0.transfer(address(positionManager), amount);

        vm.mockCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector), abi.encode(uint256(0))
        );

        MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](2);
        prepared[0] = MMA.prepareSync(Currency.wrap(lccAddr));
        prepared[1] = MMA.prepareUnwrapLcc(lccAddr, amount, locker, false);

        _executeLiquidityAs(locker, prepared);
        assertEq(ILiquidityHub(liquidityHub).settleQueue(lccAddr, positionManager.custodianFor(locker)), amount);
        assertEq(lcc0.balanceOf(address(positionManager)), 0);
        assertEq(IMMQueueCustodian(positionManager.custodianFor(locker)).queued(0, lccAddr, locker), amount);

        address cust = positionManager.custodianFor(locker);
        vm.prank(cust);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector, uint256(1), uint256(0)));
        ILiquidityHub(liquidityHub).unwrap(lccAddr, 1);
    }

    /// @notice Outstanding queue with LCC forwarded to custodian: admission counts capped custody credit so a second
    ///         unwrap with fresh synced LCC can queue incremental shortfall (HUB-02 / endpoint headroom).
    function test_unwrapLcc_fromDeltas_outstandingQueue_creditedCustody_secondBatchQueuesMore() public {
        address locker = makeAddr("lockerSecondBatchFreshDelta");
        address lccAddr = address(lcc0);
        MockERC20 underlying = MockERC20(lcc0.underlying());
        uint256 amount = 500;

        vm.prank(marketFactory);
        ILiquidityHub(liquidityHub).setBoundLevel(address(positionManager), Bounds.BOUND_NONE);
        vm.prank(marketFactory);
        ILiquidityHub(liquidityHub).setBoundLevel(address(positionManager), Bounds.BOUND_ENDPOINT);

        underlying.mint(address(liquidityHub), amount * 2);
        vm.prank(address(vtsOrchestrator));
        ILiquidityHub(liquidityHub).confirmTake(lccAddr, amount * 2, false);

        _setDirectSupply(lccAddr, 0);

        lcc0.transfer(liquidityHub, amount);
        vm.prank(liquidityHub);
        lcc0.transfer(address(positionManager), amount);

        vm.mockCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector), abi.encode(uint256(0))
        );

        MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](2);
        prepared[0] = MMA.prepareSync(Currency.wrap(lccAddr));
        prepared[1] = MMA.prepareUnwrapLcc(lccAddr, amount, locker, false);

        _executeLiquidityAs(locker, prepared);
        assertEq(ILiquidityHub(liquidityHub).settleQueue(lccAddr, positionManager.custodianFor(locker)), amount);
        assertEq(IMMQueueCustodian(positionManager.custodianFor(locker)).queued(0, lccAddr, locker), amount);

        lcc0.transfer(liquidityHub, amount);
        vm.prank(liquidityHub);
        lcc0.transfer(address(positionManager), amount);

        _executeLiquidityAs(locker, prepared);
        assertEq(ILiquidityHub(liquidityHub).settleQueue(lccAddr, positionManager.custodianFor(locker)), amount * 2);
        assertEq(IMMQueueCustodian(positionManager.custodianFor(locker)).queued(0, lccAddr, locker), amount * 2);
    }

    /// @notice Smoke: delta-funded unwrap shortfall queues to the utility queue owner and records beneficiary custody.
    /// @dev Per-custodian queue ownership removed shared-custodian reconciliation; annulment-to-Hub paths are covered in `LiquidityHub` tests.
    function test_unwrapLcc_fromDeltas_reconcilesExcessAfterQueueAnnulment() public {
        address locker = makeAddr("lockerDeltaReconcileAfterAnnul");
        address lccAddr = address(lcc0);
        uint256 q = 200;
        MockERC20 underlying = MockERC20(lcc0.underlying());

        vm.prank(marketFactory);
        ILiquidityHub(liquidityHub).setBoundLevel(address(positionManager), Bounds.BOUND_NONE);
        vm.prank(marketFactory);
        ILiquidityHub(liquidityHub).setBoundLevel(address(positionManager), Bounds.BOUND_ENDPOINT);

        underlying.mint(address(liquidityHub), q * 3);
        vm.prank(address(vtsOrchestrator));
        ILiquidityHub(liquidityHub).confirmTake(lccAddr, q * 3, false);
        _setDirectSupply(lccAddr, 0);

        lcc0.transfer(liquidityHub, q);
        vm.prank(liquidityHub);
        lcc0.transfer(address(positionManager), q);

        vm.mockCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector), abi.encode(uint256(0))
        );

        MMA.PreparedAction[] memory first = new MMA.PreparedAction[](2);
        first[0] = MMA.prepareSync(Currency.wrap(lccAddr));
        first[1] = MMA.prepareUnwrapLcc(lccAddr, q, locker, false);
        _executeLiquidityAs(locker, first);

        assertEq(ILiquidityHub(liquidityHub).settleQueue(lccAddr, positionManager.custodianFor(locker)), q);
        assertEq(IMMQueueCustodian(positionManager.custodianFor(locker)).queued(0, lccAddr, locker), q);
    }

    /// @notice Control: when MMPM is bucket-tracked (BOUND_ENDPOINT) and holds market-derived balance, unwrap should
    ///         attempt market liquidity when directSupply is 0.
    function test_unwrapLcc_fromDeltas_mmpmBoundEndpoint_marketDerived_callsUseMarketLiquidity_whenDirectSupplyZero()
        public
    {
        address locker = makeAddr("locker");

        address lccAddr = address(lcc0);
        MockERC20 underlying = MockERC20(lcc0.underlying());
        uint256 amount = 400;
        bytes32 marketId = PoolId.unwrap(corePoolKey.toId());

        // Ensure MMPM is bucket-tracked (level 1).
        vm.prank(marketFactory);
        ILiquidityHub(liquidityHub).setBoundLevel(address(positionManager), Bounds.BOUND_ENDPOINT);

        // Ensure Hub has enough underlying reserve + balance so `_pay()` can transfer it.
        underlying.mint(address(liquidityHub), amount);
        vm.prank(address(vtsOrchestrator)); // vtsOrchestrator is an issuer for market LCCs
        ILiquidityHub(liquidityHub).confirmTake(lccAddr, amount, false);

        // Make direct unwrapping impossible.
        _setDirectSupply(lccAddr, 0);

        // Give Hub some LCC and transfer Hub (exempt) -> MMPM (endpoint) to credit MARKET-DERIVED buckets on MMPM.
        lcc0.transfer(liquidityHub, amount);
        vm.prank(liquidityHub);
        lcc0.transfer(address(positionManager), amount);

        (uint256 wrappedBal, uint256 marketBal) = lcc0.balancesOf(address(positionManager));
        assertEq(wrappedBal, 0, "precondition: endpoint recipient should receive as market-derived from exempt sender");
        assertEq(marketBal, amount, "precondition: MMPM should have market-derived buckets");

        // Market liquidity should be used.
        vm.mockCall(
            marketFactory,
            abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector, lccAddr, marketId, amount),
            abi.encode(amount)
        );
        vm.expectCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector, lccAddr, marketId, amount)
        );

        // Sync LCC credit to locker and unwrap from deltas.
        MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](2);
        prepared[0] = MMA.prepareSync(Currency.wrap(lccAddr));
        prepared[1] = MMA.prepareUnwrapLcc(lccAddr, amount, locker, false);

        uint256 recipientUnderlyingBefore = underlying.balanceOf(locker);

        _executeLiquidityAs(locker, prepared);

        assertEq(underlying.balanceOf(locker) - recipientUnderlyingBefore, amount, "should unwrap via market liquidity");
        assertEq(
            ILiquidityHub(liquidityHub).settleQueue(lccAddr, positionManager.custodianFor(locker)),
            0,
            "should not queue when liquidity is used"
        );
    }

    /// @notice Ensures bucket-tracked (BOUND_ENDPOINT) MMPM can unwrap from deltas using its WRAPPED bucket balance.
    /// @dev This asserts the “happy path” where MMPM retains bucket accounting (wrapped bucket > 0) and unwrap succeeds
    ///      from Hub directSupply (no market-liquidity usage, no queueing).
    function test_unwrapLcc_fromDeltas_mmpmBoundEndpoint_wrappedBucket_unwrapsDirectSupply_andBurnsBuckets() public {
        address user = makeAddr("user");
        address locker = makeAddr("locker");

        address lccAddr = address(lcc0);
        MockERC20 underlying = MockERC20(lcc0.underlying());
        uint256 amount = 321;

        // Ensure MMPM is bucket-tracked (level 1).
        vm.prank(marketFactory);
        ILiquidityHub(liquidityHub).setBoundLevel(address(positionManager), Bounds.BOUND_ENDPOINT);

        // Give the user wrapped LCC (direct bucket), then transfer to MMPM.
        underlying.mint(user, amount);
        vm.startPrank(user);
        underlying.approve(address(liquidityHub), amount);
        ILiquidityHub(liquidityHub).wrap(lccAddr, amount);
        lcc0.transfer(address(positionManager), amount);
        vm.stopPrank();

        // Precondition: MMPM holds WRAPPED bucket balance (not bucketless) and no market-derived.
        (uint256 wrappedBal, uint256 marketBal) = lcc0.balancesOf(address(positionManager));
        assertEq(wrappedBal, amount, "precondition: MMPM should retain wrapped bucket accounting");
        assertEq(marketBal, 0, "precondition: no market-derived bucket balance");

        // This unwrap should NOT use market liquidity.
        vm.mockCallRevert(
            marketFactory,
            abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector),
            abi.encodeWithSignature("Error(string)", "useMarketLiquidity called")
        );

        // Sync the LCC balance as delta credit to the locker, then unwrap from deltas.
        MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](2);
        prepared[0] = MMA.prepareSync(Currency.wrap(lccAddr));
        prepared[1] = MMA.prepareUnwrapLcc(lccAddr, amount, locker, false);

        uint256 recipientUnderlyingBefore = underlying.balanceOf(locker);

        _executeLiquidityAs(locker, prepared);

        assertEq(
            underlying.balanceOf(locker) - recipientUnderlyingBefore, amount, "should unwrap entirely from directSupply"
        );
        assertEq(
            ILiquidityHub(liquidityHub).settleQueue(lccAddr, positionManager.custodianFor(locker)),
            0,
            "should not queue any shortfall"
        );
        assertEq(lcc0.balanceOf(address(positionManager)), 0, "MMPM should burn all LCC it unwrapped");
        (wrappedBal, marketBal) = lcc0.balancesOf(address(positionManager));
        assertEq(wrappedBal, 0, "MMPM wrapped bucket should be burned");
        assertEq(marketBal, 0, "MMPM market-derived bucket should remain zero");
    }

    /// @notice Ensures payer-is-user unwrap works when user-held LCC is market-derived.
    /// @dev User receives market-derived LCC from a protocol-exempt sender, then unwraps via MMPM.
    function test_unwrapLcc_payerIsUser_userMarketDerived_usesMarketLiquidity() public {
        address user = makeAddr("user");

        address lccAddr = address(lcc0);
        MockERC20 underlying = MockERC20(lcc0.underlying());
        uint256 amount = 456;
        bytes32 marketId = PoolId.unwrap(corePoolKey.toId());

        // Ensure MMPM is bucket-tracked (level 1) for the transfer-in.
        vm.prank(marketFactory);
        ILiquidityHub(liquidityHub).setBoundLevel(address(positionManager), Bounds.BOUND_ENDPOINT);

        // Fund Hub reserve so `_pay()` can transfer underlying.
        underlying.mint(address(liquidityHub), amount);
        vm.prank(address(vtsOrchestrator));
        ILiquidityHub(liquidityHub).confirmTake(lccAddr, amount, false);

        // Force direct unwrapping to be impossible.
        _setDirectSupply(lccAddr, 0);

        // Give user market-derived LCC via protocol-exempt sender (liquidityHub).
        lcc0.transfer(liquidityHub, amount);
        vm.prank(liquidityHub);
        lcc0.transfer(user, amount);

        (uint256 userWrapped, uint256 userMarket) = lcc0.balancesOf(user);
        assertEq(userWrapped, 0, "precondition: user should hold market-derived only");
        assertEq(userMarket, amount, "precondition: user market-derived should equal amount");

        // Market liquidity should be used to satisfy unwrap.
        vm.mockCall(
            marketFactory,
            abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector, lccAddr, marketId, amount),
            abi.encode(amount)
        );
        vm.expectCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector, lccAddr, marketId, amount)
        );

        // Approve and unwrap from user balance (payerIsUser=true).
        vm.startPrank(user);
        lcc0.approve(address(positionManager), amount);
        MMA.unwrapLcc(positionManager, lccAddr, amount, user, true);
        vm.stopPrank();

        assertEq(underlying.balanceOf(user), amount, "should unwrap market-derived via market liquidity");
    }

    /// @notice Regression: if a user transfers market-derived LCC into a bucket-tracked MMPM, the MMPM must retain
    ///         market-derived bucket accounting (not become "bucketless => all wrapped") so Hub unwrap uses market liquidity.
    /// @dev This directly reproduces the historical failure mode: Hub unwrap reads balances from `msg.sender` (the MMPM).
    function test_unwrap_directFromMmpm_userToMmpm_marketDerived_preservesBuckets_andUsesMarketLiquidity_whenDirectSupplyZero()
        public
    {
        address user = makeAddr("user");

        address lccAddr = address(lcc0);
        MockERC20 underlying = MockERC20(lcc0.underlying());
        uint256 amount = 321;
        bytes32 marketId = PoolId.unwrap(corePoolKey.toId());

        // Ensure MMPM is bucket-tracked (level 1), matching production when it should accrue buckets.
        vm.prank(marketFactory);
        ILiquidityHub(liquidityHub).setBoundLevel(address(positionManager), Bounds.BOUND_ENDPOINT);

        // Fund Hub reserve so `_pay()` can transfer underlying.
        underlying.mint(address(liquidityHub), amount);
        vm.prank(address(vtsOrchestrator)); // any issuer
        ILiquidityHub(liquidityHub).confirmTake(lccAddr, amount, false);

        // Force direct unwrapping to be impossible (must use market liquidity, not directSupply).
        _setDirectSupply(lccAddr, 0);

        // Give user market-derived LCC via protocol-exempt sender (liquidityHub).
        lcc0.transfer(liquidityHub, amount);
        vm.prank(liquidityHub);
        lcc0.transfer(user, amount);

        // User transfers market-derived LCC to bucket-tracked MMPM.
        vm.prank(user);
        lcc0.transfer(address(positionManager), amount);

        // Critical invariant: MMPM must NOT be bucketless; it must reflect market-derived buckets.
        assertEq(lcc0.balanceOf(address(positionManager)), amount, "precondition: MMPM should hold LCC principal");
        (uint256 wrappedBal, uint256 marketBal) = lcc0.balancesOf(address(positionManager));
        assertEq(
            wrappedBal, 0, "precondition: market-derived transfer should not become wrapped on bucket-tracked MMPM"
        );
        assertEq(marketBal, amount, "precondition: MMPM should hold market-derived bucket balance");

        // Market liquidity must be used.
        vm.mockCall(
            marketFactory,
            abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector, lccAddr, marketId, amount),
            abi.encode(amount)
        );
        vm.expectCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector, lccAddr, marketId, amount)
        );

        uint256 mmpmUnderlyingBefore = underlying.balanceOf(address(positionManager));

        // Call Hub `unwrap` from the MMPM (self-unwrap: immediate underlying lands on the caller).
        vm.prank(address(positionManager));
        ILiquidityHub(liquidityHub).unwrap(lccAddr, amount);

        assertEq(
            underlying.balanceOf(address(positionManager)) - mmpmUnderlyingBefore,
            amount,
            "should pay underlying to MMPM via market liquidity"
        );
        assertEq(
            ILiquidityHub(liquidityHub).settleQueue(lccAddr, positionManager.custodianFor(user)),
            0,
            "should not queue when liquidity is used"
        );
        assertEq(lcc0.balanceOf(address(positionManager)), 0, "MMPM should burn all LCC it unwrapped");
    }

    /// @notice When `directSupply` cannot cover the full wrapped slice, unwrap reverts; it must not queue wrapped/direct shortfall.
    function test_unwrap_directFromMmpm_mixedBuckets_constrainedDirectSupply_revertsWhenWrappedSliceNotFullyCovered()
        public
    {
        address user = makeAddr("user");

        MockERC20 underlying = MockERC20(lcc0.underlying());
        uint256 wrappedAmount = 200;
        uint256 marketAmount = 300;
        uint256 totalAmount = wrappedAmount + marketAmount;
        uint256 constrainedDirectSupply = 50;

        // Ensure MMPM is bucket-tracked (level 1).
        vm.prank(marketFactory);
        ILiquidityHub(liquidityHub).setBoundLevel(address(positionManager), Bounds.BOUND_ENDPOINT);

        // Fund Hub reserve for the market-derived portion so `_pay()` could transfer it (not reached on revert).
        underlying.mint(address(liquidityHub), marketAmount);
        vm.prank(address(vtsOrchestrator));
        ILiquidityHub(liquidityHub).confirmTake(address(lcc0), marketAmount, false);

        // Give user wrapped LCC via standard wrap.
        underlying.mint(user, wrappedAmount);
        vm.startPrank(user);
        underlying.approve(address(liquidityHub), wrappedAmount);
        ILiquidityHub(liquidityHub).wrap(address(lcc0), wrappedAmount);
        vm.stopPrank();

        // Give user market-derived LCC via protocol-exempt sender (liquidityHub).
        lcc0.transfer(liquidityHub, marketAmount);
        vm.prank(liquidityHub);
        lcc0.transfer(user, marketAmount);

        // Transfer full mixed balance to MMPM.
        vm.prank(user);
        lcc0.transfer(address(positionManager), totalAmount);

        {
            (uint256 pmWrappedBefore, uint256 pmMarketBefore) = lcc0.balancesOf(address(positionManager));
            assertEq(pmWrappedBefore, wrappedAmount, "precondition: MMPM should hold wrapped bucket balance");
            assertEq(pmMarketBefore, marketAmount, "precondition: MMPM should hold market-derived bucket balance");
        }

        // Constrain directSupply so unwrap cannot fully satisfy the wrapped portion (200 needed, 50 available).
        _setDirectSupply(address(lcc0), constrainedDirectSupply);

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector, wrappedAmount, constrainedDirectSupply));

        vm.prank(address(positionManager));
        ILiquidityHub(liquidityHub).unwrap(address(lcc0), totalAmount);
    }

    /// @notice Ensures payer-is-user unwrap works with a mixed balance (wrapped + market-derived).
    /// @dev Wrapped portion is unwrapped from directSupply, market-derived portion uses market liquidity.
    function test_unwrapLcc_payerIsUser_mixedBuckets_usesDirectAndMarketLiquidity() public {
        address user = makeAddr("user");

        address lccAddr = address(lcc0);
        MockERC20 underlying = MockERC20(lcc0.underlying());
        uint256 wrappedAmount = 200;
        uint256 marketAmount = 300;
        uint256 totalAmount = wrappedAmount + marketAmount;
        bytes32 marketId = PoolId.unwrap(corePoolKey.toId());

        // Ensure MMPM is bucket-tracked (level 1) so it preserves mixed buckets on transfer-in.
        // (MarketTestBase defaults it to BUCKET-EXEMPT to support issuer-minted LCC flows elsewhere.)
        vm.prank(marketFactory);
        ILiquidityHub(liquidityHub).setBoundLevel(address(positionManager), Bounds.BOUND_ENDPOINT);

        // Ensure user is treated as non-protocol.
        vm.mockCall(marketFactory, abi.encodeWithSelector(IMarketFactory.bounds.selector, user), abi.encode(false));

        // Fund reserve for the market-derived portion.
        underlying.mint(address(liquidityHub), marketAmount);
        vm.prank(address(vtsOrchestrator));
        ILiquidityHub(liquidityHub).confirmTake(lccAddr, marketAmount, false);

        // Give user wrapped LCC via standard wrap.
        underlying.mint(user, wrappedAmount);
        vm.startPrank(user);
        underlying.approve(address(liquidityHub), wrappedAmount);
        ILiquidityHub(liquidityHub).wrap(lccAddr, wrappedAmount);
        vm.stopPrank();

        // Give user market-derived LCC via protocol-exempt sender (liquidityHub).
        lcc0.transfer(liquidityHub, marketAmount);
        vm.prank(liquidityHub);
        lcc0.transfer(user, marketAmount);

        (uint256 userWrapped, uint256 userMarket) = lcc0.balancesOf(user);
        assertEq(userWrapped, wrappedAmount, "precondition: user wrapped balance should match");
        assertEq(userMarket, marketAmount, "precondition: user market-derived balance should match");

        // Market liquidity should be used for the market-derived portion.
        vm.mockCall(
            marketFactory,
            abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector, lccAddr, marketId, marketAmount),
            abi.encode(marketAmount)
        );
        vm.expectCall(
            marketFactory,
            abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector, lccAddr, marketId, marketAmount)
        );

        vm.startPrank(user);
        lcc0.approve(address(positionManager), totalAmount);
        MMA.unwrapLcc(positionManager, lccAddr, totalAmount, user, true);
        vm.stopPrank();

        assertEq(underlying.balanceOf(user), totalAmount, "should unwrap full mixed balance");
        assertEq(lcc0.balanceOf(user), 0, "user LCC should be fully burned");
    }

    /// @notice End-to-end: unwrap-from-deltas shortfall (market-derived on MMPM) forwards backing to custodian;
    ///         `COLLECT_AVAILABLE_LIQUIDITY` (tokenId 0) clears the queue once reserves are available.
    /// @dev Wrapped-only queues are not exercised here: `processSettlementFor` settles against market-derived holder
    ///      balance after custodian release (see `LiquidityHubLib.processSettlementLogic`).
    function test_unwrapLcc_fromDeltas_shortfall_custody_thenCollectClearsQueue() public {
        address locker = makeAddr("lockerUnwrapCollect");
        address lccAddr = address(lcc0);
        MockERC20 underlying = MockERC20(lcc0.underlying());
        uint256 amount = 300;

        vm.prank(marketFactory);
        ILiquidityHub(liquidityHub).setBoundLevel(address(positionManager), Bounds.BOUND_ENDPOINT);

        underlying.mint(address(liquidityHub), amount);
        vm.prank(address(vtsOrchestrator));
        ILiquidityHub(liquidityHub).confirmTake(lccAddr, amount, false);

        _setDirectSupply(lccAddr, 0);

        lcc0.transfer(liquidityHub, amount);
        vm.prank(liquidityHub);
        lcc0.transfer(address(positionManager), amount);

        (uint256 wBal, uint256 mBal) = lcc0.balancesOf(address(positionManager));
        assertEq(wBal, 0);
        assertEq(mBal, amount);

        vm.mockCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector), abi.encode(uint256(0))
        );

        MMA.PreparedAction[] memory unwrapBatch = new MMA.PreparedAction[](2);
        unwrapBatch[0] = MMA.prepareSync(Currency.wrap(lccAddr));
        unwrapBatch[1] = MMA.prepareUnwrapLcc(lccAddr, amount, locker, false);

        _executeLiquidityAs(locker, unwrapBatch);

        assertEq(ILiquidityHub(liquidityHub).settleQueue(lccAddr, positionManager.custodianFor(locker)), amount);
        assertEq(lcc0.balanceOf(address(positionManager)), 0);
        assertEq(IMMQueueCustodian(positionManager.custodianFor(locker)).queued(0, lccAddr, locker), amount);

        underlying.mint(address(liquidityHub), amount);
        vm.prank(address(vtsOrchestrator));
        ILiquidityHub(liquidityHub).confirmTake(lccAddr, amount, false);

        uint256 beforeUnderlying = underlying.balanceOf(locker);
        MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](1);
        prepared[0] = MMA.prepareCollectAvailableLiquidity(lccAddr, 0, type(uint256).max);
        _executeWithUnlockAs(locker, prepared, block.timestamp + 3600);

        assertEq(ILiquidityHub(liquidityHub).settleQueue(lccAddr, positionManager.custodianFor(locker)), 0);
        assertEq(underlying.balanceOf(locker) - beforeUnderlying, amount);
    }

    /// @notice Payer unwrap shortfall queues to the utility custodian and records beneficiary-scoped custody.
    function test_unwrapLcc_utilityCustody_reconcilesExcessAfterQueueAnnulment() public {
        address victim = makeAddr("victimUtilityReconcile");
        address lccAddr = address(lcc0);
        uint256 q = 200;
        MockERC20 underlying = MockERC20(lcc0.underlying());

        vm.prank(marketFactory);
        ILiquidityHub(liquidityHub).setBoundLevel(address(positionManager), Bounds.BOUND_ENDPOINT);
        vm.mockCall(marketFactory, abi.encodeWithSelector(IMarketFactory.bounds.selector, victim), abi.encode(false));

        underlying.mint(address(liquidityHub), q * 2);
        vm.prank(address(vtsOrchestrator));
        ILiquidityHub(liquidityHub).confirmTake(lccAddr, q * 2, false);
        _setDirectSupply(lccAddr, 0);

        lcc0.transfer(liquidityHub, q);
        vm.prank(liquidityHub);
        lcc0.transfer(victim, q);
        vm.startPrank(victim);
        lcc0.approve(address(positionManager), type(uint256).max);
        vm.stopPrank();

        vm.mockCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector), abi.encode(uint256(0))
        );
        vm.prank(victim);
        MMA.unwrapLcc(positionManager, lccAddr, q, victim, true);

        assertEq(ILiquidityHub(liquidityHub).settleQueue(lccAddr, positionManager.custodianFor(victim)), q);
        assertEq(IMMQueueCustodian(positionManager.custodianFor(victim)).queued(0, lccAddr, victim), q);
    }

    /// @notice Utility collect clears queue + custody when underlying reserve backs the custodian queue.
    function test_collectAvailableLiquidity_tokenIdZero_reconcilesAfterPartialQueueAnnulment() public {
        address user = makeAddr("userTok0Collect");
        address lccAddr = address(lcc0);
        MockERC20 underlying = MockERC20(lcc0.underlying());
        uint256 amount = 100;

        vm.prank(address(proxyHook));
        ILiquidityHub(liquidityHub).issue(lccAddr, address(liquidityHub), amount);
        vm.mockCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector), abi.encode(uint256(0))
        );
        _wireTestQueueCustodian(user);
        address utilQ = positionManager.custodianFor(user);
        vm.prank(address(vtsOrchestrator));
        ILiquidityHub(liquidityHub)
            .planCancelWithQueue(lccAddr, address(liquidityHub), address(positionManager), amount, amount, utilQ);
        vm.prank(address(liquidityHub));
        ILCC(lccAddr).transfer(address(positionManager), amount);

        address custody = positionManager.custodianFor(user);
        vm.startPrank(address(positionManager));
        lcc0.transfer(custody, amount);
        IMMQueueCustodian(custody).record(0, lccAddr, user, amount);
        vm.stopPrank();

        underlying.mint(address(liquidityHub), amount);
        vm.prank(address(vtsOrchestrator));
        ILiquidityHub(liquidityHub).confirmTake(lccAddr, amount, false);

        uint256 beforeU = underlying.balanceOf(user);
        MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](1);
        prepared[0] = MMA.prepareCollectAvailableLiquidity(lccAddr, 0, type(uint256).max);
        _executeWithUnlockAs(user, prepared, block.timestamp + 3600);

        assertEq(ILiquidityHub(liquidityHub).settleQueue(lccAddr, utilQ), 0);
        assertEq(IMMQueueCustodian(custody).queued(0, lccAddr, user), 0);
        assertEq(underlying.balanceOf(user) - beforeU, amount);
    }

    /// @notice When Hub `settleQueue` for the utility custodian is zero, `_collectAvailableLiquidity` returns without side effects.
    function test_collectAvailableLiquidity_tokenIdZero_reconcilesExcessUtilityCustodyWhenHubQueueZero() public {
        address user = makeAddr("userCollectNoop");
        address lccAddr = address(lcc0);
        assertEq(ILiquidityHub(liquidityHub).settleQueue(lccAddr, positionManager.custodianFor(user)), 0);
        uint256 uBefore = MockERC20(lcc0.underlying()).balanceOf(user);
        MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](1);
        prepared[0] = MMA.prepareCollectAvailableLiquidity(lccAddr, 0, type(uint256).max);
        _executeWithUnlockAs(user, prepared, block.timestamp + 3600);
        assertEq(MockERC20(lcc0.underlying()).balanceOf(user), uBefore);
    }

    /// @notice After partial collect, utility-bucket custody matches the remaining queue; a
    ///         later delta-funded unwrap with fresh synced LCC queues only the incremental shortfall.
    function test_unwrapLcc_fromDeltas_afterPartialCollect_admissionCreditAndSecondUnwrap() public {
        address locker = makeAddr("lockerPartialCollectThenUnwrap");
        address lccAddr = address(lcc0);
        MockERC20 underlying = MockERC20(lcc0.underlying());
        uint256 amount = 250;
        uint256 available = 100;
        uint256 freshForSecond = 50;

        vm.prank(marketFactory);
        ILiquidityHub(liquidityHub).setBoundLevel(address(positionManager), Bounds.BOUND_NONE);
        vm.prank(marketFactory);
        ILiquidityHub(liquidityHub).setBoundLevel(address(positionManager), Bounds.BOUND_ENDPOINT);

        // Avoid seeding a large `marketDerived` Hub reserve before the shortfall-only unwrap; otherwise collect can
        // settle the full queue in one go when reserves dwarf `available`.
        _setDirectSupply(lccAddr, 0);

        lcc0.transfer(liquidityHub, amount);
        vm.prank(liquidityHub);
        lcc0.transfer(address(positionManager), amount);

        vm.mockCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector), abi.encode(uint256(0))
        );

        MMA.PreparedAction[] memory unwrapBatch = new MMA.PreparedAction[](2);
        unwrapBatch[0] = MMA.prepareSync(Currency.wrap(lccAddr));
        unwrapBatch[1] = MMA.prepareUnwrapLcc(lccAddr, amount, locker, false);

        _executeLiquidityAs(locker, unwrapBatch);

        assertEq(ILiquidityHub(liquidityHub).settleQueue(lccAddr, positionManager.custodianFor(locker)), amount);
        assertEq(IMMQueueCustodian(positionManager.custodianFor(locker)).queued(0, lccAddr, locker), amount);

        underlying.mint(address(liquidityHub), available);
        vm.prank(address(vtsOrchestrator));
        ILiquidityHub(liquidityHub).confirmTake(lccAddr, available, false);

        MMA.PreparedAction[] memory collect = new MMA.PreparedAction[](1);
        collect[0] = MMA.prepareCollectAvailableLiquidity(lccAddr, 0, type(uint256).max);
        _executeWithUnlockAs(locker, collect, block.timestamp + 3600);

        uint256 remainder = amount - available;
        assertEq(ILiquidityHub(liquidityHub).settleQueue(lccAddr, positionManager.custodianFor(locker)), remainder);
        assertEq(IMMQueueCustodian(positionManager.custodianFor(locker)).queued(0, lccAddr, locker), remainder);

        underlying.mint(address(liquidityHub), freshForSecond);
        vm.prank(address(vtsOrchestrator));
        ILiquidityHub(liquidityHub).confirmTake(lccAddr, freshForSecond, false);

        lcc0.transfer(liquidityHub, freshForSecond);
        vm.prank(liquidityHub);
        lcc0.transfer(address(positionManager), freshForSecond);

        vm.mockCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector), abi.encode(uint256(0))
        );

        MMA.PreparedAction[] memory second = new MMA.PreparedAction[](2);
        second[0] = MMA.prepareSync(Currency.wrap(lccAddr));
        second[1] = MMA.prepareUnwrapLcc(lccAddr, freshForSecond, locker, false);

        _executeLiquidityAs(locker, second);

        assertEq(
            ILiquidityHub(liquidityHub).settleQueue(lccAddr, positionManager.custodianFor(locker)),
            remainder + freshForSecond,
            "incremental shortfall should add to remaining queue"
        );
        assertEq(
            IMMQueueCustodian(positionManager.custodianFor(locker)).queued(0, lccAddr, locker),
            remainder + freshForSecond
        );
    }

    /// @notice Beneficiary-scoped custody: independent lockers accrue separate slices on the same utility custodian.
    function test_unwrapLcc_fromDeltas_unwrapAdmissionCredit_isolatedPerBeneficiary() public {
        address lockerA = makeAddr("lockerA_custodyIso");
        address lockerB = makeAddr("lockerB_custodyIso");
        address lccAddr = address(lcc0);
        MockERC20 underlying = MockERC20(lcc0.underlying());
        uint256 amountA = 200;
        uint256 amountB = 50;

        vm.prank(marketFactory);
        ILiquidityHub(liquidityHub).setBoundLevel(address(positionManager), Bounds.BOUND_NONE);
        vm.prank(marketFactory);
        ILiquidityHub(liquidityHub).setBoundLevel(address(positionManager), Bounds.BOUND_ENDPOINT);

        underlying.mint(address(liquidityHub), amountA);
        vm.prank(address(vtsOrchestrator));
        ILiquidityHub(liquidityHub).confirmTake(lccAddr, amountA, false);

        _setDirectSupply(lccAddr, 0);

        lcc0.transfer(liquidityHub, amountA);
        vm.prank(liquidityHub);
        lcc0.transfer(address(positionManager), amountA);

        vm.mockCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector), abi.encode(uint256(0))
        );

        MMA.PreparedAction[] memory batchA = new MMA.PreparedAction[](2);
        batchA[0] = MMA.prepareSync(Currency.wrap(lccAddr));
        batchA[1] = MMA.prepareUnwrapLcc(lccAddr, amountA, lockerA, false);
        _executeLiquidityAs(lockerA, batchA);

        assertEq(ILiquidityHub(liquidityHub).settleQueue(lccAddr, positionManager.custodianFor(lockerA)), amountA);
        assertEq(IMMQueueCustodian(positionManager.custodianFor(lockerA)).queued(0, lccAddr, lockerA), amountA);
        assertEq(IMMQueueCustodian(positionManager.custodianFor(lockerB)).queued(0, lccAddr, lockerB), 0);

        underlying.mint(address(liquidityHub), amountB);
        vm.prank(address(vtsOrchestrator));
        ILiquidityHub(liquidityHub).confirmTake(lccAddr, amountB, false);

        lcc0.transfer(liquidityHub, amountB);
        vm.prank(liquidityHub);
        lcc0.transfer(address(positionManager), amountB);

        vm.mockCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector), abi.encode(uint256(0))
        );

        MMA.PreparedAction[] memory batchB = new MMA.PreparedAction[](2);
        batchB[0] = MMA.prepareSync(Currency.wrap(lccAddr));
        batchB[1] = MMA.prepareUnwrapLcc(lccAddr, amountB, lockerB, false);
        _executeLiquidityAs(lockerB, batchB);

        assertEq(ILiquidityHub(liquidityHub).settleQueue(lccAddr, positionManager.custodianFor(lockerA)), amountA);
        assertEq(ILiquidityHub(liquidityHub).settleQueue(lccAddr, positionManager.custodianFor(lockerB)), amountB);
        assertEq(IMMQueueCustodian(positionManager.custodianFor(lockerB)).queued(0, lccAddr, lockerB), amountB);
        assertEq(IMMQueueCustodian(positionManager.custodianFor(lockerA)).queued(0, lccAddr, lockerA), amountA);
    }

    /// @notice Another locker cannot `SYNC` + `TAKE` custodied queued backing after a victim's unwrap shortfall.
    /// @dev Uses market-derived LCC on the victim so unwrap can queue (wrapped-only shortfall reverts under Scan 21 F3).
    function test_unwrapLcc_payerIsUser_shortfall_attackerSyncTake_doesNotStealCustodiedLcc() public {
        address victim = makeAddr("victimSyncTake");
        address attacker = makeAddr("attackerSyncTake");
        address lccAddr = address(lcc0);
        uint256 amount = 200;
        MockERC20 underlying = MockERC20(lcc0.underlying());

        vm.prank(marketFactory);
        ILiquidityHub(liquidityHub).setBoundLevel(address(positionManager), Bounds.BOUND_ENDPOINT);

        vm.mockCall(marketFactory, abi.encodeWithSelector(IMarketFactory.bounds.selector, victim), abi.encode(false));

        underlying.mint(address(liquidityHub), amount);
        vm.prank(address(vtsOrchestrator));
        ILiquidityHub(liquidityHub).confirmTake(lccAddr, amount, false);

        _setDirectSupply(lccAddr, 0);

        // Victim receives issuer-routed (market-derived) LCC only.
        lcc0.transfer(liquidityHub, amount);
        vm.prank(liquidityHub);
        lcc0.transfer(victim, amount);

        vm.startPrank(victim);
        lcc0.approve(address(positionManager), type(uint256).max);
        vm.stopPrank();

        vm.mockCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector), abi.encode(uint256(0))
        );

        vm.prank(victim);
        MMA.unwrapLcc(positionManager, lccAddr, amount, victim, true);

        assertEq(ILiquidityHub(liquidityHub).settleQueue(lccAddr, positionManager.custodianFor(victim)), amount);
        assertEq(lcc0.balanceOf(address(positionManager)), 0);
        assertEq(IMMQueueCustodian(positionManager.custodianFor(victim)).queued(0, lccAddr, victim), amount);

        uint256 attackerLccBefore = lcc0.balanceOf(attacker);
        MMA.PreparedAction[] memory steal = new MMA.PreparedAction[](2);
        steal[0] = MMA.prepareSync(Currency.wrap(lccAddr));
        steal[1] = MMA.prepareTake(Currency.wrap(lccAddr), attacker, 0);
        _executeLiquidityAs(attacker, steal);

        assertEq(lcc0.balanceOf(attacker), attackerLccBefore, "attacker must not take victim custodied LCC");
    }

    /// @notice Regression: queue snapshot must be post-transfer (post-annul). Second unwrap with pre-existing queue
    ///         from first shortfall must forward the full new queued shortfall to custodian, not (newQueue - oldQueue).
    /// @dev Old bug: qBefore before transfer made `queued = after - before` subtract annulled old queue from new shortfall.
    function test_unwrapLcc_payerIsUser_secondUnwrap_afterPreExistingQueue_forwardsFullShortfallToCustodian() public {
        address victim = makeAddr("victimSecondUnwrapQueue");
        address lccAddr = address(lcc0);
        uint256 amount = 200;
        MockERC20 underlying = MockERC20(lcc0.underlying());

        vm.prank(marketFactory);
        ILiquidityHub(liquidityHub).setBoundLevel(address(positionManager), Bounds.BOUND_ENDPOINT);

        vm.mockCall(marketFactory, abi.encodeWithSelector(IMarketFactory.bounds.selector, victim), abi.encode(false));

        underlying.mint(address(liquidityHub), amount * 2);
        vm.prank(address(vtsOrchestrator));
        ILiquidityHub(liquidityHub).confirmTake(lccAddr, amount * 2, false);

        _setDirectSupply(lccAddr, 0);

        // First unwrap: shortfall queues `amount` for victim; victim has no LCC left.
        lcc0.transfer(liquidityHub, amount);
        vm.prank(liquidityHub);
        lcc0.transfer(victim, amount);

        vm.startPrank(victim);
        lcc0.approve(address(positionManager), type(uint256).max);
        vm.stopPrank();

        vm.mockCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector), abi.encode(uint256(0))
        );

        vm.prank(victim);
        MMA.unwrapLcc(positionManager, lccAddr, amount, victim, true);

        assertEq(
            ILiquidityHub(liquidityHub).settleQueue(lccAddr, positionManager.custodianFor(victim)),
            amount,
            "precondition: first shortfall queues"
        );
        assertEq(lcc0.balanceOf(victim), 0);

        // Second unwrap: same `amount` LCC again; transfer annuls prior queue then unwrap queues shortfall again.
        lcc0.transfer(liquidityHub, amount);
        vm.prank(liquidityHub);
        lcc0.transfer(victim, amount);

        vm.prank(victim);
        MMA.unwrapLcc(positionManager, lccAddr, amount, victim, true);

        assertEq(
            ILiquidityHub(liquidityHub).settleQueue(lccAddr, positionManager.custodianFor(victim)),
            amount * 2,
            "each full shortfall tranche accrues to the utility custodian queue"
        );
        assertEq(lcc0.balanceOf(address(positionManager)), 0, "no stranded queued-backing LCC on MMPM");
        assertEq(
            IMMQueueCustodian(positionManager.custodianFor(victim)).queued(0, lccAddr, victim),
            amount * 2,
            "custodian should record both shortfall tranches"
        );
    }

    /// @notice Regression: pre-transfer queue snapshot caused underflow when annul cleared queue and unwrap added none.
    /// @dev Second unwrap fully satisfies via market liquidity: no new queue; must not revert on queued delta math.
    function test_unwrapLcc_payerIsUser_secondUnwrap_annulThenFullMarket_doesNotRevert() public {
        address victim = makeAddr("victimAnnulFullMarket");
        address lccAddr = address(lcc0);
        uint256 amount = 200;
        bytes32 marketId = PoolId.unwrap(corePoolKey.toId());
        MockERC20 underlying = MockERC20(lcc0.underlying());

        vm.prank(marketFactory);
        ILiquidityHub(liquidityHub).setBoundLevel(address(positionManager), Bounds.BOUND_ENDPOINT);

        vm.mockCall(marketFactory, abi.encodeWithSelector(IMarketFactory.bounds.selector, victim), abi.encode(false));

        underlying.mint(address(liquidityHub), amount * 2);
        vm.prank(address(vtsOrchestrator));
        ILiquidityHub(liquidityHub).confirmTake(lccAddr, amount * 2, false);

        _setDirectSupply(lccAddr, 0);

        lcc0.transfer(liquidityHub, amount);
        vm.prank(liquidityHub);
        lcc0.transfer(victim, amount);

        vm.startPrank(victim);
        lcc0.approve(address(positionManager), type(uint256).max);
        vm.stopPrank();

        vm.mockCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector), abi.encode(uint256(0))
        );

        vm.prank(victim);
        MMA.unwrapLcc(positionManager, lccAddr, amount, victim, true);

        assertEq(ILiquidityHub(liquidityHub).settleQueue(lccAddr, positionManager.custodianFor(victim)), amount);

        lcc0.transfer(liquidityHub, amount);
        vm.prank(liquidityHub);
        lcc0.transfer(victim, amount);

        vm.mockCall(
            marketFactory,
            abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector, lccAddr, marketId, amount),
            abi.encode(amount)
        );

        vm.prank(victim);
        MMA.unwrapLcc(positionManager, lccAddr, amount, victim, true);

        assertEq(
            ILiquidityHub(liquidityHub).settleQueue(lccAddr, positionManager.custodianFor(victim)),
            amount,
            "first tranche queue remains until settled; second leg is fully satisfied from market liquidity"
        );
        assertEq(lcc0.balanceOf(address(positionManager)), 0);
    }

    /// @notice Mutation-killer: when `settleQueue(lcc, sender) == 0`, COLLECT_AVAILABLE_LIQUIDITY must be a no-op.
    function test_collectAvailableLiquidity_whenQueuedIsZero_isNoop() public {
        address locker = liquiditySignal.mmState.advancer;
        _wireTestQueueCustodian(locker);
        MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](1);
        uint256 lcc0BalanceBefore = lcc0.balanceOf(address(this));
        prepared[0] = MMA.prepareCollectAvailableLiquidity(address(lcc0), 0, 0);
        assertEq(
            ILiquidityHub(liquidityHub).settleQueue(address(lcc0), positionManager.custodianFor(locker)),
            0,
            "precondition: queue owner should have no queued settlement"
        );
        _executeLiquidity(prepared);
        assertEq(lcc0.balanceOf(address(this)), lcc0BalanceBefore, "no-op collect should not change LCC balances");
    }

    /// @notice Mutation-killer: when `settleQueue(lcc, sender) > 0`, COLLECT_AVAILABLE_LIQUIDITY must process settlement.
    /// @dev We create a real queued settlement entry, then ensure it is cleared and underlying is received.
    function test_collectAvailableLiquidity_whenQueuedPositive_processesSettlementToSender() public {
        address user = makeAddr("user");
        address lccAddr = address(lcc0);
        MockERC20 underlying = MockERC20(lcc0.underlying());

        // Setup:
        // - Seed MMPositionManager with MARKET-DERIVED LCC (so later it can transfer market-derived to `user`)
        // - Create a queued settlement entry for `user` (via planned cancel with full queue)
        uint256 amount = 250;
        vm.prank(address(proxyHook));
        ILiquidityHub(liquidityHub).issue(lccAddr, address(liquidityHub), amount);

        // Force unwrap to queue (no market liquidity available).
        vm.mockCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector), abi.encode(uint256(0))
        );

        _wireTestQueueCustodian(user);
        address utilQ = positionManager.custodianFor(user);
        vm.prank(address(vtsOrchestrator));
        ILiquidityHub(liquidityHub)
            .planCancelWithQueue(lccAddr, address(liquidityHub), address(positionManager), amount, amount, utilQ);

        // Transfer from a bucket-exempt endpoint (Hub) to a bucket-tracked endpoint (MMPM) so MMPM accrues market-derived.
        vm.prank(address(liquidityHub));
        ILCC(lccAddr).transfer(address(positionManager), amount);

        // Create a queue entry for `user` - using planCancelWithQueue.
        assertEq(
            ILiquidityHub(liquidityHub).settleQueue(lccAddr, positionManager.custodianFor(user)),
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

        // Move queued LCC backing into shared custody bucket 0 for this synthetic setup.
        address custody = positionManager.custodianFor(user);
        vm.prank(address(positionManager));
        lcc0.transfer(custody, amount);
        vm.prank(address(positionManager));
        IMMQueueCustodian(custody).record(0, lccAddr, user, amount);

        MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](1);
        prepared[0] = MMA.prepareCollectAvailableLiquidity(lccAddr, 0, type(uint256).max);
        _executeWithUnlockAs(user, prepared, block.timestamp + 3600);

        assertEq(
            ILiquidityHub(liquidityHub).settleQueue(lccAddr, positionManager.custodianFor(user)),
            0,
            "collect should clear sender's queue entry"
        );
        assertEq(
            underlying.balanceOf(user) - beforeUnderlying, amount, "collect should transfer queued underlying to sender"
        );
    }

    /// @notice Regression: permissionless Hub settlement can zero the custodian queue before collect; payout must still succeed.
    function test_collectAvailableLiquidity_afterPermissionlessPreSettlement_paysFromCustodian() public {
        address user = makeAddr("userPreSettle");
        address lccAddr = address(lcc0);
        MockERC20 underlying = MockERC20(lcc0.underlying());
        uint256 amount = 250;

        vm.prank(address(proxyHook));
        ILiquidityHub(liquidityHub).issue(lccAddr, address(liquidityHub), amount);

        vm.mockCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector), abi.encode(uint256(0))
        );

        _wireTestQueueCustodian(user);
        address utilQ = positionManager.custodianFor(user);
        vm.prank(address(vtsOrchestrator));
        ILiquidityHub(liquidityHub)
            .planCancelWithQueue(lccAddr, address(liquidityHub), address(positionManager), amount, amount, utilQ);

        vm.prank(address(liquidityHub));
        ILCC(lccAddr).transfer(address(positionManager), amount);

        underlying.mint(address(liquidityHub), amount);
        vm.prank(address(vtsOrchestrator));
        ILiquidityHub(liquidityHub).confirmTake(lccAddr, amount, true);

        address custody = positionManager.custodianFor(user);
        vm.startPrank(address(positionManager));
        lcc0.transfer(custody, amount);
        IMMQueueCustodian(custody).record(0, lccAddr, user, amount);
        vm.stopPrank();

        assertEq(ILiquidityHub(liquidityHub).settleQueue(lccAddr, custody), amount);
        assertEq(IMMQueueCustodian(custody).totalQueuedLcc(lccAddr), amount);

        address stranger = makeAddr("strangerSettler");
        vm.prank(stranger);
        ILiquidityHub(liquidityHub).processSettlementFor(lccAddr, custody, amount);

        assertEq(ILiquidityHub(liquidityHub).settleQueue(lccAddr, custody), 0);
        assertEq(lcc0.balanceOf(custody), 0);
        assertEq(underlying.balanceOf(custody), amount);

        uint256 beforeUnderlying = underlying.balanceOf(user);
        MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](1);
        prepared[0] = MMA.prepareCollectAvailableLiquidity(lccAddr, 0, type(uint256).max);
        _executeWithUnlockAs(user, prepared, block.timestamp + 3600);

        assertEq(IMMQueueCustodian(custody).queued(0, lccAddr, user), 0);
        assertEq(IMMQueueCustodian(custody).totalQueuedLcc(lccAddr), 0);
        assertEq(underlying.balanceOf(user) - beforeUnderlying, amount);
        assertEq(underlying.balanceOf(custody), 0);
    }

    /// @notice Regression: permissionless Hub settlement of a commit bucket must still allow collect and decommit.
    function test_collectAvailableLiquidity_commitBucket_afterPermissionlessPreSettlement_allowsDecommit() public {
        bytes memory liquiditySignalBytes = abi.encode(liquiditySignal);
        uint256 tokenId = positionManager.nextTokenId();
        address owner = liquiditySignal.mmState.owner;
        address lccAddr = address(lcc0);
        MockERC20 underlying = MockERC20(lcc0.underlying());
        uint256 amount = 250;

        MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](1);
        prepared[0] = MMA.prepareCommit(liquiditySignalBytes);
        _executeWithUnlockLiquidity(prepared, block.timestamp + 3600);

        address custody = positionManager.custodianFor(positionManager.ownerOf(tokenId));

        vm.prank(address(proxyHook));
        ILiquidityHub(liquidityHub).issue(lccAddr, address(liquidityHub), amount);
        vm.prank(address(vtsOrchestrator));
        ILiquidityHub(liquidityHub)
            .planCancelWithQueue(lccAddr, address(liquidityHub), address(positionManager), amount, amount, custody);
        vm.prank(address(liquidityHub));
        ILCC(lccAddr).transfer(address(positionManager), amount);

        underlying.mint(address(liquidityHub), amount);
        vm.prank(address(vtsOrchestrator));
        ILiquidityHub(liquidityHub).confirmTake(lccAddr, amount, true);

        vm.startPrank(address(positionManager));
        lcc0.transfer(custody, amount);
        IMMQueueCustodian(custody).record(tokenId, lccAddr, owner, amount);
        vm.stopPrank();

        assertEq(ILiquidityHub(liquidityHub).settleQueue(lccAddr, custody), amount);
        assertEq(IMMQueueCustodian(custody).queued(tokenId, lccAddr, owner), amount);

        address stranger = makeAddr("strangerCommitSettler");
        vm.prank(stranger);
        ILiquidityHub(liquidityHub).processSettlementFor(lccAddr, custody, amount);

        assertEq(ILiquidityHub(liquidityHub).settleQueue(lccAddr, custody), 0);
        assertEq(underlying.balanceOf(custody), amount);

        uint256 beforeUnderlying = underlying.balanceOf(owner);
        prepared[0] = MMA.prepareCollectAvailableLiquidity(lccAddr, tokenId, type(uint256).max);
        _executeWithUnlockLiquidity(prepared, block.timestamp + 3600);

        assertEq(IMMQueueCustodian(custody).queued(tokenId, lccAddr, owner), 0);
        assertEq(underlying.balanceOf(owner) - beforeUnderlying, amount);

        prepared[0] = MMA.prepareDecommit(tokenId);
        _executeWithUnlockLiquidity(prepared, block.timestamp + 3600);

        vm.expectRevert();
        positionManager.ownerOf(tokenId);
    }

    function test_collectAvailableLiquidity_whenNoReserveAvailable_isNoopAndKeepsCustody() public {
        address user = makeAddr("user");
        address lccAddr = address(lcc0);
        MockERC20 underlying = MockERC20(lcc0.underlying());
        _wireTestQueueCustodian(user);
        address custody = positionManager.custodianFor(user);
        uint256 tokenId = 0;
        uint256 amount = 250;

        vm.prank(address(proxyHook));
        ILiquidityHub(liquidityHub).issue(lccAddr, address(liquidityHub), amount);

        vm.mockCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector), abi.encode(uint256(0))
        );
        address utilQNoRes = positionManager.custodianFor(user);
        vm.prank(address(vtsOrchestrator));
        ILiquidityHub(liquidityHub)
            .planCancelWithQueue(lccAddr, address(liquidityHub), address(positionManager), amount, amount, utilQNoRes);
        vm.prank(address(liquidityHub));
        ILCC(lccAddr).transfer(address(positionManager), amount);

        vm.startPrank(address(positionManager));
        lcc0.transfer(custody, amount);
        IMMQueueCustodian(custody).record(tokenId, lccAddr, user, amount);
        vm.stopPrank();

        uint256 userUnderlyingBefore = underlying.balanceOf(user);
        uint256 userLccBefore = lcc0.balanceOf(user);

        MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](1);
        prepared[0] = MMA.prepareCollectAvailableLiquidity(lccAddr, tokenId, type(uint256).max);
        _executeWithUnlockAs(user, prepared, block.timestamp + 3600);

        assertEq(underlying.balanceOf(user), userUnderlyingBefore, "no reserve => no underlying transferred");
        assertEq(lcc0.balanceOf(user), userLccBefore, "no reserve => no LCC released to user");
        assertEq(
            ILiquidityHub(liquidityHub).settleQueue(lccAddr, positionManager.custodianFor(user)),
            amount,
            "queue should remain outstanding"
        );
        assertEq(IMMQueueCustodian(custody).queued(tokenId, lccAddr, user), amount, "custody should remain intact");
    }

    function test_collectAvailableLiquidity_whenReservePartiallyAvailable_keepsRemainderCustodied() public {
        address user = makeAddr("user");
        address lccAddr = address(lcc0);
        MockERC20 underlying = MockERC20(lcc0.underlying());
        _wireTestQueueCustodian(user);
        address custody = positionManager.custodianFor(user);
        uint256 tokenId = 0;
        uint256 amount = 250;
        uint256 available = 100;

        vm.prank(address(proxyHook));
        ILiquidityHub(liquidityHub).issue(lccAddr, address(liquidityHub), amount);

        vm.mockCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector), abi.encode(uint256(0))
        );
        address utilQPartial = positionManager.custodianFor(user);
        vm.prank(address(vtsOrchestrator));
        ILiquidityHub(liquidityHub)
            .planCancelWithQueue(lccAddr, address(liquidityHub), address(positionManager), amount, amount, utilQPartial);
        vm.prank(address(liquidityHub));
        ILCC(lccAddr).transfer(address(positionManager), amount);

        vm.startPrank(address(positionManager));
        lcc0.transfer(custody, amount);
        IMMQueueCustodian(custody).record(tokenId, lccAddr, user, amount);
        vm.stopPrank();

        underlying.mint(address(liquidityHub), available);
        vm.prank(address(vtsOrchestrator));
        ILiquidityHub(liquidityHub).confirmTake(lccAddr, available, false);

        uint256 beforeUnderlying = underlying.balanceOf(user);

        MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](1);
        prepared[0] = MMA.prepareCollectAvailableLiquidity(lccAddr, tokenId, type(uint256).max);
        _executeWithUnlockAs(user, prepared, block.timestamp + 3600);

        assertEq(underlying.balanceOf(user) - beforeUnderlying, available, "should settle only live reserve");
        assertEq(lcc0.balanceOf(user), 0, "released LCC should be fully burned for settled amount only");
        assertEq(
            ILiquidityHub(liquidityHub).settleQueue(lccAddr, positionManager.custodianFor(user)),
            amount - available,
            "queue remainder"
        );
        assertEq(
            IMMQueueCustodian(custody).queued(tokenId, lccAddr, user), amount - available, "custody remainder intact"
        );
    }

    /// @notice Two beneficiary-scoped utility slices cannot be drained by the wrong party (recipient-keyed custodians).
    /// @dev Each beneficiary's Hub queue and custody live on `custodianFor(beneficiary)`; isolation is end-to-end.
    function test_collectAvailableLiquidity_commitAware_cannotDrainOtherCommitBucket() public {
        address userA = makeAddr("userA_iso");
        address userB = makeAddr("userB_iso");
        address lccAddr = address(lcc0);
        _wireTestQueueCustodian(userA);
        _wireTestQueueCustodian(userB);
        address custodyA = positionManager.custodianFor(userA);
        address custodyB = positionManager.custodianFor(userB);

        vm.mockCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector), abi.encode(uint256(0))
        );

        _seedUtilityHubCustody(lccAddr, custodyA, userA, 100);
        _seedUtilityHubCustody(lccAddr, custodyB, userB, 200);

        MockERC20 underlying = MockERC20(lcc0.underlying());
        underlying.mint(address(liquidityHub), 300);
        vm.prank(address(vtsOrchestrator));
        ILiquidityHub(liquidityHub).confirmTake(lccAddr, 300, false);

        uint256 beforeA = underlying.balanceOf(userA);
        MMA.PreparedAction[] memory collectA = new MMA.PreparedAction[](1);
        collectA[0] = MMA.prepareCollectAvailableLiquidity(lccAddr, 0, type(uint256).max);
        _executeWithUnlockAs(userA, collectA, block.timestamp + 3600);
        assertEq(underlying.balanceOf(userA) - beforeA, 100);
        assertEq(IMMQueueCustodian(custodyA).queued(0, lccAddr, userA), 0);
        assertEq(
            IMMQueueCustodian(custodyB).queued(0, lccAddr, userB), 200, "userB slice must remain on their custodian"
        );
    }

    /// @dev Hub issue + plan + transfer + MM `record` for one utility beneficiary (bucket `0`).
    function _seedUtilityHubCustody(address lccAddr, address custody, address beneficiary, uint256 amount) internal {
        vm.prank(address(proxyHook));
        ILiquidityHub(liquidityHub).issue(lccAddr, address(liquidityHub), amount);
        vm.prank(address(vtsOrchestrator));
        ILiquidityHub(liquidityHub)
            .planCancelWithQueue(lccAddr, address(liquidityHub), address(positionManager), amount, amount, custody);
        vm.prank(address(liquidityHub));
        ILCC(lccAddr).transfer(address(positionManager), amount);
        vm.startPrank(address(positionManager));
        lcc0.transfer(custody, amount);
        IMMQueueCustodian(custody).record(0, lccAddr, beneficiary, amount);
        vm.stopPrank();
    }

    /// @notice A locker with a Hub queue cannot collect using another party's beneficiary slice under the same tokenId.
    function test_collectAvailableLiquidity_cannotDrainOtherBeneficiaryCustody() public {
        address user = makeAddr("user");
        address victim = makeAddr("victim");
        address lccAddr = address(lcc0);
        MockERC20 underlying = MockERC20(lcc0.underlying());
        _wireTestQueueCustodian(victim);
        address custody = positionManager.custodianFor(victim);
        uint256 amount = 150;

        vm.prank(address(proxyHook));
        ILiquidityHub(liquidityHub).issue(lccAddr, address(liquidityHub), amount);

        vm.mockCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector), abi.encode(uint256(0))
        );

        address utilQDrain = custody;
        vm.prank(address(vtsOrchestrator));
        ILiquidityHub(liquidityHub)
            .planCancelWithQueue(lccAddr, address(liquidityHub), address(positionManager), amount, amount, utilQDrain);

        vm.prank(address(liquidityHub));
        ILCC(lccAddr).transfer(address(positionManager), amount);

        assertEq(ILiquidityHub(liquidityHub).settleQueue(lccAddr, positionManager.custodianFor(victim)), amount);

        // Only `victim` has custodied LCC for this utility bucket; `user` has no beneficiary slice.
        vm.startPrank(address(positionManager));
        lcc0.transfer(custody, amount);
        IMMQueueCustodian(custody).record(0, lccAddr, victim, amount);
        vm.stopPrank();

        underlying.mint(address(liquidityHub), amount);
        vm.prank(address(vtsOrchestrator));
        ILiquidityHub(liquidityHub).confirmTake(lccAddr, amount, false);

        uint256 userUnderlyingBefore = underlying.balanceOf(user);
        uint256 victimCustodyBefore = IMMQueueCustodian(custody).queued(0, lccAddr, victim);

        MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](1);
        prepared[0] = MMA.prepareCollectAvailableLiquidity(lccAddr, 0, type(uint256).max);
        _executeWithUnlockAs(user, prepared, block.timestamp + 3600);

        assertEq(
            ILiquidityHub(liquidityHub).settleQueue(lccAddr, positionManager.custodianFor(victim)),
            amount,
            "queue owner unchanged (no release)"
        );
        assertEq(underlying.balanceOf(user), userUnderlyingBefore, "user must not receive underlying");
        assertEq(IMMQueueCustodian(custody).queued(0, lccAddr, victim), victimCustodyBefore, "victim slice intact");
    }

    /// @notice Paused MM remove with a starved vault must still call `LiquidityHub.planCancelWithQueue` and create Hub queue entries (regression: finding 4).
    /// @dev When `dryModifyLiquidities` returns zero, the entire MM `requiredSettlementDelta` is treated as shortfall, so `settleableDelta == 0` and
    ///      `OwnerCurrencyDelta.accountUnderlyingSettlementDelta` is not invoked — queue + `planCancelWithQueue` are still the critical invariants.
    ///      Calldata matches `FOUNDRY_PROFILE=debug forge test ... -vvvv` on `test_collectAvailableLiquidity_noSwap` (full decrease, starved vault).
    function test_pausedMMRemove_starvedVault_invokesPlanCancelWithQueue_andQueuesSettlement() public {
        vm.mockCall(
            marketFactory,
            abi.encodeWithSelector(IMarketFactory.bounds.selector, address(positionManager)),
            abi.encode(true)
        );

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

        (,, uint256 commitPositionCount,,) = positionManager.commitOf(tokenId);
        uint256 positionIndex = commitPositionCount - 1;

        vm.mockCall(
            address(mv),
            abi.encodeWithSelector(IMarketVaultDryBalanceDelta.dryModifyLiquidities.selector),
            abi.encode(toBalanceDelta(0, 0))
        );
        vm.mockCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector), abi.encode(uint256(0))
        );

        address locker = liquiditySignal.mmState.advancer;
        address queueOwner = positionManager.custodianFor(positionManager.ownerOf(tokenId));
        uint256 q0Before = ILiquidityHub(liquidityHub).settleQueue(Currency.unwrap(corePoolKey.currency0), queueOwner);
        uint256 q1Before = ILiquidityHub(liquidityHub).settleQueue(Currency.unwrap(corePoolKey.currency1), queueOwner);

        vtsOrchestrator.pausePool(corePoolKey.toId());

        uint256 principalPerSide = 29_953_549;
        uint256 queuePerSide = 5_999_710;

        vm.expectCall(
            liquidityHub,
            abi.encodeWithSelector(
                ILiquidityHub.planCancelWithQueue.selector,
                Currency.unwrap(corePoolKey.currency0),
                address(manager),
                address(positionManager),
                principalPerSide,
                queuePerSide,
                queueOwner
            )
        );
        vm.expectCall(
            liquidityHub,
            abi.encodeWithSelector(
                ILiquidityHub.planCancelWithQueue.selector,
                Currency.unwrap(corePoolKey.currency1),
                address(manager),
                address(positionManager),
                principalPerSide,
                queuePerSide,
                queueOwner
            )
        );

        uint256 amountToDecrease = uint256(liquidityParams.liquidityDelta);
        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](3);
        actions[0] = MMA.prepareDecrease(corePoolKey, tokenId, positionIndex, amountToDecrease);
        actions[1] = MMA.prepareTake(corePoolKey.currency0, locker, 0);
        actions[2] = MMA.prepareTake(corePoolKey.currency1, locker, 0);
        _executeWithUnlockLiquidity(actions, block.timestamp + 3600);

        assertGt(
            ILiquidityHub(liquidityHub).settleQueue(Currency.unwrap(corePoolKey.currency0), queueOwner),
            q0Before,
            "settleQueue token0 must grow after paused starved decrease"
        );
        assertGt(
            ILiquidityHub(liquidityHub).settleQueue(Currency.unwrap(corePoolKey.currency1), queueOwner),
            q1Before,
            "settleQueue token1 must grow after paused starved decrease"
        );
        assertEq(
            ILiquidityHub(liquidityHub).settleQueue(Currency.unwrap(corePoolKey.currency0), queueOwner),
            requiredSettlementAmount0,
            "token0 queued amount should match required settlement shortfall"
        );
        assertEq(
            ILiquidityHub(liquidityHub).settleQueue(Currency.unwrap(corePoolKey.currency1), queueOwner),
            requiredSettlementAmount1,
            "token1 queued amount should match required settlement shortfall"
        );
    }

    /// @notice Paused full MM remove (live vault) still stages `planCancelWithQueue`; combined with settle, MMPM underlying deltas can return to the pre-remove snapshot.
    /// @dev `OwnerCurrencyDelta.accountUnderlyingSettlementDelta` runs during the hook for non-zero `settleableDelta`; the follow-up `SETTLE` action nets locker/MMPM state.
    ///      We assert the hook path via `vm.expectCall` to `planCancelWithQueue` (queueAmount == 0) rather than requiring `getUnderlyingDeltaPair(MMPM)` to differ after a balanced settle batch.
    function test_pausedMMRemove_liveVault_invokesPlanCancelWithQueue() public {
        vm.mockCall(
            marketFactory,
            abi.encodeWithSelector(IMarketFactory.bounds.selector, address(positionManager)),
            abi.encode(true)
        );

        ModifyLiquidityParams memory liquidityParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(uint256(42))});

        (uint256 tokenId,, uint256 requiredSettlementAmount0, uint256 requiredSettlementAmount1) = _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            liquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        (,, uint256 commitPositionCount,,) = positionManager.commitOf(tokenId);
        uint256 positionIndex = commitPositionCount - 1;

        vtsOrchestrator.pausePool(corePoolKey.toId());

        uint256 principalPerSide = 29_953_549;
        uint256 queuePerSide = 0;
        address locker = liquiditySignal.mmState.advancer;
        address queueOwner = positionManager.custodianFor(positionManager.ownerOf(tokenId));

        vm.expectCall(
            liquidityHub,
            abi.encodeWithSelector(
                ILiquidityHub.planCancelWithQueue.selector,
                Currency.unwrap(corePoolKey.currency0),
                address(manager),
                address(positionManager),
                principalPerSide,
                queuePerSide,
                queueOwner
            )
        );
        vm.expectCall(
            liquidityHub,
            abi.encodeWithSelector(
                ILiquidityHub.planCancelWithQueue.selector,
                Currency.unwrap(corePoolKey.currency1),
                address(manager),
                address(positionManager),
                principalPerSide,
                queuePerSide,
                queueOwner
            )
        );

        uint256 amountToDecrease = uint256(liquidityParams.liquidityDelta);
        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](2);
        actions[0] = MMA.prepareDecrease(corePoolKey, tokenId, positionIndex, amountToDecrease);
        actions[1] = MMA.prepareSettle(
            corePoolKey,
            tokenId,
            positionIndex,
            requiredSettlementAmount0.toInt128(),
            requiredSettlementAmount1.toInt128(),
            false
        );
        _executeWithUnlockLiquidity(actions, block.timestamp + 3600);
    }

    /// @notice End-to-end regression for finding 4 using a real price-shaped one-sided remove.
    /// @dev Pushes the core price above the upper tick so a full remove returns token1 principal only, then starves
    ///      vault liquidity. Token0 therefore has no same-token principal available for queueing; its claim must
    ///      survive as an MMPositionManager underlying delta rather than being dropped.
    function test_priceShapedMMRemove_oneSidedPrincipal_preservesUnqueuedUnderlyingDelta() public {
        address locker = liquiditySignal.mmState.advancer;
        PriceShapedScenario memory scenario = _setupPriceShapedScenario();
        (uint256 settled0BeforeDecrease, uint256 settled1BeforeDecrease) = _settleShapedPositionForFullRemove(scenario);

        vm.mockCall(
            address(mv),
            abi.encodeWithSelector(
                IMarketVaultDryBalanceDelta.dryModifyLiquidities.selector,
                toBalanceDelta(SafeCast.toInt128(settled0BeforeDecrease), SafeCast.toInt128(settled1BeforeDecrease))
            ),
            abi.encode(toBalanceDelta(0, 0))
        );
        vm.mockCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector), abi.encode(uint256(0))
        );

        uint256 lockerUnderlying0Before = MockERC20(lcc0.underlying()).balanceOf(locker);

        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](4);
        actions[0] = MMA.prepareDecrease(corePoolKey, scenario.tokenId, scenario.positionIndex, 1e18);
        actions[1] = MMA.prepareSettle(
            corePoolKey, scenario.tokenId, scenario.positionIndex, SafeCast.toInt128(settled0BeforeDecrease), 0, false
        );
        actions[2] = MMA.prepareTake(Currency.wrap(address(lcc0)), locker, 0);
        actions[3] = MMA.prepareTake(Currency.wrap(address(lcc1)), locker, 0);
        _executeWithUnlockLiquidity(actions, block.timestamp + 3600);

        (uint256 settled0After, uint256 settled1After) = vtsOrchestrator.getPositionSettledAmounts(scenario.positionId);

        address queueOwner = positionManager.custodianFor(positionManager.ownerOf(scenario.tokenId));
        assertEq(
            ILiquidityHub(liquidityHub).settleQueue(address(lcc0), queueOwner),
            0,
            "token0 queue should stay zero when the remove returns no token0 principal"
        );
        assertGt(
            ILiquidityHub(liquidityHub).settleQueue(address(lcc1), queueOwner),
            0,
            "token1 shortfall should still queue against the one-sided returned principal"
        );
        assertEq(
            MockERC20(lcc0.underlying()).balanceOf(locker) - lockerUnderlying0Before,
            settled0BeforeDecrease,
            "token0 remainder should be recoverable via a follow-up settle instead of being lost"
        );
        assertEq(settled0After, 0, "token0 settled should be fully withdrawn by the follow-up settle");
        assertEq(settled1After, 0, "token1 settled should be fully removed once its shortfall is preserved via queue");
    }

    /// @notice Decommit must revert while inactive position(s) still hold live `pa.settled` (scan-16 finding 3).
    /// @dev Same price-shaped + starved-vault setup as `test_priceShapedMMRemove_oneSidedPrincipal_preservesUnqueuedUnderlyingDelta`,
    ///      but we omit the token0 settle that would drain live settled before decommit.
    function test_decommitSignal_revertsCommitNotDrained_whenInactiveSettledRemains() public {
        address locker = liquiditySignal.mmState.advancer;
        PriceShapedScenario memory scenario = _setupPriceShapedScenario();
        (uint256 settled0BeforeDecrease, uint256 settled1BeforeDecrease) = _settleShapedPositionForFullRemove(scenario);

        vm.mockCall(
            address(mv),
            abi.encodeWithSelector(
                IMarketVaultDryBalanceDelta.dryModifyLiquidities.selector,
                toBalanceDelta(SafeCast.toInt128(settled0BeforeDecrease), SafeCast.toInt128(settled1BeforeDecrease))
            ),
            abi.encode(toBalanceDelta(0, 0))
        );
        vm.mockCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector), abi.encode(uint256(0))
        );

        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](3);
        actions[0] = MMA.prepareDecrease(corePoolKey, scenario.tokenId, scenario.positionIndex, 1e18);
        actions[1] = MMA.prepareTake(Currency.wrap(address(lcc0)), locker, 0);
        actions[2] = MMA.prepareTake(Currency.wrap(address(lcc1)), locker, 0);
        _executeWithUnlockLiquidity(actions, block.timestamp + 3600);

        (uint256 live0, uint256 live1) = _getPositionLiveSettledAmounts(scenario.positionId);
        (uint256 s0, uint256 s1) = _getPositionEffectiveSettledAmounts(scenario.positionId);
        assertEq(live0 + live1, 0, "precondition: inactive remnant should sit outside live settled after decrease");
        assertGt(s0 + s1, 0, "precondition: inactive position retains effective settled until separately settled");

        (,,,, uint256 inactiveRemnantCount) = vtsOrchestrator.getCommit(scenario.tokenId);
        assertGt(inactiveRemnantCount, 0, "commit remnant counter must reflect inactive settled remainder");

        MMA.PreparedAction[] memory decommit = new MMA.PreparedAction[](1);
        decommit[0] = MMA.prepareDecommit(scenario.tokenId);
        vm.expectRevert(abi.encodeWithSelector(Errors.CommitNotDrained.selector, scenario.tokenId));
        _executeWithUnlockLiquidity(decommit, block.timestamp + 3600);
    }

    /// @notice After draining inactive live `settled`, decommit must succeed (finding #3 happy path).
    /// @dev External body avoids stack-too-deep in this dense scenario.
    function test_decommitSignal_succeeds_afterInactiveSettledRemnantsAreDrained() public {
        this._externalDecommitAfterDrainHappyPath();
    }

    function _externalDecommitAfterDrainHappyPath() external {
        address locker = liquiditySignal.mmState.advancer;
        PriceShapedScenario memory scenario = _setupPriceShapedScenario();
        (uint256 settled0BeforeDecrease, uint256 settled1BeforeDecrease) = _settleShapedPositionForFullRemove(scenario);
        uint256 scTokenId = scenario.tokenId;
        uint256 scPosIndex = scenario.positionIndex;
        PositionId scPosId = scenario.positionId;

        vm.mockCall(
            address(mv),
            abi.encodeWithSelector(
                IMarketVaultDryBalanceDelta.dryModifyLiquidities.selector,
                toBalanceDelta(SafeCast.toInt128(settled0BeforeDecrease), SafeCast.toInt128(settled1BeforeDecrease))
            ),
            abi.encode(toBalanceDelta(0, 0))
        );
        vm.mockCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector), abi.encode(uint256(0))
        );

        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](3);
        actions[0] = MMA.prepareDecrease(corePoolKey, scTokenId, scPosIndex, 1e18);
        actions[1] = MMA.prepareTake(Currency.wrap(address(lcc0)), locker, 0);
        actions[2] = MMA.prepareTake(Currency.wrap(address(lcc1)), locker, 0);
        _executeWithUnlockLiquidity(actions, block.timestamp + 3600);

        (uint256 live0, uint256 live1) = _getPositionLiveSettledAmounts(scPosId);
        (uint256 s0, uint256 s1) = _getPositionEffectiveSettledAmounts(scPosId);
        assertEq(live0 + live1, 0, "precondition: inactive remnant should sit outside live settled after decrease");
        assertGt(s0 + s1, 0, "precondition: inactive position retains effective settled until separately settled");

        assertGt(_inactiveRemnantCount(scTokenId), 0, "precondition: inactive remnant counter should be non-zero");
        _executeSettleAndAssertLockerUnderlyingGain(locker, scTokenId, scPosIndex, s0, s1);

        (uint256 s0After, uint256 s1After) = _getPositionEffectiveSettledAmounts(scPosId);
        assertEq(s0After + s1After, 0, "inactive settled should be fully drained");

        assertEq(
            _inactiveRemnantCount(scTokenId),
            0,
            "inactive remnant counter should return to zero when settled is drained"
        );

        // Commit-bucket custodied LCC (from decrease / unwrap-to-queue) must be collected before the NFT can burn.
        {
            uint256 topUp = 1e40;
            MockERC20 u0 = MockERC20(lcc0.underlying());
            MockERC20 u1 = MockERC20(lcc1.underlying());
            u0.mint(liquidityHub, topUp);
            u1.mint(liquidityHub, topUp);
            vm.prank(address(vtsOrchestrator));
            ILiquidityHub(liquidityHub).confirmTake(address(lcc0), topUp, false);
            vm.prank(address(vtsOrchestrator));
            ILiquidityHub(liquidityHub).confirmTake(address(lcc1), topUp, false);
        }

        MMA.PreparedAction[] memory collectCommit = new MMA.PreparedAction[](2);
        collectCommit[0] = MMA.prepareCollectAvailableLiquidity(address(lcc0), scTokenId, type(uint256).max);
        collectCommit[1] = MMA.prepareCollectAvailableLiquidity(address(lcc1), scTokenId, type(uint256).max);
        _executeWithUnlockLiquidity(collectCommit, block.timestamp + 3600);

        MMA.PreparedAction[] memory decommit = new MMA.PreparedAction[](1);
        decommit[0] = MMA.prepareDecommit(scTokenId);
        _executeWithUnlockLiquidity(decommit, block.timestamp + 3600);
        vm.expectRevert();
        positionManager.ownerOf(scTokenId);
    }

    /// @notice Inactive `pa.settled` remnants must remain withdrawable after commit expiry (SETTLE-03A / scan #27).
    function test_inactiveSettledRemnant_withdraw_succeeds_afterCommitExpired() public {
        this._externalInactiveRemnantDrainAfterExpiry();
    }

    function _externalInactiveRemnantDrainAfterExpiry() external {
        address locker = liquiditySignal.mmState.advancer;
        PriceShapedScenario memory scenario = _setupPriceShapedScenario();
        (uint256 settled0BeforeDecrease, uint256 settled1BeforeDecrease) = _settleShapedPositionForFullRemove(scenario);
        uint256 scTokenId = scenario.tokenId;
        uint256 scPosIndex = scenario.positionIndex;
        PositionId scPosId = scenario.positionId;

        vm.mockCall(
            address(mv),
            abi.encodeWithSelector(
                IMarketVaultDryBalanceDelta.dryModifyLiquidities.selector,
                toBalanceDelta(SafeCast.toInt128(settled0BeforeDecrease), SafeCast.toInt128(settled1BeforeDecrease))
            ),
            abi.encode(toBalanceDelta(0, 0))
        );
        vm.mockCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector), abi.encode(uint256(0))
        );

        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](3);
        actions[0] = MMA.prepareDecrease(corePoolKey, scTokenId, scPosIndex, 1e18);
        actions[1] = MMA.prepareTake(Currency.wrap(address(lcc0)), locker, 0);
        actions[2] = MMA.prepareTake(Currency.wrap(address(lcc1)), locker, 0);
        _executeWithUnlockLiquidity(actions, block.timestamp + 3600);

        (uint256 live0, uint256 live1) = _getPositionLiveSettledAmounts(scPosId);
        (uint256 s0, uint256 s1) = _getPositionEffectiveSettledAmounts(scPosId);
        assertEq(live0 + live1, 0, "precondition: inactive remnant should sit outside live settled after decrease");
        assertGt(s0 + s1, 0, "precondition: inactive position retains effective settled until separately settled");
        assertGt(_inactiveRemnantCount(scTokenId), 0, "precondition: inactive remnant counter should be non-zero");

        (, uint256 expiresAt,,,) = vtsOrchestrator.getCommit(scTokenId);
        vm.warp(expiresAt + 1);
        assertFalse(vtsOrchestrator.isSignalValid(scTokenId, true), "precondition: commit must be non-live after warp");

        _executeSettleAndAssertLockerUnderlyingGain(locker, scTokenId, scPosIndex, s0, s1);
        (uint256 s0After, uint256 s1After) = _getPositionEffectiveSettledAmounts(scPosId);
        assertEq(s0After + s1After, 0, "inactive settled should be fully drained after expiry");
        assertEq(_inactiveRemnantCount(scTokenId), 0, "inactive remnant counter should clear after drain");
    }

    /// @notice Active positions must still present a live signal for non-seizing deposits after commit expiry.
    function test_activePosition_settleDeposit_reverts_InvalidSignal_afterCommitExpired() public {
        vm.mockCall(
            marketFactory,
            abi.encodeWithSelector(IMarketFactory.bounds.selector, address(positionManager)),
            abi.encode(true)
        );

        ModifyLiquidityParams memory liquidityParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: bytes32(uint256(99))});

        (uint256 tokenId,,,) = _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            liquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        (, uint256 expiresAt,,,) = vtsOrchestrator.getCommit(tokenId);
        vm.warp(expiresAt + 1);
        assertFalse(vtsOrchestrator.isSignalValid(tokenId, true));

        address locker = liquiditySignal.mmState.advancer;
        int128 d0 = -1;
        int128 d1 = -1;
        MockERC20(lcc0.underlying()).mint(locker, 1);
        MockERC20(lcc1.underlying()).mint(locker, 1);
        vm.startPrank(locker);
        MockERC20(lcc0.underlying()).approve(address(positionManager), 1);
        MockERC20(lcc1.underlying()).approve(address(positionManager), 1);
        vm.stopPrank();

        MMA.PreparedAction[] memory settle = new MMA.PreparedAction[](1);
        settle[0] = MMA.prepareSettle(corePoolKey, tokenId, 0, d0, d1, false);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSignal.selector, tokenId));
        _executeWithUnlockLiquidity(settle, block.timestamp + 3600);
    }

    /// @notice `commitOf` must mirror `getCommit` on the orchestrator (including `inactiveRemnantCount`).
    function test_commitOf_matches_getCommit_allTupleFields() public {
        PriceShapedScenario memory scenario = _setupPriceShapedScenario();

        (MarketMaker.State memory mmG, uint256 expG, uint256 posG, uint256 actG, uint256 inactG) =
            vtsOrchestrator.getCommit(scenario.tokenId);
        (MarketMaker.State memory mmC, uint256 expC, uint256 posC, uint256 actC, uint256 inactC) =
            positionManager.commitOf(scenario.tokenId);

        assertEq(mmG.owner, mmC.owner);
        assertEq(expG, expC);
        assertEq(posG, posC);
        assertEq(actG, actC);
        assertEq(inactG, inactC);
    }

    /// @notice Mutation-killer: when `recipient == address(this)`, COLLECT_AVAILABLE_LIQUIDITY must sync underlying credit.
    /// @dev Practical tip: verify the sync by immediately doing a `TAKE(underlying)` to an external recipient.
    function test_collectAvailableLiquidity_noSwap() public {
        address recipient = liquiditySignal.mmState.advancer;
        address lcc0Addr = address(lcc0);
        MockERC20 underlying0 = MockERC20(lcc0.underlying());

        // Ensure MMPM is treated as protocol-bound (mirrors production deployment via MarketFactory initial bounds).
        vm.mockCall(
            marketFactory,
            abi.encodeWithSelector(IMarketFactory.bounds.selector, address(positionManager)),
            abi.encode(true)
        );

        uint256 lcc1BalanceBefore = Currency.wrap(address(lcc1)).balanceOfSelf();

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
            _scratchTokenId = tokenId;
            amount = requiredSettlementAmount0;

            (,, uint256 commitPositionCount,,) = positionManager.commitOf(tokenId);
            uint256 positionIndex = commitPositionCount - 1;

            // Allow `recipient` (locker) to call decrease on this position (only owner may approve).
            vm.prank(liquiditySignal.mmState.advancer);
            positionManager.approve(recipient, tokenId);

            // Force MarketVault to report zero available liquidity so cancellation must queue.
            vm.mockCall(
                address(mv),
                abi.encodeWithSelector(IMarketVaultDryBalanceDelta.dryModifyLiquidities.selector),
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

            _executeWithUnlockAs(recipient, setup, block.timestamp + 3600);
        }

        address commitCustodianNoSwap = positionManager.custodianFor(positionManager.ownerOf(_scratchTokenId));
        assertEq(
            ILiquidityHub(liquidityHub).settleQueue(lcc0Addr, address(positionManager)),
            0,
            "precondition: MMPM does NOT get assigned the queue"
        );
        assertEq(
            ILiquidityHub(liquidityHub).settleQueue(lcc0Addr, commitCustodianNoSwap),
            amount,
            "precondition: per-commit queue owner should have queued settlement after unwrap shortfall"
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
            prepared[0] = MMA.prepareCollectAvailableLiquidity(lcc0Addr, _scratchTokenId, type(uint256).max);

            _executeWithUnlockAs(recipient, prepared, block.timestamp + 3600);
        }

        uint256 lcc1BalanceAfter = Currency.wrap(address(lcc1)).balanceOfSelf();

        assertEq(
            underlying0.balanceOf(recipient) - recipientBefore,
            amount,
            "collect should settle to commit custodian then forward underlying to locker"
        );

        assertEq(lcc1BalanceAfter, lcc1BalanceBefore, "lcc1 balance should not change - no fees collected");
    }

    /// @notice Control case (no swap / no fees): queued principal is consumed by collect and there are no fee LCCs to take.
    function test_collectAvailableLiquidity_afterSwap() public {
        address recipient = liquiditySignal.mmState.advancer;
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
            _scratchTokenId = p.tokenId;
            (,, uint256 commitPositionCount,,) = positionManager.commitOf(p.tokenId);
            p.positionIndex = commitPositionCount - 1;

            _swapAccrueFeesViaSwap(underlying0, lcc0Addr, 1e18);

            {
                Currency lcc1Currency = Currency.wrap(lcc1Addr);
                lcc1BalanceBefore = lcc1Currency.balanceOfSelf();
            }

            recipientLcc0Before = IERC20(lcc0Addr).balanceOf(recipient);

            // Allow `recipient` (locker) to call decrease on this position (only owner may approve).
            vm.prank(liquiditySignal.mmState.advancer);
            positionManager.approve(recipient, p.tokenId);

            // Phase 1 (protocol prep, within unlock):
            // - SETTLE closes RFS so the position can be decreased.
            // - DECREASE triggers planCancelWithQueue and queues settlement for the locker (recipient).
            // - DECREASE credits the locker with only the *fee* slice of LCC inflows (queued principal is excluded by impl logic).
            // - We then TAKE that fee credit to `recipient` inside the same unlock session, ensuring no dangling deltas.
            p.recipient = recipient;
            p.lcc0Currency = Currency.wrap(lcc0Addr);
            p.amountToDecrease = 1e18; // matches liquidityDelta used in setup

            _afterSwapPhase1(p);
        }
        // Queued principal is an explicit Hub-backed entitlement; it should not remain as live `pa.settled`.
        address commitCustodianAfterSwap = positionManager.custodianFor(positionManager.ownerOf(_scratchTokenId));
        assertEq(
            ILiquidityHub(liquidityHub).settleQueue(lcc0Addr, address(positionManager)),
            0,
            "precondition: MMPM does NOT get assigned the queue"
        );
        amount = ILiquidityHub(liquidityHub).settleQueue(lcc0Addr, commitCustodianAfterSwap);
        assertGt(amount, 0, "precondition: commit queue owner should have queued settlement after unwrap shortfall");

        // Assert: fee LCC0 was takeable (non-zero) and did NOT drain the queued principal held by MMPM.
        recipientLcc0FeeAfterTake = IERC20(lcc0Addr).balanceOf(recipient) - recipientLcc0Before;
        assertGt(recipientLcc0FeeAfterTake, 0, "expected non-zero LCC0 fees to be takeable after swap");
        assertGe(
            IMMQueueCustodian(positionManager.custodianFor(positionManager.ownerOf(_scratchTokenId)))
                .queued(_scratchTokenId, lcc0Addr, recipient),
            amount,
            "custodian must still hold >= queued principal LCC0 after fee TAKE"
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
            prepared[0] = MMA.prepareCollectAvailableLiquidity(lcc0Addr, _scratchTokenId, type(uint256).max);

            _executeWithUnlockAs(recipient, prepared, block.timestamp + 3600);
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
            "collect should settle to commit custodian then forward underlying to locker"
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
        caller.transferFromWhileUnlocked(
            manager, positionManager, liquiditySignal.mmState.advancer, makeAddr("to"), tokenId
        );
    }

    function test_transferFrom_whenPoolManagerLocked_transfersOwnership() public {
        bytes memory liquiditySignalBytes = abi.encode(liquiditySignal);
        uint256 tokenId = positionManager.nextTokenId();

        MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](1);
        prepared[0] = MMA.prepareCommit(liquiditySignalBytes);
        _executeWithUnlockLiquidity(prepared, block.timestamp + 3600);

        address to = makeAddr("to");
        vm.prank(liquiditySignal.mmState.advancer);
        positionManager.transferFrom(liquiditySignal.mmState.advancer, to, tokenId);
        assertEq(
            positionManager.ownerOf(tokenId), to, "transferFrom should transfer ownership when PoolManager is locked"
        );
    }

    /// @notice Regression: transferring to an address that has never committed must deploy `custodianFor[to]` so
    /// queue-keyed paths (e.g. seizure, hook queue recipient) cannot revert with `QueueCustodianNotDeployed`.
    function test_transferFrom_deploysQueueCustodian_whenRecipientHasNoPriorCommit() public {
        bytes memory liquiditySignalBytes = abi.encode(liquiditySignal);
        uint256 tokenId = positionManager.nextTokenId();

        MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](1);
        prepared[0] = MMA.prepareCommit(liquiditySignalBytes);
        _executeWithUnlockLiquidity(prepared, block.timestamp + 3600);

        address freshRecipient = makeAddr("freshRecipientNoPriorCustodian");
        assertEq(
            positionManager.custodianFor(freshRecipient),
            address(0),
            "pre: recipient must not have a queue custodian yet"
        );

        vm.prank(liquiditySignal.mmState.advancer);
        positionManager.transferFrom(liquiditySignal.mmState.advancer, freshRecipient, tokenId);

        assertEq(positionManager.ownerOf(tokenId), freshRecipient);
        address cust = positionManager.custodianFor(freshRecipient);
        assertTrue(cust != address(0), "post: transfer must deploy queue custodian for recipient");
        assertTrue(cust.code.length > 0, "custodian must be a contract");
    }

    /*** INTERNAL FUNCTIONS FOR test_collectAvailableLiquidity_afterSwap ***/

    function _afterSwapPhase1(AfterSwapPhase1Params memory p) internal {
        // Force MarketVault to report zero available liquidity so cancellation must queue.
        vm.mockCall(
            address(mv),
            abi.encodeWithSelector(IMarketVaultDryBalanceDelta.dryModifyLiquidities.selector),
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

        // Fund exactly what we’re going to deposit for settlement (avoids underflow + avoids over-settling into a later withdrawal/queue).
        if (pay0 > 0) {
            MockERC20(lcc0.underlying()).mint(p.recipient, pay0);
            vm.prank(p.recipient);
            MockERC20(lcc0.underlying()).approve(address(positionManager), pay0);
        }
        if (pay1 > 0) {
            MockERC20(lcc1.underlying()).mint(p.recipient, pay1);
            vm.prank(p.recipient);
            MockERC20(lcc1.underlying()).approve(address(positionManager), pay1);
        }
        _executeWithUnlockAs(p.recipient, setup, block.timestamp + 3600);

        (uint256 settled0, uint256 settled1Out) = vtsOrchestrator.getPositionSettledAmounts(positionId);
        assertEq(settled0, 0, "full queued shortfall should leave no live settled token0");
        assertEq(settled1Out, 0, "full queued shortfall should leave no live settled token1");
    }

    function _setupPriceShapedScenario() internal returns (PriceShapedScenario memory scenario) {
        vm.mockCall(
            marketFactory,
            abi.encodeWithSelector(IMarketFactory.bounds.selector, address(positionManager)),
            abi.encode(true)
        );

        ModifyLiquidityParams memory liquidityParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: bytes32(uint256(77))});

        (
            scenario.tokenId,
            scenario.positionId,
            scenario.requiredSettlementAmount0,
            scenario.requiredSettlementAmount1
        ) =
            _setupCommittedPosition(
                positionManager,
                corePoolKey,
                abi.encode(liquiditySignal),
                liquidityParams,
                marketVTSConfiguration,
                address(lcc0),
                address(lcc1)
            );
        scenario.positionIndex = 0;

        int24 tickAfterSwap = _swapPushCorePriceAboveUpperViaToken1In(MockERC20(lcc1.underlying()), address(lcc1), 5e18);
        assertGt(tickAfterSwap, liquidityParams.tickUpper, "precondition: core price should move above the upper tick");
    }

    function _settleShapedPositionForFullRemove(PriceShapedScenario memory scenario)
        internal
        returns (uint256 settled0BeforeDecrease, uint256 settled1BeforeDecrease)
    {
        (bool rfsOpen, BalanceDelta rfsDelta) = vtsOrchestrator.calcRFS(scenario.positionId, false);
        assertTrue(rfsOpen, "precondition: shaped price move should open RFS");

        int128 settle0 = rfsDelta.amount0() > 0
            ? -rfsDelta.amount0() - SafeCast.toInt128(scenario.requiredSettlementAmount0)
            : int128(0);
        int128 settle1 = rfsDelta.amount1() > 0
            ? -rfsDelta.amount1() - SafeCast.toInt128(scenario.requiredSettlementAmount1)
            : int128(0);

        address locker = liquiditySignal.mmState.advancer;
        uint256 pay0 = LiquidityUtils.safeInt128ToUint256(settle0);
        uint256 pay1 = LiquidityUtils.safeInt128ToUint256(settle1);
        if (pay0 > 0) {
            MockERC20(lcc0.underlying()).mint(locker, pay0);
            vm.prank(locker);
            MockERC20(lcc0.underlying()).approve(address(positionManager), pay0);
        }
        if (pay1 > 0) {
            MockERC20(lcc1.underlying()).mint(locker, pay1);
            vm.prank(locker);
            MockERC20(lcc1.underlying()).approve(address(positionManager), pay1);
        }

        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](1);
        actions[0] = MMA.prepareSettle(corePoolKey, scenario.tokenId, scenario.positionIndex, settle0, settle1, false);
        _executeWithUnlockLiquidity(actions, block.timestamp + 3600);

        (settled0BeforeDecrease, settled1BeforeDecrease) =
            vtsOrchestrator.getPositionSettledAmounts(scenario.positionId);
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

    function _swapPushCorePriceAboveUpperViaToken1In(MockERC20 underlying1, address lcc1Addr, uint256 swapAmount)
        internal
        returns (int24 tickAfter)
    {
        underlying1.mint(address(this), swapAmount);
        underlying1.approve(address(liquidityHub), swapAmount);
        ILiquidityHub(liquidityHub).wrap(lcc1Addr, swapAmount);
        IERC20(lcc1Addr).approve(address(swapRouter), type(uint256).max);

        swapRouter.swap(
            corePoolKey,
            SwapParams({
                zeroForOne: false, amountSpecified: -int256(swapAmount), sqrtPriceLimitX96: ONE_FOR_ZERO_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        (, tickAfter,,) = manager.getSlot0(corePoolKey.toId());
    }

    function _setDirectSupply(address lcc, uint256 value) internal {
        uint256 slot = _store.target(liquidityHub).sig("directSupply(address)").with_key(lcc).find();
        vm.store(liquidityHub, bytes32(slot), bytes32(value));
    }

    /// @notice End-to-end: `DECREASE_LIQUIDITY` with impossible min-out reverts (Uniswap v4-style `SlippageCheck`).
    function test_mmDecrease_revertsWhenPrincipalMinOutUnreachable() public {
        address locker = liquiditySignal.mmState.advancer;
        (uint256 tokenId,,,) = _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: bytes32(0)}),
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );
        (,, uint256 positionCount,,) = positionManager.commitOf(tokenId);
        uint256 positionIndex = positionCount - 1;

        uint256 settlementAmount = 1_000_000e18;
        MockERC20(lcc0.underlying()).mint(locker, settlementAmount);
        MockERC20(lcc1.underlying()).mint(locker, settlementAmount);
        vm.startPrank(locker);
        MockERC20(lcc0.underlying()).approve(address(positionManager), settlementAmount);
        MockERC20(lcc1.underlying()).approve(address(positionManager), settlementAmount);
        vm.stopPrank();

        MMA.PreparedAction[] memory settleOnly = new MMA.PreparedAction[](1);
        settleOnly[0] = MMA.prepareSettle(
            corePoolKey,
            tokenId,
            positionIndex,
            -int128(int256(settlementAmount)),
            -int128(int256(settlementAmount)),
            false
        );
        _executeWithUnlockLiquidity(settleOnly, block.timestamp + 3600);

        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](1);
        actions[0] =
            MMA.prepareDecrease(corePoolKey, tokenId, positionIndex, 1000, type(uint128).max, type(uint128).max);
        vm.expectRevert();
        _executeWithUnlockLiquidity(actions, block.timestamp + 3600);
    }

    /// @notice End-to-end: same path as `test_mmDecrease_revertsWhenPrincipalMinOutUnreachable` but with loose min-out (Uni-like floor).
    function test_mmDecrease_succeedsWithLoosePrincipalMinOut() public {
        address locker = liquiditySignal.mmState.advancer;
        (uint256 tokenId,,,) = _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: bytes32(0)}),
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );
        (,, uint256 positionCount,,) = positionManager.commitOf(tokenId);
        uint256 positionIndex = positionCount - 1;

        uint256 settlementAmount = 1_000_000e18;
        MockERC20(lcc0.underlying()).mint(locker, settlementAmount);
        MockERC20(lcc1.underlying()).mint(locker, settlementAmount);
        vm.startPrank(locker);
        MockERC20(lcc0.underlying()).approve(address(positionManager), settlementAmount);
        MockERC20(lcc1.underlying()).approve(address(positionManager), settlementAmount);
        vm.stopPrank();

        MMA.PreparedAction[] memory settleOnly = new MMA.PreparedAction[](1);
        settleOnly[0] = MMA.prepareSettle(
            corePoolKey,
            tokenId,
            positionIndex,
            -int128(int256(settlementAmount)),
            -int128(int256(settlementAmount)),
            false
        );
        _executeWithUnlockLiquidity(settleOnly, block.timestamp + 3600);

        // Min-out floors are on actual per-leg forwarded commit custody (not hook principal); this fixture uses loose zeros.
        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](2);
        actions[0] = MMA.prepareDecrease(corePoolKey, tokenId, positionIndex, 1000, 0, 0);
        actions[1] = MMA.prepareSettleFromDeltas(corePoolKey, tokenId, positionIndex, true, true);
        _executeWithUnlockLiquidity(actions, block.timestamp + 3600);
    }
}

/// @notice Native-backed LCC + real `LiquidityHub` regressions (currency A underlying = ETH).
contract MMPositionManagerNativeEthRegressionTest is MarketTestBase, MarketMakerTestBase {
    using SafeCast for *;
    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;
    using MarketMaker for MarketMaker.State;
    using stdStorage for StdStorage;

    MMPositionManager internal positionManager;
    MarketVTSConfiguration internal marketVTSConfiguration;
    LiquidityCommitmentCertificate internal lccNative;
    LiquidityCommitmentCertificate internal lccErc20;

    StdStorage internal _store;

    function _deployCurrencyA() internal pure override returns (Currency currency) {
        return Currency.wrap(address(0));
    }

    function setUp() public {
        vm.deal(address(this), 20000 ether);
        _setupMarket();
        _setUpMM();

        positionManager = MMPositionManager(payable(mmPositionManager));
        _wireTestQueueCustodianFor(address(positionManager), liquiditySignal.mmState.advancer);
        _wireAllUtilityTestQueueCustodians(address(positionManager));

        ILCC _c2 = ILCC(payable(Currency.unwrap(_currency2)));
        ILCC _c3 = ILCC(payable(Currency.unwrap(_currency3)));
        if (_c2.underlying() == address(0)) {
            lccNative = LiquidityCommitmentCertificate(payable(address(_c2)));
            lccErc20 = LiquidityCommitmentCertificate(payable(address(_c3)));
        } else {
            lccNative = LiquidityCommitmentCertificate(payable(address(_c3)));
            lccErc20 = LiquidityCommitmentCertificate(payable(address(_c2)));
        }

        marketVTSConfiguration = vtsOrchestrator.getMarketVTSConfiguration(corePoolKey.toId());

        vm.mockCall(
            address(oracleHelper),
            abi.encodeWithSelector(IOracleHelper.getPricesForLccPair.selector),
            abi.encode(uint256(1), uint256(1))
        );
        vm.mockCall(
            address(oracleHelper), abi.encodeWithSelector(IOracleHelper.getTotalValue.selector), abi.encode(1e18)
        );
        {
            string[] memory tickers = new string[](2);
            tickers[0] = "BTC";
            tickers[1] = "USDT";
            uint256[] memory amounts = new uint256[](2);
            amounts[0] = 1e20;
            amounts[1] = 5e18;
            vm.mockCall(
                address(oracleHelper),
                abi.encodeWithSelector(IOracleHelper.getTotalValue.selector, tickers, amounts),
                abi.encode(1e18)
            );
        }

        vm.mockCall(
            marketFactory,
            abi.encodeWithSelector(IMarketFactory.bounds.selector, liquiditySignal.mmState.advancer),
            abi.encode(true)
        );
        vm.mockCall(
            marketFactory,
            abi.encodeWithSelector(IMarketFactory.bounds.selector, renewSignal.mmState.advancer),
            abi.encode(true)
        );

        _permitMMPMForNativeFixture(liquiditySignal.mmState.advancer);
        _permitMMPMForNativeFixture(renewSignal.mmState.advancer);
    }

    function _permitMMPMForNativeFixture(address adv) internal {
        address uE = lccErc20.underlying();
        vm.deal(adv, 1e22);
        if (uE != address(0)) {
            deal(uE, adv, 1e40);
        }
        vm.startPrank(adv);
        IERC20(address(lccNative)).approve(address(permit2), type(uint256).max);
        IERC20(address(lccErc20)).approve(address(permit2), type(uint256).max);
        if (uE != address(0)) {
            IERC20(uE).approve(address(permit2), type(uint256).max);
        }
        IAllowanceTransfer(permit2)
            .approve(address(lccNative), address(positionManager), type(uint160).max, type(uint48).max);
        IAllowanceTransfer(permit2)
            .approve(address(lccErc20), address(positionManager), type(uint160).max, type(uint48).max);
        if (uE != address(0)) {
            IAllowanceTransfer(permit2).approve(uE, address(positionManager), type(uint160).max, type(uint48).max);
        }
        vm.stopPrank();
    }

    function _executeLiquidityAs(address who, MMA.PreparedAction[] memory prepared) internal {
        vm.prank(who);
        MMA.execute(positionManager, prepared);
    }

    function _setDirectSupply(address lcc, uint256 value) internal {
        uint256 slot = _store.target(liquidityHub).sig("directSupply(address)").with_key(lcc).find();
        vm.store(liquidityHub, bytes32(slot), bytes32(value));
    }

    /// @notice Native unwrap shortfall: Hub queue and MM queue custodian stay aligned after credit-first native payout.
    function test_native_unwrap_fromDeltas_shortfall_settleQueue_aligns_queueCustodian() public {
        address locker = makeAddr("lockerNativeShortfallAlign");
        address lccAddr = address(lccNative);
        uint256 amount = 300;

        vm.prank(marketFactory);
        ILiquidityHub(liquidityHub).setBoundLevel(address(positionManager), Bounds.BOUND_ENDPOINT);

        // `confirmTake` bumps native market-derived reserves; fund the Hub ETH balance to satisfy the post-check.
        vm.deal(liquidityHub, liquidityHub.balance + amount);
        vm.prank(address(vtsOrchestrator));
        ILiquidityHub(liquidityHub).confirmTake(lccAddr, amount, false);

        _setDirectSupply(lccAddr, 0);

        lccNative.transfer(liquidityHub, amount);
        vm.prank(liquidityHub);
        lccNative.transfer(address(positionManager), amount);

        (uint256 wBal, uint256 mBal) = lccNative.balancesOf(address(positionManager));
        assertEq(wBal, 0);
        assertEq(mBal, amount);

        vm.mockCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector), abi.encode(uint256(0))
        );

        MMA.PreparedAction[] memory unwrapBatch = new MMA.PreparedAction[](2);
        unwrapBatch[0] = MMA.prepareSync(Currency.wrap(lccAddr));
        unwrapBatch[1] = MMA.prepareUnwrapLcc(lccAddr, amount, locker, false);

        _executeLiquidityAs(locker, unwrapBatch);

        assertEq(ILiquidityHub(liquidityHub).settleQueue(lccAddr, positionManager.custodianFor(locker)), amount);
        assertEq(lccNative.balanceOf(address(positionManager)), 0);
        assertEq(IMMQueueCustodian(positionManager.custodianFor(locker)).queued(0, lccAddr, locker), amount);
    }

    /// @notice Native analogue of `test_unwrapLcc_payerIsUser_shortfall_attackerSyncTake_doesNotStealCustodiedLcc`.
    function test_native_unwrap_payerIsUser_shortfall_attackerSyncTake_doesNotStealCustodiedLcc() public {
        address victim = makeAddr("victimNativeSyncTake");
        address attacker = makeAddr("attackerNativeSyncTake");
        address lccAddr = address(lccNative);
        uint256 amount = 200;

        vm.prank(marketFactory);
        ILiquidityHub(liquidityHub).setBoundLevel(address(positionManager), Bounds.BOUND_ENDPOINT);

        vm.mockCall(marketFactory, abi.encodeWithSelector(IMarketFactory.bounds.selector, victim), abi.encode(false));

        vm.deal(liquidityHub, liquidityHub.balance + amount);
        vm.prank(address(vtsOrchestrator));
        ILiquidityHub(liquidityHub).confirmTake(lccAddr, amount, false);

        _setDirectSupply(lccAddr, 0);

        lccNative.transfer(liquidityHub, amount);
        vm.prank(liquidityHub);
        lccNative.transfer(victim, amount);

        vm.startPrank(victim);
        lccNative.approve(address(positionManager), type(uint256).max);
        vm.stopPrank();

        vm.mockCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector), abi.encode(uint256(0))
        );

        vm.prank(victim);
        MMA.unwrapLcc(positionManager, lccAddr, amount, victim, true);

        assertEq(ILiquidityHub(liquidityHub).settleQueue(lccAddr, positionManager.custodianFor(victim)), amount);
        assertEq(lccNative.balanceOf(address(positionManager)), 0);
        assertEq(IMMQueueCustodian(positionManager.custodianFor(victim)).queued(0, lccAddr, victim), amount);

        uint256 attackerLccBefore = lccNative.balanceOf(attacker);
        MMA.PreparedAction[] memory steal = new MMA.PreparedAction[](2);
        steal[0] = MMA.prepareSync(Currency.wrap(lccAddr));
        steal[1] = MMA.prepareTake(Currency.wrap(lccAddr), attacker, 0);
        _executeLiquidityAs(attacker, steal);

        assertEq(lccNative.balanceOf(attacker), attackerLccBefore, "attacker must not take victim custodied LCC");
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
            targetMmpm.checkpoint(tokenId, positionIndex, false);
        }
        if (doTransferFrom) {
            targetMmpm.transferFrom(transferFromFrom, transferFromTo, tokenId);
        }
        return "";
    }
}

/// @dev Payable contract that acts as batch locker and counts `receive()` invocations (native payout ordering).
contract PayableLockerUnwrapHelper {
    uint256 public ethReceiveCalls;

    receive() external payable {
        ethReceiveCalls++;
    }

    function execute(MMPositionManager mmpm, bytes memory actions, bytes[] memory params) external {
        mmpm.modifyLiquiditiesWithoutUnlock(actions, params);
    }
}

/// @dev On each ETH receive, attempts `LCC.transfer(hub, 1)` when the locker holds LCC (annul / protocol-bound path).
contract PayableLockerMaliciousLccTransfer {
    uint256 public ethReceiveCalls;
    address public immutable lcc;
    address public immutable hub;

    constructor(address _lcc, address _hub) {
        lcc = _lcc;
        hub = _hub;
    }

    receive() external payable {
        ethReceiveCalls++;
        // Attempt a protocol-bound transfer on ETH receipt (annul / queue hooks on the real Hub). With `vm.etch` Hub
        // mocks this may revert; swallow so the regression still isolates native payout ordering vs `TAKE`.
        if (IERC20(lcc).balanceOf(address(this)) != 0) {
            try IERC20(lcc).transfer(hub, 1) returns (bool) {} catch {}
        }
    }

    function execute(MMPositionManager mmpm, bytes memory actions, bytes[] memory params) external {
        mmpm.modifyLiquiditiesWithoutUnlock(actions, params);
    }
}

/// @dev Minimal Hub stub for native payout tests: after `vm.etch`, LCC transfers still call Hub hooks (`boundLevels`, etc.).
contract MockNativeUnwrapHubPayer {
    receive() external payable {}

    function isFactory(address) external pure returns (bool) {
        return true;
    }

    function boundLevel(address, address) external pure returns (uint8) {
        return Bounds.BOUND_ENDPOINT;
    }

    function boundLevels(address, address, address) external pure returns (uint8, uint8) {
        return (Bounds.BOUND_ENDPOINT, Bounds.BOUND_ENDPOINT);
    }

    function annulSettlementBeforeTransfer(address, uint256, uint256, uint256) external {}

    function executePlannedCancel(address, address) external {}

    /// @dev `MMPositionManager` reads queue delta around Hub `unwrap`; return zero so no custody forward is attempted.
    function settleQueue(address, address) external pure returns (uint256) {
        return 0;
    }

    function unwrap(address, uint256) external {
        (bool ok,) = payable(msg.sender).call{value: 1 ether}("");
        require(ok, "native payout failed");
    }
}
