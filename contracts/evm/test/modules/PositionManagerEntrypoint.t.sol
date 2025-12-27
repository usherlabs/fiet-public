// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {PositionManagerEntrypoint} from "../../src/modules/PositionManagerEntrypoint.sol";
import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals = 18;

    mapping(address => uint256) public balanceOf;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract DelegationImpl {
    error ImplBoom();

    uint256 public x;

    function setX(uint256 v) external {
        x = v;
    }

    function willRevert() external pure {
        revert ImplBoom();
    }

    function viewAnswer() external pure returns (bytes32) {
        return bytes32(uint256(123));
    }

    function viewRevert() external pure returns (bytes32) {
        revert ImplBoom();
    }
}

contract PositionManagerEntrypointHarness is PositionManagerEntrypoint {
    address internal immutable _locker;
    // Used to validate delegatecall writes to the caller's storage.
    uint256 public x;

    constructor(address hub, address orch, address impl, address locker) PositionManagerEntrypoint(hub, orch, impl) {
        _locker = locker;
    }

    function msgSender() public view override returns (address) {
        return _locker;
    }

    function exposeDelegateToImpl(bytes memory data) external {
        _delegateToImpl(data);
    }

    function exposeBeforeBatch() external payable {
        _beforeBatch();
    }

    function exposeAfterBatch() external view {
        _afterBatch();
    }

    function exposeTake(Currency currency, address to, uint256 maxAmount) external {
        _take(currency, to, maxAmount);
    }
}

contract PositionManagerEntrypointTest is Test {
    PositionManagerEntrypointHarness internal h;
    DelegationImpl internal impl;

    address internal hub;
    address internal orch;
    address internal locker;

    function setUp() public {
        hub = makeAddr("hub");
        orch = makeAddr("vtsOrchestrator");
        locker = makeAddr("locker");
        // Foundry reverts on interface calls to EOAs ("call to non-contract address").
        vm.etch(orch, hex"00");
        impl = new DelegationImpl();
        h = new PositionManagerEntrypointHarness(hub, orch, address(impl), locker);
    }

    function test_delegateToImpl_success() public {
        h.exposeDelegateToImpl(abi.encodeWithSelector(DelegationImpl.setX.selector, 42));
        assertEq(h.x(), 42);
    }

    function test_delegateToImpl_bubblesRevert() public {
        vm.expectRevert(DelegationImpl.ImplBoom.selector);
        h.exposeDelegateToImpl(abi.encodeWithSelector(DelegationImpl.willRevert.selector));
    }

    function test_beforeBatch_zeroValue_doesNothing() public {
        // No calls to orchestrator expected.
        h.exposeBeforeBatch{value: 0}();
    }

    function test_beforeBatch_nonZeroValue_syncsNativeAsCredit() public {
        vm.expectCall(orch, abi.encodeWithSignature("sync(address,address,address)", address(0), address(h), locker));
        h.exposeBeforeBatch{value: 1}();
    }

    function test_afterBatch_callsAssertNonZeroDeltas() public {
        vm.expectCall(orch, abi.encodeWithSignature("assertNonZeroDeltas()"));
        h.exposeAfterBatch();
    }

    function test_take_maxAmountZero_capsToBalance_andTransfersToRecipient() public {
        MockERC20 token = new MockERC20("T", "T");
        token.mint(address(h), 100);
        address recipient = makeAddr("recipient");

        // maxAmount=0 => trueMaxAmount=bal(100)
        vm.mockCall(
            orch,
            abi.encodeWithSignature("take(address,address,uint256)", address(token), locker, 100),
            abi.encode(uint256(60))
        );

        h.exposeTake(Currency.wrap(address(token)), recipient, 0);
        assertEq(token.balanceOf(recipient), 60);
    }

    function test_take_toSelf_doesNotTransfer() public {
        MockERC20 token = new MockERC20("T", "T");
        token.mint(address(h), 100);

        vm.mockCall(
            orch,
            abi.encodeWithSignature("take(address,address,uint256)", address(token), locker, 10),
            abi.encode(uint256(7))
        );

        // maxAmount=10 and balance=100 => trueMaxAmount=10
        h.exposeTake(Currency.wrap(address(token)), address(h), 10);
        assertEq(token.balanceOf(address(h)), 100);
    }
}

