// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {MockERC20} from "@uniswap/v4-core/lib/solmate/src/test/utils/mocks/MockERC20.sol";

import {IToken} from "../src/IToken.sol";

contract ITokenTest is Test {
    IToken lccToken;
    MockERC20 token;
    address custodian = makeAddr("custodian");
    address userOne = makeAddr("userOne");
    address userTwo = makeAddr("userTwo");
    uint8 decimals = 6;
    uint256 amountToMint = 100 * 10 ** decimals;

    function deployAndApproveITokens(
        string memory name,
        string memory symbol,
        address underlyingAsset,
        uint256 base_vts
    ) internal returns (IToken iToken) {
        iToken = new IToken(name, symbol, underlyingAsset, base_vts);

        // Make sure to approve the ITokens to take out 'underlyingAsset'
        IERC20Minimal(underlyingAsset).approve(
            address(iToken),
            Constants.MAX_UINT256
        );
        return iToken;
    }

    function deployAndMintUnderlyingAsset(
        string memory name,
        string memory symbol,
        uint8 _decimals
    ) internal returns (MockERC20) {
        token = new MockERC20(name, symbol, _decimals);

        // send `amountToMint` mock usdc to user one and two
        token.mint(userOne, amountToMint);
        token.mint(userTwo, amountToMint);
        return token;
    }

    function iTokenWhitelist() internal {
        // Required to set to true
        lccToken.whitelistCustodian(custodian, true);
        // Required to set to true
        lccToken.whitelistLP(userOne, true);
    }

    function setUp() public {
        token = deployAndMintUnderlyingAsset("mock USDC", "mUSDC", decimals);
        lccToken = deployAndApproveITokens(
            "LCC USDC",
            "LCCUSDC",
            address(token),
            10_000
        );
        iTokenWhitelist();
    }

    function test_correctWhitelistAddresses() public view {
        // Check custodian privilage
        (, , bool isAllowed) = lccToken.custodians(custodian);
        assertEq(isAllowed, true);
        // Check LP privilage - userOne
        bool isLpAllowed = lccToken.liquidityProviders(userOne);
        assertEq(isLpAllowed, true);
        // Check LP privilage - userTwo
        bool isLpAllowedUserTwo = lccToken.liquidityProviders(userTwo);
        assertEq(isLpAllowedUserTwo, false);
        // Check undelying asset decimals
        uint8 tokenDecimals = token.decimals();
        assertEq(tokenDecimals, decimals);
        // Check lcc asset decimals
        uint8 lccTokenDecimals = lccToken.decimals();
        assertEq(lccTokenDecimals, decimals);
        // Check balance - userOne
        uint256 userOneBalance = token.balanceOf(userOne);
        assertEq(userOneBalance, amountToMint);
        // Check balance - userTwo
        uint256 userTwoBalance = token.balanceOf(userTwo);
        assertEq(userTwoBalance, amountToMint);
    }

    function test_wrapUnderlyingAssetToLccToken() public {
        vm.prank(userOne);
        uint256 amountToWrap = 1000000;
        // Test wrap token - wrap
        lccToken.wrap(custodian, amountToWrap);
    }
}
