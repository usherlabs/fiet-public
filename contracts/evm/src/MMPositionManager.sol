// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, toBalanceDelta} from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {ERC721Permit_v4} from "v4-periphery/src/base/ERC721Permit_v4.sol";
import {ReentrancyLock} from "v4-periphery/src/base/ReentrancyLock.sol";
import {Multicall_v4} from "v4-periphery/src/base/Multicall_v4.sol";
import {BaseActionsRouter} from "v4-periphery/src/base/BaseActionsRouter.sol";
import {PositionId, PositionLibrary} from "./types/Position.sol";
import {MarketMaker} from "./libraries/MarketMaker.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IVRLSignalManager} from "./interfaces/IVRLSignalManager.sol";
import {IOracleHelper} from "./interfaces/IOracleHelper.sol";
import {SafeCast} from "v4-periphery/lib/v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
import {ICommitmentDescriptor} from "./interfaces/ICommitmentDescriptor.sol";
import {ILiquidityHub} from "./interfaces/ILiquidityHub.sol";
import {IMMPositionManager} from "./interfaces/IMMPositionManager.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Errors} from "./libraries/Errors.sol";
import {NonzeroDeltaCount} from "@uniswap/v4-core/src/libraries/NonzeroDeltaCount.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {console} from "forge-std/console.sol";
import {IVTSOrchestrator} from "./interfaces/IVTSOrchestrator.sol";
import {Position} from "./types/Position.sol";

contract MMPositionManager is ERC721Permit_v4, IMMPositionManager, ReentrancyLock, Multicall_v4, BaseActionsRouter {
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
    IMarketFactory internal immutable marketFactory;
    IVRLSignalManager internal immutable signalManager;
    IOracleHelper internal immutable oracleHelper;
    IVTSOrchestrator internal immutable vtsOrchestrator;

    address public immutable commitmentDescriptor;

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
        DECOMMIT_SIGNAL,
        UNWRAP_LCC, // params: (address lcc, uint256 amount, address recipient, bool payerIsUser)
        WRAP_NATIVE, // params: (uint256 amount)
        UNWRAP_NATIVE, // params: (uint256 amount)
        EXTEND_GRACE_PERIOD, // params: (PoolKey, uint256 tokenId, uint256 positionIndex, uint8 settlementTokenIndex, uint32 verifierIndex, bytes settlementProof)
        TAKE_LCC, // params: (Currency currency, address recipient, uint256 maxAmount, bool payerIsUser)
        INCREASE_LIQUIDITY_FROM_DELTAS, // params: (Currency currency, int128 delta, address target)
        MINT_POSITION_FROM_DELTAS, // params: (Currency currency, int128 delta, address target)
        SETTLE_POSITION_FROM_DELTAS, // params: (PoolKey memory poolKey, uint256 tokenId, uint256 positionIndex, bool settleIn0, bool settleIn1)
        DECLARE_UNBACKED_COMMITMENT, // params: (PoolKey memory poolKey, uint256 tokenId, bytes memory liquiditySignal)
        COLLECT_AVAILABLE_LIQUIDITY // params: (address lcc, address recipient, uint256 maxAmount)
    }

    // MarketHandler must be first.
    constructor(
        address _manager,
        address _signalManager,
        address _marketFactory,
        address _vtsOrchestrator,
        address _descriptor
    )
        ERC721Permit_v4("Fiet VRL Commitment Positions Manager", "FIET-VRL-MMP")
        BaseActionsRouter(IPoolManager(_manager))
    {
        commitmentDescriptor = _descriptor;
        signalManager = IVRLSignalManager(_signalManager);
        vtsOrchestrator = IVTSOrchestrator(payable(_vtsOrchestrator));
        marketFactory = IMarketFactory(_marketFactory);
        oracleHelper = marketFactory.oracleHelper();
        liquidityHub = marketFactory.liquidityHub();
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

    /// @notice Returns the token URI for a given token id using the commitment descriptor contract
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        if (commitmentDescriptor == address(0)) {
            revert Errors.CommitmentDescriptorNotSet();
        }
        return ICommitmentDescriptor(commitmentDescriptor).tokenURI(address(this), tokenId);
    }

    /// @notice Asserts that the caller is approved or the owner of the token
    function _assertApprovedOrOwner(address caller, uint256 tokenId) internal view {
        if (!_isApprovedOrOwner(caller, tokenId)) {
            revert Errors.NotApproved(caller);
        }
    }

    /// @inheritdoc BaseActionsRouter
    function msgSender() public view override returns (address) {
        return _getLocker();
    }

    // --------------------------------------------------------------------------------
    // Uniswap-like batch entrypoints and dispatcher
    // --------------------------------------------------------------------------------

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
        _executeActionsWithoutUnlock(actions, params);
        if (NonzeroDeltaCount.read() > 0) {
            // TODO: include revert after clamping deltas is implemented
            // revert Errors.CurrencyNotSettled();
            console.log("CurrencyNotSettled");
        }
    }

    function _handleAction(uint256 action, bytes calldata params) internal override {
        if (action == uint256(MMAction.COMMIT_SIGNAL)) {
            (, bytes memory liquiditySignal, address owner) = abi.decode(params, (PoolKey, bytes, address));
            _commitSignal(liquiditySignal, _mapRecipient(owner));
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
            vtsOrchestrator.renewSignal(tokenId, liquiditySignal);
            return;
        }
        if (action == uint256(MMAction.SEIZE_POSITION)) {
            (PoolKey memory poolKey, uint256 tokenId, uint256 positionIndex, uint256 amount0, uint256 amount1) =
                abi.decode(params, (PoolKey, uint256, uint256, uint256, uint256));
            // seize is third-party guarantor action; no approval required by design
            // get owner of the token
            vtsOrchestrator.seizePosition(msgSender(), poolKey, tokenId, positionIndex, amount0, amount1);
            return;
        }
        if (action == uint256(MMAction.DECLARE_UNBACKED_COMMITMENT)) {
            (uint256 tokenId, bytes memory liquiditySignal) = abi.decode(params, (uint256, bytes));
            // declare an unbacked commitment. A third-party guarantor action; no approval required
            vtsOrchestrator.declareUnbackedCommitment(msgSender(), tokenId, liquiditySignal);
            return;
        }
        if (action == uint256(MMAction.COLLECT_AVAILABLE_LIQUIDITY)) {
            // params: (address lcc, address recipient, uint256 maxAmount)
            (address lcc, address recipient, uint256 maxAmount) = abi.decode(params, (address, address, uint256));
            vtsOrchestrator.collectAvailableLiquidity(msgSender(), lcc, recipient, maxAmount);
            return;
        }
        if (action == uint256(MMAction.DECOMMIT_SIGNAL)) {
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
            vtsOrchestrator.unwrapLCC(msgSender(), lccAddr, _mapPayer(payerIsUser), _mapRecipient(recipient), amount);
            return;
        }
        if (action == uint256(MMAction.WRAP_NATIVE)) {
            uint256 amount = abi.decode(params, (uint256));
            vtsOrchestrator.wrapNative{value: msg.value}(msgSender(), amount);
            return;
        }
        if (action == uint256(MMAction.UNWRAP_NATIVE)) {
            // params: (uint256 amount)
            uint256 amount = abi.decode(params, (uint256));
            vtsOrchestrator.unwrapNative(msgSender(), amount);
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
            vtsOrchestrator.extendGracePeriod(
                poolKey, tokenId, positionIndex, settlementTokenIndex, verifierIndex, settlementProof
            );
            return;
        }
        if (action == uint256(MMAction.TAKE_LCC)) {
            // params: (Currency currency, address recipient, uint256 maxAmount, bool payerIsUser)
            (Currency currency, address recipient, uint256 maxAmount, bool payerIsUser) =
                abi.decode(params, (Currency, address, uint256, bool));
            vtsOrchestrator.take(currency, _mapPayer(payerIsUser), _mapRecipient(recipient), maxAmount);
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
            vtsOrchestrator.settleFromDeltas(msgSender(), poolKey, tokenId, positionIndex, settleIn0, settleIn1);
            return;
        }
        revert("UnsupportedAction");
    }

    /**
     * @notice Modifies liquidity parameters of LCC-based position in a Uniswap V4 pool via the PoolManager
     * @dev This function bridges liquidity modifications from MMPositionManager to the PoolManager:
     *      - Calls PoolManager.modifyLiquidity() to add or remove liquidity
     *      - Validates the liquidity change matches expected delta
     *      - Handles currency settlement (paying owed amounts) and claims (receiving owed amounts)
     *      - Returns both principal delta and fees accrued (which are treated differently downstream)
     *
     * @param key The pool key identifying the pool to modify
     * @param params Parameters for the liquidity modification (tick range, delta, salt)
     * @return delta The principal balance delta (callerDelta) - includes liquidity change plus immediate
     *               fee/hook deltas
     * @return feesAccrued Informational delta of fee growth in the modified range for this call
     *
     * Note: The pool manager must already be unlocked by the caller before calling this function.
     */
    function _modifyPositionLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes memory hookData)
        internal
        virtual
        returns (BalanceDelta delta, BalanceDelta feesAccrued)
    {
        bool settleUsingBurn = false;
        bool takeClaims = false;

        // Note: Pool manager must already be unlocked by the caller (MMPositionManager handles this)

        address self = address(this);

        // Get liquidity state before modification for validation
        (uint128 liquidityBefore,,) =
            poolManager.getPositionInfo(key.toId(), self, params.tickLower, params.tickUpper, params.salt);

        // PoolManager returns two deltas:
        // - delta (callerDelta): principal liquidity change plus any immediate fee/hook deltas applied
        //   to the caller
        // - feesAccrued: informational delta of fee growth in the modified range for this call
        // Downstream, MMPositionManager treats principal vs feesAccrued differently: principal maps
        // to LCC issue/cancel, while feesAccrued (originating from trader flows, wrapped into LCCs)
        // must remain wrapped until explicitly unwrapped.
        (delta, feesAccrued) = poolManager.modifyLiquidity(key, params, hookData);

        // Get liquidity state after modification for validation
        (uint128 liquidityAfter,,) =
            poolManager.getPositionInfo(key.toId(), self, params.tickLower, params.tickUpper, params.salt);

        // Get net currency deltas from PoolManager
        // currencyDelta is a net including fee accrual plus any hook-side fee-sharing that's already
        // been applied at modification time.

        // Note: Prior actions in a batch don't accumulate here because each _modifyLiquidity call
        // immediately settles its deltas, resetting currencyDelta to 0 before the next
        // action. The delta read here reflects only the current modification's effect (including hook
        // adjustments like feeAdj from CoreHook). Other actions (e.g., SETTLE_POSITION) account deltas
        // to the hook contract, not to MMPositionManager, so they don't affect this currencyDelta.
        int256 delta0 = poolManager.currencyDelta(self, key.currency0);
        int256 delta1 = poolManager.currencyDelta(self, key.currency1);

        // Validate that liquidity change matches expected delta
        if (int128(liquidityBefore) + params.liquidityDelta != int128(liquidityAfter)) {
            revert Errors.InvariantViolated("liquidity change incorrect");
        }

        // Validate currency delta direction matches liquidity operation type
        if (params.liquidityDelta < 0) {
            // Removing liquidity: PoolManager owes tokens to the LP (positive delta)
            assert(delta0 > 0 || delta1 > 0);
            assert(!(delta0 < 0 || delta1 < 0));
        } else if (params.liquidityDelta > 0) {
            // Adding liquidity: LP owes tokens to PoolManager (negative delta)
            assert(delta0 < 0 || delta1 < 0);
            assert(!(delta0 > 0 || delta1 > 0));
        }

        if (delta0 < 0 && delta1 < 0) {
            // If position is increasing, and therefore caller owes tokens to PoolManager, then we issue LCCs accordingly.
            vtsOrchestrator.issueLCCs(poolKey, params, commitId, uint256(-delta0), uint256(-delta1)); // TODO: Implement this function
        } else if (delta0 > 0 && delta1 > 0) {
            // If position is decreasing, and therefore PoolManager owes tokens to caller, then we settle the deltas accordingly.
            // TODO: Implement the decrease here, and adjust the position management logic accordingly.
        }

        // Settle negative deltas: pay tokens owed to PoolManager (LP is depositing)
        if (delta0 < 0) {
            key.currency0.settle(poolManager, self, uint256(-delta0), settleUsingBurn);
        }
        if (delta1 < 0) {
            key.currency1.settle(poolManager, self, uint256(-delta1), settleUsingBurn);
        }

        // Take positive deltas: receive tokens owed from PoolManager (LP is withdrawing)
        if (delta0 > 0) {
            key.currency0.take(poolManager, self, uint256(delta0), takeClaims);
        }
        if (delta1 > 0) {
            key.currency1.take(poolManager, self, uint256(delta1), takeClaims);
        }
    }

    // ------------------------------------------------------------------------------------------------
    // MM Position Manager functions
    // ------------------------------------------------------------------------------------------------

    /// @notice Returns the position information for a given token ID and position index
    /// @param tokenId the ERC721 tokenId (commitment NFT ID)
    /// @param positionIndex the index of the position within the commitment
    /// @return Position the position information
    function getPosition(uint256 tokenId, uint256 positionIndex) public view returns (Position memory) {
        (Position memory position,) = vtsOrchestrator.getPosition(tokenId, positionIndex);
        return position;
    }

    /**
     * @dev This function returns the position ID for a given token ID and position index
     * @param tokenId The ERC721 tokenId (commitment NFT ID)
     * @param positionIndex The index of the position within the commitment
     * @return PositionId The position ID
     */
    function getPositionId(uint256 tokenId, uint256 positionIndex) public view returns (PositionId) {
        return vtsOrchestrator.getPositionId(tokenId, positionIndex);
    }

    /**
     * @dev This function returns the commit information for a given commitment NFT
     * @param tokenId the ERC721 tokenId (commitment NFT ID)
     * @return mmState The MarketMaker state
     * @return expiresAt The expiration timestamp of the state associated with the commitment
     * @return positionCount The count of positions associated with the commitment
     * @return deficitBps The deficit basis points allocated to the commitment. 0 if no deficit is allocated.
     */
    function commitOf(uint256 tokenId) public view returns (MarketMaker.State memory, uint256, uint256, uint256) {
        return vtsOrchestrator.getCommit(tokenId);
    }

    // ------------------------------------------------------------------------------------------------
    // MM Position Manager functions
    // ------------------------------------------------------------------------------------------------

    // ------------------------------------------------------------------------------------------------
    // Handler functions for the defined actions
    // ------------------------------------------------------------------------------------------------

    /**
     * @dev This function commits a liquidity signal and mints a commitment NFT.
     * @param liquiditySignal The ABI-encoded LiquiditySignal to verify and record.
     * @param owner The address to receive the commitment NFT (can be mapped constants).
     * @return tokenId The commitment NFT id created.
     */
    function _commitSignal(bytes memory liquiditySignal, address owner) internal returns (uint256 tokenId) {
        // commit the signal to the vts orchestrator
        tokenId = vtsOrchestrator.commitSignal(liquiditySignal);
        // mint the nft using the returned token id
        _mint(owner, tokenId);
    }

    /**
     * @dev This function is used to settle underlying assets to/from the position
     * @param poolKey The pool key for the position - adheres to Uniswap standards where poolKey provided as a param.
     * @param tokenId The token id to settle the position for
     * @param positionIndex The position index to settle the position for
     * @param amount0 The amount of token0 to settle. Positive amounts result in deposits, negative amounts result in withdrawals.
     * @param amount1 The amount of token1 to settle. Positive amounts result in deposits, negative amounts result in withdrawals.
     * @return seizedLiquidityUnits The amount of liquidity units seized during seizure path (0 if not seizing)
     */
    function _settle(PoolKey memory poolKey, uint256 tokenId, uint256 positionIndex, int128 amount0, int128 amount1)
        internal
        returns (uint256)
    {
        (uint256 seizedLiquidityUnits, bool isSeizing) =
            vtsOrchestrator.settle(msgSender(), poolKey, tokenId, positionIndex, toBalanceDelta(amount0, amount1));

        // Access control: if not seizing, require approval
        if (!isSeizing) {
            _assertApprovedOrOwner(msgSender(), tokenId);
        }

        return seizedLiquidityUnits;
    }

    /**
     * @dev This function is used to decommit a position for a given token id
     * @param poolKey The pool key for the position
     * @param tokenId The token id to decommit the position for
     */
    function _decommitSignal(PoolKey memory poolKey, uint256 tokenId)
        internal
        onlyIfApproved(msgSender(), tokenId)
        // onlyValidCommit(poolKey, tokenId)

    {
        // this logic would be taken out and the user would have to burn each position individually
        // get all positions attached to this token id
        // uint256 positionCount = commitToPositionCount[tokenId];
        // get the position count from the vts orchestrator
        // ? this logic would be taken out and the user would have to burn each position individually
        (,, uint256 positionCount,) = vtsOrchestrator.getCommit(tokenId);
        for (uint256 i = 0; i < positionCount; i++) {
            Position memory position = getPosition(tokenId, i);
            if (position.isActive) {
                _burnPositionInternal(poolKey, tokenId, i);
            }
        }

        // burn the nft after removing all of the liquidity
        _burn(tokenId);
        // set the token id in transient storage to indicate that the position is being decommitted
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
    {
        _burnPositionInternal(poolKey, tokenId, positionIndex);
    }

    function _burnPositionInternal(PoolKey memory poolKey, uint256 tokenId, uint256 positionIndex) internal {
        Position memory pos = getPosition(tokenId, positionIndex);
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
    ) internal onlyIfApproved(msgSender(), tokenId) {
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

        (BalanceDelta positionDelta, BalanceDelta feesAccrued) =
            _modifyPositionLiquidity(poolKey, params, Constants.ZERO_BYTES);

        vtsOrchestrator.settleModifiedLiquidities(positionDelta, feesAccrued);
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
    ) internal onlyIfApproved(msgSender(), tokenId) {
        // onlyValidCommit(poolKey, tokenId)
        // Compute liquidity from LCC credits (via router helper)
        uint256 liquidityFromDeltas = vtsOrchestrator.getLiquidityFromDeltas(msgSender(), poolKey, tickLower, tickUpper);

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
    {
        // Compute underying liquidity from credits (via router helper)
        uint256 liquidityFromDeltas = vtsOrchestrator.getLiquidityFromDeltas(msgSender(), poolKey, tickLower, tickUpper);

        _mintPositionInternal(poolKey, tokenId, tickLower, tickUpper, liquidityFromDeltas);
    }

    /**
     * @dev Internal logic for decreasing position liquidity.
     *      Removes liquidity from the pool and handles settlement.
     * @param poolKey The pool key for the position
     * @param tokenId The token id to decrease the liquidity for
     * @param positionIndex The position index to decrease the liquidity for
     * @param salt The salt of the position
     * @param amountToDecrease The amount of liquidity to decrease
     * @param hookData The hook data to pass to modifyLiquidity
     */
    function _decreaseInternal(
        PoolKey memory poolKey,
        uint256 tokenId,
        uint256 positionIndex,
        bytes32 salt,
        uint256 amountToDecrease,
        bytes memory hookData
    ) internal returns (BalanceDelta canceledDelta, BalanceDelta queueDelta) {
        (canceledDelta, queueDelta) = vtsOrchestrator.decreaseInternal(
            msgSender(), poolKey, tokenId, positionIndex, salt, amountToDecrease, hookData
        );
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
        onlyIfApproved(msgSender(), tokenId)
    {
        // For seizure, hookData is prepared in _seizePosition and passed directly to _decreaseInternal
        // Call internal logic
        _decreaseInternal(
            poolKey,
            tokenId,
            positionIndex,
            PositionLibrary.generateSalt(tokenId, positionIndex),
            amountToDecrease,
            Constants.ZERO_BYTES
        );
    }

    function _mintPositionInternal(
        PoolKey memory poolKey,
        uint256 tokenId,
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidity
    ) internal returns (PositionId positionId, uint256 positionIndex) {
        // add liquidity to the pool using the token id and position index to generate a unique salt
        (,, positionIndex,) = vtsOrchestrator.getCommit(tokenId);

        positionId = _increaseInternal(poolKey, tokenId, positionIndex, tickLower, tickUpper, liquidity);

        // Attach position to this nft
        // make sure to add the position only after modifying the liquidity
        // because the number of positions is used to generate the salt for the position
        commitToPosition[tokenId][positionIndex] = positionId;
        // Position metadata is managed centrally via PositionRegistry/VTSManager
        // increment the number of positions for the nft
        commitToPositionCount[tokenId]++;

        (positionId, positionIndex) =
            vtsOrchestrator.mintPosition(msgSender(), poolKey, tokenId, tickLower, tickUpper, liquidity);
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
    ) internal onlyIfApproved(msgSender(), tokenId) {
        _mintPositionInternal(poolKey, tokenId, tickLower, tickUpper, liquidity);
    }

    /**
     * @dev This function is used to get the settlement delta for a given user and currency pair
     * @param user The address of the user to get the settlement delta for
     * @param currency0 The address of the currency0 to get the settlement delta for
     * @param currency1 The address of the currency1 to get the settlement delta for
     * @return settlementDelta The settlement delta for the given user and currency pair
     */
    function getSettlementDelta(address user, address currency0, address currency1)
        external
        view
        returns (BalanceDelta)
    {
        return vtsOrchestrator.getSettlementDelta(user, currency0, currency1);
    }

    // ------------------------------------------------------------------------------------------------
    // Checkpoint helpers (RFS / deficit lifecycle)
    // ------------------------------------------------------------------------------------------------

    /// @notice Marks a checkpoint for a single position within a commitment.
    /// @param tokenId The ERC721 token id (commitment NFT id)
    /// @param positionIndex The index of the position within the commitment
    function checkpoint(uint256 tokenId, uint256 positionIndex) external onlyIfApproved(msg.sender, tokenId) {
        vtsOrchestrator.markCheckpoint(tokenId, positionIndex);
    }

    /// @notice Marks checkpoints for multiple (tokenId, positionIndex) pairs.
    /// @param tokenIds Array of commitment NFT ids
    /// @param positionIndexes Array of position indexes within each commitment
    function checkpoint(uint256[] calldata tokenIds, uint256[] calldata positionIndexes) external {
        require(tokenIds.length == positionIndexes.length, "Invalid input lengths");
        for (uint256 i = 0; i < tokenIds.length; i++) {
            _assertApprovedOrOwner(msg.sender, tokenIds[i]);
            vtsOrchestrator.markCheckpoint(tokenIds[i], positionIndexes[i]);
        }
    }

    /// @notice Marks checkpoints for all positions within a single commitment.
    /// @param tokenId The ERC721 token id (commitment NFT id)
    function checkpoint(uint256 tokenId) external onlyIfApproved(msg.sender, tokenId) {
        (,, uint256 positionCount,) = vtsOrchestrator.getCommit(tokenId);
        for (uint256 i = 0; i < positionCount; i++) {
            vtsOrchestrator.markCheckpoint(tokenId, i);
        }
    }

    /// @notice Marks checkpoints for all positions across multiple commitments.
    /// @param tokenIds Array of commitment NFT ids
    function checkpoint(uint256[] calldata tokenIds) external {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            _assertApprovedOrOwner(msg.sender, tokenIds[i]);
            (,, uint256 positionCount,) = vtsOrchestrator.getCommit(tokenIds[i]);
            for (uint256 j = 0; j < positionCount; j++) {
                vtsOrchestrator.markCheckpoint(tokenIds[i], j);
            }
        }
    }

    /// @dev overrides transferFrom to revert if pool manager is locked
    /// @dev mirrors PositionManager and prevents transfers while an unlock session is active (mid-batch), avoiding inconsistent state/reentrancy around router-locked flows.
    function transferFrom(address from, address to, uint256 id) public virtual override onlyIfPoolManagerLocked {
        super.transferFrom(from, to, id);
    }
}
