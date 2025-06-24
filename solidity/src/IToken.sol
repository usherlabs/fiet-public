// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
//import {IRFS} from "./interfaces/IRFS.sol";

struct Custodian {
    address custodianAddress;
    uint256 totalSupply;
    bool whitelisted;
}

contract IToken is ERC20, Ownable {
    uint256 baseVtsBPS;
    address rfsContract;
    address public underlyingAsset;

    mapping(address => bool) public liquidityProviders;
    mapping(address => Custodian) public custodians;

    modifier validCustodian(address custodian) {
        require(custodians[custodian].whitelisted, "CUSTODIAN NOT WHITELISTED");
        _;
    }

    modifier onlyLP(address custodian) {
        require(liquidityProviders[custodian], "LP NOT WHITELISTED");
        _;
    }

    constructor(
        string memory _name,
        string memory _symbol,
        address _underlying_asset,
        //address _rfs_contract,
        // This needs to setup dynamically
        uint256 _base_vts_bps
    ) ERC20(_name, _symbol) Ownable(msg.sender) {
        require(_underlying_asset != address(0), "INVALID UNDERLYING ASSET");
        underlyingAsset = _underlying_asset;
        baseVtsBPS = _base_vts_bps;
        //rfsContract = _rfs_contract;
    }

    // checks if there is sufficient liquidity to unwrap a token
    // compares current vts with base vts and returns
    function isSufficientLiquidity() internal pure returns (bool) {
        return true;
    }

    // get the current vts of the pool
    function vts(
        address custodian
    ) public view validCustodian(custodian) returns (uint256) {
        uint256 custodianTotalSupply = custodians[custodian].totalSupply;
        return
            IERC20(custodian).balanceOf(address(this)) / custodianTotalSupply;
    }

    function checkForRFS() public validCustodian(msg.sender) {
        // check the base and treshold vts to see if the conditionns for rfs are met
        bool shouldRFS = false;
        //uint256 rfsAmount = 0;
        // dead code
        if (shouldRFS) {
            // IRFS(rfsContract).triggerRfS(
            //     address(underlyingAsset),
            //     msg.sender,
            //     address(this),
            //     rfsAmount
            // );
        }
    }

    function whitelistCustodian(
        address custodian,
        bool whitelist
    ) public onlyOwner {
        custodians[custodian].whitelisted = whitelist;
    }

    function whitelistLP(address lp, bool whitelist) public onlyOwner {
        liquidityProviders[lp] = whitelist;
    }

    // some trusted markets can be allowed to mint tokens and hold the liquidity
    // this minting provides tokens at a 1:1 ratio and intended for onchain preswap wrapping
    function custodianMint(uint256 amount) public validCustodian(msg.sender) {
        address custodian = msg.sender;
        // mint some to them and increase their debt
        _mint(custodian, amount);
        // increase their balance total supply
        custodians[custodian].totalSupply += amount;
    }

    // LP's are allowed to mint tokens for themselves using the base vts
    // while specifying a custodian which would be responsible for the liquidity
    function wrap(
        address custodian,
        uint256 amount
    ) public validCustodian(custodian) onlyLP(msg.sender) {
        uint256 fees = 0;
        address owner = msg.sender;
        uint256 custodyAmount = _getReserveAmount(amount);

        // mint some tokens
        _mint(owner, amount);
        // transfer the equivalent of the underlying asset from the recipient
        IERC20(underlyingAsset).transferFrom(
            owner,
            custodian,
            custodyAmount - fees
        );
        // update the custodians total supply
        custodians[custodian].totalSupply += amount;
    }

    // unwrap some tokens
    function unwrap(
        address to,
        uint256 amount
    ) public validCustodian(msg.sender) {
        address custodian = msg.sender;
        IERC20 underlying_asset_token = IERC20(underlyingAsset);

        require(
            amount > 0 && amount <= custodians[custodian].totalSupply,
            "INVALID AMOUNT"
        );

        if (isSufficientLiquidity()) {
            // and burn their tokens
            _burn(custodian, amount);
            // since the hook has paid back some of its debt, reduce by the promised amount
            custodians[custodian].totalSupply -= amount;

            // transfer some underlying tokens to the user
            underlying_asset_token.transferFrom(custodian, to, amount);
        } else {
            // dead code: isSufficientLiquidity() hard coded to true
            // IRFS(rfsContract).queueWithdrawal(
            //     to,
            //     msg.sender,
            //     address(this),
            //     amount
            // );
        }
    }

    function _getReserveAmount(
        uint256 amount
    ) internal view returns (uint256 reserveAmount) {
        reserveAmount = (amount * baseVtsBPS) / 10_000;
    }

    function _isRecipientWhitelisted(
        address whitelisted
    ) internal view returns (bool) {
        return
            custodians[whitelisted].whitelisted == true ||
            liquidityProviders[whitelisted] == true;
    }

    function _update(
        address from,
        address to,
        uint256 value
    ) internal virtual override {
        // Allow minting and transferring only to whitelisted addresses
        if (to != address(0)) {
            require(_isRecipientWhitelisted(to), "Recipient not whitelisted");
        }

        // Optional: restrict burns to whitelisted senders too
        if (from != address(0)) {
            require(_isRecipientWhitelisted(from), "Sender not whitelisted");
        }

        super._update(from, to, value);
    }
}
