// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {NativeWrapper} from "../src/modules/NativeWrapper.sol";
import {NativeWrapper as ForksNativeWrapper} from "../src/forks/NativeWrapper.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";
import {WETH} from "@uniswap/v4-core/lib/solmate/src/tokens/WETH.sol";
import {Errors} from "../src/libraries/Errors.sol";

// ============ MOCK CONTRACTS ============

/// @notice Mock LCC contract that returns a configurable underlying address
contract MockLCCForNativeWrapper {
    address public underlying;

    constructor(address _underlying) {
        underlying = _underlying;
    }
}

/// @notice Mock MarketVault that can be configured to return different LCC addresses
/// and optionally revert on lccs() call
contract MockMarketVaultForNativeWrapper {
    address public lcc0;
    address public lcc1;
    bool public shouldRevertLccs;

    function setLccs(address _lcc0, address _lcc1) external {
        lcc0 = _lcc0;
        lcc1 = _lcc1;
    }

    function setShouldRevertLccs(bool _shouldRevert) external {
        shouldRevertLccs = _shouldRevert;
    }

    function lccs() external view returns (address, address) {
        require(!shouldRevertLccs, "lccs reverted");
        return (lcc0, lcc1);
    }

    /// @notice Helper to send ETH to a target address (simulating MarketVault sending ETH)
    /// @dev Bubbles up any revert reason from the target
    function sendEth(address payable target) external payable {
        (bool success, bytes memory returnData) = target.call{value: msg.value}("");
        if (!success) {
            // Bubble up the revert reason
            assembly {
                revert(add(returnData, 32), mload(returnData))
            }
        }
    }
}

/// @notice Contract that doesn't implement lccs() - for testing failed staticcall
contract ContractWithoutLccs {
    /// @notice Helper to send ETH to a target address
    /// @dev Bubbles up any revert reason from the target
    function sendEth(address payable target) external payable {
        (bool success, bytes memory returnData) = target.call{value: msg.value}("");
        if (!success) {
            // Bubble up the revert reason
            assembly {
                revert(add(returnData, 32), mload(returnData))
            }
        }
    }
}

// ============ TEST HARNESS FOR FORKS/NATIVEWRAPPER ============

/// @notice Test harness to expose internal functions from forks/NativeWrapper.sol
/// @dev This harness tests the BASE NativeWrapper from forks/ directory
contract ForksNativeWrapperHarness is ForksNativeWrapper {
    constructor(IWETH9 _weth9, IPoolManager _poolManager) ForksNativeWrapper(_weth9) ImmutableState(_poolManager) {}

    /// @notice Expose internal _wrap function for testing
    function wrap(uint256 amount) external {
        _wrap(amount);
    }

    /// @notice Expose internal _unwrap function for testing
    function unwrap(uint256 amount) external {
        _unwrap(amount);
    }

    /// @notice Allow receiving ETH for test setup
    receive() external payable override {
        // For forks version: only WETH9 or poolManager can send ETH
        if (msg.sender != address(WETH9) && msg.sender != address(poolManager)) {
            revert InvalidEthSender();
        }
    }
}

// ============ TEST HARNESS FOR MODULES/NATIVEWRAPPER ============

/// @notice Test harness to expose internal functions from modules/NativeWrapper.sol
/// @dev This harness tests the EXTENDED NativeWrapper from modules/ directory
contract ModulesNativeWrapperHarness is NativeWrapper {
    constructor(IWETH9 _weth9, IPoolManager _poolManager) NativeWrapper(_weth9) ImmutableState(_poolManager) {}

    /// @notice Expose internal _wrap function for testing
    function wrap(uint256 amount) external {
        _wrap(amount);
    }

    /// @notice Expose internal _unwrap function for testing
    function unwrap(uint256 amount) external {
        _unwrap(amount);
    }

    /// @notice Expose internal _assertValidEthSender for testing
    function assertValidEthSender() external view {
        _assertValidEthSender();
    }
}

// ============ TEST CONTRACT ============

contract NativeWrapperTest is Test {
    // Harnesses
    ForksNativeWrapperHarness public forksHarness;
    ModulesNativeWrapperHarness public modulesHarness;

    // Dependencies
    IWETH9 public weth9;
    IPoolManager public poolManager;

    // Mock contracts
    MockMarketVaultForNativeWrapper public mockMarketVault;
    ContractWithoutLccs public contractWithoutLccs;
    MockLCCForNativeWrapper public mockLccNativeEth;
    MockLCCForNativeWrapper public mockLccErc20;

    // Test addresses
    address public unauthorisedSender;

    function setUp() public {
        // Deploy WETH9
        weth9 = IWETH9(address(new WETH()));

        // Create mock pool manager
        poolManager = IPoolManager(makeAddr("poolManager"));

        // Deploy harnesses
        forksHarness = new ForksNativeWrapperHarness(weth9, poolManager);
        modulesHarness = new ModulesNativeWrapperHarness(weth9, poolManager);

        // Deploy mock contracts
        mockMarketVault = new MockMarketVaultForNativeWrapper();
        contractWithoutLccs = new ContractWithoutLccs();

        // Deploy mock LCCs with different underlying assets
        mockLccNativeEth = new MockLCCForNativeWrapper(address(0)); // Native ETH underlying
        mockLccErc20 = new MockLCCForNativeWrapper(makeAddr("erc20Token")); // ERC20 underlying

        // Setup test addresses
        unauthorisedSender = makeAddr("unauthorisedSender");

        // Fund harnesses with ETH for testing
        vm.deal(address(forksHarness), 100 ether);
        vm.deal(address(modulesHarness), 100 ether);

        // Fund mock contracts for sending ETH
        vm.deal(address(mockMarketVault), 10 ether);
        vm.deal(address(contractWithoutLccs), 10 ether);
        vm.deal(address(weth9), 10 ether);
        vm.deal(address(poolManager), 10 ether);
        vm.deal(unauthorisedSender, 10 ether);
    }

    // ============================================================
    // ============ FORKS/NATIVEWRAPPER.SOL TESTS ==================
    // ============================================================

    // ------------ Constructor Tests ------------

    function test_forks_constructor_setsWETH9Address() public view {
        assertEq(address(forksHarness.WETH9()), address(weth9), "WETH9 address should be set correctly");
    }

    // ------------ _wrap() Tests ------------

    function test_forks_wrap_depositsEthToWeth_whenAmountGreaterThanZero() public {
        uint256 wrapAmount = 1 ether;

        // Get balances before
        uint256 harnessEthBefore = address(forksHarness).balance;
        uint256 harnessWethBefore = weth9.balanceOf(address(forksHarness));

        // Wrap ETH
        forksHarness.wrap(wrapAmount);

        // Verify balances after
        uint256 harnessEthAfter = address(forksHarness).balance;
        uint256 harnessWethAfter = weth9.balanceOf(address(forksHarness));

        assertEq(harnessEthBefore - harnessEthAfter, wrapAmount, "ETH should decrease by wrap amount");
        assertEq(harnessWethAfter - harnessWethBefore, wrapAmount, "WETH should increase by wrap amount");
    }

    function test_forks_wrap_noOp_whenAmountIsZero() public {
        // Get balances before
        uint256 harnessEthBefore = address(forksHarness).balance;
        uint256 harnessWethBefore = weth9.balanceOf(address(forksHarness));

        // Wrap zero amount
        forksHarness.wrap(0);

        // Verify balances unchanged
        uint256 harnessEthAfter = address(forksHarness).balance;
        uint256 harnessWethAfter = weth9.balanceOf(address(forksHarness));

        assertEq(harnessEthAfter, harnessEthBefore, "ETH balance should remain unchanged");
        assertEq(harnessWethAfter, harnessWethBefore, "WETH balance should remain unchanged");
    }

    // ------------ _unwrap() Tests ------------

    function test_forks_unwrap_withdrawsWethToEth_whenAmountGreaterThanZero() public {
        uint256 wrapAmount = 1 ether;

        // First wrap some ETH to get WETH
        forksHarness.wrap(wrapAmount);

        // Get balances before unwrap
        uint256 harnessEthBefore = address(forksHarness).balance;
        uint256 harnessWethBefore = weth9.balanceOf(address(forksHarness));

        // Unwrap WETH
        forksHarness.unwrap(wrapAmount);

        // Verify balances after
        uint256 harnessEthAfter = address(forksHarness).balance;
        uint256 harnessWethAfter = weth9.balanceOf(address(forksHarness));

        assertEq(harnessEthAfter - harnessEthBefore, wrapAmount, "ETH should increase by unwrap amount");
        assertEq(harnessWethBefore - harnessWethAfter, wrapAmount, "WETH should decrease by unwrap amount");
    }

    function test_forks_unwrap_noOp_whenAmountIsZero() public {
        uint256 wrapAmount = 1 ether;

        // First wrap some ETH to get WETH
        forksHarness.wrap(wrapAmount);

        // Get balances before
        uint256 harnessEthBefore = address(forksHarness).balance;
        uint256 harnessWethBefore = weth9.balanceOf(address(forksHarness));

        // Unwrap zero amount
        forksHarness.unwrap(0);

        // Verify balances unchanged
        uint256 harnessEthAfter = address(forksHarness).balance;
        uint256 harnessWethAfter = weth9.balanceOf(address(forksHarness));

        assertEq(harnessEthAfter, harnessEthBefore, "ETH balance should remain unchanged");
        assertEq(harnessWethAfter, harnessWethBefore, "WETH balance should remain unchanged");
    }

    // ------------ receive() Tests (Forks version) ------------

    function test_forks_receive_acceptsEth_fromWETH9() public {
        uint256 sendAmount = 1 ether;
        uint256 harnessBalanceBefore = address(forksHarness).balance;

        // WETH9 sends ETH to harness (simulates withdraw callback)
        vm.prank(address(weth9));
        (bool success,) = address(forksHarness).call{value: sendAmount}("");

        assertTrue(success, "ETH transfer from WETH9 should succeed");
        assertEq(
            address(forksHarness).balance, harnessBalanceBefore + sendAmount, "Harness should receive ETH from WETH9"
        );
    }

    function test_forks_receive_acceptsEth_fromPoolManager() public {
        uint256 sendAmount = 1 ether;
        uint256 harnessBalanceBefore = address(forksHarness).balance;

        // PoolManager sends ETH to harness
        vm.prank(address(poolManager));
        (bool success,) = address(forksHarness).call{value: sendAmount}("");

        assertTrue(success, "ETH transfer from PoolManager should succeed");
        assertEq(
            address(forksHarness).balance,
            harnessBalanceBefore + sendAmount,
            "Harness should receive ETH from PoolManager"
        );
    }

    function test_forks_receive_reverts_fromUnauthorisedSender() public {
        uint256 sendAmount = 1 ether;

        // Unauthorised sender tries to send ETH
        vm.prank(unauthorisedSender);
        vm.expectRevert(ForksNativeWrapper.InvalidEthSender.selector);
        (bool success,) = address(forksHarness).call{value: sendAmount}("");

        // Note: expectRevert catches the revert, so success will be true here
        // but the revert was properly caught
        success; // silence unused variable warning
    }

    // ============================================================
    // ============ MODULES/NATIVEWRAPPER.SOL TESTS ================
    // ============================================================

    // ------------ Constructor Tests ------------

    function test_modules_constructor_setsWETH9Address() public view {
        assertEq(address(modulesHarness.WETH9()), address(weth9), "WETH9 address should be set correctly");
    }

    // ------------ _wrap() Tests (inherited) ------------

    function test_modules_wrap_depositsEthToWeth_whenAmountGreaterThanZero() public {
        uint256 wrapAmount = 1 ether;

        uint256 harnessEthBefore = address(modulesHarness).balance;
        uint256 harnessWethBefore = weth9.balanceOf(address(modulesHarness));

        modulesHarness.wrap(wrapAmount);

        uint256 harnessEthAfter = address(modulesHarness).balance;
        uint256 harnessWethAfter = weth9.balanceOf(address(modulesHarness));

        assertEq(harnessEthBefore - harnessEthAfter, wrapAmount, "ETH should decrease by wrap amount");
        assertEq(harnessWethAfter - harnessWethBefore, wrapAmount, "WETH should increase by wrap amount");
    }

    function test_modules_wrap_noOp_whenAmountIsZero() public {
        uint256 harnessEthBefore = address(modulesHarness).balance;
        uint256 harnessWethBefore = weth9.balanceOf(address(modulesHarness));

        modulesHarness.wrap(0);

        uint256 harnessEthAfter = address(modulesHarness).balance;
        uint256 harnessWethAfter = weth9.balanceOf(address(modulesHarness));

        assertEq(harnessEthAfter, harnessEthBefore, "ETH balance should remain unchanged");
        assertEq(harnessWethAfter, harnessWethBefore, "WETH balance should remain unchanged");
    }

    // ------------ _unwrap() Tests (inherited) ------------

    function test_modules_unwrap_withdrawsWethToEth_whenAmountGreaterThanZero() public {
        uint256 wrapAmount = 1 ether;

        modulesHarness.wrap(wrapAmount);

        uint256 harnessEthBefore = address(modulesHarness).balance;
        uint256 harnessWethBefore = weth9.balanceOf(address(modulesHarness));

        modulesHarness.unwrap(wrapAmount);

        uint256 harnessEthAfter = address(modulesHarness).balance;
        uint256 harnessWethAfter = weth9.balanceOf(address(modulesHarness));

        assertEq(harnessEthAfter - harnessEthBefore, wrapAmount, "ETH should increase by unwrap amount");
        assertEq(harnessWethBefore - harnessWethAfter, wrapAmount, "WETH should decrease by unwrap amount");
    }

    function test_modules_unwrap_noOp_whenAmountIsZero() public {
        uint256 wrapAmount = 1 ether;

        modulesHarness.wrap(wrapAmount);

        uint256 harnessEthBefore = address(modulesHarness).balance;
        uint256 harnessWethBefore = weth9.balanceOf(address(modulesHarness));

        modulesHarness.unwrap(0);

        uint256 harnessEthAfter = address(modulesHarness).balance;
        uint256 harnessWethAfter = weth9.balanceOf(address(modulesHarness));

        assertEq(harnessEthAfter, harnessEthBefore, "ETH balance should remain unchanged");
        assertEq(harnessWethAfter, harnessWethBefore, "WETH balance should remain unchanged");
    }

    // ------------ _assertValidEthSender() Tests ------------

    function test_modules_assertValidEthSender_returns_whenSenderIsWETH9() public {
        // Call assertValidEthSender as WETH9 - should not revert
        vm.prank(address(weth9));
        modulesHarness.assertValidEthSender();
        // If we reach here, the function returned successfully
    }

    function test_modules_assertValidEthSender_returns_whenSenderIsPoolManager() public {
        // Call assertValidEthSender as PoolManager - should not revert
        vm.prank(address(poolManager));
        modulesHarness.assertValidEthSender();
        // If we reach here, the function returned successfully
    }

    function test_modules_assertValidEthSender_reverts_whenLccsCallFails() public {
        // Use a contract that doesn't implement lccs()
        vm.prank(address(contractWithoutLccs));
        vm.expectRevert(Errors.InvalidEthSender.selector);
        modulesHarness.assertValidEthSender();
    }

    function test_modules_assertValidEthSender_reverts_whenNeitherUnderlyingIsNativeEth() public {
        // Setup mock vault with both LCCs having ERC20 underlyings (not native ETH)
        MockLCCForNativeWrapper lcc0Erc20 = new MockLCCForNativeWrapper(makeAddr("token0"));
        MockLCCForNativeWrapper lcc1Erc20 = new MockLCCForNativeWrapper(makeAddr("token1"));

        mockMarketVault.setLccs(address(lcc0Erc20), address(lcc1Erc20));

        vm.prank(address(mockMarketVault));
        vm.expectRevert(Errors.InvalidEthSender.selector);
        modulesHarness.assertValidEthSender();
    }

    function test_modules_assertValidEthSender_succeeds_whenUnderlying0IsNativeEth() public {
        // Setup mock vault with LCC0 having native ETH underlying
        mockMarketVault.setLccs(address(mockLccNativeEth), address(mockLccErc20));

        vm.prank(address(mockMarketVault));
        modulesHarness.assertValidEthSender();
        // If we reach here, the function returned successfully
    }

    function test_modules_assertValidEthSender_succeeds_whenUnderlying1IsNativeEth() public {
        // Setup mock vault with LCC1 having native ETH underlying
        mockMarketVault.setLccs(address(mockLccErc20), address(mockLccNativeEth));

        vm.prank(address(mockMarketVault));
        modulesHarness.assertValidEthSender();
        // If we reach here, the function returned successfully
    }

    function test_modules_assertValidEthSender_succeeds_whenBothUnderlyingsAreNativeEth() public {
        // Setup mock vault with both LCCs having native ETH underlying
        MockLCCForNativeWrapper anotherNativeEthLcc = new MockLCCForNativeWrapper(address(0));
        mockMarketVault.setLccs(address(mockLccNativeEth), address(anotherNativeEthLcc));

        vm.prank(address(mockMarketVault));
        modulesHarness.assertValidEthSender();
        // If we reach here, the function returned successfully
    }

    // ------------ receive() Override Tests (Modules version) ------------

    function test_modules_receive_acceptsEth_fromWETH9() public {
        uint256 sendAmount = 1 ether;
        uint256 harnessBalanceBefore = address(modulesHarness).balance;

        vm.prank(address(weth9));
        (bool success,) = address(modulesHarness).call{value: sendAmount}("");

        assertTrue(success, "ETH transfer from WETH9 should succeed");
        assertEq(
            address(modulesHarness).balance, harnessBalanceBefore + sendAmount, "Harness should receive ETH from WETH9"
        );
    }

    function test_modules_receive_acceptsEth_fromPoolManager() public {
        uint256 sendAmount = 1 ether;
        uint256 harnessBalanceBefore = address(modulesHarness).balance;

        vm.prank(address(poolManager));
        (bool success,) = address(modulesHarness).call{value: sendAmount}("");

        assertTrue(success, "ETH transfer from PoolManager should succeed");
        assertEq(
            address(modulesHarness).balance,
            harnessBalanceBefore + sendAmount,
            "Harness should receive ETH from PoolManager"
        );
    }

    function test_modules_receive_acceptsEth_fromValidMarketVault() public {
        // Setup mock vault with valid native ETH LCC
        mockMarketVault.setLccs(address(mockLccNativeEth), address(mockLccErc20));

        uint256 sendAmount = 1 ether;
        uint256 harnessBalanceBefore = address(modulesHarness).balance;

        // MarketVault sends ETH to harness
        mockMarketVault.sendEth{value: sendAmount}(payable(address(modulesHarness)));

        assertEq(
            address(modulesHarness).balance,
            harnessBalanceBefore + sendAmount,
            "Harness should receive ETH from valid MarketVault"
        );
    }

    function test_modules_receive_reverts_fromInvalidMarketVault() public {
        // Setup mock vault with NO native ETH LCCs (both ERC20)
        MockLCCForNativeWrapper lcc0Erc20 = new MockLCCForNativeWrapper(makeAddr("token0"));
        MockLCCForNativeWrapper lcc1Erc20 = new MockLCCForNativeWrapper(makeAddr("token1"));
        mockMarketVault.setLccs(address(lcc0Erc20), address(lcc1Erc20));

        uint256 sendAmount = 1 ether;

        // MarketVault without native ETH underlying tries to send ETH
        vm.expectRevert(Errors.InvalidEthSender.selector);
        mockMarketVault.sendEth{value: sendAmount}(payable(address(modulesHarness)));
    }

    function test_modules_receive_reverts_fromContractWithoutLccs() public {
        uint256 sendAmount = 1 ether;

        // Contract without lccs() function tries to send ETH
        vm.expectRevert(Errors.InvalidEthSender.selector);
        contractWithoutLccs.sendEth{value: sendAmount}(payable(address(modulesHarness)));
    }

    function test_modules_receive_reverts_fromUnauthorisedEOA() public {
        uint256 sendAmount = 1 ether;

        // Unauthorised EOA tries to send ETH
        vm.prank(unauthorisedSender);
        vm.expectRevert(Errors.InvalidEthSender.selector);
        (bool success,) = address(modulesHarness).call{value: sendAmount}("");

        success; // silence unused variable warning
    }

    // ============================================================
    // ============ EDGE CASE & FUZZ TESTS =========================
    // ============================================================

    function testFuzz_forks_wrap_variousAmounts(uint256 amount) public {
        // Bound amount to reasonable range (harness has 100 ETH)
        amount = bound(amount, 0, 50 ether);

        uint256 harnessEthBefore = address(forksHarness).balance;
        uint256 harnessWethBefore = weth9.balanceOf(address(forksHarness));

        forksHarness.wrap(amount);

        uint256 harnessEthAfter = address(forksHarness).balance;
        uint256 harnessWethAfter = weth9.balanceOf(address(forksHarness));

        assertEq(harnessEthBefore - harnessEthAfter, amount, "ETH should decrease by wrap amount");
        assertEq(harnessWethAfter - harnessWethBefore, amount, "WETH should increase by wrap amount");
    }

    function testFuzz_forks_unwrap_variousAmounts(uint256 wrapAmount, uint256 unwrapAmount) public {
        // Bound amounts to reasonable range
        wrapAmount = bound(wrapAmount, 1, 50 ether);
        unwrapAmount = bound(unwrapAmount, 0, wrapAmount);

        // First wrap some ETH
        forksHarness.wrap(wrapAmount);

        uint256 harnessEthBefore = address(forksHarness).balance;
        uint256 harnessWethBefore = weth9.balanceOf(address(forksHarness));

        forksHarness.unwrap(unwrapAmount);

        uint256 harnessEthAfter = address(forksHarness).balance;
        uint256 harnessWethAfter = weth9.balanceOf(address(forksHarness));

        assertEq(harnessEthAfter - harnessEthBefore, unwrapAmount, "ETH should increase by unwrap amount");
        assertEq(harnessWethBefore - harnessWethAfter, unwrapAmount, "WETH should decrease by unwrap amount");
    }

    function testFuzz_modules_wrap_variousAmounts(uint256 amount) public {
        amount = bound(amount, 0, 50 ether);

        uint256 harnessEthBefore = address(modulesHarness).balance;
        uint256 harnessWethBefore = weth9.balanceOf(address(modulesHarness));

        modulesHarness.wrap(amount);

        uint256 harnessEthAfter = address(modulesHarness).balance;
        uint256 harnessWethAfter = weth9.balanceOf(address(modulesHarness));

        assertEq(harnessEthBefore - harnessEthAfter, amount, "ETH should decrease by wrap amount");
        assertEq(harnessWethAfter - harnessWethBefore, amount, "WETH should increase by wrap amount");
    }
}

