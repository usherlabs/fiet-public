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
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {ILiquidityHub} from "src/interfaces/ILiquidityHub.sol";

import {E2EBase} from "./base/E2EBase.sol";

contract LiquidityProvisionE2E is E2EBase {
    using StateLibrary for IPoolManager;

    /// @dev Amount wrapped per underlying before add-liquidity (must exceed mint caps to leave swap inventory).
    uint256 internal constant WRAP_AMOUNT_PER_ASSET = 1_200e18;
    /// @dev Per-asset cap used for liquidity mint.
    uint256 internal constant LIQUIDITY_AMOUNT_MAX = 1_000e18;
    /// @dev Exact output amount for the in-flow market-derived swap.
    uint128 internal constant SWAP_AMOUNT_OUT = 10e18;
    /// @dev Swap direction for the in-flow swap.
    bool internal constant ZERO_FOR_ONE = true;
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

    function _swapAndAssert(StandaloneMarket memory m, uint256 lpPk, PoolKey memory corePoolKey)
        internal
        returns (address tokenIn, address tokenOut, uint256 swapSpent, uint256 swapReceived)
    {
        IPoolManager poolManager = IPoolManager(config.poolManager);
        (uint160 sqrtPriceX96BeforeSwap,,,) = poolManager.getSlot0(corePoolKey.toId());
        uint256 expectedAmountIn = _quoteExactOutputSingle(_deployQuoter(), corePoolKey, ZERO_FOR_ONE, SWAP_AMOUNT_OUT);
        (tokenIn, tokenOut, swapSpent, swapReceived) =
            _swapExactOutputSingle(m, lpPk, ZERO_FOR_ONE, SWAP_AMOUNT_OUT, expectedAmountIn);
        require(tokenIn == Currency.unwrap(corePoolKey.currency0), "swap tokenIn mismatch");
        require(tokenOut == Currency.unwrap(corePoolKey.currency1), "swap tokenOut mismatch");
        (uint160 sqrtPriceX96AfterSwap,,,) = poolManager.getSlot0(corePoolKey.toId());
        require(swapReceived == uint256(SWAP_AMOUNT_OUT), "swap: output mismatch");
        require(swapSpent == expectedAmountIn, "swap: input mismatch");
        require(sqrtPriceX96AfterSwap < sqrtPriceX96BeforeSwap, "swap: expected price to decrease");
    }

    function _removeAndUnwrap(
        StandaloneMarket memory m,
        uint256 lpPk,
        PoolKey memory corePoolKey,
        uint256 tokenId,
        address curr0Addr,
        address curr1Addr,
        address lp
    ) internal {
        IPositionManager positionManager = IPositionManager(payable(config.positionManager));
        ILiquidityHub hub = ILiquidityHub(m.stack.contracts.liquidityHub);

        vm.startBroadcast(lpPk);
        uint256 curr0BeforeBurn = IERC20(curr0Addr).balanceOf(lp);
        uint256 curr1BeforeBurn = IERC20(curr1Addr).balanceOf(lp);
        bytes memory burnActions = abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR));
        bytes[] memory burnParams = new bytes[](2);
        burnParams[0] = abi.encode(tokenId, 0, 0, "");
        burnParams[1] = abi.encode(corePoolKey.currency0, corePoolKey.currency1, lp);
        positionManager.modifyLiquidities(abi.encode(burnActions, burnParams), block.timestamp + 300);
        require(positionManager.getPositionLiquidity(tokenId) == 0, "position not cleared");

        uint256 received0 = IERC20(curr0Addr).balanceOf(lp) - curr0BeforeBurn;
        uint256 received1 = IERC20(curr1Addr).balanceOf(lp) - curr1BeforeBurn;
        require(received0 > 0 || received1 > 0, "burn: expected LCC received > 0");

        uint256 totalLcc0ToUnwrap = IERC20(curr0Addr).balanceOf(lp);
        uint256 totalLcc1ToUnwrap = IERC20(curr1Addr).balanceOf(lp);
        if (totalLcc0ToUnwrap > 0) hub.unwrap(curr0Addr, totalLcc0ToUnwrap);
        if (totalLcc1ToUnwrap > 0) hub.unwrap(curr1Addr, totalLcc1ToUnwrap);
        vm.stopBroadcast();
    }

    function run() external {
        console.log("=== E2E: LiquidityProvision ===");
        // Load LP signer.
        uint256 lpPk = uint256(
            _requireEnvBytes32("LP_PRIVATE_KEY", "Missing LP_PRIVATE_KEY env var (anvil keys can be used directly)")
        );
        address lp = vm.addr(lpPk);
        CoreDeployment memory d = _deployCoreContracts();
        StandaloneMarket memory m = _createMarket(d, lp, CORE_POOL_FEE);

        console.log("=== E2E: LiquidityProvision ===");
        console.log("lp:", lp);
        console.log("wrap amount per underlying:", WRAP_AMOUNT_PER_ASSET);
        console.log("liquidity cap per underlying:", LIQUIDITY_AMOUNT_MAX);

        // Snapshot underlying balances before flow.
        uint256 ua0Before = IERC20(m.underlying0).balanceOf(lp);
        uint256 ua1Before = IERC20(m.underlying1).balanceOf(lp);

        PoolKey memory corePoolKey = _corePoolKey(m);
        address curr0Addr = Currency.unwrap(corePoolKey.currency0);
        address curr1Addr = Currency.unwrap(corePoolKey.currency1);
        uint256 tokenId = _addCoreLiquidityFullRange(m, lpPk, WRAP_AMOUNT_PER_ASSET, LIQUIDITY_AMOUNT_MAX);
        console.log("minted LP position tokenId:", tokenId);
        console.log("currency0:", curr0Addr);
        console.log("currency1:", curr1Addr);

        (address swapTokenIn, address swapTokenOut, uint256 swapSpent, uint256 swapReceived) =
            _swapAndAssert(m, lpPk, corePoolKey);
        _removeAndUnwrap(m, lpPk, corePoolKey, tokenId, curr0Addr, curr1Addr, lp);

        // Snapshot balances after unwrap.
        uint256 ua0After = IERC20(m.underlying0).balanceOf(lp);
        uint256 ua1After = IERC20(m.underlying1).balanceOf(lp);
        uint256 lcc0After = IERC20(m.lcc0).balanceOf(lp);
        uint256 lcc1After = IERC20(m.lcc1).balanceOf(lp);

        // After unwrapping, the LP should hold only underlying and the net balance shift should mirror the
        // exact-output swap executed while assets were wrapped as LCCs.
        uint256 expectedUa0After = ua0Before;
        uint256 expectedUa1After = ua1Before;
        if (swapTokenIn == curr0Addr) {
            expectedUa0After -= swapSpent;
            expectedUa1After += swapReceived;
        } else {
            expectedUa1After -= swapSpent;
            expectedUa0After += swapReceived;
        }

        require(
            swapTokenOut == curr0Addr || swapTokenOut == curr1Addr,
            "swap: unexpected tokenOut for core-pool liquidity flow"
        );
        _assertApproxEq(ua0After, expectedUa0After, AMOUNT_TOLERANCE, "underlying delta: ua0 != expected");
        _assertApproxEq(ua1After, expectedUa1After, AMOUNT_TOLERANCE, "underlying delta: ua1 != expected");

        console.log("final checkpoints:");
        console.log("lcc0 final:", lcc0After);
        console.log("lcc1 final:", lcc1After);
        console.log("ua0 before/after:", ua0Before, ua0After);
        console.log("ua1 before/after:", ua1Before, ua1After);
        _assertApproxEq(lcc0After, 0, AMOUNT_TOLERANCE, "final LCC0 should be ~0 after unwrap");
        _assertApproxEq(lcc1After, 0, AMOUNT_TOLERANCE, "final LCC1 should be ~0 after unwrap");
        console.log("OK: stateful DirectLP add->swap->remove->unwrap verified");
    }
}
