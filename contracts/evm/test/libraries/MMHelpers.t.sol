// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {MMHelpers} from "../../src/libraries/MMHelpers.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {Position} from "../../src/types/Position.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

contract MMHelpersHarness {
    mapping(uint256 tokenId => address owner) internal _ownerOf;
    mapping(uint256 tokenId => address approved) internal _approved;
    mapping(address owner => mapping(address operator => bool approved)) internal _approvedForAll;

    // --- minimal ERC721Permit_v4 surface used by MMHelpers (selectors must match) ---
    function ownerOf(uint256 tokenId) external view returns (address) {
        return _ownerOf[tokenId];
    }

    function getApproved(uint256 tokenId) external view returns (address) {
        return _approved[tokenId];
    }

    function isApprovedForAll(address owner, address operator) external view returns (bool) {
        return _approvedForAll[owner][operator];
    }

    // --- test helpers ---
    function setOwner(uint256 tokenId, address owner) external {
        _ownerOf[tokenId] = owner;
    }

    function setApproved(uint256 tokenId, address approved) external {
        _approved[tokenId] = approved;
    }

    function setApprovedForAll(address owner, address operator, bool approved) external {
        _approvedForAll[owner][operator] = approved;
    }

    // --- library wrappers ---
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

contract MMHelpersTest is Test {
    MMHelpersHarness internal h;

    function setUp() public {
        h = new MMHelpersHarness();
    }

    function test_isApprovedOrOwner_trueWhenCallerIsOwner() public {
        uint256 tokenId = 1;
        address owner = address(0xBEEF);
        h.setOwner(tokenId, owner);

        assertTrue(h.isApprovedOrOwner(owner, tokenId));
    }

    function test_isApprovedOrOwner_trueWhenCallerIsApproved() public {
        uint256 tokenId = 2;
        address owner = address(0xABCD);
        address approved = address(0xCAFE);
        h.setOwner(tokenId, owner);
        h.setApproved(tokenId, approved);

        assertTrue(h.isApprovedOrOwner(approved, tokenId));
    }

    function test_isApprovedOrOwner_trueWhenCallerIsApprovedForAll() public {
        uint256 tokenId = 3;
        address owner = address(0x1111);
        address operator = address(0x2222);
        h.setOwner(tokenId, owner);
        h.setApprovedForAll(owner, operator, true);

        assertTrue(h.isApprovedOrOwner(operator, tokenId));
    }

    function test_isApprovedOrOwner_falseWhenNoPermissions() public {
        uint256 tokenId = 4;
        address owner = address(0xAAAA);
        h.setOwner(tokenId, owner);

        assertFalse(h.isApprovedOrOwner(address(0xBBBB), tokenId));
    }

    function test_assertApprovedOrOwner_revertsWhenNotApproved() public {
        uint256 tokenId = 5;
        address owner = address(0xAAAA);
        address caller = address(0xBBBB);
        h.setOwner(tokenId, owner);

        vm.expectRevert(abi.encodeWithSelector(Errors.NotApproved.selector, caller));
        h.assertApprovedOrOwner(caller, tokenId);
    }

    function test_assertApprovedOrOwner_passesWhenApproved() public {
        uint256 tokenId = 6;
        address owner = address(0xAAAA);
        address caller = address(0xBBBB);
        h.setOwner(tokenId, owner);
        h.setApproved(tokenId, caller);

        h.assertApprovedOrOwner(caller, tokenId);
    }

    function test_assertPositionForPool_revertsOnMismatch() public {
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

    function test_assertPositionForPool_passesOnMatch() public view {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(1)),
            currency1: Currency.wrap(address(2)),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(0))
        });

        Position memory p;
        p.poolId = key.toId();

        h.assertPositionForPool(key, p);
    }
}

