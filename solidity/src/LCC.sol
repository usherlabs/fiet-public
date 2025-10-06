// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
import {MarketLiquidity} from "./modules/MarketLiquidity.sol";
import {IExttload} from "v4-periphery/lib/v4-core/src/interfaces/IExttload.sol";
import {TransientSlots} from "./libraries/TransientSlots.sol";
import {PoolId} from "v4-periphery/lib/v4-core/src/types/PoolId.sol";
import {IProxyHook} from "./interfaces/IProxyHook.sol";
import {MarketVault} from "./modules/MarketVault.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {IOracle} from "./interfaces/IOracle.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IOracleRegistry} from "./interfaces/IOracleRegistry.sol";
import {IVTSManager} from "./interfaces/IVTSManager.sol";
import {console} from "forge-std/console.sol";
import {ILCC} from "./interfaces/ILCC.sol";

contract LiquidityCommitmentCertificate is
    ERC20,
    MarketLiquidity,
    Ownable,
    ILCC
{
    using SafeTransferLib for ERC20;

    error SenderNotIssuer(address sender);
    error InvalidUnderlyingAsset();
    error TransferNotAllowed();
    error InvalidAmount();
    error InvalidMarketFactory();
    error InsufficientWrappedLiquidity(uint256 requested, uint256 available);

    address public immutable underlyingAsset;
    address public immutable marketFactory;

    // All native underlying liquidity will either be
    mapping(address => bool) public issuers;

    uint256 public uaSupply; // underlying asset supply ONLY within the LCC.

    modifier onlyIssuer() {
        address caller = msg.sender;
        // Check the caller if they are a trusted proxy hook
        // Get if the caller is a registered proxy hook
        // If it is, then we need to get the two currencies it proxies
        // Then check if the underlying asset falls under any of the two currencies it supports
        address[2] memory currencies = IMarketFactory(marketFactory)
            .proxyHookToCurrencyPair(caller);
        bool isAssetProxyPool = (currencies[0] == underlyingAsset ||
            currencies[1] == underlyingAsset);
        bool isValidIssuer = issuers[caller] || isAssetProxyPool;

        // if caller is not a valid issuer then revert
        if (!isValidIssuer) {
            revert SenderNotIssuer(caller);
        }
        _;
    }

    modifier onlyProtocolTransfer(address from, address to) {
        // Allow transfers from/to zero address (minting/burning)
        if (from == address(0) || to == address(0)) {
            _;
            return;
        }

        IMarketFactory mf = IMarketFactory(marketFactory);

        // Allow transfers between protocol bounds
        if (mf.bounds(to) || mf.bounds(from)) {
            _;
            return;
        }

        // Only protocol bounds can transfer to non-bounds (EOAs, other contracts)
        if (!mf.bounds(from)) {
            revert TransferNotAllowed();
        }

        _;
    }

    /**
     * @param _underlyingAsset The underlying asset of the LCC.
     * @param _issuers The issuers of the LCC. ProxyHook, and MMPositionManager
     * @param _marketFactory The MarketFactory contract that manages this LCC.
     */
    constructor(
        address _underlyingAsset,
        address[] memory _issuers,
        address _marketFactory
    )
        ERC20(
            string.concat(
                "Fiet Liquidity Commitment Certificate for ",
                IERC20Metadata(_underlyingAsset).name()
            ),
            string.concat("lcc-", IERC20Metadata(_underlyingAsset).symbol()),
            IERC20Metadata(_underlyingAsset).decimals()
        )
        Ownable(msg.sender)
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

        if (amount == 0) {
            revert InvalidAmount();
        }

        _mint(issuer, amount);

        // totalSupply will be greater than uaSupply (supply of underlying asset in LCC)
        // This is because the PoolManager will custody the difference.
    }

    function cancel(uint256 amount) external onlyIssuer {
        address issuer = msg.sender;

        if (amount == 0) {
            revert InvalidAmount();
        }

        _burn(issuer, amount);

        // totalSupply will return back to uaSupply now that the surplus LCC managed by the issuer engagin the PoolManager has been cancelled.
    }

    // Called by Issuer before settling liquidity from LCCs to the market.
    function prepareSettle(uint256 amount) external onlyIssuer {
        // Allow issuer to facilitate direct liquidity provision transfer of underlying tokens
        ERC20(underlyingAsset).approve(msg.sender, amount);
        uaSupply -= amount;
    }

    // Called by Issuer after taking liquidity from the market to LCC.
    // Accounts for Vault -> LCC. if shouldProcessQueue is true, Vault -> Recipients.
    function confirmTake(
        bytes32 marketId,
        uint256 amount,
        bool shouldProcessQueue
    ) external onlyIssuer {
        // Track which market this underlying asset liquidity derived from.
        _trackReceivedLiquidity(marketId, amount);
        // Track total underlying asset supply
        uaSupply += amount;
        if (shouldProcessQueue) {
            _processSettlementQueue(marketId, amount, true);
        }
    }

    // DirectLPs and Traders engaging the CorePool directly will need LCC. LCC is 1:1 with the underlying asset.
    function _wrap(address from, address to, uint256 amount) internal {
        // mint some tokens
        _mint(to, amount);

        // transfer the equivalent of the underlying asset from the recipient
        ERC20(underlyingAsset).safeTransferFrom(from, address(this), amount);

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
    function _unwrapFromMarketLiquidity(
        bytes32 marketId,
        address from,
        address to,
        uint256 amount
    ) internal returns (uint256) {
        // Use market liquidity
        uint256 amountAvailable = _useMarketLiquidity(marketId, amount, from);

        // When we unwrap, we first use whatever liquidity is directly wrapped.
        // Then, we turn to available in the market.
        // If there's deficit between the amount to unwrap from market and the amount available, then we're in an insufficient liquidity situation and we queue a settlement
        uint256 deficit = amount - amountAvailable;
        if (deficit > 0) {
            _addToSettlementQueue(marketId, to, deficit);
        }

        return amountAvailable;
    }

    /**
     * @dev Unwraps LCC from out-of-market liquidity pool (wrapped LCC) i.e LCC that was created by wrapping
     * @dev Unwraps using liquidity that was provided by wrapping
     * @param amount The amount to unwrap from general pool
     * @return The amount actually unwrapped
     */
    function _unwrapFromOOMLiquidity(
        uint256 amount
    ) internal view returns (uint256) {
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
            uint256 amountUnwrapped = _unwrapFromOOMLiquidity(amount);
            totalAmountUnwrapped += amountUnwrapped;
        }

        // any amount not wrapped should be unwrapped from the market
        uint256 remainingToUnwrap = amount - totalAmountUnwrapped;

        for (
            uint256 i = 0;
            i < userMarkets.length && remainingToUnwrap > 0;
            i++
        ) {
            bytes32 marketId = userMarkets[i];
            uint256 userMarketBalance = balanceOfUserFromMarket[from][marketId]; // inherited from MarketLiquidity

            if (userMarketBalance == 0) continue;

            // get the max amount that can be unwrapped from this market
            uint256 amountFromThisMarket = Math.min(
                remainingToUnwrap,
                userMarketBalance
            );

            // unwrap from this market's liquidity
            uint256 amountUnwrapped = _unwrapFromMarketLiquidity(
                marketId,
                from,
                to,
                amountFromThisMarket
            );

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

    function wrapTo(address to, uint256 amount) external {
        _wrap(msg.sender, to, amount);
    }

    function unwrapTo(address to, uint256 amount) external {
        _unwrap(msg.sender, to, amount);
    }

    function _transferUnderlyingAssets(address user, uint256 amount) internal {
        // confirm the amount is valid and not greater than the uaSupply
        require(amount > 0 && amount <= uaSupply, "invalid amount");
        uaSupply -= amount;

        ERC20(underlyingAsset).safeTransfer(user, amount);
    }

    // Pay an outstanding settlement to a user and burn their underlying tokens
    function _payOutstandingSettlementToUser(
        address user,
        uint256 amount
    ) internal override {
        _burn(user, amount);
        _transferUnderlyingAssets(user, amount);
    }

    // On transfer hook
    function onTransfer(
        address from,
        address to,
        uint256 amount
    ) internal onlyProtocolTransfer(msg.sender, to) {
        // clear any outstanding settlement in all markets to be paid to the sender initiating the transfer
        _annulUserSettlementBeforeTransfer(from, amount);

        // process the market tracing logic to find out which market the token transfer came from
        _processMarketTracing(to, amount);
    }

    function transfer(
        address to,
        uint256 amount
    ) public virtual override returns (bool) {
        onTransfer(msg.sender, to, amount);
        return super.transfer(to, amount);
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public virtual override returns (bool) {
        onTransfer(from, to, amount);
        return super.transferFrom(from, to, amount);
    }

    /**
     * @dev Get the price of the underlying asset
     * @return The price of the asset
     * @return The decimals of the asset
     */
    function usdPrice(
        address marketOracleFactory
    ) public view returns (uint256, uint256) {
        string memory quoteTicker = "USD";
        address oracleRegistry = IMarketFactory(marketFactory).oracleRegistry();
        // get the ticker of the underlying asset
        string memory ticker = IERC20Metadata(underlyingAsset).symbol();
        // asspend /quote to it eg /USDT
        string memory pricePair = string.concat(ticker, "/", quoteTicker);
        // get the price of the asset using oracle
        address oracle = IOracleRegistry(oracleRegistry).getOracle(
            pricePair,
            marketOracleFactory
        );

        // get the price of the asset
        uint256 assetPrice = IOracle(oracle).getPrice();
        uint256 decimals = IOracle(oracle).decimals();

        return (assetPrice, decimals);
    }

    /**
     * @dev Get the tracing flag and current market from the core hook
     * @return isTracingActive Whether tracing is active
     * @return currentMarket The current market if any is set
     */
    function _getCoreHookFlags()
        internal
        view
        returns (bool isTracingActive, bytes32 currentMarket)
    {
        // get the core hook from the market factory
        address coreHook = IMarketFactory(marketFactory).getCoreHook();

        // read in all the bytes from the transient storage of the hook contract
        bytes32 tracingFlagBytes = IExttload(coreHook).exttload(
            TransientSlots.TRACING_FLAG_SLOT
        );
        bytes32 currentMarketBytes = IExttload(coreHook).exttload(
            TransientSlots.CURRENT_MARKET_SLOT
        );

        // set the tracing flag and current market
        isTracingActive = tracingFlagBytes != bytes32(0);
        currentMarket = currentMarketBytes;
    }

    /**
     * @dev Annul the user's pending settlements partially or completely
     * @dev This is called before a transfer is made to clear any outstanding settlements to this user relative to the amount to settle.
     * @param fromUser The user to annul the pending settlements for
     * @param amountToTransfer The amount to transfer
     */
    function _annulUserSettlementBeforeTransfer(
        address fromUser,
        uint256 amountToTransfer
    ) internal {
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

        uint256 maxAmountCanTransferWithoutClearing = userBalance -
            userPendingSettlement;

        if (amountToTransfer > maxAmountCanTransferWithoutClearing) {
            uint256 amountToAnnul = amountToTransfer -
                maxAmountCanTransferWithoutClearing;
            // annull the equivalent pending settlements

            // If a transaction to process settlements occurs before the transfer. In that case, the user's LCC transfer will revert, and they'll have native assets in their wallet instead.
            _annulUserSettlement(fromUser, amountToAnnul);
        }
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
        bytes32 tracingFlagBytes = IExttload(coreHook).exttload(
            TransientSlots.TRACING_FLAG_SLOT
        );
        bytes32 currentMarketBytes = IExttload(coreHook).exttload(
            TransientSlots.CURRENT_MARKET_SLOT
        );

        // Tracing is active if this flag has been set by the core hook right after a swap
        bool isTracingActive = tracingFlagBytes != bytes32(0);
        bool isProtocolBound = IMarketFactory(marketFactory).bounds(recipient);
        bytes32 currentMarket = currentMarketBytes;

        if (isTracingActive && !isProtocolBound) {
            // ? !isProtocolBound is to ensure that we only process the market tracing logic for non-protocol bounds (ie. transfer to EOAs.)
            // CRITICAL CHECK: Ensure this LCC belongs to the active market
            if (!_isLCCSupportedByMarket(currentMarket)) {
                return; // This LCC doesn't belong to the active market
            }

            // Process the market tracing logic, letting us know where this LCC came from for this particular user
            _trackMarketAcquisition(recipient, currentMarket, amount);
        }
    }

    /**
     * @dev Check if the LCC is supported by the market i.e if the LCC is either token0 or token1 for a given core pool
     * @param marketId The ID of the market i.e for uniswap v4 it is the core pool id
     * @return bool True if the LCC is supported by the market, false otherwise
     */
    function _isLCCSupportedByMarket(
        bytes32 marketId
    ) internal view returns (bool) {
        // get the two currencies that the core pool is trading
        address[2] memory currencies = IMarketFactory(marketFactory)
            .corePoolToCurrencyPair(PoolId.wrap(marketId));

        // Check if this LCC contract matches either currency in the core pool
        address lccAddress = address(this);
        return (lccAddress == currencies[0] || lccAddress == currencies[1]);
    }

    function toERC20() external view returns (ERC20) {
        return ERC20(address(this));
    }
}
