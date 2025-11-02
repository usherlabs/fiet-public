// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ILCC} from "./interfaces/ILCC.sol";
import {ILiquidityHub} from "./interfaces/ILiquidityHub.sol";
import {OracleUtils} from "./libraries/OracleUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract LiquidityCommitmentCertificate is ERC20, Ownable, ILCC {
    using SafeERC20 for IERC20;
    error SenderNotIssuer(address sender);
    error InvalidUnderlyingAsset();
    error TransferNotAllowed();
    error InvalidAmount();
    error InsufficientETH();
    error InvalidMarketFactory();
    error InsufficientWrappedLiquidity(uint256 requested, uint256 available);
    error InsufficientBalance(address sender, uint256 balance, uint256 needed);

    uint8 private immutable _decimals;
    address private immutable underlyingAsset;
    IMarketFactory private immutable marketFactory;
    address private immutable marketVaultAddress; // ie. the uniswap v4 pool manager
    address private immutable resilientOracleAddress;
    ILiquidityHub private immutable hub;

    mapping(address => uint256) private wrappedBalances;
    mapping(address => uint256) private marketDerivedBalances;

    /**
     * @param _underlyingAsset The underlying asset of the LCC.
     * @param name The token name
     * @param symbol The token symbol
     * @param __decimals The token decimals
     * @param _resilientOracleAddress The address of the resilient oracle
     */
    constructor(
        address _marketFactory,
        address _underlyingAsset,
        string memory name,
        string memory symbol,
        uint8 __decimals,
        address _resilientOracleAddress
    ) ERC20(name, symbol) Ownable(_msgSender()) {
        if (_underlyingAsset == address(0)) {
            revert InvalidUnderlyingAsset();
        }

        _decimals = __decimals;
        underlyingAsset = _underlyingAsset;
        resilientOracleAddress = _resilientOracleAddress;
        marketFactory = IMarketFactory(_marketFactory);
        hub = ILiquidityHub(_msgSender());

        // Note: bounds are managed by the MarketFactory, not set in constructor
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

        // Allow transfers between protocol bounds
        if (fromProtocol && toProtocol) {
            return true;
        }

        // Allow protocol -> non-protocol transfers
        if (fromProtocol && !toProtocol) {
            return true;
        }

        // Allow non-protocol -> protocol transfers
        if (!fromProtocol && toProtocol) {
            return true;
        }

        // Block non-protocol -> non-protocol transfers
        return false;
    }

    /**
     * @dev Get the market ID of the LCC
     * @return The market ID of the LCC
     */
    function marketId() external view returns (bytes32) {
        (, bytes32 id,,) = hub.lccToMarket(address(this));
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
     * @return wrapped The wrapped balance
     * @return marketDerived The market-derived balance
     */
    function balancesOf(address account) public view virtual returns (uint256 wrapped, uint256 marketDerived) {
        return (wrappedBalances[account], marketDerivedBalances[account]);
    }

    /**
     * @notice Issues LCC tokens to an address (called by factory after validating permissions)
     * @param to The address to mint tokens to
     * @param directAmount The amount to issue to direct balance
     * @param marketAmount The amount to issue to market-derived balance
     */
    function mint(address to, uint256 directAmount, uint256 marketAmount) external onlyOwner {
        uint256 amount = directAmount + marketAmount;
        if (amount == 0) {
            revert InvalidAmount();
        }
        _mint(to, amount);
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
    function burn(address from, uint256 directAmount, uint256 marketAmount) external onlyOwner {
        uint256 amount = directAmount + marketAmount;
        if (amount == 0) {
            revert InvalidAmount();
        }
        _burn(from, amount);
        if (marketAmount > 0) {
            marketDerivedBalances[from] -= amount;
        }
        if (directAmount > 0) {
            wrappedBalances[from] -= amount;
        }
    }

    function _onTransfer(address from, address to, uint256 amount) internal {
        bool fromProtocol = marketFactory.bounds(from);
        bool toProtocol = marketFactory.bounds(to);
        bool isProtocolTransfer = _isProtocolTransfer(from, to, fromProtocol, toProtocol);

        if (!isProtocolTransfer) {
            revert TransferNotAllowed();
        }

        if (fromProtocol && toProtocol) {
            // Protocol -> Protocol: do not accrue buckets to protocol addresses
            return;
        } else if (fromProtocol && !toProtocol) {
            // Protocol -> Non-protocol: receiver accrues market-derived balance; protocol buckets remain untouched
            marketDerivedBalances[to] += amount;
        } else if (!fromProtocol && toProtocol) {
            // Non-protocol -> Protocol: decrement sender balances (market-derived first, then wrapped). Protocol accrues nothing
            uint256 totalBalance = marketDerivedBalances[from] + wrappedBalances[from];
            if (totalBalance < amount) {
                // This should never happen, as balanceOf from ERC20 will throw first.
                revert InsufficientBalance(from, totalBalance, amount);
            }
            // Before adjusting local buckets, annul any portion that bleeds into queued settlements
            hub.annulSettlementBeforeTransfer(
                address(this), from, wrappedBalances[from], marketDerivedBalances[from], amount
            );
            uint256 fromMarketDerived = Math.min(marketDerivedBalances[from], amount);
            marketDerivedBalances[from] -= fromMarketDerived;
            uint256 remaining = amount - fromMarketDerived;
            if (remaining > 0) {
                uint256 fromWrapped = Math.min(wrappedBalances[from], remaining);
                wrappedBalances[from] -= fromWrapped;
            }
            // Protocol should not accrue bucket balances
        }
        // Non-protocol -> Non-protocol: blocked by modifier, shouldn't reach here
    }

    function transfer(address to, uint256 amount) public virtual override(ERC20, IERC20) returns (bool) {
        _onTransfer(_msgSender(), to, amount);
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount)
        public
        virtual
        override(ERC20, IERC20)
        returns (bool)
    {
        _onTransfer(from, to, amount);
        return super.transferFrom(from, to, amount);
    }
}
