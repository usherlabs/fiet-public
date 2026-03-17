// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {console} from "forge-std/Script.sol";

import {E2EBase} from "./E2EBase.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Token} from "../../setup/MockERC20.s.sol";

import {LiquiditySignal} from "src/types/Commit.sol";
import {MarketMaker} from "src/libraries/MarketMaker.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ActionConstants} from "v4-periphery/src/libraries/ActionConstants.sol";

import {ILCC} from "src/interfaces/ILCC.sol";
import {MMPositionManager} from "src/MMPositionManager.sol";
import {IVTSOrchestrator} from "src/interfaces/IVTSOrchestrator.sol";
import {LiquidityUtils} from "src/libraries/LiquidityUtils.sol";
import {MarketVTSConfiguration} from "src/types/VTS.sol";
import {ILiquidityHub} from "src/interfaces/ILiquidityHub.sol";
import {MMActions} from "src/libraries/MMActions.sol";

abstract contract MME2EBase is E2EBase {
    using MarketMaker for MarketMaker.State;
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;

    function _executeMMActions(MMPositionManager mmpm, bytes memory actions, bytes[] memory params, uint256 deadline)
        internal
    {
        mmpm.modifyLiquidities(abi.encode(actions, params), deadline);
    }

    /// @dev Fee “poke”: no-op increase (0) to touch the position, then TAKE both pool currencies to wallet.
    function _pokePosition(StandaloneMarket memory m, uint256 mmPk, uint256 commitId)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        address mm = vm.addr(mmPk);
        PoolKey memory corePoolKey = _corePoolKey(m);

        address lcc0 = Currency.unwrap(corePoolKey.currency0);
        address lcc1 = Currency.unwrap(corePoolKey.currency1);

        uint256 lcc0Before = IERC20(lcc0).balanceOf(mm);
        uint256 lcc1Before = IERC20(lcc1).balanceOf(mm);

        vm.startBroadcast(mmPk);
        {
            // IMPORTANT: The unlock batch must end with no residual deltas, so we TAKE both currencies after touching.
            MMPositionManager mmpm = MMPositionManager(payable(m.stack.contracts.mmPositionManager));
            bytes memory actions = abi.encodePacked(
                bytes1(uint8(MMActions.INCREASE_LIQUIDITY)), bytes1(uint8(MMActions.TAKE)), bytes1(uint8(MMActions.TAKE))
            );
            bytes[] memory params = new bytes[](3);
            params[0] = abi.encode(corePoolKey, commitId, 0, 0);
            params[1] = abi.encode(corePoolKey.currency0, mm, 0);
            params[2] = abi.encode(corePoolKey.currency1, mm, 0);
            _executeMMActions(mmpm, actions, params, block.timestamp + 3600);
        }
        vm.stopBroadcast();

        uint256 lcc0After = IERC20(lcc0).balanceOf(mm);
        uint256 lcc1After = IERC20(lcc1).balanceOf(mm);

        amount0 = lcc0After - lcc0Before;
        amount1 = lcc1After - lcc1Before;
        require(amount0 > 0 || amount1 > 0, "poke: expected some LCC change");

        console.log("OK: position poked");
        console.log("fee lcc0 taken:", amount0);
        console.log("fee lcc1 taken:", amount1);
    }

    /// @dev CHECKPOINT a position via MMPositionManager. Pass `liquiditySignal = bytes("")` to skip commitment validation.
    function _checkpointPosition(
        StandaloneMarket memory m,
        uint256 mmPk,
        uint256 commitId,
        uint256 positionIndex,
        bytes memory liquiditySignal
    ) internal {
        vm.startBroadcast(mmPk);
        {
            MMPositionManager mmpm = MMPositionManager(payable(m.stack.contracts.mmPositionManager));
            mmpm.checkpoint(commitId, positionIndex, liquiditySignal.length > 0);
        }
        vm.stopBroadcast();
    }

    /// @dev Optionally fund+wrap for a taker, then execute a single exact-input swap.
    /// If `wrapAmount == 0`, funding/wrapping is skipped and only the swap is executed.
    /// @return amountOut Amount of tokenOut received from the swap
    function _mintAndSwap(
        StandaloneMarket memory m,
        uint256 takerPk,
        uint256 wrapAmount,
        bool zeroForOne,
        uint128 swapAmount
    ) internal returns (uint256 amountOut) {
        _logTick("tick (before swap)", _corePoolKey(m));
        address taker = vm.addr(takerPk);

        // Fund taker and wrap underlying -> LCC so taker can trade core pool currencies.
        if (wrapAmount > 0) {
            // IMPORTANT: `zeroForOne` is defined relative to the *sorted pool currencies* (currency0/currency1),
            // not `m.underlying0/m.underlying1`. To ensure we fund the correct input token, derive the input LCC
            // from the PoolKey and then wrap its underlying.
            PoolKey memory key = _corePoolKey(m);
            address tokenIn = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);

            vm.startBroadcast(takerPk);
            address underlying = ILCC(tokenIn).underlying();
            Token(underlying).mint(taker, wrapAmount);
            _wrapAndMintLcc(ILiquidityHub(m.stack.contracts.liquidityHub), m.marketId, underlying, taker, wrapAmount);
            vm.stopBroadcast();
        }

        (,,, amountOut) = _swapExactInputSingle(m, takerPk, zeroForOne, swapAmount, 0);
        console.log("OK: swap complete");
        console.log("zeroForOne:", zeroForOne);
        console.log("amountIn:", swapAmount);
        console.log("amountOut:", amountOut);
        _logTick("tick (after swap)", _corePoolKey(m));
    }

    /// @dev Fund a taker with underlying, wrap -> LCC, then swap in both directions.
    /// @return amountOut0 Amount of token0 received from the 1 -> 0 swap
    /// @return amountOut1 Amount of token1 received from the 0 -> 1 swap
    function _swapBothDirections(StandaloneMarket memory m, uint256 takerPk, uint256 wrapAmount, uint128 swapAmount)
        internal
        returns (uint256 amountOut0, uint256 amountOut1)
    {
        // One swap in each direction. Fund+wrap both currencies once for symmetric inputs.
        if (wrapAmount > 0) {
            address taker = vm.addr(takerPk);
            ILiquidityHub hub = ILiquidityHub(m.stack.contracts.liquidityHub);
            vm.startBroadcast(takerPk);
            Token(m.underlying0).mint(taker, wrapAmount);
            Token(m.underlying1).mint(taker, wrapAmount);
            _wrapAndMintLccPair(hub, m, taker, wrapAmount);
            vm.stopBroadcast();
        }

        amountOut1 = _mintAndSwap(m, takerPk, 0, true, swapAmount); // 0 -> 1
        amountOut0 = _mintAndSwap(m, takerPk, 0, false, swapAmount); // 1 -> 0
        console.log("OK: swap both directions complete");
    }

    /// @dev Settle a position to a given amount of underlying0 and underlying1
    function _settleToPosition(
        StandaloneMarket memory m,
        uint256 mmPk,
        uint256 commitId,
        int128 amount0,
        int128 amount1
    ) internal {
        require(amount0 > 0 && amount1 > 0, "settleToPosition: amounts must be > 0");
        address mm = vm.addr(mmPk);
        MMPositionManager mmpm = MMPositionManager(payable(m.stack.contracts.mmPositionManager));

        vm.startBroadcast(mmPk);
        // Ensure MM has enough underlying to settle.
        Token(m.underlying0).mint(mm, uint256(uint128(amount0)));
        Token(m.underlying1).mint(mm, uint256(uint128(amount1)));
        IERC20(m.underlying0).approve(address(mmpm), uint256(uint128(amount0)));
        IERC20(m.underlying1).approve(address(mmpm), uint256(uint128(amount1)));

        PoolKey memory key = _corePoolKey(m);
        bytes memory actions = abi.encodePacked(bytes1(uint8(MMActions.SETTLE_POSITION)));
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(key, commitId, 0, -amount0, -amount1, false);
        _executeMMActions(mmpm, actions, params, block.timestamp + 3600);
        vm.stopBroadcast();
    }

    /// @dev Log the tick of a pool
    function _logTick(string memory label, PoolKey memory key) internal view {
        (, int24 tick,,) = IPoolManager(config.poolManager).getSlot0(key.toId());
        console.log(label, tick);
    }

    function _baseSettlementAmounts(
        address vtsOrchestratorAddr,
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liq
    )
        internal
        view
        returns (uint256 settle0, uint256 settle1)
    {
        IVTSOrchestrator vts = IVTSOrchestrator(vtsOrchestratorAddr);
        MarketVTSConfiguration memory vtsCfg = vts.getMarketVTSConfiguration(key.toId());
        (uint256 c0, uint256 c1) = LiquidityUtils.calculateCommitmentMaxima(tickLower, tickUpper, liq);
        (settle0, settle1) =
            LiquidityUtils.getBaseSettlementAmounts(c0, c1, vtsCfg.token0.baseVTSRate, vtsCfg.token1.baseVTSRate);
    }

    function _executeCreatePositionBatch(
        MMPositionManager mmpm,
        PoolKey memory key,
        uint256 commitId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liq,
        bytes memory liquiditySignalBytes,
        uint256 settle0,
        uint256 settle1
    ) internal {
        bytes memory actions = abi.encodePacked(
            bytes1(uint8(MMActions.COMMIT_SIGNAL)),
            bytes1(uint8(MMActions.MINT_POSITION)),
            bytes1(uint8(MMActions.SETTLE_POSITION))
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(liquiditySignalBytes, ActionConstants.MSG_SENDER, bytes(""));
        params[1] = abi.encode(key, commitId, tickLower, tickUpper, liq);
        params[2] =
            abi.encode(key, commitId, 0, -int128(int256(settle0)), -int128(int256(settle1)), false);
        _executeMMActions(mmpm, actions, params, block.timestamp + 3600);
    }

    /// @dev Create a new position for a market maker
    function _createMmPosition(StandaloneMarket memory m, uint256 mmPk, int24 tickLower, int24 tickUpper, uint128 liq)
        internal
        returns (uint256 commitId)
    {
        address mm = vm.addr(mmPk);

        MMPositionManager mmpm = MMPositionManager(payable(m.stack.contracts.mmPositionManager));
        PoolKey memory key = _corePoolKey(m);

        bytes memory liquiditySignalBytes = _buildSingleLeafLiquiditySignal(mmPk, 1);
        (uint256 settle0, uint256 settle1) =
            _baseSettlementAmounts(m.stack.contracts.vtsOrchestrator, key, tickLower, tickUpper, liq);

        commitId = mmpm.nextTokenId();

        vm.startBroadcast(mmPk);
        Token(m.underlying0).mint(mm, settle0);
        Token(m.underlying1).mint(mm, settle1);
        IERC20(m.underlying0).approve(address(mmpm), settle0);
        IERC20(m.underlying1).approve(address(mmpm), settle1);

        _executeCreatePositionBatch(
            mmpm, key, commitId, tickLower, tickUpper, liq, liquiditySignalBytes, settle0, settle1
        );
        vm.stopBroadcast();

        require(mmpm.ownerOf(commitId) == mm, "mmpm: owner mismatch");
    }

    /// @dev Close RFS (so burn can succeed), then burn → withdraw-from-deltas → decommit, and TAKE any LCC credits.
    function _closeRfsBurnDecommitAndTakeAllLccs(StandaloneMarket memory m, uint256 mmPk, uint256 commitId) internal {
        _settleRfsIfOpen(m, mmPk, commitId);
        _burnDecommitAndTakeAllLccs(m, mmPk, commitId);
    }

    /// @dev Settle the RFS if it is open
    function _settleRfsIfOpen(StandaloneMarket memory m, uint256 mmPk, uint256 commitId) internal {
        address mm = vm.addr(mmPk);
        PoolKey memory corePoolKey = _corePoolKey(m);

        IVTSOrchestrator vts = IVTSOrchestrator(m.stack.contracts.vtsOrchestrator);
        (, bool rfsOpen, BalanceDelta rfsDelta) = vts.calcRFS(commitId, 0, false);
        int128 d0 = rfsDelta.amount0();
        int128 d1 = rfsDelta.amount1();

        if (!rfsOpen) {
            vts.calcRFS(commitId, 0, true);
            return;
        }

        // If delta > 0, settlement is required; we deposit with negative amounts.
        int128 settle0 = d0 > 0 ? -type(int128).max : int128(0);
        int128 settle1 = d1 > 0 ? -type(int128).max : int128(0);

        uint256 fund0 = d0 > 0 ? uint256(int256(type(int128).max)) : 0;
        uint256 fund1 = d1 > 0 ? uint256(int256(type(int128).max)) : 0;

        vm.startBroadcast(mmPk);
        {
            MMPositionManager mmpm = MMPositionManager(payable(m.stack.contracts.mmPositionManager));

            if (fund0 > 0) {
                Token(m.underlying0).mint(mm, fund0);
                IERC20(m.underlying0).approve(address(mmpm), fund0);
            }
            if (fund1 > 0) {
                Token(m.underlying1).mint(mm, fund1);
                IERC20(m.underlying1).approve(address(mmpm), fund1);
            }

            bytes memory actions = abi.encodePacked(bytes1(uint8(MMActions.SETTLE_POSITION)));
            bytes[] memory params = new bytes[](1);
            params[0] = abi.encode(corePoolKey, commitId, 0, settle0, settle1, false);
            _executeMMActions(mmpm, actions, params, block.timestamp + 3600);
        }
        vm.stopBroadcast();

        vts.calcRFS(commitId, 0, true);
    }

    /// @dev Burn the position, settle from deltas, decommit, and take all LCCs
    function _burnDecommitAndTakeAllLccs(StandaloneMarket memory m, uint256 mmPk, uint256 commitId) internal {
        address mm = vm.addr(mmPk);
        PoolKey memory corePoolKey = _corePoolKey(m);

        vm.startBroadcast(mmPk);
        {
            MMPositionManager mmpm = MMPositionManager(payable(m.stack.contracts.mmPositionManager));
            bytes memory actions = abi.encodePacked(
                bytes1(uint8(MMActions.BURN_POSITION)),
                bytes1(uint8(MMActions.SETTLE_POSITION_FROM_DELTAS)),
                bytes1(uint8(MMActions.DECOMMIT_SIGNAL)),
                bytes1(uint8(MMActions.TAKE)),
                bytes1(uint8(MMActions.TAKE))
            );
            bytes[] memory params = new bytes[](5);
            params[0] = abi.encode(corePoolKey, commitId, 0);
            params[1] = abi.encode(corePoolKey, commitId, 0, true, true);
            params[2] = abi.encode(commitId);
            params[3] = abi.encode(corePoolKey.currency0, mm, 0);
            params[4] = abi.encode(corePoolKey.currency1, mm, 0);
            _executeMMActions(mmpm, actions, params, block.timestamp + 3600);
        }
        vm.stopBroadcast();

        console.log("OK: closed RFS + burned + withdrew-from-deltas + decommitted");
    }

    /// @dev Unwraps LCC balances held by `mmPk` back to underlying tokens.
    /// `unwrapAmount == 0` is treated as unwrap-all by MMPositionManager.
    function _unwrapLcc(StandaloneMarket memory m, address lcc, uint256 mmPk, uint256 unwrapAmount, bool assertBalance)
        internal
        returns (uint256 underlyingDelta)
    {
        address mm = vm.addr(mmPk);
        address underlying = ILCC(lcc).underlying();
        ILiquidityHub hub = ILiquidityHub(m.stack.contracts.liquidityHub);

        uint256 lccBefore = IERC20(lcc).balanceOf(mm);
        uint256 underlyingBefore = IERC20(underlying).balanceOf(mm);

        vm.startBroadcast(mmPk);
        {
            MMPositionManager mmpm = MMPositionManager(payable(m.stack.contracts.mmPositionManager));

            // UNWRAP_LCC(payerIsUser=true) pulls LCC from the MM via transferFrom.
            // Approve exactly what we currently hold.
            IERC20(lcc).approve(address(mmpm), lccBefore);

            bytes memory actions = abi.encodePacked(bytes1(uint8(MMActions.UNWRAP_LCC)));
            bytes[] memory params = new bytes[](1);
            params[0] = abi.encode(lcc, unwrapAmount, mm, true);
            _executeMMActions(mmpm, actions, params, block.timestamp + 3600);
        }
        vm.stopBroadcast();

        uint256 lccAfter = IERC20(lcc).balanceOf(mm);
        uint256 underlyingAfter = IERC20(underlying).balanceOf(mm);
        uint256 outstandingQueued = hub.settleQueue(lcc, mm);

        uint256 lccSpent = lccBefore - lccAfter;
        underlyingDelta = underlyingAfter - underlyingBefore;

        console.log("unwrap spent lcc:", lccSpent);
        console.log("unwrap underlying received:", underlyingDelta);
        console.log("unwrap queued shortfall:", outstandingQueued);

        // Unwrap may annul existing queue during transferFrom and then queue fresh shortfall.
        // Assert immediate underlying plus the final outstanding queue equals LCC spent.
        if (assertBalance) {
            require(underlyingDelta + outstandingQueued == lccSpent, "unwrap: redemption mismatch");
        }
    }

    /// @dev Unwraps LCC balances held by `mmPk` back to underlying tokens.
    /// `unwrapAmount == 0` is treated as unwrap-all by MMPositionManager.
    function _unwrapAllLccsAndAssert(StandaloneMarket memory m, uint256 mmPk, uint256 unwrapAmount, bool assertBalance)
        internal
        returns (uint256 underlying0Delta, uint256 underlying1Delta)
    {
        PoolKey memory corePoolKey = _corePoolKey(m);

        address lcc0 = Currency.unwrap(corePoolKey.currency0);
        address lcc1 = Currency.unwrap(corePoolKey.currency1);

        underlying0Delta = _unwrapLcc(m, lcc0, mmPk, unwrapAmount, assertBalance);
        underlying1Delta = _unwrapLcc(m, lcc1, mmPk, unwrapAmount, assertBalance);
    }

    // ============================================================
    // Signal utilities (MM-specific)
    // ============================================================

    function _packSig(uint8 v, bytes32 r, bytes32 s) internal pure returns (bytes memory) {
        return abi.encodePacked(r, s, v);
    }

    /// @dev Signs an Ethereum message with a private key
    function _signEthMessage(uint256 pk, bytes32 messageHash) internal pure returns (bytes memory sig) {
        bytes32 ethSigned = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, ethSigned);
        sig = _packSig(v, r, s);
    }

    /// @dev Rounds down to nearest multiple of `tickSpacing` (handles negative ticks).
    function _floorTick(int24 tick, int24 tickSpacing) internal pure returns (int24 rounded) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && (tick % tickSpacing) != 0) compressed -= 1;
        rounded = compressed * tickSpacing;
    }

    /// @dev Builds a single-leaf LiquiditySignal (MMPositionManager commit path).
    function _buildSingleLeafLiquiditySignal(uint256 mmPk, uint256 nonce)
        internal
        view
        returns (bytes memory signalBytes)
    {
        address mm = vm.addr(mmPk);

        MarketMaker.State memory st;
        st.owner = mm;
        st.sourceState = "e2e.sourceState";
        st.prover = "e2e.prover";
        st.nonce = "e2e.nonce";
        // MMPositionManager forwards locker as hook-data sender on MM ops;
        // keep advancer aligned with the E2E MM actor to satisfy sender guards.
        st.advancer = mm;
        st.reserves = new MarketMaker.Reserve[](2);
        st.reserves[0] = MarketMaker.Reserve({asset: "BTC", amount: 1e20});
        st.reserves[1] = MarketMaker.Reserve({asset: "USDT", amount: 5e18});

        bytes32 leafHash = st.toLeafHash();
        bytes32 rootHash = leafHash;

        // MM authorizes the signal by signing the leafHash (verifier checks recovered == mmState.owner).
        bytes memory mmSig = _signEthMessage(mmPk, leafHash);

        // Canister (in E2E: deployer EOA) signs (nonce, rootHash).
        bytes32 rootMsg = keccak256(abi.encodePacked(nonce, rootHash));
        bytes memory rootSig = _signEthMessage(_getDeployerPrivateKey(), rootMsg);

        bytes32[] memory proof = new bytes32[](0);
        LiquiditySignal memory sig = LiquiditySignal({
            nonce: nonce,
            rootHash: rootHash,
            rootHashSignature: rootSig,
            merkleProof: proof,
            mmState: st,
            mmSignature: mmSig
        });

        signalBytes = abi.encode(sig);
    }
}

