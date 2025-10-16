// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {LiquidityRouter} from "./modules/LiquidityRouter.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "v4-periphery/lib/v4-core/src/types/PoolOperation.sol";
import {Constants} from "v4-periphery/lib/v4-core/test/utils/Constants.sol";
import {BalanceDelta, toBalanceDelta} from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {PoolId} from "v4-periphery/lib/v4-core/src/types/PoolId.sol";
import {ERC721} from "solmate/tokens/ERC721.sol";
import {PositionMeta, PositionId, PositionLibrary} from "./types/Position.sol";
import {LiquiditySignal, SignalState} from "./types/Position.sol";
import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {IVTSManager} from "./interfaces/IVTSManager.sol";
import {MarketVTSConfiguration, MarketVTSConfigurationLibrary} from "./types/VTS.sol";
import {RFSCheckpoint, RFSCheckpointLibrary} from "./types/Checkpoint.sol";
import {LiquidityUtils} from "./libraries/LiquidityUtils.sol";
import {IMMPositionManager} from "./interfaces/IMMPositionManager.sol";
import {IProxyHook} from "./interfaces/IProxyHook.sol";
import {ILCC} from "./interfaces/ILCC.sol";
import {IVRLSignalManager} from "./interfaces/IVRLSignalManager.sol";
import {IPositionIndex} from "./interfaces/IPositionIndex.sol";
import {SafeCast} from "v4-periphery/lib/v4-core/src/libraries/SafeCast.sol";
import {FullMath} from "v4-periphery/lib/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";

contract MMPositionManager is LiquidityRouter, ERC721, IMMPositionManager {
    using SafeCast for *;
    using RFSCheckpointLibrary for RFSCheckpoint;
    using MarketVTSConfigurationLibrary for MarketVTSConfiguration;
    using PositionLibrary for PositionId;
    using StateLibrary for IPoolManager;

    error InvalidDelta(int128 amount0, int128 amount1);
    error InvalidAmount(uint256 amount, uint256 maxAmount);
    error InvalidLiquiditySignal(uint256 totalSignalUsdValue, uint256 totalLCCValue);
    error InvalidPosition(uint256 tokenId, uint256 positionIndex, PositionId positionId);
    error InvalidMarket(PoolKey poolKey);
    error SignalExpired(uint256 tokenId);
    error UnauthorizedSignalOwner();

    event SignalCommitted(address indexed mm, uint256 tokenId, uint256 positionIndex);
    event SignalDecommitted(
        address indexed mm, uint256 tokenId, uint256 positionIndex, uint256 amount0, uint256 amount1
    );
    event Checkpointed(uint256 tokenId, uint256 positionIndex, RFSCheckpoint checkpoint);

    address public immutable marketFactory;
    uint256 private nextTokenId = 1;
    IPoolManager private poolManager;
    IVRLSignalManager public immutable signalManager;
    mapping(PositionId => RFSCheckpoint) public positionToCheckpoint;
    mapping(uint256 => mapping(uint256 => PositionId)) public nftToPositionId;
    mapping(uint256 => uint256) public nftToPositionCount;
    mapping(PositionId => string) public proverOfPosition; //? is this necessary?
    mapping(uint256 => SignalState) public tokenIdToSignal;

    modifier onlyNFTOwner(uint256 tokenId) {
        if (ownerOf(tokenId) != msg.sender) {
            revert InvalidPosition(tokenId, 0, PositionId.wrap(0));
        }
        _;
    }

    modifier onlyValidSignal(uint256 tokenId) {
        if (tokenIdToSignal[tokenId].expiresAt < block.timestamp) {
            revert SignalExpired(tokenId);
        }
        _;
    }

    constructor(address _manager, address _signalManager, address _marketFactory)
        LiquidityRouter(_manager)
        ERC721("MMPositionManager", "MMPM")
    {
        marketFactory = _marketFactory;
        poolManager = IPoolManager(_manager);
        signalManager = IVRLSignalManager(_signalManager);
    }

    function tokenURI(uint256) public pure override returns (string memory) {
        revert("Metadata not implemented");
    }

    function _getVTSManager() internal view returns (IVTSManager) {
        return IVTSManager(IMarketFactory(marketFactory).getCoreHook());
    }

    function _getPositionIndex() internal view returns (IPositionIndex) {
        return IPositionIndex(IMarketFactory(marketFactory).getCoreHook());
    }

    function getPositionId(uint256 tokenId, uint256 positionIndex) public view returns (PositionId) {
        return nftToPositionId[tokenId][positionIndex];
    }

    function getSignalState(uint256 tokenId) public view returns (SignalState memory) {
        return tokenIdToSignal[tokenId];
    }

    function _isMMPosition(PositionId positionId, PositionMeta memory m) internal view returns (bool) {
        return m.owner == address(this) && m.isActive && bytes(proverOfPosition[positionId]).length != 0;
    }

    function _isValidPositionForPool(PoolKey memory poolKey, PositionMeta memory position)
        internal
        pure
        returns (bool)
    {
        return PoolId.unwrap(position.poolId) == PoolId.unwrap(poolKey.toId());
    }

    /**
     * @dev Check if the LCC is supported by the market i.e if the LCC is either token0 or token1 for a given core pool
     * @param _poolKey The pool key to check market validity for
     * @return bool True if the LCC is supported by the market, false otherwise
     */
    function _isValidMarket(PoolKey memory _poolKey) internal view returns (bool) {
        // Fetch currencies traded by the core pool
        address[2] memory currencies = IMarketFactory(marketFactory).corePoolToCurrencyPair(_poolKey.toId());
        address c0 = Currency.unwrap(_poolKey.currency0);
        address c1 = Currency.unwrap(_poolKey.currency1);
        // Market is valid if the poolKey currencies match the factory's registered core pool currencies (in any order)
        return (c0 == currencies[0] && c1 == currencies[1]) || (c0 == currencies[1] && c1 == currencies[0]);
    }

    modifier onlyValidMarket(PoolKey memory _poolKey) {
        if (!_isValidMarket(_poolKey)) {
            revert InvalidMarket(_poolKey);
        }
        _;
    }

    /**
     * Gets information about a position using the token id and position index
     * @param tokenId The token id to get the position info for
     * @param positionIndex The position index to get the position info for
     * @return positionInfo The position info
     */
    function getPosition(uint256 tokenId, uint256 positionIndex) public view returns (PositionMeta memory) {
        PositionId positionId = getPositionId(tokenId, positionIndex);
        if (PositionId.unwrap(positionId) == bytes32(0)) {
            revert InvalidPosition(tokenId, positionIndex, positionId);
        }
        PositionMeta memory m = _getPositionIndex().getPosition(positionId, true);

        if (!_isMMPosition(positionId, m)) {
            revert InvalidPosition(tokenId, positionIndex, positionId);
        }

        return m;
    }

    /**
     * @dev This function is used to settle more underlying assets for a particular position
     * @param poolKey The pool key for the position - adheres to Uniswap standards where poolKey provided as a param.
     * @param tokenId The token id to settle the position for
     * @param positionIndex The position index to settle the position for
     * @param amount0 The amount of token0 to settle
     * @param amount1 The amount of token1 to settle
     */
    function settle(PoolKey memory poolKey, uint256 tokenId, uint256 positionIndex, uint256 amount0, uint256 amount1)
        public
        onlyNFTOwner(tokenId)
    {
        PositionMeta memory m = getPosition(tokenId, positionIndex); // Validate the position by fetching it.

        if (amount0 == 0 && amount1 == 0) {
            // Cannot settle 0 amounts
            revert InvalidDelta(0, 0);
        }

        if (!_isValidPositionForPool(poolKey, m)) {
            revert InvalidMarket(poolKey);
        }

        PositionId positionId = getPositionId(tokenId, positionIndex);

        // settle the underlying assets to the proxy hook
        _modifyMarketUnderlyingAsset(
            positionId,
            m.poolId,
            toBalanceDelta(amount0.toInt128(), amount1.toInt128()),
            ILCC(Currency.unwrap(poolKey.currency0)).underlyingAsset(),
            ILCC(Currency.unwrap(poolKey.currency1)).underlyingAsset()
        );

        // mark RFS checkpoint
        _checkpoint(tokenId, positionIndex);
    }

    /**
     * @dev This function is used to withdraw settled liquidity from a position
     * @param poolKey The pool key for the position - adheres to Uniswap standards where poolKey provided as a param.
     * @param tokenId The token id to withdraw the position for
     * @param positionIndex The position index to withdraw the position for
     * @param amount0 The amount of token0 to withdraw
     * @param amount1 The amount of token1 to withdraw
     */
    function withdraw(PoolKey memory poolKey, uint256 tokenId, uint256 positionIndex, uint256 amount0, uint256 amount1)
        public
        onlyNFTOwner(tokenId)
    {
        PositionId positionId = getPositionId(tokenId, positionIndex);
        PositionMeta memory m = getPosition(tokenId, positionIndex);

        if (!_isValidPositionForPool(poolKey, m)) {
            revert InvalidMarket(poolKey);
        }

        if (amount0 == 0 && amount1 == 0) {
            // Cannot withdraw 0 amounts
            // 0, 0 amounts reserved for defaulting to totalSettledAmounts during liquidation.
            revert InvalidDelta(0, 0);
        }

        // withdraw the amounts from the position
        _modifyMarketUnderlyingAsset(
            positionId,
            m.poolId,
            toBalanceDelta(-amount0.toInt128(), -amount1.toInt128()),
            ILCC(Currency.unwrap(poolKey.currency0)).underlyingAsset(),
            ILCC(Currency.unwrap(poolKey.currency1)).underlyingAsset()
        );

        // mark RFS checkpoint
        _checkpoint(tokenId, positionIndex);
    }

    /**
     * @dev This function is used to commit a liquidity signal to the position manager
     *      Commitment creates a new position and attaches it to a token id
     *      A token id represents a liquidity signal and its validity(before it expires)
     * @param poolKey The pool key to commit the liquidity signal to
     * @param tickLower The lower tick of the position
     * @param tickUpper The upper tick of the position
     * @param liquidity The liquidity amount to add
     * @param liquiditySignal The liquidity signal to commit to the position manager
     * @return positionId The unique identifier of the position created
     */
    function commit(
        PoolKey calldata poolKey,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidity,
        bytes memory liquiditySignal
    ) external onlyValidMarket(poolKey) returns (PositionId) {
        // verify the liquidity signal, this will return the validated reserves
        if (liquiditySignal.length == 0) {
            revert InvalidLiquiditySignal(0, 0);
        }
        if (liquidity == 0) {
            revert InvalidDelta(0, 0);
        }

        // calculate the token0 and token1 amounts to mint to create the position
        ModifyLiquidityParams memory liquidityParams = ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: liquidity,
            salt: bytes32(0) // safe to set to zero because the salt is generated based on paramaters
        });

        address lccAddr0 = Currency.unwrap(poolKey.currency0);
        address lccAddr1 = Currency.unwrap(poolKey.currency1);
        ILCC lcc0 = ILCC(lccAddr0);
        ILCC lcc1 = ILCC(lccAddr1);

        // calculate the total LCC USD value and confirm it is less than the total signal usd value

        (,, uint256 signalExpiryInSeconds) =
            signalManager.verifyLiquiditySignalSolvency(poolKey, liquiditySignal, liquidityParams);

        // derive the validated liquidity signal
        LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));

        uint256 tokenId = _createCommitmentForSignal(
            msg.sender, SignalState({signal: signal, expiresAt: block.timestamp + signalExpiryInSeconds})
        );
        (PositionId positionId, uint256 positionIndex) = _createPosition(tokenId, poolKey, liquidityParams);

        // use the position id to make the initial settlement of the underlying tokens to the proxy hook
        // Get amount of underlying liquidity to transfer from the issuer to the lcc
        (uint256 underlyingLiquidityFraction0, uint256 underlyingLiquidityFraction1) = LiquidityUtils
            .getBaseSettlementAmounts(liquidityParams, _getVTSManager().getMarketVTSConfiguration(poolKey.toId()));

        // settle the underlying tokens to the proxy hook
        // By calling VTSManager.onMMLiquidityModify, we are also settling the position growths for new MMPosition.
        _modifyMarketUnderlyingAsset(
            positionId,
            poolKey.toId(),
            toBalanceDelta(underlyingLiquidityFraction0.toInt128(), underlyingLiquidityFraction1.toInt128()),
            lcc0.underlyingAsset(),
            lcc1.underlyingAsset()
        );

        emit SignalCommitted(msg.sender, tokenId, positionIndex);

        return positionId;
    }

    /**
     * @dev This function is used to mint a new position for a given token id
     * @param poolKey The pool key to mint the position for
     * @param tokenId The token id to mint the position for
     * @param tickLower The lower tick of the position
     * @param tickUpper The upper tick of the position
     * @param liquidity The liquidity amount to mint
     */
    function mint(PoolKey calldata poolKey, uint256 tokenId, int24 tickLower, int24 tickUpper, int256 liquidity)
        public
        onlyNFTOwner(tokenId)
        onlyValidSignal(tokenId)
        returns (uint256)
    {
        uint256 posCount = nftToPositionCount[tokenId];
        if (posCount == 0) {
            // should never be reached, however validate that nft has an existing position attached to it
            revert InvalidPosition(tokenId, 0, PositionId.wrap(0));
        }

        PositionMeta memory lastPos = getPosition(tokenId, posCount - 1); // get existingPos
        if (!_isValidPositionForPool(poolKey, lastPos)) {
            // validate that provided poolKey belongs to the tokenId.
            revert InvalidMarket(poolKey);
        }
        // derive the liquidity modification parameters
        ModifyLiquidityParams memory liquidityParams = ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: liquidity,
            salt: bytes32(0) // safe to set to zero because the salt is generated based on paramaters
        });

        // get the total usd value of all the commitments under this nft
        uint256 currentUnsettledUSDValue = getTokenUnsettledUSDValue(tokenId);
        // get the total usd value of the new commitment
        (uint256 newCommitmentsUSDValue, uint256 totalSignalUsdValue,) =
            signalManager.checkSignalSolvency(poolKey, abi.encode(tokenIdToSignal[tokenId].signal), liquidityParams);

        // validate that the total usd value of outstanding commitments + new commitment < total usd value of signal
        uint256 sumOfValues = currentUnsettledUSDValue + newCommitmentsUSDValue;
        if (sumOfValues > totalSignalUsdValue) {
            revert InvalidLiquiditySignal(totalSignalUsdValue, sumOfValues);
        }

        // create the position
        (PositionId positionId, uint256 positionIndex) = _createPosition(tokenId, poolKey, liquidityParams);

        // settle base for the position
        // Get amount of underlying liquidity to transfer from the issuer to the lcc
        (uint256 underlyingLiquidityFraction0, uint256 underlyingLiquidityFraction1) = LiquidityUtils
            .getBaseSettlementAmounts(liquidityParams, _getVTSManager().getMarketVTSConfiguration(poolKey.toId()));

        // settle the underlying tokens to the proxy hook
        // By calling VTSManager.onMMLiquidityModify, we are also settling the position growths for new MMPosition.
        _modifyMarketUnderlyingAsset(
            positionId,
            poolKey.toId(),
            toBalanceDelta(underlyingLiquidityFraction0.toInt128(), underlyingLiquidityFraction1.toInt128()),
            ILCC(Currency.unwrap(poolKey.currency0)).underlyingAsset(),
            ILCC(Currency.unwrap(poolKey.currency1)).underlyingAsset()
        );
        // by validating the provided pooKey, we can rely securely on the currency0,1

        // No event emitted here. Uniswap will emit a new position event.
        // Ref https://github.com/Uniswap/v4-core/blob/a7cf038cd568801a79a9b4cf92cd5b52c95c8585/src/PoolManager.sol#L175

        return positionIndex;
    }

    /**
     * @dev This function is used to get the total unsettled USD value for a given token id
     *      I.e it provides the value of this position which has not been settled
     * @param tokenId The token id to get the total unsettled USD value for
     * @return totalUSDValue The total unsettled USD value
     */
    function getTokenUnsettledUSDValue(uint256 tokenId) public view returns (uint256) {
        // get all positions attached to this token id
        uint256 totalUSDValue = 0;
        IVTSManager vtsManager = _getVTSManager();
        uint256 positionCount = nftToPositionCount[tokenId];
        // get all the positions attached to this nft
        for (uint256 i = 0; i < positionCount; i++) {
            // get the position attached to this NFT using the token id and position index
            PositionMeta memory position = getPosition(tokenId, i);
            PositionId positionId = getPositionId(tokenId, i);
            // get the unsettled USD value of the position
            uint256 unsettledUSDValue = vtsManager.getPositionUnsettledUSDValue(position.poolId, positionId);
            totalUSDValue += unsettledUSDValue;
        }

        return totalUSDValue;
    }

    /**
     * @dev This function is used to decommit a position for a given token id
     * @param poolKey The pool key for the position
     * @param tokenId The token id to decommit the position for
     */
    function decommit(PoolKey memory poolKey, uint256 tokenId) public onlyNFTOwner(tokenId) {
        uint256 totalS0 = 0;
        uint256 totalS1 = 0;

        // get all positions attached to this token id
        uint256 positionCount = nftToPositionCount[tokenId];
        for (uint256 i = 0; i < positionCount; i++) {
            PositionMeta memory position = getPosition(tokenId, i);
            if (position.isActive) {
                BalanceDelta balanceDelta = burn(poolKey, tokenId, i);
                totalS0 += LiquidityUtils.safeInt128ToUint256(balanceDelta.amount0());
                totalS1 += LiquidityUtils.safeInt128ToUint256(balanceDelta.amount1());
            }
        }

        // burn the nft after removing all of the liquidity
        _burn(tokenId);

        emit SignalDecommitted(msg.sender, tokenId, positionCount, totalS0, totalS1);
    }

    /**
     * @dev This function is used to decommit a position for a given position id
     * @param poolKey The pool key for the position
     * @param tokenId The token id to decommit the position for
     * @param positionIndex The position index to decommit the position for
     * @return balanceDelta The balance delta
     */
    function burn(PoolKey memory poolKey, uint256 tokenId, uint256 positionIndex)
        public
        onlyNFTOwner(tokenId)
        onlyValidSignal(tokenId)
        returns (BalanceDelta)
    {
        // -- Validate the poolKey
        PositionMeta memory pos = getPosition(tokenId, positionIndex);
        if (!_isValidPositionForPool(poolKey, pos)) {
            revert InvalidMarket(poolKey);
        }

        // Liquidate position will call VTSManager.onMMLiquidityModify, which will settle the position growths for the new MMPosition.
        // _modifyMarketUnderlyingAsset will be called inside of _liquidatePosition.
        uint256 completeLiquidity = uint256(pos.liquidity);
        return _liquidatePosition(poolKey, pos, _positionSalt(tokenId, positionIndex), completeLiquidity);
    }

    function modify(PoolKey memory poolKey, uint256 tokenId, uint256 positionIndex, int256 liquidity)
        public
        onlyNFTOwner(tokenId)
        onlyValidSignal(tokenId)
    {
        IVTSManager vtsManager = _getVTSManager();
        PositionMeta memory position = getPosition(tokenId, positionIndex);

        // Validate poolKey
        if (!_isValidPositionForPool(poolKey, position)) {
            revert InvalidMarket(poolKey);
        }

        ILCC lcc0 = ILCC(Currency.unwrap(poolKey.currency0));
        ILCC lcc1 = ILCC(Currency.unwrap(poolKey.currency1));
        address ua0 = lcc0.underlyingAsset();
        address ua1 = lcc1.underlyingAsset();

        ModifyLiquidityParams memory modifyLiquidityParams = ModifyLiquidityParams({
            tickLower: position.tickLower,
            tickUpper: position.tickUpper,
            liquidityDelta: liquidity,
            salt: _positionSalt(tokenId, positionIndex)
        });
        // mint the tokens required to facilitate this liquidity addition
        (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(poolKey.toId());
        (uint256 lcc0Amount, uint256 lcc1Amount) =
            LiquidityUtils.calculateTokenAmountsFromPositionParams(sqrtPriceX96, currentTick, modifyLiquidityParams);

        // get the liquidity delta
        // if it is positive add liquidity to the position
        if (liquidity > 0) {
            // get the base settlements to make based on the liquidity to be added
            (uint256 underlyingLiquidityFraction0, uint256 underlyingLiquidityFraction1) = LiquidityUtils
                .getBaseSettlementAmounts(modifyLiquidityParams, vtsManager.getMarketVTSConfiguration(poolKey.toId()));

            // settle the underlying tokens to the proxy hook
            _modifyMarketUnderlyingAsset(
                getPositionId(tokenId, positionIndex),
                poolKey.toId(),
                toBalanceDelta(underlyingLiquidityFraction0.toInt128(), underlyingLiquidityFraction1.toInt128()),
                ua0,
                ua1
            );

            lcc0.issue(lcc0Amount);
            lcc1.issue(lcc1Amount);

            // actually modify the liquidity
            _modifyLiquidity(poolKey, modifyLiquidityParams, Constants.ZERO_BYTES);
        } else {
            // Direct partial liquidation with minimal calls
            uint256 amountToLiquidate = uint256(-liquidity);
            _liquidatePosition(poolKey, position, _positionSalt(tokenId, positionIndex), amountToLiquidate);
        }
    }

    /**
     * @dev This function is used to create a new position
     * @param tokenId The token id to create the position for
     * @param poolKey The pool key to create the position for
     * @param liquidityParams The liquidity parameters to create the position for
     * @return positionId The position id
     * @return positionIndex The position index
     */
    function _createPosition(uint256 tokenId, PoolKey memory poolKey, ModifyLiquidityParams memory liquidityParams)
        internal
        returns (PositionId positionId, uint256 positionIndex)
    {
        ILCC lcc0 = ILCC(Currency.unwrap(poolKey.currency0));
        ILCC lcc1 = ILCC(Currency.unwrap(poolKey.currency1));

        // derive the LCC amounts to mint to facilitate the commitment
        (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(poolKey.toId());
        (uint256 lcc0AmountToMint, uint256 lcc1AmountToMint) =
            LiquidityUtils.calculateTokenAmountsFromPositionParams(sqrtPriceX96, currentTick, liquidityParams);

        // Mint the tokens required for the liquidity commitment
        lcc0.issue(lcc0AmountToMint);
        lcc1.issue(lcc1AmountToMint);

        // add liquidity to the pool using the token id and position index to generate a unique salt
        positionIndex = nftToPositionCount[tokenId];
        liquidityParams.salt = _positionSalt(tokenId, positionIndex);

        // add liquidity to the pool
        (positionId,) = _callModifyLiquidity(poolKey, liquidityParams);

        // Attach position to this nft
        // make sure to add the position only after modifying the liquidity
        // because the number of positions is used to generate the salt for the position
        nftToPositionId[tokenId][positionIndex] = positionId;
        // Position metadata is managed centrally via PositionIndex/VTSManager
        // increment the number of positions for the nft
        nftToPositionCount[tokenId]++;
        // the prover of the liquidity signal verified to create this position
        // by default, this is address(0). However, if owner = mm position manager, then this is the prover of the liquidity signal verified to create this position
        proverOfPosition[positionId] = tokenIdToSignal[tokenId].signal.mmState.prover;
    }

    /**
     * @dev This function is used to generate a unique salt for a given token id and position index
     * @param tokenId The token id to generate the salt for
     * @param positionIndex The position index to generate the salt for
     * @return salt The unique salt
     */
    function _positionSalt(uint256 tokenId, uint256 positionIndex) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(tokenId, positionIndex));
    }

    /**
     * @dev This function is used to modify liquidity for a given pool key and parameters
     * @param poolKey The pool key to modify liquidity for
     * @param params The liquidity parameters to modify liquidity for
     * @return positionId The position id
     * @return balanceDelta The balance delta
     */
    function _callModifyLiquidity(PoolKey memory poolKey, ModifyLiquidityParams memory params)
        internal
        returns (PositionId positionId, BalanceDelta balanceDelta)
    {
        // use param to modify liquidity
        balanceDelta = _modifyLiquidity(poolKey, params, Constants.ZERO_BYTES);
        // generate unique position id using the params which contains the salt making this unique across all positions
        positionId = PositionLibrary.generateId(address(this), params);
    }

    /**
     * @dev This function is used to create a new nft for a commitment
     * @param to The address of the user who is creating the commitment
     * @return tokenId The id of the nft created
     */
    function _createCommitmentForSignal(address to, SignalState memory signalState)
        internal
        returns (uint256 tokenId)
    {
        // get the token id
        tokenId = nextTokenId++;
        // mint the nft
        _mint(to, tokenId);
        // store the signal state
        tokenIdToSignal[tokenId] = signalState;
        return tokenId;
    }

    /**
     * @dev This function is used to modify the underlying assets for a given position
     * @param positionId The position id to modify the underlying assets for
     * @param poolId The pool id to modify the underlying assets for
     * @param targetDelta The target balance delta amount to modify for the underlying assets to modify
     * @param ua0 The address of the underlying asset 0
     * @param ua1 The address of the underlying asset 1
     * @return modifiedDelta The balance delta of the underlying assets modified
     */
    function _modifyMarketUnderlyingAsset(
        PositionId positionId,
        PoolId poolId,
        BalanceDelta targetDelta,
        address ua0,
        address ua1
    ) internal returns (BalanceDelta modifiedDelta) {
        address sender = msg.sender;

        int128 amount0 = targetDelta.amount0();
        int128 amount1 = targetDelta.amount1();

        // make sure the target delta is not zero and the amounts are either both positive or both negative
        if (LiquidityUtils.isZeroDelta(targetDelta) || !((amount0 > 0 && amount1 > 0) || (amount0 < 0 && amount1 < 0)))
        {
            revert InvalidDelta(0, 0);
        }

        // If Settlement, Transfer the underlying tokens amount based on the VTS calc to the MarketVault
        address proxyHook = IMarketFactory(marketFactory).corePoolToProxyHook(poolId);

        uint256 modifyAmount0 = LiquidityUtils.safeInt128ToUint256(amount0);
        uint256 modifyAmount1 = LiquidityUtils.safeInt128ToUint256(amount1);

        if (amount0 > 0 && amount1 > 0) {
            // transfer the underlying tokens to the Market Vault (proxy hook)
            if (modifyAmount0 > 0) {
                IERC20Minimal(ua0).transferFrom(sender, proxyHook, modifyAmount0);
            }
            if (modifyAmount1 > 0) {
                IERC20Minimal(ua1).transferFrom(sender, proxyHook, modifyAmount1);
            }
        }

        // notify the vts manager of the settlement made for this position
        // onMMLiquidityModify operates now on a try basis -- if targetDelta < rfsDelta, then default to rfsDelta (if rfsOpen = false)
        modifiedDelta = _getVTSManager().onMMLiquidityModify(positionId, targetDelta);

        // notify the proxy hook of the settled underlying tokens
        // a positive balance delta means we are settling underlying tokens to the proxy hook, negative means withdrawing.
        IProxyHook(proxyHook).onMMLiquidityModify(modifiedDelta);

        // Overwrite the amount0 and amount1 with the actual modified delta amounts
        amount0 = modifiedDelta.amount0();
        amount1 = modifiedDelta.amount1();

        // if it is a take, then transfer the underlying tokens from the contract to the actual recipient
        if (amount0 < 0 && amount1 < 0) {
            if (modifyAmount0 > 0) {
                // transfer from this contract to the actual recipient
                IERC20Minimal(ua0).transfer(sender, modifyAmount0);
            }
            if (modifyAmount1 > 0) {
                // transfer from this contract to the actual recipient
                IERC20Minimal(ua1).transfer(sender, modifyAmount1);
            }
        }
    }

    /**
     * @dev This function is used to liquidate a position for a given token id and position index
     *      it removes the underlying liquidity from the position to the caller firstly
     *      then it removes the liquidity from the position and burns the tokens
     * @param poolKey The pool key for the position
     * @param position The position to liquidate
     * @param salt The salt of the position
     * @param amountToLiquidate The amount of liquidity to liquidate
     * @dev make sure to settle the underlying assets before calling this function
     *      because this function could potentially mark the position as inactive
     *      and if the position is inactive, then the call to modify the underlying assets will fail
     */
    function _liquidatePosition(
        PoolKey memory poolKey,
        PositionMeta memory position,
        bytes32 salt,
        uint256 amountToLiquidate
    ) internal returns (BalanceDelta returnDelta) {
        // validate liquidity is not over available
        if (uint256(position.liquidity) < amountToLiquidate) {
            revert InvalidAmount(amountToLiquidate, uint256(position.liquidity));
        }

        // remove the liquidity from the pool
        // By calling this, CoreHook afterRemoveLiquidity will be called to deactivate the position.
        (PositionId posId, BalanceDelta positionDelta) = _callModifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: position.tickLower,
                tickUpper: position.tickUpper,
                liquidityDelta: -int256(amountToLiquidate),
                salt: salt
            })
        );

        ILCC lcc0 = ILCC(Currency.unwrap(poolKey.currency0));
        ILCC lcc1 = ILCC(Currency.unwrap(poolKey.currency1));

        address ua0 = lcc0.underlyingAsset();
        address ua1 = lcc1.underlyingAsset();

        // This target delta may be negative beyond what is capable of being withdrawn. ie. target < rfs
        // ? VTSManager.onMMLiquidityModify will handle the clamp. ie. it's a "try withdraw" to this amounnt.
        BalanceDelta targetDelta = LiquidityUtils.safeToBalanceDelta(
            LiquidityUtils.safeInt128ToUint256(positionDelta.amount0()),
            LiquidityUtils.safeInt128ToUint256(positionDelta.amount1()),
            true,
            true
        );

        // take all the settled underlying assets from the position to the caller
        // ? _modifyMarketUnderlyingAsset will transfer assets based on modifiedDelta returned by VTSManager.onMMLiquidityModify.
        // TODO: On Seizure, this amount should be the seizureSettled + (portion of position settled relative to seizuredLiquidityUnits/liquidity)
        // ----- LCCs acquired by the seizing party are NOT cancelled, rather transferred for unwrap, or subsequent swaps. VTSManager.onMMLiquidityModify coordinates position settlement amounts, whereas Market Vault aggregates them and coordinates LCC queue clearance.
        // TODO: On burn (decommitPosition), this amount should be the total settled amount in the position.
        // ----- By checking if position.isActive == false, we can determine if full position is liquidated.
        // TODO: In all other cases where liquidity position is modified, (modify, seizeCommitment), only facilitate a portion of the settledAmounts AND then clamp by RfS.
        // ----- This can be done by comparing the targetDelta with effectiveLiquidity amounts in position to derive a portion of the settled amounts to impact.
        // ----- This can be determined, by calling onMMLiquidityModify within the _touchPosition, revealing the before/after liquidity amounts.
        // ----- Otherwise, we can utilise transient storage cached in _touchPosition (beforeLiquidityUnits) to maintain unified the interface, and check within the onMMLiquidityModify, revealing the before/after liquidity amounts.
        // TODO: On withdraw (default), simply clamp by RfS.
        returnDelta = _modifyMarketUnderlyingAsset(posId, poolKey.toId(), targetDelta, ua0, ua1);

        // burn the LCC originally committed to the position.
        // This may be greater than the amount of underlying asset tokens in the position.
        // TODO: LCC cancellation ONLY in burn() and modify() when RfS is closed.
        lcc0.cancel(LiquidityUtils.safeInt128ToUint256(positionDelta.amount0()));
        lcc1.cancel(LiquidityUtils.safeInt128ToUint256(positionDelta.amount1()));
    }

    /**
     * @dev This function is used to renew a liquidity signal for a given token id
     * @param tokenId The token id to renew the liquidity signal for
     * @param liquiditySignal The liquidity signal to renew the liquidity signal for
     */
    function renew(uint256 tokenId, bytes memory liquiditySignal) public onlyNFTOwner(tokenId) {
        // get the total outstanding usd value for all existing positions
        uint256 positionTotalCommitmentsUSDValue = getTokenUnsettledUSDValue(tokenId);
        // verify signal and get total usd value as well
        (uint256 totalSignalUsdValue, uint256 signalExpiryInSeconds) =
            signalManager.renewLiquiditySignal(liquiditySignal);
        // make sure signal is solvent
        if (positionTotalCommitmentsUSDValue > totalSignalUsdValue) {
            revert InvalidLiquiditySignal(totalSignalUsdValue, positionTotalCommitmentsUSDValue);
        }

        LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));

        // update expiry date and signal
        tokenIdToSignal[tokenId] = SignalState({signal: signal, expiresAt: block.timestamp + signalExpiryInSeconds});
    }

    /**
     * @dev Seizure of a position by a guarantor (other MM)
     * @param poolKey The pool key for the position
     * @param tokenId The token id to settle the position for
     * @param positionIndex The position index to settle the position for
     * @param amount0 The amount of token0 to settle
     * @param amount1 The amount of token1 to settle
     */
    function seize(PoolKey memory poolKey, uint256 tokenId, uint256 positionIndex, uint256 amount0, uint256 amount1)
        public
        returns (BalanceDelta seizedPositionDelta)
    {
        // -- Validate the position
        PositionMeta memory position = getPosition(tokenId, positionIndex);
        PositionId positionId = getPositionId(tokenId, positionIndex);

        // -- Validate that caller is not position owner
        if (msg.sender == position.owner || position.isActive == false) {
            revert InvalidPosition(tokenId, positionIndex, positionId);
        }

        // -- Validate the poolKey
        if (!_isValidPositionForPool(poolKey, position)) {
            revert InvalidMarket(poolKey);
        }

        // require at least one side is settled
        if (amount0 == 0 && amount1 == 0) {
            revert InvalidDelta(0, 0);
        }

        // create a balance delta of the amounts to settle
        BalanceDelta settleBalanceDelta = toBalanceDelta(amount0.toInt128(), amount1.toInt128());

        IVTSManager vtsManager = _getVTSManager();

        // Validate grace (using last checkpoint) and derive liquidity to seize
        uint256 seizedLiquidityUnits =
            vtsManager.calcSeizure(positionId, settleBalanceDelta, positionToCheckpoint[positionId]);

        // -- Settle the position to meet rfs requirements
        address ua0 = ILCC(Currency.unwrap(poolKey.currency0)).underlyingAsset();
        address ua1 = ILCC(Currency.unwrap(poolKey.currency1)).underlyingAsset();

        // settle underlying assets to the position to ensure it now meets rfs requirements
        // ? settlement is necessary because the seizing party is covering the deficit (settlement queue) in exchange for LCCs.
        _modifyMarketUnderlyingAsset(positionId, position.poolId, settleBalanceDelta, ua0, ua1);

        // -- Move the underlying liquidity to the to the seizer/caller or to the new position

        // -- Liquidate the position partially or fully
        // do this last because it counld potentially mark the position as inactive and cause some of the above calls to fail as they require an active position
        // ? _liquidatePosition will utilise the removed liquidity BalanceDelta, forward it to VTSManager.onMMLiquidityModify, where it will tryTake relative to the amount settled.
        return _liquidatePosition(poolKey, position, _positionSalt(tokenId, positionIndex), seizedLiquidityUnits);
    }

    /**
     * @dev This function is used to mark the checkpoint of the RFS for a given position. Called by MMs, and Guarantors incentivised to ensure open RfS is tracked.
     * @param tokenId The token id to mark the checkpoint of the RFS for
     * @param positionIndex The position index to mark the checkpoint of the RFS for
     */
    function checkpoint(uint256 tokenId, uint256 positionIndex) public {
        _checkpoint(tokenId, positionIndex);
    }

    /**
     * @dev This function is used to mark the checkpoint of the RFS for all positions of a given token id
     * @param tokenId The token id to mark the checkpoint of the RFS for
     * @dev Same name as checkpoint(uint256, uint256), but different selector/parameters.
     */
    function checkpoint(uint256 tokenId) public {
        for (uint256 i = 0; i < nftToPositionCount[tokenId]; i++) {
            _checkpoint(tokenId, i);
        }
    }

    /**
     * @dev This function is used to mark the checkpoint of the RFS for a given position
     * @param tokenId The token id to mark the checkpoint of the RFS for
     * @param positionIndex The position index to mark the checkpoint of the RFS for
     */
    function _checkpoint(uint256 tokenId, uint256 positionIndex) internal {
        // validate the position
        getPosition(tokenId, positionIndex);
        PositionId positionId = getPositionId(tokenId, positionIndex);
        IVTSManager vtsManager = _getVTSManager();
        // check if rfs is open for this position
        (bool rfsOpen,) = vtsManager.calcRFS(positionId, false);
        // mark the checkpoint with the state of the rfs of the position
        positionToCheckpoint[positionId].mark(rfsOpen);
        emit Checkpointed(tokenId, positionIndex, positionToCheckpoint[positionId]);
    }

    /**
     * @dev Sieze a portion of an insolvent commitment
     * @param poolKey The pool key to sieze the commitment for
     * @param tokenId The token id to sieze the commitment for
     * @param liquiditySignal The liquidity signal to sieze the commitment for
     */
    // TODO: Ensure seizeCommitment maths is correct.
    function seizeCommitment(PoolKey memory poolKey, uint256 tokenId, bytes memory liquiditySignal)
        public
        returns (uint256 deficitFractionInBips)
    {
        // verify the new liquidity signal(this increases the nonce of the mm's signals)
        // get the total usd value of the signal and its expiry time
        (uint256 totalSignalUsdValue, uint256 signalExpiryInSeconds) =
            signalManager.renewLiquiditySignal(liquiditySignal);
        // get the total unsettled value of the position
        uint256 positionTotalCommitmentsUSDValue = getTokenUnsettledUSDValue(tokenId);
        // make sure the new signal is insolvent before it can be reallocated
        if (totalSignalUsdValue >= positionTotalCommitmentsUSDValue) {
            revert InvalidLiquiditySignal(totalSignalUsdValue, positionTotalCommitmentsUSDValue);
        }
        LiquiditySignal memory newSignal = abi.decode(liquiditySignal, (LiquiditySignal));
        LiquiditySignal memory oldSignal = tokenIdToSignal[tokenId].signal;
        // validate that new signal belongs to the same mm as the old signal
        if (newSignal.mmState.owner != oldSignal.mmState.owner) {
            revert UnauthorizedSignalOwner();
        }
        // require caller is advancer, and ensures that the advancer is not the owner of the signal.
        if (msg.sender != newSignal.mmState.advancer && newSignal.mmState.advancer == newSignal.mmState.owner) {
            revert UnauthorizedSignalOwner();
        }
        // PositionMeta memory position = getPosition(tokenId, positionIndex);
        // update the signal state
        tokenIdToSignal[tokenId] = SignalState({signal: newSignal, expiresAt: block.timestamp + signalExpiryInSeconds});
        // get the difference in the usd value of the signal and the position
        // get the fraction of the deficit of the position, unit is in wad(1e18) for better precision
        deficitFractionInBips = FullMath.mulDiv(
            positionTotalCommitmentsUSDValue - totalSignalUsdValue,
            LiquidityUtils.ONE_BIP,
            positionTotalCommitmentsUSDValue
        );

        // iterate through all the positions using the position index, then liquidate a percentage given by the deficit fraction
        uint256 positionCount = nftToPositionCount[tokenId];
        for (uint256 i = 0; i < positionCount; i++) {
            PositionMeta memory position = getPosition(tokenId, i);
            // liquidate a percentage given by the deficit fraction
            uint256 liquidityToSeize =
                FullMath.mulDiv(uint256(position.liquidity), deficitFractionInBips, LiquidityUtils.ONE_BIP);
            _liquidatePosition(poolKey, position, _positionSalt(tokenId, i), liquidityToSeize);
        }
    }
}
