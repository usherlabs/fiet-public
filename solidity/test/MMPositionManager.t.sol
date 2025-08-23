// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {CurrencySortHelper} from "../script/libraries/CurrencySortHelper.sol";
import {ProxyHook} from "../src/ProxyHook.sol";
import {CoreHook} from "../src/CoreHook.sol";
import {LiquidityCommitmentCertificate} from "../src/LCC.sol";
import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";
import {LiquidityUtils} from "../src/libraries/LiquidityUtils.sol";
import {console} from "forge-std/console.sol";
import {HookFlags} from "../script/constants/HookFlags.sol";
import {MarketTestBase} from "./modules/MarketTestBase.sol";
import {MMPositionManager} from "../src/MMPositionManager.sol";
import {StubSpokeVerifier} from "../src/modules/StubSpokeVerifier.sol";
import {MarketMakerTestBase} from "./modules/MMTestBase.sol";
import {MockV3Aggregator} from "@chainlink/contracts/src/v0.8/tests/MockV3Aggregator.sol";
import {MarketMaker} from "../src/libraries/MarketMaker.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {PositionInfo} from "../src/types/Position.sol";

contract MMPositionManagerTest is MarketTestBase, MarketMakerTestBase {
    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;
    using MarketMaker for MarketMaker.State;

    MockV3Aggregator btcPriceFeed;
    MockV3Aggregator usdtPriceFeed;

    LiquidityCommitmentCertificate lcc0;
    LiquidityCommitmentCertificate lcc1;

    MMPositionManager mmPositionManager;

    function setUp() public {
        _setupMarket();
        _setUpMM();

        lcc0 = LiquidityCommitmentCertificate(Currency.unwrap(_currency2));
        lcc1 = LiquidityCommitmentCertificate(Currency.unwrap(_currency3));

        mmPositionManager = new MMPositionManager(manager, address(stubSpokeVerifier));

        // approve the lccs to the mmPositionManager to be able to route tokens to the pool manager
        lcc0.approve(address(mmPositionManager), Constants.MAX_UINT256);
        lcc0.setIssuer(address(mmPositionManager), true);
        lcc1.approve(address(mmPositionManager), Constants.MAX_UINT256);
        lcc1.setIssuer(address(mmPositionManager), true);

        // Mock the getOraclePrice
        // LCC0: ~$0.997 * 10^8 = 99700000
        vm.mockCall(address(lcc0), abi.encodeWithSignature("getOraclePrice()"), abi.encode(uint256(99700000)));
        // LCC1: ~$0.999 * 10^8 = 99900000
        vm.mockCall(address(lcc1), abi.encodeWithSignature("getOraclePrice()"), abi.encode(uint256(99900000)));

        // initialize the price feeds for the mock assets
        // Create mock price feeds with 8 decimals (standard for Chainlink)
        // BTC: $200 * 10^8 = 20000000000
        // BTC: ~$113,000 * 10^8 = 11300000000000
        btcPriceFeed = new MockV3Aggregator(8, 11300000000000);
        // USDT: ~$1.00 * 10^8 = 100000000
        usdtPriceFeed = new MockV3Aggregator(8, 100000000);
        mmPositionManager.addAssetPriceFeed("BTC", address(btcPriceFeed));
        mmPositionManager.addAssetPriceFeed("USDT", address(usdtPriceFeed));
    }

    function test_canAddLiquidityToCorePool() public {
        modifyLiquidityRouter.modifyLiquidity(
            corePoolKey,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: bytes32(0)}),
            ZERO_BYTES
        );
    }

    function test_canCommitLiquidityToCorePool() public {
        int24 tickLower = -60;
        int24 tickUpper = 60;

        // fill in the amounts and tickers
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1;
        amounts[1] = 15001;
        string[] memory tickers = new string[](2);
        tickers[0] = "BTC";
        tickers[1] = "USDT";

        uint256 totalUSDValue = mmPositionManager.getTotalUsdValue(tickers, amounts);

        (uint256 lccUnderlyingAmountToCommit0, uint256 lccUnderlyingAmountToCommit1) = mmPositionManager
            .getCommitmentAmounts(
            MarketMaker.PositionParams({corePoolKey: corePoolKey, tickLower: tickLower, tickUpper: tickUpper}),
            totalUSDValue
        );
        (uint256 lccAmount0ToMint, uint256 lccAmount1ToMint, uint128 liquidityDelta) = mmPositionManager
            .calculateLCCAmountsDeltaFromUSD(
            MarketMaker.PositionParams({corePoolKey: corePoolKey, tickLower: tickLower, tickUpper: tickUpper}),
            totalUSDValue
        );

        // approve the LCC contract to spend our underlying tokens for lcc0 and lcc1
        ERC20(lcc0.underlyingAsset()).approve(address(lcc0), lccUnderlyingAmountToCommit0);
        ERC20(lcc1.underlyingAsset()).approve(address(lcc1), lccUnderlyingAmountToCommit1);

        // underlying balance of lcc0
        uint256 lcc0UnderlyingBalanceBeforeCommitment = ERC20(lcc0.underlyingAsset()).balanceOf(address(this));
        uint256 lcc1UnderlyingBalanceBeforeCommitment = ERC20(lcc1.underlyingAsset()).balanceOf(address(this));

        uint256 lcc0TotalSupplyBeforeCommitment = lcc0.totalSupply();
        uint256 lcc1TotalSupplyBeforeCommitment = lcc1.totalSupply();
        // total supply of lcc1 and lcc2

        // get the poolmanaggers lcc balance
        uint256 pmlcc0BalanceBeforeCommitment = lcc0.balanceOf(address(manager));
        uint256 pmlcc1BalanceBeforeCommitment = lcc1.balanceOf(address(manager));

        // confirm there are no lcc's in the MM contract prior to it being minted when liquidity is being commited
        assertEq(lcc0.balanceOf(address(mmPositionManager)), 0);
        assertEq(lcc1.balanceOf(address(mmPositionManager)), 0);

        // commit the liquidity
        mmPositionManager.commitLiquidity(
            MarketMaker.PositionParams({corePoolKey: corePoolKey, tickLower: tickLower, tickUpper: tickUpper}),
            MarketMaker.ProofParams({
                rootStateHash: merkleRootHash,
                rootStateHashSignature: mm1MerkleRootHashSignature,
                merkleProof: merkleProofs,
                mmStateData: mmState,
                mmStateHashSignature: mm1StateHashSignature
            }),
            tickers,
            amounts
        );
        // confirm there are no left over lcc's in the MPMM contract after liquidity is committed
        assertEq(lcc0.balanceOf(address(mmPositionManager)), 0);
        assertEq(lcc1.balanceOf(address(mmPositionManager)), 0);

        // get the poolmanaggers lcc balance
        uint256 pmlcc0BalanceAfterCommitment = lcc0.balanceOf(address(manager));
        uint256 pmlcc1BalanceAfterCommitment = lcc1.balanceOf(address(manager));

        // underlying balance of lcc0
        uint256 lcc0UnderlyingBalanceAfterCommitment = ERC20(lcc0.underlyingAsset()).balanceOf(address(this));
        uint256 lcc1UnderlyingBalanceAfterCommitment = ERC20(lcc1.underlyingAsset()).balanceOf(address(this));

        // total supply of lcc1 and lcc2
        uint256 lcc0TotalSupplyAfterCommitment = lcc0.totalSupply();
        uint256 lcc1TotalSupplyAfterCommitment = lcc1.totalSupply();

        // validate liquidity was added to the pool, and the right amounts of lccs were minted and the right amounts of underlying tokens were transferred to the lccs
        assertEq(
            lcc0UnderlyingBalanceBeforeCommitment - lcc0UnderlyingBalanceAfterCommitment, lccUnderlyingAmountToCommit0
        );
        assertEq(
            lcc1UnderlyingBalanceBeforeCommitment - lcc1UnderlyingBalanceAfterCommitment, lccUnderlyingAmountToCommit1
        );
        assertEq(lcc0TotalSupplyAfterCommitment - lcc0TotalSupplyBeforeCommitment, lccAmount0ToMint);
        assertEq(lcc1TotalSupplyAfterCommitment - lcc1TotalSupplyBeforeCommitment, lccAmount1ToMint);

        // validate pool manager lcc balance increases after commitment
        assertGt(pmlcc0BalanceAfterCommitment, pmlcc0BalanceBeforeCommitment);
        assertGt(pmlcc1BalanceAfterCommitment, pmlcc1BalanceBeforeCommitment);

        // validate the position's nft was created
        uint256 tokenId = 1;
        (uint128 totalLiquidity, uint256 activePositionCount) = mmPositionManager.getTotalNFTLiquidity(tokenId);
        assertEq(totalLiquidity, liquidityDelta);
        assertEq(activePositionCount, 1);
        assertEq(mmPositionManager.ownerOf(tokenId), address(this));

        // validate the position details with the details of the liquidity added to the pool
    }

    function test_canRemoveCommitmentToCorePool() public {
        int24 tickLower = -60;
        int24 tickUpper = 60;

        // fill in the amounts and tickers
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1;
        amounts[1] = 1000;
        string[] memory tickers = new string[](2);
        tickers[0] = "BTC";
        tickers[1] = "USDT";

        uint256 totalUSDValue = mmPositionManager.getTotalUsdValue(tickers, amounts);

        (uint256 lccAmount0Delta, uint256 lccAmount1Delta,) = mmPositionManager.calculateLCCAmountsDeltaFromUSD(
            MarketMaker.PositionParams({corePoolKey: corePoolKey, tickLower: tickLower, tickUpper: tickUpper}),
            totalUSDValue
        );

        (uint256 lccUnderlyingAmountToCommit0, uint256 lccUnderlyingAmountToCommit1) = mmPositionManager
            .getCommitmentAmounts(
            MarketMaker.PositionParams({corePoolKey: corePoolKey, tickLower: tickLower, tickUpper: tickUpper}),
            totalUSDValue
        );

        // approve the lccs to the mmPositionManager to be able to route tokens to the pool manager
        ERC20(lcc0.underlyingAsset()).approve(address(lcc0), lccUnderlyingAmountToCommit0);
        ERC20(lcc1.underlyingAsset()).approve(address(lcc1), lccUnderlyingAmountToCommit1);

        // commit the liquidity
        uint256 tokenId = mmPositionManager.commitLiquidity(
            MarketMaker.PositionParams({corePoolKey: corePoolKey, tickLower: tickLower, tickUpper: tickUpper}),
            MarketMaker.ProofParams({
                rootStateHash: merkleRootHash,
                rootStateHashSignature: mm1MerkleRootHashSignature,
                merkleProof: merkleProofs,
                mmStateData: mmState,
                mmStateHashSignature: mm1StateHashSignature
            }),
            tickers,
            amounts
        );

        // get lcc balances of lcc0 and lcc1 of position manager
        console.log("mmpmLcc0BalanceAfterCommitment", lcc0.balanceOf(address(mmPositionManager)));
        console.log("mmpmLcc1BalanceAfterCommitment", lcc1.balanceOf(address(mmPositionManager)));

        //  try decommit the liquidity
        mmPositionManager.removeLiquidityCommitment(tokenId);

        console.log("mmpmLcc0BalanceAfterDeCommitment", lcc0.balanceOf(address(mmPositionManager)));
        console.log("mmpmLcc1BalanceAfterDeCommitment", lcc1.balanceOf(address(mmPositionManager)));

        // confirm the lcc tokens have indeed been added to the position manager contract i.e the liquidity has been removed from the pool
        // validate that the lcc balance of the position manager/router has increased by the amount of lccs removed from the pool
        assertGt(lcc0.balanceOf(address(mmPositionManager)), 0);
        assertGt(lcc1.balanceOf(address(mmPositionManager)), 0);

        // validate the position's nft was destroyed
        (uint128 totalLiquidity, uint256 activePositionCount) = mmPositionManager.getTotalNFTLiquidity(tokenId);
        assertEq(totalLiquidity, 0);
        assertEq(activePositionCount, 0);
        // assertEq(mmPositionManager.ownerOf(tokenId), address(0));
    }
}
