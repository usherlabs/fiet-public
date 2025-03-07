// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {CSMM} from "../src/CSMM.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {SortTokens} from "@uniswap/v4-core/test/utils/SortTokens.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {VRLManagerStub} from "./mock/VRLManagerStub.sol";
import {LiquidityVerifierStub} from "./mock/LiquidityVerifierStub.sol";
import {GLPFeeConfigManagerStub} from "./mock/GLPFeeConfigManagerStub.sol";
import {ALMStub} from "./mock/ALMStub.sol";

contract CSMMTest is Test, Deployers {
    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;

    // Define a couple of users
    address user1 = address(0xD1798D6b74EF965d6A60f45E0036f44AEd3DfA1b);
    address user2 = address(0x60500535A90b3E2F459A66591DAab0bAC86ee515);

    // define verified amounts and signature for user1
    uint256 swapAmount1 = 100;
    uint256 nonce = 100; // a randomly selected number to guarante a unique signature
    bytes32 nonceAndAmountHash1 =
        0x315f1cfc49ecfc87246f19e56dfaaa098cdb8a0d7e8b2461f3275d5f68fbde3c;
    bytes hashSignature1 =
        hex"668d0b690fe23e83c9e716a034bcaa6cfbf4807fa6dcdbe652d86d5a7488b28b6c78ab1365c2b0373a8d1c3394c7fc3bd3247ef895ad7d11cf7a79796d7f1a371b";

    // define verified amounts and signature for user2
    uint256 swapAmount2 = 90;
    bytes32 nonceAndAmountHash2 =
        0xeda14cbefc6f96aaafddcf33ef1adf6ad0e14b05d4916862b26d6f49deb03cbf;
    bytes hashSignature2 =
        hex"9602596965d7ba2824013bc5770593cd7cde8fe6244088e7eff9c45bf9233a6f416ff6bccbe18bb63f9b3dd8600f8c1c567766308e9ad267cfd3ee21b2df5e011b";

    CSMM hookAndLDToken;
    MockERC20 stableToken;

    // define for the currencies
    Currency stableTokenCurrency;
    Currency hookAndLDTokenCurrency;

    // define the stub contracts
    LiquidityVerifierStub liquidityVerifierStub;
    VRLManagerStub vrlManagerStub;
    GLPFeeConfigManagerStub glpFeeConfigManagerStub;
    // ALMStub alm;

    PoolSwapTest.TestSettings settings =
        PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
    function deployStubs() public {
        vrlManagerStub = new VRLManagerStub();
        glpFeeConfigManagerStub = new GLPFeeConfigManagerStub();
        liquidityVerifierStub = new LiquidityVerifierStub(vrlManagerStub);
    }

    function deployAndApproveTokens() public {
        // deploy the hook contract
        address hookAddress = address(
            uint160(
                Hooks.AFTER_INITIALIZE_FLAG |
                    Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
                    Hooks.BEFORE_SWAP_FLAG |
                    Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            )
        );
        deployCodeTo(
            "CSMM.sol",
            abi.encode(
                manager,
                address(vrlManagerStub),
                glpFeeConfigManagerStub,
                2000 //usdc treshold is 20% of initial liquidity added
            ),
            hookAddress
        );
        hookAndLDToken = CSMM(hookAddress);
        hookAndLDTokenCurrency = Currency.wrap(hookAddress);

        // deploy the stable token
        uint256 stableTokenInitialsupply = 100000 ether;
        stableToken = new MockERC20("Stable Test Token", "USDC", 18);
        stableTokenCurrency = Currency.wrap(address(stableToken));

        // // deploy the ALM stub
        // alm = new ALMStub(
        //     vrlManagerStub,
        //     stableToken,
        //     address(swapRouter),
        //     key,
        //     hookAddress
        // );

        // mint some stable tokens for ourselves
        stableToken.mint(address(this), stableTokenInitialsupply);
        stableToken.mint(user1, stableTokenInitialsupply);
        stableToken.mint(user2, stableTokenInitialsupply);

        // set amount to approve for each address
        address[10] memory toApprove = [
            address(swapRouter),
            address(swapRouterNoChecks),
            address(modifyLiquidityRouter),
            address(modifyLiquidityNoChecks),
            address(donateRouter),
            address(takeRouter),
            address(claimsRouter),
            address(actionsRouter),
            address(manager),
            address(hookAndLDToken)
            // address(alm)
        ];

        address[3] memory allUsers = [
            address(user1),
            address(user2),
            address(this)
        ];

        // loop and approve the right addresses to take our tokens
        for (uint256 i = 0; i < allUsers.length; i++) {
            vm.startPrank(allUsers[i]);
            for (uint256 j = 0; j < toApprove.length; j++) {
                stableToken.approve(toApprove[j], Constants.MAX_UINT256);
            }
            vm.stopPrank();
        }

        (currency0, currency1) = SortTokens.sort(
            MockERC20(Currency.unwrap(stableTokenCurrency)),
            MockERC20(Currency.unwrap(hookAndLDTokenCurrency))
        );
    }

    function setUp() public {
        deployFreshManagerAndRouters();
        deployStubs();
        deployAndApproveTokens();

        (key, ) = initPool(
            currency0,
            currency1,
            hookAndLDToken,
            3000,
            SQRT_PRICE_1_1,
            ZERO_BYTES
        );
    }

    // test erc20 token parameters
    function test_erc20TokenParams() public view {
        // validate the erc20 properties of the hook contract
        string memory name = hookAndLDToken.name();
        string memory symbol = hookAndLDToken.symbol();
        uint8 decimals = hookAndLDToken.decimals();
        assertEq(name, "Liquidity Delta");
        assertEq(symbol, "LD");
        assertEq(decimals, 18);
    }

    // test deposit fiat to recieve crypto
    function test_depositFiatForCrypto() public {
        // Add some initial liquidity through the custom `addLiquidity` function
        hookAndLDToken.addLiquidity(key, 1000 ether);

        address testUser = address(user1);
        vm.startPrank(testUser);

        string memory mockNGNProof = "NGN-500000"; // currency-dollarEquivalentDeposited
        bytes32 fiatCurrencyHash = keccak256(abi.encode("NGN"));

        // first signal some liquidity using the signal contract
        liquidityVerifierStub.verifyAndSignal(mockNGNProof);

        // get balance before and after swap
        uint256 preBalance = stableToken.balanceOf(address(testUser));

        bytes memory hookData = hookAndLDToken.encodeHookData(
            nonce,
            testUser,
            fiatCurrencyHash,
            hashSignature1
        );

        // get the swap fee for this particular swap
        uint256 swapFee = hookAndLDToken.getOnrampFees(
            fiatCurrencyHash,
            swapAmount1
        );

        // subtract the fees from the swap amount, this should be the amount i expected
        uint256 expectedOutputAmount = hookAndLDToken.applyFees(
            swapAmount1,
            swapFee
        );

        // get the base fee from the GLP fee config manager and confirm we have the base fee and not the quadratic fee since we arent below treshold
        uint256 baseFee = glpFeeConfigManagerStub.getBaseFee(fiatCurrencyHash);

        assertEq(swapFee, baseFee);

        // then make a swap
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(swapAmount1),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            hookData
        );

        uint256 postBalance = stableToken.balanceOf(address(testUser));
        uint256 LDHookBalance = hookAndLDToken.balanceOf(
            address(hookAndLDToken)
        );

        // make sure the user's balance increases by the output amount
        assertEq(postBalance - preBalance, expectedOutputAmount);
        // make sure the balance of LD tokens increases accordingly
        assertEq(LDHookBalance, uint256(swapAmount1));

        vm.startPrank(testUser);
    }

    // test for fiat to crpyto swap when liquidity has not been signalled
    function test_depositFiatForCryptoWithoutLiquiditySignal() public {
        // Add some initial liquidity through the custom `addLiquidity` function
        uint256 initialDeposit = 1000 ether;
        hookAndLDToken.addLiquidity(key, initialDeposit);

        address testUser = address(user1);
        vm.startPrank(testUser);

        bytes32 fiatCurrencyHash = keccak256(abi.encode("NGN"));

        // get balance before and after swap
        uint256 preBalance = stableToken.balanceOf(address(testUser));

        bytes memory hookData = hookAndLDToken.encodeHookData(
            nonce,
            testUser,
            fiatCurrencyHash,
            hashSignature1
        );

        // then make a swap and expect an error because we didnt signal liquidity
        vm.expectRevert();
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(swapAmount1),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            hookData
        );
        vm.stopPrank();
    }

    // confirm quadratic increase in fees when treshold is met
    function test_quadraticFeeIncreaseWhenTresholdIsMet() public {
        // Add some initial liquidity through the custom `addLiquidity` function
        // since we want to withdraw 100USDC and we want to make sure w hit the fee when we get to 20% of initial liquidity
        // put an initial liquidity of 110, so when we withdraw 100, we are left with 10, which will trigger treshold fee
        uint256 initialDeposit = 110;
        hookAndLDToken.addLiquidity(key, initialDeposit);

        address testUser = address(user1);
        vm.startPrank(testUser);

        string memory mockNGNProof = "NGN-500000"; // currency-dollarEquivalentDeposited
        bytes32 fiatCurrencyHash = keccak256(abi.encode("NGN"));

        // first signal some liquidity using the signal contract
        liquidityVerifierStub.verifyAndSignal(mockNGNProof);

        // get balance before and after swap
        uint256 preBalance = stableToken.balanceOf(address(testUser));

        bytes memory hookData = hookAndLDToken.encodeHookData(
            nonce,
            testUser,
            fiatCurrencyHash,
            hashSignature1
        );

        // get the swap fee for this particular swap
        uint256 swapFee = hookAndLDToken.getOnrampFees(
            fiatCurrencyHash,
            swapAmount1
        );

        // get the base fee from the GLP fee config manager and confirm we have the base fee and not the quadratic fee since we arent below treshold
        uint256 baseFee = glpFeeConfigManagerStub.getBaseFee(fiatCurrencyHash);
        // make sure we are not paying teh base fee
        assert(swapFee > baseFee);

        // then make a swap
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(swapAmount1),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            hookData
        );

        // subtract the fees from the swap amount, this should be the amount i expected
        uint256 expectedOutputAmount = hookAndLDToken.applyFees(
            swapAmount1,
            swapFee
        );

        uint256 postBalance = stableToken.balanceOf(address(testUser));
        uint256 LDHookBalance = hookAndLDToken.balanceOf(
            address(hookAndLDToken)
        );

        uint256 hookUSDCBalance = hookAndLDToken.totalStableCoinSupply();

        // make sure the user's balance increases by the output amount
        assertEq(postBalance - preBalance, expectedOutputAmount);
        // make sure the balance of LD tokens increases accordingly
        assertEq(LDHookBalance, uint256(swapAmount1));
        // make sure the USDC Balance of the pool is the initialdeposit - withdraw amount to make sure it is balanced
        assertEq(hookUSDCBalance, initialDeposit - expectedOutputAmount);

        vm.startPrank(testUser);
    }

    // test for crypto to fiat swap using left over LD tokens in pool
    function test_depositCryptoForFiat() public {
        // add some initial liquidity to the pool
        uint256 initialDeposit = 1000 ether;
        hookAndLDToken.addLiquidity(key, initialDeposit);

        // get some LD in the pool by doing a swap as user1
        address testUser1 = address(user1);
        address testUser2 = address(user2);

        vm.startPrank(testUser1);

        string memory mockNGNProof = "NGN-500000"; // currency-dollarEquivalentDeposited
        bytes32 fiatCurrencyHash = keccak256(abi.encode("NGN"));

        // first signal some liquidity using the signal contract to deposit LD to swap
        liquidityVerifierStub.verifyAndSignal(mockNGNProof);
        bytes memory hookData = hookAndLDToken.encodeHookData(
            nonce,
            testUser1,
            fiatCurrencyHash,
            hashSignature1
        );
        // then make a swap
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(swapAmount1),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            hookData
        );
        vm.stopPrank();

        // increment block by approximate number of blocks per day
        // assume a day has passed and let rebate accrue
        uint256 currentBlock = block.number;
        uint256 blockIncrement = 50000;
        vm.roll(currentBlock + blockIncrement);

        // Make another swap as another user using some part of ld left by user1's swap
        vm.startPrank(user2);
        uint256 fiatBalanceBefore = vrlManagerStub.balanceOf(
            user2,
            fiatCurrencyHash
        );
        bytes memory hookData2 = hookAndLDToken.encodeHookData(
            nonce,
            testUser2,
            fiatCurrencyHash,
            hashSignature2
        );
        // get the swap fee for this particular swap
        uint256 swapFee = hookAndLDToken.getOffRampFees(
            fiatCurrencyHash,
            swapAmount1
        );

        // // subtract the fees from the swap amount, this should be the amount i expected
        uint256 expectedFiatAmount = hookAndLDToken.applyFees(
            swapAmount2,
            swapFee
        );

        // get crypto balance before
        uint256 cryptoBalanceBefore = stableToken.balanceOf(testUser2);
        // also get the rebate for this particular swap
        uint256 rebate1e6 = hookAndLDToken.calculateRebateFee(fiatCurrencyHash);
        uint256 expectedDebit = hookAndLDToken.applyFees(
            swapAmount2,
            rebate1e6
        );
        swapRouter.swap(
            key,
            // TODO: extract the zero for one variable to actually check the addresses rather than assuming the 0 token would be the fiat because of the way it is generated
            IPoolManager.SwapParams({
                zeroForOne: false, //not a zero for one swap
                amountSpecified: -int256(swapAmount2),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            hookData2
        );
        uint256 cryptoBalanceAfter = stableToken.balanceOf(testUser2);
        // assert rebate was successfull
        assertEq(cryptoBalanceBefore - cryptoBalanceAfter, expectedDebit);

        // assert balance
        // VRL balance should increase by expectedFiatAmount
        // check for VRL balance in the VRLManager reduced
        uint256 fiatBalanceAfter = vrlManagerStub.balanceOf(
            user2,
            fiatCurrencyHash
        );
        assertEq(fiatBalanceAfter - fiatBalanceBefore, expectedFiatAmount);

        vm.stopPrank();
    }

    // validate the calculation for dynamic fees when reserves treshold is met
    function test_dynamicTresholdFeeCalculation() public view {
        uint256 usdcAmount = 100 * 1e6; // 100 USDC
        uint256 currentUSDC = 250 * 1e6; // 250 USDC current reserves
        uint256 initialUSDC = 1000 * 1e6; // 1000 USDC initial reserves
        uint256 tauBps = 2000; // 20% threshold

        uint256 dynamicFeeInPips = hookAndLDToken.calculateDynamicTresholdFee(
            usdcAmount,
            currentUSDC,
            initialUSDC,
            tauBps
        );

        assertEq(dynamicFeeInPips, 437500);
    }

    // validate JIT Pools use when there is not enough LD for a given fiat in the pool
    // function test_validateJITFiat() public {
    //     uint256 fiatPoolDeposit = 100000;
    //     uint256 cryptoPoolDeposit = 100000;

    //     uint256 fiatFeeTreshold = 50000;
    //     uint256 cryptoFeeTreshold = 50000;

    //     // signal liquidity to deposit VRL
    //     // Add some initial liquidity through the custom `addLiquidity` function
    //     hookAndLDToken.addLiquidity(key, 1000 ether);

    //     address testUser = address(user1);
    //     vm.startPrank(testUser);

    //     string memory mockNGNProof = "NGN-5000000"; // currency-dollarEquivalentDeposited
    //     bytes32 currencyHash = keccak256(abi.encode("NGN"));

    //     // first signal some liquidity using the signal contract
    //     liquidityVerifierStub.verifyAndSignal(mockNGNProof);
    //     // ALM approved to take stablecoin

    //     alm.createPool(
    //         fiatPoolDeposit,
    //         cryptoPoolDeposit,
    //         fiatFeeTreshold,
    //         cryptoFeeTreshold,
    //         currencyHash
    //     );
    //     // validate pool contains amount
    //     uint256 cryptoAmount = alm.stablecoinPool(
    //         currencyHash,
    //         testUser
    //     );
    //     // console.log(cryptoAmount);
    //     // uint256 fiatAmount = ;

    //     vm.stopPrank();
    // }
    // validate that when there is no LD, a counter position should be opened for the user
}
