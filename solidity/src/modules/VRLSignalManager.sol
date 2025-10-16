// SPDX-License-Identifier: MIT
// The VRLSpokeReceiver is a module that is responsible for verifying the liquidity signal and returning the tickers and amounts of the assets
// It is used by the `MMPositionManager` to verify the liquidity signal and return the tickers and amounts of the assets
// and to ensure that the MM has enough reserves in their signal to cover their liquidity commitment to the Market
pragma solidity ^0.8.0;

import {MarketMaker} from "../libraries/MarketMaker.sol";
import {IMarketFactory} from "../interfaces/IMarketFactory.sol";
import {ISpokeVerifier} from "../interfaces/ISpokeVerifier.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {LiquiditySignal} from "../types/Position.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {IOracleRegistry} from "../interfaces/IOracleRegistry.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ILCC} from "../interfaces/ILCC.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityUtils} from "../libraries/LiquidityUtils.sol";
import {IVTSManager} from "../interfaces/IVTSManager.sol";
import {ISettlementVerifier} from "../interfaces/ISettlementVerifier.sol";

contract VRLSignalManager is Ownable, ISettlementVerifier {
    ISpokeVerifier public verifier;
    IOracleRegistry public oracleRegistry;
    IMarketFactory public marketFactory;

    using MarketMaker for MarketMaker.State;

    event VerifierChanged(address indexed oldVerifier, address indexed newVerifier);

    error InvalidProof();
    error InvalidDelta(int128 amount0, int128 amount1);
    error InvalidNonce(uint256 newNonce, uint256 prevNonce);
    error InvalidLiquiditySignalEncoding();
    error InvalidLiquiditySignal();
    error InsufficientLiquidityInSignal();

    mapping(address => uint256) public mmNonce;
    uint256 public signalExpiryInSeconds;

    constructor(address _verifier, address _oracleRegistry, address _marketFactory, uint256 _signalExpiryInSeconds)
        Ownable(msg.sender)
    {
        verifier = ISpokeVerifier(_verifier);
        oracleRegistry = IOracleRegistry(_oracleRegistry);
        marketFactory = IMarketFactory(_marketFactory);
        signalExpiryInSeconds = _signalExpiryInSeconds;
    }

    /**
     * @dev This function is used to set the verifier for the VRLSpokeReceiver
     *      the verifier responsible for verifing the signatures and inclusion proofs
     * @param _newVerifier The new verifier to set
     */
    function setVerifier(address _newVerifier) external onlyOwner {
        address oldVerifier = address(verifier);
        verifier = ISpokeVerifier(_newVerifier);
        emit VerifierChanged(oldVerifier, _newVerifier);
    }

    /**
     * @dev This function is used to set the expiry in seconds for the liquidity signal
     * @param _signalExpiryInSeconds The new expiry in seconds to set
     */
    function setSignalExpiryInSeconds(uint256 _signalExpiryInSeconds) external onlyOwner {
        signalExpiryInSeconds = _signalExpiryInSeconds;
    }

    /**
     * @dev This function is used to verify the liquidity signal and makes sure it updates the nonce for the mm
     * @param liquiditySignal The liquidity signal to verify
     */
    function verifyLiquiditySignalSolvency(
        PoolKey calldata poolKey,
        bytes memory liquiditySignal,
        ModifyLiquidityParams memory liquidityParams
    ) public returns (uint256, uint256, uint256) {
        LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));

        // verify the proofs associated with the state
        bool isSignalValid = verifyLiquiditySignal(signal);
        // if the proof is invalid, revert
        if (!isSignalValid) {
            revert InvalidProof();
        }

        // check the solvency of the signal
        // reverts if insolvent
        return checkSignalSolvency(poolKey, liquiditySignal, liquidityParams);
    }

    /**
     * @dev This function is used to verify the liquidity signal and return the tickers and amounts of the assets
     * @param signal The liquidity signal to verify
     * @return isProofValid Whether the proof is valid
     */
    function verifyLiquiditySignal(LiquiditySignal memory signal) public returns (bool isProofValid) {
        // derive the liquidity signal
        // validate the new nonce is greater than than the previous nonce
        if (signal.nonce <= mmNonce[signal.mmState.owner]) {
            revert InvalidNonce(signal.nonce, mmNonce[signal.mmState.owner]);
        }

        // verify the proofs associated with the state
        isProofValid = verifier.verifyProof(
            signal.nonce,
            signal.rootHash,
            signal.rootHashSignature,
            signal.mmSignature,
            signal.mmState,
            signal.merkleProof
        );

        if (isProofValid) {
            // update the nonce for the mm if the proof is valid
            mmNonce[signal.mmState.owner] = signal.nonce;
        }
    }

    /**
     * @dev This function is used to verify the settlement proof and return the grace period extension
     *      This function is yet to be implemented
     * @return gracePeriodExtension The grace period extension
     */
    function verifySettlementProof(bytes memory) public pure returns (uint256 gracePeriodExtension) {
        return 0;
    }

    /**
     * Renew a liquidity signal by verifying it and returning the usd value of the signal
     * @param liquiditySignal the signal encoded in bytes
     */
    function renewLiquiditySignal(bytes memory liquiditySignal) public returns (uint256, uint256) {
        LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));

        bool isSignalValid = verifyLiquiditySignal(signal);
        if (!isSignalValid) {
            revert InvalidProof();
        }
        // get usd value of signal
        (string[] memory tickers, uint256[] memory amounts) = signal.mmState.getReserves();
        uint256 totalSignalUsdValue = getTotalUsdValue(tickers, amounts);

        return (totalSignalUsdValue, signalExpiryInSeconds);
    }

    /**
     * @dev This function is used to calculate the solvency of the liquidity signal against the value of the provided lccs
     *      This function will compare the total USD value of the LCC's to the total USD value of the assets in the liquidity signal
     *      This function does not verify the signal
     * @param poolKey The pool key of the liquidity signal
     * @param liquiditySignal The liquidity signal to calculate the solvency of
     * @param liquidityParams The liquidity parameters of the liquidity signal
     * @return totalLCCValue The total USD value of the LCC's
     * @return totalSignalUsdValue The total USD value of the assets in the liquidity signal
     * @return signalExpiryInSeconds The expiry in seconds of the liquidity signal
     */
    function checkSignalSolvency(
        PoolKey calldata poolKey,
        bytes memory liquiditySignal,
        ModifyLiquidityParams memory liquidityParams
    ) public view returns (uint256, uint256, uint256) {
        ILCC lcc0 = ILCC(Currency.unwrap(poolKey.currency0));
        ILCC lcc1 = ILCC(Currency.unwrap(poolKey.currency1));

        // if the signal is zero bytes then revert
        if (liquiditySignal.length == 0) {
            revert InvalidLiquiditySignal();
        }
        LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));

        // --- Calculate the total USD value of the LCC's ---

        // get the price of the LCC's
        address coreHook = IMarketFactory(marketFactory).getCoreHook();
        address marketOracleFactory = IVTSManager(coreHook).getMarketVTSConfiguration(poolKey.toId()).oracleFactory;

        (uint256 lcc0Amount, uint256 lcc1Amount) = LiquidityUtils.calculateCommitmentMaxima(
            liquidityParams.tickLower, liquidityParams.tickUpper, uint128(uint256(liquidityParams.liquidityDelta))
        );

        (uint256 lcc0Price, uint256 lcc0Decimals) = lcc0.usdPrice(marketOracleFactory);
        (uint256 lcc1Price, uint256 lcc1Decimals) = lcc1.usdPrice(marketOracleFactory);

        uint256 totalLCCValue =
            ((lcc0Price * lcc0Amount) / 10 ** lcc0Decimals) + ((lcc1Price * lcc1Amount) / 10 ** lcc1Decimals);

        // --- Calculate the total USD value of the assets in the liquidity signal ---
        (string[] memory tickers, uint256[] memory amounts) = signal.mmState.getReserves();
        uint256 totalSignalUsdValue = getTotalUsdValue(tickers, amounts);

        //  Position is solvent if the total LCC value is greater than or equal to the total signal usd value
        bool isSolvent = totalSignalUsdValue >= totalLCCValue;

        // if the position is not solvent, revert
        if (!isSolvent) {
            revert InsufficientLiquidityInSignal();
        }

        return (totalLCCValue, totalSignalUsdValue, signalExpiryInSeconds);
    }

    /**
     * @dev This function is used to get the total USD value of the assets provided identified by their tickers and scaled by the amounts
     * @param tickers The tickers of the assets
     * @param amounts The amounts of the assets
     * @return totalUsdValue The total USD value of the assets
     */
    function getTotalUsdValue(string[] memory tickers, uint256[] memory amounts) public view returns (uint256) {
        uint256 totalUsdValue = 0;
        for (uint256 i = 0; i < tickers.length; i++) {
            totalUsdValue += _getAssetUsdValue(tickers[i], amounts[i]);
        }
        return totalUsdValue;
    }

    /**
     * @dev This function is used to get the USD value of an asset provided identified by its ticker and scaled by the amount
     * @param ticker The ticker of the asset
     * @param amount The amount of the asset
     * @return usdValue The USD value of the asset
     */
    function _getAssetUsdValue(string memory ticker, uint256 amount) internal view returns (uint256) {
        // get the price from the price oracle registry
        string memory pricePair = string.concat(ticker, "/", "USD");
        // use the default market oracle factory when calculating value of assets in signal reserves
        address marketOracleFactory = address(0);

        address priceOracle = IOracleRegistry(oracleRegistry).getOracle(pricePair, marketOracleFactory);
        // convert the price to USD value
        // assume each oracle provides a decimal interface to incerase precision
        uint256 decimals = IOracle(priceOracle).decimals();
        uint256 price = IOracle(priceOracle).getPrice();
        uint256 usdValue = (uint256(price) * amount) / 10 ** decimals;
        // return the USD value
        return usdValue;
    }
}
