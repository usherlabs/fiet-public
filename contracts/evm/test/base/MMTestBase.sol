// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {MarketMaker} from "../../src/libraries/MarketMaker.sol";
import {MerkleProofGenerator} from "../utils/MerkleProofGenerator.sol";
import {LiquiditySignal} from "../../src/types/Commit.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PositionId} from "../../src/types/Position.sol";
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";
import {MarketVTSConfiguration} from "../../src/types/VTS.sol";
import {MMPositionManager} from "../../src/MMPositionManager.sol";
import {MMActionAdapter as MMA} from "../utils/MMActionAdapter.sol";
import {LiquidityUtils} from "../../src/libraries/LiquidityUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VTSOrchestrator} from "../../src/VTSOrchestrator.sol";
import {Test} from "forge-std/Test.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {ILCC} from "../../src/interfaces/ILCC.sol";

abstract contract MarketMakerTestBase is Test {
    using MarketMaker for MarketMaker.State;
    using MerkleProofGenerator for bytes32[];
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    LiquiditySignal liquiditySignal;
    LiquiditySignal renewSignal;

    uint256 nonce = 1;

    // mock details about the ic canister
    uint256 signatureVerifierPrivateKey = uint256(keccak256(abi.encodePacked(makeAddr("publicKeyAddress"))));
    address signatureVerifier;

    struct StatePayload {
        uint256 privateKey;
        MarketMaker.State state;
    }

    /**
     * @dev entrypoint function to set up the market makers and generate the liquidity signals
     */
    function _setUpMM() public {
        signatureVerifier = vm.addr(signatureVerifierPrivateKey);
        // Create a liquidity signal
        LiquiditySignal[] memory signals = generateLiquiditySignals(2);
        _saveSignal(liquiditySignal, signals[0]);
        _saveSignal(renewSignal, signals[1]);
    }

    /// @dev Copies LiquiditySignal from memory to storage (legacy pipeline compatible)
    function _saveSignal(LiquiditySignal storage dest, LiquiditySignal memory src) internal {
        dest.nonce = src.nonce;
        dest.rootHash = src.rootHash;
        dest.rootHashSignature = src.rootHashSignature;
        // Clear and copy merkle proof
        delete dest.merkleProof;
        for (uint256 i = 0; i < src.merkleProof.length; i++) {
            dest.merkleProof.push(src.merkleProof[i]);
        }
        // Copy mmState using helper
        MarketMaker.save(dest.mmState, src.mmState);
        dest.mmSignature = src.mmSignature;
    }

    /**
     * @dev generate liquidity signals for n market makers, each with a unique private key
     * @param numOfMarketMakers The number of market makers to generate signals for
     * @return The liquidity signals
     */
    function generateLiquiditySignals(uint256 numOfMarketMakers) internal returns (LiquiditySignal[] memory) {
        // store the states of the market makers
        StatePayload[] memory marketMakerStates = new StatePayload[](numOfMarketMakers);
        // store the merkle leaves of the market makers
        bytes32[] memory merkleLeaves = new bytes32[](numOfMarketMakers);

        uint256 proofDeadline = block.timestamp + 180 days;

        for (uint256 i = 0; i < numOfMarketMakers; i++) {
            // generate a private key to serve as the signer
            uint256 uniquePrivateKey = uint256(keccak256(abi.encodePacked(i)));
            // append the market maker state to the liqudity signals generated so far
            MarketMaker.State memory state = _createMarketMakerState(uniquePrivateKey).state;
            state.expiryAt = proofDeadline;
            // append the state to the array of merkle leaves, and store the mm state and private key info
            merkleLeaves[i] = state.toLeafHash();
            marketMakerStates[i] = StatePayload({privateKey: uniquePrivateKey, state: state});
        }

        // using the states, generate the merkle root hash for the states
        bytes32 merkleRootHash = merkleLeaves.generateMerkleRoot();

        // generate liquidity signals for each market maker
        LiquiditySignal[] memory liquiditySignals = new LiquiditySignal[](numOfMarketMakers);
        for (uint256 i = 0; i < numOfMarketMakers; i++) {
            // generate liquidity payload to sign
            // bytes32 liquidityPayload = _generateLiquidityPayload(marketMakerStates[i], nonce);
            // generate the signature of the liquidity payload
            bytes memory liquidityPayloadSignature =
                _signEthMessage(marketMakerStates[i].privateKey, marketMakerStates[i].state.toLeafHash());

            // generate a canister signature of the payload(merkle root hash and signature)
            uint256 signalNonce = nonce;
            bytes32 tssMessageHash = EfficientHashLib.hash(abi.encodePacked(signalNonce, merkleRootHash));
            bytes memory signatureVerifierMerkleRootHashSignature =
                _signEthMessage(signatureVerifierPrivateKey, tssMessageHash);
            // generate the liquidity signal
            liquiditySignals[i] = LiquiditySignal({
                // the merkle root hash of the merkle tree generated from the states
                rootHash: merkleRootHash,
                // the ic canister's signature of the payload(merkle root hash and the nonce)
                rootHashSignature: signatureVerifierMerkleRootHashSignature,
                // the merkle proof of the market maker state
                merkleProof: merkleLeaves.generateProof(i),
                // the market maker state
                mmState: marketMakerStates[i].state,
                // the signature of the market maker state and the nonce
                mmSignature: liquidityPayloadSignature,
                // The nonce must always be incrementing.
                nonce: signalNonce
            });
            nonce = signalNonce + 1;
        }

        // return the liquidity signals
        return liquiditySignals;
    }

    /**
     * @dev Single-MM liquidity signal with an explicit `advancer` (must satisfy `VRLSignalManager` advancer policy).
     *      Sets `mmState.owner == advancer` so direct fresh commit from `MMPositionManager` passes owner authentication
     *      while the batch locker (`msgSender`) remains the advancer.
     */
    function generateLiquiditySignalWithAdvancer(address advancer) internal returns (LiquiditySignal memory) {
        uint256 proofDeadline = block.timestamp + 180 days;
        uint256 uniquePrivateKey = uint256(keccak256(abi.encodePacked("advancerOverride", advancer)));
        MarketMaker.State memory state = _createMarketMakerState(uniquePrivateKey).state;
        state.owner = advancer;
        state.advancer = advancer;
        state.expiryAt = proofDeadline;

        bytes32[] memory merkleLeaves = new bytes32[](1);
        merkleLeaves[0] = state.toLeafHash();
        bytes32 merkleRootHash = merkleLeaves.generateMerkleRoot();

        bytes memory liquidityPayloadSignature = _signEthMessage(uniquePrivateKey, state.toLeafHash());

        uint256 signalNonce = nonce;
        bytes32 tssMessageHash = EfficientHashLib.hash(abi.encodePacked(signalNonce, merkleRootHash));
        bytes memory signatureVerifierMerkleRootHashSignature =
            _signEthMessage(signatureVerifierPrivateKey, tssMessageHash);

        LiquiditySignal memory out = LiquiditySignal({
            rootHash: merkleRootHash,
            rootHashSignature: signatureVerifierMerkleRootHashSignature,
            merkleProof: merkleLeaves.generateProof(0),
            mmState: state,
            mmSignature: liquidityPayloadSignature,
            nonce: signalNonce
        });
        nonce = signalNonce + 1;
        return out;
    }

    /**
     * @dev given a private key, generate a state for this market maker
     * @param privateKey The private key to generate the state for
     * @return The state payload
     */
    function _createMarketMakerState(uint256 privateKey) internal view returns (StatePayload memory) {
        // use private key to get the address of the owner
        address owner = vm.addr(privateKey);
        // create a state for the owner
        MarketMaker.State memory state;
        state.owner = owner;
        state.sourceState = "0xstate.sourceState";
        state.prover = "state.prover";
        state.nonce = "nonce123";
        // Advancer must be a plain EOA or canonical EIP-7702 delegated account (see `VRLSignalManager`).
        // Align advancer with owner so `msgSender()` (MM locker) can match via `vm.startPrank(owner)` in tests.
        state.advancer = owner;

        // Add reserves
        state.reserves = new MarketMaker.Reserve[](2);
        state.reserves[0] = MarketMaker.Reserve({asset: "BTC", amount: 1e20});
        state.reserves[1] = MarketMaker.Reserve({asset: "USDT", amount: 5e18});

        return StatePayload({privateKey: privateKey, state: state});
    }

    /**
     * @dev convert the message to eth signed message and sign it, then compress the signature to 65 bytes
     * @param privateKey The private key to sign the message with
     * @param messageHash The message to sign
     * @return The compressed signature
     */
    function _signEthMessage(uint256 privateKey, bytes32 messageHash) internal pure returns (bytes memory) {
        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(messageHash);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, ethSignedMessageHash);
        return abi.encodePacked(r, s, v);
    }

    // ============ COMMITMENT SETUP HELPERS ============

    /// @dev Effective MMPM batch locker for MM liquidity ops: hook `locker` must match `mmState.advancer`
    ///      (`VTSLifecycleLinkedLib.validateMMOperation`). Commit mints the NFT to `msgSender()` (same locker).
    ///      Fresh commit requires `msgSender() == mmState.owner` on the direct path; default signals set `owner == advancer`.
    function _mmBatchLockerFromSignal(bytes memory signalBytes) internal pure returns (address) {
        return abi.decode(signalBytes, (LiquiditySignal)).mmState.advancer;
    }

    /**
     * @notice Calculates the base settlement amounts required for a given liquidity position
     * @param liquidityParams The liquidity parameters for the position
     * @param marketVTSConfiguration The VTS configuration for the market
     * @return requiredSettlementAmount0 The amount of token0 to settle
     * @return requiredSettlementAmount1 The amount of token1 to settle
     */
    function _calculateSettlementAmounts(
        ModifyLiquidityParams memory liquidityParams,
        MarketVTSConfiguration memory marketVTSConfiguration
    ) internal pure returns (uint256 requiredSettlementAmount0, uint256 requiredSettlementAmount1) {
        (uint256 c0, uint256 c1) = LiquidityUtils.calculateCommitmentMaxima(
            liquidityParams.tickLower, liquidityParams.tickUpper, uint128(uint256(liquidityParams.liquidityDelta))
        );
        return LiquidityUtils.getBaseSettlementAmounts(
            c0, c1, marketVTSConfiguration.token0.baseVTSRate, marketVTSConfiguration.token1.baseVTSRate
        );
    }

    /**
     * @notice Approves tokens for the position manager
     * @param token0 The first token
     * @param token1 The second token
     * @param amount0 The amount of token0 to approve
     * @param amount1 The amount of token1 to approve
     */
    function _approveTokenForPositionManager(
        address token0,
        address token1,
        address positionManager,
        uint256 amount0,
        uint256 amount1
    ) internal {
        if (token0 != address(0)) IERC20(token0).approve(positionManager, amount0);
        if (token1 != address(0)) IERC20(token1).approve(positionManager, amount1);
    }

    /// @dev Funds `locker` with settlement underlyings; native underlyings use `vm.deal`.
    function _fundLockerForSettlement(address locker, address token0, address token1, uint256 amount0, uint256 amount1)
        internal
    {
        if (token0 != address(0) && amount0 > 0) deal(token0, locker, amount0);
        if (token1 != address(0) && amount1 > 0) deal(token1, locker, amount1);
        // If either side is native ETH backing, ensure the locker can pay value the PM may pull.
        if (token0 == address(0) && amount0 > 0) vm.deal(locker, locker.balance + amount0);
        if (token1 == address(0) && amount1 > 0) vm.deal(locker, locker.balance + amount1);
    }

    /**
     * @notice Full workflow: calculates settlement amounts, approves tokens, and commits+mints a position
     * @param positionManager The MMPositionManager instance
     * @param corePoolKey The pool key for the core pool
     * @param signalBytes The liquidity signal bytes
     * @param liquidityParams The liquidity parameters for the position
     * @param marketVTSConfiguration The VTS configuration for the market
     * @param lcc0 The address of the first LCC token
     * @param lcc1 The address of the second LCC token
     * @return tokenId The token ID of the committed position
     * @return positionId The position ID of the minted position
     * @return requiredSettlementAmount0 The amount of token0 settled
     * @return requiredSettlementAmount1 The amount of token1 settled
     */
    function _setupCommittedPosition(
        MMPositionManager positionManager,
        PoolKey memory corePoolKey,
        bytes memory signalBytes,
        ModifyLiquidityParams memory liquidityParams,
        MarketVTSConfiguration memory marketVTSConfiguration,
        address lcc0,
        address lcc1
    )
        internal
        returns (
            uint256 tokenId,
            PositionId positionId,
            uint256 requiredSettlementAmount0,
            uint256 requiredSettlementAmount1
        )
    {
        // Calculate settlement amounts
        (requiredSettlementAmount0, requiredSettlementAmount1) =
            _calculateSettlementAmounts(liquidityParams, marketVTSConfiguration);

        address locker = _mmBatchLockerFromSignal(signalBytes);

        tokenId = _setupCommittedPositionAsLocker(
            positionManager,
            corePoolKey,
            signalBytes,
            liquidityParams,
            lcc0,
            lcc1,
            locker,
            requiredSettlementAmount0,
            requiredSettlementAmount1
        );

        positionId = positionManager.getPositionId(tokenId, 0);
    }

    /// @dev Funds the MM locker EOA, pranks it, and runs commit+mint+settle (see `VRLSignalManager` advancer policy).
    function _setupCommittedPositionAsLocker(
        MMPositionManager positionManager,
        PoolKey memory corePoolKey,
        bytes memory signalBytes,
        ModifyLiquidityParams memory liquidityParams,
        address lcc0,
        address lcc1,
        address locker,
        uint256 requiredSettlementAmount0,
        uint256 requiredSettlementAmount1
    ) private returns (uint256 tokenId) {
        address u0 = ILCC(lcc0).underlying();
        address u1 = ILCC(lcc1).underlying();
        _fundLockerForSettlement(locker, u0, u1, requiredSettlementAmount0, requiredSettlementAmount1);

        vm.startPrank(locker);
        _approveTokenForPositionManager(
            u0, u1, address(positionManager), requiredSettlementAmount0, requiredSettlementAmount1
        );

        tokenId = positionManager.nextTokenId();

        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](3);
        actions[0] = MMA.prepareCommit(signalBytes);
        actions[1] = MMA.prepareMint(
            corePoolKey,
            tokenId,
            liquidityParams.tickLower,
            liquidityParams.tickUpper,
            uint256(liquidityParams.liquidityDelta)
        );
        actions[2] = MMA.prepareSettle(
            corePoolKey,
            tokenId,
            0,
            -SafeCast.toInt128(requiredSettlementAmount0),
            -SafeCast.toInt128(requiredSettlementAmount1),
            false
        );

        (bytes memory actionsBytes, bytes[] memory params) = MMA.concatPrepared(actions);
        positionManager.modifyLiquidities(abi.encode(actionsBytes, params), block.timestamp + 3600);
        vm.stopPrank();
    }
}
