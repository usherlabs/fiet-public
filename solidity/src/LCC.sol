// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import "forge-std/console.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

contract LiquidityCommitmentCertificate is ERC20, Ownable {
    error InvalidUnderlyingAsset();
    error TransferNotAllowed();

    address public immutable underlyingAsset;

    // All native underlying liquidity will either be
    mapping(address => bool) public issuers;
    mapping(address => bool) public bounds;

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
        if (bounds[to] || bounds[from]) {
            _;
            return;
        }

        // Only protocol bounds can transfer to non-bounds (EOAs, other contracts)
        if (!bounds[from]) {
            revert TransferNotAllowed();
        }

        _;
    }

    /**
     * @param _underlyingAsset The underlying asset of the LCC.
     * @param _issuers The issuers of the LCC. ProxyHook, and MMPositionManager
     * @param _bounds The protocol addresses that form the LCC bounds. - Uniswap PoolManager, Routers, etc. is managed by an owner for dev-safety.
     */
    constructor(address _underlyingAsset, address[] memory _issuers, address[] memory _bounds) Ownable(msg.sender) {
        // TODO: handle ETH native token is future?
        if (_underlyingAsset == address(0)) {
            revert InvalidUnderlyingAsset();
        }
        underlyingAsset = _underlyingAsset;
        metadata = IERC20Metadata(underlyingAsset);
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

    function addBounds(address[] memory _bounds) public onlyOwner {
        for (uint256 i = 0; i < _bounds.length; i++) {
            bounds[_bounds[i]] = true;
        }
    }

    function removeBounds(address[] memory _bounds) public onlyOwner {
        for (uint256 i = 0; i < _bounds.length; i++) {
            bounds[_bounds[i]] = false;
        }
    }

    // checks if there is sufficient liquidity to unwrap a token
    // compares current vts with base vts and returns
    function isSufficientLiquidity() internal pure returns (bool) {
        return true;
    }

    // some trusted issuer Smart Contracts can be allowed to mint tokens and hold the liquidity
    // this minting provides tokens at a 1:1 ratio and intended for onchain preswap wrapping
    function mint(uint256 amount) public isIssuer(msg.sender) {
        address issuer = msg.sender;
        _mint(issuer, amount);
    }

    // DirectLPs and Traders engaging the CorePool directly will need LCC. LCC is 1:1 with the underlying asset.
    function wrap(address custodian, uint256 amount) public validCustodian(custodian) onlyLP(msg.sender) {
        address owner = msg.sender;

        // transfer the equivalent of the underlying asset from the recipient
        SafeTransferLib.safeTransferFrom(underlyingAsset, owner, address(this), amount);
        // mint some tokens
        _mint(owner, amount);
    }

    // unwrap some tokens
    function unwrap(address to, uint256 amount) public validCustodian(msg.sender) {
        address custodian = msg.sender;
        IERC20 underlying_asset_token = IERC20(underlyingAsset);

        require(amount > 0 && amount <= custodians[custodian].totalSupply, "INVALID AMOUNT");

        if (isSufficientLiquidity()) {
            // and burn their tokens
            _burn(custodian, amount);
            // since the hook has paid back some of its debt, reduce by the promised amount
            custodians[custodian].totalSupply -= amount;

            // transfer underlying tokens to the user

            bool success = underlying_asset_token.transferFrom(custodian, to, amount);
            require(success, "Unwrap failed");
            console.log("Itoken: transferfrom done");
        } else {
            // TODO: https://www.notion.so/usherlabs/Outcomes-of-LCC-Insufficient-Liquidity-22b6d8286da580c8a455efc4175970a0?source=copy_link#22b6d8286da580de8a33cf367d3b7220

            // TODO: Add LCC into a queue, where if new liquidity is settled, it immediately covers the unwrap within their wallet.
        }
    }

    function transfer(address to, uint256 amount)
        public
        virtual
        override
        onlyProtocolTransfer(msg.sender, to)
        returns (bool)
    {
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount)
        public
        virtual
        override
        onlyProtocolTransfer(from, to)
        returns (bool)
    {
        return super.transferFrom(from, to, amount);
    }
}
