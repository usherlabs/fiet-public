// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {PositionManagerEntrypoint} from "../../src/modules/PositionManagerEntrypoint.sol";
import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {Errors} from "../../src/libraries/Errors.sol";

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

    constructor(address factory, address orch, address canonicalCustody, address impl, address locker)
        PositionManagerEntrypoint(factory, orch, canonicalCustody, impl)
    {
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

    function exposeAfterBatch() external {
        _afterBatch();
    }

    function exposeTake(Currency currency, address to, uint256 maxAmount) external {
        _take(currency, to, maxAmount);
    }
}

contract BeforeAfterBatchCaller {
    function callZeroThenOne(PositionManagerEntrypointHarness harness) external payable {
        if (msg.value != 1) revert();
        harness.exposeBeforeBatch{value: 0}();
        harness.exposeAfterBatch();
        harness.exposeBeforeBatch{value: 1}();
    }
}

contract PositionManagerEntrypointTest is Test {
    PositionManagerEntrypointHarness internal h;
    DelegationImpl internal impl;
    BeforeAfterBatchCaller internal caller;

    address internal hub;
    address internal factory;
    address internal orch;
    address internal canonical;
    address internal locker;

    function setUp() public {
        hub = makeAddr("hub");
        factory = makeAddr("factory");
        orch = makeAddr("vtsOrchestrator");
        canonical = makeAddr("canonicalVault");
        locker = makeAddr("locker");
        // Foundry reverts on interface calls to EOAs ("call to non-contract address").
        vm.etch(factory, hex"00");
        vm.mockCall(factory, abi.encodeWithSignature("liquidityHub()"), abi.encode(hub));
        vm.etch(orch, hex"00");
        vm.etch(canonical, hex"00");
        impl = new DelegationImpl();
        h = new PositionManagerEntrypointHarness(factory, orch, canonical, address(impl), locker);
        caller = new BeforeAfterBatchCaller();
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
        vm.mockCall(
            orch,
            abi.encodeWithSignature("creditExact(address,address,address,uint256)", factory, address(0), locker, 1),
            abi.encode(int128(1))
        );
        vm.expectCall(
            orch,
            abi.encodeWithSignature("creditExact(address,address,address,uint256)", factory, address(0), locker, 1)
        );
        h.exposeBeforeBatch{value: 1}();
    }

    function test_beforeBatch_zeroThenNonZero_afterBatchClearsReadGuard_andCreditsSecondCall() public {
        vm.mockCall(
            orch,
            abi.encodeWithSignature("creditExact(address,address,address,uint256)", factory, address(0), locker, 1),
            abi.encode(int128(1))
        );
        vm.expectCall(
            orch,
            abi.encodeWithSignature("creditExact(address,address,address,uint256)", factory, address(0), locker, 1)
        );
        caller.callZeroThenOne{value: 1}(h);
    }

    function test_afterBatch_callsAssertNonZeroDeltas() public {
        vm.expectCall(orch, abi.encodeWithSignature("assertNonZeroDeltas()"));
        vm.expectCall(orch, abi.encodeWithSignature("assertNoPendingMarketDeltas(address)", factory));
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

    function test_constructor_revertsWhenActionsImplHasNoContractCode() public {
        address badImpl = makeAddr("badActionsImpl");
        vm.etch(badImpl, hex"");
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, badImpl));
        new PositionManagerEntrypointHarness(factory, orch, canonical, badImpl, locker);
    }

    function test_constructor_revertsWhenCanonicalCustodyIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
        new PositionManagerEntrypointHarness(factory, orch, address(0), address(impl), locker);
    }
}

