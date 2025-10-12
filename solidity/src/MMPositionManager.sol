// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {LiquidityRouter} from "./modules/LiquidityRouter.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {ISpokeVerifier} from "./interfaces/ISpokeVerifier.sol";
import {MarketMaker} from "./libraries/MarketMaker.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "v4-periphery/lib/v4-core/src/types/PoolOperation.sol";
import {Constants} from "v4-periphery/lib/v4-core/test/utils/Constants.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {PoolId} from "v4-periphery/lib/v4-core/src/types/PoolId.sol";
import {ERC721} from "solmate/tokens/ERC721.sol";
import {PositionMeta, PositionId, PositionLibrary} from "./types/Position.sol";
import {LiquiditySignal} from "./types/Position.sol";
import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {IVTSManager} from "./interfaces/IVTSManager.sol";
import {MarketVTSConfiguration, MarketVTSConfigurationLibrary} from "./types/VTS.sol";
import {RFSCheckpoint, RFSCheckpointLibrary} from "./types/Checkpoint.sol";
import {LiquidityUtils} from "./libraries/LiquidityUtils.sol";
import {toBalanceDelta} from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
import {IMMPositionManager} from "./interfaces/IMMPositionManager.sol";
import {IProxyHook} from "./interfaces/IProxyHook.sol";
import {ILCC} from "./interfaces/ILCC.sol";
import {IVRLSpokeReceiver} from "./interfaces/IVRLSpokeReciever.sol";
import {IPositionIndex} from "./interfaces/IPositionIndex.sol";
import {console} from "forge-std/console.sol";
import {SafeCast} from "v4-periphery/lib/v4-core/src/libraries/SafeCast.sol";

contract MMPositionManager is LiquidityRouter, ERC721, IMMPositionManager {
    using SafeCast for *;
    using RFSCheckpointLibrary for RFSCheckpoint;
    using MarketVTSConfigurationLibrary for MarketVTSConfiguration;
    using PositionLibrary for PositionId;

    error InvalidDelta(int128 amount0, int128 amount1);
    error InvalidAmount(uint256 amount, uint256 maxAmount);
    error InvalidTicker(string ticker);
    error InvalidPositionId(PositionId positionId);
    error InvalidTokenId(uint256 tokenId);
    error InvalidLiquiditySignalEncoding();
    error InsufficientLiquidityInSignal(uint256 totalSignalUsdValue, uint256 totalLCCValue);
    error InactivePosition(PositionId positionId);
    error InsufficientAmountToWithdraw(PositionId positionId, uint256 amount, uint256 maxAmount);
    error InvalidMarket(PoolKey poolKey);
    error RFSNotOpen(PositionId positionId);

    event SignalCommitted(address indexed mm, uint256 tokenId, uint256 positionIndex, uint256 amount0, uint256 amount1);
    event SignalDecommitted(
        address indexed mm, uint256 tokenId, uint256 positionIndex, uint256 amount0, uint256 amount1
    );

    address public immutable marketFactory;
    uint256 private nextTokenId = 1;
    IVRLSpokeReceiver public immutable spokeReceiver;
    mapping(PositionId => RFSCheckpoint) public positionToCheckpoint;
    mapping(uint256 => mapping(uint256 => PositionId)) public nftToPositionId;
    mapping(uint256 => uint256) public nftToPositionCount;
    mapping(PositionId => string) public proverOfPosition; //? is this necessary?

    modifier onlyNFTOwner(uint256 tokenId) {
        if (ownerOf(tokenId) != msg.sender) {
            revert InvalidTokenId(tokenId);
        }
        _;
    }

    constructor(address _manager, address _spokeReceiver, address _marketFactory)
        LiquidityRouter(_manager)
        ERC721("MMPositionManager", "MMPM")
    {
        marketFactory = _marketFactory;
        spokeReceiver = IVRLSpokeReceiver(_spokeReceiver);
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

    function _isMMPosition(PositionId positionId, PositionMeta memory m) internal view returns (bool) {
        return m.owner == address(this) && m.isActive && bytes(proverOfPosition[positionId]).length != 0;
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
            revert InvalidPositionId(positionId);
        }
        PositionMeta memory m = _getPositionIndex().getPosition(positionId, true);

        if (!_isMMPosition(positionId, m)) {
            revert InvalidPositionId(positionId);
        }

        return m;
    }

    /**
     * @dev This function is used to settle more underlying assets for a particular position
     * @param tokenId The token id to settle the position for
     * @param positionIndex The position index to settle the position for
     * @param amount0 The amount of token0 to settle
     * @param amount1 The amount of token1 to settle
     */
    function settle(uint256 tokenId, uint256 positionIndex, uint256 amount0, uint256 amount1)
        public
        onlyNFTOwner(tokenId)
    {
        PositionMeta memory m = getPosition(tokenId, positionIndex); // Validate the position by fetching it.

        // settle the underlying assets to the proxy hook
        _modifyMarketUnderlyingAsset(
            getPositionId(tokenId, positionIndex), m.poolId, toBalanceDelta(amount0.toInt128(), amount1.toInt128())
        );
        // mark RFS checkpoint
        _checkpoint(getPositionId(tokenId, positionIndex).toArray());
    }

    /**
     * @dev This function is used to withdraw settled liquidity from a position
     * @param tokenId The token id to withdraw the position for
     * @param positionIndex The position index to withdraw the position for
     * @param amount0 The amount of token0 to withdraw
     * @param amount1 The amount of token1 to withdraw
     */
    function withdraw(uint256 tokenId, uint256 positionIndex, uint256 amount0, uint256 amount1)
        public
        onlyNFTOwner(tokenId)
    {
        PositionId positionId = getPositionId(tokenId, positionIndex);
        PositionMeta memory position = getPosition(tokenId, positionIndex);

        // validate that there is no open RFS for this position
        (, BalanceDelta balanceDelta) = _getVTSManager().calcRFS(positionId, true);

        // validate the amounts to be withdrawn is within limits
        uint256 maxAmount0ToWithdraw = LiquidityUtils.safeInt128ToUint256(balanceDelta.amount0());
        uint256 maxAmount1ToWithdraw = LiquidityUtils.safeInt128ToUint256(balanceDelta.amount1());

        if (amount0 > maxAmount0ToWithdraw) {
            revert InsufficientAmountToWithdraw(positionId, amount0, maxAmount0ToWithdraw);
        }
        if (amount1 > maxAmount1ToWithdraw) {
            revert InsufficientAmountToWithdraw(positionId, amount1, maxAmount1ToWithdraw);
        }

        // withdraw the amounts from the position
        _modifyMarketUnderlyingAsset(
            positionId, position.poolId, toBalanceDelta(-amount0.toInt128(), -amount1.toInt128())
        );

        // mark RFS checkpoint
        _checkpoint(positionId.toArray());
    }

    /**
     * @dev This function is used to commit a liquidity signal to the position manager
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
        ILCC lcc0 = ILCC(Currency.unwrap(poolKey.currency0));
        ILCC lcc1 = ILCC(Currency.unwrap(poolKey.currency1));

        // verify the liquidity signal, this will return the validated reserves
        if (liquiditySignal.length == 0) {
            revert InvalidLiquiditySignalEncoding();
        }
        LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
        (string[] memory reservesTickers, uint256[] memory reservesAmounts) =
            spokeReceiver.verifyLiquiditySignal(signal);

        // calculate the total signal usd value
        uint256 totalSignalUsdValue = spokeReceiver.getTotalUsdValue(reservesTickers, reservesAmounts);

        // calculate the token0 and token1 amounts to mint to create the position
        ModifyLiquidityParams memory liquidityParams = ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: liquidity,
            salt: bytes32(0)
        });

        (uint256 lcc0AmountToMint, uint256 lcc1AmountToMint) =
            calculateTokenAmountsFromPositionParams(poolKey, liquidityParams);

        // calcualte the total LCC USD value and confirm it is less than the total signal usd value
        IVTSManager vtsManager = _getVTSManager();
        // TODO: Use a standard registry that internally maps markets to oracle factories -> oracles.
        address marketOracleFactory = vtsManager.getMarketVTSConfiguration(poolKey.toId()).oracleFactory;

        (uint256 lcc0Price, uint256 lcc0Decimals) = lcc0.usdPrice(marketOracleFactory);
        (uint256 lcc1Price, uint256 lcc1Decimals) = lcc1.usdPrice(marketOracleFactory);

        uint256 totalLCCValue = ((lcc0Price * lcc0AmountToMint) / 10 ** lcc0Decimals)
            + ((lcc1Price * lcc1AmountToMint) / 10 ** lcc1Decimals);

        // if the amount they want to commit is greater than the total signal usd value, revert
        if (totalLCCValue > totalSignalUsdValue) {
            revert InsufficientLiquidityInSignal(totalSignalUsdValue, totalLCCValue);
        }

        // Mint the tokens required for the liquidity commitment
        (PositionId positionId, uint256 tokenId, uint256 positionIndex) =
            _createPosition(poolKey, liquidityParams, signal.mmState.prover, lcc0AmountToMint, lcc1AmountToMint);

        // use the position id to make the initial settlement of the underlying tokens to the proxy hook
        // Get amount of underlying liquidity to transfer from the issuer to the lcc
        (uint256 underlyingLiquidityFraction0, uint256 underlyingLiquidityFraction1) =
            getBaseSettlementAmounts(poolKey, liquidityParams);

        // settle the underlying tokens to the proxy hook
        // By calling VTSManager.onMMLiquidityModify, we are also settling the position growths for new MMPosition.
        _modifyMarketUnderlyingAsset(
            positionId,
            poolKey.toId(),
            toBalanceDelta(underlyingLiquidityFraction0.toInt128(), underlyingLiquidityFraction1.toInt128())
        );

        emit SignalCommitted(msg.sender, tokenId, positionIndex, lcc0AmountToMint, lcc1AmountToMint);

        return positionId;
    }

    /**
     * @dev This function is used to decommit a position for a given token id
     * @param poolKey The pool key for the position
     * @param tokenId The token id to decommit the position for
     */
    function decommit(PoolKey memory poolKey, uint256 tokenId) public onlyNFTOwner(tokenId) {
        // get all positions attached to this token id
        uint256 positionCount = nftToPositionCount[tokenId];
        for (uint256 i = 0; i < positionCount; i++) {
            PositionMeta memory position = getPosition(tokenId, i);
            if (position.isActive) {
                decommitPosition(poolKey, tokenId, i);
            }
        }

        // burn the nft after removing all of the liquidity
        _burn(tokenId);
    }

    /**
     * @dev This function is used to decommit a position for a given position id
     * @param poolKey The pool key for the position
     * @param tokenId The token id to decommit the position for
     * @param positionIndex The position index to decommit the position for
     * @return balanceDelta The balance delta
     */
    function decommitPosition(PoolKey memory poolKey, uint256 tokenId, uint256 positionIndex)
        public
        onlyNFTOwner(tokenId)
        returns (BalanceDelta)
    {
        PositionId positionId = getPositionId(tokenId, positionIndex);

        // check if RFS is open
        (uint256 s0, uint256 s1) = _getVTSManager().prepareLiquidation(positionId);
        // take all the settled underlying assets from the position to the caller
        _modifyMarketUnderlyingAsset(
            getPositionId(tokenId, positionIndex), poolKey.toId(), toBalanceDelta(-s0.toInt128(), -s1.toInt128())
        );

        // different things are done with the outcome from liquidating a position partially or fully
        // during decommitment, full liquidation is done
        // during seizure, underlying liquidity is either moved to a new position if liquidated by an mm
        // so its best to handle underlying liquidity outside the liquidation logic

        // Liquidate position will call VTSManager.onMMLiquidityModify, which will settle the position growths for the new MMPosition.
        // The kicker is that it's called after getRFS, so inflows haven't been settled.
        uint256 completeLiquidity = uint256(getPosition(tokenId, positionIndex).liquidity);
        _liquidatePosition(poolKey, tokenId, positionIndex, completeLiquidity);

        emit SignalDecommitted(msg.sender, tokenId, positionIndex, uint256(uint128(s0)), uint256(uint128(s1)));

        return toBalanceDelta(int128(uint128(s0)), int128(uint128(s1)));
    }

    /**
     * @dev Get the total liquidity across all active positions for an NFT
     * @param tokenId The NFT token ID
     * @return totalLiquidity The sum of all active position liquidity
     * @return activePositionCount The number of active positions
     */
    function getTotalNFTLiquidity(uint256 tokenId)
        public
        view
        returns (int256 totalLiquidity, uint256 activePositionCount)
    {
        uint256 positionCount = nftToPositionCount[tokenId];

        for (uint256 i = 0; i < positionCount; i++) {
            PositionMeta memory position = getPosition(tokenId, i);
            if (position.isActive) {
                totalLiquidity += position.liquidity;
                activePositionCount++;
            }
        }

        return (totalLiquidity, activePositionCount);
    }

    /**
     * @dev This utility function is used to get the base settlement amounts using the base vts for a given pool key and lcc amounts
     * @param poolKey The pool key to get the base settlement amounts for
     * @param liquidityParams The liquidity parameters to get the base settlement amounts for
     * @return underlyingLiquidityFraction0 The amount of underlying liquidity to transfer from the issuer to the lcc0
     * @return underlyingLiquidityFraction1 The amount of underlying liquidity to transfer from the issuer to the lcc1
     */
    function getBaseSettlementAmounts(PoolKey memory poolKey, ModifyLiquidityParams memory liquidityParams)
        public
        view
        returns (uint256, uint256)
    {
        // get the base vts of the currencies from the pool configuration
        MarketVTSConfiguration memory vtsConfiguration = _getVTSManager().getMarketVTSConfiguration(poolKey.toId());
        (uint256 c0, uint256 c1) = LiquidityUtils.calculateCommitmentMaxima(
            liquidityParams.tickLower, liquidityParams.tickUpper, uint128(int128(liquidityParams.liquidityDelta))
        );

        // get the amount of underlying liquidity to transfer from the issuer to the lcc
        // divide by 10000 to convert to a percentage from bips
        uint256 oneBip = 10000;
        uint256 underlyingLiquidityFraction0 = (c0 * vtsConfiguration.token0.baseVTSRate) / oneBip;
        uint256 underlyingLiquidityFraction1 = (c1 * vtsConfiguration.token1.baseVTSRate) / oneBip;

        return (underlyingLiquidityFraction0, underlyingLiquidityFraction1);
    }

    function _createPosition(
        PoolKey memory poolKey,
        ModifyLiquidityParams memory liquidityParams,
        string memory prover,
        uint256 amount0,
        uint256 amount1
    ) internal returns (PositionId positionId, uint256 tokenId, uint256 positionIndex) {
        address owner = msg.sender;
        ILCC lcc0 = ILCC(Currency.unwrap(poolKey.currency0));
        ILCC lcc1 = ILCC(Currency.unwrap(poolKey.currency1));

        // Mint the tokens required for the liquidity commitment
        lcc0.issue(amount0);
        lcc1.issue(amount1);

        // Mint nft representing this position
        // ? under which condition will the tokenId be reused across multiple positions
        // TODO: Currently, this mints NFT for every commit(). Maybe we can re-use the NFT between signal verifications for quicker position management.
        tokenId = _createCommitmentNFT(owner);

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
        proverOfPosition[positionId] = prover;
    }

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
    function _createCommitmentNFT(address to) internal returns (uint256 tokenId) {
        tokenId = nextTokenId++;
        _mint(to, tokenId);
    }

    /**
     * @dev This function is used to modify the underlying assets for a given position
     * @param positionId The position id to modify the underlying assets for
     * @param poolId The pool id to modify the underlying assets for
     * @param balanceDelta The balance delta of the underlying assets to modify
     */
    function _modifyMarketUnderlyingAsset(PositionId positionId, PoolId poolId, BalanceDelta balanceDelta) internal {
        address sender = msg.sender;
        IMarketFactory mf = IMarketFactory(marketFactory);
        ILCC lcc0 = ILCC(mf.corePoolToCurrencyPair(poolId)[0]);
        ILCC lcc1 = ILCC(mf.corePoolToCurrencyPair(poolId)[1]);

        int128 amount0 = balanceDelta.amount0();
        int128 amount1 = balanceDelta.amount1();

        // make sure at least one of the amounts is not zero
        require(amount0 != 0 || amount1 != 0, InvalidDelta(amount0, amount1));
        // make sure the amounts are either both positive or both negative
        require((amount0 >= 0 && amount1 >= 0) || (amount0 <= 0 && amount1 <= 0), InvalidDelta(amount0, amount1));
        // if at least one is positive, then it is a settle, otherwise it is a take
        bool isSettle = amount0 >= 0 && amount1 >= 0;

        // Transfer the underlying tokens amount based on the vts to the market in the proxy hook
        // using the core pool key, get the corresponding proxy hook
        // transfer token1 and token0 to the proxy hook
        // call the proxy hook specifying the amount of underlying tokens transferred so it can get claim tokens for them
        address proxyHook = mf.corePoolToProxyHook(poolId);

        if (isSettle) {
            uint256 settleAmount0 = LiquidityUtils.safeInt128ToUint256(balanceDelta.amount0());
            uint256 settleAmount1 = LiquidityUtils.safeInt128ToUint256(balanceDelta.amount1());

            // transfer the underlying tokens to the Market Vault (proxy hook)
            if (settleAmount0 > 0) {
                IERC20Minimal(lcc0.underlyingAsset()).transferFrom(sender, proxyHook, settleAmount0);
            }
            if (settleAmount1 > 0) {
                IERC20Minimal(lcc1.underlyingAsset()).transferFrom(sender, proxyHook, settleAmount1);
            }
        }

        // notify the proxy hook of the settled underlying tokens we just sent to it
        // specify token0, amount0 and token1, amount1 it is important to specify the token1 and token0 here because order is important to know
        // and we can validate if the tokens are handled by the proxy hook in the `onMMLiquidityModify` function
        // a positive balance delta means we are settling underlying tokens to the proxy hook similar to having a positive liquidity delta
        IProxyHook(proxyHook).onMMLiquidityModify(balanceDelta);
        _getVTSManager().onMMLiquidityModify(positionId, balanceDelta);

        // if it is a take, then transfer the underlying tokens from the contract to the actual recipient
        if (!isSettle) {
            // transfer from this contract to the actual recipient
            uint256 takeAmount0 = LiquidityUtils.safeInt128ToUint256(balanceDelta.amount0());
            uint256 takeAmount1 = LiquidityUtils.safeInt128ToUint256(balanceDelta.amount1());
            if (takeAmount0 > 0) {
                // transfer from this contract to the actual recipient
                IERC20Minimal(lcc0.underlyingAsset()).transfer(sender, takeAmount0);
            }
            if (takeAmount1 > 0) {
                // transfer from this contract to the actual recipient
                IERC20Minimal(lcc1.underlyingAsset()).transfer(sender, takeAmount1);
            }
        }
    }

    /**
     * @dev This function is used to liquidate a position for a given token id and position index
     * @param poolKey The pool key for the position
     * @param tokenId The token id of the position to liquidate
     * @param positionIndex The position index to liquidate
     * @dev make sure to settle the underlying assets before calling this function
     *      because this function could potentially mark the position as inactive
     *      and if the position is inactive, then the call to modify the underlying assets will fail
     */
    function _liquidatePosition(
        PoolKey memory poolKey,
        uint256 tokenId,
        uint256 positionIndex,
        uint256 amountToLiquidate
    ) internal returns (BalanceDelta balanceDelta) {
        PositionMeta memory position = getPosition(tokenId, positionIndex);

        // remove the liquidity from the pool
        // By calling this, CoreHook afterRemoveLiquidity will be called to deactivate the position.
        (, balanceDelta) = _callModifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: position.tickLower,
                tickUpper: position.tickUpper,
                liquidityDelta: -int256(amountToLiquidate),
                salt: _positionSalt(tokenId, positionIndex)
            })
        );

        IMarketFactory mf = IMarketFactory(marketFactory);
        ILCC lcc0 = ILCC(mf.corePoolToCurrencyPair(position.poolId)[0]);
        ILCC lcc1 = ILCC(mf.corePoolToCurrencyPair(position.poolId)[1]);

        // burn the LCC tokens gotten from the position
        lcc0.cancel(LiquidityUtils.safeInt128ToUint256(balanceDelta.amount0()));
        lcc1.cancel(LiquidityUtils.safeInt128ToUint256(balanceDelta.amount1()));
    }

    /**
     * @dev This function is used to settle more underlying assets for a particular position
     * @param tokenId The token id to settle the position for
     * @param positionIndex The position index to settle the position for
     * @param amount0 The amount of token0 to settle
     * @param amount1 The amount of token1 to settle
     */
    function seize(uint256 tokenId, uint256 positionIndex, uint256 amount0, uint256 amount1)
        public
        returns (PositionId newPositionId)
    {
        PositionMeta memory position = getPosition(tokenId, positionIndex);
        PositionId positionId = getPositionId(tokenId, positionIndex);
        // -- Validate the position

        // make sure at least one of the amounts is zero and the other is not zero
        require((amount0 == 0) != (amount1 == 0), "InvalidBalanceDelta");
        // make sure there is an open RFS for this position
        (, BalanceDelta rfsBalanceDelta) = _getVTSManager().calcRFS(positionId, true);

        // create a balance delta of the amounts to settle
        BalanceDelta settleBalanceDelta = toBalanceDelta(amount0.toInt128(), amount1.toInt128());

        // get grace period for this position from market vts configuration
        IVTSManager vtsManager = _getVTSManager();
        MarketVTSConfiguration memory vtsConfiguration = vtsManager.getMarketVTSConfiguration(position.poolId);
        vtsConfiguration.validateGracePeriod(positionId, positionToCheckpoint[positionId]);

        uint256 maxSiezureFractionBPS = vtsManager.getSeizureAmount(positionId);
        // based on the amount they are choosing to settle, calculate how much of the total siezable amount to be seized by the caller
        uint256 seizureFractionBPS =
            LiquidityUtils.calculateSiezureFraction(settleBalanceDelta, rfsBalanceDelta, maxSiezureFractionBPS);

        // -- Settle the position to meet rfs requirements

        // settle underlying assets to the position to make it meet rfs requirements
        _modifyMarketUnderlyingAsset(
            positionId, position.poolId, toBalanceDelta(amount0.toInt128(), amount1.toInt128())
        );

        // -- Move the underlying liquidity to the to the seizer/caller or to the new position

        // transfer or liquidate all or part of the position
        uint256 liquidityToSeize = (uint256(position.liquidity) / 10000) * seizureFractionBPS;

        // get the pool key from the market factory
        IMarketFactory mf = IMarketFactory(marketFactory);
        PoolKey memory positionPoolKey = mf.poolIdToPoolKey(position.poolId);

        // if caller is an mm, then create new position for the caller based on the amount already liquidated
        // and thus transferring a percentage of the underlying asset to the caller
        // if the user already has at least one position, they are an mm, thus we check if a user is an mm based on if they have an existing position
        bool callerIsMM = balanceOf(msg.sender) > 0;

        // the amount to transfer is based on the amount already liquidated in bps
        // get the fraction of underlying assets to transfer to the caller/liquidator
        // get the total settlement amount for the position from the vts manager
        // both amount0 and amount1 are positive
        (uint256 totalSettlementAmount0, uint256 totalSettlementAmount1) =
            _getVTSManager().getPositionSettledAmounts(positionId);
        // based on the amount of the position liquidated, calculate the fraction of the underlying assets to liquidate
        BalanceDelta settlementFractionDelta = LiquidityUtils.calculateLiquidityFraction(
            toBalanceDelta(totalSettlementAmount0.toInt128(), totalSettlementAmount1.toInt128()), seizureFractionBPS
        );

        // if caller is not an mm, then immediately transfer the liquidity removed as well as the underlying assets
        if (!callerIsMM) {
            // take some position from the owner to the caller
            // this would reduce the settlement amount on the position
            _modifyMarketUnderlyingAsset(
                positionId,
                position.poolId,
                toBalanceDelta(-settlementFractionDelta.amount0(), -settlementFractionDelta.amount1())
            );
        } else {
            // settle the corresponding underlying assets to the caller/liquidator
            // create new position using the details of the previous position
            ModifyLiquidityParams memory liquidityParams = ModifyLiquidityParams({
                tickLower: position.tickLower,
                tickUpper: position.tickUpper,
                liquidityDelta: int256(liquidityToSeize),
                salt: bytes32(0)
            });
            // calculate amounts that would be settled on the new position using the new parameters
            // calculate the token0 and token1 amounts to mint to create the position
            (uint256 lcc0AmountToMint, uint256 lcc1AmountToMint) =
                LiquidityUtils.calculateTokenAmountsFromPositionParams(manager, positionPoolKey, liquidityParams);

            (newPositionId,,) = _createPosition(
                positionPoolKey, liquidityParams, proverOfPosition[positionId], lcc0AmountToMint, lcc1AmountToMint
            );

            // move settlement fraction delta to the new position
            // -- remove from old position
            vtsManager.onMMLiquidityModify(positionId, LiquidityUtils.negateBalanceDelta(settlementFractionDelta));
            // -- add to new position
            vtsManager.onMMLiquidityModify(newPositionId, settlementFractionDelta);
        }

        // -- Liquidate the position partially or fully
        // do this last because it counld potentially mark the position as inactive and cause some of the above calls to fail as they require an active position
        _liquidatePosition(positionPoolKey, tokenId, positionIndex, liquidityToSeize);
    }

    /**
     * @dev This function is used to mark the checkpoint of the RFS for a given position
     * @param positionIds The position ids to mark the checkpoint of the RFS for
     */
    function checkpoint(PositionId[] memory positionIds) public {
        _checkpoint(positionIds);
    }

    /**
     * @dev This function is used to mark the checkpoint of the RFS for a given position
     * @param positionIds The position ids to mark the checkpoint of the RFS for
     */
    function _checkpoint(PositionId[] memory positionIds) internal {
        IVTSManager vtsManager = _getVTSManager();
        for (uint256 i = 0; i < positionIds.length; i++) {
            PositionId positionId = positionIds[i];
            // check if rfs is open for this position
            (bool rfsOpen,) = vtsManager.calcRFS(positionId, false);
            // mark the checkpoint with the state of the rfs of the position
            positionToCheckpoint[positionId].mark(rfsOpen);
        }
    }
}
