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
import {PositionInfo} from "./types/Position.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";

contract MMPositionManager is LiquidityRouter, VRLSpokeReceiver, ERC721 {
    error InvalidTicker(string ticker);
    error InvalidTokenId(uint256 tokenId);

    event SignalDropped(uint256 indexed tokenId, address indexed mm, uint256 amount0, uint256 amount1);

    uint256 private nextTokenId = 1;
    mapping(uint256 => PositionInfo[]) public nftToPositions;

    constructor(address _manager, address _verifier)
        LiquidityRouter(_manager)
        VRLSpokeReceiver(_verifier)
        ERC721("MMPositionManager", "MMPM")
    {}

    function tokenURI(uint256) public pure override returns (string memory) {
        revert("Metadata not implemented");
    }

    function getPositionInfo(uint256 tokenId, uint256 positionIndex) public view returns (PositionInfo memory) {
        return nftToPositions[tokenId][positionIndex];
    }

    /**
     * @dev This function is used to commit liquidity to a pool on behalf of a market maker
     * @param positionParams The parameters of the position
     * @param proofParams The parameters of the proof
     * @param tickers The tickers of the reserves
     * @param amounts The amounts of the reserves
     */
    function commitLiquidity(
        MarketMaker.PositionParams calldata positionParams,
        // state verification parameters
        MarketMaker.ProofParams calldata proofParams,
        // amount/reserves/commitment parameters
        string[] calldata tickers,
        uint256[] calldata amounts
    ) public returns (uint256 tokenId) {
        address owner = msg.sender;
        // verify the VRL, this will return the total signal USD value
        uint256 totalSignalUsdValue = _verifyVRL(proofParams, tickers, amounts);

        // Mint the tokens required for the liquidity commitment
        (uint256 lccAmount0ToMint, uint256 lccAmount1ToMint, uint128 liquidityDelta) =
            _mintLCCPairWithBaseVTS(positionParams, totalSignalUsdValue);

        // approve pool manager to spend the lccs
        ERC20(Currency.unwrap(positionParams.corePoolKey.currency0)).approve(address(manager), lccAmount0ToMint);
        ERC20(Currency.unwrap(positionParams.corePoolKey.currency1)).approve(address(manager), lccAmount1ToMint);

        // Mint nft representing this position
        tokenId = _createCommitmentNFT(owner);

        // add liquidity to the pool
        _proxyModifyLiquidity(positionParams, int128(liquidityDelta), tokenId, nftToPositions[tokenId].length);

        // Attach position to this nft
        // make sure to add the position only after modifying the liquidity
        // because the number of positions is used to generate the salt for the position
        nftToPositions[tokenId].push(
            PositionInfo({
                poolKey: positionParams.corePoolKey,
                tickLower: positionParams.tickLower,
                tickUpper: positionParams.tickUpper,
                liquidity: liquidityDelta,
                owner: owner,
                issuer: proofParams.mmStateData.prover,
                isActive: true
            })
        );
    }

    function removeLiquidityCommitment(uint256 tokenId) public {
        // make sure only the owner can take back the commitment(s) attached to provided token id
        if (ownerOf(tokenId) != msg.sender) {
            revert InvalidTokenId(tokenId);
        }

        // TODO: Check RfS lock

        // keep track of the amount of currency0 and currency1 that was taken out of the pool
        uint256 amount0Total = 0;
        uint256 amount1Total = 0;
        PositionInfo[] storage positions = nftToPositions[tokenId];
        uint256 totalPositions = positions.length;
        for (uint256 i = 0; i < totalPositions; i++) {
            if (positions[i].isActive) {
                MarketMaker.PositionParams memory positionParams = MarketMaker.PositionParams({
                    corePoolKey: positions[i].poolKey,
                    tickLower: positions[i].tickLower,
                    tickUpper: positions[i].tickUpper
                });

                BalanceDelta balanceDelta =
                    _proxyModifyLiquidity(positionParams, -int128(positions[i].liquidity), tokenId, i);

                amount0Total += uint256(uint128(balanceDelta.amount0()));
                amount1Total += uint256(uint128(balanceDelta.amount1()));
            }
            positions[i].isActive = false;
        }
        // After removing all the liquidity, burn the nft
        _burn(tokenId);

        // TODO: unwrap lcc gotten back from the pool and send back to the user at a determined ratio

        emit SignalDropped(tokenId, msg.sender, amount0Total, amount1Total);
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
        returns (uint128 totalLiquidity, uint256 activePositionCount)
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
     * @dev This function is used to calculate the amounts of underlying liquidity needed for token0 and token1
     *      in order to create a position with the specified parameters. This is used to calculate the amount of liquidity to add to the pool
     *      for a position to be created.
     * @param positionParams The parameters of the position
     * @param totalSignalUsdValue The total signal USD value
     * @return lccUnderlyingAmount0 The amount of underlying liquidity for token0 to create the position with the specified parameters
     * @return lccUnderlyingAmount1 The amount of underlying liquidity for token1 to create the position with the specified parameters
     */
    function getCommitmentAmounts(MarketMaker.PositionParams calldata positionParams, uint256 totalSignalUsdValue)
        public
        view
        returns (uint256 lccUnderlyingAmount0, uint256 lccUnderlyingAmount1)
    {
        //TODO: Get the base vts for the lccs instead of using a mock value
        uint256 mockBaseVts = 2000;
        // calculate the split of lcc tokens in order to create the position with the specified parameters
        (uint256 lccAmount0, uint256 lccAmount1,) = calculateLCCAmountsDeltaFromUSD(positionParams, totalSignalUsdValue);

        // get the amount of underlying liquidity to transfer from the issuer to the lcc
        uint256 underlyingLiquidityFraction0 = (lccAmount0 * mockBaseVts) / 10000;
        uint256 underlyingLiquidityFraction1 = (lccAmount1 * mockBaseVts) / 10000;
        return (underlyingLiquidityFraction0, underlyingLiquidityFraction1);
    }

    /**
     * @dev This function is used to modify the liquidity of the pool
     * @param positionParams The parameters of the position
     * @param liquidityDelta The amount of liquidity to add to the pool
     * @param tokenId The token id of the nft
     */
    function _proxyModifyLiquidity(
        MarketMaker.PositionParams memory positionParams,
        int128 liquidityDelta,
        uint256 tokenId,
        uint256 positionIndex
    ) internal returns (BalanceDelta balanceDelta) {
        // generate salt using tokenId and identifier of the position
        bytes32 salt = keccak256(abi.encodePacked(tokenId, positionIndex));
        balanceDelta = _modifyLiquidity(
            positionParams.corePoolKey,
            ModifyLiquidityParams({
                tickLower: positionParams.tickLower,
                tickUpper: positionParams.tickUpper,
                liquidityDelta: int256(liquidityDelta),
                salt: salt
            }),
            Constants.ZERO_BYTES
        );
    }

    /**
     * @dev This function is used to create a new nft for a commitment
     * @param to The address of the user who is creating the commitment
     * @return tokenId The id of the nft created
     */
    function _createCommitmentNFT(address to) internal returns (uint256) {
        uint256 tokenId = nextTokenId++;
        _mint(to, tokenId);
        return tokenId;
    }

    function _mintLCCPairWithBaseVTS(MarketMaker.PositionParams calldata positionParams, uint256 totalSignalUsdValue)
        internal
        returns (uint256 lccAmount0ToMint, uint256 lccAmount1ToMint, uint128 liquidityDelta)
    {
        // mint the lccs to the mmPositionManager
        LiquidityCommitmentCertificate lcc0 =
            LiquidityCommitmentCertificate(Currency.unwrap(positionParams.corePoolKey.currency0));
        LiquidityCommitmentCertificate lcc1 =
            LiquidityCommitmentCertificate(Currency.unwrap(positionParams.corePoolKey.currency1));

        // Get amount to mint and amount to commit based on total signal usd value
        (lccAmount0ToMint, lccAmount1ToMint, liquidityDelta) =
            calculateLCCAmountsDeltaFromUSD(positionParams, totalSignalUsdValue);
        // Get amount of underlying liquidity to transfer from the issuer to the lcc
        (uint256 underlyingLiquidityFraction0, uint256 underlyingLiquidityFraction1) =
            getCommitmentAmounts(positionParams, totalSignalUsdValue);

        bytes32 marketId = PoolId.unwrap(positionParams.corePoolKey.toId());

        // issue the tokens needed to be minted
        lcc0.issue(lccAmount0ToMint);
        lcc1.issue(lccAmount1ToMint);

        // Transfer the underlying tokens amount based on the vts to the respective lcc
        IERC20Minimal(lcc0.underlyingAsset()).transferFrom(msg.sender, address(lcc0), underlyingLiquidityFraction0);
        IERC20Minimal(lcc1.underlyingAsset()).transferFrom(msg.sender, address(lcc1), underlyingLiquidityFraction1);

        // and then call confirmTake on the lcc with the marketId to account for the amount we just sent to it
        lcc0.confirmTakeWithMarketId(marketId, underlyingLiquidityFraction0);
        lcc1.confirmTakeWithMarketId(marketId, underlyingLiquidityFraction1);

        return (lccAmount0ToMint, lccAmount1ToMint, liquidityDelta);
    }
}
