// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IOracleHelper} from "./interfaces/IOracleHelper.sol";
import {LCCFactory} from "./modules/LCCFactory.sol";
import {CurrencyTransfer} from "./libraries/CurrencyTransfer.sol";
import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

/**
 * @title LiquidityHub
 * @notice Factory contract for creating Fiet protocol markets with LCC tokens and pool management
 * @dev Manages LCC token creation, pool deployment, and protocol bounds administration
 */
contract LiquidityHub is Ownable, LCCFactory {
    using CurrencyTransfer for Currency;

    IOracleHelper public immutable oracleHelper;

    error InvalidCaller();
    error InvalidLcc(address lcc);
    error LiquidityError(address lcc, uint256 amount);

    event FactorySet(address indexed factory, bool enabled);

    // IMPORTANT NOTE: The LiquidityHub is agnostic/unaware of the end account.
    // Similarly to how PoolManager leverages periphery contracts to manage end-account balances, the LiquidityHub aggregates balances, and uses LCCs to track account balances in a hub-and-spoke model.

    // Map of market factories
    mapping(address => bool) public isFactory;
    // Mapping from underlying token to OOM (Out-of-Market) balance of the account
    mapping(address => uint256) public directSupply;
    mapping(address => uint256) public reserveOfUnderlying; // reserve of the underlying token

    constructor(
        address _oracleHelper,
        string memory _nativeAssetName,
        string memory _nativeAssetSymbol,
        uint8 _nativeAssetDecimals
    ) Ownable(msg.sender) LCCFactory(_nativeAssetName, _nativeAssetSymbol, _nativeAssetDecimals) {
        oracleHelper = IOracleHelper(_oracleHelper);
    }

    modifier onlyFactory() {
        if (!isFactory[_msgSender()]) {
            revert InvalidCaller();
        }
        _;
    }

    modifier onlyFactoryOrOwner() {
        if (!isFactory[_msgSender()] && _msgSender() != owner()) {
            revert InvalidCaller();
        }
        _;
    }

    modifier onlyValidLcc(address lcc) {
        _assertValidLcc(lcc);
        _;
    }

    function setFactory(address factory, bool enabled) external onlyOwner {
        isFactory[factory] = enabled;
        emit FactorySet(factory, enabled);
    }

    /**
     * @notice Creates LCC token pair for a market
     * @param marketRef The market reference (bytes from proxyHookAddress)
     * @param underlyingAsset0 The first underlying asset address
     * @param underlyingAsset1 The second underlying asset address
     * @param marketName The market name
     * @param initialIssuers Array of addresses to set as issuers for both LCC tokens
     * @return lccToken0 The first LCC token address
     * @return lccToken1 The second LCC token address
     */
    function createLCCPair(
        bytes memory marketRef,
        address underlyingAsset0,
        address underlyingAsset1,
        string memory marketName,
        address[] memory initialIssuers
    ) external onlyFactory returns (address lccToken0, address lccToken1) {
        address[2] memory underlyingPair = [underlyingAsset0, underlyingAsset1];
        lccToken0 = _createLCC(_msgSender(), marketRef, underlyingPair, 0, marketName, initialIssuers);
        lccToken1 = _createLCC(_msgSender(), marketRef, underlyingPair, 1, marketName, initialIssuers);
    }

    /**
     * @notice Initializes the mapping from LCC tokens to Market (with ID and Ref)
     * @param lccToken0 The first LCC token address
     * @param lccToken1 The second LCC token address
     * @param marketId The market ID (corePoolKey -> PoolID -> unwrap() to bytes32)
     * @param marketRef The market reference (bytes from proxyHookAddress)
     * @param refIsValidIssuer Whether the market ref address is a valid issuer
     */
    function initialize(
        address lccToken0,
        address lccToken1,
        bytes32 marketId,
        bytes memory marketRef,
        bool refIsValidIssuer
    ) external onlyFactory {
        _initialize(lccToken0, lccToken1, marketId, marketRef, refIsValidIssuer, _msgSender());
    }

    // ============ TRADER FUNCTIONS ============

    // DirectLPs and Traders engaging the CorePool directly will need LCC. LCC is 1:1 with the underlying asset.
    function _wrap(address lcc, address from, address to, uint256 amount) internal onlyValidLcc(lcc) {
        address underlying = lccToUnderlying[lcc];
        bool isNativeAsset = underlying == address(0);
        // throw error if the native ETH is insufficient and it is a native ETH backed LCC
        if (isNativeAsset) {
            if (msg.value != amount) {
                revert InvalidAmount();
            }
        } else {
            // safe to make ERC20 call here since we have verified that from address is not a native asset
            ERC20(underlying).safeTransferFrom(from, address(this), amount);
        }

        directSupply[lcc] += amount;
        reserveOfUnderlying[underlying] += amount;

        // mint some tokens
        _mint(lcc, to, amount);
    }

    function wrapTo(address lcc, address to, uint256 amount) external payable {
        _wrap(lcc, _msgSender(), to, amount);
    }

    function wrapTo(address underlying, bytes32 marketId, address to, uint256 amount) external payable {
        _wrap(marketUnderlyingToLCC[marketId][underlying], _msgSender(), to, amount);
    }

    function wrap(address lcc, uint256 amount) external payable {
        _wrap(lcc, _msgSender(), _msgSender(), amount);
    }

    function wrap(address underlying, bytes32 marketId, uint256 amount) external payable {
        _wrap(marketUnderlyingToLCC[marketId][underlying], _msgSender(), _msgSender(), amount);
    }

    /**
     * @dev Unwraps LCC from the account's wallet.
     * @dev Accounts should only be able to unwrap if LCC in their wallet.
     * @param from The account to unwrap from
     * @param to The recipient of the underlying asset
     * @param amount The amount to unwrap
     */
    function _unwrap(address lcc, address from, address to, uint256 amount) internal onlyValidLcc(lcc) {
        (uint256 wrappedBalance, uint256 marketDerivedBalance) = _balancesOf(lcc, from);
        uint256 fromBalance = wrappedBalance + marketDerivedBalance;
        if (amount == 0 || amount > fromBalance) {
            revert InvalidAmount();
        }

        // Unwrap from wrapped balance first (out-of-market liquidity)
        uint256 directUnwrapped = 0;
        uint256 marketUnwrapped = 0;

        if (wrappedBalance > 0) {
            uint256 amountFromWrapped = Math.min(amount, wrappedBalance);
            directUnwrapped = _directUnwrap(amountFromWrapped);
        }

        // Unwrap remaining amount from market-derived balance
        uint256 remainingToUnwrap = amount - directUnwrapped;
        if (remainingToUnwrap > 0 && marketDerivedBalance > 0) {
            // Get the max amount that can be unwrapped from this market
            uint256 amountFromMarket = Math.min(remainingToUnwrap, marketDerivedBalance);

            // Unwrap from this market's liquidity
            marketUnwrapped = _marketUnwrap(lcc, from, to, amountFromMarket);

            remainingToUnwrap -= amountFromMarket;
        }

        if (remainingToUnwrap > 0) {
            // When we unwrap, we first use whatever liquidity is directly wrapped.
            // Then, we turn to liquidity either directly in the market or pending settlement to the market in the future.
            // If there's deficit between the amount to unwrap from market and the amount available, then we're in an insufficient liquidity situation and we queue a settlement
            _queueSettlement(lccToMarket[lcc].id, to, remainingToUnwrap);
        }

        // Burn the amount that was unwrapped
        // and transfer the underlying assets to the account
        if (directUnwrapped + marketUnwrapped > 0) {
            _pay(lcc, to, directUnwrapped, marketUnwrapped);
        }
    }

    function unwrap(address lcc, uint256 amount) external {
        _unwrap(lcc, _msgSender(), _msgSender(), amount);
    }

    function unwrap(address underlying, bytes32 marketId, uint256 amount) external {
        _unwrap(marketUnderlyingToLCC[marketId][underlying], _msgSender(), _msgSender(), amount);
    }

    function unwrapTo(address lcc, address to, uint256 amount) external {
        _unwrap(lcc, _msgSender(), to, amount);
    }

    function unwrapTo(address underlying, bytes32 marketId, address to, uint256 amount) external {
        _unwrap(marketUnderlyingToLCC[marketId][underlying], _msgSender(), to, amount);
    }

    // ============ LIQUIDITY FUNCTIONS ============

    function marketLiquidity(address lcc) public view returns (uint256) {
        return lccToMarket[lcc].id != bytes32(0)
            ? IMarketFactory(lccToMarket[lcc].factory).marketLiquidity(lccToUnderlying[lcc], lccToMarket[lcc].id)
            : 0;
    }

    function _useMarketLiquidity(address lcc, uint256 amount) internal returns (uint256 available, uint256 toUse) {
        bytes32 marketId = lccToMarket[lcc].id;
        return IMarketFactory(lccToMarket[lcc].factory).useMarketLiquidity(lccToUnderlying[lcc], marketId, amount);
    }

    // pending supply is the amount of liquidity that is pending settlement to the market.
    // amount that has not been wrapped, and is not in market.
    // However, LCC can be held but not queued for settlement...
    // function pendingSupply(address lcc) public view returns (uint256) {
    //     return marketLiquidity(lcc) - directSupply[lcc];
    // }

    /**
     * @dev Unwraps LCC from a specific market's liquidity reserves
     * @notice OOM vs IM Distinction: When acquiring LCCs from a market, it's underlying liquidity either in the market, or to be settled to the market.
     * @param lcc The LCC token address
     * @param to The recipient of underlying assets
     * @param amount The amount to unwrap from this market
     * @return The amount actually unwrapped from this market
     */
    function _marketUnwrap(address lcc, address to, uint256 amount) internal returns (uint256) {
        // TODO: On LCC unwrap where LCC underlying, we need to call unwrap on any available after net.
        // Use market liquidity
        (, uint256 toUse) = _useMarketLiquidity(lcc, amount);

        return toUse;
    }

    /**
     * @dev Unwraps LCC from out-of-market liquidity pool (wrapped LCC) i.e LCC that was created by wrapping
     * @dev Unwraps using liquidity that was provided by wrapping
     * @param amount The amount to unwrap from general pool
     * @return The amount actually unwrapped
     */
    function _directUnwrap(uint256 amount) internal view returns (uint256) {
        // Directly wrapped LCC should always be fully backed by underlying
        // No settlement queue needed ? - this should always succeed

        // if the UA supply that was wrapped is less than the amount to unwrap, then revert
        if (directSupply[lcc] < amount) {
            revert InsufficientWrappedLiquidity(amount, uaSupply);
        }

        directSupply[lcc] -= amount;

        // Should Always returns full amount
        return amount;
    }

    // ============ ISSUER FUNCTIONS ============

    // /**
    //  * @dev Unwraps LCC from the Market Vault. Called exclusively by the Market Vault / Proxy Hook.
    //  * @param marketId The market ID
    //  * @param amount The amount to unwrap from the vault
    //  * @param deficitAmount The amount of the underlying asset to unwrap from the vault
    //  * @param excessLCCRecipient The recipient of the underlying asset
    //  */
    // function unwrapFromVault(bytes32 marketId, uint256 amount, uint256 deficitAmount, address excessLCCRecipient)
    //     external
    //     onlyMarketVault
    // {
    //     // On PH .cancel, market liquidity is utilised to cover swaps.
    //     // On MMP .cancel, market liquidity (MM Positions) are removed first, and therefore in-market settled liquidity is isolated for withdrawal...
    //     if (amount == 0) {
    //         revert InvalidAmount();
    //     }

    //     address sender = msg.sender;

    //     _burn(sender, amount);
    //     // _incrementCoverage(marketId, amount); // TODO: errors occuring here...

    //     if (deficitAmount > 0 && excessLCCRecipient != address(0)) {
    //         // Transfer to recipient.
    //         // CoreHook.afterSwap will automatically trigger tracing, therefore transfer here is already traced to source market.
    //         // Calling transfer here is as though it was called externally by the issuer. The proxy hook calls take on LCC before this function called.
    //         transfer(excessLCCRecipient, deficitAmount); // msg.sender is the issuer.
    //     }
    // }

    // // Called by Issuer before settling liquidity from LCCs to the market.
    // function prepareSettle(uint256 amount) external onlyMarketVault {
    //     address vault = msg.sender;
    //     Currency underlyingAssetCurrency = Currency.wrap(underlyingAsset);
    //     // Allow issuer to facilitate direct liquidity provision transfer of underlying tokens
    //     // approval does nothing if we are using ETH(address(0)) as the underlying asset
    //     // so to prepare settle, we simply transfer the ETH to the issuer calling this function
    //     // so that way the caller can then transfer the ETH on the behalf of the LCC contract since there is no native  `transferFrom`
    //     if (underlyingAssetCurrency.isAddressZero()) {
    //         underlyingAssetCurrency.transfer(vault, amount);
    //     } else {
    //         underlyingAssetCurrency.approve(vault, amount);
    //     }
    //     uaSupply -= amount;
    // }

    // Called by MarketVault after taking underlying liquidity from the market to LCC.
    // Accounts for Vault -> LCC. if shouldProcessQueue is true, Vault -> Recipients.
    function confirmTake(address lcc, uint256 amount, bool shouldProcessQueue) external onlyIssuer(lcc) {
        // Track total underlying asset supply
        reserveOfUnderlying[lccToUnderlying[lcc]] += amount;
    }

    // ============ SETTLEMENT FUNCTIONS ============

    /**
     * @dev Transfers underlying assets to an account
     * @param underlying The underlying asset address
     * @param account The account to transfer the underlying assets to
     * @param amount The amount of underlying assets to transfer
     */
    function _transferUnderlying(address underlying, address account, uint256 amount) internal {
        // confirm the amount is valid and not greater than the uaSupply
        if (amount == 0 || amount > reserveOfUnderlying[underlying]) {
            revert InvalidAmount();
        }
        reserveOfUnderlying[underlying] -= amount;

        Currency.wrap(underlying).transfer(account, amount);
    }

    // Pay an outstanding settlement to an account and burn their underlying tokens
    function _pay(address lcc, address to, uint256 fromDirect, uint256 fromMarket) internal {
        _burn(lcc, to, fromDirect, fromMarket);
        _transferUnderlying(lccToUnderlying[lcc], to, fromDirect + fromMarket);
    }

    /**
     * @dev Adds a settlement request to the queue
     * @param marketId The market ID with pending settlements
     * @param recipient The address with pending settlements
     * @param amount The amount to eventually settle
     */
    // TODO: Queue logic leaves an edge case where someone can clog the queue through micro-transactions across 1000s of wallets.
    // If we require that liquidity be available before withdraw, then a separate priphery contract can help LCC holders automatically withdraw their liquidity.
    function _queueSettlement(address lcc, address recipient, uint256 amount) internal {
        // Add to amount we owe this recipient for this market
        if (settleQueue[lcc][recipient] == 0) {
            // First settlement to this recipient in this market
            pendingRecipients[lcc].push(recipient);
        }

        settleQueue[lcc][recipient] += amount;
        totalQueued[lcc] += amount;
    }

    /**
     * @dev Partially or Completely process the market settlement queue
     * @param marketId The market to process the settlement queue for
     * @param availableLiquidity The available liquidity in the market
     * @param burnTokens Whether to burn the equivalent LCC tokens for the settlement settled
     * @return processedAmount The amount processed from the settlement queue
     */
    function _processQueue(address lcc, uint256 amountToProcess, bool burnTokens)
        internal
        returns (uint256 processedAmount)
    {
        uint256 available = Math.min(amountToProcess, totalQueued[lcc]);

        address[] memory settlementRecipients = marketSettlementRecipients[marketId];

        for (uint256 i = 0; i < settlementRecipients.length && remainingLiquidity > 0; i++) {
            address recipient = settlementRecipients[i];
            uint256 amount = marketUserSettlement[marketId][recipient];

            if (amount == 0) continue; // Skip fully paid settlements

            uint256 amountToSettle = Math.min(remainingLiquidity, amount);
            _processQueueForRecipient(marketId, recipient, amountToSettle, burnTokens);
            remainingLiquidity -= amountToSettle;
            processedAmount += amountToSettle;
        }
    }

    function _processQueueForAllRecipientMarkets(address recipient, uint256 amountToProcess, bool burnTokens) internal {
        uint256 remainingLiquidity = amountToProcess;
        bytes32[] memory userMarkets = _getUserMarkets(recipient);
        for (uint256 i = 0; i < userMarkets.length; i++) {
            bytes32 marketId = userMarkets[i];
            uint256 amountInMarket = marketUserSettlement[marketId][recipient];
            if (amountInMarket == 0) continue;
            uint256 amount = Math.min(remainingLiquidity, amountInMarket);

            remainingLiquidity -= amount; // Math.min ensures that the amount is always less than or equal to the remaining liquidity to process

            _processQueueForRecipient(marketId, recipient, amount, burnTokens);

            if (remainingLiquidity == 0) break;
        }
    }

    /**
     * @dev Processes a settlement queue for a recipient
     * @param marketId The market ID to process the settlement queue for
     * @param recipient The recipient to process the settlement queue for
     * @param amount The amount to process
     * @param burnTokens Whether to burn the equivalent LCC tokens for the settlement settled
     */
    function _processQueueForRecipient(bytes32 marketId, address recipient, uint256 amount, bool burnTokens) internal {
        // Update amount we owe
        marketUserSettlement[marketId][recipient] -= amount;
        marketTotalSettlementDeficit[marketId] -= amount;

        // If amount fully paid, remove from pending settlement holders list
        if (marketUserSettlement[marketId][recipient] == 0) {
            hasPendingSettlement[marketId][recipient] = false;
            _removeMarketRecipientRecord(marketId, recipient);
        }

        // burn the equivalent LCC Tokens for this user's amount that was just paid off
        // and transfer the underlying assets to the recipient of the settlement
        // if burn is false, it means we are clearing a settlement we did not pay off
        if (burnTokens) {
            _payOutstandingSettlementToUser(recipient, amount);
        }
    }

    /**
     * @dev Process all the market settlement queues for a user partially or completely clearing out their pending settlements
     * @param fromUser The user who's settlements are being cleared
     * @param amountToClear The amount of pending settlements to clear
     */
    function _annulUserSettlement(address fromUser, uint256 amountToClear) internal {
        _processQueueForAllRecipientMarkets(fromUser, amountToClear, false);
    }

    // /**
    //  * @dev Annul the account's pending settlements partially or completely
    //  * @dev This is called before a transfer is made to clear any outstanding settlements to this account relative to the amount to settle.
    //  * @param fromAccount The account to annul the pending settlements for
    //  * @param amountToTransfer The amount to transfer
    //  */
    // function _annulAccountSettlementBeforeTransfer(address from, uint256 amountToTransfer) internal {
    //     // get the markets the account has LCC from
    //     // get their balance
    //     // get their total market pending settlements
    //     // max amount they can transfer  is balance - sum pending settlements
    //     // if they try to transfer more than that, then we need to annull the equivalent amount of pending settlements
    //     uint256 balance = balanceOf[from];

    //     if (balance == 0) {
    //         return;
    //     }

    //     if (amountToTransfer > balance) {
    //         revert InvalidAmount();
    //     }

    //     // get the account's total pending settlements across all markets
    //     uint256 accountPendingSettlement = _getAccountPendingSettlement(from);
    //     if (accountPendingSettlement == 0) {
    //         return;
    //     }

    //     uint256 maxAmountCanTransferWithoutClearing = balance - accountPendingSettlement;

    //     if (amountToTransfer > maxAmountCanTransferWithoutClearing) {
    //         uint256 amountToAnnul = amountToTransfer - maxAmountCanTransferWithoutClearing;
    //         // annull the equivalent pending settlements

    //         // If a transaction to process settlements occurs before the transfer. In that case, the account's LCC transfer will revert, and they'll have native assets in their wallet instead.
    //         _annulAccountSettlement(from, amountToAnnul);
    //     }
    // }

    // On transfer hook
    function onTransfer(address from, address to, uint256 amount) external onlyValidLcc(_msgSender()) {
        address lcc = _msgSender();

        // // clear any outstanding settlement in all markets to be paid to the sender initiating the transfer
        // _annulAccountSettlementBeforeTransfer(from, amount);

        // // process the market tracing logic to find out which market the token transfer came from
        // _processMarketTracing(to, amount);
    }
}
