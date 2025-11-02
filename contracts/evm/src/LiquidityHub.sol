// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IOracleHelper} from "./interfaces/IOracleHelper.sol";
import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
import {LCCFactory} from "./modules/LCCFactory.sol";

/**
 * @title LiquidityHub
 * @notice Factory contract for creating Fiet protocol markets with LCC tokens and pool management
 * @dev Manages LCC token creation, pool deployment, and protocol bounds administration
 */
contract LiquidityHub is Ownable, LCCFactory {
    IOracleHelper public immutable oracleHelper;
    address public mmPositionManager;

    error NotFactory();

    // Map of market factories
    mapping(address => bool) public isFactory;

    constructor(
        address _oracleHelper,
        address _mmPositionManager,
        string memory _nativeAssetName,
        string memory _nativeAssetSymbol,
        uint8 _nativeAssetDecimals
    ) Ownable(msg.sender) LCCFactory(_nativeAssetName, _nativeAssetSymbol, _nativeAssetDecimals) {
        oracleHelper = IOracleHelper(_oracleHelper);
        mmPositionManager = _mmPositionManager;
    }

    modifier onlyFactory(address factory) {
        if (!isFactory[factory]) {
            revert NotFactory();
        }
        _;
    }

    function setFactory(address factory) external onlyOwner {
        isFactory[factory] = true;
    }

    function unsetFactory(address factory) external onlyOwner {
        isFactory[factory] = false;
    }

    /**
     * @notice Creates LCC token pair for a market
     * @param factory The factory address
     * @param marketId The market ID
     * @param underlyingAsset0 The first underlying asset address
     * @param underlyingAsset1 The second underlying asset address
     * @return lccToken0 The first LCC token address
     * @return lccToken1 The second LCC token address
     */
    function createLCCPair(
        address factory,
        bytes32 marketId,
        address underlyingAsset0,
        address underlyingAsset1,
        string memory marketName
    ) external onlyFactory(factory) returns (address lccToken0, address lccToken1) {
        address[2] memory underlyingPair = [underlyingAsset0, underlyingAsset1];
        lccToken0 = _createLCC(factory, marketId, underlyingPair, 0, marketName);
        lccToken1 = _createLCC(factory, marketId, underlyingPair, 1, marketName);
    }
}
