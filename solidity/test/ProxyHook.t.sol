// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {MockERC20} from "@uniswap/v4-core/lib/solmate/src/test/utils/mocks/MockERC20.sol";
import {SortTokens} from "@uniswap/v4-core/test/utils/SortTokens.sol";
import {ProxyHook} from "../src/ProxyHook.sol";
import {IToken} from "../src/IToken.sol";
import {MockRFS} from "./mock/rfs.sol";

contract ProxyPoolTest is Test, Deployers {
    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;

    ProxyHook hook;
    MockRFS rfs;
    // store the currencies
    Currency internal _currency0;
    Currency internal _currency1;
    Currency internal _currency2;
    Currency internal _currency3;

    uint160 ZERO_FOR_ONE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 ONE_FOR_ZERO_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    // store the keys for the different pools
    PoolKey corePoolKey;
    PoolKey proxyPoolKey;

    function deployAndApproveITokens(
        string memory name,
        string memory symbol,
        address underlyingAsset,
        uint256 base_vts
    ) internal returns (Currency currency) {
        IToken token = new IToken(
            name,
            symbol,
            underlyingAsset,
            //address(rfs),
            base_vts
        );

        address[10] memory toApprove = [
            address(swapRouter),
            address(swapRouterNoChecks),
            address(modifyLiquidityRouter),
            address(modifyLiquidityNoChecks),
            address(donateRouter),
            address(takeRouter),
            address(claimsRouter),
            address(nestedActionRouter.executor()),
            address(actionsRouter),
            address(manager)
        ];

        for (uint256 i = 0; i < toApprove.length; i++) {
            token.approve(toApprove[i], Constants.MAX_UINT256);
        }

        // ! Make sure to approve the ITokens to take out 'underlyingAsset'
        IERC20Minimal(underlyingAsset).approve(address(token), Constants.MAX_UINT256);
        return Currency.wrap(address(token));
    }

    function deployCurrencies() public {
        uint256 baseVts = 10_000;

        rfs = new MockRFS();

        Currency _currencyA = deployMintAndApproveCurrency();
        Currency _currencyB = deployMintAndApproveCurrency();

        Currency _currencyC = deployAndApproveITokens(
            "Intents TOKEN0 Settlement Receipt", "iTOKEN0R", Currency.unwrap(_currencyA), baseVts
        );
        Currency _currencyD = deployAndApproveITokens(
            "Intents TOKEN1 Settlement Receipt", "ITOKEN1R", Currency.unwrap(_currencyB), baseVts
        );

        (_currency0, _currency1) =
            SortTokens.sort(MockERC20(Currency.unwrap(_currencyA)), MockERC20(Currency.unwrap(_currencyB)));

        (_currency2, _currency3) =
            SortTokens.sort(MockERC20(Currency.unwrap(_currencyC)), MockERC20(Currency.unwrap(_currencyD)));
    }

    function deployCorePool() public {
        //  Deploy the pool without the hook
        (corePoolKey,) = initPool(_currency2, _currency3, IHooks(address(0)), 3000, SQRT_PRICE_1_1);
    }

    function deployProxyPool() public {
        // Proxy pool needs hook not core pool
        address hookAddress = address(
            uint160(
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                    | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            )
        );

        //  Deploy the hook contract
        deployCodeTo("ProxyHook.sol", abi.encode(manager, corePoolKey), hookAddress);
        hook = ProxyHook(hookAddress);

        //  Deploy the pool with the hook
        (proxyPoolKey,) = initPool(_currency0, _currency1, hook, 3000, SQRT_PRICE_1_1);
    }

    function mintAndApproveHookToMintITokens() public {
        uint256 mintAmount = Constants.MAX_UINT256 / 100e18;
        address custodian = address(hook);

        IToken itoken0 = IToken(Currency.unwrap(corePoolKey.currency0));
        IToken itoken1 = IToken(Currency.unwrap(corePoolKey.currency1));

        // approve the hook contract to be able to mint tokens on promise
        itoken0.whitelistCustodian(address(hook), true);
        itoken1.whitelistCustodian(address(hook), true);

        // whitelist the self as an lp
        itoken0.whitelistLP(address(this), true);
        itoken1.whitelistLP(address(this), true);

        itoken0.whitelistLP(address(manager), true);
        itoken1.whitelistLP(address(manager), true);
        itoken0.wrap(custodian, mintAmount);
        itoken1.wrap(custodian, mintAmount);
    }

    function setUp() public {
        deployFreshManagerAndRouters();
        deployCurrencies();
        deployCorePool();
        deployProxyPool();
        mintAndApproveHookToMintITokens();
    }

    function test_cannotModifyLiquidityOfProxyHook() public {
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(
            proxyPoolKey,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1000e18, salt: bytes32(0)}),
            ZERO_BYTES
        );
    }

    function test_canModifyLiquidityOfCoreHook() public {
        modifyLiquidityRouter.modifyLiquidity(
            corePoolKey,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: bytes32(0)}),
            ZERO_BYTES
        );
    }

    function test_swap_exactInput_zeroForOneOnCore() public {
        modifyLiquidityRouter.modifyLiquidity(
            corePoolKey,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1000e18, salt: bytes32(0)}),
            ZERO_BYTES
        );

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        uint256 selfBalanceOfTokenABefore = corePoolKey.currency0.balanceOfSelf();

        swapRouter.swap(
            corePoolKey,
            SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            settings,
            ZERO_BYTES
        );

        uint256 selfBalanceOfTokenAAfter = corePoolKey.currency0.balanceOfSelf();

        assertEq(selfBalanceOfTokenABefore - selfBalanceOfTokenAAfter, 1e18);
    }

    function test_swap_exactInput_zeroForOneOnProxy() public {
        // add some liquidity to the core pool since it is where swaps will actually take place and not the proxy pool
        modifyLiquidityRouter.modifyLiquidity(
            corePoolKey,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 10000e18, salt: bytes32(0)}),
            ZERO_BYTES
        );

        // add some liquidity to the core pool since it is where swaps will actually take place and not the proxy pool
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        uint256 selfBalanceOfTokenABefore = proxyPoolKey.currency0.balanceOfSelf();
        uint256 selfBalanceOfTokenBBefore = proxyPoolKey.currency1.balanceOfSelf();

        uint256 swapAmount = 100;
        swapRouter.swap(
            proxyPoolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(swapAmount), sqrtPriceLimitX96: ZERO_FOR_ONE_LIMIT}),
            settings,
            abi.encode(address(this))
        );

        uint256 selfBalanceOfTokenAAfter = proxyPoolKey.currency0.balanceOfSelf();
        uint256 selfBalanceOfTokenBAfter = proxyPoolKey.currency1.balanceOfSelf();

        assertEq(selfBalanceOfTokenABefore - selfBalanceOfTokenAAfter, swapAmount);
        assert(selfBalanceOfTokenBAfter > selfBalanceOfTokenBBefore);
    }

    function test_swap_exactInput_oneForZeroOnProxy() public {
        // add some liquidity to the core pool since it is where swaps will actually take place and not the proxy pool
        modifyLiquidityRouter.modifyLiquidity(
            corePoolKey,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 10000e18, salt: bytes32(0)}),
            ZERO_BYTES
        );

        // add some liquidity to the core pool since it is where swaps will actually take place and not the proxy pool
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        uint256 selfBalanceOfTokenABefore = proxyPoolKey.currency0.balanceOfSelf();
        uint256 selfBalanceOfTokenBBefore = proxyPoolKey.currency1.balanceOfSelf();

        uint256 swapAmount = 100;
        swapRouter.swap(
            proxyPoolKey,
            SwapParams({zeroForOne: false, amountSpecified: -int256(swapAmount), sqrtPriceLimitX96: ONE_FOR_ZERO_LIMIT}),
            settings,
            abi.encode(address(this))
        );

        uint256 selfBalanceOfTokenAAfter = proxyPoolKey.currency0.balanceOfSelf();
        uint256 selfBalanceOfTokenBAfter = proxyPoolKey.currency1.balanceOfSelf();

        assertEq(selfBalanceOfTokenBBefore - selfBalanceOfTokenBAfter, swapAmount);
        assert(selfBalanceOfTokenAAfter > selfBalanceOfTokenABefore);
    }

    function test_swap_exactOutput_zeroForOneOnProxy() public {
        // add some liquidity to the core pool since it is where swaps will actually take place and not the proxy pool
        modifyLiquidityRouter.modifyLiquidity(
            corePoolKey,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 10000e18, salt: bytes32(0)}),
            ZERO_BYTES
        );

        // add some liquidity to the core pool since it is where swaps will actually take place and not the proxy pool
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        uint256 selfBalanceOfTokenABefore = proxyPoolKey.currency0.balanceOfSelf();
        uint256 selfBalanceOfTokenBBefore = proxyPoolKey.currency1.balanceOfSelf();

        uint256 swapAmount = 100;
        swapRouter.swap(
            proxyPoolKey,
            SwapParams({zeroForOne: true, amountSpecified: int256(swapAmount), sqrtPriceLimitX96: ZERO_FOR_ONE_LIMIT}),
            settings,
            abi.encode(address(this))
        );

        uint256 selfBalanceOfTokenAAfter = proxyPoolKey.currency0.balanceOfSelf();
        uint256 selfBalanceOfTokenBAfter = proxyPoolKey.currency1.balanceOfSelf();

        assert(selfBalanceOfTokenABefore > selfBalanceOfTokenAAfter);

        assertEq(selfBalanceOfTokenBAfter, selfBalanceOfTokenBBefore + swapAmount);
    }

    function test_swap_exactOutput_oneForZeroOnProxy() public {
        // add some liquidity to the core pool since it is where swaps will actually take place and not the proxy pool
        modifyLiquidityRouter.modifyLiquidity(
            corePoolKey,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 10000e18, salt: bytes32(0)}),
            ZERO_BYTES
        );

        // add some liquidity to the core pool since it is where swaps will actually take place and not the proxy pool
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        uint256 selfBalanceOfTokenABefore = proxyPoolKey.currency0.balanceOfSelf();
        uint256 selfBalanceOfTokenBBefore = proxyPoolKey.currency1.balanceOfSelf();

        uint256 swapAmount = 100;
        swapRouter.swap(
            proxyPoolKey,
            SwapParams({zeroForOne: false, amountSpecified: int256(swapAmount), sqrtPriceLimitX96: ONE_FOR_ZERO_LIMIT}),
            settings,
            abi.encode(address(this))
        );

        uint256 selfBalanceOfTokenAAfter = proxyPoolKey.currency0.balanceOfSelf();
        uint256 selfBalanceOfTokenBAfter = proxyPoolKey.currency1.balanceOfSelf();

        assert(selfBalanceOfTokenBBefore > selfBalanceOfTokenBAfter);

        assertEq(selfBalanceOfTokenAAfter, selfBalanceOfTokenABefore + swapAmount);
    }
}
