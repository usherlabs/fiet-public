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

import {E2EBase} from "./base/E2EBase.sol";
import {CurrencySortHelper} from "../libraries/CurrencySortHelper.sol";

contract LiquidityProvisionE2E is E2EBase {
    using StateLibrary for IPoolManager;

    /// @dev Fixed amount per underlying to wrap for this scenario (no env vars).
    uint256 internal constant LP_LIQUIDITY_AMOUNT = 1_000e18;

    function run() external {
        // Load LP signer.
        uint256 lpPk = uint256(vm.envBytes32("LP_PRIVATE_KEY"));
        address lp = vm.addr(lpPk);

        // Deploy full stack.
        CoreDeployment memory d = _deployCoreContracts();
        // Create a fresh market (mints underlyings, configures oracle, mines ProxyHook salt, resolves LCCs).
        StandaloneMarket memory m = _createMarket(d, lp);

        ILiquidityHub hub = ILiquidityHub(m.stack.contracts.liquidityHub);
        IPoolManager poolManager = IPoolManager(config.poolManager);
        IPositionManager positionManager = IPositionManager(payable(config.positionManager));
        IPermit2 permit2 = IPermit2(config.permit2);

        // Fixed amount per underlying (minted amount == wrapped amount == LCC amount).
        uint256 amount = LP_LIQUIDITY_AMOUNT;

        // CORE pool is LCC/LCC, hooks = CoreHook, fee=0, tickSpacing=60 (matches _deployStandaloneMarket).
        (Currency c0, Currency c1) = CurrencySortHelper.sortAddresses(m.lcc0, m.lcc1);
        PoolKey memory corePoolKey = PoolKey({
            currency0: c0, currency1: c1, fee: 0, tickSpacing: int24(60), hooks: IHooks(m.stack.contracts.coreHook)
        });

        console.log("=== E2E: LiquidityProvision ===");
        console.log("lp:", lp);
        console.log("amount per underlying:", amount);
        console.log("MarketFactory:", m.stack.contracts.marketFactory);
        console.log("LiquidityHub:", m.stack.contracts.liquidityHub);
        console.log("CoreHook:", m.stack.contracts.coreHook);
        console.log("PositionManager:", config.positionManager);

        // Snapshot balances (LCC) before flow.
        uint256 lcc0Before = IERC20(m.lcc0).balanceOf(lp);
        uint256 lcc1Before = IERC20(m.lcc1).balanceOf(lp);

        vm.startBroadcast(lpPk);

        // Wrap underlying -> LCC for both assets.
        _wrapAndMintLccPair(hub, m, lp, amount);

        // Approve LCC to Permit2, and Permit2 -> PositionManager (v4 PM pulls tokens via Permit2).
        IERC20(Currency.unwrap(corePoolKey.currency0)).approve(address(permit2), type(uint256).max);
        IERC20(Currency.unwrap(corePoolKey.currency1)).approve(address(permit2), type(uint256).max);
        uint48 deadline = uint48(block.timestamp + 1 days);
        permit2.approve(Currency.unwrap(corePoolKey.currency0), address(positionManager), type(uint160).max, deadline);
        permit2.approve(Currency.unwrap(corePoolKey.currency1), address(positionManager), type(uint160).max, deadline);

        // Mint a full-range position into the CORE pool.
        (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(corePoolKey.toId());
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

        // Snapshot balances after add (LCC likely reduced).
        uint256 lcc0AfterAdd = IERC20(m.lcc0).balanceOf(lp);
        uint256 lcc1AfterAdd = IERC20(m.lcc1).balanceOf(lp);

        // Burn the position and take the LCC pair back to the LP.
        bytes memory burnActions = abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR));
        bytes[] memory burnParams = new bytes[](2);
        burnParams[0] = abi.encode(tokenId, 0, 0, "");
        burnParams[1] = abi.encode(corePoolKey.currency0, corePoolKey.currency1, lp);
        positionManager.modifyLiquidities(abi.encode(burnActions, burnParams), block.timestamp + 300);

        vm.stopBroadcast();

        // Snapshot balances after remove (LCC should increase).
        uint256 lcc0AfterRemove = IERC20(m.lcc0).balanceOf(lp);
        uint256 lcc1AfterRemove = IERC20(m.lcc1).balanceOf(lp);

        uint256 lcc0Received = lcc0AfterRemove > lcc0AfterAdd ? (lcc0AfterRemove - lcc0AfterAdd) : 0;
        uint256 lcc1Received = lcc1AfterRemove > lcc1AfterAdd ? (lcc1AfterRemove - lcc1AfterAdd) : 0;

        console.log("--- LCC balances ---");
        console.log("lcc0 before:", lcc0Before);
        console.log("lcc0 after add:", lcc0AfterAdd);
        console.log("lcc0 after remove:", lcc0AfterRemove);
        console.log("lcc1 before:", lcc1Before);
        console.log("lcc1 after add:", lcc1AfterAdd);
        console.log("lcc1 after remove:", lcc1AfterRemove);
        console.log("lcc0 received:", lcc0Received);
        console.log("lcc1 received:", lcc1Received);

        // Validate LP receives some LCC back from removing liquidity.
        require(lcc0Received > 0 || lcc1Received > 0, "expected LCC received > 0");

        console.log("OK: LiquidityProvision flow completed (LP received LCC back)");
    }
}

