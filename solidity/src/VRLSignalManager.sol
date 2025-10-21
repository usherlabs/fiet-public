// SPDX-License-Identifier: MIT
// The VRLSpokeReceiver is a module that is responsible for verifying the liquidity signal and returning the tickers and amounts of the assets
// It is used by the `MMPositionManager` to verify the liquidity signal and return the tickers and amounts of the assets
// and to ensure that the MM has enough reserves in their signal to cover their liquidity commitment to the Market
pragma solidity ^0.8.0;

import {MarketMaker} from "./libraries/MarketMaker.sol";
import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
import {ISpokeVerifier} from "./interfaces/ISpokeVerifier.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {LiquiditySignal} from "./types/Position.sol";
import {IOracle} from "./interfaces/IOracle.sol";
import {IOracleRegistry} from "./interfaces/IOracleRegistry.sol";
// removed unused imports after solvency removal

contract VRLSignalManager is Ownable {
    ISpokeVerifier public verifier;
    IOracleRegistry public oracleRegistry;
    IMarketFactory public marketFactory;

    using MarketMaker for MarketMaker.State;

    event VerifierChanged(address indexed oldVerifier, address indexed newVerifier);
    event SignalExpiryInSecondsChanged(
        uint256 indexed oldSignalExpiryInSeconds, uint256 indexed newSignalExpiryInSeconds
    );

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
        uint256 _oldSignalExpiryInSeconds = signalExpiryInSeconds;
        signalExpiryInSeconds = _signalExpiryInSeconds;
        emit SignalExpiryInSecondsChanged(_oldSignalExpiryInSeconds, _signalExpiryInSeconds);
    }

    /**
     * @dev This function is used to verify the liquidity signal and return the tickers and amounts of the assets
     * @param signal The liquidity signal to verify
     * @return isProofValid Whether the proof is valid
     */
    function verifyLiquiditySignal(LiquiditySignal memory signal)
        public
        returns (bool isProofValid, uint256 _signalExpiryInSeconds)
    {
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

        _signalExpiryInSeconds = signalExpiryInSeconds;
    }

    // bytes overload to match interface (non-reverting version)
    function verifyLiquiditySignal(bytes memory liquiditySignal)
        external
        returns (bool ok, uint256 _signalExpiryInSeconds)
    {
        LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
        (ok, _signalExpiryInSeconds) = verifyLiquiditySignal(signal);
    }

    // removed: checkSignalSolvency (documentation cleaned up)

    function verifyLiquiditySignal(bytes memory liquiditySignal, bool revertOnInvalid)
        external
        returns (bool ok, uint256 _signalExpiryInSeconds)
    {
        LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
        (ok, _signalExpiryInSeconds) = verifyLiquiditySignal(signal);
        if (revertOnInvalid && !ok) revert InvalidProof();
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
