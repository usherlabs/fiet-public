// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import "forge-std/console.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {IMarketFactory} from "./interfaces/IMarketFactory.sol";

contract LiquidityCommitmentCertificate is ERC20 {
    error InvalidUnderlyingAsset();
    error TransferNotAllowed();
    error InvalidAmount();
    error InvalidMarketFactory();

    address public immutable underlyingAsset;
    address public immutable marketFactory;

    // All native underlying liquidity will either be
    mapping(address => bool) public issuers;

    uint256 public uaSupply; // underlying asset supply

    modifier isIssuer(address sender) {
        require(issuers[sender], "SENDER NOT ISSUER");
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
     * @param _bounds The protocol addresses that form the LCC bounds. - Uniswap PoolManager, Routers, etc. is managed by an owner for dev-safety.
     * @param _marketFactory The MarketFactory contract that manages this LCC.
     */
    constructor(address _underlyingAsset, address[] memory _issuers, address _marketFactory) {
        // TODO: handle ETH native token is future?
        if (_underlyingAsset == address(0)) {
            revert InvalidUnderlyingAsset();
        }
        if (_marketFactory == address(0)) {
            revert InvalidMarketFactory();
        }

        underlyingAsset = _underlyingAsset;
        marketFactory = _marketFactory;

        IERC20Metadata metadata = IERC20Metadata(underlyingAsset);
        string memory _name = metadata.name();
        string memory _symbol = metadata.symbol();
        uint8 _decimals = metadata.decimals();

        for (uint256 i = 0; i < _issuers.length; i++) {
            issuers[_issuers[i]] = true;
        }

        bounds[address(this)] = true;
        for (uint256 i = 0; i < _bounds.length; i++) {
            bounds[_bounds[i]] = true;
        }

        string memory prefixedSymbol = string.concat("lcc-", _symbol);
        string memory prefixedName = string.concat("Fiet Liquidity Commitment Certificate for ", _name);
        ERC20(prefixedName, prefixedSymbol, _decimals);
    }

    // some trusted issuer Smart Contracts can be allowed to mint tokens and hold the liquidity
    // this minting provides tokens at a 1:1 ratio and intended for onchain preswap wrapping
    function mint(uint256 amount) external isIssuer(msg.sender) {
        address issuer = msg.sender;
        _mint(issuer, amount);
    }

    // DirectLPs and Traders engaging the CorePool directly will need LCC. LCC is 1:1 with the underlying asset.
    function _wrap(address from, address to, uint256 amount) internal {
        ERC20 uaToken = ERC20(underlyingAsset);

        // transfer the equivalent of the underlying asset from the recipient
        SafeTransferLib.safeTransferFrom(uaToken, from, address(this), amount);
        // mint some tokens
        _mint(to, amount);

        uaSupply += amount;
    }

    // unwrap some tokens - engaged by the Trader
    function _unwrap(address from, address to, uint256 amount) internal {
        ERC20 uaToken = ERC20(underlyingAsset);

        if (amount == 0 || amount > balanceOf[from]) {
            revert InvalidAmount();
        }

        uint256 amountToUnwrap;
        uint256 deficit = 0;
        if (uaSupply < amount) {
            // Is insufficient liquidity
            amountToUnwrap = uaSupply;
            deficit = amount - uaSupply;
        } else {
            // Is sufficient liquidity
            amountToUnwrap = amount;
        }

        // and burn their tokens
        _burn(from, amount);
        // reduce the underlying asset supply
        uaSupply -= amount;

        if (deficit > 0) {
            // TODO: https://www.notion.so/usherlabs/Outcomes-of-LCC-Insufficient-Liquidity-22b6d8286da580c8a455efc4175970a0?source=copy_link#22b6d8286da580de8a33cf367d3b7220
            // TODO: Add LCC into a queue, where if new liquidity is settled, it immediately covers the unwrap within their wallet.
        }

        SafeTransferLib.safeTransfer(uaToken, to, amountToUnwrap);
    }

    function wrap(uint256 amount) external {
        _wrap(msg.sender, msg.sender, amount);
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

    // ? We may not need a withdraw for ProxyHook, as poolManager settle can from this LCC.
    // function withdraw(address to, uint256 amount) public isIssuer(msg.sender) {
    //     IERC20 underlying_asset_token = IERC20(underlyingAsset);
    //     underlying_asset_token.transferFrom(custodian, to, amount);
    // }

    // TODO: Re-enable in the future...
    // function transfer(address to, uint256 amount)
    //     public
    //     virtual
    //     override
    //     onlyProtocolTransfer(msg.sender, to)
    //     returns (bool)
    // {
    //     return super.transfer(to, amount);
    // }

    // function transferFrom(address from, address to, uint256 amount)
    //     public
    //     virtual
    //     override
    //     onlyProtocolTransfer(from, to)
    //     returns (bool)
    // {
    //     return super.transferFrom(from, to, amount);
    // }
}
