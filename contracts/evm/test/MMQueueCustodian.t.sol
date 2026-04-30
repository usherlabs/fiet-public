// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {MMQueueCustodian} from "../src/MMQueueCustodian.sol";
import {MMQueueCustodianFactory} from "../src/MMQueueCustodianFactory.sol";
import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";
import {INativeSettlementReceiver} from "../src/interfaces/INativeSettlementReceiver.sol";
import {Errors} from "../src/libraries/Errors.sol";
import {MockERC20} from "./_mocks/MockERC20.sol";

contract DummyPositionManager {}

/// @dev Has bytecode so `MMQueueCustodian` constructor accepts it as `positionManager`.
contract DummyMmpmWithCode {}

contract MockLccForQueueCustodian is MockERC20 {
    address public immutable hub;
    address public immutable underlying;

    constructor(address hub_, address underlying_) MockERC20("LCC", "LCC", 18) {
        hub = hub_;
        underlying = underlying_;
    }
}

contract MockHubForQueueCustodian {
    MockERC20 internal immutable underlying;

    uint256 internal queueBefore;
    uint256 internal queueAfter;
    uint256 internal immediateUnderlying;
    bool internal unwrapCalled;

    constructor(MockERC20 underlying_) {
        underlying = underlying_;
    }

    function configure(uint256 queueBefore_, uint256 queueAfter_, uint256 immediateUnderlying_) external {
        queueBefore = queueBefore_;
        queueAfter = queueAfter_;
        immediateUnderlying = immediateUnderlying_;
        unwrapCalled = false;
    }

    function settleQueue(address, address) external view returns (uint256) {
        return unwrapCalled ? queueAfter : queueBefore;
    }

    function unwrap(address, uint256) external {
        unwrapCalled = true;
        if (immediateUnderlying > 0) {
            underlying.mint(msg.sender, immediateUnderlying);
        }
    }
}

contract MMQueueCustodianTest is Test {
    event UnderlyingReleasedToManager(address indexed lcc, uint256 amount);

    MMQueueCustodian internal custodian;
    MockERC20 internal lcc;
    MockERC20 internal underlying;
    MockHubForQueueCustodian internal hub;
    MockLccForQueueCustodian internal hubBackedLcc;
    DummyPositionManager internal positionManager;

    address internal attacker = makeAddr("attacker");
    address internal beneficiaryAddr = makeAddr("beneficiary");
    address internal forwardRecipient = makeAddr("forwardRecipient");

    function setUp() public {
        positionManager = new DummyPositionManager();
        custodian = new MMQueueCustodian(address(positionManager), beneficiaryAddr);
        lcc = new MockERC20("LCC", "LCC", 18);
        underlying = new MockERC20("Underlying", "UND", 18);
        hub = new MockHubForQueueCustodian(underlying);
        hubBackedLcc = new MockLccForQueueCustodian(address(hub), address(underlying));
    }

    function test_constructor_revertsForZeroPositionManager() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
        new MMQueueCustodian(address(0), beneficiaryAddr);
    }

    function test_constructor_revertsForEoaPositionManager() public {
        address eoa = makeAddr("eoa");
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, eoa));
        new MMQueueCustodian(eoa, beneficiaryAddr);
    }

    function test_constructor_revertsForZeroBeneficiary() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
        new MMQueueCustodian(address(positionManager), address(0));
    }

    function test_positionManager_and_beneficiary_areImmutable() public {
        assertEq(custodian.positionManager(), address(positionManager));
        assertEq(custodian.beneficiary(), beneficiaryAddr);
    }

    /// @dev `totalQueuedLcc` is the on-chain LCC ERC20 balance (balance-as-ledger).
    function test_totalQueuedLcc_matchesLccBalance() public {
        lcc.mint(address(custodian), 100);
        assertEq(custodian.totalQueuedLcc(address(lcc)), 100);
    }

    function test_totalQueuedLcc_zeroWhenNoLccHeld() public {
        assertEq(custodian.totalQueuedLcc(address(lcc)), 0);
    }

    function test_supportsInterface_declaresNativeSettlementReceiver() public view {
        assertTrue(custodian.supportsInterface(type(IERC165).interfaceId));
        assertTrue(custodian.supportsInterface(type(INativeSettlementReceiver).interfaceId));
    }

    function test_unwrapLcc_revertsWhenCallerIsNotPositionManager() public {
        vm.prank(attacker);
        vm.expectRevert(Errors.InvalidSender.selector);
        custodian.unwrapLcc(address(hubBackedLcc), forwardRecipient, 1);
    }

    function test_unwrapLcc_revertsWhenQueuedDeltaExceedsHeldLcc() public {
        hubBackedLcc.mint(address(custodian), 1);
        hub.configure(4, 7, 0);

        vm.prank(address(positionManager));
        vm.expectRevert(abi.encodeWithSelector(Errors.InsufficientBalance.selector, uint256(1), uint256(3)));
        custodian.unwrapLcc(address(hubBackedLcc), forwardRecipient, 5);
    }

    function test_unwrapLcc_forwardsOnlyImmediateUnderlyingDelta() public {
        underlying.mint(address(custodian), 7);
        hubBackedLcc.mint(address(custodian), 10);
        hub.configure(2, 2, 5);

        vm.prank(address(positionManager));
        custodian.unwrapLcc(address(hubBackedLcc), forwardRecipient, 10);

        assertEq(underlying.balanceOf(forwardRecipient), 5);
        assertEq(underlying.balanceOf(address(custodian)), 7);
    }

    function test_release_revertsWhenCallerIsNotPositionManager() public {
        vm.prank(attacker);
        vm.expectRevert(Errors.InvalidSender.selector);
        custodian.release(address(hubBackedLcc), 1);
    }

    function test_release_transfersAvailableUnderlyingToPositionManagerAndEmits() public {
        underlying.mint(address(custodian), 6);

        vm.expectEmit(true, false, false, true, address(custodian));
        emit UnderlyingReleasedToManager(address(hubBackedLcc), 4);

        vm.prank(address(positionManager));
        custodian.release(address(hubBackedLcc), 4);

        assertEq(underlying.balanceOf(address(positionManager)), 4);
        assertEq(underlying.balanceOf(address(custodian)), 2);
    }
}

/// @notice Unit tests for `MMQueueCustodianFactory` authorisation and deployment wiring.
contract MMQueueCustodianFactoryTest is Test {
    MMQueueCustodianFactory internal factory;
    address internal marketFactoryAddr;

    function setUp() public {
        factory = new MMQueueCustodianFactory();
        marketFactoryAddr = makeAddr("marketFactory");
    }

    function test_factory_deploy_reverts_zeroRecipient() public {
        vm.mockCall(
            marketFactoryAddr, abi.encodeWithSelector(IMarketFactory.bounds.selector, address(this)), abi.encode(true)
        );
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
        factory.deploy(address(0), IMarketFactory(marketFactoryAddr));
    }

    function test_factory_deploy_reverts_whenCallerNotBound() public {
        address caller = makeAddr("unboundMmpm");
        vm.mockCall(
            marketFactoryAddr, abi.encodeWithSelector(IMarketFactory.bounds.selector, caller), abi.encode(false)
        );
        vm.prank(caller);
        vm.expectRevert(Errors.InvalidSender.selector);
        factory.deploy(makeAddr("recipient"), IMarketFactory(marketFactoryAddr));
    }

    function test_factory_deploy_succeeds_whenCallerBound() public {
        address mmpm = address(new DummyMmpmWithCode());
        address recipient = makeAddr("recipient");
        vm.mockCall(marketFactoryAddr, abi.encodeWithSelector(IMarketFactory.bounds.selector, mmpm), abi.encode(true));
        vm.prank(mmpm);
        address deployed = factory.deploy(recipient, IMarketFactory(marketFactoryAddr));
        assertEq(MMQueueCustodian(payable(deployed)).positionManager(), mmpm);
        assertEq(MMQueueCustodian(payable(deployed)).beneficiary(), recipient);
    }
}
