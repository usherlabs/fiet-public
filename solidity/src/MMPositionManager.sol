// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {LiquidityRouter} from "./modules/LiquidityRouter.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {VRLSpokeReceiver} from "./modules/VRLSpokeReceiver.sol";
import {ISpokeVerifier} from "./interfaces/ISpokeVerifier.sol";
import {MarketMaker} from "./libraries/MarketMaker.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "v4-periphery/lib/v4-core/src/types/PoolOperation.sol";
import {Constants} from "v4-periphery/lib/v4-core/test/utils/Constants.sol";
import {console} from "forge-std/console.sol";
import {BalanceDelta} from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
import {LiquidityCommitmentCertificate} from "./LCC.sol";
import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {PoolId} from "v4-periphery/lib/v4-core/src/types/PoolId.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC721} from "solmate/tokens/ERC721.sol";
import {PositionInfo, PositionId, PositionLibrary} from "./types/Position.sol";
import {LiquiditySignal} from "./types/Position.sol";
import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
import {ProxyHook} from "./ProxyHook.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {IVTSManager} from "./interfaces/IVTSManager.sol";
import {MarketVTSConfiguration} from "./types/VTS.sol";

contract MMPositionManager is LiquidityRouter, VRLSpokeReceiver, ERC721 {
    error InvalidTicker(string ticker);
    error InvalidTokenId(uint256 tokenId);
    error InvalidLiquiditySignalEncoding();
    error InsufficientLiquidityInSignal(uint256 totalSignalUsdValue, uint256 totalLCCValue);

    event SignalCommitted(
        address indexed mm, uint256 indexed tokenId, uint256 indexed positionIndex, uint256 amount0, uint256 amount1
    );

    uint256 private nextTokenId = 1;
    mapping(uint256 => PositionInfo[]) public nftToPositions;
    address public marketFactory;

    constructor(address _manager, address _oracleRegistry, address _verifier, address _marketFactory)
        LiquidityRouter(_manager)
        VRLSpokeReceiver(_verifier, _oracleRegistry)
        ERC721("MMPositionManager", "MMPM")
    {
        marketFactory = _marketFactory;
    }

    function tokenURI(uint256) public pure override returns (string memory) {
        revert("Metadata not implemented");
    }

    function getPositionInfo(uint256 tokenId, uint256 positionIndex) public view returns (PositionInfo memory) {
        return nftToPositions[tokenId][positionIndex];
    }

    function commit(
        PoolKey calldata _poolKey,
        ModifyLiquidityParams memory _liquidityParams,
        bytes memory _liquiditySignal
    ) external returns (uint256 tokenId) {
        LiquidityCommitmentCertificate lcc0 =
            LiquidityCommitmentCertificate(payable(Currency.unwrap(_poolKey.currency0)));
        LiquidityCommitmentCertificate lcc1 =
            LiquidityCommitmentCertificate(payable(Currency.unwrap(_poolKey.currency1)));

        address owner = msg.sender;
        // verify the liquidity signal, this will return the validated reserves
        if (_liquiditySignal.length == 0) {
            revert InvalidLiquiditySignalEncoding();
        }
        LiquiditySignal memory signal = abi.decode(_liquiditySignal, (LiquiditySignal));
        (string[] memory reservesTickers, uint256[] memory reservesAmounts) = _verifyLiquiditySignal(signal);
        string memory issuer = signal.mmState.prover;

        // calculate the total signal usd value
        uint256 totalSignalUsdValue = getTotalUsdValue(reservesTickers, reservesAmounts);

        // calculate the token0 and token1 amounts to mint to create the position
        (uint256 lcc0AmountToMint, uint256 lcc1AmountToMint) =
            calculateTokenAmountsFromPositionParams(_poolKey, _liquidityParams);

        // calcualte the total LCC USD value and confirm it is less than the total signal usd value
        (uint256 lcc0Price, uint256 lcc0Decimals) = lcc0.usdPrice();
        (uint256 lcc1Price, uint256 lcc1Decimals) = lcc1.usdPrice();

        uint256 totalLCCValue = ((lcc0Price * lcc0AmountToMint) / 10 ** lcc0Decimals)
            + ((lcc1Price * lcc1AmountToMint) / 10 ** lcc1Decimals);

        if (totalLCCValue > totalSignalUsdValue) {
            revert InsufficientLiquidityInSignal(totalSignalUsdValue, totalLCCValue);
        }

        // Mint the tokens required for the liquidity commitment
        lcc0.issue(lcc0AmountToMint);
        lcc1.issue(lcc1AmountToMint);

        // Mint nft representing this position
        // ? under which condition will the tokenId be reused across multiple positions
        tokenId = _createCommitmentNFT(owner);

        // add liquidity to the pool using the token id and position index to generate a unique salt
        uint256 positionIndex = nftToPositions[tokenId].length;
        (PositionId positionId,) = _proxyModifyLiquidity(_poolKey, _liquidityParams, tokenId, positionIndex);

        // use the position id to make the initial settlement of the underlying tokens to the proxy hook
        _settleBaseLCCPair(_poolKey, positionId, lcc0AmountToMint, lcc1AmountToMint);

        // Attach position to this nft
        // make sure to add the position only after modifying the liquidity
        // because the number of positions is used to generate the salt for the position
        nftToPositions[tokenId].push(
            PositionInfo({
                positionId: positionId,
                poolKey: _poolKey,
                tickLower: _liquidityParams.tickLower,
                tickUpper: _liquidityParams.tickUpper,
                liquidity: _liquidityParams.liquidityDelta,
                owner: owner,
                issuer: issuer,
                isActive: true
            })
        );

        emit SignalCommitted(msg.sender, tokenId, positionIndex, lcc0AmountToMint, lcc1AmountToMint);
    }

    // function removeLiquidityCommitment(uint256 tokenId) public {
    // make sure only the owner can take back the commitment(s) attached to provided token id
    // if (ownerOf(tokenId) != msg.sender) {
    //     revert InvalidTokenId(tokenId);
    // }

    // // TODO: Check RfS lock

    // // keep track of the amount of currency0 and currency1 that was taken out of the pool
    // uint256 amount0Total = 0;
    // uint256 amount1Total = 0;
    // PositionInfo[] storage positions = nftToPositions[tokenId];
    // uint256 totalPositions = positions.length;
    // for (uint256 i = 0; i < totalPositions; i++) {
    //     if (positions[i].isActive) {
    //         MarketMaker.PositionParams memory positionParams = MarketMaker.PositionParams({
    //             corePoolKey: positions[i].poolKey,
    //             tickLower: positions[i].tickLower,
    //             tickUpper: positions[i].tickUpper
    //         });

    //         BalanceDelta balanceDelta =
    //             _proxyModifyLiquidity(positionParams, -int128(positions[i].liquidity), tokenId, i);

    //         amount0Total += uint256(uint128(balanceDelta.amount0()));
    //         amount1Total += uint256(uint128(balanceDelta.amount1()));
    //     }
    //     positions[i].isActive = false;
    // }
    // // After removing all the liquidity, burn the nft
    // _burn(tokenId);

    // // TODO: unwrap lcc gotten back from the pool and send back to the user at a determined ratio

    // }

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
        PositionInfo[] storage positions = nftToPositions[tokenId];

        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].isActive) {
                totalLiquidity += positions[i].liquidity;
                activePositionCount++;
            }
        }

        return (totalLiquidity, activePositionCount);
    }

    /**
     * @dev This function is used to get the base settlement amounts using the base vts for a given pool key and lcc amounts
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
    function _proxyModifyLiquidity(
        PoolKey memory poolKey,
        ModifyLiquidityParams memory liquidityParams,
        uint256 tokenId,
        uint256 positionIndex
    ) internal returns (PositionId positionId, BalanceDelta balanceDelta) {
        // generate salt using tokenId and identifier of the position
        bytes32 salt = keccak256(abi.encodePacked(tokenId, positionIndex));

        balanceDelta = _modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: liquidityParams.tickLower,
                tickUpper: liquidityParams.tickUpper,
                liquidityDelta: int256(liquidityParams.liquidityDelta),
                salt: salt
            }),
            Constants.ZERO_BYTES
        );

        positionId = PositionLibrary.generateId(msg.sender, liquidityParams);
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
     * @dev This function is used to settle the LCC pair required to create the position on the pool
     *      it also derives the initial settlement amounts for the underlying tokens for the LCC pair, and transfers the underlying tokens to the proxy prool
     *      it then calls the proxy hook notify it of the added liquidity so the proxy pool can get claim tokens for them and deposit it into the pool manager
     * @param poolKey The pool key to issue and settle the base lcc pair for
     * @param lcc0Amount The amount of lcc0 to settle
     * @param lcc1Amount The amount of lcc1 to settle
     */
    function _settleBaseLCCPair(PoolKey memory poolKey, PositionId positionId, uint256 lcc0Amount, uint256 lcc1Amount)
        internal
    {
        // Get amount of underlying liquidity to transfer from the issuer to the lcc
        (uint256 underlyingLiquidityFraction0, uint256 underlyingLiquidityFraction1) =
            getBaseSettlementAmounts(poolKey, lcc0Amount, lcc1Amount);

        // settle the underlying tokens to the proxy hook
        _settleUnderlyingAssetToProxyHook(
            poolKey, positionId, underlyingLiquidityFraction0, underlyingLiquidityFraction1
        );
    }

    /**
     * @dev This function is used to settle some assets to the proxy hook of a market specified by the pool key provided
     * @param poolKey The pool key to settle the underlying assets to the proxy hook
     * @param underlyingLCC0AmountToSettle The amount of underlying token0 to settle to the proxy hook
     * @param underlyingLCC1AmountToSettle The amount of underlying token1 to settle to the proxy hook
     */
    function _settleUnderlyingAssetToProxyHook(
        PoolKey memory poolKey,
        PositionId positionId,
        uint256 underlyingLCC0AmountToSettle,
        uint256 underlyingLCC1AmountToSettle
    ) internal {
        address sender = msg.sender;
        LiquidityCommitmentCertificate lcc0 =
            LiquidityCommitmentCertificate(payable(Currency.unwrap(poolKey.currency0)));
        LiquidityCommitmentCertificate lcc1 =
            LiquidityCommitmentCertificate(payable(Currency.unwrap(poolKey.currency1)));

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
        // and we can validate if the tokens are handled by the proxy hook in the `onSettleUnderlyingAssets` function
        ProxyHook(proxyHook).onSettleUnderlyingAssets(
            lcc0.underlyingAsset(), lcc1.underlyingAsset(), underlyingLCC0AmountToSettle, underlyingLCC1AmountToSettle
        );

        // notify the vts manager of the settlement made for this position
        address coreHook = IMarketFactory(marketFactory).getCoreHook();
        IVTSManager(coreHook).onSettleAssets(positionId, underlyingLCC0AmountToSettle, underlyingLCC1AmountToSettle);
    }
}
