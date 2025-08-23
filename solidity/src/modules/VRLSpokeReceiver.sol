// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {MarketMaker} from "../libraries/MarketMaker.sol";
import {ISpokeVerifier} from "../interfaces/ISpokeVerifier.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

abstract contract VRLSpokeReceiver is Ownable {
    ISpokeVerifier public verifier;

    event VerifierChanged(address indexed oldVerifier, address indexed newVerifier);
    event AssetWhitelisted(string indexed asset, address indexed priceFeed);
    event AssetUnwhitelisted(string indexed asset);

    error InvalidProof();
    error InsufficientReserves();
    error InvalidSignalAmount();
    error InvalidSignalAmountAndTickers();

    mapping(string => address) public priceFeeds;
    string[] public whitelistedAssets;

    constructor(address _verifier) Ownable(msg.sender) {
        verifier = ISpokeVerifier(_verifier);
    }

    function setVerifier(address _newVerifier) external onlyOwner {
        address oldVerifier = address(verifier);
        verifier = ISpokeVerifier(_newVerifier);
        emit VerifierChanged(oldVerifier, _newVerifier);
    }

    function addAssetPriceFeed(string calldata asset, address priceFeed) external onlyOwner {
        // Add admin check in production
        // require(priceFeeds[asset] == address(0), "Asset already whitelisted");
        priceFeeds[asset] = priceFeed;
        whitelistedAssets.push(asset);
        emit AssetWhitelisted(asset, priceFeed);
    }

    function removeAssetPriceFeed(string calldata asset) external onlyOwner {
        require(priceFeeds[asset] != address(0), "Asset not whitelisted");
        delete priceFeeds[asset];
        for (uint256 i = 0; i < whitelistedAssets.length; i++) {
            if (keccak256(bytes(whitelistedAssets[i])) == keccak256(bytes(asset))) {
                whitelistedAssets[i] = whitelistedAssets[whitelistedAssets.length - 1];
                whitelistedAssets.pop();
                break;
            }
        }
        emit AssetUnwhitelisted(asset);
    }

    function _verifyVRL(
        MarketMaker.ProofParams calldata proofParams,
        string[] calldata signalTickers,
        uint256[] calldata signalAmounts
    ) internal view returns (uint256) {
        if (signalTickers.length != signalAmounts.length) {
            revert InvalidSignalAmountAndTickers();
        }
        // verify the proof
        if (
            !verifier.verifyProof(
                proofParams.rootStateHash,
                proofParams.rootStateHashSignature,
                proofParams.mmStateHashSignature,
                proofParams.mmStateData,
                proofParams.merkleProof
            )
        ) {
            // if the proof is invalid, revert
            revert InvalidProof();
        }

        // get the reserves from the mm state
        (string[] memory tickers, uint256[] memory amounts) = MarketMaker.getReserves(proofParams.mmStateData);
        // get the total USD value of the reserves
        uint256 totalReservesUsdValue = getTotalUsdValue(tickers, amounts);
        // get the total USD They want to signal
        uint256 totalSignalUsdValue = getTotalUsdValue(signalTickers, signalAmounts);

        // check that the total signal USD value is less than the total reserves USD value
        if (totalSignalUsdValue > totalReservesUsdValue) {
            revert InsufficientReserves();
        }

        // check that the total signal USD value is greater than zero
        if (totalSignalUsdValue == 0) {
            revert InvalidSignalAmount();
        }

        // return the total signal USD value
        return totalSignalUsdValue;
    }

    function getTotalUsdValue(string[] memory tickers, uint256[] memory amounts) public view returns (uint256) {
        uint256 totalUsdValue = 0;
        for (uint256 i = 0; i < tickers.length; i++) {
            totalUsdValue += _getAssetUsdValue(tickers[i], amounts[i]);
        }
        return totalUsdValue;
    }

    function _getAssetUsdValue(string memory ticker, uint256 amount) internal view returns (uint256) {
        address priceFeed = priceFeeds[ticker];
        // return zero rather than reverting for when we do not have the price feed configured
        if (priceFeed == address(0)) {
            return 0;
        }
        // get the price from the price feed
        AggregatorV3Interface priceFeedContract = AggregatorV3Interface(priceFeed);
        uint256 decimals = priceFeedContract.decimals();
        (, int256 price,,,) = priceFeedContract.latestRoundData();
        // convert the price to USD value
        uint256 usdValue = (uint256(price) * amount) / 10 ** decimals;
        // return the USD value
        return usdValue;
    }
}
