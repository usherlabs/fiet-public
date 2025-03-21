// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @title LimitedERC20 - An ERC20 token with transfer restrictions
/// @notice This contract implements an ERC20 token where transfers are limited to whitelisted addresses only
contract LimitedERC20 is ERC20 {
    /// @notice Error thrown when attempting to transfer to a non-whitelisted address
    error CannotTransferVRL();

    /// @notice Mapping to track whitelisted addresses
    /// @dev Maps address to boolean indicating if it's whitelisted
    mapping(address => bool) public whitelist;

    /// @notice Restricts function execution to whitelisted addresses only
    /// @dev Reverts if the target address isn't the contract itself
    /// @param _address The address to check against the whitelist
    modifier onlyWhitelisted(address _address) {
        if (_address != address(this)) {
            revert CannotTransferVRL();
        }
        _;
    }

    /// @notice Constructor for creating a new LimitedERC20 token
    /// @param name The name of the token
    /// @param symbol The symbol/ticker of the token
    /// @param decimals The number of decimal places for token amounts
    constructor(
        string memory name,
        string memory symbol,
        uint8 decimals
    ) ERC20(name, symbol, decimals) {}

    /// @notice Transfers tokens to a specified address
    /// @dev Overrides ERC20.transfer with whitelist restriction
    /// @param to The recipient address (must be this contract)
    /// @param amount The amount of tokens to transfer
    /// @return bool indicating success of the transfer
    function transfer(
        address to,
        uint256 amount
    ) public virtual override onlyWhitelisted(to) returns (bool) {
        return super.transfer(to, amount);
    }

    /// @notice Transfers tokens from one address to another
    /// @dev Overrides ERC20.transferFrom with whitelist restriction
    /// @param from The sender's address
    /// @param to The recipient address (must be this contract)
    /// @param amount The amount of tokens to transfer
    /// @return bool indicating success of the transfer
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public virtual override onlyWhitelisted(to) returns (bool) {
        return super.transferFrom(from, to, amount);
    }

    /// @notice Mints new tokens to the contract itself
    /// @dev Internal function only callable within contract and inheriting contracts
    /// @param amount The amount of tokens to mint
    function mint(uint256 amount) internal {
        _mint(address(this), amount);
    }

    /// @notice Burns tokens owned by the contract
    /// @dev Internal function only callable within contract and inheriting contracts
    /// @param amount The amount of tokens to burn
    function burn(uint256 amount) internal {
        _burn(address(this), amount);
    }
}