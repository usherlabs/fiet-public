// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ILCC} from "../../src/interfaces/ILCC.sol";

/**
 * @title MockLCC
 * @notice Mock Liquidity Commitment Certificate for testing
 * @dev Implements ILCC interface with configurable underlying asset
 */
contract MockLCC is ERC20, ILCC {
    address private immutable _underlying;
    uint8 private immutable _decimals_;

    constructor(string memory name, string memory symbol, uint8 decimals_, address underlyingAsset)
        ERC20(name, symbol)
    {
        _decimals_ = decimals_;
        _underlying = underlyingAsset;
    }

    function decimals() public view virtual override returns (uint8) {
        return _decimals_;
    }

    /// @inheritdoc ILCC
    function underlying() external view override returns (address) {
        return _underlying;
    }

    /// @inheritdoc ILCC
    function balancesOf(address account) external view override returns (uint256 wrapped, uint256 marketDerived) {
        // For testing, just return total balance as wrapped
        return (balanceOf(account), 0);
    }

    /// @notice Mint tokens for testing
    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    /// @notice Burn tokens for testing
    function burn(address account, uint256 amount) external {
        _burn(account, amount);
    }
}

