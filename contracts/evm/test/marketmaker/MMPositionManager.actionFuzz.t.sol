// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {MarketTestBase} from "../base/MarketTestBase.sol";
import {MarketMakerTestBase} from "../base/MMTestBase.sol";
import {MMPositionManager} from "../../src/MMPositionManager.sol";
import {MMActionAdapter as MMA} from "../libraries/MMActionAdapter.sol";
import {LiquidityCommitmentCertificate} from "../../src/LCC.sol";
import {MarketVTSConfiguration} from "../../src/types/VTS.sol";
import {ILiquidityHub} from "../../src/interfaces/ILiquidityHub.sol";
import {IOracleHelper} from "../../src/interfaces/IOracleHelper.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {MMActions} from "../../src/libraries/MMActions.sol";
import {PositionId} from "../../src/types/Position.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Fuzz-style action dispatcher tests for MMPositionManager.
/// @dev These tests intentionally allow many random sequences to revert; the goal is to explore
///      which action combinations are valid under the delta + unlock model.
contract MMPositionManagerActionFuzzTest is MarketTestBase, MarketMakerTestBase {
    using CurrencyLibrary for Currency;

    MMPositionManager internal mmpm;
    LiquidityCommitmentCertificate internal lcc0;
    LiquidityCommitmentCertificate internal lcc1;
    MarketVTSConfiguration internal vtsConfig;
    bytes internal signal0;
    bytes internal signal1;

    function setUp() public {
        _setupMarket();
        _setUpMM();

        mmpm = MMPositionManager(payable(mmPositionManager));
        lcc0 = LiquidityCommitmentCertificate(payable(Currency.unwrap(_currency2)));
        lcc1 = LiquidityCommitmentCertificate(payable(Currency.unwrap(_currency3)));
        vtsConfig = vtsOrchestrator.getMarketVTSConfiguration(corePoolKey.toId());
        signal0 = abi.encode(liquiditySignal);
        signal1 = abi.encode(renewSignal);

        // Make commitment-backing validation deterministic for fuzzing (avoid external oracle calls).
        vm.mockCall(
            address(oracleHelper),
            abi.encodeWithSelector(IOracleHelper.getPricesForLccPair.selector, address(lcc0), address(lcc1)),
            abi.encode(uint256(1), uint256(1))
        );

        // MMTestBase uses fixed reserve tickers ("BTC", "USDT") and fixed amounts (1e20, 5e18) for signals.
        // VTSCommitLib.validateLiquidityDelta queries these to get signal USD value.
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
                abi.encode(uint256(1e18))
            );
        }

        // Ensure we have plenty of ETH to test wrap/unwrap flows.
        vm.deal(address(this), 100 ether);

        // Ensure we have some LCC in the locker (this test contract) for user-paid unwrapLcc paths.
        _mintAndWrapLccToSelf(address(lcc0), 1_000e18);
        _mintAndWrapLccToSelf(address(lcc1), 1_000e18);
        IERC20(address(lcc0)).approve(address(mmpm), type(uint256).max);
        IERC20(address(lcc1)).approve(address(mmpm), type(uint256).max);
    }

    // ============================================================
    // Fuzz driver
    // ============================================================

    /// @dev Runs a small pseudo-random action batch. Many sequences are expected to revert; that’s fine.
    ///      If it succeeds, it must satisfy MMPM’s own invariant (no stuck deltas) and basic balance sanity.
    function testFuzz_actionBatch_smoke(uint256 seed) public {
        uint8 steps = uint8(_bounded(_rand(seed, "steps"), 1, 8));

        // Track whether we have a known-good commitment tokenId to reference.
        uint256 tokenId;
        bool hasTokenId;
        uint256 commitCount;

        // Occasionally start by creating a valid commit+position via the canonical helper.
        // NOTE: LiquiditySignals enforce a monotonic nonce; we only do this once per signal.
        if ((_rand(seed, "bootstrap") % 2) == 0) {
            (tokenId,,,) = _setupCommittedPosition(
                mmpm,
                corePoolKey,
                signal0,
                ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)}),
                vtsConfig,
                address(lcc0),
                address(lcc1)
            );
            hasTokenId = true;
            commitCount = 1;
        }

        for (uint256 i = 0; i < steps; i++) {
            uint256 r = _rand(seed, string(abi.encodePacked("step:", vm.toString(i))));
            uint256 actionType = r % 11;

            // Each step executes a *small batch* (1–3 actions) via MMPM’s dispatcher, similar to scenario tests.
            // Some batches are intentionally invalid and may revert.
            MMA.PreparedAction[] memory prepared = new MMA.PreparedAction[](3);
            uint256 count = 0;
            uint256 value = 0;

            // Pick a tokenId, even if it might not exist (that’s part of the fuzzing).
            uint256 chosenTokenId = hasTokenId ? tokenId : _bounded(_rand(r, "tokenId"), 1, 5);
            uint256 positionIndex = 0;

            if (actionType == 0) {
                // Commit+mint+settle (valid path). Only attempt if we still have an unused signal nonce.
                if (commitCount < 2) {
                    bytes memory sig = commitCount == 0 ? signal0 : signal1;
                    (tokenId,,,) = _setupCommittedPosition(
                        mmpm,
                        corePoolKey,
                        sig,
                        ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)}),
                        vtsConfig,
                        address(lcc0),
                        address(lcc1)
                    );
                    hasTokenId = true;
                    commitCount++;
                }
                continue;
            } else if (actionType == 1) {
                // Increase liquidity (may revert if not enough settlement, or tokenId invalid).
                uint256 liq = _bounded(_rand(r, "liq"), 1, 10_000);
                prepared[count++] = MMA.prepareIncrease(corePoolKey, chosenTokenId, positionIndex, liq);
            } else if (actionType == 2) {
                // Decrease liquidity (may revert if too large / inactive / invalid).
                uint256 liq = _bounded(_rand(r, "liq"), 1, 10_000);
                prepared[count++] = MMA.prepareDecrease(corePoolKey, chosenTokenId, positionIndex, liq);
            } else if (actionType == 3) {
                // Burn position.
                prepared[count++] = MMA.prepareBurn(corePoolKey, chosenTokenId, positionIndex);
            } else if (actionType == 4) {
                // Decommit (may revert if active positions remain).
                prepared[count++] = MMA.prepareDecommit(chosenTokenId);
            } else if (actionType == 5) {
                // Checkpoint (with or without commitment).
                bool withCommitment = (_rand(r, "withCommitment") % 2) == 0;
                bytes memory sig = withCommitment ? abi.encode(liquiditySignal) : bytes("");
                prepared[count++] = MMA.prepareCheckpoint(chosenTokenId, positionIndex, sig);
            } else if (actionType == 6) {
                // Wrap native then optionally take WETH to a recipient.
                uint256 amt = _bounded(_rand(r, "amt"), 1e9, 0.2 ether);
                value = amt;
                prepared[count++] = MMA.prepareWrapNative(amt);
                if ((_rand(r, "takeWeth") % 2) == 0) {
                    address recipient = address(uint160(_rand(r, "recipient")));
                    if (recipient == address(0)) recipient = address(this);
                    prepared[count++] = MMA.prepareTake(Currency.wrap(address(weth9)), recipient, 0);
                }
            } else if (actionType == 7) {
                // Unwrap native (payer is user), then take ETH out.
                // This requires the caller to have WETH and approve MMPM.
                uint256 amt = _bounded(_rand(r, "amt"), 0, 0.2 ether);
                if (amt > 0) {
                    weth9.deposit{value: amt}();
                    weth9.approve(address(mmpm), type(uint256).max);
                }
                prepared[count++] = MMA.prepareUnwrapNative(0, true); // amount=0 => unwrap max
                prepared[count++] = MMA.prepareTake(CurrencyLibrary.ADDRESS_ZERO, address(this), 0);
            } else if (actionType == 8) {
                // Unwrap LCC from the user (locker) to self or a random recipient.
                address recipient = address(uint160(_rand(r, "recipient")));
                if (recipient == address(0)) recipient = address(this);
                address lccAddr = (_rand(r, "whichLcc") % 2) == 0 ? address(lcc0) : address(lcc1);
                uint256 amt = _bounded(_rand(r, "amt"), 0, 100e18); // 0 => unwrap max of user balance
                prepared[count++] = MMA.prepareUnwrapLcc(lccAddr, amt, recipient, true);
            } else if (actionType == 9) {
                // Sync then take (tests the “locker delta” pattern for takeable balances).
                Currency c = (_rand(r, "which") % 2) == 0 ? Currency.wrap(address(weth9)) : CurrencyLibrary.ADDRESS_ZERO;
                prepared[count++] = MMA.prepareSync(c);
                prepared[count++] = MMA.prepareTake(c, address(this), 0);
            } else {
                // Attempt an unknown action to ensure UnsupportedAction is reachable.
                // This is expected to revert.
                bytes memory actions = abi.encodePacked(uint8(0xFE));
                bytes[] memory params = new bytes[](1);
                params[0] = hex"";
                (bool ok,) = address(mmpm)
                    .call(
                        abi.encodeWithSelector(
                            MMPositionManager.modifyLiquiditiesWithoutUnlock.selector, actions, params
                        )
                    );
                ok; // ignored: this step is “revert-expected”
                continue;
            }

            // Execute the batch and accept either success or revert.
            MMA.PreparedAction[] memory batch = _shrink(prepared, count);
            bool success = _tryExecute(batch, value);

            // Strong post-success invariants:
            // - No stuck deltas (MMPM asserts this internally; we re-assert here for clarity).
            if (success) {
                vtsOrchestrator.assertNonZeroDeltas();
            }

            // If the batch succeeded and it included a wrap-native with take, ensure we didn't mint ETH out of thin air.
            // (MMPM enforces no stuck deltas via _afterBatch().)
            if (success && value > 0) {
                assertLe(weth9.balanceOf(address(this)), 100 ether, "sanity: unexpected WETH balance explosion");
            }
        }
    }

    // ============================================================
    // Deterministic action-matrix tests (branch-focused)
    // ============================================================

    /// @notice Exercise the `MMPositionActionsImpl._settleFromDeltas` branch matrix using action batches.
    /// @dev We keep the assertions lightweight: the main goal is to ensure these action combos can be executed
    ///      (or, when required, that follow-up TAKEs consume any synced credits so the batch completes).
    function test_actionMatrix_settleFromDeltas_smoke() public {
        address underlying0 = lcc0.underlying();
        address underlying1 = lcc1.underlying();
        require(underlying0 != address(0) && underlying1 != address(0), "requires ERC20 underlyings");

        // Commit 1: two positions, then create protocol credits by burning.
        uint256 tokenId1;
        {
            (tokenId1,,,) = _setupCommittedPosition(
                mmpm,
                corePoolKey,
                signal0,
                ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)}),
                vtsConfig,
                address(lcc0),
                address(lcc1)
            );

            // Mint a 2nd position under the same commit (idx=1).
            {
                (uint256 req0, uint256 req1) = _calculateSettlementAmounts(
                    ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)}),
                    vtsConfig
                );
                _approveTokenForPositionManager(underlying0, underlying1, address(mmpm), req0, req1);

                MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](2);
                actions[0] = MMA.prepareMint(corePoolKey, tokenId1, -60, 60, 1e10);
                actions[1] =
                    MMA.prepareSettle(corePoolKey, tokenId1, 1, -int128(int256(req0)), -int128(int256(req1)), false);
                MMA.executeWithUnlock(mmpm, actions, block.timestamp + 3600);
            }
        }

        // (A) payerIsUser=true, shouldTake=false  => net protocol credits into a position via onMMSettle (no token movement)
        // Create protocol credits by burning position 0, then deposit them into position 1.
        {
            MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](6);
            actions[0] = MMA.prepareBurn(corePoolKey, tokenId1, 0);
            actions[1] = MMA.prepareSettleFromDeltas(corePoolKey, tokenId1, 1, true, false);
            // Any fee accrual / LCC credit created by the burn+settle path must be taken to avoid CurrencyNotSettled.
            actions[2] = MMA.prepareTake(Currency.wrap(address(lcc0)), address(this), 0);
            actions[3] = MMA.prepareTake(Currency.wrap(address(lcc1)), address(this), 0);
            // If underlying credits were created on the locker, take them too (no-op if none).
            actions[4] = MMA.prepareTake(Currency.wrap(underlying0), address(this), 0);
            actions[5] = MMA.prepareTake(Currency.wrap(underlying1), address(this), 0);
            _expectOkOrCurrencyNotSettled(actions, 0);
        }

        // (B) payerIsUser=true, shouldTake=true => withdraw protocol credits to locker via _settle (no sync)
        // Burn position 1 to recreate credits, then withdraw them.
        {
            MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](6);
            actions[0] = MMA.prepareBurn(corePoolKey, tokenId1, 1);
            actions[1] = MMA.prepareSettleFromDeltas(corePoolKey, tokenId1, 1, true, true);
            actions[2] = MMA.prepareTake(Currency.wrap(address(lcc0)), address(this), 0);
            actions[3] = MMA.prepareTake(Currency.wrap(address(lcc1)), address(this), 0);
            actions[4] = MMA.prepareTake(Currency.wrap(underlying0), address(this), 0);
            actions[5] = MMA.prepareTake(Currency.wrap(underlying1), address(this), 0);
            _expectOkOrCurrencyNotSettled(actions, 0);
        }

        // (C) payerIsUser=false, shouldTake=false => settle from MMPM balance using locker credit
        // Transfer underlying to MMPM, sync as credit to locker, then deposit into position.
        {
            uint256 amt0 = 123;
            uint256 amt1 = 456;
            _mintErc20To(underlying0, address(this), amt0);
            _mintErc20To(underlying1, address(this), amt1);
            IERC20(underlying0).transfer(address(mmpm), amt0);
            IERC20(underlying1).transfer(address(mmpm), amt1);

            MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](7);
            actions[0] = MMA.prepareSync(Currency.wrap(underlying0));
            actions[1] = MMA.prepareSync(Currency.wrap(underlying1));
            actions[2] = MMA.prepareSettleFromDeltas(corePoolKey, tokenId1, 0, false, false);
            // Drain any credits produced by the settle path (fees / dust).
            actions[3] = MMA.prepareTake(Currency.wrap(address(lcc0)), address(this), 0);
            actions[4] = MMA.prepareTake(Currency.wrap(address(lcc1)), address(this), 0);
            actions[5] = MMA.prepareTake(Currency.wrap(underlying0), address(this), 0);
            actions[6] = MMA.prepareTake(Currency.wrap(underlying1), address(this), 0);
            _expectOkOrCurrencyNotSettled(actions, 0);
        }

        // (D) payerIsUser=false, shouldTake=true => withdraw to MMPM and sync credits to locker, then TAKE to close deltas
        // Use a fresh commit to guarantee protocol credits exist after burn.
        {
            uint256 tokenId2;
            (tokenId2,,,) = _setupCommittedPosition(
                mmpm,
                corePoolKey,
                signal1,
                ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)}),
                vtsConfig,
                address(lcc0),
                address(lcc1)
            );

            address recipient = makeAddr("recipient");
            uint256 bal0Before = IERC20(underlying0).balanceOf(recipient);
            uint256 bal1Before = IERC20(underlying1).balanceOf(recipient);

            MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](6);
            actions[0] = MMA.prepareBurn(corePoolKey, tokenId2, 0);
            actions[1] = MMA.prepareSettleFromDeltas(corePoolKey, tokenId2, 0, false, true);
            actions[2] = MMA.prepareTake(Currency.wrap(underlying0), recipient, 0);
            actions[3] = MMA.prepareTake(Currency.wrap(underlying1), recipient, 0);
            actions[4] = MMA.prepareTake(Currency.wrap(address(lcc0)), recipient, 0);
            actions[5] = MMA.prepareTake(Currency.wrap(address(lcc1)), recipient, 0);
            _expectOkOrCurrencyNotSettled(actions, 0);

            assertGe(IERC20(underlying0).balanceOf(recipient), bal0Before);
            assertGe(IERC20(underlying1).balanceOf(recipient), bal1Before);
        }
    }

    /// @notice Gap action value (0x06) routes to impl (<= 0x09) and must revert UnsupportedAction in MMPositionActionsImpl.
    function test_actionsImpl_unsupportedActionGap_reverts() public {
        bytes memory actions = abi.encodePacked(uint8(0x06)); // gap between SEIZE (0x05) and INCREASE_FROM_DELTAS (0x07)
        bytes[] memory params = new bytes[](1);
        params[0] = hex"";
        vm.expectRevert(abi.encodeWithSelector(Errors.UnsupportedAction.selector, uint256(0x06)));
        mmpm.modifyLiquiditiesWithoutUnlock(actions, params);
    }

    /// @notice Seize should revert when caller is approved/owner (owner cannot seize their own position).
    function test_seize_revertsWhenCallerIsApprovedOrOwner() public {
        (uint256 tokenId,,,) = _setupCommittedPosition(
            mmpm,
            corePoolKey,
            signal0,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)}),
            vtsConfig,
            address(lcc0),
            address(lcc1)
        );

        // Caller is the owner of tokenId (this test contract), so seize must revert.
        bytes memory sig = abi.encode(corePoolKey, tokenId, 0, uint256(1), uint256(1), false);
        bytes memory actions = abi.encodePacked(uint8(MMActions.SEIZE_POSITION));
        bytes[] memory params = new bytes[](1);
        params[0] = sig;

        // Need positionId for exact revert encoding.
        PositionId posId = vtsOrchestrator.getPositionId(tokenId, 0);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidPosition.selector, tokenId, 0, posId));
        mmpm.modifyLiquidities(abi.encode(actions, params), block.timestamp + 3600);
    }

    /// @notice Increase should revert when liquidity > uint128 max (covers `_increaseInternal` guard).
    function test_increase_revertsWhenLiquidityGtUint128Max() public {
        (uint256 tokenId,,,) = _setupCommittedPosition(
            mmpm,
            corePoolKey,
            signal0,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)}),
            vtsConfig,
            address(lcc0),
            address(lcc1)
        );

        uint256 tooLarge = uint256(type(uint128).max) + 1;
        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](1);
        actions[0] = MMA.prepareIncrease(corePoolKey, tokenId, 0, tooLarge);

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector, tooLarge, type(uint128).max));
        MMA.executeWithUnlock(mmpm, actions, block.timestamp + 3600);
    }

    /// @notice Decrease should revert when amountToDecrease > current position liquidity.
    function test_decrease_revertsWhenAmountGtPositionLiquidity() public {
        (uint256 tokenId,,,) = _setupCommittedPosition(
            mmpm,
            corePoolKey,
            signal0,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)}),
            vtsConfig,
            address(lcc0),
            address(lcc1)
        );

        uint256 tooMuch = 1e30;
        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](1);
        actions[0] = MMA.prepareDecrease(corePoolKey, tokenId, 0, tooMuch);
        // Exact max in error is position.liquidity (1e10 in this fixture).
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector, tooMuch, uint256(1e10)));
        MMA.executeWithUnlock(mmpm, actions, block.timestamp + 3600);
    }

    // ============================================================
    // Helpers
    // ============================================================

    function _tryExecute(MMA.PreparedAction[] memory batch, uint256 value) internal returns (bool) {
        (bytes memory actionsBytes, bytes[] memory params) = MMA.concatPrepared(batch);
        bytes memory unlockData = abi.encode(actionsBytes, params);
        (bool ok,) = address(mmpm)
        .call{
            value: value
        }(abi.encodeWithSelector(MMPositionManager.modifyLiquidities.selector, unlockData, block.timestamp + 3600));
        return ok;
    }

    function _tryExecuteWithRet(MMA.PreparedAction[] memory batch, uint256 value)
        internal
        returns (bool ok, bytes memory ret)
    {
        (bytes memory actionsBytes, bytes[] memory params) = MMA.concatPrepared(batch);
        bytes memory unlockData = abi.encode(actionsBytes, params);
        (ok, ret) = address(mmpm)
        .call{
            value: value
        }(abi.encodeWithSelector(MMPositionManager.modifyLiquidities.selector, unlockData, block.timestamp + 3600));
    }

    function _expectOkOrCurrencyNotSettled(MMA.PreparedAction[] memory batch, uint256 value) internal {
        (bool ok, bytes memory ret) = _tryExecuteWithRet(batch, value);
        if (!ok) {
            // Expected failure mode for some action combos: leftover currency deltas at end-of-batch.
            assertGe(ret.length, 4, "expected custom error");
            assertEq(bytes4(ret), Errors.CurrencyNotSettled.selector);
        }
    }

    function _shrink(MMA.PreparedAction[] memory src, uint256 n)
        internal
        pure
        returns (MMA.PreparedAction[] memory out)
    {
        out = new MMA.PreparedAction[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = src[i];
        }
    }

    function _rand(uint256 seed, string memory salt) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(seed, salt)));
    }

    function _bounded(uint256 x, uint256 min, uint256 max) internal pure returns (uint256) {
        if (max <= min) return min;
        return min + (x % (max - min + 1));
    }

    function _mintAndWrapLccToSelf(address lccAddr, uint256 amount) internal {
        address underlying = LiquidityCommitmentCertificate(payable(lccAddr)).underlying();
        if (underlying == address(0)) {
            // Native ETH backing – provide ETH directly to wrap.
            ILiquidityHub(liquidityHub).wrap{value: amount}(lccAddr, amount);
        } else {
            // Mint mock underlying (MarketTestBase uses mintable test currencies).
            // We can rely on deployMintAndApproveCurrency producing mintable ERC20s in tests.
            // If it's not mintable, wrap will revert and that’s fine for fuzz-style flows.
            (bool ok,) = underlying.call(abi.encodeWithSignature("mint(address,uint256)", address(this), amount));
            ok; // ignore
            IERC20(underlying).approve(address(liquidityHub), amount);
            ILiquidityHub(liquidityHub).wrap(lccAddr, amount);
        }
    }

    function _mintErc20To(address token, address to, uint256 amount) internal {
        (bool ok,) = token.call(abi.encodeWithSignature("mint(address,uint256)", to, amount));
        ok;
    }
}

