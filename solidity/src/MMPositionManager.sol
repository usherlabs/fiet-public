// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {LiquidityRouter} from "./modules/LiquidityRouter.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "v4-periphery/lib/v4-core/src/types/PoolOperation.sol";
import {Constants} from "v4-periphery/lib/v4-core/test/utils/Constants.sol";
import {BalanceDelta, toBalanceDelta, BalanceDeltaLibrary} from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {PoolId} from "v4-periphery/lib/v4-core/src/types/PoolId.sol";
import {ERC721Permit_v4} from "v4-periphery/src/base/ERC721Permit_v4.sol";
import {ReentrancyLock} from "v4-periphery/src/base/ReentrancyLock.sol";
import {Multicall_v4} from "v4-periphery/src/base/Multicall_v4.sol";
import {BaseActionsRouter} from "v4-periphery/src/base/BaseActionsRouter.sol";
import {PositionMeta, PositionId, PositionLibrary} from "./types/Position.sol";
import {LiquiditySignal, SignalState} from "./types/Position.sol";
import {MarketMaker} from "./libraries/MarketMaker.sol";
import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {IVTSManager} from "./interfaces/IVTSManager.sol";
import {MarketVTSConfiguration, MarketVTSConfigurationLibrary} from "./types/VTS.sol";
import {LiquidityUtils} from "./libraries/LiquidityUtils.sol";
import {IMMPositionManager} from "./interfaces/IMMPositionManager.sol";
import {IProxyHook} from "./interfaces/IProxyHook.sol";
import {ILCC} from "./interfaces/ILCC.sol";
import {IVRLSignalManager} from "./interfaces/IVRLSignalManager.sol";
import {IPositionIndex} from "./interfaces/IPositionIndex.sol";
import {SafeCast} from "v4-periphery/lib/v4-core/src/libraries/SafeCast.sol";
import {FullMath} from "v4-periphery/lib/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
import {RFSCheckpointModule} from "./modules/RFSCheckpoint.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {NativeWrapper} from "v4-periphery/src/base/NativeWrapper.sol";
import {LCCWrapper} from "./modules/LCCWrapper.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {TransientSlots} from "./libraries/TransientSlots.sol";
import {CurrencyLibrary} from "v4-periphery/lib/v4-core/src/types/Currency.sol";

interface ICommitmentDescriptor {
    function tokenURI(address manager, uint256 tokenId) external view returns (string memory);
}

contract MMPositionManager is
    LiquidityRouter,
    ERC721Permit_v4,
    RFSCheckpointModule,
    IMMPositionManager,
    ReentrancyLock,
    Multicall_v4,
    BaseActionsRouter,
    NativeWrapper,
    LCCWrapper
{
    using SafeCast for uint256;
    using MarketVTSConfigurationLibrary for MarketVTSConfiguration;
    using PositionLibrary for PositionId;
    using MarketMaker for MarketMaker.State;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    error InvalidDelta(int128 amount0, int128 amount1);
    error InvalidAmount(uint256 amount, uint256 maxAmount);
    error InvalidLiquiditySignal(uint256 totalSignalUsdValue, uint256 totalLCCValue);
    error InvalidPosition(uint256 tokenId, uint256 positionIndex, PositionId positionId);
    error InvalidMarket(PoolKey poolKey);
    error SignalExpired(uint256 tokenId);
    error UnauthorizedSignalOwner();
    error DeadlinePassed(uint256 deadline);
    error NotApproved(address caller);

    event SignalCommitted(uint256 tokenId);
    event SignalDecommitted(uint256 tokenId, uint256 positionIndex, uint256 amount0, uint256 amount1);

    address public immutable marketFactory;
    address public immutable commitmentDescriptor;
    uint256 private nextTokenId = 1;
    IVRLSignalManager public immutable signalManager;
    mapping(uint256 => mapping(uint256 => PositionId)) public commitToPosition;
    mapping(uint256 => uint256) public commitToPositionCount;

    struct Commit {
        SignalState state;
        PoolId poolId;
    }

    mapping(uint256 => Commit) public commitOf;

    enum MMAction {
        COMMIT_SIGNAL,
        MINT_POSITION,
        SETTLE_POSITION,
        INCREASE_LIQUIDITY,
        DECREASE_LIQUIDITY,
        BURN_POSITION,
        RENEW_SIGNAL,
        SEIZE_POSITION,
        SEIZE_COMMITMENT,
        DECOMMIT,
        UNWRAP_LCC, // params: (address lcc, uint256 amount)
        WRAP_NATIVE, // params: (uint256 amount)
        UNWRAP_NATIVE // params: (uint256 amount)

    }

    constructor(address _manager, address _signalManager, address _marketFactory, address _descriptor, IWETH9 _weth9)
        ERC721Permit_v4("Fiet VRL Commitment Positions Manager", "FIET-VRL-MMP")
        BaseActionsRouter(IPoolManager(_manager))
        NativeWrapper(_weth9)
    {
        marketFactory = _marketFactory;
        signalManager = IVRLSignalManager(_signalManager);
        commitmentDescriptor = _descriptor;
    }

    modifier onlyValidCommit(PoolKey memory poolKey, uint256 tokenId) {
        _assertSignalValid(tokenId);
        _assertCommitForPool(poolKey, tokenId);
        _;
    }

    /// @notice Reverts if the caller is not the owner or approved for the ERC721 token
    /// @param caller The address of the caller
    /// @param tokenId the unique identifier of the ERC721 token
    /// @dev either msg.sender or msgSender() is passed in as the caller
    /// msgSender() should ONLY be used if this is called from within the unlockCallback, unless the codepath has reentrancy protection
    modifier onlyIfApproved(address caller, uint256 tokenId) {
        _assertApprovedOrOwner(caller, tokenId);
        _;
    }

    /// @notice Enforces that the PoolManager is locked.
    modifier onlyIfPoolManagerLocked() {
        if (poolManager.isUnlocked()) revert IPositionManager.PoolManagerMustBeLocked();
        _;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        if (commitmentDescriptor != address(0)) {
            return ICommitmentDescriptor(commitmentDescriptor).tokenURI(address(this), tokenId);
        }
        uint256 posCount = commitToPositionCount[tokenId];
        SignalState memory s = commitOf[tokenId].state;
        string memory name = string(abi.encodePacked("Fiet Commitment #", Strings.toString(tokenId)));
        string memory description = "Fiet VRL Commitment NFT granting position management rights.";
        string memory attributes = string(
            abi.encodePacked(
                "[{\"trait_type\":\"positions\",\"value\":",
                Strings.toString(posCount),
                "},",
                "{\"trait_type\":\"expiresAt\",\"value\":",
                Strings.toString(s.expiresAt),
                "}]"
            )
        );
        string memory json = string(
            abi.encodePacked(
                "{\"name\":\"",
                name,
                "\",",
                "\"description\":\"",
                description,
                "\",",
                "\"attributes\":",
                attributes,
                "}"
            )
        );
        return string(abi.encodePacked("data:application/json;utf8,", json));
    }

    function _getVTSManager() internal view returns (IVTSManager) {
        return IVTSManager(IMarketFactory(marketFactory).getCoreHook());
    }

    function _getPositionIndex() internal view returns (IPositionIndex) {
        return IPositionIndex(IMarketFactory(marketFactory).getCoreHook());
    }

    /// @dev Internal helper to unwrap an arbitrary LCC (pair-agnostic) to msgSender().
    ///      Non-reverting best-effort: clamps to manager-held balance; used by UNWRAP_LCC action.
    function _unwrapLCCInternal(address lccAddr, uint256 amount) internal returns (uint256 unwrapped) {
        unwrapped = _unwrapLCC(ILCC(lccAddr), msgSender(), amount);
    }

    function getPositionId(uint256 tokenId, uint256 positionIndex) public view returns (PositionId) {
        return commitToPosition[tokenId][positionIndex];
    }

    /// @notice Returns the next tokenId that will be minted on the next commit
    function getNextTokenId() external view returns (uint256) {
        return nextTokenId;
    }

    function getSignalState(uint256 tokenId) public view returns (SignalState memory) {
        return commitOf[tokenId].state;
    }

    function _positionCountOf(uint256 tokenId) internal view override returns (uint256) {
        return commitToPositionCount[tokenId];
    }

    function _isMMPosition(PositionMeta memory m) internal view returns (bool) {
        // MM-managed positions are those owned by this manager and active.
        // Prover metadata can be read from commit state if needed; not required to validate MM ownership.
        return m.owner == address(this) && m.isActive;
    }

    function _assertApprovedOrOwner(address caller, uint256 tokenId) internal view {
        if (!_isApprovedOrOwner(caller, tokenId)) revert NotApproved(caller);
    }

    function _assertSignalValid(uint256 tokenId) internal view {
        if (commitOf[tokenId].state.expiresAt < block.timestamp) {
            revert SignalExpired(tokenId);
        }
    }

    function _assertCommitForPool(PoolKey memory poolKey, uint256 tokenId) internal view {
        if (PoolId.unwrap(commitOf[tokenId].poolId) != PoolId.unwrap(poolKey.toId())) {
            revert InvalidMarket(poolKey);
        }
    }

    /// @inheritdoc BaseActionsRouter
    function msgSender() public view override(BaseActionsRouter, LiquidityRouter) returns (address) {
        return _getLocker();
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

    // ------------------------
    // Uniswap-like batch entrypoints and dispatcher
    // ------------------------

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert DeadlinePassed(deadline);
        _;
    }

    // Mirrors v4 PositionManager.modifyLiquidities
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline)
        external
        payable
        isNotLocked
        checkDeadline(deadline)
    {
        _executeActions(unlockData);
    }

    // Mirrors v4 PositionManager.modifyLiquiditiesWithoutUnlock
    function modifyLiquiditiesWithoutUnlock(bytes calldata actions, bytes[] calldata params)
        external
        payable
        isNotLocked
    {
        _executeActionsWithoutUnlock(actions, params);
    }

    function _handleAction(uint256 action, bytes calldata params) internal override {
        if (action == uint256(MMAction.COMMIT_SIGNAL)) {
            (PoolKey memory poolKey, bytes memory liquiditySignal) = abi.decode(params, (PoolKey, bytes));
            _commitSignal(poolKey, liquiditySignal);
            return;
        }
        if (action == uint256(MMAction.MINT_POSITION)) {
            (PoolKey memory poolKey, uint256 tokenId, int24 tickLower, int24 tickUpper, uint256 liquidity) =
                abi.decode(params, (PoolKey, uint256, int24, int24, uint256));
            _mintPosition(poolKey, tokenId, tickLower, tickUpper, liquidity);
            return;
        }
        if (action == uint256(MMAction.SETTLE_POSITION)) {
            (PoolKey memory poolKey, uint256 tokenId, uint256 positionIndex, int128 amount0, int128 amount1) =
                abi.decode(params, (PoolKey, uint256, uint256, int128, int128));
            _settle(poolKey, tokenId, positionIndex, amount0, amount1);
            return;
        }
        if (action == uint256(MMAction.INCREASE_LIQUIDITY)) {
            (
                PoolKey memory poolKey,
                uint256 tokenId,
                uint256 positionIndex,
                int24 tickUpper,
                int24 tickLower,
                uint256 liquidity
            ) = abi.decode(params, (PoolKey, uint256, uint256, int24, int24, uint256));
            _increase(poolKey, tokenId, positionIndex, tickUpper, tickLower, liquidity);
            return;
        }
        if (action == uint256(MMAction.DECREASE_LIQUIDITY)) {
            (PoolKey memory poolKey, uint256 tokenId, uint256 positionIndex, uint256 amountToDecrease) =
                abi.decode(params, (PoolKey, uint256, uint256, uint256));
            PositionMeta memory position = getPosition(tokenId, positionIndex);
            _assertSignalValid(tokenId);
            _assertCommitForPool(poolKey, tokenId);
            _assertApprovedOrOwner(msgSender(), tokenId);
            _decrease(poolKey, position, _positionSalt(tokenId, positionIndex), amountToDecrease, true);
            return;
        }
        if (action == uint256(MMAction.BURN_POSITION)) {
            (PoolKey memory poolKey, uint256 tokenId, uint256 positionIndex) =
                abi.decode(params, (PoolKey, uint256, uint256));
            _assertSignalValid(tokenId);
            _assertCommitForPool(poolKey, tokenId);
            _assertApprovedOrOwner(msgSender(), tokenId);
            _burnPosition(poolKey, tokenId, positionIndex);
            return;
        }
        if (action == uint256(MMAction.RENEW_SIGNAL)) {
            (uint256 tokenId, bytes memory liquiditySignal) = abi.decode(params, (uint256, bytes));
            _renew(tokenId, liquiditySignal);
            return;
        }
        if (action == uint256(MMAction.SEIZE_POSITION)) {
            (PoolKey memory poolKey, uint256 tokenId, uint256 positionIndex, uint256 amount0, uint256 amount1) =
                abi.decode(params, (PoolKey, uint256, uint256, uint256, uint256));
            // seize is third-party action; no approval required by design
            _seizePosition(poolKey, tokenId, positionIndex, amount0, amount1);
            return;
        }
        if (action == uint256(MMAction.SEIZE_COMMITMENT)) {
            (PoolKey memory poolKey, uint256 tokenId, bytes memory liquiditySignal) =
                abi.decode(params, (PoolKey, uint256, bytes));
            // seize commitment is third-party advancer flow; no approval required
            _seizeCommitment(poolKey, tokenId, liquiditySignal);
            return;
        }
        if (action == uint256(MMAction.DECOMMIT)) {
            (PoolKey memory poolKey, uint256 tokenId) = abi.decode(params, (PoolKey, uint256));
            _decommitSignal(poolKey, tokenId);
            return;
        }
        if (action == uint256(MMAction.UNWRAP_LCC)) {
            // params: (address lcc, uint256 amount)
            (address lccAddr, uint256 amount) = abi.decode(params, (address, uint256));
            // Pair-agnostic: accept any LCC address. Governance/guards can be added if needed.
            // Unwrap best-effort to msgSender(); non-reverting, clamps to available manager-held LCC.
            _unwrapLCCInternal(lccAddr, amount);
            return;
        }
        if (action == uint256(MMAction.WRAP_NATIVE)) {
            // Reference: https://github.com/Uniswap/v4-periphery/blob/444c526b77d804590f0d7bc5a481af5a3277c952/src/PositionManager.sol#L275
            // params: (uint256 amount)
            uint256 amount = abi.decode(params, (uint256));
            uint256 wrapAmt = amount > address(this).balance ? address(this).balance : amount;
            if (wrapAmt > 0) {
                _wrap(wrapAmt); // deposit ETH to WETH into this contract
                // forward WETH to logical caller
                IERC20Minimal(address(WETH9)).transfer(msgSender(), wrapAmt);
            }
            return;
        }
        if (action == uint256(MMAction.UNWRAP_NATIVE)) {
            // params: (uint256 amount)
            uint256 amount = abi.decode(params, (uint256));
            uint256 wethBal = IERC20Minimal(address(WETH9)).balanceOf(address(this));
            uint256 unwrapAmt = amount > wethBal ? wethBal : amount;
            if (unwrapAmt > 0) {
                _unwrap(unwrapAmt); // withdraw WETH to ETH into this contract
                // forward ETH to logical caller
                CurrencyLibrary.ADDRESS_ZERO.transfer(msgSender(), unwrapAmt);
            }
            return;
        }
        revert("UnsupportedAction");
    }

    // ------------------------------------------------------------------------------------------------
    // Internal helper functions
    // ------------------------------------------------------------------------------------------------

    /**
     * @dev This function is used to modify liquidity for a given pool key and parameters
     * @param poolKey The pool key to modify liquidity for
     * @param params The liquidity parameters to modify liquidity for
     * @return positionId The position id
     * @return requiredSettlementDelta The balance delta of the required settlements
     * @return positionDelta The balance delta of the position caller delta
     * @return feesAccrued The balance delta of the fees accrued
     */
    function _callModifyLiquidity(PoolKey memory poolKey, ModifyLiquidityParams memory params)
        internal
        returns (
            PositionId positionId,
            BalanceDelta requiredSettlementDelta,
            BalanceDelta positionDelta,
            BalanceDelta feesAccrued,
            BalanceDelta feeAdj
        )
    {
        // use param to modify liquidity
        (positionDelta, feesAccrued) = _modifyLiquidity(poolKey, params, Constants.ZERO_BYTES);
        // generate unique position id using the params which contains the salt making this unique across all positions
        positionId = PositionLibrary.generateId(address(this), params);
        // Consume the aggregated required settlement delta from CoreHook (VTSManager) and clear it
        requiredSettlementDelta = TransientSlots.consumePositionRequiredSettlementDelta(address(_getVTSManager()));
        // Consume fee adjustment materialised by CoreHook for this call
        feeAdj = TransientSlots.consumeFeeAdjDelta(address(_getVTSManager()));
    }

    /**
     * @dev Settles the underlying assets for a given position based on protocol-defined settlement rules.
     * Utilizes the provided modifyDelta as an input; the actual settled amounts (settlementDelta) are determined in accordance with protocol rules applied by the VTSManager,
     * which may differ from modifyDelta (e.g., due to clamping or adjustments).
     * The appropriate underlying assets are then transferred or withdrawn, and the proxy hook is notified.
     * In essence, the MM is providing a modifyDelta what default settlements apply.
     * @param poolId The pool id associated with the position
     * @param settlementDelta The balance delta for underlying asset settlement. Either direct via _settle, or position-required via _callModifyLiquidity
     * @param ua0 The address of underlying asset 0
     * @param ua1 The address of underlying asset 1
     */
    function _settleUnderlying(PoolId poolId, BalanceDelta settlementDelta, address ua0, address ua1) internal {
        address sender = msgSender();

        address marketVault = IMarketFactory(marketFactory).corePoolToProxyHook(poolId);

        // for deposits, transfer to the Market Vault (proxy hook)
        if (settlementDelta.amount0() > 0) {
            IERC20Minimal(ua0).transferFrom(
                sender, marketVault, LiquidityUtils.safeInt128ToUint256(settlementDelta.amount0())
            );
        }
        if (settlementDelta.amount1() > 0) {
            IERC20Minimal(ua1).transferFrom(
                sender, marketVault, LiquidityUtils.safeInt128ToUint256(settlementDelta.amount1())
            );
        }
        // notify the proxy hook of the settled underlying tokens
        // a positive balance delta means we are settling underlying tokens to the proxy hook, negative means withdrawing to the MMP.
        // Call after deposits, but before withdrawals.
        IProxyHook(marketVault).onMMLiquidityModify(settlementDelta);

        // for withdrawals, transfer to the caller/sender/MM.
        if (settlementDelta.amount0() < 0) {
            IERC20Minimal(ua0).transfer(sender, LiquidityUtils.safeInt128ToUint256(settlementDelta.amount0()));
        }
        if (settlementDelta.amount1() < 0) {
            IERC20Minimal(ua1).transfer(sender, LiquidityUtils.safeInt128ToUint256(settlementDelta.amount1()));
        }
    }

    // ------------------------------------------------------------------------------------------------
    // MM Position Manager functions
    // ------------------------------------------------------------------------------------------------

    /**
     * @dev This function is used to calculate the RFS for a given token id and position index.
     * @dev Utilised within RFSCheckpointModule.
     * @param tokenId The token id to calculate the RFS for
     * @param positionIndex The position index to calculate the RFS for
     * @param requireClosedRfS Whether to require the RFS to be closed
     * @return positionId The position id
     * @return rfsOpen Whether the RFS is open
     * @return rfsDelta The balance delta of the RFS
     */
    function calcRFS(uint256 tokenId, uint256 positionIndex, bool requireClosedRfS)
        public
        override
        returns (PositionId positionId, bool rfsOpen, BalanceDelta rfsDelta)
    {
        positionId = getPositionId(tokenId, positionIndex);
        (rfsOpen, rfsDelta) = _getVTSManager().calcRFS(positionId, requireClosedRfS);
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

        if (!_isMMPosition(m)) {
            revert InvalidPosition(tokenId, positionIndex, positionId);
        }

        return m;
    }

    // ------------------------
    // Commit-level helpers
    // ------------------------

    /// @dev Resolves the market's oracle factory and LCC pair addresses for a given pool.
    /// @param poolId The core pool identifier for the market the commit is bound to.
    /// @return oracleFactory Address of the oracle factory configured for this market.
    /// @return lcc0 Address of token0's LCC contract for the core pool.
    /// @return lcc1 Address of token1's LCC contract for the core pool.
    function _marketOracleFactoryAndPair(PoolId poolId)
        internal
        view
        returns (address oracleFactory, address lcc0, address lcc1)
    {
        oracleFactory = _getVTSManager().getMarketVTSConfiguration(poolId).oracleFactory;
        address[2] memory pair = IMarketFactory(marketFactory).corePoolToCurrencyPair(poolId);
        lcc0 = pair[0];
        lcc1 = pair[1];
    }

    /// @dev Sums settled raw token amounts across all positions attached to a commit NFT.
    /// @param tokenId The commit NFT id.
    /// @return s0 Total settled token0 across positions.
    /// @return s1 Total settled token1 across positions.
    function _sumSettledAmountsForCommit(uint256 tokenId) internal view returns (uint256 s0, uint256 s1) {
        uint256 n = commitToPositionCount[tokenId];
        IVTSManager vts = _getVTSManager();
        PositionId[] memory pids = new PositionId[](n);
        for (uint256 i = 0; i < n; i++) {
            PositionId pid = getPositionId(tokenId, i);
            pids[i] = pid;
        }
        (s0, s1) = vts.getPositionSettledAmounts(pids);
    }

    /// @dev Re-composes effective LCC amounts across all positions at the current pool price.
    ///      This reflects the live composition of the commitment rather than any historical issuance tallies.
    /// @param tokenId The commit NFT id.
    /// @return e0 Effective token0 backing amount implied by current price and position params.
    /// @return e1 Effective token1 backing amount implied by current price and position params.
    function _effectiveIssuedAmountsForCommit(uint256 tokenId) internal view returns (uint256 e0, uint256 e1) {
        PoolId poolId = commitOf[tokenId].poolId;
        (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(poolId);
        uint256 n = commitToPositionCount[tokenId];
        for (uint256 i = 0; i < n; i++) {
            PositionMeta memory m = getPosition(tokenId, i);
            (uint256 a0, uint256 a1) = LiquidityUtils.calculateEffectiveTokenAmounts(
                sqrtPriceX96, currentTick, m.tickLower, m.tickUpper, m.liquidity
            );
            e0 += a0;
            e1 += a1;
        }
    }

    /// @dev Values a pair of LCC amounts using USD prices from the market oracle factory.
    ///      Uses FullMath.mulDiv to prevent overflow and ensure deterministic flooring.
    /// @param lcc0 Address of token0 LCC.
    /// @param a0 Amount of token0 LCC (raw units).
    /// @param lcc1 Address of token1 LCC.
    /// @param a1 Amount of token1 LCC (raw units).
    /// @param oracleFactory Oracle factory address to query prices from.
    /// @return Total USD value of the two amounts (normalised by oracle decimals).
    function _usdValueLccPair(address lcc0, uint256 a0, address lcc1, uint256 a1, address oracleFactory)
        internal
        view
        returns (uint256)
    {
        (uint256 p0, uint256 d0) = ILCC(lcc0).usdPrice(oracleFactory);
        (uint256 p1, uint256 d1) = ILCC(lcc1).usdPrice(oracleFactory);
        uint256 v0 = a0 == 0 ? 0 : FullMath.mulDiv(p0, a0, 10 ** d0);
        uint256 v1 = a1 == 0 ? 0 : FullMath.mulDiv(p1, a1, 10 ** d1);
        return v0 + v1;
    }

    /// @dev Values the currently stored signal reserves in USD via the signal manager.
    ///      This does not mutate the signal nonce; it is a pure view against the stored state.
    /// @param tokenId The commit NFT id.
    /// @return USD value of the stored signal reserves.
    function _currentSignalUsdValue(uint256 tokenId) internal view returns (uint256) {
        (string[] memory tickers, uint256[] memory amounts) = commitOf[tokenId].state.signal.mmState.getReserves();
        return signalManager.getTotalUsdValue(tickers, amounts);
    }

    /// @dev Verifies a new signal (nonce bump) and returns its USD value.
    ///      Reverts if invalid; used for renew paths to gate solvency with the new state.
    /// @param liquiditySignal ABI-encoded LiquiditySignal.
    /// @return USD value of the new signal reserves.
    function _verifiedSignalUsdValue(bytes memory liquiditySignal) internal returns (uint256) {
        // Will revert if invalid; also bumps the nonce when valid
        LiquiditySignal memory sig = abi.decode(liquiditySignal, (LiquiditySignal));
        (bool isSignalValid,) = signalManager.verifyLiquiditySignal(sig);
        if (!isSignalValid) {
            revert InvalidLiquiditySignal(0, 0);
        }
        (string[] memory tickers, uint256[] memory amounts) = sig.mmState.getReserves();
        return signalManager.getTotalUsdValue(tickers, amounts);
    }

    /// @dev Asserts commit solvency against the currently stored signal.
    ///      Effective LCC (including any prospective issuance passed in) must be ≤ signal USD + settled USD.
    /// @param tokenId The commit NFT id.
    /// @param extraIssue0 Prospective token0 LCC to add to effective amounts (e.g., for a new mint).
    /// @param extraIssue1 Prospective token1 LCC to add to effective amounts (e.g., for a new mint).
    function _assertCommitmentSolventStored(uint256 tokenId, uint256 extraIssue0, uint256 extraIssue1) internal view {
        PoolId poolId = commitOf[tokenId].poolId;
        (address oracleFactory, address l0, address l1) = _marketOracleFactoryAndPair(poolId);

        (uint256 e0, uint256 e1) = _effectiveIssuedAmountsForCommit(tokenId);
        uint256 issuedUsd = _usdValueLccPair(l0, e0 + extraIssue0, l1, e1 + extraIssue1, oracleFactory);

        (uint256 s0, uint256 s1) = _sumSettledAmountsForCommit(tokenId);
        uint256 settledUsd = _usdValueLccPair(l0, s0, l1, s1, oracleFactory);

        uint256 signalUsd = _currentSignalUsdValue(tokenId);

        // Invariant: issued ≤ signal + settled (prevents over-issuance relative to backing)
        if (issuedUsd > signalUsd + settledUsd) {
            revert InvalidLiquiditySignal(signalUsd + settledUsd, issuedUsd);
        }
    }

    /// @dev Asserts commit solvency against a newly supplied signal.
    ///      Verifies the signal (nonce bump), then checks effective LCC ≤ signal USD + settled USD.
    /// @param tokenId The commit NFT id.
    /// @param liquiditySignal ABI-encoded LiquiditySignal (new state).
    function _assertCommitmentSolventWithNewSignal(uint256 tokenId, bytes memory liquiditySignal) internal {
        PoolId poolId = commitOf[tokenId].poolId;
        (address oracleFactory, address l0, address l1) = _marketOracleFactoryAndPair(poolId);

        (uint256 e0, uint256 e1) = _effectiveIssuedAmountsForCommit(tokenId);
        uint256 issuedUsd = _usdValueLccPair(l0, e0, l1, e1, oracleFactory);

        (uint256 s0, uint256 s1) = _sumSettledAmountsForCommit(tokenId);
        uint256 settledUsd = _usdValueLccPair(l0, s0, l1, s1, oracleFactory);

        uint256 signalUsd = _verifiedSignalUsdValue(liquiditySignal);

        // Invariant: issued ≤ signal + settled (post-verify renew path)
        if (issuedUsd > signalUsd + settledUsd) {
            revert InvalidLiquiditySignal(signalUsd + settledUsd, issuedUsd);
        }
    }

    // ------------------------------------------------------------------------------------------------
    // Actions handlers
    // ------------------------------------------------------------------------------------------------

    /**
     * @dev This function is used to settle underlying assets to/from the position
     * @param poolKey The pool key for the position - adheres to Uniswap standards where poolKey provided as a param.
     * @param tokenId The token id to settle the position for
     * @param positionIndex The position index to settle the position for
     * @param amount0 The amount of token0 to settle. Positive amounts result in deposits, negative amounts result in withdrawals.
     * @param amount1 The amount of token1 to settle. Positive amounts result in deposits, negative amounts result in withdrawals.
     */
    function _settle(PoolKey memory poolKey, uint256 tokenId, uint256 positionIndex, int128 amount0, int128 amount1)
        internal
        onlyIfApproved(msgSender(), tokenId)
        onlyValidCommit(poolKey, tokenId)
    {
        getPosition(tokenId, positionIndex); // Validate the position by fetching it.

        if (amount0 == 0 && amount1 == 0) {
            // Cannot settle 0 amounts for both assets.
            revert InvalidDelta(0, 0);
        }

        PositionId positionId = getPositionId(tokenId, positionIndex);

        // notify the vts manager of the settlement made for this position
        // returns the delta of required settlements IN or OUT
        (BalanceDelta settlementDelta, bool rfsOpen) = _getVTSManager().onMMSettle(
            positionId, poolKey.currency0, poolKey.currency1, toBalanceDelta(amount0, amount1)
        );

        // mark RFS checkpoint
        _markCheckpoint(positionId, rfsOpen); // checkpoint directly on the _settleUnderlying call.

        // settle the underlying assets to the proxy hook
        _settleUnderlying(
            commitOf[tokenId].poolId,
            settlementDelta,
            ILCC(Currency.unwrap(poolKey.currency0)).underlyingAsset(),
            ILCC(Currency.unwrap(poolKey.currency1)).underlyingAsset()
        );
    }

    /**
     * @dev This function is used to decommit a position for a given token id
     * @param poolKey The pool key for the position
     * @param tokenId The token id to decommit the position for
     */
    function _decommitSignal(PoolKey memory poolKey, uint256 tokenId)
        internal
        onlyIfApproved(msgSender(), tokenId)
        onlyValidCommit(poolKey, tokenId)
    {
        uint256 totalS0 = 0;
        uint256 totalS1 = 0;

        // get all positions attached to this token id
        uint256 positionCount = commitToPositionCount[tokenId];
        for (uint256 i = 0; i < positionCount; i++) {
            PositionMeta memory position = getPosition(tokenId, i);
            if (position.isActive) {
                BalanceDelta balanceDelta = _burnPosition(poolKey, tokenId, i);
                totalS0 += LiquidityUtils.safeInt128ToUint256(balanceDelta.amount0());
                totalS1 += LiquidityUtils.safeInt128ToUint256(balanceDelta.amount1());
            }
        }

        // burn the nft after removing all of the liquidity
        _burn(tokenId);

        emit SignalDecommitted(tokenId, positionCount, totalS0, totalS1);
    }

    /**
     * @dev This function is used to decommit a position for a given position id
     * @param poolKey The pool key for the position
     * @param tokenId The token id to decommit the position for
     * @param positionIndex The position index to decommit the position for
     * @return balanceDelta The balance delta
     */
    function _burnPosition(PoolKey memory poolKey, uint256 tokenId, uint256 positionIndex)
        internal
        returns (BalanceDelta)
    {
        PositionMeta memory pos = getPosition(tokenId, positionIndex);
        uint256 completeLiquidity = uint256(pos.liquidity);
        BalanceDelta ret = _decrease(poolKey, pos, _positionSalt(tokenId, positionIndex), completeLiquidity, true);
        return ret;
    }

    /**
     * @dev This function is used to increase the liquidity of a position
     * @param poolKey The pool key for the position
     * @param tokenId The token id to increase the liquidity for
     * @param positionIndex The position index to increase the liquidity for
     * @param liquidity The amount of liquidity to increase
     */
    function _increase(
        PoolKey memory poolKey,
        uint256 tokenId,
        uint256 positionIndex,
        int24 tickUpper,
        int24 tickLower,
        uint256 liquidity
    ) internal onlyIfApproved(msgSender(), tokenId) onlyValidCommit(poolKey, tokenId) returns (PositionId positionId) {
        if (liquidity == 0) {
            revert InvalidDelta(0, 0);
        }

        // mint the tokens required to facilitate this liquidity addition
        (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(poolKey.toId());
        (uint256 lcc0AmountToMint, uint256 lcc1AmountToMint) = LiquidityUtils.calculateEffectiveTokenAmounts(
            sqrtPriceX96, currentTick, tickLower, tickUpper, liquidity.toInt256()
        );

        // Solvency gate: effective LCC (including prospective) <= signal + settled
        _assertCommitmentSolventStored(tokenId, lcc0AmountToMint, lcc1AmountToMint);

        ILCC lcc0 = ILCC(Currency.unwrap(poolKey.currency0));
        ILCC lcc1 = ILCC(Currency.unwrap(poolKey.currency1));
        address ua0 = lcc0.underlyingAsset();
        address ua1 = lcc1.underlyingAsset();

        lcc0.issue(lcc0AmountToMint);
        lcc1.issue(lcc1AmountToMint);

        // mint or modify liquidity. If the position is not minted, this will mint it. If the position is already minted, this will modify it.
        (PositionId pId, BalanceDelta requiredSettlementDelta,,,) = _callModifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: liquidity.toInt256(),
                salt: _positionSalt(tokenId, positionIndex)
            })
        );

        positionId = pId;

        // settle the underlying tokens to the proxy hook
        _settleUnderlying(poolKey.toId(), requiredSettlementDelta, ua0, ua1);
    }

    /**
     * @dev This function is used to liquidate a position for a given token id and position index
     *      it removes the underlying liquidity from the position to the caller firstly
     *      then it removes the liquidity from the position and burns the tokens
     * @param poolKey The pool key for the position
     * @param position The position to liquidate
     * @param salt The salt of the position
     * @param amountToLiquidate The amount of liquidity to liquidate
     * @param byApprovedOrOwner Whether the caller is the approved or owner of the Commit (therefore, the position)
     * @return returnDelta The balance delta of excess (above new lower commitmentMaxima) settlement returned.
     * @dev make sure to settle the underlying assets before calling this function
     *      because this function could potentially mark the position as inactive
     *      and if the position is inactive, then the call to modify the underlying assets will fail
     */
    /// @dev Decrease position liquidity by amountToDecrease and settle underlying changes.
    ///      Mirrors native PositionManager _decrease semantics (first modify, then settle flows).
    ///      Returns the balance delta of excess (above new lower commitmentMaxima) settlement returned.
    /// @dev Passing liqudity delta 0 will still surface feesAccrued, and therefore transfer (fee sweep) functionality.
    function _decrease(
        PoolKey memory poolKey,
        PositionMeta memory position,
        bytes32 salt,
        uint256 amountToDecrease,
        bool byApprovedOrOwner
    ) internal returns (BalanceDelta returnDelta) {
        // validate liquidity is not over available
        if (uint256(position.liquidity) < amountToDecrease) {
            revert InvalidAmount(amountToDecrease, uint256(position.liquidity));
        }

        // remove the liquidity from the pool
        // By calling this, CoreHook afterRemoveLiquidity will be called to deactivate the position.
        (
            ,
            BalanceDelta requiredSettlementDelta,
            BalanceDelta positionDelta,
            BalanceDelta feesAccrued,
            BalanceDelta feeAdj
        ) = _callModifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: position.tickLower,
                tickUpper: position.tickUpper,
                liquidityDelta: -int256(amountToDecrease),
                salt: salt
            })
        );

        ILCC lcc0 = ILCC(Currency.unwrap(poolKey.currency0));
        ILCC lcc1 = ILCC(Currency.unwrap(poolKey.currency1));

        address ua0 = lcc0.underlyingAsset();
        address ua1 = lcc1.underlyingAsset();

        // TODO: On Seizure, this amount should be the seizureSettled + (portion of position settled relative to seizuredLiquidityUnits/liquidity)
        // ----- LCCs acquired by the seizing party are NOT cancelled, rather transferred for unwrap, or subsequent swaps. VTSManager.onMMLiquidityModify coordinates position settlement amounts, whereas Market Vault aggregates them and coordinates LCC queue clearance.

        // pass zero delta because caller is not explicitly settling anything IN or OUT. However, settlements may occur as a reaction to position modification.
        // reference: solidity/src/modules/VTSManager.sol _touchPosition
        _settleUnderlying(poolKey.toId(), requiredSettlementDelta, ua0, ua1);
        returnDelta = requiredSettlementDelta;

        // ? ----- During seizeCommitment, issued LCCs must remained solvent. RfS positions must be closed across the commitment. Identifying insolvency essentially enables seizure with a skip on gracePeriod validation.
        // // ? ----- ----- Despite the signal value no longer matching LCC value, the open RfS + settled liquidity expresses utilised liquidity.
        // // ? ----- ----- Rather than apportioning the commitment, the entire commitment should be seized.
        // ? ----- ----- As per the second point under decommit, LCCs issued during position management rather than for entire commitment reduces the solvency requirement before seizeCommitment and decommit.
        // ? ----- ----- Assuming that the full commitment is utilised in positions, then 80% of the commitment is insolvent, what occurs?
        // ? ----- ----- What if proving insolvency results in unlocking seizure across positions in an intra-transaction process - raising the a position specific-deficit by the diff in signal -> commit values, and skipping the gracePeriod validation for X amount.
        // ? ----- ----- This could allow re-use of position seizure, and for all MMs/Guarantors to paritipate on the seizure. The advancer can be given a share of the seized outcome.
        // ? ----- ----- If we adopt an action-dispatcher model as per the Native PositionManager, then MM's can chain actions together, ie. insolvent (prove insolvency), seize position, mint position, etc.

        // Distinguish raw position deltas (a0/a1) from feesAccrued, then derive principal (after deducting fees).
        // a0/a1 are the gross amounts returned by the PoolManager for position modification.
        // principal0/principal1 = a{0,1} - fees{0,1} (clamped at zero) reflect the true principal liquidity change
        // that maps to LCC cancellation. fees are trader-derived, wrapped LCC value and must remain wrapped.
        uint256 a0 = LiquidityUtils.safeInt128ToUint256(positionDelta.amount0());
        uint256 a1 = LiquidityUtils.safeInt128ToUint256(positionDelta.amount1());
        // CoreHook applies a feeAdj to the callerDelta. ie.  callerDelta = principalDelta - feesAccrued - feeAdj.
        // Treat feeAdj as part of fees for cancel/transfer purposes.
        uint256 fees0 = LiquidityUtils.safeInt128ToUint256(feesAccrued.amount0());
        uint256 fees1 = LiquidityUtils.safeInt128ToUint256(feesAccrued.amount1());
        uint256 adj0 = LiquidityUtils.safeInt128ToUint256(feeAdj.amount0());
        uint256 adj1 = LiquidityUtils.safeInt128ToUint256(feeAdj.amount1());
        // feesEffective = max(0, feesAccrued - feeAdj)
        uint256 feesEff0 = fees0 > adj0 ? (fees0 - adj0) : 0;
        uint256 feesEff1 = fees1 > adj1 ? (fees1 - adj1) : 0;
        // principal = max(0, a - feesEffective)
        uint256 principal0 = a0 > feesEff0 ? (a0 - feesEff0) : 0;
        uint256 principal1 = a1 > feesEff1 ? (a1 - feesEff1) : 0;
        bytes32 marketId = PoolId.unwrap(poolKey.toId());
        if (byApprovedOrOwner) {
            // Burn only principal LCC that was originally issued for the position's liquidity.
            // feesAccrued (from trader flows) stays wrapped and can be unwrapped via UNWRAP_LCC.
            if (principal0 > 0) {
                lcc0.cancel(principal0);
            }
            if (principal1 > 0) {
                lcc1.cancel(principal1);
            }
            // Transfer residual LCC fees (wrapped via trader flows) to the logical caller.
            // These fees are not principal-issued LCC and must not be cancelled; the MM may later unwrap them explicitly.
            if (fees0 > 0) {
                lcc0.traceTransfer(msgSender(), marketId, fees0);
            }
            if (fees1 > 0) {
                lcc1.traceTransfer(msgSender(), marketId, fees1);
            }
        } else {
            // If we get here, then the position is being seized by a non-approved or owner.
            // Therefore, we transfer instead of cancel.
            if (a0 > 0) {
                lcc0.traceTransfer(msgSender(), marketId, a0);
            }
            if (a1 > 0) {
                lcc1.traceTransfer(msgSender(), marketId, a1);
            }
        }
    }

    /**
     * @dev This function is used to renew a liquidity signal for a given token id
     * @param tokenId The token id to renew the liquidity signal for
     * @param liquiditySignal The liquidity signal to renew the liquidity signal for
     */
    function _renew(uint256 tokenId, bytes memory liquiditySignal) internal onlyIfApproved(msgSender(), tokenId) {
        if (liquiditySignal.length == 0) {
            revert InvalidLiquiditySignal(0, 0);
        }

        // Assert solvency against the new signal
        _assertCommitmentSolventWithNewSignal(tokenId, liquiditySignal);

        // Verify new signal (nonce bump) and persist without extra pricing
        (, uint256 expirySeconds) = signalManager.verifyLiquiditySignal(liquiditySignal, true);
        LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
        commitOf[tokenId].state = SignalState({signal: signal, expiresAt: block.timestamp + expirySeconds});
    }

    /**
     * @dev This function commits a liquidity signal and mints a commitment NFT.
     * @param poolKey The pool key the commitment binds to.
     * @param liquiditySignal The ABI-encoded LiquiditySignal to verify and record.
     * @return tokenId The commitment NFT id created.
     */
    function _commitSignal(PoolKey memory poolKey, bytes memory liquiditySignal) internal returns (uint256 tokenId) {
        if (liquiditySignal.length == 0) {
            revert InvalidLiquiditySignal(0, 0);
        }

        LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
        // verify the proofs associated with the state
        (bool isSignalValid, uint256 expirySeconds) = signalManager.verifyLiquiditySignal(signal);
        // if the proof is invalid, revert
        if (!isSignalValid) {
            revert InvalidLiquiditySignal(0, 0);
        }

        // ? -- Mint the Commitment NFT
        address to = msgSender();
        // get the token id
        tokenId = nextTokenId++;
        // mint the nft
        _mint(to, tokenId);
        // store the signal state (new + legacy for migration) and bind commit to pool
        commitOf[tokenId].state = SignalState({signal: signal, expiresAt: block.timestamp + expirySeconds});
        commitOf[tokenId].poolId = poolKey.toId();

        emit SignalCommitted(tokenId);
    }

    /**
     * @dev This function is used to mint a new position for a given token id
     * @param poolKey The pool key to mint the position for
     * @param tokenId The token id to mint the position for
     * @param tickLower The lower tick of the position
     * @param tickUpper The upper tick of the position
     * @param liquidity The liquidity amount to mint
     */
    function _mintPosition(PoolKey memory poolKey, uint256 tokenId, int24 tickLower, int24 tickUpper, uint256 liquidity)
        internal
        returns (PositionId positionId, uint256 positionIndex)
    {
        // add liquidity to the pool using the token id and position index to generate a unique salt
        positionIndex = commitToPositionCount[tokenId];

        positionId = _increase(poolKey, tokenId, positionIndex, tickLower, tickUpper, liquidity);

        // Attach position to this nft
        // make sure to add the position only after modifying the liquidity
        // because the number of positions is used to generate the salt for the position
        commitToPosition[tokenId][positionIndex] = positionId;
        // Position metadata is managed centrally via PositionIndex/VTSManager
        // increment the number of positions for the nft
        commitToPositionCount[tokenId]++;
    }

    /**
     * @dev Seizure of a position by a guarantor (other MM)
     * @param poolKey The pool key for the position
     * @param tokenId The token id to settle the position for
     * @param positionIndex The position index to settle the position for
     * @param amount0 The amount of token0 to settle
     * @param amount1 The amount of token1 to settle
     */
    function _seizePosition(
        PoolKey memory poolKey,
        uint256 tokenId,
        uint256 positionIndex,
        uint256 amount0,
        uint256 amount1
    ) internal returns (BalanceDelta seizedPositionDelta) {
        // -- Validate the poolKey
        _assertCommitForPool(poolKey, tokenId);

        // require at least one side is settled
        if (amount0 == 0 && amount1 == 0) {
            revert InvalidDelta(0, 0);
        }

        PositionMeta memory position = getPosition(tokenId, positionIndex);
        PositionId positionId = getPositionId(tokenId, positionIndex);

        // -- Validate that caller is not position owner
        // use _isApprovedOrOwner to get the owner/approved wallets of the token id, as position.owner is address(this).
        // Technically, seizing your own position cannot be stopped (via proxy wallets), but there should be no incentive.
        if (_isApprovedOrOwner(msgSender(), tokenId) || position.isActive == false) {
            revert InvalidPosition(tokenId, positionIndex, positionId);
        }

        // create a balance delta of the amounts to settle
        BalanceDelta settlementDelta = toBalanceDelta(amount0.toInt128(), amount1.toInt128());

        IVTSManager vtsManager = _getVTSManager();

        // Validate grace (using last checkpoint) and derive liquidity to seize
        uint256 seizedLiquidityUnits =
            vtsManager.calcSeizure(positionId, settlementDelta, positionToCheckpoint[positionId]);

        // ? settlement is necessary because the seizing party is covering the deficit (settlement queue) in exchange for LCCs.
        // calcSeizure will internally manage the required settlement delta.
        // _settle();
        // TODO: What if we do a _seize, _settle - where if failure to settle, then revert. This could ensure _settle occurs to a new position owned by the seizing party, intra-transaction.
        require(false == true, "TODO: Seize Position needs an independent refactor.");

        // -- Move the underlying liquidity to the to the seizer/caller or to the new position

        // -- Liquidate the position partially or fully
        // do this last because it could potentially mark the position as inactive and cause some of the above calls to fail as they require an active position
        // Mirror liquidate by decreasing liquidity by seized units and letting settle logic handle deltas
        return _decrease(poolKey, position, _positionSalt(tokenId, positionIndex), seizedLiquidityUnits, false);
    }

    /**
     * @dev Sieze a portion of an insolvent commitment
     * @param poolKey The pool key to sieze the commitment for
     * @param tokenId The token id to sieze the commitment for
     * @param liquiditySignal The liquidity signal to sieze the commitment for
     */
    // TODO: Ensure seizeCommitment maths is correct.
    function _seizeCommitment(PoolKey memory poolKey, uint256 tokenId, bytes memory liquiditySignal)
        internal
        view
        returns (uint256 deficitFractionInBips)
    {
        _assertCommitForPool(poolKey, tokenId);

        // // verify the new liquidity signal(this increases the nonce of the mm's signals)
        // // get the total usd value of the signal and its expiry time
        // (uint256 totalSignalUsdValue, uint256 signalExpiryInSeconds) =
        //     signalManager.verifyLiquiditySignal(liquiditySignal, true);
        // // get the total unsettled value of the position
        // // replaced by effective recomposition solvency; keep legacy math for seizeCommitment path
        // uint256 positionTotalCommitmentsUSDValue = 0;
        // {
        //     PoolId poolId = commitOf[tokenId].poolId;
        //     (address oracleFactory, address l0, address l1) = _marketOracleFactoryAndPair(poolId);
        //     (uint256 e0, uint256 e1) = _effectiveIssuedAmountsForCommit(tokenId);
        //     (uint256 s0, uint256 s1) = _sumSettledAmountsForCommit(tokenId);
        //     uint256 issuedUsd = _usdValueLccPair(l0, e0, l1, e1, oracleFactory);
        //     uint256 settledUsd = _usdValueLccPair(l0, s0, l1, s1, oracleFactory);
        //     // Effective commitments = issuedUsd; legacy path used this as “position value”
        //     positionTotalCommitmentsUSDValue = issuedUsd > settledUsd ? (issuedUsd - settledUsd) : 0;
        // }
        // // make sure the new signal is insolvent before it can be reallocated
        // if (totalSignalUsdValue >= positionTotalCommitmentsUSDValue) {
        //     revert InvalidLiquiditySignal(totalSignalUsdValue, positionTotalCommitmentsUSDValue);
        // }
        // LiquiditySignal memory newSignal = abi.decode(liquiditySignal, (LiquiditySignal));
        // LiquiditySignal memory oldSignal = commitOf[tokenId].state.signal;
        // // validate that new signal belongs to the same mm as the old signal
        // // require caller is advancer, and ensures that the advancer is not the owner of the signal.
        // if (
        //     newSignal.mmState.owner != oldSignal.mmState.owner && msgSender() != newSignal.mmState.advancer
        //         && newSignal.mmState.advancer == newSignal.mmState.owner
        // ) {
        //     revert UnauthorizedSignalOwner();
        // }
        // SignalState memory s = SignalState({signal: newSignal, expiresAt: block.timestamp + signalExpiryInSeconds});
        // commitOf[tokenId].state = s;

        // // get the difference in the usd value of the signal and the position
        // // get the fraction of the deficit of the position, unit is in wad(1e18) for better precision
        // deficitFractionInBips = FullMath.mulDiv(
        //     positionTotalCommitmentsUSDValue - totalSignalUsdValue,
        //     LiquidityUtils.ONE_BIP,
        //     positionTotalCommitmentsUSDValue
        // );

        // // iterate through all the positions using the position index, then liquidate a percentage given by the deficit fraction
        // uint256 positionCount = commitToPositionCount[tokenId];
        // for (uint256 i = 0; i < positionCount; i++) {
        //     PositionMeta memory position = getPosition(tokenId, i);
        //     // liquidate a percentage given by the deficit fraction
        //     uint256 liquidityToSeize =
        //         FullMath.mulDiv(uint256(position.liquidity), deficitFractionInBips, LiquidityUtils.ONE_BIP);
        //     _decrease(poolKey, position, _positionSalt(tokenId, i), liquidityToSeize, false);
        // }
    }

    /// @dev overrides solmate transferFrom to revert if pool manager is locked
    /// @dev mirrors PositionManager and prevents transfers while an unlock session is active (mid-batch), avoiding inconsistent state/reentrancy around router-locked flows.
    function transferFrom(address from, address to, uint256 id) public virtual override onlyIfPoolManagerLocked {
        super.transferFrom(from, to, id);
    }
}
