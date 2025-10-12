// SPDX-License-Identifier: MIT
// The VRLSpokeReceiver is a module that is responsible for verifying the liquidity signal and returning the tickers and amounts of the assets
// It is used by the `MMPositionManager` to verify the liquidity signal and return the tickers and amounts of the assets
// and to ensure that the MM has enough reserves in their signal to cover their liquidity commitment to the Market
pragma solidity ^0.8.0;

import {MarketMaker} from "../libraries/MarketMaker.sol";
import {ISpokeVerifier} from "../interfaces/ISpokeVerifier.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {LiquiditySignal} from "../types/Position.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {IOracleRegistry} from "../interfaces/IOracleRegistry.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {console} from "forge-std/console.sol";

contract VRLSpokeReceiver is Ownable {
    ISpokeVerifier public verifier;
    IOracleRegistry public oracleRegistry;

    event VerifierChanged(address indexed oldVerifier, address indexed newVerifier);

    error InvalidProof();

    constructor(address _verifier, address _oracleRegistry) Ownable(msg.sender) {
        verifier = ISpokeVerifier(_verifier);
        oracleRegistry = IOracleRegistry(_oracleRegistry);
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
     * @dev This function is used to verify the liquidity signal and return the tickers and amounts of the assets
     * @param liquiditySignal The liquidity signal to verify
     * @return tickers The tickers of the assets
     * @return amounts The amounts of the assets
     */
    function verifyLiquiditySignal(LiquiditySignal memory liquiditySignal)
        public
        view
        returns (string[] memory tickers, uint256[] memory amounts)
    {
        // verify the proofs associated with the state
        if (
            !verifier.verifyProof(
                liquiditySignal.rootHash,
                liquiditySignal.rootHashSignature,
                liquiditySignal.signature,
                liquiditySignal.mmState,
                liquiditySignal.merkleProof
            )
        ) {
            // if the proof is invalid, revert
            revert InvalidProof();
        }

        // get the reserves from the mm state
        (tickers, amounts) = MarketMaker.getReserves(liquiditySignal.mmState);
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
