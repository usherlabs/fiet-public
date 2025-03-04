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
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {SortTokens} from "@uniswap/v4-core/test/utils/SortTokens.sol";

import {VRLManagerStub} from "./mock/VRLManagerStub.sol";
import {LiquidityVerifierStub} from "./mock/LiquidityVerifierStub.sol";

contract CSMMTest is Test, Deployers {
    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;

    // Define a couple of users
    address user1 = address(0xD1798D6b74EF965d6A60f45E0036f44AEd3DfA1b);
    address user2 = address(0x5678);

    uint256 swapAmount = 1000000000000000000;
    bytes user1signatureOfAmount = hex"efc3355fd0d1bb3fb121a6071dacba11a5abf8c1e802c58e5139a1767093c9a7643fe523de91b4e4423be84e8a73eddf8bc4024f709ad1e27dd19df59f6161161b";

    CSMM hookAndLDToken;
    MockERC20 stableToken;

    // define for the currencies
    Currency stableTokenCurrency;
    Currency hookAndLDTokenCurrency;

    // define the stub contracts
    LiquidityVerifierStub liquidityVerifierStub;
    VRLManagerStub vrlManager;

    PoolSwapTest.TestSettings settings =
        PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

    function deployStubs() public {
        vrlManager = new VRLManagerStub();
        liquidityVerifierStub = new LiquidityVerifierStub(vrlManager);
    }

    function deployAndApproveTokens() public {
        // deploy the hook contract
        address hookAddress = address(
            uint160(
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
                    Hooks.BEFORE_SWAP_FLAG |
                    Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            )
        );
        deployCodeTo("CSMM.sol", abi.encode(manager), hookAddress);
        hookAndLDToken = CSMM(hookAddress);
        hookAndLDTokenCurrency = Currency.wrap(hookAddress);

        // deploy the stable token
        uint256 stableTokenInitialsupply = 100000 ether;
        stableToken = new MockERC20("Stable Test Token", "USDC", 18);
        stableTokenCurrency = Currency.wrap(address(stableToken));

        // mint some stable tokens for ourselves
        stableToken.mint(address(this), stableTokenInitialsupply);

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
        ];

        // loop and approve the right addresses to take our tokens
        for (uint256 i = 0; i < toApprove.length; i++) {
            stableToken.approve(toApprove[i], Constants.MAX_UINT256);
        }

        (currency0, currency1) = SortTokens.sort(
            MockERC20(Currency.unwrap(stableTokenCurrency)),
            MockERC20(Currency.unwrap(hookAndLDTokenCurrency))
        );
    }

    function setUp() public {
        deployFreshManagerAndRouters();
        deployAndApproveTokens();
        deployStubs();

        (key, ) = initPool(
            currency0,
            currency1,
            hookAndLDToken,
            3000,
            SQRT_PRICE_1_1,
            ZERO_BYTES
        );

        // Add some initial liquidity through the custom `addLiquidity` function
        hookAndLDToken.addLiquidity(key, 1000 ether);
    }

    function test_erc20TokenParams() public view {
        // validate the erc20 properties of the hook contract
        string memory name = hookAndLDToken.name();
        string memory symbol = hookAndLDToken.symbol();
        uint8 decimals = hookAndLDToken.decimals();
        assertEq(name, "Liquidity Delta");
        assertEq(symbol, "LD");
        assertEq(decimals, 18);
    }

    function test_userCannotTransferVRL() public {
        // ensure that the VRL tokkens cannot be created
        address recipient = address(1);
        uint256 amount = 2000;
        vm.expectRevert();
        hookAndLDToken.transfer(recipient, amount);
    }

    function test_depositfiat() public {
        // vm.prank(user1);
        string memory mockNGNProof = "NGN-50000";
        bytes32 fiatCurrency = keccak256(abi.encode("NGN"));
        // first signal liquidity using the signal contract
        liquidityVerifierStub.verifyAndSignal(mockNGNProof);
        // then check if VRL is in the contract
        uint256 userBalance = vrlManager.getUserCurrencyVRL(
            user1,
            fiatCurrency
        );
        // get balance before and after swap
        uint256 preBalance = stableToken.balanceOf(address(this));
        console.log(preBalance);
        // then make a swap
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -10 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            ZERO_BYTES
        );

        uint256 postBalance = stableToken.balanceOf(address(this));
        console.log(postBalance);
        // check if the user has recieved the funds
        // implement FIAT -> USDC swap when theres a pending LD
    }
}
