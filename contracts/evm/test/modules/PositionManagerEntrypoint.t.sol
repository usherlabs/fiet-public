// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {PositionManagerEntrypoint} from "../../src/modules/PositionManagerEntrypoint.sol";
import {VTSCurrencyDeltaHarness} from "../libraries/harnesses/VTSCurrencyDeltaHarness.sol";
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

    /// @dev Payable so `delegatecall` from a payable outer call (e.g. multicall simulation) does not revert on non-zero `msg.value`.
    function exposeAfterBatch() external payable {
        _afterBatch();
    }

    function exposeTake(Currency currency, address to, uint256 maxAmount) external {
        _take(currency, to, maxAmount);
    }

    /// @dev Mirrors `Multicall_v4`: each inner step is `address(this).delegatecall(...)`, so the outer tx `msg.value`
    ///      is visible on every inner batch without re-attaching ETH (unlike nested `{value: ...}` calls).
    function simulateMulticall_twoBatches() external payable {
        if (msg.value != 1 ether) revert();
        (bool ok,) = address(this).delegatecall(abi.encodeCall(this.exposeBeforeBatch, ()));
        require(ok);
        (ok,) = address(this).delegatecall(abi.encodeCall(this.exposeAfterBatch, ()));
        require(ok);
        (ok,) = address(this).delegatecall(abi.encodeCall(this.exposeBeforeBatch, ()));
        require(ok);
    }

    /// @dev Three inner payable batches under one outer `msg.value` — native credit must apply on the first leg only.
    function simulateMulticall_threeBatches() external payable {
        if (msg.value != 1 ether) revert();
        (bool ok,) = address(this).delegatecall(abi.encodeCall(this.exposeBeforeBatch, ()));
        require(ok);
        (ok,) = address(this).delegatecall(abi.encodeCall(this.exposeAfterBatch, ()));
        require(ok);
        (ok,) = address(this).delegatecall(abi.encodeCall(this.exposeBeforeBatch, ()));
        require(ok);
        (ok,) = address(this).delegatecall(abi.encodeCall(this.exposeAfterBatch, ()));
        require(ok);
        (ok,) = address(this).delegatecall(abi.encodeCall(this.exposeBeforeBatch, ()));
        require(ok);
    }
}

/// @dev Two separate external calls in one tx (not `delegatecall`); second call attaches fresh ETH.
contract TwoTopLevelPayableBatches {
    function run(PositionManagerEntrypointHarness h) external payable {
        h.exposeBeforeBatch{value: 0}();
        h.exposeAfterBatch();
        h.exposeBeforeBatch{value: 1 ether}();
    }
}

/// @dev Two funded top-level batches in one tx (e.g. 0.5 + 0.5 ETH) — each fresh attachment credits once.
contract TwoTopLevelTwoFundedBatches {
    function run(PositionManagerEntrypointHarness h) external payable {
        if (msg.value != 1 ether) revert();
        h.exposeBeforeBatch{value: 0.5 ether}();
        h.exposeAfterBatch();
        h.exposeBeforeBatch{value: 0.5 ether}();
        h.exposeAfterBatch();
    }
}

/// @dev Funded first batch, then zero-value second batch — second leg must not call `creditExact` again.
contract FundedThenZeroTopLevel {
    function run(PositionManagerEntrypointHarness h) external payable {
        if (msg.value != 1 ether) revert();
        h.exposeBeforeBatch{value: 1 ether}();
        h.exposeAfterBatch();
        h.exposeBeforeBatch{value: 0}();
        h.exposeAfterBatch();
    }
}

contract PositionManagerEntrypointTest is Test {
    PositionManagerEntrypointHarness internal h;
    DelegationImpl internal impl;

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

    /// @notice Single payable batch in an isolated tx: full `msg.value` is credited (no prior snapshot).
    function test_singleBatch_singlePayableCall_creditsFullMsgValue() public {
        vm.mockCall(
            orch,
            abi.encodeWithSignature(
                "creditExact(address,address,address,uint256)", factory, address(0), locker, 2 ether
            ),
            abi.encode(int128(int256(2 ether)))
        );
        vm.expectCall(
            orch,
            abi.encodeWithSignature(
                "creditExact(address,address,address,uint256)", factory, address(0), locker, 2 ether
            )
        );
        h.exposeBeforeBatch{value: 2 ether}();
    }

    /// @notice Single tx, single batch, zero `msg.value`: no credit (ambient-only balance unchanged for credit purposes).
    function test_singleBatch_zeroMsgValue_noCreditEvenWithAmbientEth() public {
        vm.deal(address(h), 3 ether);
        // No creditExact
        h.exposeBeforeBatch{value: 0}();
    }

    /// @notice Distinct payable top-level calls in one tx must each credit new ETH (not blocked by tx-scoped boolean guard).
    function test_balanceDelta_twoTopLevelCalls_creditsSecondFundedOnly() public {
        vm.mockCall(
            orch,
            abi.encodeWithSignature(
                "creditExact(address,address,address,uint256)", factory, address(0), locker, 1 ether
            ),
            abi.encode(int128(int256(1 ether)))
        );
        vm.mockCall(orch, abi.encodeWithSignature("assertNonZeroDeltas(address)", factory), abi.encode());
        vm.expectCall(
            orch,
            abi.encodeWithSignature(
                "creditExact(address,address,address,uint256)", factory, address(0), locker, 1 ether
            ),
            1
        );
        vm.expectCall(orch, abi.encodeWithSignature("assertNonZeroDeltas(address)", factory), 1);
        TwoTopLevelPayableBatches router = new TwoTopLevelPayableBatches();
        router.run{value: 1 ether}(h);
    }

    /// @notice Two funded top-level batches in one tx: each 0.5 ETH attachment credits separately (1 ETH total credit).
    function test_balanceDelta_twoTopLevelFundedBatches_eachCreditsHalf() public {
        vm.mockCall(
            orch,
            abi.encodeWithSignature(
                "creditExact(address,address,address,uint256)", factory, address(0), locker, 0.5 ether
            ),
            abi.encode(int128(int256(0.5 ether)))
        );
        vm.mockCall(orch, abi.encodeWithSignature("assertNonZeroDeltas(address)", factory), abi.encode());
        vm.expectCall(
            orch,
            abi.encodeWithSignature(
                "creditExact(address,address,address,uint256)", factory, address(0), locker, 0.5 ether
            ),
            2
        );
        vm.expectCall(orch, abi.encodeWithSignature("assertNonZeroDeltas(address)", factory), 2);
        TwoTopLevelTwoFundedBatches router = new TwoTopLevelTwoFundedBatches();
        router.run{value: 1 ether}(h);
    }

    /// @notice Ambient ETH on the harness must not be credited; only `msg.value` for this call is.
    function test_balanceDelta_ambientPlusMsgValue_creditsOnlyMsgValue() public {
        vm.deal(address(h), 5 ether);
        vm.mockCall(
            orch,
            abi.encodeWithSignature(
                "creditExact(address,address,address,uint256)", factory, address(0), locker, 1 ether
            ),
            abi.encode(int128(int256(1 ether)))
        );
        vm.expectCall(
            orch,
            abi.encodeWithSignature(
                "creditExact(address,address,address,uint256)", factory, address(0), locker, 1 ether
            )
        );
        h.exposeBeforeBatch{value: 1 ether}();
    }

    /// @notice Regression: `Multicall_v4`-style delegatecalls must not each credit the same outer `msg.value`.
    function test_multicallDelegatecall_twoBatches_creditExactCalledOnce() public {
        vm.mockCall(
            orch,
            abi.encodeWithSignature(
                "creditExact(address,address,address,uint256)", factory, address(0), locker, 1 ether
            ),
            abi.encode(int128(int256(1 ether)))
        );
        vm.mockCall(orch, abi.encodeWithSignature("assertNonZeroDeltas(address)", factory), abi.encode());
        vm.expectCall(
            orch,
            abi.encodeWithSignature(
                "creditExact(address,address,address,uint256)", factory, address(0), locker, 1 ether
            ),
            1
        );
        vm.expectCall(orch, abi.encodeWithSignature("assertNonZeroDeltas(address)", factory), 1);
        h.simulateMulticall_twoBatches{value: 1 ether}();
    }

    /// @notice Three inner delegatecall batches under one outer ETH: `creditExact` once for that ETH.
    function test_multicallDelegatecall_threeBatches_creditExactCalledOnce() public {
        vm.mockCall(
            orch,
            abi.encodeWithSignature(
                "creditExact(address,address,address,uint256)", factory, address(0), locker, 1 ether
            ),
            abi.encode(int128(int256(1 ether)))
        );
        vm.mockCall(orch, abi.encodeWithSignature("assertNonZeroDeltas(address)", factory), abi.encode());
        vm.expectCall(
            orch,
            abi.encodeWithSignature(
                "creditExact(address,address,address,uint256)", factory, address(0), locker, 1 ether
            ),
            1
        );
        vm.expectCall(orch, abi.encodeWithSignature("assertNonZeroDeltas(address)", factory), 2);
        h.simulateMulticall_threeBatches{value: 1 ether}();
    }

    /// @notice Asymmetry: funded batch then zero-value batch — only one `creditExact` for the funded attachment.
    function test_balanceDelta_fundedThenZeroTopLevel_secondBatchDoesNotCreditAgain() public {
        vm.mockCall(
            orch,
            abi.encodeWithSignature(
                "creditExact(address,address,address,uint256)", factory, address(0), locker, 1 ether
            ),
            abi.encode(int128(int256(1 ether)))
        );
        vm.mockCall(orch, abi.encodeWithSignature("assertNonZeroDeltas(address)", factory), abi.encode());
        vm.expectCall(
            orch,
            abi.encodeWithSignature(
                "creditExact(address,address,address,uint256)", factory, address(0), locker, 1 ether
            ),
            1
        );
        vm.expectCall(orch, abi.encodeWithSignature("assertNonZeroDeltas(address)", factory), 2);
        FundedThenZeroTopLevel router = new FundedThenZeroTopLevel();
        router.run{value: 1 ether}(h);
    }

    function test_afterBatch_callsAssertNonZeroDeltas() public {
        vm.expectCall(orch, abi.encodeWithSignature("assertNonZeroDeltas(address)", factory));
        h.exposeAfterBatch();
    }

    /// @notice Regression: `_afterBatch` must fail the unlock when factory-scoped produced credit remains uncleared.
    /// @dev Uses `VTSCurrencyDeltaHarness` as the orchestrator stand-in so `MarketCurrencyDelta` transient state
    ///      matches the callee context of `assertNonZeroDeltas` (same as production `VTSOrchestrator` wiring).
    function test_afterBatch_revertsWhenMarketProducedCreditUnresolved() public {
        VTSCurrencyDeltaHarness orchHarness = new VTSCurrencyDeltaHarness();
        PositionManagerEntrypointHarness hh =
            new PositionManagerEntrypointHarness(factory, address(orchHarness), canonical, address(impl), locker);

        MockERC20 creditToken = new MockERC20("P", "P");
        orchHarness.seedMarketProduced(factory, Currency.wrap(address(creditToken)), 1 ether);

        vm.expectRevert(Errors.CurrencyNotSettled.selector);
        hh.exposeAfterBatch();
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

