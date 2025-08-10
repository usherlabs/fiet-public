// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
import {MarketDebt} from "./modules/MarketDebt.sol";
import {IExttload} from "v4-periphery/lib/v4-core/src/interfaces/IExttload.sol";
import {TransientSlots} from "./libraries/TransientSlots.sol";
import {PoolId} from "v4-periphery/lib/v4-core/src/types/PoolId.sol";
import {console} from "forge-std/console.sol";
import {IProxyHook} from "./interfaces/IProxyHook.sol";
import {MarketVault} from "./modules/MarketVault.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

contract LiquidityCommitmentCertificate is ERC20, MarketDebt {
    using SafeTransferLib for ERC20;

    error SenderNotIssuer();
    error InvalidUnderlyingAsset();
    error TransferNotAllowed();
    error InvalidAmount();
    error InvalidMarketFactory();
    error InsufficientWrappedLiquidity(uint256 requested, uint256 available);

    address public immutable underlyingAsset;
    address public immutable marketFactory;
    bytes32 public immutable defaultMarket = bytes32(0);

    // All native underlying liquidity will either be
    mapping(address => bool) public issuers;

    // Define a mapping from

    uint256 public uaSupply; // underlying asset supply ONLY within the LCC.

    modifier onlyIssuer() {
        address caller = msg.sender;
        // Check the caller if they are a trusted proxy hook
        // Get if the caller is a registered proxy hook
        // If it is, then we need to get the two currencies it proxies
        // Then check if the underlying asset falls under any of the two currencies it supports
        address[2] memory currencies = IMarketFactory(marketFactory).proxyHookToCurrencyPair(caller);
        bool isAssetProxyPool = (currencies[0] == underlyingAsset || currencies[1] == underlyingAsset);
        bool isValidIssuer = issuers[caller] || isAssetProxyPool;

        // if caller is not a valid issuer then revert
        if (!isValidIssuer) {
            revert SenderNotIssuer();
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
        if (IMarketFactory(marketFactory).bounds(to) || IMarketFactory(marketFactory).bounds(from)) {
            _;
            return;
        }

        // Only protocol bounds can transfer to non-bounds (EOAs, other contracts)
        if (!IMarketFactory(marketFactory).bounds(from)) {
            revert TransferNotAllowed();
        }

        _;
    }

    /**
     * @param _underlyingAsset The underlying asset of the LCC.
     * @param _issuers The issuers of the LCC. ProxyHook, and MMPositionManager
     * @param _marketFactory The MarketFactory contract that manages this LCC.
     */
    constructor(address _underlyingAsset, address[] memory _issuers, address _marketFactory)
        ERC20(
            string.concat("Fiet Liquidity Commitment Certificate for ", IERC20Metadata(_underlyingAsset).name()),
            string.concat("lcc-", IERC20Metadata(_underlyingAsset).symbol()),
            IERC20Metadata(_underlyingAsset).decimals()
        )
    {
        // TODO: handle ETH native token
        if (_underlyingAsset == address(0)) {
            revert InvalidUnderlyingAsset();
        }
        if (_marketFactory == address(0)) {
            revert InvalidMarketFactory();
        }

        underlyingAsset = _underlyingAsset;
        marketFactory = _marketFactory;

        for (uint256 i = 0; i < _issuers.length; i++) {
            issuers[_issuers[i]] = true;
        }

        // Note: bounds are managed by the MarketFactory, not set in constructor
    }

    // some trusted issuer Smart Contracts can be allowed to mint tokens and hold the liquidity
    // this minting provides tokens at a 1:1 ratio and intended for onchain preswap wrapping
    function issue(uint256 amount) external onlyIssuer {
        address issuer = msg.sender;
        _mint(issuer, amount);

        // totalSupply will be greater than uaSupply (supply of underlying asset in LCC)
        // This is because the PoolManager will custody the difference.
    }

    function cancel(uint256 amount) external onlyIssuer returns (uint256 amountToCancel, uint256 deficit) {
        address issuer = msg.sender;
        uint256 externallyCustodied = totalSupply - uaSupply;
        if (amount == 0) {
            revert InvalidAmount();
        }

        if (amount > externallyCustodied) {
            amountToCancel = externallyCustodied;
            deficit = amount - externallyCustodied;
        } else {
            amountToCancel = amount;
        }

        _burn(issuer, amountToCancel);

        if (deficit > 0) {
            // TODO: https://www.notion.so/usherlabs/Outcomes-of-LCC-Insufficient-Liquidity-22b6d8286da580c8a455efc4175970a0?source=copy_link#22b6d8286da580de8a33cf367d3b7220
        }

        return (amountToCancel, deficit);
    }

    // Called by Issuer before settling liquidity from LCCs to the market.
    function prepareSettle(uint256 amount) external onlyIssuer {
        // Allow issuer to facilitate direct liquidity provision transfer of underlying tokens
        IERC20(underlyingAsset).approve(msg.sender, amount);
        uaSupply -= amount;
    }

    // Called by Issuer after taking liquidity from the market to LCC.
    function confirmTake(uint256 amount) external onlyIssuer {
        // get the market id from the caller
        address issuer = msg.sender;

        // from the proxy pool address, get the core pool id
        PoolId corePoolId = IProxyHook(issuer).getCorePoolId();
        bytes32 marketId = PoolId.unwrap(corePoolId);

        // Process the debt queue for this market
        uint256 processedAmount = _processMarketDebtQueue(marketId, amount);
        uint256 remainingAmount = amount - processedAmount;

        // if after settling debts there is still some liquidity left, then store it in the market reserves
        if (remainingAmount > 0) {
            // Track market specific  underlying asset supply
            _trackMarketLiquidity(marketId, remainingAmount);
            // Track total underlying asset supply
            uaSupply += remainingAmount;
        }
    }

    // DirectLPs and Traders engaging the CorePool directly will need LCC. LCC is 1:1 with the underlying asset.
    function _wrap(address from, address to, uint256 amount) internal {
        ERC20 uaToken = ERC20(underlyingAsset);

        // mint some tokens
        _mint(to, amount);

        // transfer the equivalent of the underlying asset from the recipient
        SafeTransferLib.safeTransferFrom(uaToken, from, address(this), amount);

        uaSupply += amount;
    }

    function wrap(uint256 amount) external {
        _wrap(msg.sender, msg.sender, amount);
    }

    /**
     * @dev Unwraps LCC from a specific market's liquidity reserves
     * @param marketId The market to unwrap from
     * @param to The recipient of underlying assets
     * @param amount The amount to unwrap from this market
     * @return The amount actually unwrapped from this market
     */
    function _unwrapFromMarket(bytes32 marketId, address from, address to, uint256 amount) internal returns (uint256) {
        // Use market liquidity
        uint256 amountAvailable = _useMarketLiquidity(marketId, amount);

        // Add remainder to market-specific debt queue
        uint256 deficit = amount - amountAvailable;
        if (deficit > 0) {
            _addMarketDebtRequest(marketId, to, deficit);
        }

        // Update user's market balance
        userMarketBalances[from][marketId] -= amountAvailable;

        // Transfer what we can immediately
        if (amountAvailable > 0) {
            _transferUnderlyingAssets(to, amountAvailable);
        }

        return amountAvailable;
    }

    /**
     * @dev Unwraps LCC from general liquidity pool (wrapped LCC)
     * @dev Unwraps using liquidity that was provided by wrapping
     * @param to The recipient of underlying assets
     * @param amount The amount to unwrap from general pool
     * @return The amount actually unwrapped
     */
    function _unwrapFromGeneralPool(address to, uint256 amount) internal returns (uint256) {
        // Wrapped LCC should always be fully backed by uaSupply
        // No debt queue needed ? - this should always succeed

        if (uaSupply < amount) {
            // This should never happen in a properly functioning system
            // If it does, it's a bug in the accounting
            // Do we need to track amount wrapped as well.
            revert InsufficientWrappedLiquidity(amount, uaSupply);
        }

        // Transfer the full amount
        _transferUnderlyingAssets(to, amount);

        // Should Always returns full amount
        return amount;
    }

    // Users should only be able to unwrap if LCC in their wallet.
    // unwrap some tokens - engaged by the Trader
    function _unwrap(address from, address to, uint256 amount) internal {
        if (amount == 0 || amount > balanceOf[from]) {
            revert InvalidAmount();
        }

        uint256 remainingToUnwrap = amount;
        uint256 totalAmountUnwrapped = 0;

        // Step 1: Unwrap from user's market-specific balances first
        // This ensures market LCC uses market-specific liquidity
        bytes32[] memory userMarkets = _getUserMarkets(from);

        for (uint256 i = 0; i < userMarkets.length && remainingToUnwrap > 0; i++) {
            bytes32 marketId = userMarkets[i];
            uint256 userMarketBalance = userMarketBalances[from][marketId];

            if (userMarketBalance > 0) {
                uint256 amountFromThisMarket = Math.min(remainingToUnwrap, userMarketBalance);

                // Try to unwrap from this market's liquidity
                uint256 amountUnwrapped = _unwrapFromMarket(marketId, from, to, amountFromThisMarket);

                totalAmountUnwrapped += amountUnwrapped;
                remainingToUnwrap -= amountFromThisMarket;
            }
        }

        // Step 2: Any remaining amount comes from wrapped LCC (general pool)
        if (remainingToUnwrap > 0) {
            uint256 amountUnwrapped = _unwrapFromGeneralPool(to, remainingToUnwrap);
            totalAmountUnwrapped += amountUnwrapped;
        }

        // Burn the full amount of LCC tokens
        _burn(from, amount);
    }

    function unwrap(uint256 amount) external {
        _unwrap(msg.sender, msg.sender, amount);
    }

    function wrapTo(address to, uint256 amount) external {
        _wrap(msg.sender, to, amount);
    }

    function unwrapTo(address to, uint256 amount) external {
        _unwrap(msg.sender, to, amount);
    }

    function _transferUnderlyingAssets(address user, uint256 amount) internal override {
        // confirm the amount is valid and not greater than the uaSupply
        require(amount > 0 && amount <= uaSupply, "invalid amount");

        uaSupply -= amount;

        SafeTransferLib.safeTransfer(ERC20(underlyingAsset), user, amount);
    }

    // TODO: Re-enable protocol-bounds in the future...

    // On transfer hook
    // function onTransfer(address from, address to, uint256 amount) internal onlyProtocolTransfer(msg.sender, to){
    function onTransfer(address, address to, uint256 amount) internal {
        _processMarketTracing(to, amount);
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
     * @dev Get the tracing flag and current market from the core hook
     * @return isTracingActive Whether tracing is active
     * @return currentMarket The current market if any is set
     */
    function _getCoreHookFlags() internal view returns (bool isTracingActive, bytes32 currentMarket) {
        // get the core hook from the market factory
        address coreHook = IMarketFactory(marketFactory).getCoreHook();

        // read in all the bytes from the transient storage of the hook contract
        bytes32 tracingFlagBytes = IExttload(coreHook).exttload(TransientSlots.TRACING_FLAG_SLOT);
        bytes32 currentMarketBytes = IExttload(coreHook).exttload(TransientSlots.CURRENT_MARKET_SLOT);

        // set the tracing flag and current market
        isTracingActive = tracingFlagBytes != bytes32(0);
        currentMarket = currentMarketBytes;
    }

    /**
     * @dev Process the market tracing logic
     * @param recipient The recipient of the transfer
     * @param amount The amount of the transfer
     */
    function _processMarketTracing(address recipient, uint256 amount) private {
        // get the appropriate flags from the core hook
        address coreHook = IMarketFactory(marketFactory).getCoreHook();

        // read in all the bytes from the transient storage of the hook contract
        // Read transient storage from CoreHook
        bytes32 tracingFlagBytes = IExttload(coreHook).exttload(TransientSlots.TRACING_FLAG_SLOT);
        bytes32 currentMarketBytes = IExttload(coreHook).exttload(TransientSlots.CURRENT_MARKET_SLOT);

        // Tracing is active if this flag has been set by the core hook right after a swap
        bool isTracingActive = tracingFlagBytes != bytes32(0);
        bool isProtocolBound = IMarketFactory(marketFactory).bounds(recipient);
        bytes32 currentMarket = currentMarketBytes;

        if (isTracingActive && !isProtocolBound) {
            // CRITICAL CHECK: Ensure this LCC belongs to the active market
            if (!_isLCCSupportedByMarket(currentMarket)) {
                return; // This LCC doesn't belong to the active market
            }

            // Process the market tracing logic
            _trackMarketAcquisition(recipient, currentMarket, amount);
        }
    }

    /**
     * @dev Check if the LCC is supported by the market
     * @param marketId The ID of the market i.e for uniswap v4 it is the core pool id
     * @return bool True if the LCC is supported by the market, false otherwise
     */
    function _isLCCSupportedByMarket(bytes32 marketId) internal view returns (bool) {
        // get the core pool from the market factory
        PoolId corePool = IMarketFactory(marketFactory).coreToProxy(PoolId.wrap(marketId));

        // get the two currencies that the core pool is trading
        address[2] memory currencies = IMarketFactory(marketFactory).corePoolToCurrencyPair(corePool);

        // Check if this LCC contract matches either currency in the core pool
        address lccAddress = address(this);
        return (lccAddress == currencies[0] || lccAddress == currencies[1]);
    }

    /**
     * @dev Gets all markets a user has LCC from
     * @param user The user address
     * @return Array of market IDs the user has balances in
     */
    function _getUserMarkets(address user) public view returns (bytes32[] memory) {
        bytes32[] memory userMarkets = new bytes32[](knownMarkets.length);
        uint256 count = 0;

        for (uint256 i = 0; i < knownMarkets.length; i++) {
            bytes32 marketId = knownMarkets[i];
            if (userMarketBalances[user][marketId] > 0) {
                userMarkets[count] = marketId;
                count++;
            }
        }
        return userMarkets;
    }
}
