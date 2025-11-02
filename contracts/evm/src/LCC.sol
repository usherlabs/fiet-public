// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
import {PoolId} from "v4-periphery/lib/v4-core/src/types/PoolId.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IVTSManager} from "./interfaces/IVTSManager.sol";
import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {ILCC} from "./interfaces/ILCC.sol";
import {CurrencyTransfer} from "./libraries/CurrencyTransfer.sol";

contract LiquidityCommitmentCertificate is ERC20, Ownable, ILCC {
    using SafeTransferLib for ERC20;
    using CurrencyTransfer for Currency;

    error SenderNotIssuer(address sender);
    error InvalidUnderlyingAsset();
    error TransferNotAllowed();
    error InvalidAmount();
    error InsufficientETH();
    error InvalidMarketFactory();
    error InsufficientWrappedLiquidity(uint256 requested, uint256 available);

    address public immutable underlyingAsset;
    IMarketFactory public immutable marketFactory;

    // All native underlying liquidity will either be
    mapping(address => bool) public issuers;

    uint256 public uaSupply; // underlying asset supply ONLY within the LCC.

    modifier onlyIssuer() {
        if (!_isCallerIssuer(false)) {
            revert SenderNotIssuer(msg.sender);
        }
        _;
    }

    modifier onlyMarketVault() {
        if (!_isCallerIssuer(true)) {
            revert SenderNotIssuer(msg.sender);
        }
        _;
    }

    modifier onlyProtocolTransfer(address from, address to) {
        // Allow transfers from/to zero address (minting/burning)
        if (from == address(0) || to == address(0)) {
            _;
            return;
        }

        // Allow transfers between protocol bounds
        if (marketFactory.bounds(to) || marketFactory.bounds(from)) {
            _;
            return;
        }

        // Only protocol bounds can transfer to non-bounds (EOAs, other contracts)
        if (!marketFactory.bounds(from)) {
            revert TransferNotAllowed();
        }

        _;
    }

    /**
     * @param marketId The market ID
     * @param _underlyingAsset The underlying asset of the LCC.
     * @param name The token name
     * @param symbol The token symbol
     * @param decimals The token decimals
     */
    constructor(bytes32 marketId, address _underlyingAsset, string memory name, string memory symbol, uint8 decimals)
        ERC20(name, symbol, decimals)
        Ownable(msg.sender)
    {
        if (_underlyingAsset == address(0)) {
            revert InvalidUnderlyingAsset();
        }

        underlyingAsset = _underlyingAsset;
        marketFactory = IMarketFactory(msg.sender); // Set by factory during deployment

        // Note: bounds are managed by the MarketFactory, not set in constructor
    }

    /**
     * @dev Check if the caller is a valid issuer
     * @param isMarketVaultExclusive Whether the caller is a market vault
     * @return bool True if the caller is a valid issuer, false otherwise
     */
    function _isCallerIssuer(bool isMarketVaultExclusive) internal view returns (bool) {
        address caller = msg.sender;
        // Check the caller if they are a trusted proxy hook
        // Get if the caller is a registered proxy hook
        // If it is, then we need to get the two currencies it proxies
        // Then check if the underlying asset falls under any of the two currencies it supports
        address[2] memory currencies = marketFactory.proxyHookToCurrencyPair(caller);
        bool isAssetProxyPool = (currencies[0] == underlyingAsset || currencies[1] == underlyingAsset);
        if (isMarketVaultExclusive) {
            return isAssetProxyPool;
        }
        bool isValidIssuer = issuers[caller] || isAssetProxyPool;
        return isValidIssuer;
    }

    /**
     * @dev Get the underlying asset of the LCC
     * @return The underlying asset of the LCC
     */
    function underlying() external view returns (address) {
        // the `ResilientOracle` might call underlying()
        // if it calls underlying for lcc-eth
        // it will return address(0) which would cause an erc20 error as it tried to call .decimals() on it
        // so there is an edge case for the oracles for getting the underlying price of lcc-eth
        // a solution could be to modify the asset being returned to the oracle's native address
        // if the caller is the resilient oracle
        // TODO: (OPTIONAL) check if caller is ResilientOracle, and if underlying asset is native, and if so return RESILIENT_ORACLE_NATIVE_TOKEN_ADDR

        return underlyingAsset;
    }

    // some trusted issuer Smart Contracts can be allowed to mint tokens and hold the liquidity
    // this minting provides tokens at a 1:1 ratio and intended for onchain preswap wrapping
    // DEPRECATED: Use LCCFactory.issue() instead
    function issue(uint256 amount) external onlyIssuer {
        if (amount == 0) {
            revert InvalidAmount();
        }

        address issuer = msg.sender;

        _mint(issuer, amount);

        // totalSupply will be greater than uaSupply (supply of underlying asset in LCC)
        // This is because the PoolManager will custody the difference.
    }

    // DEPRECATED: Use LCCFactory.cancel() instead
    function cancel(uint256 amount) external onlyIssuer {
        if (amount == 0) {
            revert InvalidAmount();
        }

        address issuer = msg.sender;

        _burn(issuer, amount);

        // totalSupply will return back to uaSupply now that the surplus LCC managed by the issuer engagin the PoolManager has been cancelled.
    }

    /**
     * @notice Issues LCC tokens to an issuer (called by factory after validating permissions)
     * @param issuer The issuer address to mint tokens to
     * @param amount The amount to issue
     */
    function issueTo(address to, uint256 amount) external onlyOwner {
        if (amount == 0) {
            revert InvalidAmount();
        }
        _mint(to, amount);
    }

    /**
     * @notice Cancels LCC tokens from an issuer (called by factory after validating permissions)
     * @param issuer The issuer address to burn tokens from
     * @param amount The amount to cancel
     */
    function cancelFrom(address from, uint256 amount) external onlyOwner {
        if (amount == 0) {
            revert InvalidAmount();
        }
        _burn(from, amount);
    }

    /**
     * @dev Unwraps LCC from the Market Vault. Called exclusively by the Market Vault / Proxy Hook.
     * @param marketId The market ID
     * @param amount The amount to unwrap from the vault
     * @param deficitAmount The amount of the underlying asset to unwrap from the vault
     * @param excessLCCRecipient The recipient of the underlying asset
     */
    function unwrapFromVault(bytes32 marketId, uint256 amount, uint256 deficitAmount, address excessLCCRecipient)
        external
        onlyMarketVault
    {
        // On PH .cancel, market liquidity is utilised to cover swaps.
        // On MMP .cancel, market liquidity (MM Positions) are removed first, and therefore in-market settled liquidity is isolated for withdrawal...
        if (amount == 0) {
            revert InvalidAmount();
        }

        address sender = msg.sender;

        _burn(sender, amount);
        // _incrementCoverage(marketId, amount); // TODO: errors occuring here...

        if (deficitAmount > 0 && excessLCCRecipient != address(0)) {
            // Transfer to recipient.
            // CoreHook.afterSwap will automatically trigger tracing, therefore transfer here is already traced to source market.
            // Calling transfer here is as though it was called externally by the issuer. The proxy hook calls take on LCC before this function called.
            transfer(excessLCCRecipient, deficitAmount); // msg.sender is the issuer.
        }
    }

    // Called by Issuer before settling liquidity from LCCs to the market.
    function prepareSettle(uint256 amount) external onlyMarketVault {
        address vault = msg.sender;
        Currency underlyingAssetCurrency = Currency.wrap(underlyingAsset);
        // Allow issuer to facilitate direct liquidity provision transfer of underlying tokens
        // approval does nothing if we are using ETH(address(0)) as the underlying asset
        // so to prepare settle, we simply transfer the ETH to the issuer calling this function
        // so that way the caller can then transfer the ETH on the behalf of the LCC contract since there is no native  `transferFrom`
        if (underlyingAssetCurrency.isAddressZero()) {
            underlyingAssetCurrency.transfer(vault, amount);
        } else {
            underlyingAssetCurrency.approve(vault, amount);
        }
        uaSupply -= amount;
    }

    // Called by MarketVault after taking underlying liquidity from the market to LCC.
    // Accounts for Vault -> LCC. if shouldProcessQueue is true, Vault -> Recipients.
    function confirmTake(bytes32 marketId, uint256 amount, bool shouldProcessQueue) external onlyMarketVault {
        // Track which market this underlying asset liquidity derived from.
        _trackReceivedLiquidity(marketId, amount);
        // Track total underlying asset supply
        uaSupply += amount;
        if (shouldProcessQueue) {
            _processSettlementQueue(marketId, amount, true);
        }
    }

    // Called by MMP to transfer LLCs and track market source.
    function traceTransfer(address to, bytes32 marketId, uint256 amount) external onlyIssuer {
        transfer(to, amount);
        _trackMarketAcquisition(to, marketId, amount);
    }

    // DirectLPs and Traders engaging the CorePool directly will need LCC. LCC is 1:1 with the underlying asset.
    function _wrap(address from, address to, uint256 amount) internal {
        bool isNativeAsset = underlyingAsset == address(0);
        // throw error if the native ETH is insufficient and it is a native ETH backed LCC
        if (isNativeAsset && msg.value != amount) {
            revert InvalidAmount();
        }

        // mint some tokens
        _mint(to, amount);

        // transfer the underlying asset from the recipient if it is not a native ETH backed LCC
        if (!isNativeAsset) {
            // safe to make ERC20 call here since we have verified that from address is not a native asset
            ERC20(underlyingAsset).safeTransferFrom(from, address(this), amount);
        }

        uaSupply += amount;
    }

    function wrap(uint256 amount) external payable {
        _wrap(msg.sender, msg.sender, amount);
    }

    /**
     * @dev Increment the LCC unwrap coverage of the market
     * @param marketId The market id
     * @param amount The amount to increment the coverage by
     */
    function _incrementCoverage(bytes32 marketId, uint256 amount) internal {
        IVTSManager(marketFactory.getCoreHook()).incrementCoverage(PoolId.wrap(marketId), amount);
    }

    /**
     * @dev Unwraps LCC from a specific market's liquidity reserves
     * @notice OOM vs IM Distinction: When acquiring LCCs from a market, it's underlying liquidity either in the market, or to be settled to the market.
     * @param marketId The market to unwrap from
     * @param to The recipient of underlying assets
     * @param amount The amount to unwrap from this market
     * @return The amount actually unwrapped from this market
     */
    function _unwrapFromMarketLiquidity(bytes32 marketId, address from, address to, uint256 amount)
        internal
        returns (uint256)
    {
        // Use market liquidity
        uint256 amountAvailable = _useMarketLiquidity(marketId, amount, from);

        // When we unwrap, we first use whatever liquidity is directly wrapped.
        // Then, we turn to available in the market.
        // If there's deficit between the amount to unwrap from market and the amount available, then we're in an insufficient liquidity situation and we queue a settlement
        uint256 deficit = amount - amountAvailable;
        if (deficit > 0) {
            _addToSettlementQueue(marketId, to, deficit);
        }

        _incrementCoverage(marketId, amountAvailable);

        return amountAvailable;
    }

    /**
     * @dev Unwraps LCC from out-of-market liquidity pool (wrapped LCC) i.e LCC that was created by wrapping
     * @dev Unwraps using liquidity that was provided by wrapping
     * @param amount The amount to unwrap from general pool
     * @return The amount actually unwrapped
     */
    function _unwrapFromOOMLiquidity(uint256 amount) internal view returns (uint256) {
        // Wrapped LCC should always be fully backed by uaSupply
        // No settlement queue needed ? - this should always succeed

        // get the UA supply that was wrapped by sutracting the total supply from the sum of all market balances
        uint256 totalMarketBalances = _getTotalMarketBalances();
        uint256 uaSupplyWrapped = uaSupply - totalMarketBalances;

        // if the UA supply that was wrapped is less than the amount to unwrap, then revert
        if (uaSupplyWrapped < amount) {
            revert InsufficientWrappedLiquidity(amount, uaSupply);
        }

        // Should Always returns full amount
        return amount;
    }

    /**
     * @dev Unwraps LCC from the user's wallet.
     * @dev Users should only be able to unwrap if LCC in their wallet.
     * @param from The user to unwrap from
     * @param to The recipient of the underlying asset
     * @param amount The amount to unwrap
     */
    function _unwrap(address from, address to, uint256 amount) internal {
        if (amount == 0 || amount > balanceOf[from]) {
            revert InvalidAmount();
        }

        uint256 totalAmountUnwrapped = 0;

        bytes32[] memory userMarkets = _getUserMarkets(from);
        uint256 userMarketsTotalBalance = _getUserTotalMarketBalance(from);
        uint256 userWrappedBalance = balanceOf[from] - userMarketsTotalBalance;
        // if the user has wrapped balance, then we need to unwrap from the market first
        if (userWrappedBalance > 0) {
            // Only unwrapFromOOMLiquidity if the amount to unwrap is greater than the user's wrapped balance
            uint256 amountUnwrapped = _unwrapFromOOMLiquidity(Math.min(amount, userWrappedBalance));
            totalAmountUnwrapped += amountUnwrapped;
        }

        // any amount not wrapped should be unwrapped from the market
        uint256 remainingToUnwrap = amount - totalAmountUnwrapped;

        for (uint256 i = 0; i < userMarkets.length && remainingToUnwrap > 0; i++) {
            bytes32 marketId = userMarkets[i];
            uint256 userMarketBalance = balanceOfUserFromMarket[from][marketId]; // inherited from MarketLiquidity

            if (userMarketBalance == 0) continue;

            // get the max amount that can be unwrapped from this market
            uint256 amountFromThisMarket = Math.min(remainingToUnwrap, userMarketBalance);

            // unwrap from this market's liquidity
            uint256 amountUnwrapped = _unwrapFromMarketLiquidity(marketId, from, to, amountFromThisMarket);

            totalAmountUnwrapped += amountUnwrapped;
            remainingToUnwrap -= amountFromThisMarket;
        }

        // burn the amount that was unwrapped
        // and transfer the underlying assets to the user
        if (totalAmountUnwrapped > 0) {
            _payOutstandingSettlementToUser(from, totalAmountUnwrapped);
        }
    }

    function unwrap(uint256 amount) external {
        _unwrap(msg.sender, msg.sender, amount);
    }

    function wrapTo(address to, uint256 amount) external payable {
        _wrap(msg.sender, to, amount);
    }

    function unwrapTo(address to, uint256 amount) external {
        _unwrap(msg.sender, to, amount);
    }

    function _transferUnderlyingAssets(address user, uint256 amount) internal {
        // confirm the amount is valid and not greater than the uaSupply
        if (amount == 0 || amount > uaSupply) {
            revert InvalidAmount();
        }
        uaSupply -= amount;

        Currency.wrap(underlyingAsset).transfer(user, amount);
    }

    // Pay an outstanding settlement to a user and burn their underlying tokens
    function _payOutstandingSettlementToUser(address user, uint256 amount) internal override {
        _burn(user, amount);
        _transferUnderlyingAssets(user, amount);
    }

    // On transfer hook
    function onTransfer(address from, address to, uint256 amount) internal onlyProtocolTransfer(msg.sender, to) {
        // clear any outstanding settlement in all markets to be paid to the sender initiating the transfer
        _annulUserSettlementBeforeTransfer(from, amount);
    }

    function transfer(address to, uint256 amount) public virtual override returns (bool) {
        onTransfer(msg.sender, to, amount);
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public virtual override returns (bool) {
        onTransfer(from, to, amount);
        return super.transferFrom(from, to, amount);
    }

    /**
     * @dev Annul the user's pending settlements partially or completely
     * @dev This is called before a transfer is made to clear any outstanding settlements to this user relative to the amount to settle.
     * @param fromUser The user to annul the pending settlements for
     * @param amountToTransfer The amount to transfer
     */
    function _annulUserSettlementBeforeTransfer(address fromUser, uint256 amountToTransfer) internal {
        // get the markets the user has LCC from
        // get their balance
        // get their total market pending settlements
        // max amount they can transfer  is balance - sum pending settlements
        // if they try to transfer more than that, then we need to annull the equivalent amount of pending settlements
        uint256 userBalance = balanceOf[fromUser];

        if (userBalance == 0) {
            return;
        }

        if (amountToTransfer > userBalance) {
            revert InvalidAmount();
        }

        // get the user's total pending settlements across all markets
        uint256 userPendingSettlement = _getUserPendingSettlement(fromUser);
        if (userPendingSettlement == 0) {
            return;
        }

        uint256 maxAmountCanTransferWithoutClearing = userBalance - userPendingSettlement;

        if (amountToTransfer > maxAmountCanTransferWithoutClearing) {
            uint256 amountToAnnul = amountToTransfer - maxAmountCanTransferWithoutClearing;
            // annull the equivalent pending settlements

            // If a transaction to process settlements occurs before the transfer. In that case, the user's LCC transfer will revert, and they'll have native assets in their wallet instead.
            _annulUserSettlement(fromUser, amountToAnnul);
        }
    }
}
