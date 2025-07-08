// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "forge-std/console.sol";
//import {IRFS} from "./interfaces/IRFS.sol";

struct Custodian {
    address custodianAddress;
    uint256 totalSupply;
    bool whitelisted;
}

contract IToken is ERC20, Ownable {
    uint256 baseVtsBPS;
    address rfsContract;
    address public immutable underlyingAsset;
    uint8 public lccDecimals;

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
        lccDecimals = IERC20Metadata(underlyingAsset).decimals();
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
        if (custodianTotalSupply == 0) return 0;
        return
            IERC20(custodian).balanceOf(address(this)) / custodianTotalSupply;
    }

    function checkForRFS() public view validCustodian(msg.sender) {
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
        require(custodian != address(0), "Invalid address");
        custodians[custodian].whitelisted = whitelist;
    }

    function whitelistLP(address lp, bool whitelist) public onlyOwner {
        require(lp != address(0), "Invalid address");
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

        // transfer the equivalent of the underlying asset from the recipient
        IERC20(underlyingAsset).transferFrom(
            owner,
            custodian,
            custodyAmount - fees
        );
        // mint some tokens
        _mint(owner, amount);
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

            // transfer underlying tokens to the user

            bool success = underlying_asset_token.transferFrom(
                custodian,
                to,
                amount
            );
            require(success, "Unwrap failed");
            console.log("Itoken: transferfrom done");
        } else {
            // TODO: We have a problem...
            // // I just realised that the Proxy Hook needs to have liquidity on hand for the maths/accounting to work with Uniswap.
            // If this occurs, the Uniswap Pool Manager will not consider LCCs sent to the user, as native token required to fulfil the delta = 0 neutrality.
            // * The fix to this is adjusting the delta of the Outflow Token, reducing it to account only for liquidity on hand, and making up for the rest in LCC.
            // However, the LCCs pending inside of the Proxy Hook still need a destination recipient.
            // An off-chain resolver could map swaps with pending LCCs to pending LCCs
            // 1. Proxy Hook must maintain a balance of pending outflow LCCs.
            // 2. Resolver will produce a proof that swap event with recipient resulted in a balance of pending LCCs.
            //....
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

    function decimals() public view virtual override returns (uint8) {
        return lccDecimals;
    }
}
