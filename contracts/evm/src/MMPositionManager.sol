// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, toBalanceDelta} from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency, CurrencyLibrary} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "v4-periphery/lib/v4-core/test/utils/CurrencySettler.sol";
import {ERC721Permit_v4} from "v4-periphery/src/base/ERC721Permit_v4.sol";
import {ReentrancyLock} from "v4-periphery/src/base/ReentrancyLock.sol";
import {Multicall_v4} from "v4-periphery/src/base/Multicall_v4.sol";
import {BaseActionsRouter} from "v4-periphery/src/base/BaseActionsRouter.sol";
import {NativeWrapper} from "./forks/NativeWrapper.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {PositionId, PositionLibrary, PositionModificationHookDataLib} from "./types/Position.sol";
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
import {IMarketVault} from "./interfaces/IMarketVault.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Errors} from "./libraries/Errors.sol";
import {LiquidityUtils} from "./libraries/LiquidityUtils.sol";
import {ILCC} from "./interfaces/ILCC.sol";
import {NonzeroDeltaCount} from "@uniswap/v4-core/src/libraries/NonzeroDeltaCount.sol";
import {IVTSOrchestrator} from "./interfaces/IVTSOrchestrator.sol";
import {Position} from "./types/Position.sol";
import {TransientSlots} from "./libraries/TransientSlots.sol";
import {PositionManagerBase} from "./modules/PositionManagerBase.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyTransfer} from "./libraries/CurrencyTransfer.sol";
import {CurrencyDelta} from "v4-periphery/lib/v4-core/src/libraries/CurrencyDelta.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {MarketHandlerLib} from "./libraries/MarketHandlerLib.sol";
import {ImmutableMarketState} from "./modules/ImmutableMarketState.sol";

contract MMPositionManager is
    ERC721Permit_v4,
    IMMPositionManager,
    ReentrancyLock,
    Multicall_v4,
    BaseActionsRouter,
    NativeWrapper,
    PositionManagerBase,
    ImmutableMarketState
{
    using SafeCast for uint256;
    using PositionLibrary for PositionId;
    using MarketMaker for MarketMaker.State;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using CurrencyTransfer for Currency;
    using CurrencyDelta for Currency;
    using SafeERC20 for IERC20;

    event SignalCommitted(uint256 tokenId);
    event SignalDecommitted(uint256 tokenId, uint256 positionCount);

    ILiquidityHub internal immutable liquidityHub;
    IOracleHelper internal immutable oracleHelper;

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
        UNWRAP_NATIVE, // params: (uint256 amount, bool payerIsUser)
        EXTEND_GRACE_PERIOD, // params: (PoolKey, uint256 tokenId, uint256 positionIndex, uint8 settlementTokenIndex, uint32 verifierIndex, bytes settlementProof)
        TAKE, // params: (Currency currency, address recipient, uint256 maxAmount, bool payerIsUser)
        INCREASE_LIQUIDITY_FROM_DELTAS, // params: (Currency currency, int128 delta, address target)
        MINT_POSITION_FROM_DELTAS, // params: (Currency currency, int128 delta, address target)
        SETTLE_POSITION_FROM_DELTAS, // params: (PoolKey memory poolKey, uint256 tokenId, uint256 positionIndex, bool settleIn0, bool settleIn1)
        DECLARE_UNBACKED_COMMITMENT, // params: (PoolKey memory poolKey, uint256 tokenId, bytes memory liquiditySignal)
        COLLECT_AVAILABLE_LIQUIDITY // params: (address lcc, address recipient, uint256 maxAmount)
    }

    constructor(address _manager, address _marketFactory, address _vtsOrchestrator, address _descriptor, IWETH9 _weth9)
        ERC721Permit_v4("Fiet VRL Commitment Positions Manager", "FIET-VRL-MMP")
        BaseActionsRouter(IPoolManager(_manager))
        NativeWrapper(_weth9)
        PositionManagerBase(_vtsOrchestrator)
        ImmutableMarketState(_marketFactory)
    {
        commitmentDescriptor = _descriptor;
        // TODO: Replace with structure of immutable, extendable contracts.
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

    /// @notice Modifier to check if the commit is valid
    modifier onlyValidCommit(PoolKey memory poolKey, uint256 tokenId) {
        _assertSignalValid(tokenId);
        _;
    }

    /// @notice Enforces that the commit is valid (not expired)
    /// @param tokenId The token id (commit id) to validate
    function _assertSignalValid(uint256 tokenId) internal view {
        (, uint256 expiresAt,,) = vtsOrchestrator.getCommit(tokenId);
        if (expiresAt < block.timestamp) {
            revert Errors.SignalExpired(tokenId);
        }
    }

    function _assertPositionForPool(PoolKey memory poolKey, Position memory position) internal view {
        if (PoolId.unwrap(position.poolId) != PoolId.unwrap(poolKey.toId())) {
            revert Errors.InvalidMarket(poolKey);
        }
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
    function msgSender() public view override(BaseActionsRouter, PositionManagerBase) returns (address) {
        return _getLocker();
    }

    /// @inheritdoc PositionManagerBase
    function _liquidityHub() internal view override returns (ILiquidityHub) {
        return liquidityHub;
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
        assertNonZeroDeltas
    {
        _handleNativeValue();
        _executeActionsWithoutUnlock(actions, params);
    }

    function _handleAction(uint256 action, bytes calldata params) internal virtual override {
        if (action == uint256(MMAction.SETTLE_POSITION)) {
            (
                PoolKey memory poolKey,
                uint256 tokenId,
                uint256 positionIndex,
                int128 amount0,
                int128 amount1,
                bool withUser0,
                bool withUser1
            ) = abi.decode(params, (PoolKey, uint256, uint256, int128, int128, bool, bool));
            _settle(poolKey, tokenId, positionIndex, amount0, amount1, withUser0, withUser1);
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
            _renewSignal(tokenId, liquiditySignal);
            return;
        }
        if (action == uint256(MMAction.SEIZE_POSITION)) {
            (PoolKey memory poolKey, uint256 tokenId, uint256 positionIndex, uint256 amount0, uint256 amount1) =
                abi.decode(params, (PoolKey, uint256, uint256, uint256, uint256));
            // seize is third-party guarantor action; no approval required by design
            _seizePosition(poolKey, tokenId, positionIndex, amount0, amount1);
            return;
        }
        if (action == uint256(MMAction.DECLARE_UNBACKED_COMMITMENT)) {
            (uint256 tokenId, bytes memory liquiditySignal) = abi.decode(params, (uint256, bytes));
            _declareUnbackedCommitment(tokenId, liquiditySignal);
            return;
        }
        if (action == uint256(MMAction.COLLECT_AVAILABLE_LIQUIDITY)) {
            // params: (address lcc, address recipient, uint256 maxAmount)
            (address lcc, address recipient, uint256 maxAmount) = abi.decode(params, (address, address, uint256));
            _collectAvailableLiquidity(lcc, recipient, maxAmount);
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
            _unwrapLCC(lccAddr, _mapPayer(payerIsUser), _mapRecipient(recipient), amount);
            return;
        }
        if (action == uint256(MMAction.WRAP_NATIVE)) {
            // Following Uniswap v4 PositionManager pattern: wrap is a simple WETH9 deposit
            // Syncs WETH9 balance to deltas after wrapping
            uint256 amount = abi.decode(params, (uint256));
            _wrapNative(amount);
            return;
        }
        if (action == uint256(MMAction.UNWRAP_NATIVE)) {
            // Following Uniswap v4 PositionManager pattern: unwrap is a simple WETH9 withdraw
            // Syncs native currency balance to deltas after unwrapping
            (uint256 amount, bool payerIsUser) = abi.decode(params, (uint256, bool));
            _unwrapNative(amount, payerIsUser);
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
        if (action == uint256(MMAction.TAKE)) {
            // params: (Currency currency, address to, uint256 maxAmount)
            (Currency currency, address to, uint256 maxAmount) = abi.decode(params, (Currency, address, uint256));
            _take(currency, to, maxAmount); // address(this) is the sender of the LCCs to the recipient.
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
            _settleFromDeltas(poolKey, tokenId, positionIndex, settleIn0, settleIn1);
            return;
        }
        revert("UnsupportedAction");
    }

    // ------------------------------------------------------------------------------------------------
    // MM Position Manager functions
    // ------------------------------------------------------------------------------------------------

    /// @notice Returns the position information for a given token ID and position index
    /// @param tokenId the ERC721 tokenId (commitment NFT ID)
    /// @param positionIndex the index of the position within the commitment
    /// @return Position the position information
    function getPosition(uint256 tokenId, uint256 positionIndex) public view returns (Position memory, PositionId) {
        return vtsOrchestrator.getPosition(tokenId, positionIndex);
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
    // Native Asset Wrap/Unwrap Operations
    // ------------------------------------------------------------------------------------------------

    /**
     * @dev This function is used to handle the native value
     * @dev Syncs native currency balance to deltas after wrapping so the wrapped amount is available for subsequent operations
     */
    function _handleNativeValue() internal {
        uint256 amount = TransientSlots.readMsgValueOnce();
        if (amount > 0) {
            _syncBalanceToDeltas(CurrencyLibrary.ADDRESS_ZERO);
        }
    }

    /// @notice Wraps native ETH to WETH, updating deltas accordingly
    /// @dev Flow: 1) Debits native delta (take), 2) Wraps ETH→WETH, 3) Credits WETH delta (sync)
    ///      If amount=0, wraps full available native credit.
    /// @param amount The amount to wrap (0 = wrap full available native credit)
    function _wrapNative(uint256 amount) internal {
        uint256 takeAmount = vtsOrchestrator.take(CurrencyLibrary.ADDRESS_ZERO, msgSender(), amount);
        if (amount > 0 && amount > takeAmount) {
            revert Errors.InsufficientBalance(takeAmount, amount);
        } else if (amount == 0) {
            amount = takeAmount;
        }
        if (amount == 0) {
            return;
        }

        _wrap(amount);
        Currency weth = Currency.wrap(address(WETH9));
        // Sync WETH9 balance to deltas so the wrapped amount is available for subsequent operations
        _syncBalanceToDeltas(weth);
    }

    /**
     * @dev This function is used to unwrap native asset
     * @param amount The amount of native asset to unwrap
     * @param payerIsUser Whether the payer is the user
     * @dev Syncs native currency balance to deltas after unwrapping so the unwrapped amount is available for subsequent operations
     */
    function _unwrapNative(uint256 amount, bool payerIsUser) internal {
        Currency weth = Currency.wrap(address(WETH9));
        if (payerIsUser) {
            // Source: User wallet — pull WETH, no delta debit
            address payer = msgSender();
            if (amount == 0) {
                amount = weth.balanceOf(payer);
            }
            weth.transferFrom(payer, address(this), amount);
        } else {
            // Source: Delta credit — debit WETH delta
            uint256 takeAmount = vtsOrchestrator.take(weth, msgSender(), amount);
            if (amount > 0 && amount > takeAmount) {
                revert Errors.InsufficientBalance(takeAmount, amount);
            } else if (amount == 0) {
                amount = takeAmount;
            }
            if (amount == 0) {
                return;
            }
        }
        _unwrap(amount);
        // Sync native currency (ADDRESS_ZERO) balance to deltas so the unwrapped amount is available
        _syncBalanceToDeltas(CurrencyLibrary.ADDRESS_ZERO);
    }

    // ------------------------------------------------------------------------------------------------
    // MM Position Manager functions/actions
    // ------------------------------------------------------------------------------------------------

    /**
     * @dev This function is used to extend the grace period for a position
     * @param poolKey The pool key for the position
     * @param tokenId The token id to extend the grace period for
     * @param positionIndex The position index to extend the grace period for
     * @param settlementTokenIndex The index of the settlement token
     * @param verifierIndex The verifier index
     * @param settlementProof The settlement proof
     */
    function _extendGracePeriod(
        PoolKey memory poolKey,
        uint256 tokenId,
        uint256 positionIndex,
        uint8 settlementTokenIndex,
        uint32 verifierIndex,
        bytes memory settlementProof
    ) internal onlyIfApproved(msgSender(), tokenId) onlyValidCommit(poolKey, tokenId) {
        // extend the grace period for the position
        vtsOrchestrator.extendGracePeriod(
            poolKey, tokenId, positionIndex, settlementTokenIndex, verifierIndex, settlementProof
        );
    }

    /**
     * @dev This function is used to check if the position is being seized
     * @param positionId The position id to check if it is being seized
     * @return bool True if the position is being seized, false otherwise
     */
    function _isSeizing(PositionId positionId) internal view returns (bool) {
        PositionId seizedPositionId = TransientSlots.getSeizedPositionId();
        return PositionId.unwrap(seizedPositionId) == PositionId.unwrap(positionId);
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
        (Position memory position, PositionId positionId) = getPosition(tokenId, positionIndex);
        _assertPositionForPool(poolKey, position);

        // -- Validate that caller is not position owner (approved/owner of NFT)
        // use _isApprovedOrOwner to get the owner/approved wallets of the token id, as position.owner is address(this).
        // Technically, seizing your own position cannot be stopped (via proxy wallets), but there should be no incentive.
        if (_isApprovedOrOwner(msgSender(), tokenId) || position.isActive == false) {
            revert Errors.InvalidPosition(tokenId, positionIndex, positionId);
        }

        // Run internal seize checks to ensure valid seizure. ie. elapsed grace period, etc.
        vtsOrchestrator.onSeize(tokenId, positionIndex);

        // Set transient storage for seizure tracking
        TransientSlots.setSeizedPositionId(positionId);

        // Call _settle - this will return the seizedLiquidityUnits
        // Seizure operations don't interact with user wallets (withUser = false, false)
        uint256 seizedLiquidityUnits =
            _settle(poolKey, tokenId, positionIndex, amount0.toInt128(), amount1.toInt128(), false, false);

        // Prepare hookData
        BalanceDelta seizureSettlementDelta = LiquidityUtils.safeToBalanceDelta(amount0, amount1, true, true);
        bytes memory hookData = PositionModificationHookDataLib.encodeSeizure(
            tokenId, positionIndex, seizureSettlementDelta.amount0(), seizureSettlementDelta.amount1()
        );

        // Call _decreaseInternal with hookData
        _decreaseInternal(
            poolKey, position, PositionLibrary.generateSalt(tokenId, positionIndex), seizedLiquidityUnits, hookData
        );
    }

    /**
     * @dev This function is used to declare an unbacked commitment
     * @param tokenId The token id to declare the commitment for
     * @param liquiditySignal The liquidity signal to declare the commitment for
     */
    function _declareUnbackedCommitment(uint256 tokenId, bytes memory liquiditySignal) internal {
        // declare an unbacked commitment. A third-party guarantor action; no approval required
        vtsOrchestrator.declareUnbackedCommitment(msgSender(), tokenId, liquiditySignal);
    }

    /// @notice Unwrap LCC to underlying asset, either from deltas (requested == 0) or from caller's wallet (requested > 0).
    /// @dev Non-reverting: clamps to available; returns actually unwrapped amount observed via balance delta.
    ///      After unwrapping, syncs the underlying currency balance to deltas for the recipient if recipient is this contract.
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
        uint256 beforeBal = IERC20(underlying).balanceOf(to);

        uint256 toUnwrap;

        // Unwrap from locker's deltas: take from MMPM-held deltas on behalf of locker.
        if (from == address(this)) {
            toUnwrap = vtsOrchestrator.take(lccCurrency, msgSender(), requested);
        } else {
            toUnwrap = lcc.balanceOf(from);
            // Clamp toUnwrap by the amount requested. Otherwise, use whatever balance is available.
            if (requested > 0 && toUnwrap > requested) {
                toUnwrap = requested;
            }
        }

        if (toUnwrap > 0) {
            if (from != address(this)) {
                // Transfer to this contract first.
                lcc.safeTransferFrom(from, address(this), toUnwrap);
            }
            // Route through LiquidityHub to leverage reserve tracking and settlement queuing
            liquidityHub.unwrapTo(lccAddr, to, toUnwrap);
        }

        // Compute actually unwrapped by observing recipient balance delta
        // Note: this requires 'to' to not be malicious reentrant contract masking balance?
        unwrapped = IERC20(underlying).balanceOf(to) - beforeBal;

        // Sync the underlying currency balance to deltas if recipient is this contract
        // This makes the unwrapped underlying available for subsequent operations in the same batch
        if (to == address(this) && unwrapped > 0) {
            _syncBalanceToDeltas(Currency.wrap(underlying));
        }
    }

    /**
     * @dev Collects available liquidity from the settlement queue for the caller.
     * @dev Allows for subsequent TAKE over amounts in delta.
     * @param lcc The LCC token address to process settlement for
     * @param recipient The recipient address to receive the underlying assets
     * @param maxAmount The maximum amount to settle
     */
    function _collectAvailableLiquidity(address lcc, address recipient, uint256 maxAmount) internal {
        address sender = msgSender();
        uint256 queued = liquidityHub.settleQueue(lcc, sender);

        if (queued > 0) {
            liquidityHub.processSettlementFor(lcc, recipient, maxAmount);
        }

        // If there's any persisted deltas, prime them to allow the locker to TAKE, or SETTLE...
        vtsOrchestrator.primeUnderlyingCredits(sender, Currency.wrap(lcc));
    }

    /**
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
     * @param withUser0 Whether to settle the position for token0 with deposit from the user's balance, or withdraw to the user's balance
     * @param withUser1 Whether to settle the position for token1 with deposit from the user's balance, or withdraw to the user's balance
     * @return seizedLiquidityUnits The amount of liquidity units seized during seizure path (0 if not seizing)
     *
     * @notice Value Transfer Flow:
     *         Transfers flow from MMPM to MarketVault (MV) and PoolManager (PM) rather than through VTSOrchestrator (VTSO).
     *         This ensures deposits (including native ETH) are handled correctly, where MMPM can on-transfer to MV
     *         in cases where ERC20.transferFrom is unavailable (e.g., native ETH deposits via msg.value).
     *         VTSO is used exclusively for delta management and authentication, maintaining clean separation of concerns.
     */
    function _settle(
        PoolKey memory poolKey,
        uint256 tokenId,
        uint256 positionIndex,
        int128 amount0,
        int128 amount1,
        bool withUser0,
        bool withUser1
    ) internal returns (uint256) {
        if (amount0 == 0 && amount1 == 0) {
            // Cannot settle 0 amounts for both assets.
            revert Errors.InvalidDelta(0, 0);
        }

        (Position memory position, PositionId positionId) = getPosition(tokenId, positionIndex);
        _assertPositionForPool(poolKey, position);

        bool isSeizing = _isSeizing(positionId);

        // Access control: if not seizing, require approval
        if (!isSeizing) {
            _assertSignalValid(tokenId);
            _assertApprovedOrOwner(msgSender(), tokenId);
        }

        (BalanceDelta settlementDelta, bool rfsOpen, uint256 seizedLiquidityUnits) = vtsOrchestrator.onMMSettle(
            positionId, poolKey.currency0, poolKey.currency1, toBalanceDelta(amount0, amount1), isSeizing
        );

        // Convert LCC currencies to underlying currencies for settlement
        Currency underlying0 = _lccToUnderlyingCurrency(poolKey.currency0);
        Currency underlying1 = _lccToUnderlyingCurrency(poolKey.currency1);

        // Determine Vault (ProxyHook)
        IMarketVault vault = MarketHandlerLib.getVault(marketFactory, poolKey.toId());
        address vaultAddress = address(vault);

        // Determine sender for user interactions
        address sender = msgSender();

        int128 delta0 = settlementDelta.amount0();
        int128 delta1 = settlementDelta.amount1();

        // // Consume any self positive deltas first for withdrawals
        // Consumption/withdrawal of any currency with a positive delta is handled by _take()

        // Handle Deposits (Pull underlying from User to Vault)
        // withUser flags determine whether to interact with user's wallet
        if (delta0 < 0 && withUser0) {
            underlying0.transferFrom(sender, vaultAddress, LiquidityUtils.safeInt128ToUint256(delta0));
        }
        if (delta1 < 0 && withUser1) {
            underlying1.transferFrom(sender, vaultAddress, LiquidityUtils.safeInt128ToUint256(delta1));
        }

        // Execute Settlement via Vault (with remaining delta after self-consumption)
        BalanceDelta remainingDelta = toBalanceDelta(delta0, delta1);
        BalanceDelta usedDelta = vault.tryModifyLiquidities(remainingDelta);

        // Handle Withdrawals (Push underlying from Vault to User)
        if (usedDelta.amount0() > 0 && withUser0) {
            underlying0.transfer(sender, LiquidityUtils.safeInt128ToUint256(usedDelta.amount0()));
        }
        if (usedDelta.amount1() > 0 && withUser1) {
            underlying1.transfer(sender, LiquidityUtils.safeInt128ToUint256(usedDelta.amount1()));
        }

        // Handle shortfall: persist any unfulfilled withdrawal as credit owed to user
        BalanceDelta shortfall = remainingDelta - usedDelta;
        if (shortfall.amount0() > 0 || shortfall.amount1() > 0) {
            // Shortfall represents underlying that couldn't be withdrawn from vault
            // This will be persisted and claimable later when liquidity becomes available
            // TODO: persist?
        }

        // Return seized liquidity units (0 if not seizing)
        return seizedLiquidityUnits;
    }

    /**
     * @dev This function is used to renew a signal
     * @param tokenId The token id to renew the signal for
     * @param liquiditySignal The liquidity signal to renew the signal for
     */
    function _renewSignal(uint256 tokenId, bytes memory liquiditySignal) internal onlyIfApproved(msgSender(), tokenId) {
        vtsOrchestrator.renewSignal(tokenId, liquiditySignal);
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
        // this logic would be taken out and the user would have to burn each position individually
        // get all positions attached to this token id
        // uint256 positionCount = commitToPositionCount[tokenId];
        // get the position count from the vts orchestrator
        // ? this logic would be taken out and the user would have to burn each position individually
        (,, uint256 positionCount,) = vtsOrchestrator.getCommit(tokenId);
        if (positionCount > 0) {
            revert Errors.CommitNotEmpty(tokenId);
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
        onlyValidCommit(poolKey, tokenId)
    {
        (Position memory position,) = getPosition(tokenId, positionIndex);
        _assertPositionForPool(poolKey, position);
        uint256 completeLiquidity = uint256(position.liquidity);
        _decreaseInternal(
            poolKey,
            position,
            PositionLibrary.generateSalt(tokenId, positionIndex),
            completeLiquidity,
            PositionModificationHookDataLib.encode(tokenId, positionIndex)
        );
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
        // Validate position within _increase, but not within _increaseInternal (called by _mint);
        (Position memory position,) = getPosition(tokenId, positionIndex);
        _assertPositionForPool(poolKey, position);
        _increaseInternal(poolKey, tokenId, positionIndex, tickLower, tickUpper, liquidity);
    }

    /**
     * @dev Internal function to increase liquidity for an existing position.
     *      Flow:
     *      1. Encode hookData with commitId and positionIndex
     *      2. Call _modifySyntheticLiquidity which:
     *         - Calls poolManager.modifyLiquidity (triggers CoreHook -> VTSOrchestrator.processPosition)
     *         - VTSOrchestrator handles: fee accounting, LCC issuance, delta accounting
     *         - Settles with poolManager
     *
     * @param poolKey The pool key for the position
     * @param tokenId The token id (commit id)
     * @param positionIndex The position index within the commit
     * @param tickLower The lower tick of the position
     * @param tickUpper The upper tick of the position
     * @param liquidity The liquidity amount to add
     * @return positionId The position ID
     */
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
            salt: PositionLibrary.generateSalt(tokenId, positionIndex)
        });

        // Generate position ID for return
        positionId = PositionLibrary.generateId(address(this), params);

        // Encode hook data with commitId and positionIndex
        bytes memory hookData = PositionModificationHookDataLib.encode(tokenId, positionIndex);

        // Single call: modify liquidity + settle
        // VTSOrchestrator.processPosition handles: fee accounting, LCC issuance, delta accounting
        _modifySyntheticLiquidity(poolKey, params, hookData);
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
        // Validate position within _increaseFromDeltas, but not within _increaseInternal (called by _mint);
        (Position memory position,) = getPosition(tokenId, positionIndex);
        _assertPositionForPool(poolKey, position);

        // Compute liquidity from LCC credits (via router helper)
        uint256 liquidityFromDeltas = _getLiquidityFromDeltas(poolKey, address(this), tickLower, tickUpper);

        _increaseInternal(poolKey, tokenId, positionIndex, tickLower, tickUpper, liquidityFromDeltas);
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
        uint256 liquidityFromDeltas = _getLiquidityFromDeltas(poolKey, address(this), tickLower, tickUpper);

        _mintPositionInternal(poolKey, tokenId, tickLower, tickUpper, liquidityFromDeltas);
    }

    /**
     * @dev This function is used to settle a position from deltas
     * @param poolKey The pool key for the position
     * @param tokenId The token id to settle the position for
     * @param positionIndex The position index to settle the position for
     * @param settleIn0 Whether to settle in token0
     * @param settleIn1 Whether to settle in token1
     */
    // TODO: Merge in with _settle?
    function _settleFromDeltas(
        PoolKey memory poolKey,
        uint256 tokenId,
        uint256 positionIndex,
        bool settleIn0,
        bool settleIn1
    ) internal {
        // Settlement happens in underlying terms, so we need to check underlying credits, not LCC credits
        // Note: settleIn0/settleIn1 flags determine direction. After onMMSettle negates the delta:
        //       true = negative amount = deposit (settle IN), false = positive amount = withdraw (settle OUT)
        (uint256 credit0, uint256 credit1) = _getFullCreditPair(
            _lccToUnderlyingCurrency(poolKey.currency0), _lccToUnderlyingCurrency(poolKey.currency1), address(this)
        );
        BalanceDelta sDelta = LiquidityUtils.safeToBalanceDelta(credit0, credit1, settleIn0, settleIn1);

        // Includes position validation within _settle
        // settleIn flags determine which currencies interact with user wallet
        _settle(poolKey, tokenId, positionIndex, sDelta.amount0(), sDelta.amount1(), settleIn0, settleIn1);
    }

    /**
     * @dev Internal logic for decreasing position liquidity.
     *      Flow:
     *      1. Encode hookData with commitId and positionIndex (or use provided hookData for seizure)
     *      2. Call _modifySyntheticLiquidity which:
     *         - Calls poolManager.modifyLiquidity (triggers CoreHook -> VTSOrchestrator.processPosition)
     *         - VTSOrchestrator handles: fee accounting, LCC cancellation, delta accounting
     *         - Settles with poolManager
     *
     * @param poolKey The pool key for the position
     * @param position The position to decrease liquidity for (must be validated by caller)
     * @param salt The salt of the position
     * @param amountToDecrease The amount of liquidity to decrease
     * @param hookData The hook data to pass to modifyLiquidity (for seizure operations)
     */
    function _decreaseInternal(
        PoolKey memory poolKey,
        Position memory position,
        bytes32 salt,
        uint256 amountToDecrease,
        bytes memory hookData
    ) internal {
        // Validate liquidity is not over available
        uint256 posLiq = uint256(position.liquidity);
        if (amountToDecrease > posLiq) {
            revert Errors.InvalidAmount(amountToDecrease, posLiq);
        }

        // Clamp to max int256
        if (amountToDecrease > uint256(type(int256).max)) {
            amountToDecrease = uint256(type(int256).max);
        }

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: position.tickLower,
            tickUpper: position.tickUpper,
            liquidityDelta: -amountToDecrease.toInt256(),
            salt: salt
        });

        // Single call: modify liquidity + settle
        // VTSOrchestrator.processPosition handles: fee accounting, LCC cancellation, delta accounting
        _modifySyntheticLiquidity(poolKey, params, hookData);

        // Persist unavailable underlying credits from MMPM's delta against the locker
        // Only persists the difference between MMPM's delta and balance (unavailable portion)
        vtsOrchestrator.persistUnavailableUnderlyingCredits(
            address(this), msgSender(), poolKey.currency0, poolKey.currency1
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
        onlyValidCommit(poolKey, tokenId)
    {
        // Get position and validate it belongs to the pool
        (Position memory position,) = getPosition(tokenId, positionIndex);
        _assertPositionForPool(poolKey, position);

        // Call internal logic
        _decreaseInternal(
            poolKey,
            position,
            PositionLibrary.generateSalt(tokenId, positionIndex),
            amountToDecrease,
            PositionModificationHookDataLib.encode(tokenId, positionIndex)
        );
    }

    /**
     * @dev Internal function to mint a new position.
     *      Flow:
     *      1. Encode hookData with commitId and positionIndex
     *      2. Call _modifySyntheticLiquidity which:
     *         - Calls poolManager.modifyLiquidity (triggers CoreHook -> VTSOrchestrator.processPosition)
     *         - VTSOrchestrator handles: fee accounting, LCC issuance, position linking, delta accounting
     *         - Settles with poolManager
     *
     * @param poolKey The pool key for the position
     * @param tokenId The token id (commit id)
     * @param tickLower The lower tick of the position
     * @param tickUpper The upper tick of the position
     * @param liquidity The liquidity amount to mint
     * @return positionId The position ID
     * @return positionIndex The position index within the commit
     */
    function _mintPositionInternal(
        PoolKey memory poolKey,
        uint256 tokenId,
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidity
    ) internal returns (PositionId positionId, uint256 positionIndex) {
        // Prevent overflow when converting to int256/int128 for modifyLiquidity
        if (liquidity > type(uint128).max) {
            revert Errors.InvalidAmount(liquidity, type(uint128).max);
        }

        // Get the current position count to use as the positionIndex for salt generation
        (,, positionIndex,) = vtsOrchestrator.getCommit(tokenId);

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: liquidity.toInt256(),
            salt: PositionLibrary.generateSalt(tokenId, positionIndex)
        });

        // Generate position ID
        positionId = PositionLibrary.generateId(address(this), params);

        // Encode hook data with commitId and positionIndex
        bytes memory hookData = PositionModificationHookDataLib.encode(tokenId, positionIndex);

        // Single call: modify liquidity + settle
        // VTSOrchestrator.processPosition handles: fee accounting, LCC issuance, position linking, delta accounting
        _modifySyntheticLiquidity(poolKey, params, hookData);
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
    ) internal onlyIfApproved(msgSender(), tokenId) onlyValidCommit(poolKey, tokenId) {
        _mintPositionInternal(poolKey, tokenId, tickLower, tickUpper, liquidity);
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
