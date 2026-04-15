// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ILCC} from "../interfaces/ILCC.sol";
import {IMarketVault} from "../interfaces/IMarketVault.sol";
import {ICanonicalVault} from "../interfaces/ICanonicalVault.sol";
import {ILiquidityHub} from "../interfaces/ILiquidityHub.sol";
import {VaultSettlementIntent} from "../types/VTS.sol";
import {Errors} from "../libraries/Errors.sol";
import {ReentrancyGuardTransient} from "openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
import {ImmutableMarketState} from "./ImmutableMarketState.sol";

/// @notice Thin per-market facade over the factory-scoped CanonicalVault.
abstract contract MarketVaultFacade is IMarketVault, ImmutableMarketState, ReentrancyGuardTransient {
    using PoolIdLibrary for PoolKey;

    event SwapDeficit(PoolId indexed poolId, address indexed lccToken, address deficitRecipient, uint256 deficitAmount);
    event MarketRegistered(bytes32 indexed marketId);
    event MarketLiquidityAdded(bytes32 indexed marketId, uint256 amount);
    event MarketLiquidityUsed(bytes32 indexed marketId, uint256 amount);
    event LiquidityAddedToVault(address indexed sender, address indexed from, address currency, uint256 amount);
    event LiquidityTakenFromVault(address indexed sender, address indexed recipient, address currency, uint256 amount);

    modifier onlyProtocolBounds() {
        if (!marketFactory.bounds(msg.sender)) revert Errors.InvalidSender();
        _;
    }

    modifier onlyVTS() {
        if (msg.sender != address(marketFactory.vts())) revert Errors.InvalidSender();
        _;
    }

    constructor(address _marketFactory) ImmutableMarketState(_marketFactory) {}

    function _underlying() internal view virtual returns (Currency currency0, Currency currency1);

    function _lccs() internal view virtual returns (ILCC lccToken0, ILCC lccToken1);

    function _marketId() internal view virtual returns (bytes32);

    function _liquidityHub() internal view returns (ILiquidityHub) {
        return marketFactory.liquidityHub();
    }

    function _canonicalVault() internal view returns (ICanonicalVault vault) {
        address canonical = marketFactory.canonicalVault();
        if (canonical == address(0)) revert Errors.InvalidAddress(canonical);
        vault = ICanonicalVault(canonical);
    }

    /// @notice Core pool id (`bytes32`) this facade routes for.
    function marketId() external view returns (bytes32) {
        return _marketId();
    }

    /// @notice Factory-scoped canonical custody contract backing all markets for this factory.
    function canonicalVault() external view returns (address) {
        return address(_canonicalVault());
    }

    /// @notice LCC token pair for this market (sorted per pool key conventions).
    /// @return lccToken0 First LCC ERC20 address.
    /// @return lccToken1 Second LCC ERC20 address.
    function lccs() external view returns (address lccToken0, address lccToken1) {
        (ILCC l0, ILCC l1) = _lccs();
        return (address(l0), address(l1));
    }

    function inMarketBalanceOf(Currency currency) public view virtual returns (uint256) {
        return _canonicalVault().inMarketBalanceOf(_marketId(), currency);
    }

    function dryModifyLiquidities(BalanceDelta balanceDelta) public view virtual returns (BalanceDelta) {
        (Currency currency0, Currency currency1) = _coreUnderlying();
        return _canonicalVault().dryModifyLiquidities(_marketId(), currency0, currency1, balanceDelta);
    }

    function dryModifyLiquidities(VaultSettlementIntent calldata settlementIntent)
        public
        view
        virtual
        returns (BalanceDelta)
    {
        (Currency currency0, Currency currency1) = _coreUnderlying();
        return _canonicalVault().dryModifyLiquidities(_marketId(), currency0, currency1, settlementIntent);
    }

    function modifyLiquidities(BalanceDelta balanceDelta) external virtual onlyProtocolBounds nonReentrant {
        (Currency currency0, Currency currency1) = _coreUnderlying();
        (ILCC lcc0, ILCC lcc1) = _lccs();
        BalanceDelta usedDelta = _canonicalVault()
            .modifyLiquidities(
                _marketId(), currency0, currency1, address(lcc0), address(lcc1), balanceDelta, msg.sender
            );
        if (BalanceDelta.unwrap(usedDelta) != BalanceDelta.unwrap(balanceDelta)) {
            revert Errors.InsufficientLiquidityToTake();
        }
    }

    function modifyLiquidities(VaultSettlementIntent calldata settlementIntent)
        external
        virtual
        onlyProtocolBounds
        nonReentrant
    {
        (Currency currency0, Currency currency1) = _coreUnderlying();
        (ILCC lcc0, ILCC lcc1) = _lccs();
        BalanceDelta usedDelta = _canonicalVault()
            .modifyLiquidities(
                _marketId(), currency0, currency1, address(lcc0), address(lcc1), settlementIntent, msg.sender
            );
        if (BalanceDelta.unwrap(usedDelta) != BalanceDelta.unwrap(settlementIntent.requestedDelta)) {
            revert Errors.InsufficientLiquidityToTake();
        }
    }

    function tryModifyLiquidities(BalanceDelta balanceDelta)
        external
        virtual
        onlyProtocolBounds
        nonReentrant
        returns (BalanceDelta)
    {
        (Currency currency0, Currency currency1) = _coreUnderlying();
        (ILCC lcc0, ILCC lcc1) = _lccs();
        return _canonicalVault()
            .modifyLiquidities(
                _marketId(), currency0, currency1, address(lcc0), address(lcc1), balanceDelta, msg.sender
            );
    }

    function tryModifyLiquidities(VaultSettlementIntent calldata settlementIntent)
        external
        virtual
        onlyProtocolBounds
        nonReentrant
        returns (BalanceDelta)
    {
        (Currency currency0, Currency currency1) = _coreUnderlying();
        (ILCC lcc0, ILCC lcc1) = _lccs();
        return _canonicalVault()
            .modifyLiquidities(
                _marketId(), currency0, currency1, address(lcc0), address(lcc1), settlementIntent, msg.sender
            );
    }

    function tryModifyLiquiditiesWithRecipient(BalanceDelta balanceDelta, address recipient)
        external
        virtual
        onlyProtocolBounds
        nonReentrant
        returns (BalanceDelta)
    {
        if (recipient == address(0)) revert Errors.InvalidAddress(recipient);
        (Currency currency0, Currency currency1) = _coreUnderlying();
        (ILCC lcc0, ILCC lcc1) = _lccs();
        return _canonicalVault()
            .modifyLiquidities(_marketId(), currency0, currency1, address(lcc0), address(lcc1), balanceDelta, recipient);
    }

    function tryModifyLiquiditiesWithRecipient(VaultSettlementIntent calldata settlementIntent, address recipient)
        external
        virtual
        onlyProtocolBounds
        nonReentrant
        returns (BalanceDelta)
    {
        if (recipient == address(0)) revert Errors.InvalidAddress(recipient);
        (Currency currency0, Currency currency1) = _coreUnderlying();
        (ILCC lcc0, ILCC lcc1) = _lccs();
        return _canonicalVault()
            .modifyLiquidities(
                _marketId(), currency0, currency1, address(lcc0), address(lcc1), settlementIntent, recipient
            );
    }

    function _settleObligations(PoolKey memory) internal virtual {
        (ILCC lcc0, ILCC lcc1) = _lccs();
        _canonicalVault().settleObligations(_marketId(), address(lcc0), address(lcc1));
    }

    function _settleObligationsForLCC(ILCC lccToken) internal virtual {
        _canonicalVault().settleObligationsForLCC(_marketId(), address(lccToken));
    }

    function _cancelLCCWithDeficit(PoolKey memory poolKey, ILCC lccToken, uint256 amount, address deficitRecipient)
        internal
        returns (uint256 amountToCancel)
    {
        amountToCancel =
            _canonicalVault().cancelLCCWithDeficit(_marketId(), address(lccToken), amount, deficitRecipient);
        if (amountToCancel < amount && deficitRecipient != address(0)) {
            emit SwapDeficit(poolKey.toId(), address(lccToken), deficitRecipient, amount - amountToCancel);
        }
    }

    function _settleUnderlyingToVaultFromHub(ILCC lccToken, uint256 amount) internal virtual {
        _canonicalVault().settleUnderlyingToVaultFromHub(_marketId(), address(lccToken), amount);
    }

    function _takeUnderlyingClaims(Currency underlyingCurrency, uint256 amount) internal {
        _canonicalVault().takeUnderlyingClaims(_marketId(), underlyingCurrency, amount);
    }

    function _settleUnderlyingFromClaims(Currency underlyingCurrency, uint256 amount) internal {
        _canonicalVault().settleUnderlyingFromClaims(_marketId(), underlyingCurrency, amount);
    }

    function _issueAndSettleLcc(address lccToken, uint256 amount) internal {
        _canonicalVault().issueAndSettleLcc(_marketId(), lccToken, amount);
    }

    function _takeLccFromPoolManager(address lccToken, uint256 amount) internal {
        _canonicalVault().takeLccFromPoolManager(_marketId(), lccToken, amount);
    }

    function _increaseLiquidityReserve(Currency underlyingCurrency, uint256 amount) internal {
        _canonicalVault().increaseLiquidityReserve(_marketId(), underlyingCurrency, amount);
    }

    function _decreaseLiquidityReserve(Currency underlyingCurrency, uint256 amount) internal {
        _canonicalVault().decreaseLiquidityReserve(_marketId(), underlyingCurrency, amount);
    }

    function decreaseLiquidityReserve(Currency underlyingCurrency, uint256 amount) external onlyVTS {
        _decreaseLiquidityReserve(underlyingCurrency, amount);
    }

    function increaseLiquidityReserve(Currency underlyingCurrency, uint256 amount) external onlyVTS {
        _increaseLiquidityReserve(underlyingCurrency, amount);
    }

    function _coreUnderlying() internal view returns (Currency currency0, Currency currency1) {
        (ILCC lcc0, ILCC lcc1) = _lccs();
        currency0 = Currency.wrap(lcc0.underlying());
        currency1 = Currency.wrap(lcc1.underlying());
    }

    /// @notice Accepts ETH only from the canonical vault, `address(0)` (selfdestruct-style origin), factory bounds, or this contract.
    receive() external payable virtual {
        address canonical = marketFactory.canonicalVault();
        if (
            msg.sender != canonical && msg.sender != address(0) && !marketFactory.bounds(msg.sender)
                && msg.sender != address(this)
        ) {
            revert Errors.InvalidEthSender();
        }
    }
}
