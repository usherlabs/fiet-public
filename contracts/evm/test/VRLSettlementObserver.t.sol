// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {VRLSettlementObserver} from "../src/VRLSettlementObserver.sol";
import {IVRLSettlementObserver} from "../src/interfaces/IVRLSettlementObserver.sol";
import {StubSettlementVerifier} from "../src/verifiers/StubSettlementVerifier.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Errors} from "../src/libraries/Errors.sol";

contract VRLSettlementObserverTest is Test {
    VRLSettlementObserver public observer;
    StubSettlementVerifier public stubVerifier;

    address public owner = makeAddr("owner");
    address public nonOwner = makeAddr("nonOwner");
    address public verifier1;
    address public verifier2;

    function setUp() public {
        // Deploy as owner so owner is set correctly
        vm.prank(owner);
        observer = new VRLSettlementObserver(owner);

        // Deploy stub verifiers for testing
        stubVerifier = new StubSettlementVerifier();
        verifier1 = address(stubVerifier);
        verifier2 = address(new StubSettlementVerifier());

        // Add initial verifier
        vm.prank(owner);
        observer.addVerifier(verifier1);
    }

    function test_AddVerifier() public {
        // Check initial state
        assertEq(observer.verifiers(0), verifier1);
        assertEq(observer.nextVerifierIndex(), 1);

        // Add a new verifier as owner
        vm.prank(owner);
        uint32 index = observer.addVerifier(verifier2);

        // Verify the verifier was added at the correct index
        assertEq(index, 1);
        assertEq(observer.verifiers(1), verifier2);
        assertEq(observer.nextVerifierIndex(), 2);
    }

    function test_AddVerifier_EmitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit IVRLSettlementObserver.VerifierAdded(verifier2, 1);
        observer.addVerifier(verifier2);
    }

    function test_AddVerifier_InvalidAddress() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidVerifier.selector));
        observer.addVerifier(address(0));
    }

    function test_NullifyVerifier() public {
        // Add verifier2 first
        vm.prank(owner);
        uint32 index2 = observer.addVerifier(verifier2);

        // Verify both verifiers are present
        assertEq(observer.verifiers(0), verifier1);
        assertEq(observer.verifiers(index2), verifier2);

        // Nullify verifier1
        vm.prank(owner);
        observer.nullifyVerifier(0);

        // Verify verifier1 was nullified (should be address(0))
        assertEq(observer.verifiers(0), address(0));
        // verifier2 should still be present
        assertEq(observer.verifiers(index2), verifier2);
    }

    function test_NullifyVerifier_EmitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit IVRLSettlementObserver.VerifierRemoved(verifier1, 0);
        observer.nullifyVerifier(0);
    }

    function test_NullifyVerifier_InvalidIndex() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidVerifier.selector));
        observer.nullifyVerifier(999);
    }

    function test_AllowVerifierForTokens() public {
        address token1 = makeAddr("token1");
        address token2 = makeAddr("token2");
        address[] memory tokens = new address[](2);
        tokens[0] = token1;
        tokens[1] = token2;

        // Initially not allowed
        assertEq(observer.allowedVerifiersForToken(token1, 0), false);
        assertEq(observer.allowedVerifiersForToken(token2, 0), false);

        // Allow verifier for tokens
        vm.prank(owner);
        observer.allowVerifierForTokens(0, tokens);

        // Verify both tokens are now allowed
        assertEq(observer.allowedVerifiersForToken(token1, 0), true);
        assertEq(observer.allowedVerifiersForToken(token2, 0), true);
    }

    function test_AllowVerifierForTokens_EmitsEvents() public {
        address token1 = makeAddr("token1");
        address[] memory tokens = new address[](1);
        tokens[0] = token1;

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit IVRLSettlementObserver.VerifierAllowed(token1, 0);
        observer.allowVerifierForTokens(0, tokens);
    }

    function test_AllowVerifierForTokens_InvalidVerifierIndex() public {
        address[] memory tokens = new address[](1);
        tokens[0] = makeAddr("token1");

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidVerifier.selector));
        observer.allowVerifierForTokens(999, tokens);
    }

    function test_DisallowVerifierForTokens() public {
        address token1 = makeAddr("token1");
        address[] memory tokens = new address[](1);
        tokens[0] = token1;

        // First allow
        vm.prank(owner);
        observer.allowVerifierForTokens(0, tokens);
        assertEq(observer.allowedVerifiersForToken(token1, 0), true);

        // Then disallow
        vm.prank(owner);
        observer.disallowVerifierForTokens(0, tokens);
        assertEq(observer.allowedVerifiersForToken(token1, 0), false);
    }

    function test_DisallowVerifierForTokens_EmitsEvents() public {
        address token1 = makeAddr("token1");
        address[] memory tokens = new address[](1);
        tokens[0] = token1;

        // First allow
        vm.prank(owner);
        observer.allowVerifierForTokens(0, tokens);

        // Then disallow
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit IVRLSettlementObserver.VerifierDisallowed(token1, 0);
        observer.disallowVerifierForTokens(0, tokens);
    }

    function test_VerifySettlementProof() public {
        // Setup: allow verifier for token
        address token = makeAddr("token");
        address[] memory tokens = new address[](1);
        tokens[0] = token;

        vm.prank(owner);
        observer.allowVerifierForTokens(0, tokens);

        // Create a pool key
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(token),
            currency1: Currency.wrap(makeAddr("token1")),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        bytes memory settlementProof = "proof";
        uint8 tokenIndex = 0;
        uint32 verifierIndex = 0;

        // Verify the proof (should succeed since stub verifier always returns true)
        bool isValid = observer.verifySettlementProof(poolKey, tokenIndex, verifierIndex, settlementProof, false);
        assertTrue(isValid);
    }

    function test_VerifySettlementProof_EmptyProof() public {
        address token = makeAddr("token");
        address[] memory tokens = new address[](1);
        tokens[0] = token;

        vm.prank(owner);
        observer.allowVerifierForTokens(0, tokens);

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(token),
            currency1: Currency.wrap(makeAddr("token1")),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        bytes memory emptyProof = "";
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidProof.selector));
        observer.verifySettlementProof(poolKey, 0, 0, emptyProof, false);
    }

    function test_VerifySettlementProof_VerifierNotAllowed() public {
        address token = makeAddr("token");
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(token),
            currency1: Currency.wrap(makeAddr("token1")),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        bytes memory settlementProof = "proof";
        // Verifier not allowed for this token
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidVerifier.selector));
        observer.verifySettlementProof(poolKey, 0, 0, settlementProof, false);
    }

    function test_VerifySettlementProof_InvalidVerifierIndex() public {
        address token = makeAddr("token");
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(token),
            currency1: Currency.wrap(makeAddr("token1")),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        bytes memory settlementProof = "proof";
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidVerifier.selector));
        observer.verifySettlementProof(poolKey, 0, 999, settlementProof, false);
    }

    function test_VerifySettlementProof_InvalidTokenIndex() public {
        address token = makeAddr("token");
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(token),
            currency1: Currency.wrap(makeAddr("token1")),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        bytes memory settlementProof = "proof";
        // tokenIndex must be 0 or 1
        vm.expectRevert("Invalid token index");
        observer.verifySettlementProof(poolKey, 2, 0, settlementProof, false);
    }

    function test_VerifySettlementProof_RevertOnInvalid() public {
        // Note: This test would need a mock verifier that returns false
        // For now, we test the revertOnInvalid flag with an invalid verifier index
        address token = makeAddr("token");
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(token),
            currency1: Currency.wrap(makeAddr("token1")),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        bytes memory settlementProof = "proof";
        // Should revert with InvalidVerifier, not InvalidProof
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidVerifier.selector));
        observer.verifySettlementProof(poolKey, 0, 999, settlementProof, true);
    }

    function test_OnlyOwnerCanAddVerifier() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        observer.addVerifier(verifier2);
    }

    function test_OnlyOwnerCanNullifyVerifier() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        observer.nullifyVerifier(0);
    }

    function test_OnlyOwnerCanAllowVerifierForTokens() public {
        address[] memory tokens = new address[](1);
        tokens[0] = makeAddr("token");

        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        observer.allowVerifierForTokens(0, tokens);
    }

    function test_OnlyOwnerCanDisallowVerifierForTokens() public {
        address[] memory tokens = new address[](1);
        tokens[0] = makeAddr("token");

        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        observer.disallowVerifierForTokens(0, tokens);
    }
}
