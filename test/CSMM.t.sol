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
// import stubs
// import {SuretyStub} from "./mock/SuretyStub.sol";
// import {LiquidityVerifierStub} from "./mock/LiquidityVerifierStub.sol";

contract CSMMTest is Test, Deployers {
    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;

    CSMM hookAndLDToken;
    MockERC20 stableToken;

    // definen for the currencies
    Currency stableTokenCurrency;
    Currency hookAndLDTokenCurrency;
    // SuretyStub suretyStub;
    // LiquidityVerifierStub verifierStub;

    function deployStubs() public {
        // verifierStub = new LiquidityVerifierStub();
        // suretyStub = new SuretyStub(verifierStub);
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

        // set amount to mint to each address
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

        // mint some stable tokens for ourselves
        stableToken.mint(address(this), stableTokenInitialsupply);

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
        hookAndLDToken.addLiquidity(key, 1);
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
        // first signal liquidity
    }
}
