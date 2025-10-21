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
import {RFSCheckpointModule} from "./modules/RFSCheckpoint.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";

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
    BaseActionsRouter
{
    using SafeCast for *;
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
    error DeadlinePassed(uint256 deadline);
    error NotApproved(address caller);

    event SignalCommitted(uint256 tokenId);
    event SignalDecommitted(uint256 tokenId, uint256 positionIndex, uint256 amount0, uint256 amount1);

    address public immutable marketFactory;
    address public immutable commitmentDescriptor;
    uint256 private nextTokenId = 1;
    IPoolManager private poolManager;
    IVRLSignalManager public immutable signalManager;
    mapping(uint256 => mapping(uint256 => PositionId)) public commitToPosition;
    mapping(uint256 => uint256) public commitToPositionCount;
    mapping(PositionId => string) public proverOfPosition;

    // TODO: Should be relative to a pool
    struct Commit {
        SignalState state;
        int256[2] maxIssuable;
        int256[2] issued;
        int256[2] insolvent;
    }

    mapping(uint256 => Commit) public commitOf;

    enum MMAction {
        COMMIT_SIGNAL,
        MINT_POSITION,
        SETTLE_POSITION,
        MODIFY_LIQUIDITY,
        BURN_POSITION,
        RENEW_SIGNAL,
        SEIZE_POSITION,
        SEIZE_COMMITMENT,
        DECOMMIT
    }

    constructor(address _manager, address _signalManager, address _marketFactory, address _descriptor)
        LiquidityRouter(_manager)
        ERC721Permit_v4("Fiet VRL Commitment Positions Manager", "FIET-VRL-MMP")
        BaseActionsRouter(IPoolManager(_manager))
    {
        marketFactory = _marketFactory;
        poolManager = IPoolManager(_manager);
        signalManager = IVRLSignalManager(_signalManager);
        commitmentDescriptor = _descriptor;
    }

    modifier onlyValidSignal(uint256 tokenId) {
        if (commitOf[tokenId].state.expiresAt < block.timestamp) {
            revert SignalExpired(tokenId);
        }
        _;
    }

    /// @notice Reverts if the caller is not the owner or approved for the ERC721 token
    /// @param caller The address of the caller
    /// @param tokenId the unique identifier of the ERC721 token
    /// @dev either msg.sender or msgSender() is passed in as the caller
    /// msgSender() should ONLY be used if this is called from within the unlockCallback, unless the codepath has reentrancy protection
    modifier onlyIfApproved(address caller, uint256 tokenId) override {
        if (!_isApprovedOrOwner(caller, tokenId)) revert NotApproved(caller);
        _;
    }

    /// @notice Enforces that the PoolManager is locked.
    modifier onlyIfPoolManagerLocked() override {
        if (poolManager.isUnlocked()) revert PoolManagerMustBeLocked();
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

    function getPositionId(uint256 tokenId, uint256 positionIndex) public view returns (PositionId) {
        return commitToPosition[tokenId][positionIndex];
    }

    function getSignalState(uint256 tokenId) public view returns (SignalState memory) {
        return commitOf[tokenId].state;
    }

    function _positionCountOf(uint256 tokenId) internal view override returns (uint256) {
        return commitToPositionCount[tokenId];
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
            (PoolKey memory poolKey, uint256 tokenId, int24 tickLower, int24 tickUpper, int256 liquidity) =
                abi.decode(params, (PoolKey, uint256, int24, int24, int256));
            _mintPosition(poolKey, tokenId, tickLower, tickUpper, liquidity);
            return;
        }
        if (action == uint256(MMAction.SETTLE_POSITION)) {
            (PoolKey memory poolKey, uint256 tokenId, uint256 positionIndex, int128 amount0, int128 amount1) =
                abi.decode(params, (PoolKey, uint256, uint256, int128, int128));
            _settle(poolKey, tokenId, positionIndex, amount0, amount1);
            return;
        }
        if (action == uint256(MMAction.MODIFY_LIQUIDITY)) {
            (PoolKey memory poolKey, uint256 tokenId, uint256 positionIndex, int256 liquidityDelta) =
                abi.decode(params, (PoolKey, uint256, uint256, int256));
            _modifyLiquidityDelta(poolKey, tokenId, positionIndex, liquidityDelta);
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
     * @dev Settles the underlying assets for a given position based on protocol-defined settlement rules.
     * Utilizes the provided modifyDelta as an input; the actual settled amounts (settlementDelta) are determined in accordance with protocol rules applied by the VTSManager,
     * which may differ from modifyDelta (e.g., due to clamping or adjustments).
     * The appropriate underlying assets are then transferred or withdrawn, and the proxy hook is notified.
     * In essence, the MM is providing a modifyDelta what default settlements apply.
     * @param positionId The position id for which to settle underlying assets
     * @param poolId The pool id associated with the position
     * @param modifyDelta The requested balance delta for underlying asset settlement (input)
     * @param ua0 The address of underlying asset 0
     * @param ua1 The address of underlying asset 1
     * @return settlementDelta The actual balance delta of underlying assets settled, as determined by settlement logic
     */
    function _settleUnderlying(
        PositionId positionId,
        PoolId poolId,
        BalanceDelta modifyDelta, // amount we want to modify default deltas by - ie. amount to settle IN or OUT (purely UA)
        address ua0,
        address ua1
    ) internal returns (BalanceDelta settlementDelta) {
        address sender = msgSender();

        address proxyHook = IMarketFactory(marketFactory).corePoolToProxyHook(poolId);

        // notify the vts manager of the settlement made for this position
        // returns the delta of required settlements IN or OUT
        bool rfsOpen = false;
        (settlementDelta, rfsOpen) = _getVTSManager().onMMLiquidityModify(positionId, modifyDelta);

        // mark RFS checkpoint
        _markCheckpoint(positionId, rfsOpen); // checkpoint directly on the _settleUnderlying call.

        // for deposits, transfer to the Market Vault (proxy hook)
        if (settlementDelta.amount0() > 0) {
            IERC20Minimal(ua0).transferFrom(
                sender, proxyHook, LiquidityUtils.safeInt128ToUint256(settlementDelta.amount0())
            );
        }
        if (settlementDelta.amount0() > 0) {
            IERC20Minimal(ua1).transferFrom(
                sender, proxyHook, LiquidityUtils.safeInt128ToUint256(settlementDelta.amount1())
            );
        }

        // notify the proxy hook of the settled underlying tokens
        // a positive balance delta means we are settling underlying tokens to the proxy hook, negative means withdrawing to the MMP.
        // Call after deposits, but before withdrawals.
        IProxyHook(proxyHook).onMMLiquidityModify(settlementDelta);

        // for withdrawals, transfer to the caller/sender/MM.
        if (settlementDelta.amount0() < 0) {
            IERC20Minimal(ua0).transfer(sender, LiquidityUtils.safeInt128ToUint256(settlementDelta.amount0()));
        }
        if (settlementDelta.amount1() < 0) {
            IERC20Minimal(ua1).transfer(sender, LiquidityUtils.safeInt128ToUint256(settlementDelta.amount1()));
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
        (PositionId posId,) = _callModifyLiquidity(
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

        // TODO: On Seizure, this amount should be the seizureSettled + (portion of position settled relative to seizuredLiquidityUnits/liquidity)
        // ----- LCCs acquired by the seizing party are NOT cancelled, rather transferred for unwrap, or subsequent swaps. VTSManager.onMMLiquidityModify coordinates position settlement amounts, whereas Market Vault aggregates them and coordinates LCC queue clearance.

        // pass zero delta because caller is not explicitly settling anything IN or OUT. However, settlements may occur as a reaction to position modification.
        // reference: solidity/src/modules/VTSManager.sol _touchPosition
        returnDelta = _settleUnderlying(posId, poolKey.toId(), BalanceDeltaLibrary.ZERO_DELTA, ua0, ua1);

        // TODO: LCC cancellation should only occur on signal decommit or LCC unwrap. Once we Commitment -> LCC restructure, this because simpler to manage.
        // ? ----- During decommit, signal value must match LCC value in vault (no positions). ie. "LCCs are solvent, and entirely in my possession (In Commit Vault), and therefore I cancel/burn LCCs".
        // ? ----- ----- By minting all LCCs upfront, and issue/cancel in bulk, rather than per position, we minimise dependency on Oracle value normalisation, and can utilise total LCCs minted per commitment to restrict position management.
        // ? ----- ----- However, it causes LCCs issued to be 1:1 with committed amounts, rather than 1:1 with the commitment utilised amounts. The latter allows us to burn without total signal value matching. Only the the value of the amount issued needs solvency before decommit.
        // ? ----- During seize, Guarantor acquires LCCs from MM. Guarantor will settle the position, covering the MM's deficit, receiving their portioned position, and then liquidating it.
        // // ? ----- -----  The outcome is that Guarantors force settlement, because unwrap of LCCs acquired via the position will draw on the MM's reserve liquidity.
        // // ? ----- -----  This also means we need to track LCCs acquired by seizure from a market in _marketLiquidity. OR that we attribute deficit to the original MM? Well the original deficit will not be covered?
        // ? ----- ----- Guarantor receives LCCs for this liquidation, NOT underlying assets (as the settlement covers deficits). However, on LCC unwrap, it must know which market (or position/commitment) it derived from.
        // ? ----- ----- LCCs acquired by seizure from a market must be tracked in _marketLiquidity. Otherwise, how will we know which market to attribute the settlement queue of unwrap to?
        // ? ----- ----- Original MMs will NOT accrue a deficit, as Guarantor has already settled it. Rather, protocol, proactive liquidity, or settlement queue will cover the seizure unwrap.
        // ? ----- ----- Is there a math problem here, where inflows attribute to positions, but also cover settlement queue? Inflows/Deficits accrue to the tick. Inflows settle to positions' totalSettledAmount, but also automatically cover settlement queue requirements.
        // ? ----- ----- This logic should work - as regular settlements to positions also cover settlement queue requirements. Therefore inflows are basically MM-triggered settlements but from traders, in exchange for the position's deficit.
        // ? ----- During seizeCommitment, issued LCCs must remained solvent. RfS positions must be closed across the commitment. Identifying insolvency essentially enables seizure with a skip on gracePeriod validation.
        // // ? ----- ----- Despite the signal value no longer matching LCC value, the open RfS + settled liquidity expresses utilised liquidity.
        // // ? ----- ----- Rather than apportioning the commitment, the entire commitment should be seized.
        // ? ----- ----- As per the second point under decommit, LCCs issued during position management rather than for entire commitment reduces the solvency requirement before seizeCommitment and decommit.
        // ? ----- ----- Assuming that the full commitment is utilised in positions, then 80% of the commitment is insolvent, what occurs?
        // ? ----- ----- What if proving insolvency results in unlocking seizure across positions in an intra-transaction process - raising the a position specific-deficit by the diff in signal -> commit values, and skipping the gracePeriod validation for X amount.
        // ? ----- ----- This could allow re-use of position seizure, and for all MMs/Guarantors to paritipate on the seizure. The advancer can be given a share of the seized outcome.
        // ? ----- ----- If we adopt an action-dispatcher model as per the Native PositionManager, then MM's can chain actions together, ie. insolvent (prove insolvency), seize position, mint position, etc.

        // if (cancelLCCs) {
        // burn the LCC originally committed to the position.
        // lcc0.cancel(LiquidityUtils.safeInt128ToUint256(positionDelta.amount0()));
        // lcc1.cancel(LiquidityUtils.safeInt128ToUint256(positionDelta.amount1()));
        // }
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

        if (!_isMMPosition(positionId, m)) {
            revert InvalidPosition(tokenId, positionIndex, positionId);
        }

        return m;
    }

    /**
     * @dev This function is used to get the total unsettled USD value for a given token id
     *      I.e it provides the value of this position which has not been settled
     * @param tokenId The token id to get the total unsettled USD value for
     * @return totalUSDValue The total unsettled USD value
     */
    function inReserveUSDValue(uint256 tokenId) public view returns (uint256) {
        // get all positions attached to this token id
        uint256 totalUSDValue = 0;
        IVTSManager vtsManager = _getVTSManager();
        uint256 positionCount = commitToPositionCount[tokenId];
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
        onlyValidSignal(tokenId)
    {
        PositionMeta memory m = getPosition(tokenId, positionIndex); // Validate the position by fetching it.

        if (amount0 == 0 && amount1 == 0) {
            // Cannot settle 0 amounts for both assets.
            revert InvalidDelta(0, 0);
        }

        if (!_isValidPositionForPool(poolKey, m)) {
            revert InvalidMarket(poolKey);
        }

        PositionId positionId = getPositionId(tokenId, positionIndex);

        // settle the underlying assets to the proxy hook
        _settleUnderlying(
            positionId,
            m.poolId,
            toBalanceDelta(amount0, amount1),
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
        onlyValidSignal(tokenId)
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
        onlyIfApproved(msgSender(), tokenId)
        onlyValidSignal(tokenId)
        returns (BalanceDelta)
    {
        PositionMeta memory pos = getPosition(tokenId, positionIndex);
        if (!_isValidPositionForPool(poolKey, pos)) {
            revert InvalidMarket(poolKey);
        }
        uint256 completeLiquidity = uint256(pos.liquidity);
        PositionId pid = getPositionId(tokenId, positionIndex);
        BalanceDelta ret = _liquidatePosition(poolKey, pos, _positionSalt(tokenId, positionIndex), completeLiquidity);
        return ret;
    }

    function _modifyLiquidityDelta(PoolKey memory poolKey, uint256 tokenId, uint256 positionIndex, int256 liquidity)
        internal
        onlyIfApproved(msgSender(), tokenId)
        onlyValidSignal(tokenId)
    {
        PositionMeta memory position = getPosition(tokenId, positionIndex);

        // Validate poolKey
        if (!_isValidPositionForPool(poolKey, position)) {
            revert InvalidMarket(poolKey);
        }

        // get the liquidity delta
        // if it is positive add liquidity to the position
        if (liquidity > 0) {
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
            (uint256 lcc0Amount, uint256 lcc1Amount) = LiquidityUtils.calculateEffectiveTokenAmounts(
                sqrtPriceX96, currentTick, position.tickLower, position.tickUpper, liquidity
            );

            // TODO: replace in Commitment -> LCC restructure.
            lcc0.issue(lcc0Amount);
            lcc1.issue(lcc1Amount);

            // modify the liquidity first
            _modifyLiquidity(poolKey, modifyLiquidityParams, Constants.ZERO_BYTES);

            // settle the underlying tokens to the proxy hook
            _settleUnderlying(
                getPositionId(tokenId, positionIndex), poolKey.toId(), BalanceDeltaLibrary.ZERO_DELTA, ua0, ua1
            );
        } else {
            // Direct partial liquidation with minimal calls
            uint256 amountToLiquidate = uint256(-liquidity);
            _liquidatePosition(poolKey, position, _positionSalt(tokenId, positionIndex), amountToLiquidate);
        }
    }

    /**
     * @dev This function is used to renew a liquidity signal for a given token id
     * @param tokenId The token id to renew the liquidity signal for
     * @param liquiditySignal The liquidity signal to renew the liquidity signal for
     */
    function _renew(uint256 tokenId, bytes memory liquiditySignal) internal onlyIfApproved(msgSender(), tokenId) {
        // TODO: This signal is going to comprise of values that are already NOT settled.
        // Therefore, to renew the signal, we need to check that the value of LCC issued for a commitment is <= the total value of signal + value of total settled amount.
        // Furthermore, the valuations do not need to be all using USD denominator.
        // The total LCC issued may not be the same as the effective composition of LCCs in the position. However, we can determine the current effective composition by calculating LCC amounts over pos params and current sqrtPrice.
        uint256 _inReserveUSDValue = inReserveUSDValue(tokenId);
        // verify signal and get total usd value as well
        (uint256 totalSignalUsdValue, uint256 signalExpiryInSeconds) =
            signalManager.renewLiquiditySignal(liquiditySignal);
        // make sure signal is solvent
        if (_inReserveUSDValue > totalSignalUsdValue) {
            revert InvalidLiquiditySignal(totalSignalUsdValue, _inReserveUSDValue);
        }

        LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
        SignalState memory s = SignalState({signal: signal, expiresAt: block.timestamp + signalExpiryInSeconds});
        commitOf[tokenId].state = s;
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
        PositionMeta memory position = getPosition(tokenId, positionIndex);
        PositionId positionId = getPositionId(tokenId, positionIndex);

        // -- Validate that caller is not position owner
        if (msgSender() == position.owner || position.isActive == false) {
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
        _settleUnderlying(positionId, position.poolId, settleBalanceDelta, ua0, ua1);

        // -- Move the underlying liquidity to the to the seizer/caller or to the new position

        // -- Liquidate the position partially or fully
        // do this last because it counld potentially mark the position as inactive and cause some of the above calls to fail as they require an active position
        // ? _liquidatePosition will utilise the removed liquidity BalanceDelta, forward it to VTSManager.onMMLiquidityModify, where it will tryTake relative to the amount settled.
        return _liquidatePosition(poolKey, position, _positionSalt(tokenId, positionIndex), seizedLiquidityUnits);
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
        returns (uint256 deficitFractionInBips)
    {
        // verify the new liquidity signal(this increases the nonce of the mm's signals)
        // get the total usd value of the signal and its expiry time
        (uint256 totalSignalUsdValue, uint256 signalExpiryInSeconds) =
            signalManager.renewLiquiditySignal(liquiditySignal);
        // get the total unsettled value of the position
        uint256 positionTotalCommitmentsUSDValue = inReserveUSDValue(tokenId);
        // make sure the new signal is insolvent before it can be reallocated
        if (totalSignalUsdValue >= positionTotalCommitmentsUSDValue) {
            revert InvalidLiquiditySignal(totalSignalUsdValue, positionTotalCommitmentsUSDValue);
        }
        LiquiditySignal memory newSignal = abi.decode(liquiditySignal, (LiquiditySignal));
        LiquiditySignal memory oldSignal = commitOf[tokenId].state.signal;
        // validate that new signal belongs to the same mm as the old signal
        // require caller is advancer, and ensures that the advancer is not the owner of the signal.
        if (
            newSignal.mmState.owner != oldSignal.mmState.owner && msgSender() != newSignal.mmState.advancer
                && newSignal.mmState.advancer == newSignal.mmState.owner
        ) {
            revert UnauthorizedSignalOwner();
        }
        SignalState memory s = SignalState({signal: newSignal, expiresAt: block.timestamp + signalExpiryInSeconds});
        commitOf[tokenId].state = s;

        // get the difference in the usd value of the signal and the position
        // get the fraction of the deficit of the position, unit is in wad(1e18) for better precision
        deficitFractionInBips = FullMath.mulDiv(
            positionTotalCommitmentsUSDValue - totalSignalUsdValue,
            LiquidityUtils.ONE_BIP,
            positionTotalCommitmentsUSDValue
        );

        // iterate through all the positions using the position index, then liquidate a percentage given by the deficit fraction
        uint256 positionCount = commitToPositionCount[tokenId];
        for (uint256 i = 0; i < positionCount; i++) {
            PositionMeta memory position = getPosition(tokenId, i);
            // liquidate a percentage given by the deficit fraction
            uint256 liquidityToSeize =
                FullMath.mulDiv(uint256(position.liquidity), deficitFractionInBips, LiquidityUtils.ONE_BIP);
            _liquidatePosition(poolKey, position, _positionSalt(tokenId, i), liquidityToSeize);
        }
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
    function _commitSignal(PoolKey memory poolKey, bytes memory liquiditySignal) internal returns (uint256 tokenId) {
        if (liquiditySignal.length == 0) {
            revert InvalidLiquiditySignal(0, 0);
        }
        // Verify solvency using a minimal params shell; we don't yet know position bounds at commit time
        // ModifyLiquidityParams memory params =
        //     ModifyLiquidityParams({tickLower: 0, tickUpper: 0, liquidityDelta: int256(1), salt: bytes32(0)});
        // TODO: Resolve the isolated signal commitment mechanic.
        // (,, uint256 signalExpiryInSeconds) =
        //     signalManager.verifyLiquiditySignalSolvency(poolKey, liquiditySignal, params);

        // LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
        // verify the proofs associated with the state
        bool isSignalValid = signalManager.verifyLiquiditySignal(liquiditySignal);
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
        // store the signal state (new + legacy for migration)
        commitOf[tokenId].state =
            SignalState({signal: signal, expiresAt: block.timestamp + signalManager.signalExpiryInSeconds()});

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
    function _mintPosition(PoolKey memory poolKey, uint256 tokenId, int24 tickLower, int24 tickUpper, int256 liquidity)
        internal
        onlyIfApproved(msgSender(), tokenId)
        onlyValidSignal(tokenId)
        returns (PositionId positionId, uint256 positionIndex)
    {
        if (liquidity == 0) {
            revert InvalidDelta(0, 0);
        }

        ModifyLiquidityParams memory liquidityParams = ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: liquidity,
            salt: bytes32(0)
        });

        // TODO: replace following logic with Commitment -> LCC restructure.
        // ? -- Validate that new Minted Position is within Signal Value threshold.
        // get the total usd value of all the commitments under this nft
        uint256 currentUnsettledUSDValue = inReserveUSDValue(tokenId);
        // get the total usd value of the new commitment
        (uint256 newCommitmentsUSDValue, uint256 totalSignalUsdValue,) =
            signalManager.checkSignalSolvency(poolKey, abi.encode(commitOf[tokenId].state.signal), liquidityParams);

        // validate that the total usd value of outstanding commitments + new commitment < total usd value of signal
        uint256 sumOfValues = currentUnsettledUSDValue + newCommitmentsUSDValue;
        if (sumOfValues > totalSignalUsdValue) {
            revert InvalidLiquiditySignal(totalSignalUsdValue, sumOfValues);
        }

        // ? -- Mint Position
        ILCC lcc0 = ILCC(Currency.unwrap(poolKey.currency0));
        ILCC lcc1 = ILCC(Currency.unwrap(poolKey.currency1));

        // derive the LCC amounts to mint to facilitate the commitment
        (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(poolKey.toId());
        (uint256 lcc0AmountToMint, uint256 lcc1AmountToMint) =
            LiquidityUtils.calculateEffectiveTokenAmounts(sqrtPriceX96, currentTick, tickLower, tickUpper, liquidity);

        // Mint the tokens required for the liquidity commitment
        lcc0.issue(lcc0AmountToMint);
        lcc1.issue(lcc1AmountToMint);
        // Track issuance at commitment level
        commitOf[tokenId].issued[0] += int256(lcc0AmountToMint);
        commitOf[tokenId].issued[1] += int256(lcc1AmountToMint);

        // add liquidity to the pool using the token id and position index to generate a unique salt
        positionIndex = commitToPositionCount[tokenId];
        liquidityParams.salt = _positionSalt(tokenId, positionIndex);

        // add liquidity to the pool
        (positionId,) = _callModifyLiquidity(poolKey, liquidityParams);

        // Attach position to this nft
        // make sure to add the position only after modifying the liquidity
        // because the number of positions is used to generate the salt for the position
        commitToPosition[tokenId][positionIndex] = positionId;
        // Position metadata is managed centrally via PositionIndex/VTSManager
        // increment the number of positions for the nft
        commitToPositionCount[tokenId]++;
        // the prover of the liquidity signal verified to create this position
        // by default, this is address(0). However, if owner = mm position manager, then this is the prover of the liquidity signal verified to create this position
        proverOfPosition[positionId] = commitOf[tokenId].state.signal.mmState.prover;

        _settleUnderlying(
            positionId, poolKey.toId(), BalanceDeltaLibrary.ZERO_DELTA, lcc0.underlyingAsset(), lcc1.underlyingAsset()
        );
    }

    /// @dev overrides solmate transferFrom in case a notification to subscribers is needed
    /// @dev will revert if pool manager is locked
    function transferFrom(address from, address to, uint256 id) public virtual override onlyIfPoolManagerLocked {
        super.transferFrom(from, to, id);
        if (positionInfo[id].hasSubscriber()) _unsubscribe(id);
    }
}
