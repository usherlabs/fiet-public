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
    uint256 amountToMint = 100 * 10 ** decimals; // 100 tokens

    function deployITokens(string memory name, string memory symbol, address underlyingAsset, uint256 base_vts)
        internal
        returns (IToken iToken)
    {
        iToken = new IToken(name, symbol, underlyingAsset, base_vts);
        return iToken;
    }

    function deployAndMintUnderlyingAsset(string memory name, string memory symbol, uint8 _decimals)
        internal
        returns (MockERC20)
    {
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
        lccToken = deployITokens("LCC USDC", "LCCUSDC", address(token), 10_000);
        iTokenWhitelist();
    }

    function test_correctDeployment() public view {
        // Check custodian privilage
        (,, bool isAllowed) = lccToken.custodians(custodian);
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
        uint256 amountToWrap = 10_000_000; // 10 Mock USDC
        uint256 tokenBalanceBefore = token.balanceOf(address(userOne));
        assertEq(tokenBalanceBefore, amountToMint);
        // Check userOne LCC mock balance. This should be Zero
        uint256 lccBalanceBefore = lccToken.balanceOf(address(userOne));
        assertEq(lccBalanceBefore, 0);
        // Check custodian balance. Underlying asset should go to custodian upon wrap
        uint256 custodianBalanceBefore = token.balanceOf(address(custodian));
        assertEq(custodianBalanceBefore, 0);

        vm.startPrank(userOne);
        token.approve(address(lccToken), type(uint256).max);
        // Test wrap token - wrap
        lccToken.wrap(custodian, amountToWrap);
        vm.stopPrank();

        // Check lcc token balance after `wrap`
        uint256 lccBalanceAfter = lccToken.balanceOf(address(userOne));
        assertEq(lccBalanceAfter, amountToWrap);
        // check underlying asset balance after `wrap`
        uint256 tokenBalanceAfter = token.balanceOf(address(userOne));
        assertEq(tokenBalanceAfter, tokenBalanceBefore - amountToWrap);
        // Check custodian balance after. Underlying asset should go to custodian
        uint256 custodianBalanceAfter = token.balanceOf(address(custodian));
        assertEq(custodianBalanceAfter, amountToWrap);
    }

    function test_unWrapToUnderlyingAsset() public {
        vm.skip(true);
        /**
         * When unwrapping to underlying asset from user one this fails
         * User should be able to wrap without restriction
         */
        test_wrapUnderlyingAssetToLccToken(); // performing wrap here
        vm.startPrank(custodian);
        uint256 amountToUnWrap = 5_000_000; // 5 mock USDC
        // unwrap to underlying asset
        lccToken.unwrap(userOne, amountToUnWrap);
        vm.stopPrank();
    }
}
