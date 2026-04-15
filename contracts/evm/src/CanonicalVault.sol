// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC6909Claims} from "@uniswap/v4-core/src/interfaces/external/IERC6909Claims.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {CurrencyTransfer} from "./libraries/CurrencyTransfer.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";
import {ILCC} from "./interfaces/ILCC.sol";
import {ILiquidityHub} from "./interfaces/ILiquidityHub.sol";
import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
import {ICanonicalVault} from "./interfaces/ICanonicalVault.sol";
import {Errors} from "./libraries/Errors.sol";
import {LiquidityUtils} from "./libraries/LiquidityUtils.sol";
import {VaultSettlementIntent} from "./types/VTS.sol";

/**
 * @title CanonicalVault
 * @notice Factory-scoped custody layer that owns PoolManager claims and per-market underlying reserves.
 * @dev Owner-level same-underlying credits are fungible at the VTS layer, but actual custody remains market-scoped.
 *      This contract is the bridge between those two truths:
 *      - each market keeps its own underlying sub-ledger in `marketLiquidityReserves`;
 *      - same-underlying credit produced in one market can fund another market only through explicit VTS-provided
 *        settlement intent;
 *      - this contract does not own any hidden transient reconciliation subsystem.
 */
contract CanonicalVault is ICanonicalVault, ImmutableState, ReentrancyGuardTransient {
    using CurrencySettler for Currency;
    using CurrencyTransfer for Currency;

    /// @dev Immutable market metadata used to validate that only registered assets mutate a market's custody state.
    struct MarketConfig {
        address facade;
        address lcc0;
        address lcc1;
        address underlying0;
        address underlying1;
        bool exists;
    }

    event MarketRegistered(bytes32 indexed marketId, address facade, address lcc0, address lcc1);
    event LiquidityAddedToVault(bytes32 indexed marketId, address sender, address currency, uint256 amount);
    event LiquidityTakenFromVault(bytes32 indexed marketId, address recipient, address currency, uint256 amount);
    event SwapDeficit(PoolId indexed poolId, address lccToken, address deficitRecipient, uint256 deficitAmount);

    ILiquidityHub public immutable liquidityHub;
    address public immutable marketFactory;

    mapping(bytes32 => MarketConfig) internal markets;
    mapping(address => bytes32) public facadeToMarket;
    mapping(bytes32 => mapping(address => uint256)) public marketLiquidityReserves;
    mapping(address => uint256) public totalUnderlyingReserves;

    constructor(address _poolManager, address _liquidityHub, address _marketFactory)
        ImmutableState(IPoolManager(_poolManager))
    {
        if (_liquidityHub == address(0)) revert Errors.InvalidAddress(_liquidityHub);
        if (_marketFactory == address(0)) revert Errors.InvalidAddress(_marketFactory);
        liquidityHub = ILiquidityHub(_liquidityHub);
        marketFactory = _marketFactory;
    }

    modifier onlyFactory() {
        if (msg.sender != marketFactory) revert Errors.InvalidSender();
        _;
    }

    modifier onlyMarketFacade(bytes32 marketId) {
        MarketConfig storage cfg = _marketConfig(marketId);
        if (cfg.facade != msg.sender || !IMarketFactory(marketFactory).isMarketFacade(marketId, msg.sender)) {
            revert Errors.InvalidSender();
        }
        _;
    }

    modifier onlyVTS() {
        if (msg.sender != address(IMarketFactory(marketFactory).vts())) {
            revert Errors.InvalidSender();
        }
        _;
    }

    function registerMarket(
        bytes32 marketId,
        address facade,
        address lcc0,
        address lcc1,
        address underlying0,
        address underlying1
    ) external onlyFactory {
        if (marketId == bytes32(0)) {
            revert Errors.InvariantViolated("CanonicalVault: zero marketId unsupported");
        }
        if (facade == address(0) || lcc0 == address(0) || lcc1 == address(0)) {
            revert Errors.InvalidSender();
        }
        if (markets[marketId].exists || facadeToMarket[facade] != bytes32(0)) {
            revert Errors.InvariantViolated("CanonicalVault: market already registered");
        }
        markets[marketId] = MarketConfig({
            facade: facade, lcc0: lcc0, lcc1: lcc1, underlying0: underlying0, underlying1: underlying1, exists: true
        });
        facadeToMarket[facade] = marketId;
        IERC6909Claims(address(poolManager)).setOperator(facade, true);
        emit MarketRegistered(marketId, facade, lcc0, lcc1);
    }

    function inMarketBalanceOf(bytes32 marketId, Currency currency) external view returns (uint256) {
        _assertUnderlyingConfigured(_marketConfig(marketId), currency);
        return marketLiquidityReserves[marketId][Currency.unwrap(currency)];
    }

    function dryModifyLiquidities(bytes32 marketId, Currency currency0, Currency currency1, BalanceDelta balanceDelta)
        external
        view
        onlyMarketFacade(marketId)
        returns (BalanceDelta)
    {
        return _dryModifyLiquidities(
            marketId,
            currency0,
            currency1,
            VaultSettlementIntent({
                requestedDelta: balanceDelta, creditBackedWithdrawal0: 0, creditBackedWithdrawal1: 0
            })
        );
    }

    function dryModifyLiquidities(
        bytes32 marketId,
        Currency currency0,
        Currency currency1,
        VaultSettlementIntent calldata settlementIntent
    ) external view onlyMarketFacade(marketId) returns (BalanceDelta) {
        return _dryModifyLiquidities(marketId, currency0, currency1, settlementIntent);
    }

    function modifyLiquidities(
        bytes32 marketId,
        Currency currency0,
        Currency currency1,
        address lcc0,
        address lcc1,
        BalanceDelta balanceDelta,
        address recipient
    ) external onlyMarketFacade(marketId) nonReentrant returns (BalanceDelta usedDelta) {
        VaultSettlementIntent memory settlementIntent = VaultSettlementIntent({
            requestedDelta: balanceDelta, creditBackedWithdrawal0: 0, creditBackedWithdrawal1: 0
        });
        return _modifyLiquidities(marketId, currency0, currency1, lcc0, lcc1, settlementIntent, recipient);
    }

    function modifyLiquidities(
        bytes32 marketId,
        Currency currency0,
        Currency currency1,
        address lcc0,
        address lcc1,
        VaultSettlementIntent calldata settlementIntent,
        address recipient
    ) external onlyMarketFacade(marketId) nonReentrant returns (BalanceDelta usedDelta) {
        return _modifyLiquidities(marketId, currency0, currency1, lcc0, lcc1, settlementIntent, recipient);
    }

    function _modifyLiquidities(
        bytes32 marketId,
        Currency currency0,
        Currency currency1,
        address lcc0,
        address lcc1,
        VaultSettlementIntent memory settlementIntent,
        address recipient
    ) internal returns (BalanceDelta usedDelta) {
        MarketConfig storage cfg = _marketConfig(marketId);
        _assertUnderlyingPairConfigured(cfg, currency0, currency1);
        _assertLccPairConfigured(cfg, lcc0, lcc1);
        usedDelta = _dryModifyLiquidities(marketId, currency0, currency1, settlementIntent);
        _modifyLiquidityWithRecipient(marketId, currency0, currency1, settlementIntent, usedDelta, recipient);
        _finaliseModifyLiquidity(marketId, lcc0, lcc1, settlementIntent.requestedDelta, usedDelta, recipient);
    }

    function settleObligations(bytes32 marketId, address lcc0, address lcc1) external onlyMarketFacade(marketId) {
        _settleObligationsForLCC(marketId, ILCC(lcc0));
        _settleObligationsForLCC(marketId, ILCC(lcc1));
    }

    function settleObligationsForLCC(bytes32 marketId, address lccToken) external onlyMarketFacade(marketId) {
        _settleObligationsForLCC(marketId, ILCC(lccToken));
    }

    function settleUnderlyingToVaultFromHub(bytes32 marketId, address lccToken, uint256 amount)
        external
        onlyMarketFacade(marketId)
    {
        if (amount == 0) return;
        _assertLccConfigured(_marketConfig(marketId), lccToken);
        liquidityHub.prepareSettle(lccToken, amount);
        Currency uaCurrency = Currency.wrap(ILCC(lccToken).underlying());
        address payer = uaCurrency.isAddressZero() ? address(this) : address(liquidityHub);
        _settleUnderlyingToVaultFromSender(marketId, uaCurrency, payer, amount);
    }

    function cancelLCCWithDeficit(bytes32 marketId, address lccToken, uint256 amount, address deficitRecipient)
        external
        onlyMarketFacade(marketId)
        returns (uint256 amountToCancel)
    {
        _assertLccConfigured(_marketConfig(marketId), lccToken);
        ILCC lcc = ILCC(lccToken);
        uint256 available = marketLiquidityReserves[marketId][lcc.underlying()];
        uint256 deficitAmount;
        if (amount > available) {
            amountToCancel = available;
            deficitAmount = amount - available;
        } else {
            amountToCancel = amount;
        }

        if (deficitAmount > 0 && deficitRecipient == address(0)) {
            revert Errors.InvariantViolated("MarketVault: deficit requires recipient");
        }

        if (amountToCancel > 0) {
            liquidityHub.cancel(lccToken, address(this), amountToCancel);
        }

        if (deficitAmount > 0) {
            Currency.wrap(lccToken).transfer(deficitRecipient, deficitAmount);
            liquidityHub.queueForTransferRecipient(lccToken, deficitRecipient, deficitAmount);
            emit SwapDeficit(PoolId.wrap(marketId), lccToken, deficitRecipient, deficitAmount);
        }
    }

    function takeUnderlyingClaims(bytes32 marketId, Currency underlyingCurrency, uint256 amount)
        external
        onlyMarketFacade(marketId)
    {
        if (amount == 0) return;
        _assertUnderlyingConfigured(_marketConfig(marketId), underlyingCurrency);
        underlyingCurrency.take(poolManager, address(this), amount, true);
        _incrementReserve(marketId, underlyingCurrency, amount);
    }

    function settleUnderlyingFromClaims(bytes32 marketId, Currency underlyingCurrency, uint256 amount)
        external
        onlyMarketFacade(marketId)
    {
        if (amount == 0) return;
        _assertUnderlyingConfigured(_marketConfig(marketId), underlyingCurrency);
        _decrementReserve(marketId, underlyingCurrency, amount);
        underlyingCurrency.settle(poolManager, address(this), amount, true);
    }

    function issueAndSettleLcc(bytes32 marketId, address lccToken, uint256 amount) external onlyMarketFacade(marketId) {
        if (amount == 0) return;
        _assertLccConfigured(_marketConfig(marketId), lccToken);
        liquidityHub.issue(lccToken, address(this), amount);
        Currency.wrap(lccToken).settle(poolManager, address(this), amount, false);
    }

    function takeLccFromPoolManager(bytes32 marketId, address lccToken, uint256 amount)
        external
        onlyMarketFacade(marketId)
    {
        if (amount == 0) return;
        _assertLccConfigured(_marketConfig(marketId), lccToken);
        Currency.wrap(lccToken).take(poolManager, address(this), amount, false);
    }

    function increaseLiquidityReserve(bytes32 marketId, Currency underlyingCurrency, uint256 amount)
        external
        onlyMarketFacade(marketId)
    {
        if (amount == 0) return;
        _assertUnderlyingConfigured(_marketConfig(marketId), underlyingCurrency);
        _incrementReserve(marketId, underlyingCurrency, amount);
    }

    function decreaseLiquidityReserve(bytes32 marketId, Currency underlyingCurrency, uint256 amount)
        external
        onlyMarketFacade(marketId)
    {
        if (amount == 0) return;
        _assertUnderlyingConfigured(_marketConfig(marketId), underlyingCurrency);
        _decrementReserve(marketId, underlyingCurrency, amount);
    }

    function _dryModifyLiquidities(
        bytes32 marketId,
        Currency currency0,
        Currency currency1,
        VaultSettlementIntent memory settlementIntent
    ) internal view returns (BalanceDelta) {
        _assertUnderlyingPairConfigured(_marketConfig(marketId), currency0, currency1);
        int128 delta0 = settlementIntent.requestedDelta.amount0();
        int128 delta1 = settlementIntent.requestedDelta.amount1();
        int128 actualDelta0 = delta0;
        int128 actualDelta1 = delta1;

        if (delta0 > 0) {
            uint256 requested0 = LiquidityUtils.safeInt128ToUint256(delta0);
            uint256 creditBacked0 = settlementIntent.creditBackedWithdrawal0;
            if (creditBacked0 > requested0) creditBacked0 = requested0;
            uint256 settledRequested0 = requested0 - creditBacked0;
            uint256 settledAvailable0 = marketLiquidityReserves[marketId][Currency.unwrap(currency0)];
            uint256 actual0 = creditBacked0 + Math.min(settledRequested0, settledAvailable0);
            if (actual0 < requested0) actualDelta0 = SafeCast.toInt128(actual0);
        }

        if (delta1 > 0) {
            uint256 requested1 = LiquidityUtils.safeInt128ToUint256(delta1);
            uint256 creditBacked1 = settlementIntent.creditBackedWithdrawal1;
            if (creditBacked1 > requested1) creditBacked1 = requested1;
            uint256 settledRequested1 = requested1 - creditBacked1;
            uint256 settledAvailable1 = marketLiquidityReserves[marketId][Currency.unwrap(currency1)];
            uint256 actual1 = creditBacked1 + Math.min(settledRequested1, settledAvailable1);
            if (actual1 < requested1) actualDelta1 = SafeCast.toInt128(actual1);
        }

        return toBalanceDelta(actualDelta0, actualDelta1);
    }

    function _modifyLiquidityWithRecipient(
        bytes32 marketId,
        Currency currency0,
        Currency currency1,
        VaultSettlementIntent memory settlementIntent,
        BalanceDelta balanceDelta,
        address recipient
    ) internal {
        (int128 amount0, int128 amount1) = (balanceDelta.amount0(), balanceDelta.amount1());

        if (amount0 > 0) {
            uint256 requested0 = LiquidityUtils.safeInt128ToUint256(amount0);
            uint256 creditBacked0 = settlementIntent.creditBackedWithdrawal0;
            if (creditBacked0 > requested0) creditBacked0 = requested0;
            uint256 settledBacked0 = requested0 - creditBacked0;
            if (settledBacked0 > 0) {
                _decrementReserve(marketId, currency0, settledBacked0);
            }
            _takeUnderlyingFromVaultToRecipient(marketId, currency0, recipient, requested0);
        } else if (amount0 < 0) {
            _settleUnderlyingToVaultFromSender(
                marketId, currency0, address(this), LiquidityUtils.safeInt128ToUint256(amount0)
            );
        }

        if (amount1 > 0) {
            uint256 requested1 = LiquidityUtils.safeInt128ToUint256(amount1);
            uint256 creditBacked1 = settlementIntent.creditBackedWithdrawal1;
            if (creditBacked1 > requested1) creditBacked1 = requested1;
            uint256 settledBacked1 = requested1 - creditBacked1;
            if (settledBacked1 > 0) {
                _decrementReserve(marketId, currency1, settledBacked1);
            }
            _takeUnderlyingFromVaultToRecipient(marketId, currency1, recipient, requested1);
        } else if (amount1 < 0) {
            _settleUnderlyingToVaultFromSender(
                marketId, currency1, address(this), LiquidityUtils.safeInt128ToUint256(amount1)
            );
        }
    }

    function _finaliseModifyLiquidity(
        bytes32 marketId,
        address lcc0,
        address lcc1,
        BalanceDelta balanceDelta,
        BalanceDelta usedDelta,
        address recipient
    ) internal {
        if (balanceDelta.amount0() < 0) {
            _settleObligationsForLCC(marketId, ILCC(lcc0));
        }
        if (balanceDelta.amount1() < 0) {
            _settleObligationsForLCC(marketId, ILCC(lcc1));
        }
        if (recipient == address(liquidityHub)) {
            int128 used0 = usedDelta.amount0();
            if (used0 > 0) liquidityHub.confirmTake(lcc0, LiquidityUtils.safeInt128ToUint256(used0), true);
            int128 used1 = usedDelta.amount1();
            if (used1 > 0) liquidityHub.confirmTake(lcc1, LiquidityUtils.safeInt128ToUint256(used1), true);
        }
    }

    function _settleUnderlyingToVaultFromSender(
        bytes32 marketId,
        Currency underlyingCurrency,
        address sender,
        uint256 amount
    ) internal {
        uint256 senderBalance = underlyingCurrency.balanceOf(sender);
        if (senderBalance < amount) revert Errors.InsufficientLiquidityToSettle();

        underlyingCurrency.settle(poolManager, sender, amount, false);
        underlyingCurrency.take(poolManager, address(this), amount, true);
        _incrementReserve(marketId, underlyingCurrency, amount);

        emit LiquidityAddedToVault(marketId, sender, Currency.unwrap(underlyingCurrency), amount);
    }

    function _takeUnderlyingFromVaultToRecipient(
        bytes32 marketId,
        Currency underlyingCurrency,
        address recipient,
        uint256 amount
    ) internal {
        uint256 availableLiquidity = poolManager.balanceOf(address(this), underlyingCurrency.toId());
        if (availableLiquidity < amount) revert Errors.InsufficientLiquidityToTake();

        underlyingCurrency.settle(poolManager, address(this), amount, true);
        if (underlyingCurrency.isAddressZero() && recipient == address(liquidityHub)) {
            underlyingCurrency.take(poolManager, address(this), amount, false);
            (bool ok,) = payable(recipient).call{value: amount}("");
            if (!ok) revert Errors.InvariantViolated("Native transfer to LiquidityHub failed");
        } else {
            underlyingCurrency.take(poolManager, recipient, amount, false);
        }

        emit LiquidityTakenFromVault(marketId, recipient, Currency.unwrap(underlyingCurrency), amount);
    }

    function _takeUnderlyingFromVaultToHub(bytes32 marketId, ILCC lccToken, uint256 amount, bool shouldEmit) internal {
        Currency uaCurrency = Currency.wrap(lccToken.underlying());
        _decrementReserve(marketId, uaCurrency, amount);
        _takeUnderlyingFromVaultToRecipient(marketId, uaCurrency, address(liquidityHub), amount);
        liquidityHub.confirmTake(address(lccToken), amount, shouldEmit);
    }

    function _settleObligationsForLCC(bytes32 marketId, ILCC lccToken) internal {
        _assertLccConfigured(_marketConfig(marketId), address(lccToken));
        uint256 unfunded = liquidityHub.unfundedQueueOfUnderlying(address(lccToken));
        if (unfunded == 0) return;

        Currency uaCurrency = Currency.wrap(lccToken.underlying());
        uint256 availableLiquidity = marketLiquidityReserves[marketId][Currency.unwrap(uaCurrency)];
        uint256 amountToSettle = Math.min(unfunded, availableLiquidity);
        if (amountToSettle == 0) return;
        _takeUnderlyingFromVaultToHub(marketId, lccToken, amountToSettle, true);
    }

    function _incrementReserve(bytes32 marketId, Currency underlyingCurrency, uint256 amount) internal {
        address underlying = Currency.unwrap(underlyingCurrency);
        marketLiquidityReserves[marketId][underlying] += amount;
        totalUnderlyingReserves[underlying] += amount;
    }

    function _decrementReserve(bytes32 marketId, Currency underlyingCurrency, uint256 amount) internal {
        address underlying = Currency.unwrap(underlyingCurrency);
        uint256 current = marketLiquidityReserves[marketId][underlying];
        if (current < amount) revert Errors.InsufficientLiquidityToTake();
        marketLiquidityReserves[marketId][underlying] = current - amount;
        totalUnderlyingReserves[underlying] -= amount;
    }

    function _marketConfig(bytes32 marketId) internal view returns (MarketConfig storage cfg) {
        cfg = markets[marketId];
        if (!cfg.exists) revert Errors.InvalidSender();
    }

    function _assertUnderlyingConfigured(MarketConfig storage cfg, Currency underlyingCurrency) internal view {
        address underlying = Currency.unwrap(underlyingCurrency);
        if (underlying != cfg.underlying0 && underlying != cfg.underlying1) {
            revert Errors.InvalidSender();
        }
    }

    function _assertLccConfigured(MarketConfig storage cfg, address lccToken) internal view {
        if (lccToken != cfg.lcc0 && lccToken != cfg.lcc1) {
            revert Errors.InvalidSender();
        }
    }

    function _assertUnderlyingPairConfigured(MarketConfig storage cfg, Currency currency0, Currency currency1)
        internal
        view
    {
        if (Currency.unwrap(currency0) != cfg.underlying0 || Currency.unwrap(currency1) != cfg.underlying1) {
            revert Errors.InvalidSender();
        }
    }

    function _assertLccPairConfigured(MarketConfig storage cfg, address lcc0, address lcc1) internal view {
        if (lcc0 != cfg.lcc0 || lcc1 != cfg.lcc1) {
            revert Errors.InvalidSender();
        }
    }

    /// @notice Accepts native ETH only from PoolManager, LiquidityHub, or factory-registered protocol bounds.
    /// @dev Unlike `MarketVaultFacade.receive`, `address(0)` is not whitelisted: canonical custody rejects unknown
    ///      ETH origins (including selfdestruct-style zero-address sends) while per-market facades remain more permissive.
    receive() external payable {
        if (
            msg.sender != address(poolManager) && msg.sender != address(liquidityHub)
                && !IMarketFactory(marketFactory).bounds(msg.sender)
        ) {
            revert Errors.InvalidEthSender();
        }
    }
}
