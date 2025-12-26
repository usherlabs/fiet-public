// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {OlympixUnitTest} from "../tools/OlympixUnitTest.sol";
import {MMHelpers} from "../../../src/libraries/MMHelpers.sol";
import {Errors} from "../../../src/libraries/Errors.sol";
import {Position} from "../../../src/types/Position.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

contract MMHelpersHarness {
    function isApprovedOrOwner(address caller, uint256 tokenId) external view returns (bool) {
        return MMHelpers.isApprovedOrOwner(caller, tokenId);
    }

    function assertApprovedOrOwner(address caller, uint256 tokenId) external view {
        MMHelpers.assertApprovedOrOwner(caller, tokenId);
    }

    function assertPositionForPool(PoolKey calldata poolKey, Position memory position) external pure {
        MMHelpers.assertPositionForPool(poolKey, position);
    }
}

contract MMHelpersTest_Autocover is Test, OlympixUnitTest("MMHelpersHarness") {
    MMHelpersHarness internal h;

    function setUp() public {}

    function test_assertPositionForPool_revertsOnMismatch() public {
        h = new MMHelpersHarness();
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(1)),
            currency1: Currency.wrap(address(2)),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(0))
        });

        Position memory p;
        p.poolId = PoolId.wrap(bytes32(uint256(123)));

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidMarket.selector, key));
        h.assertPositionForPool(key, p);
    }
}

