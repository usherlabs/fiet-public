// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IOracleHelper} from "./interfaces/IOracleHelper.sol";
import {LCCFactory} from "./modules/LCCFactory.sol";

/**
 * @title LiquidityHub
 * @notice Factory contract for creating Fiet protocol markets with LCC tokens and pool management
 * @dev Manages LCC token creation, pool deployment, and protocol bounds administration
 */
contract LiquidityHub is Ownable, LCCFactory {
    IOracleHelper public immutable oracleHelper;
    address public mmPositionManager;

    error InvalidCaller();

    // Map of market factories
    mapping(address => bool) public isFactory;

    constructor(
        address _oracleHelper,
        address _mmPositionManager,
        string memory _nativeAssetName,
        string memory _nativeAssetSymbol,
        uint8 _nativeAssetDecimals,
        bool _marketRefIsValidIssuer
    )
        Ownable(msg.sender)
        LCCFactory(
            _nativeAssetName,
            _nativeAssetSymbol,
            _nativeAssetDecimals,
            _marketRefIsValidIssuer
        )
    {
        oracleHelper = IOracleHelper(_oracleHelper);
        mmPositionManager = _mmPositionManager;
    }

    modifier onlyFactory() {
        if (!isFactory[_msgSender()]) {
            revert InvalidCaller();
        }
        _;
    }

    modifier onlyFactoryOrOwner() {
        if (!isFactory[_msgSender()] && _msgSender() != owner()) {
            revert InvalidCaller();
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
     * @param marketRef The market reference (bytes from proxyHookAddress)
     * @param underlyingAsset0 The first underlying asset address
     * @param underlyingAsset1 The second underlying asset address
     * @param marketName The market name
     * @return lccToken0 The first LCC token address
     * @return lccToken1 The second LCC token address
     */
    function createLCCPair(
        address factory,
        bytes memory marketRef,
        address underlyingAsset0,
        address underlyingAsset1,
        string memory marketName
    )
        external
        onlyFactoryOrOwner
        returns (address lccToken0, address lccToken1)
    {
        address[2] memory underlyingPair = [underlyingAsset0, underlyingAsset1];
        lccToken0 = _createLCC(
            factory,
            marketRef,
            underlyingPair,
            0,
            marketName
        );
        lccToken1 = _createLCC(
            factory,
            marketRef,
            underlyingPair,
            1,
            marketName
        );
    }

    /**
     * @notice Initializes the mapping from LCC tokens to Market (with ID and Ref)
     * @param lccToken0 The first LCC token address
     * @param lccToken1 The second LCC token address
     * @param marketId The market ID (corePoolKey -> PoolID -> unwrap() to bytes32)
     * @param marketRef The market reference (bytes from proxyHookAddress)
     */
    function initialize(
        address lccToken0,
        address lccToken1,
        bytes32 marketId,
        bytes memory marketRef
    ) external onlyFactory {
        _initialize(lccToken0, lccToken1, marketId, marketRef);
    }
}
