// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {LiquidityRouter} from "./modules/LiquidityRouter.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {ISpokeVerifier} from "./interfaces/ISpokeVerifier.sol";
import {MarketMaker} from "./libraries/MarketMaker.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "v4-periphery/lib/v4-core/src/types/PoolOperation.sol";
import {Constants} from "v4-periphery/lib/v4-core/test/utils/Constants.sol";
import {BalanceDelta} from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {PoolId} from "v4-periphery/lib/v4-core/src/types/PoolId.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC721} from "solmate/tokens/ERC721.sol";
import {PositionInfo, PositionId, PositionLibrary} from "./types/Position.sol";
import {LiquiditySignal} from "./types/Position.sol";
import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {IVTSManager} from "./interfaces/IVTSManager.sol";
import {MarketVTSConfiguration} from "./types/VTS.sol";
import {LiquidityUtils} from "./libraries/LiquidityUtils.sol";
import {toBalanceDelta} from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMMPositionManager} from "./interfaces/IMMPositionManager.sol";
import {IProxyHook} from "./interfaces/IProxyHook.sol";
import {ILCC} from "./interfaces/ILCC.sol";
import {IVRLSpokeReceiver} from "./interfaces/IVRLSpokeReciever.sol";

contract MMPositionManager is LiquidityRouter, ERC721, IMMPositionManager {
    error InvalidTicker(string ticker);
    error InvalidPositionId(PositionId positionId);
    error InvalidTokenId(uint256 tokenId);
    error InvalidLiquiditySignalEncoding();
    error InsufficientLiquidityInSignal(uint256 totalSignalUsdValue, uint256 totalLCCValue);
    error InactivePosition(PositionId positionId);
    error RFSOpenForPosition(PositionId positionId);
    error InsufficientAmountToWithdraw(PositionId positionId, uint256 amount, uint256 maxAmount);

    event SignalCommitted(address indexed mm, PositionId positionId, uint256 amount0, uint256 amount1);
    event SignalDecommitted(address indexed mm, PositionId positionId, uint256 amount0, uint256 amount1);

    address public marketFactory;
    uint256 private nextTokenId = 1;
    IVRLSpokeReceiver public spokeReceiver;
    // mapping(tokenId => mapping(positionIndex => PositionInfo)) public nftToPositions;
    mapping(uint256 => mapping(uint256 => PositionId)) public nftToPositionId;
    mapping(PositionId => PositionInfo) public positions; // TODO: Merge PositionIndex and this mapping, unifying all position state across DirectLPs and MMs.

    // mapping(tokenId => numNFTPositionsCount) public nftToPositionCount;
    mapping(uint256 => uint256) public nftToPositionCount;

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

    /**
     * Gets information about a position using the token id and position index
     * @param positionId The position id to get the position info for
     * @return positionInfo The position info
     */
    function getPosition(PositionId positionId) public view returns (PositionInfo memory) {
        return positions[positionId];
    }

    /**
     * @dev This function is used to settle more underlying assets for a particular position
     * @param positionId The position id to settle the position for
     * @param amount0 The amount of token0 to settle
     * @param amount1 The amount of token1 to settle
     */
    function settle(PositionId positionId, uint256 amount0, uint256 amount1) public {
        PositionInfo memory position = positions[positionId];
        // make sure only the owner can settle the position
        if (position.owner != msg.sender) {
            revert InvalidPositionId(positionId);
        }

        // make sure the position is active
        if (!position.isActive) {
            revert InactivePosition(positionId);
        }

        // settle the underlying assets to the proxy hook
        _settleUnderlyingAssetToMarket(position.poolKey, position.positionId, amount0, amount1);
    }

    /**
     * @dev This function is used to withdraw settled liquidity from a position
     * @param positionId The position id to withdraw the position for
     * @param amount0 The amount of token0 to withdraw
     * @param amount1 The amount of token1 to withdraw
     */
    function withdraw(PositionId positionId, uint256 amount0, uint256 amount1) public {
        PositionInfo memory position = positions[positionId];
        // make sure only the owner can withdraw the position
        if (position.owner != msg.sender) {
            revert InvalidPositionId(positionId);
        }
        // make sure the position is active
        if (!position.isActive) {
            revert InactivePosition(positionId);
        }

        // validate that there is no open RFS for this position
        address vtsManager = IMarketFactory(marketFactory).getCoreHook();
        (bool rfsOpen, BalanceDelta balanceDelta) = IVTSManager(vtsManager).getRFS(positionId);
        if (rfsOpen) {
            revert RFSOpenForPosition(positionId);
        }

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
        _takeUnderlyingAssetFromMarket(position.poolKey, positionId, amount0, amount1);
    }

    /**
     * @dev This function is used to commit a liquidity signal to the position manager
     * @param _poolKey The pool key to commit the liquidity signal to
     * @param _liquidityParams The liquidity parameters to commit the liquidity signal to
     * @param _liquiditySignal The liquidity signal to commit to the position manager
     * @return positionId The unique identifier of the position created
     */
    function commit(
        PoolKey calldata _poolKey,
        ModifyLiquidityParams memory _liquidityParams,
        bytes memory _liquiditySignal
    ) external returns (PositionId) {
        address owner = msg.sender;
        ILCC lcc0 = ILCC(Currency.unwrap(_poolKey.currency0));
        ILCC lcc1 = ILCC(Currency.unwrap(_poolKey.currency1));

        // verify the liquidity signal, this will return the validated reserves
        if (_liquiditySignal.length == 0) {
            revert InvalidLiquiditySignalEncoding();
        }
        LiquiditySignal memory signal = abi.decode(_liquiditySignal, (LiquiditySignal));
        (string[] memory reservesTickers, uint256[] memory reservesAmounts) =
            spokeReceiver.verifyLiquiditySignal(signal);
        string memory issuer = signal.mmState.prover;

        // calculate the total signal usd value
        uint256 totalSignalUsdValue = spokeReceiver.getTotalUsdValue(reservesTickers, reservesAmounts);

        // calculate the token0 and token1 amounts to mint to create the position
        (uint256 lcc0AmountToMint, uint256 lcc1AmountToMint) =
            calculateTokenAmountsFromPositionParams(_poolKey, _liquidityParams);

        // calcualte the total LCC USD value and confirm it is less than the total signal usd value
        address vtsManager = IMarketFactory(marketFactory).getCoreHook();
        address marketOracleFactory = IVTSManager(vtsManager).getMarketVTSConfiguration(_poolKey.toId()).oracleFactory;

        (uint256 lcc0Price, uint256 lcc0Decimals) = lcc0.usdPrice(marketOracleFactory);
        (uint256 lcc1Price, uint256 lcc1Decimals) = lcc1.usdPrice(marketOracleFactory);

        uint256 totalLCCValue = ((lcc0Price * lcc0AmountToMint) / 10 ** lcc0Decimals)
            + ((lcc1Price * lcc1AmountToMint) / 10 ** lcc1Decimals);

        // if the amount they want to commit is greater than the total signal usd value, revert
        if (totalLCCValue > totalSignalUsdValue) {
            revert InsufficientLiquidityInSignal(totalSignalUsdValue, totalLCCValue);
        }

        // Mint the tokens required for the liquidity commitment
        lcc0.issue(lcc0AmountToMint);
        lcc1.issue(lcc1AmountToMint);

        // Mint nft representing this position
        // ? under which condition will the tokenId be reused across multiple positions
        uint256 tokenId = _createCommitmentNFT(owner);

        // add liquidity to the pool using the token id and position index to generate a unique salt
        uint256 positionIndex = nftToPositionCount[tokenId];
        (PositionId positionId,) = _callModifyLiquidity(_poolKey, _liquidityParams, tokenId, positionIndex);

        // use the position id to make the initial settlement of the underlying tokens to the proxy hook
        // Get amount of underlying liquidity to transfer from the issuer to the lcc
        (uint256 underlyingLiquidityFraction0, uint256 underlyingLiquidityFraction1) =
            getBaseSettlementAmounts(_poolKey, lcc0AmountToMint, lcc1AmountToMint);

        // settle the underlying tokens to the proxy hook
        _settleUnderlyingAssetToMarket(_poolKey, positionId, underlyingLiquidityFraction0, underlyingLiquidityFraction1);

        // Attach position to this nft
        // make sure to add the position only after modifying the liquidity
        // because the number of positions is used to generate the salt for the position
        nftToPositionId[tokenId][positionIndex] = positionId;
        positions[positionId] = PositionInfo({
            owner: owner,
            tokenId: tokenId,
            isActive: true,
            issuer: issuer,
            positionId: positionId,
            poolKey: _poolKey,
            positionIndex: positionIndex,
            tickLower: _liquidityParams.tickLower,
            tickUpper: _liquidityParams.tickUpper,
            liquidity: _liquidityParams.liquidityDelta
        });
        // increment the number of positions for the nft
        nftToPositionCount[tokenId]++;

        emit SignalCommitted(msg.sender, positionId, lcc0AmountToMint, lcc1AmountToMint);

        return positionId;
    }

    /**
     * @dev This function is used to decommit a position for a given token id
     * @param tokenId The token id to decommit the position for
     */
    function decommit(uint256 tokenId) public {
        // make sure only the owner can take back the commitment(s) attached to provided token id
        if (ownerOf(tokenId) != msg.sender) {
            revert InvalidTokenId(tokenId);
        }

        // get all positions attached to this token id
        uint256 positionCount = nftToPositionCount[tokenId];
        for (uint256 i = 0; i < positionCount; i++) {
            PositionId positionId = nftToPositionId[tokenId][i];
            PositionInfo memory position = positions[positionId];
            if (position.isActive) {
                decommitPosition(positionId);
            }
        }

        // burn the nft after removing all of the liquidity
        _burn(tokenId);
    }

    /**
     * @dev This function is used to decommit a position for a given position id
     * @param positionId The position id to decommit the position for
     * @return balanceDelta The balance delta
     */
    function decommitPosition(PositionId positionId) public returns (BalanceDelta) {
        PositionInfo memory position = positions[positionId];
        // make sure only the owner can take back the commitment(s) attached to provided token id
        if (position.owner != msg.sender) {
            revert InvalidPositionId(positionId);
        }

        // check if RFS is open
        address vtsManager = IMarketFactory(marketFactory).getCoreHook();
        (bool rfsOpen,) = IVTSManager(vtsManager).getRFS(positionId);
        if (rfsOpen) {
            revert RFSOpenForPosition(positionId);
        }

        // liquidiate the position
        BalanceDelta balanceDelta = _liquidatePosition(positionId);

        emit SignalDecommitted(
            msg.sender, positionId, uint256(uint128(balanceDelta.amount0())), uint256(uint128(balanceDelta.amount1()))
        );

        return balanceDelta;
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
            PositionId positionId = nftToPositionId[tokenId][i];
            PositionInfo memory position = positions[positionId];
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
     * @param lccAmount0 The amount of lcc0 to get the base settlement amounts for
     * @param lccAmount1 The amount of lcc1 to get the base settlement amounts for
     * @return lccUnderlyingAmount0 The amount of underlying liquidity to transfer from the issuer to the lcc0
     * @return lccUnderlyingAmount1 The amount of underlying liquidity to transfer from the issuer to the lcc1
     */
    function getBaseSettlementAmounts(PoolKey memory poolKey, uint256 lccAmount0, uint256 lccAmount1)
        public
        view
        returns (uint256 lccUnderlyingAmount0, uint256 lccUnderlyingAmount1)
    {
        // get the base vts of the currencies from the pool configuration
        address coreHook = IMarketFactory(marketFactory).getCoreHook();
        MarketVTSConfiguration memory vtsConfiguration = IVTSManager(coreHook).getMarketVTSConfiguration(poolKey.toId());

        // get the amount of underlying liquidity to transfer from the issuer to the lcc
        // divide by 10000 to convert to a percentage from bips
        uint256 underlyingLiquidityFraction0 = (lccAmount0 * vtsConfiguration.token0.baseVTSRate) / 10000;
        uint256 underlyingLiquidityFraction1 = (lccAmount1 * vtsConfiguration.token1.baseVTSRate) / 10000;
        return (underlyingLiquidityFraction0, underlyingLiquidityFraction1);
    }

    /**
     * @dev This function is used to modify liquidity for a given pool key, token id and position index and generates a unique salt using the token id and position index
     * @param poolKey The pool key to modify liquidity for
     * @param liquidityParams The liquidity parameters to modify liquidity for
     * @param tokenId The token id to modify liquidity for
     * @param positionIndex The position index to modify liquidity for
     * @return positionId The position id
     * @return balanceDelta The balance delta
     */
    function _callModifyLiquidity(
        PoolKey memory poolKey,
        ModifyLiquidityParams memory liquidityParams,
        uint256 tokenId,
        uint256 positionIndex
    ) internal returns (PositionId positionId, BalanceDelta balanceDelta) {
        // generate salt using tokenId and identifier of the position
        bytes32 salt = keccak256(abi.encodePacked(tokenId, positionIndex));
        // use salt to create a unique params for the modify liquidity operation
        // @dev do not use the direct liqidity params because we generate a new salt and the one passed in is not used
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: liquidityParams.tickLower,
            tickUpper: liquidityParams.tickUpper,
            liquidityDelta: int256(liquidityParams.liquidityDelta),
            salt: salt
        });
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
     * @dev This function is used to settle some assets to the proxy hook of a market specified by the pool key provided
     * @param poolKey The pool key to settle the underlying assets to the proxy hook
     * @param underlyingLCC0AmountToSettle The amount of underlying token0 to settle to the proxy hook
     * @param underlyingLCC1AmountToSettle The amount of underlying token1 to settle to the proxy hook
     */
    function _settleUnderlyingAssetToMarket(
        PoolKey memory poolKey,
        PositionId positionId,
        uint256 underlyingLCC0AmountToSettle,
        uint256 underlyingLCC1AmountToSettle
    ) internal {
        address sender = msg.sender;
        ILCC lcc0 = ILCC(Currency.unwrap(poolKey.currency0));
        ILCC lcc1 = ILCC(Currency.unwrap(poolKey.currency1));

        // Transfer the underlying tokens amount based on the vts to the market in the proxy hook
        // using the core pool key, get the corresponding proxy hook
        // transfer token1 and token0 to the proxy hook
        // call the proxy hook specifying the amount of underlying tokens transferred so it can get claim tokens for them
        PoolId proxyPoolId = IMarketFactory(marketFactory).coreToProxy(poolKey.toId());
        address proxyHook = IMarketFactory(marketFactory).proxyToHook(proxyPoolId);

        // transfer the underlying tokens to the proxy hook
        IERC20Minimal(lcc0.underlyingAsset()).transferFrom(sender, proxyHook, underlyingLCC0AmountToSettle);
        IERC20Minimal(lcc1.underlyingAsset()).transferFrom(sender, proxyHook, underlyingLCC1AmountToSettle);

        // notify the proxy hook of the settled underlying tokens we just sent to it
        // specify token0, amount0 and token1, amount1 it is important to specify the token1 and token0 here because order is important to know
        // and we can validate if the tokens are handled by the proxy hook in the `onMMLiquidityModify` function
        // a positive balance delta means we are settling underlying tokens to the proxy hook similar to having a positive liquidity delta
        BalanceDelta balanceDelta =
            toBalanceDelta(int128(uint128(underlyingLCC0AmountToSettle)), int128(uint128(underlyingLCC1AmountToSettle)));
        IProxyHook(proxyHook).onMMLiquidityModify(lcc0.underlyingAsset(), lcc1.underlyingAsset(), balanceDelta);

        // notify the vts manager of the settlement made for this position
        address coreHook = IMarketFactory(marketFactory).getCoreHook();
        IVTSManager(coreHook).onMMLiquidityModify(positionId, balanceDelta);
    }

    /**
     * @dev This function is used to settle some assets to the proxy hook of a market specified by the pool key provided
     * @param poolKey The pool key to settle the underlying assets to the proxy hook
     * @param underlyingLCC0AmountToTake The amount of underlying token0 to settle to the proxy hook
     * @param underlyingLCC1AmountToTake The amount of underlying token1 to settle to the proxy hook
     */
    function _takeUnderlyingAssetFromMarket(
        PoolKey memory poolKey,
        PositionId positionId,
        uint256 underlyingLCC0AmountToTake,
        uint256 underlyingLCC1AmountToTake
    ) internal {
        address sender = msg.sender;
        ILCC lcc0 = ILCC(Currency.unwrap(poolKey.currency0));
        ILCC lcc1 = ILCC(Currency.unwrap(poolKey.currency1));

        PoolId proxyPoolId = IMarketFactory(marketFactory).coreToProxy(poolKey.toId());
        address proxyHook = IMarketFactory(marketFactory).proxyToHook(proxyPoolId);

        // a negative balance delta means we are taking underlying tokens from the proxy hook similar to having a negative liquidity delta
        BalanceDelta balanceDelta =
            toBalanceDelta(-int128(uint128(underlyingLCC0AmountToTake)), -int128(uint128(underlyingLCC1AmountToTake)));

        // notify the proxy hook of the underlying tokens we just took from it
        // specify token0, amount0 and token1, amount1 it is important to specify the token1 and token0 here because order is important to know
        // and we can validate if the tokens are handled by the proxy hook in the `onMMLiquidityModify` function
        IProxyHook(proxyHook).onMMLiquidityModify(lcc0.underlyingAsset(), lcc1.underlyingAsset(), balanceDelta);

        // notify the vts manager of the settlement made for this position
        address coreHook = IMarketFactory(marketFactory).getCoreHook();
        IVTSManager(coreHook).onMMLiquidityModify(positionId, balanceDelta);

        // transfer from this contract to the actual recipient
        IERC20Minimal(lcc0.underlyingAsset()).transfer(sender, underlyingLCC0AmountToTake);
        IERC20Minimal(lcc1.underlyingAsset()).transfer(sender, underlyingLCC1AmountToTake);
    }

    /**
     * @dev This function is used to liquidate a position for a given token id and position index
     * @param positionId The position id to liquidate the position for
     * @return balanceDelta The balance delta
     */
    function _liquidatePosition(PositionId positionId) internal returns (BalanceDelta) {
        PositionInfo memory position = positions[positionId];
        ILCC lcc0 = ILCC(Currency.unwrap(position.poolKey.currency0));
        ILCC lcc1 = ILCC(Currency.unwrap(position.poolKey.currency1));
        // make sure the position is active
        if (!position.isActive) {
            revert InactivePosition(positionId);
        }

        // get total amount settled from the VTS manager
        // important to do this before removing the liquidity from the pool
        // because the position information is cleared after removing the liquidity
        address vtsManager = IMarketFactory(marketFactory).getCoreHook();
        (uint256 settledAmount0, uint256 settledAmount1) = IVTSManager(vtsManager).getPositionSettledAmounts(positionId);

        // remove the liquidity from the pool
        (, BalanceDelta balanceDelta) = _callModifyLiquidity(
            position.poolKey,
            ModifyLiquidityParams({
                tickLower: position.tickLower,
                tickUpper: position.tickUpper,
                liquidityDelta: -int256(position.liquidity),
                salt: bytes32(0)
            }),
            position.tokenId,
            position.positionIndex
        );

        // get the amounts removed from the pool
        uint256 amount0 = LiquidityUtils.safeInt128ToUint256(balanceDelta.amount0());
        uint256 amount1 = LiquidityUtils.safeInt128ToUint256(balanceDelta.amount1());

        // delete metadata associated with the position
        positions[positionId].isActive = false;

        // burn the LCC gotten back from the pool
        lcc0.burn(amount0);
        lcc1.burn(amount1);

        // take amount settled from the proxy hook
        _takeUnderlyingAssetFromMarket(position.poolKey, positionId, settledAmount0, settledAmount1);

        // return the balance delta which is the settled amount
        return toBalanceDelta(int128(uint128(settledAmount0)), int128(uint128(settledAmount1)));
    }
}
