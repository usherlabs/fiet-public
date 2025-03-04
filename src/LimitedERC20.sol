// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

contract LimitedERC20 is ERC20 {
    mapping(address => bool) public whitelist;

    /// @notice Restricts function to whitelisted addresses only
    modifier onlyWhitelisted(address _address) {
        require(whitelist[_address], "To address not whitelisted");
        _;
    }

    constructor(
        string memory name,
        string memory symbol,
        uint8 decimals,
        address[] memory whitelistedAddresses
    ) ERC20(name, symbol, decimals) {
        // Populate the whitelist mapping
        for (uint256 i = 0; i < whitelistedAddresses.length; i++) {
            whitelist[whitelistedAddresses[i]] = true;
        }
    }

    function transfer(
        address to,
        uint256 amount
    ) public override onlyWhitelisted(to) returns (bool) {
        balanceOf[msg.sender] -= amount;

        // Cannot overflow because the sum of all user
        // balances can't exceed the max uint256 value.
        unchecked {
            balanceOf[to] += amount;
        }

        emit Transfer(msg.sender, to, amount);

        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public override onlyWhitelisted(to) returns (bool) {
        uint256 allowed = allowance[from][msg.sender]; // Saves gas for limited approvals.

        if (allowed != type(uint256).max)
            allowance[from][msg.sender] = allowed - amount;

        balanceOf[from] -= amount;

        // Cannot overflow because the sum of all user
        // balances can't exceed the max uint256 value.
        unchecked {
            balanceOf[to] += amount;
        }

        emit Transfer(from, to, amount);

        return true;
    }

    function mint(uint256 amount) private {
        _mint(address(this), amount);
    }

    function burn(uint256 amount) private {
        _burn(address(this), amount);
    }
}
