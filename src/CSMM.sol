// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IVRLManager} from "./interfaces/IVRLManager.sol";
import {IGLPFeeManager} from "./interfaces/IGLPFeeManager.sol";
import {LimitedERC20} from "./LimitedERC20.sol";
import {SignatureLib} from "./lib/Signature.sol";
import "forge-std/console.sol";

// A CSMM is a pricing curve that follows the invariant `x + y = k`

contract CSMM is BaseHook, LimitedERC20 {
    using CurrencySettler for Currency;

    error AddLiquidityThroughHook();
    error InsufficientFiat();
    error CannotWithdrawZero();

    struct CallbackData {
        uint256 amountEach;
        Currency currency0;
        Currency currency1;
        address sender;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "NOT_OWNER");
        _;
    }

    ERC20 stableToken;

    address owner;
    uint256 public totalStableCoinSupply;
    uint256 initialStableCoinDeposit;
    uint256 reserveTresholdBPS;
    uint256 totalFeesCollected; // Total fees in wei
    uint256 totalRebatesPaid; // Total fees in wei

    IVRLManager vrlManager;
    IGLPFeeManager feeConfigManager;
    mapping(bytes => bool) public usedSignatures;
    mapping(bytes32 => uint256) public fiatDelta;
    mapping(bytes32 => uint256) public fiatRebateLastBlock;

    // rebate variables
    // initial rebate fee for protocol. 0.01% in 1e6 scale
    uint256 public constant MAX_REBATE = 800000; // maximum possible rebate should be 80% of inputamount

    uint256 public rebatePerBlock = 10; // 0.001% per block
    uint256 public rebatePerUnitBalanceShort = 10; // 0.001% extra unit stablecoin in the pool
    uint256 public rebateBufferTreshold = 100; // if net fees are over 100 uints of stable token(e,g 100usdc) reduce base fee

    constructor(
        IPoolManager _manager,
        IVRLManager _vrlManager,
        IGLPFeeManager _feeConfigManager,
        uint256 _reserveTresholdBPS
    ) BaseHook(_manager) LimitedERC20("Liquidity Delta", "LD", 18) {
        vrlManager = _vrlManager;
        reserveTresholdBPS = _reserveTresholdBPS;
        feeConfigManager = _feeConfigManager;

        owner = msg.sender;
    }

    function setReserveTreshold(uint256 _reserveTresholdBPS) public onlyOwner {
        reserveTresholdBPS = _reserveTresholdBPS;
    }

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: true,
                beforeAddLiquidity: true, // Don't allow adding liquidity normally
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true, // Override how swaps are done
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true, // Allow beforeSwap to return a custom delta
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    // after initialize hook to store the two currencies of the hook
    function afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24 tick,
        bytes calldata
    ) external override onlyByPoolManager returns (bytes4) {
        address stableCurrencyAddress = Currency.unwrap(key.currency0) ==
            address(this)
            ? Currency.unwrap(key.currency1)
            : Currency.unwrap(key.currency0);

        stableToken = ERC20(stableCurrencyAddress);
        return this.afterInitialize.selector;
    }

    // Disable adding liquidity through the PM
    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        revert AddLiquidityThroughHook();
    }

    // Custom add liquidity function
    function addLiquidity(PoolKey calldata key, uint256 amountEach) external {
        poolManager.unlock(
            abi.encode(
                CallbackData(
                    amountEach,
                    key.currency0,
                    key.currency1,
                    msg.sender
                )
            )
        );
    }

    function _unlockCallback(
        bytes calldata data
    ) internal override returns (bytes memory) {
        CallbackData memory callbackData = abi.decode(data, (CallbackData));

        // There should be two tokens in the pool
        // one should be this token which is the hook contract
        // and the other should be the token that will be used to inject liquidity
        // We make a check to make sure we take the token that is not 'LD' i.e the stable coin deposited

        // Settle `amountEach` of stablecoin from the sender
        // i.e. Create a debit of `amountEach` of the stable coin with the Pool Manager

        // Since we didn't go through the regular "modify liquidity" flow,
        // the PM just has a debit of `amountEach` of the stable currency from us
        // We can, in exchange, get back ERC-6909 claim tokens for `amountEach` of each currency
        // to create a credit of `amountEach` of each currency to us
        // that balances out the debit

        // We will store those claim tokens with the hook, so when swaps take place
        // liquidity from our CSMM can be used by minting/burning claim tokens the hook owns

        // we have two tokens in the pool, one which would have the hook's address(FIAT) and the other would be the stable currency
        // the stable currency is one where the address is not the same address as the one of the hook
        Currency stableCurrency = Currency.unwrap(callbackData.currency0) ==
            address(this)
            ? callbackData.currency1
            : callbackData.currency0;

        stableCurrency.settle(
            poolManager,
            callbackData.sender,
            callbackData.amountEach,
            false // `burn` = `false` i.e. we're actually transferring tokens, not burning ERC-6909 Claim Tokens
        );

        stableCurrency.take(
            poolManager,
            address(this),
            callbackData.amountEach,
            true // true = mint claim tokens for the hook, equivalent to money we just deposited to the PM
        );

        // if this is the first deposit, then set the variable
        if (initialStableCoinDeposit == 0) {
            initialStableCoinDeposit = callbackData.amountEach;
        }
        totalStableCoinSupply += callbackData.amountEach;

        return "";
    }

    // // Swapping
    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes memory hookData
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        // check if it is a crypto => fiat swap or fiat => crypto swap
        // i.e isFiatToCrypto if it is a zeroForOneSwap and the zero currency is this address of the LD(FIAT represented) token
        // i.e isFiatToCrypto if it is a OneForZeroSwap and the one currency is this address of the LD(FIAT represented) token
        bool isFiatToCrypto = params.zeroForOne
            ? Currency.unwrap(key.currency0) == address(this)
            : Currency.unwrap(key.currency1) == address(this);

        // get the absolute value of the provided amount
        int256 amountInOutPositive = params.amountSpecified > 0
            ? int256(params.amountSpecified)
            : int256(-params.amountSpecified);

        (Currency fiat, Currency crypto) = Currency.unwrap(key.currency0) ==
            address(this)
            ? (key.currency0, key.currency1)
            : (key.currency1, key.currency0);

        (
            address userAddress,
            bytes32 fiatCurrencyHash
        ) = decodeAndVerifyHookData(hookData, uint256(amountInOutPositive));

        // define the swap delta variable to be assigned depending on the direction of the swap
        BeforeSwapDelta beforeSwapDelta;

        if (isFiatToCrypto) {
            beforeSwapDelta = _handleFiatToCryptoSwap(
                userAddress,
                fiatCurrencyHash,
                uint256(amountInOutPositive),
                crypto
            );
        } else {
            beforeSwapDelta = _handleCryptoToFiatSwap(
                userAddress,
                fiatCurrencyHash,
                uint256(amountInOutPositive),
                crypto
            );
        }

        // TODO: Fee rebating and stuff and JIT liquidity pools
        return (this.beforeSwap.selector, beforeSwapDelta, 0);
    }

    // swap utility functions
    function _handleFiatToCryptoSwap(
        address user,
        bytes32 fiatCurrencyHash,
        uint256 amountIn,
        Currency stableCurrency
    ) private returns (BeforeSwapDelta) {
        // if this is a fiat to crypto swap then they must have at least the amount they want to withdraw in the VRLManager contract
        // delta should be equal to the `amountIn`, just to make sure the vrlManager is in charge of the LD minted in the hook contract
        uint256 delta = vrlManager.withdrawVRL(
            user,
            fiatCurrencyHash,
            uint256(amountIn),
            true //should lock the VRL being withdrawn
        );
        // increase the supply of LD tokens in the hook by delta
        mint(delta);

        // get the fees
        uint fee1e6 = getOnrampFees(fiatCurrencyHash, amountIn);
        // calculate the amout out
        uint amountOut = applyFees(amountIn, fee1e6);
        uint256 feePaid = amountIn - amountOut;
        totalFeesCollected += feePaid;

        // increment the fiat delta for this currency by the amount in
        fiatDelta[fiatCurrencyHash] += uint256(amountIn);
        // decrement the total stablecoin supply by the amount being disbursed out
        totalStableCoinSupply -= uint256(amountOut);
        // when we put a token in the pool start, set the block to accumulate rebates over time for that fiat deposit
        // Only do this if the block has not been set prior so we do not override an uncollected rebate in progress
        if (fiatRebateLastBlock[fiatCurrencyHash] == 0) {
            fiatRebateLastBlock[fiatCurrencyHash] = block.timestamp;
        }

        // settle the pool manager with the amount of crypto we are giving them in the block above '-amountInOutPositive'
        // in order to settle the deltas
        stableCurrency.settle(
            poolManager,
            address(this),
            uint256(amountOut),
            true // `burn` = `true` i.e. we're actually burning ERC-6909 Claim Tokens we minted('take') when we added liquidity
        );
        return
            toBeforeSwapDelta(
                // take 0 LD(FIAT) tokens from the user since it cacnt be transferred anyway
                int128(0),
                // give them the amount requested for in stable coins
                int128(-int256(amountOut))
            );
    }

    function _handleCryptoToFiatSwap(
        address user,
        bytes32 fiatCurrencyHash,
        uint256 amountIn,
        Currency stableCurrency
    ) private returns (BeforeSwapDelta) {
        // validate availability of liquidity
        uint256 availableLiquidityForFiat = fiatDelta[fiatCurrencyHash];
        if (availableLiquidityForFiat < uint256(amountIn)) {
            // check if there is a fee bost
            bool isFeeBoost = false;
            if (!isFeeBoost) {
                revert InsufficientFiat();
            }
            // if there is call an external pool which would get some tokens into the pool
            // then run some checks to be sure
            // then proceed with the swap as usual
        }

        // check if there is a rebate available for this currency
        // if there is, apply it to the input amount and give a discount(rebate)
        uint256 rebateFee1e6 = calculateRebateFee(fiatCurrencyHash);

        // after application of rebates, this is the actual amount the user would be debited of
        uint256 cryptoAmountToDeduct = applyFees(amountIn, rebateFee1e6);

        // take the deposit of crypto made to the pool manager
        stableCurrency.take(
            poolManager,
            address(this),
            uint256(cryptoAmountToDeduct),
            true // true = mint claim tokens for the hook, equivalent to money we just deposited to the PM
        );

        // send back the rebate amount to the user
        // which is the the amountIn - amountToDebit
        // it is basically a refund/discount
        // if there are no rebates, it is zero
        uint256 rebateAmount = amountIn - cryptoAmountToDeduct;
        totalRebatesPaid += rebateAmount;
        stableCurrency.take(
            poolManager,
            user,
            uint256(rebateAmount),
            false // false = do not mint claim tokens for the user, make an ERC20 transfer to them since we want to give them actual funds
        );
        // we do this two staged `take`
        // because we need to `take` the equivalent of the amountIn to balance the deltas
        // so we `take` some for the hook contract
        // and we `take` the rebate/refund amount back to the user
        // where they both sum up to the input amount

        // calculate the fees then the amount out
        uint256 fee1e6 = getOffRampFees(fiatCurrencyHash, amountIn);
        uint256 fiatAmountOut = applyFees(amountIn, fee1e6);
        uint256 feePaid = amountIn - fiatAmountOut;
        totalFeesCollected += feePaid;

        burn(uint256(fiatAmountOut));
        vrlManager.unlockLiquidityDelta(
            user,
            fiatCurrencyHash,
            uint256(fiatAmountOut)
        );
        totalStableCoinSupply += uint256(cryptoAmountToDeduct);
        // when we take a fiat out of the pool, restart the rebate block counter
        // fiatRebateLastBlock[fiatCurrencyHash] = 0;
        fiatDelta[fiatCurrencyHash] -= uint256(fiatAmountOut);
        // if there is still some fiat, then we reset the rebate counter
        // otherwise set rebate counter to 0
        fiatRebateLastBlock[fiatCurrencyHash] = fiatDelta[fiatCurrencyHash] > 0
            ? block.number
            : 0;

        return
            toBeforeSwapDelta(
                // take 'amountInOutPositive' of cryptoToken from the sender
                int128(int256(amountIn)),
                // give them 0 LD tokens back since it cannot be transferred anyways
                int128(0)
            );
    }

    /**
     * @notice Applies a fee to a given base amount.
     * @dev This function calculates and deducts a fee from the base amount, where the fee is expressed in 1e6 scale.
     * @param baseAmount The initial amount before applying fees.
     * @param fee1e6 The fee percentage in 1e6 format (e.g., 100000 = 10%).
     * @return The final amount after deducting the fee.
     */
    function applyFees(
        uint256 baseAmount,
        uint256 fee1e6
    ) public pure returns (uint256) {
        // Ensure the fee percentage is non-negative
        if (fee1e6 == 0) return baseAmount;

        // Calculate the fee amount
        // fee1e6 is expressed in 1e6 scale, so we divide by 1e6 to get the actual percentage
        uint256 feeAmount = (baseAmount * fee1e6) / 1e6;
        // Subtract the fee from the base amount to get the final amount
        return baseAmount - feeAmount;
    }

    // function handleCryptoToFiatSwap(uint256 amountIn, bytes32 currencyHash) {}

    // helper function to hash the currency
    function hashCurrency(
        string memory currency
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(currency));
    }

    // helper function to get hook data
    function encodeHookData(
        uint256 nonce,
        address userAddress,
        bytes32 fiatCurrencyHash,
        bytes calldata signature
    ) public pure returns (bytes memory) {
        return abi.encode(nonce, fiatCurrencyHash, signature, userAddress);
    }

    // helper function to decode hook data and make sure the provided signature is valid across the nonce and amount
    function decodeAndVerifyHookData(
        bytes memory encodedData,
        uint256 amount
    ) public returns (address, bytes32) {
        (
            uint256 nonce,
            bytes32 fiatCurrencyHash,
            bytes memory signature,
            address userAddress
        ) = abi.decode(encodedData, (uint256, bytes32, bytes, address));
        require(!usedSignatures[signature], "USED_SIGNATURE");

        bytes32 dataHash = generateSignaturePayload(nonce, amount);
        require(
            SignatureLib.verify(userAddress, dataHash, signature),
            "INVALID_SIGNATURE"
        );
        usedSignatures[signature] = true;

        return (userAddress, fiatCurrencyHash);
    }

    // helper to verify and parse hook data
    function generateSignaturePayload(
        uint256 nonce,
        uint256 amount
    ) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(nonce, amount));
    }

    // Fiet Protocol Fees:
    // Denominated in pips (one-hundredth bps) 5000pips => 0.5%
    // FIAT => USDC
    // 1. Base Fee: GLPs set for fiat-to-USDC (e.g., 0.1% on 100 AUD = 0.1 USDC).
    // 2. Threshold Fee: Quadratic if USDC < 20% (e.g., 0.25 USDC on 100 USDC at 15% reserves).
    function getOnrampFees(
        bytes32 currencyHash,
        uint256 withdrawAmount
    ) public returns (uint256) {
        // get base fee from external contract
        uint256 baseFee = feeConfigManager.getBaseFee(currencyHash);
        uint256 stableTokenDecimals = 10 ** stableToken.decimals();
        uint256 decimalAdjustedRebaseBuffer = rebateBufferTreshold *
            stableTokenDecimals;

        // adjust the base fee based on net fees collected

        // Adjustment based on fees vs rebates
        int256 netFeeBalance = int256(totalFeesCollected) -
            int256(totalRebatesPaid);
        if (netFeeBalance < 0) {
            // scale the netfee down to a unit token by divinding by the decimal place
            // then add an extra fee per deficit balance
            uint256 adjustment = (uint256(-netFeeBalance) /
                stableTokenDecimals) * rebatePerUnitBalanceShort; // +10 per 1 USDC surplus
            baseFee += adjustment;
        } else if (uint256(netFeeBalance) > decimalAdjustedRebaseBuffer) {
            // Reduce by 50% if we have recuperated our loses and fees + buffer > rebates
            baseFee = baseFee / 2;
        }

        // check if it has gotten below the treshold to apply treshold fee
        uint256 dynamicTresholdFee = calculateHookDynamicTresholdFee(
            withdrawAmount
        );

        // for a FIAT -> USDC swap
        // total fee is baseFee + dynamic treshold fee
        return baseFee + dynamicTresholdFee;
    }

    // calculate the dynamic fees based on contract parameters
    function calculateHookDynamicTresholdFee(
        uint256 withdrawAmount
    ) public view returns (uint256 fee1e6) {
        return
            calculateDynamicTresholdFee(
                withdrawAmount,
                totalStableCoinSupply,
                initialStableCoinDeposit,
                reserveTresholdBPS
            );
    }
    // Example dynamic fee function in 1e6 scale

    // calculates the fees required to facilitate a swap
    // returns fee scaled by 10e6
    function calculateDynamicTresholdFee(
        uint256 usdcAmount,
        uint256 currentUSDC,
        uint256 initialUSDC,
        uint256 tauBps
    ) public pure returns (uint256 fee1e6) {
        uint256 postSwapUSDC = currentUSDC - usdcAmount;
        uint256 threshold = (tauBps * initialUSDC) / 10000; // tauBps still in bps

        if (postSwapUSDC > threshold) return 0;

        uint256 xSquared = postSwapUSDC * postSwapUSDC;
        uint256 thresholdSquared = threshold * threshold;
        uint256 scaled = (xSquared * 1000000) / thresholdSquared;
        fee1e6 = 1000000 - scaled; // Fee in 1e6 scale (e.g., 437500 => 0.4375)
        return fee1e6;
    }

    // USDC => FIAT
    // 3. Volatility Fee: On USDC-to-fiat for FX risk (e.g., 0.5 USDC on 100 USDC if AUD drops 5%).
    // 4. Priority Fee: Trader pays extra for JIT speed (e.g., 0.5 USDC on 100 USDC when LD = 0).
    // 5. Rebate: Discount on USDC-to-fiat, max 80% of base (e.g., 0.08 USDC back on 100 USDC swap).
    function getOffRampFees(
        bytes32 currencyHash,
        uint256 withdrawAmount
    ) public returns (uint256) {
        if (withdrawAmount == 0) {
            revert CannotWithdrawZero();
        }
        // volatility fee is gotten from the VRLManager in pips
        uint256 volatilityFee1e6 = vrlManager.getVolatilityFee(currencyHash);
        // calculate rebate based on time that has passed since last rebate and adjust it based on if fees > rebates
        return volatilityFee1e6;
    }

    // rebate parameters
    function calculateRebateFee(
        bytes32 currencyHash
    ) public view returns (uint256) {
        // Start with base
        uint256 rebate1e6 = 0;
        uint256 decimals = 10 ** stableToken.decimals();

        // Adjustment based on block advancement
        // the longer the time since last rebate
        // rebate fee should increase since rebate for a given currency
        // there will only be `lastRebateBlock` for a particular currency if it is still present in the pool
        uint256 lastRebateBlock = fiatRebateLastBlock[currencyHash];
        if (lastRebateBlock != 0) {
            uint256 blocksElapsed = block.number - lastRebateBlock;
            rebate1e6 += blocksElapsed * rebatePerBlock;
        }

        // cap the rebate growth to `MAX_REBATE` which is 80% to ensure rebate is never greater than input amount
        return rebate1e6 > MAX_REBATE ? MAX_REBATE : rebate1e6;
    }
}
