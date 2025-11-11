// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {LiquidityRouter} from "./modules/LiquidityRouter.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "v4-periphery/lib/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta, BalanceDeltaLibrary} from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {PoolId} from "v4-periphery/lib/v4-core/src/types/PoolId.sol";
import {ERC721Permit_v4} from "v4-periphery/src/base/ERC721Permit_v4.sol";
import {ReentrancyLock} from "v4-periphery/src/base/ReentrancyLock.sol";
import {Multicall_v4} from "v4-periphery/src/base/Multicall_v4.sol";
import {BaseActionsRouter} from "v4-periphery/src/base/BaseActionsRouter.sol";
import {PositionMeta, PositionId, PositionLibrary} from "./types/Position.sol";
import {LiquiditySignal, SignalState} from "./types/Position.sol";
import {MarketMaker} from "./libraries/MarketMaker.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IVTSManager} from "./interfaces/IVTSManager.sol";
import {MarketVTSConfiguration} from "./types/VTS.sol";
import {LiquidityUtils} from "./libraries/LiquidityUtils.sol";
import {CurrencyTransfer} from "./libraries/CurrencyTransfer.sol";
import {ILCC} from "./interfaces/ILCC.sol";
import {IVRLSignalManager} from "./interfaces/IVRLSignalManager.sol";
import {IOracleHelper} from "./interfaces/IOracleHelper.sol";
import {SafeCast} from "v4-periphery/lib/v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
import {RFSCheckpointModule} from "./modules/RFSCheckpoint.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {TransientSlots} from "./libraries/TransientSlots.sol";

import {ICommitmentDescriptor} from "./interfaces/ICommitmentDescriptor.sol";
import {ILiquidityHub} from "./interfaces/ILiquidityHub.sol";
import {IMMPositionManager} from "./interfaces/IMMPositionManager.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Errors} from "./libraries/Errors.sol";
import {NonzeroDeltaCount} from "@uniswap/v4-core/src/libraries/NonzeroDeltaCount.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

contract MMPositionManager is
    LiquidityRouter,
    ERC721Permit_v4,
    RFSCheckpointModule,
    IMMPositionManager,
    ReentrancyLock,
    Multicall_v4,
    BaseActionsRouter
{
    using SafeCast for uint256;
    using PositionLibrary for PositionId;
    using MarketMaker for MarketMaker.State;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;

    event SignalCommitted(uint256 tokenId);
    event SignalDecommitted(uint256 tokenId, uint256 positionCount);

    ILiquidityHub internal immutable liquidityHub;
    IVTSManager internal immutable vtsManager;
    IVRLSignalManager internal immutable signalManager;
    IOracleHelper internal immutable oracleHelper;

    uint256 private nextTokenId = 1;

    address public immutable commitmentDescriptor;
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
        UNWRAP_LCC, // params: (address lcc, uint256 amount, address recipient, bool payerIsUser)
        WRAP_NATIVE, // params: (uint256 amount)
        UNWRAP_NATIVE, // params: (uint256 amount)
        EXTEND_GRACE_PERIOD, // params: (PoolKey, uint256 tokenId, uint256 positionIndex, uint8 settlementTokenIndex, uint32 verifierIndex, bytes settlementProof)
        TAKE_LCC, // params: (Currency currency, address recipient, uint256 maxAmount, bool payerIsUser)
        INCREASE_LIQUIDITY_FROM_DELTAS, // params: (Currency currency, int128 delta, address target)
        MINT_POSITION_FROM_DELTAS, // params: (Currency currency, int128 delta, address target)
        SETTLE_POSITION_FROM_DELTAS // params: (PoolKey memory poolKey, uint256 tokenId, uint256 positionIndex, bool settleIn0, bool settleIn1)
    }

    // MarketHandler must be first.
    constructor(
        address _manager,
        address _signalManager,
        address _marketFactory,
        address _settlementObserver,
        address _descriptor,
        IWETH9 _weth9
    )
        ERC721Permit_v4("Fiet VRL Commitment Positions Manager", "FIET-VRL-MMP")
        LiquidityRouter(_marketFactory, _weth9)
        BaseActionsRouter(IPoolManager(_manager))
        RFSCheckpointModule(_settlementObserver)
    {
        signalManager = IVRLSignalManager(_signalManager);
        commitmentDescriptor = _descriptor;
        vtsManager = IVTSManager(marketFactory.coreHook());
        oracleHelper = marketFactory.oracleHelper();
        liquidityHub = marketFactory.liquidityHub();
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
        if (poolManager.isUnlocked()) revert Errors.PoolManagerMustBeLocked();
        _;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        if (commitmentDescriptor == address(0)) {
            revert Errors.CommitmentDescriptorNotSet();
        }
        return ICommitmentDescriptor(commitmentDescriptor).tokenURI(address(this), tokenId);
    }

    function getPositionId(uint256 tokenId, uint256 positionIndex)
        public
        view
        override(IMMPositionManager, RFSCheckpointModule)
        returns (PositionId)
    {
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
        if (!_isApprovedOrOwner(caller, tokenId)) revert Errors.NotApproved(caller);
    }

    function _assertSignalValid(uint256 tokenId) internal view {
        if (commitOf[tokenId].state.expiresAt < block.timestamp) {
            revert Errors.SignalExpired(tokenId);
        }
    }

    function _assertCommitForPool(PoolKey memory poolKey, uint256 tokenId) internal view {
        if (PoolId.unwrap(commitOf[tokenId].poolId) != PoolId.unwrap(poolKey.toId())) {
            revert Errors.InvalidMarket(poolKey);
        }
    }

    /// @inheritdoc BaseActionsRouter
    function msgSender() public view override returns (address) {
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
        if (block.timestamp > deadline) revert Errors.DeadlinePassed(deadline);
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
        _handleNativeValue(msgSender());

        _executeActionsWithoutUnlock(actions, params);

        if (NonzeroDeltaCount.read() > 0) {
            revert Errors.CurrencyNotSettled();
        }
        TransientSlots.clearSeizedPosition();
    }

    function _handleAction(uint256 action, bytes calldata params) internal override {
        if (action == uint256(MMAction.COMMIT_SIGNAL)) {
            (PoolKey memory poolKey, bytes memory liquiditySignal, address owner) =
                abi.decode(params, (PoolKey, bytes, address));
            _commitSignal(poolKey, liquiditySignal, _mapRecipient(owner));
            return;
        }
        if (action == uint256(MMAction.MINT_POSITION)) {
            (PoolKey memory poolKey, uint256 tokenId, int24 tickLower, int24 tickUpper, uint256 liquidity) =
                abi.decode(params, (PoolKey, uint256, int24, int24, uint256));
            _assertSignalValid(tokenId);
            _assertCommitForPool(poolKey, tokenId);
            _assertApprovedOrOwner(msgSender(), tokenId);
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
                int24 tickLower,
                int24 tickUpper,
                uint256 liquidity
            ) = abi.decode(params, (PoolKey, uint256, uint256, int24, int24, uint256));
            _increase(poolKey, tokenId, positionIndex, tickLower, tickUpper, liquidity);
            return;
        }
        if (action == uint256(MMAction.DECREASE_LIQUIDITY)) {
            (PoolKey memory poolKey, uint256 tokenId, uint256 positionIndex, uint256 amountToDecrease) =
                abi.decode(params, (PoolKey, uint256, uint256, uint256));
            _decrease(poolKey, tokenId, positionIndex, amountToDecrease);
            return;
        }
        if (action == uint256(MMAction.BURN_POSITION)) {
            (PoolKey memory poolKey, uint256 tokenId, uint256 positionIndex) =
                abi.decode(params, (PoolKey, uint256, uint256));
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
            // params: (address lcc, uint256 amount, address recipient)
            (address lccAddr, uint256 amount, address recipient, bool payerIsUser) =
                abi.decode(params, (address, uint256, address, bool));
            // Pair-agnostic: accept any LCC address. Governance/guards can be added if needed.
            // Unwrap best-effort to recipient; non-reverting, clamps to available manager-held LCC.
            _unwrapLCC(lccAddr, _mapPayer(payerIsUser), _mapRecipient(recipient), amount);
            return;
        }
        if (action == uint256(MMAction.WRAP_NATIVE)) {
            // params: (uint256 amount)
            uint256 amount = abi.decode(params, (uint256));
            _wrapNative(msgSender(), amount);
            return;
        }
        if (action == uint256(MMAction.UNWRAP_NATIVE)) {
            // params: (uint256 amount)
            uint256 amount = abi.decode(params, (uint256));
            _unwrapNative(msgSender(), amount);
            return;
        }
        if (action == uint256(MMAction.EXTEND_GRACE_PERIOD)) {
            (
                PoolKey memory poolKey,
                uint256 tokenId,
                uint256 positionIndex,
                uint8 settlementTokenIndex,
                uint32 verifierIndex,
                bytes memory settlementProof
            ) = abi.decode(params, (PoolKey, uint256, uint256, uint8, uint32, bytes));
            _extendGracePeriod(poolKey, tokenId, positionIndex, settlementTokenIndex, verifierIndex, settlementProof);
            return;
        }
        if (action == uint256(MMAction.TAKE_LCC)) {
            // params: (Currency currency, address recipient, uint256 maxAmount, bool payerIsUser)
            (Currency currency, address recipient, uint256 maxAmount, bool payerIsUser) =
                abi.decode(params, (Currency, address, uint256, bool));
            _take(currency, _mapPayer(payerIsUser), _mapRecipient(recipient), maxAmount);
            return;
        }
        if (action == uint256(MMAction.INCREASE_LIQUIDITY_FROM_DELTAS)) {
            (PoolKey memory poolKey, uint256 tokenId, uint256 positionIndex, int24 tickLower, int24 tickUpper) =
                abi.decode(params, (PoolKey, uint256, uint256, int24, int24));
            _increaseFromDeltas(poolKey, tokenId, positionIndex, tickLower, tickUpper);
            return;
        }
        if (action == uint256(MMAction.MINT_POSITION_FROM_DELTAS)) {
            (PoolKey memory poolKey, uint256 tokenId, int24 tickLower, int24 tickUpper) =
                abi.decode(params, (PoolKey, uint256, int24, int24));
            _mintFromDeltas(poolKey, tokenId, tickLower, tickUpper);
            return;
        }
        if (action == uint256(MMAction.SETTLE_POSITION_FROM_DELTAS)) {
            (PoolKey memory poolKey, uint256 tokenId, uint256 positionIndex, bool settleIn0, bool settleIn1) =
                abi.decode(params, (PoolKey, uint256, uint256, bool, bool));
            // Settlement happens in underlying terms, so we need to check underlying credits, not LCC credits
            // Note: settleIn0/settleIn1 flags determine direction. After onMMSettle negates the delta:
            //       true = negative amount = deposit (settle IN), false = positive amount = withdraw (settle OUT)
            BalanceDelta sDelta = LiquidityUtils.safeToBalanceDelta(
                _getFullCredit(_lccToUnderlyingCurrency(poolKey.currency0), msgSender()),
                _getFullCredit(_lccToUnderlyingCurrency(poolKey.currency1), msgSender()),
                settleIn0,
                settleIn1
            );
            _settle(poolKey, tokenId, positionIndex, sDelta.amount0(), sDelta.amount1());
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
     * @param hookData The hook data to pass to the pool manager
     * @return principalDelta The balance delta of the principal liquidity
     * @return accruedFeesAfterAdj The balance delta of the fees accrued after adjustment
     */
    function _modifyPositionLiquidity(
        PoolKey memory poolKey,
        ModifyLiquidityParams memory params,
        bytes memory hookData
    ) internal override returns (BalanceDelta principalDelta, BalanceDelta accruedFeesAfterAdj) {
        // use param to modify liquidity
        (BalanceDelta positionDelta, BalanceDelta feesAccrued) =
            super._modifyPositionLiquidity(poolKey, params, hookData);

        // Consume fee adjustment materialised by CoreHook for this call
        BalanceDelta feeAdj = TransientSlots.consumeFeeAdjDelta(address(vtsManager));

        // CoreHook applies a feeAdj to the callerDelta. ie.  callerDelta = principalDelta - feesAccrued - feeAdj.
        // Treat feeAdj as part of fees for cancel/transfer purposes.
        // ? feeAdj bonus is negative, slash is positive. The result is higher fees for bonus, lower for slash.
        accruedFeesAfterAdj = feesAccrued - feeAdj;

        // positionDelta(a0/a1) are the gross amounts returned by the PoolManager for position modification.
        // principal0/principal1 = a{0,1} - fees{0,1} reflect the true principal liquidity change
        // that maps to LCC cancellation. fees are trader-derived, wrapped LCC value and must remain wrapped.
        principalDelta = positionDelta - accruedFeesAfterAdj;

        _accountDelta(poolKey.currency0, accruedFeesAfterAdj.amount0(), msgSender());
        _accountDelta(poolKey.currency1, accruedFeesAfterAdj.amount1(), msgSender());

        // Consume the aggregated required settlement delta from CoreHook (VTSManager) and clear it
        // Signs: negative delta = caller owes liquidity (deposit), positive = protocol owes (withdrawal)
        BalanceDelta requiredSettlementDelta =
            TransientSlots.consumePositionRequiredSettlementDelta(address(vtsManager));
        _accountUnderlyingSettlementDelta(msgSender(), requiredSettlementDelta, poolKey.currency0, poolKey.currency1);
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
        (rfsOpen, rfsDelta) = vtsManager.calcRFS(positionId, requireClosedRfS);
    }

    /**
     * Gets information about a position using the token id and position index
     * @param tokenId The token id to get the position info for
     * @param positionIndex The position index to get the position info for
     * @return positionInfo The position info
     */
    function _getPosition(uint256 tokenId, uint256 positionIndex, bool requireActive)
        internal
        view
        returns (PositionMeta memory)
    {
        PositionId positionId = getPositionId(tokenId, positionIndex);
        if (PositionId.unwrap(positionId) == bytes32(0)) {
            revert Errors.InvalidPosition(tokenId, positionIndex, positionId);
        }
        PositionMeta memory m = vtsManager.getPosition(positionId, requireActive, true);

        if (!_isMMPosition(m)) {
            revert Errors.InvalidPosition(tokenId, positionIndex, positionId);
        }

        return m;
    }

    // Overloaded function to automate require active position.
    function getPosition(uint256 tokenId, uint256 positionIndex) public view returns (PositionMeta memory) {
        return _getPosition(tokenId, positionIndex, true);
    }

    // ------------------------
    // Commit-level helpers
    // ------------------------

    /// @dev Resolves the market's LCC pair addresses for a given pool.
    /// @param poolId The core pool identifier for the market the commit is bound to.
    /// @return lcc0 Address of token0's LCC contract for the core pool.
    /// @return lcc1 Address of token1's LCC contract for the core pool.
    function _marketLccPair(PoolId poolId) internal view returns (address lcc0, address lcc1) {
        address[2] memory pair = _corePoolToCurrencyPair(poolId);
        lcc0 = pair[0];
        lcc1 = pair[1];
    }

    /// @dev Sums settled raw token amounts across all positions attached to a commit NFT.
    /// @param tokenId The commit NFT id.
    /// @return s0 Total settled token0 across positions.
    /// @return s1 Total settled token1 across positions.
    function _sumSettledAmountsForCommit(uint256 tokenId) internal view returns (uint256 s0, uint256 s1) {
        uint256 n = commitToPositionCount[tokenId];
        PositionId[] memory pids = new PositionId[](n);
        for (uint256 i = 0; i < n; i++) {
            PositionId pid = getPositionId(tokenId, i);
            pids[i] = pid;
        }
        (s0, s1) = vtsManager.getPositionSettledAmounts(pids);
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

    /// @dev Values a pair of LCC amounts using USD prices from OracleHelper.
    ///      Uses ResilientOracle normalization (handles decimals internally).
    /// @param lcc0 Address of token0 LCC.
    /// @param a0 Amount of token0 LCC (raw units).
    /// @param lcc1 Address of token1 LCC.
    /// @param a1 Amount of token1 LCC (raw units).
    /// @return Total USD value of the two amounts (normalised by ResilientOracle).
    function _usdValueLccPair(address lcc0, uint256 a0, address lcc1, uint256 a1) internal view returns (uint256) {
        (uint256 p0, uint256 p1) = oracleHelper.getPricesForLCCPair(lcc0, lcc1);
        // Rely on ResilientOracle normalization; direct computation
        return (p0 * a0) + (p1 * a1);
    }

    /// @dev Values the currently stored signal reserves in USD via OracleHelper.
    ///      This does not mutate the signal nonce; it is a pure view against the stored state.
    /// @param tokenId The commit NFT id.
    /// @return USD value of the stored signal reserves.
    function _currentSignalUsdValue(uint256 tokenId) internal view returns (uint256) {
        (string[] memory tickers, uint256[] memory amounts) = commitOf[tokenId].state.signal.mmState.getReserves();
        return oracleHelper.getTotalUsdValue(tickers, amounts);
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
            revert Errors.InvalidLiquiditySignal(0, 0);
        }
        (string[] memory tickers, uint256[] memory amounts) = sig.mmState.getReserves();
        return oracleHelper.getTotalUsdValue(tickers, amounts);
    }

    /// @dev Computes USD values for issued and settled amounts for a commit.
    /// @param tokenId The commit NFT id.
    /// @param extraIssue0 Additional token0 LCC to add to effective amounts (for prospective issuance).
    /// @param extraIssue1 Additional token1 LCC to add to effective amounts (for prospective issuance).
    /// @return issuedUsd Total USD value of effective issued LCC amounts.
    /// @return settledUsd Total USD value of settled amounts.
    function _computeCommitmentUsdValues(uint256 tokenId, uint256 extraIssue0, uint256 extraIssue1)
        internal
        view
        returns (uint256 issuedUsd, uint256 settledUsd)
    {
        PoolId poolId = commitOf[tokenId].poolId;
        (address l0, address l1) = _marketLccPair(poolId);

        (uint256 e0, uint256 e1) = _effectiveIssuedAmountsForCommit(tokenId);
        issuedUsd = _usdValueLccPair(l0, e0 + extraIssue0, l1, e1 + extraIssue1);

        (uint256 s0, uint256 s1) = _sumSettledAmountsForCommit(tokenId);
        settledUsd = _usdValueLccPair(l0, s0, l1, s1);
    }

    /// @dev Asserts commit solvency against the currently stored signal.
    ///      Effective LCC (including any prospective issuance passed in) must be ≤ signal USD + settled USD.
    /// @param tokenId The commit NFT id.
    /// @param extraIssue0 Prospective token0 LCC to add to effective amounts (e.g., for a new mint).
    /// @param extraIssue1 Prospective token1 LCC to add to effective amounts (e.g., for a new mint).
    function _assertCommitmentSolventStored(uint256 tokenId, uint256 extraIssue0, uint256 extraIssue1) internal view {
        (uint256 issuedUsd, uint256 settledUsd) = _computeCommitmentUsdValues(tokenId, extraIssue0, extraIssue1);
        uint256 signalUsd = _currentSignalUsdValue(tokenId);

        // Invariant: issued ≤ signal + settled (prevents over-issuance relative to backing)
        if (issuedUsd > signalUsd + settledUsd) {
            revert Errors.InvalidLiquiditySignal(signalUsd + settledUsd, issuedUsd);
        }
    }

    /// @dev Asserts commit solvency against a newly supplied signal.
    ///      Verifies the signal (nonce bump), then checks effective LCC ≤ signal USD + settled USD.
    /// @param tokenId The commit NFT id.
    /// @param liquiditySignal ABI-encoded LiquiditySignal (new state).
    function _assertCommitmentSolventWithNewSignal(uint256 tokenId, bytes memory liquiditySignal) internal {
        (uint256 issuedUsd, uint256 settledUsd) = _computeCommitmentUsdValues(tokenId, 0, 0);
        uint256 signalUsd = _verifiedSignalUsdValue(liquiditySignal);

        // Invariant: issued ≤ signal + settled (post-verify renew path)
        if (issuedUsd > signalUsd + settledUsd) {
            revert Errors.InvalidLiquiditySignal(signalUsd + settledUsd, issuedUsd);
        }
    }

    // ------------------------------------------------------------------------------------------------
    // Actions handlers
    // ------------------------------------------------------------------------------------------------

    /// @notice Unwrap LCC to underlying asset, either from deltas (requested == 0) or from caller's wallet (requested > 0).
    /// @dev Non-reverting: clamps to available; returns actually unwrapped amount observed via balance delta.
    /// @param lccAddr The LCC token address to unwrap
    /// @param from The address to unwrap from (for deltas or wallet transfer)
    /// @param to The recipient address to receive the underlying asset
    /// @param requested The requested LCC amount to unwrap (0 = unwrap from deltas, >0 = unwrap from caller's wallet)
    /// @return unwrapped The actual amount of underlying delivered to the recipient
    function _unwrapLCC(address lccAddr, address from, address to, uint256 requested)
        internal
        returns (uint256 unwrapped)
    {
        ILCC lcc = ILCC(lccAddr);
        Currency lccCurrency = Currency.wrap(lccAddr);
        address underlying = lcc.underlying();

        // Measure recipient underlying balance before unwrap
        uint256 beforeBal = IERC20Minimal(underlying).balanceOf(to);

        uint256 toUnwrap;

        if (requested == 0) {
            // Unwrap from deltas: use available credit from this contract's deltas
            uint256 available = _getFullCredit(lccCurrency, from);
            toUnwrap = available; // Unwrap all available deltas
        } else {
            // Unwrap from caller's wallet: transfer LCC from caller to this contract first
            toUnwrap = requested;
        }

        if (toUnwrap > 0) {
            // Route unwrap via LiquidityHub to leverage reserve tracking and settlement queuing
            if (from != address(this)) {
                lcc.safeTransferFrom(from, address(this), toUnwrap);
            }
            liquidityHub.unwrapTo(lccAddr, to, toUnwrap);
        }

        // Compute actually unwrapped by observing recipient balance delta
        unwrapped = IERC20Minimal(underlying).balanceOf(to) - beforeBal;

        if (unwrapped > 0) {
            _accountDelta(lccCurrency, -unwrapped.toInt128(), msgSender()); // Debit LCC delta from source
            _accountDelta(Currency.wrap(underlying), unwrapped.toInt128(), to); // Credit underlying delta to recipient
        }
    }

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
    {
        _assertCommitForPool(poolKey, tokenId);

        if (amount0 == 0 && amount1 == 0) {
            // Cannot settle 0 amounts for both assets.
            revert Errors.InvalidDelta(0, 0);
        }

        PositionId positionId = getPositionId(tokenId, positionIndex);
        // Check transient storage for seized position to determine if seizing
        PositionId seizedPositionId = TransientSlots.getSeizedPositionId();
        bool isSeizing = PositionId.unwrap(seizedPositionId) == PositionId.unwrap(positionId);

        // Access control: if not seizing, require approval
        if (!isSeizing) {
            _assertSignalValid(tokenId);
            _assertApprovedOrOwner(msgSender(), tokenId);
        }

        // notify the vts manager of the settlement made for this position
        // validats the position internally, or throws.
        // returns the delta of required underlying settlements IN or OUT, rfs open/closed, and the amount of liquidity units seized during seizure path
        (BalanceDelta settlementDelta, bool rfsOpen, uint256 seizedLiqUnits) = vtsManager.onMMSettle(
            positionId, poolKey.currency0, poolKey.currency1, toBalanceDelta(amount0, amount1), isSeizing
        );

        // mark RFS checkpoint
        _markCheckpoint(positionId, rfsOpen); // checkpoint directly on the _settleUnderlying call.

        // settle the underlying assets to the proxy
        _settleUnderlying(
            msgSender(),
            poolKey.toId(),
            settlementDelta,
            ILCC(Currency.unwrap(poolKey.currency0)).underlying(),
            ILCC(Currency.unwrap(poolKey.currency1)).underlying()
        );

        if (seizedLiqUnits > 0 && isSeizing) {
            TransientSlots.setSeizedPosition(positionId, seizedLiqUnits);
        }
    }

    /**
     * @dev This function is used to extend the grace period for a position by providing a settlement proof
     * @param poolKey The pool key for the position
     * @param tokenId The token id of the position
     * @param positionIndex The position index
     * @param settlementTokenIndex The index of the settlement token (0 or 1)
     * @param verifierIndex The index of the verifier to use
     * @param settlementProof The settlement proof containing the proof
     */
    function _extendGracePeriod(
        PoolKey memory poolKey,
        uint256 tokenId,
        uint256 positionIndex,
        uint8 settlementTokenIndex,
        uint32 verifierIndex,
        bytes memory settlementProof
    ) internal onlyIfApproved(msgSender(), tokenId) onlyValidCommit(poolKey, tokenId) {
        getPosition(tokenId, positionIndex); // Validate the position by fetching it.

        // Get the VTS configuration for the pool
        MarketVTSConfiguration memory vtsConfiguration = vtsManager.getMarketVTSConfiguration(poolKey.toId());

        // Call the inherited function from RFSCheckpointModule
        // Note: Different signature allows function overloading, but we use super to explicitly call parent
        super._extendGracePeriod(
            poolKey, vtsConfiguration, tokenId, positionIndex, settlementTokenIndex, verifierIndex, settlementProof
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
        // get all positions attached to this token id
        uint256 positionCount = commitToPositionCount[tokenId];
        for (uint256 i = 0; i < positionCount; i++) {
            PositionMeta memory position = getPosition(tokenId, i);
            if (position.isActive) {
                _burnPositionInternal(poolKey, tokenId, i);
            }
        }

        // burn the nft after removing all of the liquidity
        _burn(tokenId);

        emit SignalDecommitted(tokenId, positionCount);
    }

    /**
     * @dev This function is used to decommit a position for a given position id
     * @param poolKey The pool key for the position
     * @param tokenId The token id to decommit the position for
     * @param positionIndex The position index to decommit the position for
     */
    function _burnPosition(PoolKey memory poolKey, uint256 tokenId, uint256 positionIndex)
        internal
        onlyIfApproved(msgSender(), tokenId)
        onlyValidCommit(poolKey, tokenId)
    {
        _burnPositionInternal(poolKey, tokenId, positionIndex);
    }

    function _burnPositionInternal(PoolKey memory poolKey, uint256 tokenId, uint256 positionIndex) internal {
        PositionMeta memory pos = getPosition(tokenId, positionIndex);
        uint256 completeLiquidity = uint256(pos.liquidity);
        _decrease(poolKey, tokenId, positionIndex, completeLiquidity);
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
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidity
    ) internal onlyIfApproved(msgSender(), tokenId) onlyValidCommit(poolKey, tokenId) {
        _increaseInternal(poolKey, tokenId, positionIndex, tickLower, tickUpper, liquidity);
    }

    function _increaseInternal(
        PoolKey memory poolKey,
        uint256 tokenId,
        uint256 positionIndex,
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidity
    ) internal returns (PositionId positionId) {
        // Prevent overflow when converting to int256/int128 for modifyLiquidity
        if (liquidity > type(uint128).max) {
            revert Errors.InvalidAmount(liquidity, type(uint128).max);
        }

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: liquidity.toInt256(),
            salt: _positionSalt(tokenId, positionIndex)
        });

        // mint or modify liquidity. If the position is not minted, this will mint it. If the position is already minted, this will modify it.
        (BalanceDelta principalDelta,) = _modifyPositionLiquidity(poolKey, params, Constants.ZERO_BYTES);
        // generate unique position id using the params which contains the salt making this unique across all positions
        // ? If an existing position is being modified, then the position id will be the SAME, so long as (tickUpper, tickLower, salt, AND owner) do not change.
        // ie. changing liquidity does not impact the position id.
        positionId = PositionLibrary.generateId(address(this), params);
        if (liquidity == 0 && LiquidityUtils.isZeroDelta(principalDelta)) {
            return positionId;
        }

        uint256 a0 = LiquidityUtils.safeInt128ToUint256(principalDelta.amount0());
        uint256 a1 = LiquidityUtils.safeInt128ToUint256(principalDelta.amount1());
        // Solvency gate: effective LCC (including prospective) <= signal + settled
        _assertCommitmentSolventStored(tokenId, a0, a1);

        address lcc0 = Currency.unwrap(poolKey.currency0);
        address lcc1 = Currency.unwrap(poolKey.currency1);
        if (a0 > 0) {
            liquidityHub.issue(lcc0, a0);
        }
        if (a1 > 0) {
            liquidityHub.issue(lcc1, a1);
        }
    }

    /**
     * @dev This function is used to get the liquidity from deltas
     * @param poolKey The pool key for the position
     * @param tickLower The lower tick of the position
     * @param tickUpper The upper tick of the position
     * @return liquidity The liquidity from deltas
     */
    function _getLiquidityFromDeltas(PoolKey memory poolKey, int24 tickLower, int24 tickUpper)
        internal
        view
        returns (uint256 liquidity)
    {
        address sender = msgSender();
        uint256 credit0 = _getFullCredit(_lccToUnderlyingCurrency(poolKey.currency0), sender);
        uint256 credit1 = _getFullCredit(_lccToUnderlyingCurrency(poolKey.currency1), sender);
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());
        return LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            credit0,
            credit1
        );
    }

    /**
     * @dev Increases liquidity of an existing position using fees accrued (LCC credits)
     * @param poolKey The pool key for the position
     * @param tokenId The token id to increase the liquidity for
     * @param positionIndex The position index to increase the liquidity for
     * @param tickLower The lower tick of the position
     * @param tickUpper The upper tick of the position
     */
    function _increaseFromDeltas(
        PoolKey memory poolKey,
        uint256 tokenId,
        uint256 positionIndex,
        int24 tickLower,
        int24 tickUpper
    ) internal onlyIfApproved(msgSender(), tokenId) onlyValidCommit(poolKey, tokenId) {
        // Compute liquidity from LCC credits (via router helper)
        uint256 liquidityFromDeltas = _getLiquidityFromDeltas(poolKey, tickLower, tickUpper);

        _increase(poolKey, tokenId, positionIndex, tickLower, tickUpper, liquidityFromDeltas);
    }

    /**
     * @dev Mints a new position using fees accrued (LCC credits)
     * @param poolKey The pool key to mint the position for
     * @param tokenId The token id to mint the position for
     * @param tickLower The lower tick of the position
     * @param tickUpper The upper tick of the position
     */
    function _mintFromDeltas(PoolKey memory poolKey, uint256 tokenId, int24 tickLower, int24 tickUpper)
        internal
        onlyIfApproved(msgSender(), tokenId)
        onlyValidCommit(poolKey, tokenId)
    {
        // Compute underying liquidity from credits (via router helper)
        uint256 liquidityFromDeltas = _getLiquidityFromDeltas(poolKey, tickLower, tickUpper);

        _mintPosition(poolKey, tokenId, tickLower, tickUpper, liquidityFromDeltas);
    }

    /**
     * @dev Entry point for decreasing position liquidity.
     *      Validates position and access control, then calls internal logic.
     * @param poolKey The pool key for the position
     * @param tokenId The token id to decrease the liquidity for
     * @param positionIndex The position index to decrease the liquidity for
     * @param amountToDecrease The amount of liquidity to decrease
     */
    function _decrease(PoolKey memory poolKey, uint256 tokenId, uint256 positionIndex, uint256 amountToDecrease)
        internal
    {
        _assertCommitForPool(poolKey, tokenId);

        PositionMeta memory position = getPosition(tokenId, positionIndex);
        PositionId positionId = getPositionId(tokenId, positionIndex);

        // Check transient storage for seized position
        PositionId seizedPositionId = TransientSlots.getSeizedPositionId();
        bool isSeizing = PositionId.unwrap(seizedPositionId) == PositionId.unwrap(positionId);

        // Access control: if not seizing, require approval
        if (!isSeizing) {
            _assertSignalValid(tokenId);
            _assertApprovedOrOwner(msgSender(), tokenId);
        }

        // For seizure, hookData is prepared in _seizePosition and passed directly to _decreaseInternal
        // Call internal logic
        _decreaseInternal(
            poolKey, position, _positionSalt(tokenId, positionIndex), amountToDecrease, Constants.ZERO_BYTES
        );
    }

    /**
     * @dev Internal logic for decreasing position liquidity.
     *      Removes liquidity from the pool and handles settlement.
     * @param poolKey The pool key for the position
     * @param position The position to decrease
     * @param salt The salt of the position
     * @param amountToDecrease The amount of liquidity to decrease
     * @param hookData The hook data to pass to modifyLiquidity
     */
    function _decreaseInternal(
        PoolKey memory poolKey,
        PositionMeta memory position,
        bytes32 salt,
        uint256 amountToDecrease,
        bytes memory hookData
    ) internal {
        // validate liquidity is not over available
        uint256 posLiq = uint256(position.liquidity);
        if (amountToDecrease > posLiq) {
            revert Errors.InvalidAmount(amountToDecrease, posLiq);
        }
        if (amountToDecrease > uint256(type(int256).max)) {
            amountToDecrease = uint256(type(int256).max); // clamp by max.
        }

        // remove the liquidity from the pool
        // By calling this, CoreHook afterRemoveLiquidity will be called to deactivate the position.
        (BalanceDelta principalDelta,) = _modifyPositionLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: position.tickLower,
                tickUpper: position.tickUpper,
                liquidityDelta: -amountToDecrease.toInt256(),
                salt: salt
            }),
            hookData
        );

        if (amountToDecrease == 0 && LiquidityUtils.isZeroDelta(principalDelta)) {
            return;
        }

        BalanceDelta settlementDelta = _getUnderlyingSettlementDelta(msgSender(), poolKey.currency0, poolKey.currency1);
        BalanceDelta availableDelta = _clampSettlementDeltaByAvailableLiquidities(position.poolId, settlementDelta);
        BalanceDelta diff = settlementDelta - availableDelta;
        if (availableDelta.amount0() > 0) {
            liquidityHub.cancel(
                Currency.unwrap(poolKey.currency0), LiquidityUtils.safeInt128ToUint256(availableDelta.amount0())
            );
        }
        if (availableDelta.amount1() > 0) {
            liquidityHub.cancel(
                Currency.unwrap(poolKey.currency1), LiquidityUtils.safeInt128ToUint256(availableDelta.amount1())
            );
        }
        // For unavailable liquidity, mark the difference as LCCs (withdrawable = positive delta) to the caller.
        if (diff.amount0() > 0 || diff.amount1() > 0) {
            _convertUnderlyingDeltaToLccDelta(msgSender(), diff, poolKey.currency0, poolKey.currency1);
        }
    }

    /**
     * @dev This function is used to renew a liquidity signal for a given token id
     * @param tokenId The token id to renew the liquidity signal for
     * @param liquiditySignal The liquidity signal to renew the liquidity signal for
     */
    function _renew(uint256 tokenId, bytes memory liquiditySignal) internal onlyIfApproved(msgSender(), tokenId) {
        if (liquiditySignal.length == 0) {
            revert Errors.InvalidLiquiditySignal(0, 0);
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
     * @param owner The address to receive the commitment NFT (can be mapped constants).
     * @return tokenId The commitment NFT id created.
     */
    function _commitSignal(PoolKey memory poolKey, bytes memory liquiditySignal, address owner)
        internal
        returns (uint256 tokenId)
    {
        if (liquiditySignal.length == 0) {
            revert Errors.InvalidLiquiditySignal(0, 0);
        }

        LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
        // verify the proofs associated with the state
        (bool isSignalValid, uint256 expirySeconds) = signalManager.verifyLiquiditySignal(signal);
        // if the proof is invalid, revert
        if (!isSignalValid) {
            revert Errors.InvalidLiquiditySignal(0, 0);
        }

        // ? -- Mint the Commitment NFT
        // get the token id
        tokenId = nextTokenId++;
        // mint the nft
        _mint(owner, tokenId);
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
    function _mintPosition(
        PoolKey memory poolKey,
        uint256 tokenId,
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidity
    ) internal returns (PositionId positionId, uint256 positionIndex) {
        // add liquidity to the pool using the token id and position index to generate a unique salt
        positionIndex = commitToPositionCount[tokenId];

        positionId = _increaseInternal(poolKey, tokenId, positionIndex, tickLower, tickUpper, liquidity);

        // Attach position to this nft
        // make sure to add the position only after modifying the liquidity
        // because the number of positions is used to generate the salt for the position
        commitToPosition[tokenId][positionIndex] = positionId;
        // Position metadata is managed centrally via PositionRegistry/VTSManager
        // increment the number of positions for the nft
        commitToPositionCount[tokenId]++;
    }

    /**
     * @dev Seizure of a position by a guarantor (other MM)
     * @param poolKey The pool key for the position
     * @param tokenId The token id to settle the position for
     * @param positionIndex The position index to settle the position for
     */
    function _seizePosition(
        PoolKey memory poolKey,
        uint256 tokenId,
        uint256 positionIndex,
        uint256 amount0,
        uint256 amount1
    ) internal {
        // -- Validate the poolKey
        _assertCommitForPool(poolKey, tokenId);

        PositionMeta memory position = getPosition(tokenId, positionIndex);
        PositionId positionId = getPositionId(tokenId, positionIndex);

        // -- Validate that caller is not position owner
        // use _isApprovedOrOwner to get the owner/approved wallets of the token id, as position.owner is address(this).
        // Technically, seizing your own position cannot be stopped (via proxy wallets), but there should be no incentive.
        if (_isApprovedOrOwner(msgSender(), tokenId) || position.isActive == false) {
            revert Errors.InvalidPosition(tokenId, positionIndex, positionId);
        }

        // Validate grace period has elapsed
        _isSeizable(vtsManager.getMarketVTSConfiguration(position.poolId), tokenId, positionIndex, true); // revert if grace period has not elapsed

        BalanceDelta settlementDelta = LiquidityUtils.safeToBalanceDelta(amount0, amount1, true, true);

        // Set transient storage placeholder (will be updated after settlement with actual seizedLiquidityUnits)
        TransientSlots.setSeizedPosition(positionId, 0);

        // Call _settle - this will read isSeizing from transient storage and call onMMSettle
        _settle(poolKey, tokenId, positionIndex, amount0.toInt128(), amount1.toInt128());

        uint256 seizedLiquidityUnits = TransientSlots.getSeizedLiquidityUnits(); // set inside of _settle

        // Prepare hookData: encode seizedPositionId and settlementDelta
        bytes memory hookData =
            abi.encode(PositionId.unwrap(positionId), settlementDelta.amount0(), settlementDelta.amount1());

        // Call _decreaseInternal with hookData (convert to calldata via helper)
        _decreaseInternal(poolKey, position, _positionSalt(tokenId, positionIndex), seizedLiquidityUnits, hookData);
    }

    /**
     * @dev Sieze a portion of an insolvent commitment
     * @param poolKey The pool key to sieze the commitment for
     * @param tokenId The token id to sieze the commitment for
     * @param liquiditySignal The liquidity signal to sieze the commitment for
     */
    // TODO: Ensure seizeCommitment maths is correct.
    function _seizeCommitment(PoolKey memory poolKey, uint256 tokenId, bytes memory liquiditySignal) internal {
        _assertCommitForPool(poolKey, tokenId);

        // ? ----- During seizeCommitment, issued LCCs must remained solvent. RfS positions must be closed across the commitment. Identifying insolvency essentially enables seizure with a skip on gracePeriod validation.
        // // ? ----- ----- Despite the signal value no longer matching LCC value, the open RfS + settled liquidity expresses utilised liquidity.
        // // ? ----- ----- Rather than apportioning the commitment, the entire commitment should be seized.
        // ? ----- ----- As per the second point under decommit, LCCs issued during position management rather than for entire commitment reduces the solvency requirement before seizeCommitment and decommit.
        // ? ----- ----- Assuming that the full commitment is utilised in positions, then 80% of the commitment is insolvent, what occurs?
        // ? ----- ----- What if proving insolvency results in unlocking seizure across positions in an intra-transaction process - raising the a position specific-deficit by the diff in signal -> commit values, and skipping the gracePeriod validation for X amount.
        // ? ----- ----- This could allow re-use of position seizure, and for all MMs/Guarantors to paritipate on the seizure. The advancer can be given a share of the seized outcome.
        // ? ----- ----- If we adopt an action-dispatcher model as per the Native PositionManager, then MM's can chain actions together, ie. insolvent (prove insolvency), seize position, mint position, etc.

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
        //     LiquidityUtils.BPS_DENOMINATOR,
        //     positionTotalCommitmentsUSDValue
        // );

        // // iterate through all the positions using the position index, then liquidate a percentage given by the deficit fraction
        // uint256 positionCount = commitToPositionCount[tokenId];
        // for (uint256 i = 0; i < positionCount; i++) {
        //     PositionMeta memory position = getPosition(tokenId, i);
        //     // liquidate a percentage given by the deficit fraction
        //     uint256 liquidityToSeize =
        //         FullMath.mulDiv(uint256(position.liquidity), deficitFractionInBips, LiquidityUtils.BPS_DENOMINATOR);
        //     _decrease(poolKey, position, _positionSalt(tokenId, i), liquidityToSeize, false);
        // }
    }

    /// @dev overrides transferFrom to revert if pool manager is locked
    /// @dev mirrors PositionManager and prevents transfers while an unlock session is active (mid-batch), avoiding inconsistent state/reentrancy around router-locked flows.
    function transferFrom(address from, address to, uint256 id) public virtual override onlyIfPoolManagerLocked {
        super.transferFrom(from, to, id);
    }
}
