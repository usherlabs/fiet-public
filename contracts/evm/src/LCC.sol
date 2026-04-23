// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {ILCC} from "./interfaces/ILCC.sol";
import {ILiquidityHub} from "./interfaces/ILiquidityHub.sol";
import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
import {Bounds} from "./libraries/Bounds.sol";
import {OracleUtils} from "./libraries/OracleUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Errors} from "./libraries/Errors.sol";

contract LiquidityCommitmentCertificate is ERC20, ILCC {
    uint8 private immutable _decimals;
    address private immutable underlyingAsset;
    address private immutable resilientOracleAddress;
    address public immutable factory;
    address public immutable hub;

    mapping(address => uint256) private wrappedBalances;
    mapping(address => uint256) private marketDerivedBalances;

    /**
     * @param _underlyingAsset The underlying asset of the LCC.
     * @param name The token name
     * @param symbol The token symbol
     * @param __decimals The token decimals
     * @param _resilientOracleAddress The address of the resilient oracle
     * @param _hub The LiquidityHub authority for this LCC
     * @param _factory The MarketFactory namespace for bound checks and sequencing
     */
    constructor(
        address _underlyingAsset,
        string memory name,
        string memory symbol,
        uint8 __decimals,
        address _resilientOracleAddress,
        address _hub,
        address _factory
    ) ERC20(name, symbol) {
        if (_hub == address(0)) revert Errors.InvalidAddress(_hub);
        if (_factory == address(0)) revert Errors.InvalidAddress(_factory);

        _decimals = __decimals;
        underlyingAsset = _underlyingAsset;
        resilientOracleAddress = _resilientOracleAddress;
        hub = _hub;
        factory = _factory;

        // Note: bounds are managed by the LiquidityHub, not set in constructor
    }

    modifier onlyHub() {
        _onlyHub();
        _;
    }

    function _onlyHub() internal view {
        if (_msgSender() != hub) {
            revert Errors.InvalidSender();
        }
    }

    function _isProtocolTransfer(address from, address to, bool fromProtocol, bool toProtocol)
        internal
        pure
        returns (bool)
    {
        // Allow transfers from/to zero address (minting/burning)
        if (from == address(0) || to == address(0)) {
            return true;
        }

        // Any transfer with at least one protocol-bound endpoint is allowed.
        // Non-protocol -> non-protocol transfers are blocked.
        return fromProtocol || toProtocol;
    }

    /**
     * @dev Get the market ID of the LCC
     * @return The market ID of the LCC
     */
    function marketId() external view returns (bytes32) {
        (bytes32 id,) = ILiquidityHub(hub).lccToMarket(address(this));
        return id;
    }

    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    /**
     * @dev Get the underlying asset of the LCC
     * @return The underlying asset of the LCC
     */
    function underlying() external view returns (address) {
        // the `ResilientOracle` may call underlying() - https://github.com/VenusProtocol/oracle/blob/develop/contracts/ResilientOracle.sol#L279
        // if it calls underlying for lcc-eth (where underlyingAsset is address(0))
        // it will attempt to call erc20.decimals() which will error.
        // To ensure full compatibility, we cover this edge case by observing if the caller is ResilientOracle, and modifying the response.

        if (_msgSender() == resilientOracleAddress) {
            return OracleUtils.unifyNativeTokenAddress(underlyingAsset);
        }
        return underlyingAsset;
    }

    /**
     * @dev Get the balance breakdown for an account
     * @param account The account address
     * @return wrapped The wrapped (direct-backed) bucket balance for bucket-tracked holders; always zero for
     *         `BOUND_EXEMPT` endpoints (see invariant: exempt-held LCC is semantically market-derived for views).
     * @return marketDerived The market-derived bucket balance; for exempt holders equals full ERC20 balance.
     */
    function balancesOf(address account) public view virtual returns (uint256 wrapped, uint256 marketDerived) {
        // Only bucket-exempt protocol endpoints are allowed to hold ERC20 balance without per-address bucket maps.
        // Their ERC20 balance is not durable Domain A (wrapped) holder inventory: issuer paths mint market-only to
        // exempt; egress to non-protocol credits market-derived; issuer `cancel` burns market-only. Expose that
        // consistently here so off-chain and Hub helpers do not read exempt balance as wrapped.
        uint256 balanceSum = wrappedBalances[account] + marketDerivedBalances[account];
        uint256 fullBalance = balanceOf(account);
        if (Bounds.isExempt(ILiquidityHub(hub).boundLevel(factory, account))) {
            return (0, fullBalance);
        }
        if (balanceSum != fullBalance) {
            revert Errors.InvalidBucketState(account, fullBalance);
        }
        return (wrappedBalances[account], marketDerivedBalances[account]);
    }

    /**
     * @notice Issues LCC tokens to an address (called by factory after validating permissions)
     * @param to The address to mint tokens to
     * @param directAmount The amount to issue to direct balance
     * @param marketAmount The amount to issue to market-derived balance
     */
    function mint(address to, uint256 directAmount, uint256 marketAmount) external onlyHub {
        uint256 amount = directAmount + marketAmount;
        if (amount == 0) {
            revert Errors.InvalidAmount(0, 0);
        }
        // Direct-backed mints require bucket accounting; exempt endpoints skip buckets (see early return below).
        // Allowing directAmount > 0 to exempt would misalign `directSupply` with per-holder buckets and allow
        // Domain A liquidity to sit on an address that does not carry wrapped bucket state (exempt `balancesOf`
        // reports market-derived only; egress still reclassifies to recipients as market-derived).
        if (Bounds.isExempt(ILiquidityHub(hub).boundLevel(factory, to)) && directAmount > 0) {
            revert Errors.MintToNotAllowedRecipient(to);
        }
        _mint(to, amount);
        // Bucket bookkeeping is skipped only for bucket-exempt protocol endpoints.
        // Bound-role changes across the exempt boundary are restricted on-chain (see `BoundRegistry._setBoundLevel` / MKT-04A);
        // bucket-tracked endpoints and users must populate bucket maps; otherwise
        // the recipient becomes "bucketless with nonzero ERC20 balance" and cannot correctly transfer/unwrap.
        // In standard MarketFactory, only VTSO and ProxyHook/MarketVault are issuers. VTSO mints to MMPM for new positions, where PoolManager is exempt, and triggers burn on PoolManager -> MMPM (after) transfer
        if (Bounds.isExempt(ILiquidityHub(hub).boundLevel(factory, to))) return;
        if (marketAmount > 0) {
            marketDerivedBalances[to] += marketAmount;
        }
        if (directAmount > 0) {
            wrappedBalances[to] += directAmount;
        }
    }

    /**
     * @notice Cancels LCC tokens from an issuer (called by factory after validating permissions)
     * @param from The address to burn tokens from
     * @param directAmount The amount to cancel from direct balance
     * @param marketAmount The amount to cancel from market-derived balance
     */
    function burn(address from, uint256 directAmount, uint256 marketAmount) external onlyHub {
        uint256 amount = directAmount + marketAmount;
        if (amount == 0) {
            revert Errors.InvalidAmount(0, 0);
        }
        _burn(from, amount);
        // Bucket bookkeeping is skipped only for bucket-exempt protocol endpoints.
        // Bucket-tracked endpoints and users must decrement bucket maps.
        if (Bounds.isExempt(ILiquidityHub(hub).boundLevel(factory, from))) return;
        if (marketAmount > 0) {
            marketDerivedBalances[from] -= marketAmount;
        }
        if (directAmount > 0) {
            wrappedBalances[from] -= directAmount;
        }
    }

    /**
     * @dev Hook called before token transfer
     * @param from The sender address
     * @param to The recipient address
     * @param amount The transfer amount
     */
    function _beforeTransfer(address from, address to, uint256 amount) internal {
        (uint8 fromLevel, uint8 toLevel) = ILiquidityHub(hub).boundLevels(factory, from, to);
        bool fromProtocol = Bounds.isEndpoint(fromLevel);
        bool toProtocol = Bounds.isEndpoint(toLevel);
        bool isProtocolTransfer = _isProtocolTransfer(from, to, fromProtocol, toProtocol);

        if (!isProtocolTransfer) {
            revert Errors.TransferNotAllowed();
        }

        if (!fromProtocol && toProtocol) {
            _handleNonProtocolToProtocol(from, to, amount, toLevel);
            return;
        }

        if (fromProtocol && !toProtocol) {
            _handleProtocolToNonProtocol(from, to, amount, fromLevel);
            return;
        }

        if (fromProtocol && toProtocol) {
            _handleProtocolToProtocol(from, to, amount, fromLevel, toLevel);
        }
        // Non-protocol -> Non-protocol: blocked above, shouldn't reach here
    }

    function _handleNonProtocolToProtocol(address from, address to, uint256 amount, uint8 toLevel) internal {
        uint256 totalBalance = marketDerivedBalances[from] + wrappedBalances[from];
        if (totalBalance < amount) {
            // This should never happen, as balanceOf from ERC20 will throw first.
            revert Errors.InsufficientBalance(totalBalance, amount);
        }
        // Before adjusting local buckets, annul any portion that bleeds into queued settlements.
        // This preserves queue/backing integrity across protocol-bound transfers; it is not itself
        // a substitute for settlement-time serviceability checks.
        ILiquidityHub(hub)
            .annulSettlementBeforeTransfer(from, wrappedBalances[from], marketDerivedBalances[from], amount);

        // Non-protocol -> Protocol: decrement sender balances (market-derived first, then wrapped).
        uint256 fromMarketDerived = Math.min(marketDerivedBalances[from], amount);
        uint256 remaining = amount - fromMarketDerived;
        uint256 fromWrapped = Math.min(wrappedBalances[from], remaining);
        marketDerivedBalances[from] -= fromMarketDerived;
        wrappedBalances[from] -= fromWrapped;

        // Protocol accrues buckets only if it is bucket-tracked.
        if (!Bounds.isExempt(toLevel)) {
            marketDerivedBalances[to] += fromMarketDerived;
            wrappedBalances[to] += fromWrapped;
        } else if (Bounds.isDex(toLevel)) {
            // DEX ingress: always run `prepareMarketLiquidity` so `prepareMarketLiquidityIngress` can enforce
            // unlock, active `sync(lcc)`, and `balance(PoolManager) == syncedReserves` even when `fromWrapped == 0`
            // (LCC-03; `handleIngress` only runs when wrappedAmount > 0). Market-derived-only transfers that are not
            // inside a valid window revert here, blocking stray LCC and later `NestedIngressUnpaidTransferExists`
            // griefing.
            IMarketFactory(factory).prepareMarketLiquidity(address(this), fromWrapped);
        }
    }

    function _handleProtocolToNonProtocol(address from, address to, uint256 amount, uint8 fromLevel) internal {
        if (Bounds.isExempt(fromLevel)) {
            // Bucket-exempt protocol -> non-protocol: credit as market-derived (legacy behaviour).
            marketDerivedBalances[to] += amount;
            return;
        }

        uint256 totalBalance = marketDerivedBalances[from] + wrappedBalances[from];
        if (totalBalance < amount) {
            revert Errors.InsufficientBalance(totalBalance, amount);
        }
        uint256 fromMarketDerived = Math.min(marketDerivedBalances[from], amount);
        uint256 remaining = amount - fromMarketDerived;
        uint256 fromWrapped = Math.min(wrappedBalances[from], remaining);
        marketDerivedBalances[from] -= fromMarketDerived;
        wrappedBalances[from] -= fromWrapped;
        marketDerivedBalances[to] += fromMarketDerived;
        wrappedBalances[to] += fromWrapped;
    }

    function _handleProtocolToProtocol(address from, address to, uint256 amount, uint8 fromLevel, uint8 toLevel)
        internal
    {
        if (Bounds.isExempt(fromLevel)) {
            // Bucket-exempt -> protocol: only credit bucket-tracked recipients.
            if (!Bounds.isExempt(toLevel)) {
                marketDerivedBalances[to] += amount;
            } else if (Bounds.isDex(toLevel)) {
                // DEX (bucket-exempt): run zero-wrapped validation when origin has no bucket split (LCC-03).
                IMarketFactory(factory).prepareMarketLiquidity(address(this), 0);
            }
            return;
        }

        uint256 totalBalance = marketDerivedBalances[from] + wrappedBalances[from];
        if (totalBalance < amount) {
            revert Errors.InsufficientBalance(totalBalance, amount);
        }
        uint256 fromMarketDerived = Math.min(marketDerivedBalances[from], amount);
        uint256 fromWrapped = Math.min(wrappedBalances[from], amount - fromMarketDerived);
        marketDerivedBalances[from] -= fromMarketDerived;
        wrappedBalances[from] -= fromWrapped;
        if (!Bounds.isExempt(toLevel)) {
            marketDerivedBalances[to] += fromMarketDerived;
            wrappedBalances[to] += fromWrapped;
        } else if (Bounds.isDex(toLevel)) {
            // Non-exempt -> DEX: same as `nonProtocol -> DEX` — always validate ingress; `fromWrapped` may be zero.
            IMarketFactory(factory).prepareMarketLiquidity(address(this), fromWrapped);
        }
    }

    /**
     * @dev Hook called after token transfer
     * @param from The sender address
     * @param to The recipient address
     */
    function _afterTransfer(
        address from,
        address to,
        uint256 /* amount */
    )
        internal
    {
        // Execute planned cancellations after transfer completes (tokens are now in recipient's balance)
        ILiquidityHub(hub).executePlannedCancel(from, to);
    }

    /**
     * @dev Override _update to add before/after transfer hooks
     */
    function _update(address from, address to, uint256 value) internal virtual override {
        // Call before hook for validation and settlement annulment
        if (from != address(0) && to != address(0)) {
            _beforeTransfer(from, to, value);
        }

        // Execute the actual transfer
        super._update(from, to, value);

        // Call after hook for planned cancel execution and balance bucket updates
        if (from != address(0) && to != address(0)) {
            _afterTransfer(from, to, value);
        }
    }
}
