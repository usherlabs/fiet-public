// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * E2E: LiquidityProvision (standalone)
 *
 * A minimal “regular LP” flow:
 * - picks an LP EOA
 * - deploys a fresh full stack + creates a fresh market
 * - mints underlying to the LP (via standalone market setup)
 * - wraps underlying -> LCC
 * - adds liquidity (mints a PositionManager position) to the CORE pool (LCC/LCC)
 * - removes liquidity (burns the position)
 * - asserts the LP receives LCC back (> 0)
 *
 * Usage:
 * FOUNDRY_PROFILE=deploy forge script script/e2e/LiquidityProvision.s.sol:LiquidityProvisionE2E --rpc-url $RPC --broadcast -vvv
 *
 * Env:
 * - NETWORK
 * - PRIVATE_KEY (deployer / GlobalConfig owner)
 * - LP_PRIVATE_KEY (EOA performing LP actions)
 */

import {console} from "forge-std/Script.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";

import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {ILiquidityHub} from "src/interfaces/ILiquidityHub.sol";
import {MMPositionManager} from "src/MMPositionManager.sol";
import {MMActionAdapter} from "evm-test/utils/MMActionAdapter.sol";

import {E2EBase} from "./base/E2EBase.sol";
import {CurrencySortHelper} from "../libraries/CurrencySortHelper.sol";

contract LiquidityProvisionE2E is E2EBase {
    using StateLibrary for IPoolManager;

    /// @dev Fixed amount per underlying to wrap for this scenario (no env vars).
    uint256 internal constant LP_LIQUIDITY_AMOUNT = 1_000e18;
    /// @dev Core pool fee used when creating the market (no env vars).
    uint24 internal constant CORE_POOL_FEE = 0;
    /// @dev Allow tiny rounding differences in liquidity math / settlement.
    uint256 internal constant AMOUNT_TOLERANCE = 3;

    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? (a - b) : (b - a);
    }

    function _assertApproxEq(uint256 a, uint256 b, uint256 tol, string memory err) internal pure {
        require(_absDiff(a, b) <= tol, err);
    }

    function run() external {
        console.log("=== E2E: LiquidityProvision ===");
        // Load LP signer.
        uint256 lpPk = uint256(vm.envBytes32("LP_PRIVATE_KEY"));
        address lp = vm.addr(lpPk);

        // Deploy full stack.
        CoreDeployment memory d = _deployCoreContracts();
        // Create a fresh market (mints underlyings, configures oracle, mines ProxyHook salt, resolves LCCs).
        StandaloneMarket memory m = _createMarket(d, lp, CORE_POOL_FEE);

        ILiquidityHub hub = ILiquidityHub(m.stack.contracts.liquidityHub);
        IPoolManager poolManager = IPoolManager(config.poolManager);
        IPositionManager positionManager = IPositionManager(payable(config.positionManager));
        IPermit2 permit2 = IPermit2(config.permit2);
        MMPositionManager mmpm = MMPositionManager(payable(m.stack.contracts.mmPositionManager));

        // Fixed amount per underlying (minted amount == wrapped amount == LCC amount).
        uint256 amount = LP_LIQUIDITY_AMOUNT;

        // CORE pool is LCC/LCC, hooks = CoreHook, tickSpacing=60 (matches E2EBase._createMarket).
        (Currency c0, Currency c1) = CurrencySortHelper.sortAddresses(m.lcc0, m.lcc1);
        PoolKey memory corePoolKey = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: m.corePoolFee,
            tickSpacing: int24(60),
            hooks: IHooks(m.stack.contracts.coreHook)
        });

        console.log("=== E2E: LiquidityProvision ===");
        console.log("lp:", lp);
        console.log("wrap amount per underlying:", amount);

        // Snapshot balances (LCC) before flow.
        uint256 lcc0Before = IERC20(m.lcc0).balanceOf(lp);
        uint256 lcc1Before = IERC20(m.lcc1).balanceOf(lp);
        uint256 ua0Before = IERC20(m.underlying0).balanceOf(lp);
        uint256 ua1Before = IERC20(m.underlying1).balanceOf(lp);

        vm.startBroadcast(lpPk);

        // Wrap underlying -> LCC for both assets.
        _wrapAndMintLccPair(hub, m, lp, amount);

        // Track balances for the actual pool currency order (currency0/currency1) for exact assertions.
        address curr0Addr = Currency.unwrap(corePoolKey.currency0);
        address curr1Addr = Currency.unwrap(corePoolKey.currency1);
        console.log("core pool currencies (LCC):");
        console.log("currency0:", curr0Addr);
        console.log("currency1:", curr1Addr);
        uint256 curr0BeforeMint = IERC20(curr0Addr).balanceOf(lp);
        uint256 curr1BeforeMint = IERC20(curr1Addr).balanceOf(lp);

        // Approve LCC to Permit2, and Permit2 -> PositionManager (v4 PM pulls tokens via Permit2).
        IERC20(Currency.unwrap(corePoolKey.currency0)).approve(address(permit2), type(uint256).max);
        IERC20(Currency.unwrap(corePoolKey.currency1)).approve(address(permit2), type(uint256).max);
        uint48 deadline = uint48(block.timestamp + 1 days);
        permit2.approve(Currency.unwrap(corePoolKey.currency0), address(positionManager), type(uint160).max, deadline);
        permit2.approve(Currency.unwrap(corePoolKey.currency1), address(positionManager), type(uint160).max, deadline);

        // Mint a full-range position into the CORE pool.
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(corePoolKey.toId());
        require(sqrtPriceX96 != 0, "core pool not initialized");

        int24 tickLower = (TickMath.MIN_TICK / corePoolKey.tickSpacing) * corePoolKey.tickSpacing;
        int24 tickUpper = (TickMath.MAX_TICK / corePoolKey.tickSpacing) * corePoolKey.tickSpacing;

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), amount, amount
        );
        require(liquidity > 0, "computed liquidity is 0");

        uint256 tokenId = positionManager.nextTokenId();
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(corePoolKey, tickLower, tickUpper, liquidity, amount, amount, lp, "");
        params[1] = abi.encode(corePoolKey.currency0, corePoolKey.currency1);
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 300);
        require(IERC721(address(positionManager)).ownerOf(tokenId) == lp, "position not minted to LP");

        // Subscribe the DirectLPDeltaResolver so burn/modify clears hook deltas within the unlock session.
        positionManager.subscribe(tokenId, m.stack.contracts.directLPDeltaResolver, "");

        // Assert minted position liquidity matches our computed liquidity.
        require(positionManager.getPositionLiquidity(tokenId) == liquidity, "position liquidity mismatch");

        // Exact principal amounts spent on mint (pool currency0/currency1 order).
        uint256 curr0AfterMint = IERC20(curr0Addr).balanceOf(lp);
        uint256 curr1AfterMint = IERC20(curr1Addr).balanceOf(lp);
        uint256 spent0 = curr0BeforeMint - curr0AfterMint;
        uint256 spent1 = curr1BeforeMint - curr1AfterMint;
        require(spent0 > 0 || spent1 > 0, "spent is 0");

        // Strong consistency check: the amounts actually spent should imply the same liquidity we computed.
        uint128 liquidityFromSpent = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), spent0, spent1
        );
        require(liquidityFromSpent == liquidity, "spent amounts != minted liquidity");

        console.log("minted LP position:");
        console.log("spent currency0:", spent0);
        console.log("spent currency1:", spent1);

        // Snapshot balances after add (LCC likely reduced).
        uint256 curr0AfterAdd = curr0AfterMint;
        uint256 curr1AfterAdd = curr1AfterMint;

        // Burn the position and take the LCC pair back to the LP.
        bytes memory burnActions = abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR));
        bytes[] memory burnParams = new bytes[](2);
        burnParams[0] = abi.encode(tokenId, 0, 0, "");
        burnParams[1] = abi.encode(corePoolKey.currency0, corePoolKey.currency1, lp);
        positionManager.modifyLiquidities(abi.encode(burnActions, burnParams), block.timestamp + 300);

        // Assert burned position liquidity is cleared.
        require(positionManager.getPositionLiquidity(tokenId) == 0, "position not cleared");

        // Compute exact LCC amounts received from burn (pool currency0/currency1 order).
        uint256 curr0AfterBurn = IERC20(curr0Addr).balanceOf(lp);
        uint256 curr1AfterBurn = IERC20(curr1Addr).balanceOf(lp);
        uint256 received0 = curr0AfterBurn - curr0AfterAdd;
        uint256 received1 = curr1AfterBurn - curr1AfterAdd;

        // Milestone 1: LCC principal round-trips (burn returns the same LCC principal we spent on mint).
        _assertApproxEq(received0, spent0, AMOUNT_TOLERANCE, "LCC roundtrip: received0 != spent0");
        _assertApproxEq(received1, spent1, AMOUNT_TOLERANCE, "LCC roundtrip: received1 != spent1");
        console.log("burned LP position:");
        console.log("received currency0:", received0);
        console.log("received currency1:", received1);

        // Unwrap the received LCC back to underlying via MMPositionManager.
        // This keeps us on the same “production” path (MMPM acquires PoolManager.unlock internally).
        require(received0 > 0 && received1 > 0, "expected both LCC received > 0");

        IERC20(curr0Addr).approve(address(mmpm), received0);
        IERC20(curr1Addr).approve(address(mmpm), received1);

        MMActionAdapter.PreparedAction[] memory prepared = new MMActionAdapter.PreparedAction[](2);
        prepared[0] = MMActionAdapter.prepareUnwrapLcc(curr0Addr, received0, lp, true);
        prepared[1] = MMActionAdapter.prepareUnwrapLcc(curr1Addr, received1, lp, true);
        MMActionAdapter.executeWithUnlock(mmpm, prepared, block.timestamp + 3600);

        vm.stopBroadcast();

        // Snapshot balances after unwrap.
        uint256 ua0After = IERC20(m.underlying0).balanceOf(lp);
        uint256 ua1After = IERC20(m.underlying1).balanceOf(lp);
        uint256 lcc0After = IERC20(m.lcc0).balanceOf(lp);
        uint256 lcc1After = IERC20(m.lcc1).balanceOf(lp);

        // Milestone 2: Underlying round-trips after unwrap (LP ends with ~same underlying as started).
        _assertApproxEq(ua0After, ua0Before, AMOUNT_TOLERANCE, "underlying roundtrip: ua0 != before");
        _assertApproxEq(ua1After, ua1Before, AMOUNT_TOLERANCE, "underlying roundtrip: ua1 != before");

        console.log("final checkpoints:");
        console.log("lcc0 before/after:", lcc0Before, lcc0After);
        console.log("lcc1 before/after:", lcc1Before, lcc1After);
        console.log("ua0 before/after:", ua0Before, ua0After);
        console.log("ua1 before/after:", ua1Before, ua1After);
        console.log("OK: LCC + underlying roundtrip verified");
    }
}

