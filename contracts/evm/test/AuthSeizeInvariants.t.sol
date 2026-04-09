// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {MarketTestBase} from "./base/MarketTestBase.sol";
import {MarketMakerTestBase} from "./base/MMTestBase.sol";
import {MMPositionManager} from "../src/MMPositionManager.sol";
import {MMActionAdapter as MMA} from "./utils/MMActionAdapter.sol";
import {LiquidityCommitmentCertificate} from "../src/LCC.sol";
import {MarketVTSConfiguration} from "../src/types/VTS.sol";
import {Errors} from "../src/libraries/Errors.sol";
import {IOracleHelper} from "../src/interfaces/IOracleHelper.sol";

import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Real-path auth/seizure coverage for AUTH-01/AUTH-01A/AUTH-02.
contract AuthSeizeInvariantsTest is MarketTestBase, MarketMakerTestBase {
    uint256 internal constant SEIZE_SETTLE0 = 5_999_709_018_652_707;
    uint256 internal constant SEIZE_SETTLE1 = 5_999_709_018_652_707;

    MMPositionManager internal positionManager;
    LiquidityCommitmentCertificate internal lcc0;
    LiquidityCommitmentCertificate internal lcc1;
    MarketVTSConfiguration internal marketVTSConfiguration;

    function setUp() public {
        _setupMarket();
        _setUpMM();

        positionManager = MMPositionManager(payable(mmPositionManager));
        lcc0 = LiquidityCommitmentCertificate(payable(Currency.unwrap(_currency2)));
        lcc1 = LiquidityCommitmentCertificate(payable(Currency.unwrap(_currency3)));
        marketVTSConfiguration = vtsOrchestrator.getMarketVTSConfiguration(corePoolKey.toId());

        // Keep commitment-backing validation deterministic.
        vm.mockCall(
            address(oracleHelper),
            abi.encodeWithSelector(IOracleHelper.getPricesForLccPair.selector, address(lcc0), address(lcc1)),
            abi.encode(uint256(1), uint256(1))
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
                abi.encode(uint256(1e18))
            );
        }
    }

    function testFuzz_auth01_nonApprovedCannotSettleWhenNotSeizing(int128 amount0Raw, int128 amount1Raw) public {
        (uint256 tokenId,,,) = _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)}),
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        int128 amount0 = _boundNonZero(amount0Raw);
        int128 amount1 = _boundNonZero(amount1Raw);
        address attacker = makeAddr("attacker");

        MMA.PreparedAction[] memory attackerActions = new MMA.PreparedAction[](1);
        attackerActions[0] = MMA.prepareSettle(corePoolKey, tokenId, 0, amount0, amount1, false);

        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotApproved.selector, attacker));
        MMA.executeWithUnlock(positionManager, attackerActions, block.timestamp + 3600);
        vm.stopPrank();
    }

    function test_auth02_transferFromBlockedWhenPoolManagerUnlocked() public {
        (uint256 tokenId,,,) = _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)}),
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        UnlockCaller caller = new UnlockCaller();
        vm.expectRevert(Errors.PoolManagerMustBeLocked.selector);
        caller.transferFromWhileUnlocked(manager, positionManager, address(this), makeAddr("to"), tokenId);
    }

    function test_auth01a_seizeContext_samePositionOnlyInBatch() public {
        (uint256 seizedTokenId,,,) = _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)}),
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );
        (uint256 otherTokenId,,,) = _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(renewSignal),
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e10, salt: bytes32(uint256(1))}),
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );

        _openSeizeWindow(seizedTokenId);

        address guarantor = makeAddr("guarantor-auth01a-scope");
        IERC20(lcc0.underlying()).transfer(guarantor, SEIZE_SETTLE0);
        IERC20(lcc1.underlying()).transfer(guarantor, SEIZE_SETTLE1);

        vm.startPrank(guarantor);
        IERC20(lcc0.underlying()).approve(address(positionManager), type(uint256).max);
        IERC20(lcc1.underlying()).approve(address(positionManager), type(uint256).max);

        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](5);
        actions[0] = MMA.prepareSeize(corePoolKey, seizedTokenId, 0, SEIZE_SETTLE0, SEIZE_SETTLE1, false);
        actions[1] = MMA.prepareSettleFromDeltas(corePoolKey, seizedTokenId, 0, true, true);
        actions[2] = MMA.prepareTake(Currency.wrap(address(lcc0)), guarantor, 0);
        actions[3] = MMA.prepareTake(Currency.wrap(address(lcc1)), guarantor, 0);
        // This touches a different position in the same batch; it must not inherit seize context.
        actions[4] = MMA.prepareSettle(corePoolKey, otherTokenId, 0, -int128(1), -int128(1), false);

        vm.expectRevert(abi.encodeWithSelector(Errors.NotApproved.selector, guarantor));
        MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);
        vm.stopPrank();
    }

    function test_auth01a_seizeContext_clearedAtBatchEnd() public {
        (uint256 tokenId,,,) = _setupCommittedPosition(
            positionManager,
            corePoolKey,
            abi.encode(liquiditySignal),
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)}),
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );
        _openSeizeWindow(tokenId);

        address guarantor = makeAddr("guarantor-auth01a-clear");
        IERC20(lcc0.underlying()).transfer(guarantor, SEIZE_SETTLE0);
        IERC20(lcc1.underlying()).transfer(guarantor, SEIZE_SETTLE1);

        vm.startPrank(guarantor);
        IERC20(lcc0.underlying()).approve(address(positionManager), type(uint256).max);
        IERC20(lcc1.underlying()).approve(address(positionManager), type(uint256).max);

        // Batch 1: valid seize flow on the target position.
        MMA.PreparedAction[] memory seizeActions = new MMA.PreparedAction[](4);
        seizeActions[0] = MMA.prepareSeize(corePoolKey, tokenId, 0, SEIZE_SETTLE0, SEIZE_SETTLE1, false);
        seizeActions[1] = MMA.prepareSettleFromDeltas(corePoolKey, tokenId, 0, true, true);
        seizeActions[2] = MMA.prepareTake(Currency.wrap(address(lcc0)), guarantor, 0);
        seizeActions[3] = MMA.prepareTake(Currency.wrap(address(lcc1)), guarantor, 0);
        MMA.executeWithUnlock(positionManager, seizeActions, block.timestamp + 3600);

        // Batch 2: same caller, same position, but seize context must be cleared.
        MMA.PreparedAction[] memory postBatch = new MMA.PreparedAction[](1);
        postBatch[0] = MMA.prepareSettle(corePoolKey, tokenId, 0, -int128(1), -int128(1), false);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotApproved.selector, guarantor));
        MMA.executeWithUnlock(positionManager, postBatch, block.timestamp + 3600);
        vm.stopPrank();
    }

    function _openSeizeWindow(uint256 tokenId) internal {
        swapRouter.swap(
            proxyPoolKey,
            SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: ZERO_FOR_ONE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
        // Persist the live RFS-open state before time-warping so seizure grace measures a stored checkpoint window.
        positionManager.checkpoint(tokenId, 0, false);
        // Exceed grace period to enable seizure path.
        vm.warp(block.timestamp + 300000 + 1);
    }

    function _boundNonZero(int128 value) internal pure returns (int128 bounded) {
        bounded = value;
        if (bounded == 0) bounded = 1;
        if (bounded > 1e18) bounded = 1e18;
        if (bounded < -1e18) bounded = -1e18;
    }
}

contract UnlockCaller {
    address internal transferFromFrom;
    address internal transferFromTo;
    uint256 internal transferFromTokenId;
    MMPositionManager internal targetMmpm;

    function transferFromWhileUnlocked(
        IPoolManager manager,
        MMPositionManager mmpm,
        address from,
        address to,
        uint256 tokenId
    ) external {
        transferFromFrom = from;
        transferFromTo = to;
        transferFromTokenId = tokenId;
        targetMmpm = mmpm;
        manager.unlock(bytes(""));
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        targetMmpm.transferFrom(transferFromFrom, transferFromTo, transferFromTokenId);
        return bytes("");
    }
}
