// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencyTransfer} from "../../src/libraries/CurrencyTransfer.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {MockERC20} from "../_mocks/MockERC20.sol";

/// @notice Branch coverage for `CurrencyTransfer` (native vs ERC-20 self vs pull paths).
contract CurrencyTransferTest is Test {
    using CurrencyLibrary for Currency;

    MockERC20 internal token;

    function setUp() public {
        token = new MockERC20("T", "T", 18);
    }

    function test_transferFrom_native_fromNonSelf_reverts() public {
        Currency c = Currency.wrap(address(0));
        assertTrue(c.isAddressZero());
        vm.expectRevert(abi.encodeWithSelector(Errors.NativeTransferFromUnsupported.selector, address(0xB0B)));
        this._external_transferFrom_native_nonSelf(c);
    }

    /// @dev External call so `vm.expectRevert` matches library revert depth.
    function _external_transferFrom_native_nonSelf(Currency c) external {
        CurrencyTransfer.transferFrom(c, address(0xB0B), address(0xCAFE), 1 ether);
    }

    function test_approve_native_isNoOp() public {
        Currency c = Currency.wrap(address(0));
        // Should not revert; branch `if (currency.isAddressZero()) return;`
        CurrencyTransfer.approve(c, address(0x111), 1 ether);
    }

    function test_transferFrom_erc20_fromSelf_usesTransferPath() public {
        Currency c = Currency.wrap(address(token));
        token.mint(address(this), 10 ether);
        token.approve(address(this), type(uint256).max);

        uint256 beforeTo = token.balanceOf(address(0xACE));
        CurrencyTransfer.transferFrom(c, address(this), address(0xACE), 3 ether);
        assertEq(token.balanceOf(address(0xACE)), beforeTo + 3 ether);
    }
}
