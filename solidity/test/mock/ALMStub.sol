// StubContract.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ISwapRouter} from "../../src/interfaces/ISwapRouter.sol";
import {VRLManagerStub} from "./VRLManagerStub.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {ICSMMUtils} from "../../src/interfaces/ICSMMUtils.sol";

import "forge-std/Test.sol";

contract ALMStub {
    // define pool for stablecoin CURRENCYHASH -> POOLID/USER  -> amountSignalled
    // define pool for fiat CURRENCYHASH -> POOLID/USER -> usdc deposited
    // define pool config stablecoin CURRENCYHASH -> POOLID/USER -> amount {rebateTreshold, blockNumber}
    // define pool config fiats CURRENCYHASH -> POOLID/USER -> amount {rebateTreshold, blockNumber}
    // store mapping of all the RLP's for a given cuurency

    struct PoolConfig {
        // the fee treshold required in order to facilitate a JIT liquidity provision
        uint256 feeTreshold;
        // the block number this was created at in order to support FIFO
        uint256 blockNumber;
    }

    struct TestSettings {
        bool takeClaims;
        bool settleUsingBurn;
    }

    // Stablecoin Pool for a given FIAT: CURRENCYHASH -> POOLID/USER -> Amount signaled
    mapping(bytes32 => mapping(address => uint256)) public stablecoinPool;

    // Fiat Pool for a give FIAT: CURRENCYHASH -> POOLID/USER -> USDC deposited
    mapping(bytes32 => mapping(address => uint256)) public fiatPool;

    // Stablecoin Pool Config: CURRENCYHASH -> POOLID/USER -> Config
    mapping(bytes32 => mapping(address => PoolConfig)) public stablecoinPoolConfig;

    // Fiat Pool Config: CURRENCYHASH -> POOLID/USER -> Config
    mapping(bytes32 => mapping(address => PoolConfig)) public fiatPoolConfig;

    // Store RLPs for a given currency: CURRENCYHASH -> RLPs for easy iteration
    mapping(bytes32 => address[]) public rlpList;

    // manager contracts
    VRLManagerStub vrlManager;
    MockERC20 stableToken;
    ISwapRouter swapRouter;
    PoolKey poolKey;
    ICSMMUtils hookUtils;

    constructor(
        VRLManagerStub _vrlManager,
        MockERC20 _stableToken,
        address _swapRouter,
        PoolKey memory _poolkey,
        address _hookUtils
    ) {
        vrlManager = _vrlManager;
        stableToken = _stableToken;
        swapRouter = ISwapRouter(_swapRouter);
        poolKey = _poolkey;
        hookUtils = ICSMMUtils(_hookUtils);
    }

    // provide liquidity for either fiat or usdc or both by providing an amount of each
    // should the staking happen here?
    function createPool(
        uint256 fiatAmount,
        uint256 stableCoinAmount,
        uint256 fiatFeeTreshold1e6,
        uint256 cryptoFeeTreshold1e6,
        bytes32 currencyHash
    ) public {
        address owner = msg.sender;

        // if it is their first time adding liquidity
        // add then to the list of liquidity providers
        if (stablecoinPool[currencyHash][owner] == 0 && fiatPool[currencyHash][owner] == 0) {
            rlpList[currencyHash].push(owner);
        }

        // update the state variables
        // update the crypto pool and its config
        stablecoinPool[currencyHash][owner] += stableCoinAmount;
        stablecoinPoolConfig[currencyHash][owner] =
            PoolConfig({feeTreshold: fiatFeeTreshold1e6, blockNumber: block.number});

        // update the fiat pool and its config
        fiatPool[currencyHash][owner] += fiatAmount;
        stablecoinPoolConfig[currencyHash][owner] =
            PoolConfig({feeTreshold: cryptoFeeTreshold1e6, blockNumber: block.number});

        // move in both FIAT and stables into the ALM pool
        // check if there is enough vrl to take from what has been signalled
        uint256 fiatDelta = vrlManager.withdrawVRL(
            owner,
            currencyHash,
            fiatAmount,
            false // do not lock the funds, just deduct itand return the delta
        );
        bool success = stableToken.transferFrom(owner, address(this), fiatAmount);

        require(success);
    }

    // provide function to search for a pool which matches a given fee criteria
    function injectLiquidity() public {
        // send sequivalent funds to the VRL manager to facilitate some swap
        // if conditions are met
        // perform a swap into the pool
        // first perform a swap into the pool of a specified amount
        // then focus on the conditions being
        bytes memory hashSignature1 =
            hex"668d0b690fe23e83c9e716a034bcaa6cfbf4807fa6dcdbe652d86d5a7488b28b6c78ab1365c2b0373a8d1c3394c7fc3bd3247ef895ad7d11cf7a79796d7f1a371b";
        ISwapRouter.TestSettings memory settings = ISwapRouter.TestSettings({takeClaims: false, settleUsingBurn: false});
        bytes memory hookData = hookUtils.encodeHookData(
            10, 0xD1798D6b74EF965d6A60f45E0036f44AEd3DfA1b, hookUtils.hashCurrency("NGN"), hashSignature1
        );
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true, //a zero for one swap
                amountSpecified: -int256(100),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            hookData
        );

        // validate we recieved some funds
        // assign some to the usdc pool of this user
    }
}
