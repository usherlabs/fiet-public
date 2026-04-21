// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {MMQueueCustodian} from "../src/MMQueueCustodian.sol";
import {MMQueueCustodianFactory} from "../src/MMQueueCustodianFactory.sol";
import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";
import {Errors} from "../src/libraries/Errors.sol";
import {MockERC20} from "./_mocks/MockERC20.sol";

contract DummyPositionManager {}

/// @dev Has bytecode so `MMQueueCustodian` constructor accepts it as `positionManager`.
contract DummyMmpmWithCode {}

contract MMQueueCustodianTest is Test {
    MMQueueCustodian internal custodian;
    MockERC20 internal lcc;
    DummyPositionManager internal positionManager;

    address internal attacker = makeAddr("attacker");
    address internal beneficiary = makeAddr("beneficiary");
    address internal otherBeneficiary = makeAddr("otherBeneficiary");

    uint256 internal constant TOKEN_ID_A = 11;
    uint256 internal constant TOKEN_ID_B = 22;

    function setUp() public {
        positionManager = new DummyPositionManager();
        custodian = new MMQueueCustodian(address(positionManager));
        lcc = new MockERC20("LCC", "LCC", 18);
    }

    function test_constructor_revertsForZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
        new MMQueueCustodian(address(0));
    }

    function test_constructor_revertsForEoa() public {
        address eoa = makeAddr("eoa");
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, eoa));
        new MMQueueCustodian(eoa);
    }

    function test_positionManager_isImmutable() public {
        assertEq(custodian.positionManager(), address(positionManager));
    }

    function test_record_revertsWhenCallerIsNotPositionManager() public {
        vm.prank(attacker);
        vm.expectRevert(Errors.InvalidSender.selector);
        custodian.record(TOKEN_ID_A, address(lcc), beneficiary, 1);
    }

    function test_record_revertsForZeroLcc() public {
        vm.prank(address(positionManager));
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
        custodian.record(TOKEN_ID_A, address(0), beneficiary, 1);
    }

    function test_record_revertsForZeroBeneficiary() public {
        vm.prank(address(positionManager));
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
        custodian.record(TOKEN_ID_A, address(lcc), address(0), 1);
    }

    function test_record_zeroAmount_isNoop() public {
        vm.prank(address(positionManager));
        custodian.record(TOKEN_ID_A, address(lcc), beneficiary, 0);

        assertEq(custodian.queued(TOKEN_ID_A, address(lcc), beneficiary), 0);
        assertTrue(custodian.isBucketEmpty(TOKEN_ID_A));
    }

    function test_record_accumulatesPerTokenIdLccAndBeneficiary() public {
        vm.startPrank(address(positionManager));
        custodian.record(TOKEN_ID_A, address(lcc), beneficiary, 10);
        custodian.record(TOKEN_ID_A, address(lcc), beneficiary, 15);
        custodian.record(TOKEN_ID_B, address(lcc), beneficiary, 7);
        custodian.record(TOKEN_ID_A, address(lcc), otherBeneficiary, 100);
        vm.stopPrank();

        assertEq(custodian.queued(TOKEN_ID_A, address(lcc), beneficiary), 25);
        assertEq(custodian.queued(TOKEN_ID_B, address(lcc), beneficiary), 7);
        assertEq(custodian.queued(TOKEN_ID_A, address(lcc), otherBeneficiary), 100);
        assertFalse(custodian.isBucketEmpty(TOKEN_ID_A));
        assertFalse(custodian.isBucketEmpty(TOKEN_ID_B));
    }

    function test_totalQueuedLcc_tracksRecordsAcrossBuckets() public {
        vm.startPrank(address(positionManager));
        custodian.record(TOKEN_ID_A, address(lcc), beneficiary, 10);
        custodian.record(TOKEN_ID_B, address(lcc), beneficiary, 7);
        assertEq(custodian.totalQueuedLcc(address(lcc)), 17);
        vm.stopPrank();
    }

    function test_isBucketEmpty_trueWhenBucketUnused() public {
        assertTrue(custodian.isBucketEmpty(TOKEN_ID_A));
    }
}

/// @dev No `receive` / `fallback`: native ETH transfer from custodian fails; WETH fallback must apply (see HUB-02C).
contract NonPayableBeneficiary {}

/// @dev Minimal Hub exposing `weth9()` for `MMQueueCustodian._payNativeWithWethFallback`.
contract MockHubForWeth {
    address public immutable weth;

    constructor(address _weth) {
        weth = _weth;
    }

    function weth9() external view returns (address) {
        return weth;
    }
}

/// @dev Native-backed LCC: `underlying() == address(0)`, `hub()` returns the mock Hub above.
contract MockLccNative {
    address public immutable hub;

    constructor(address _hub) {
        hub = _hub;
    }

    function underlying() external pure returns (address) {
        return address(0);
    }
}

/// @dev Minimal WETH9: `deposit{value}` mints to caller (IWETH9-compatible for custodian wrap).
contract MockWETH9 is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    receive() external payable {
        _mint(msg.sender, msg.value);
    }
}

/// @notice Regression: non-payable beneficiary receives WETH when native push fails (mirrors `LiquidityHubLib.transferUnderlying`).
contract MMQueueCustodianNativeWethFallbackTest is Test {
    uint256 internal constant TOKEN_ID = 1;
    uint256 internal constant AMOUNT = 1 ether;

    function test_collectUnderlyingToBeneficiary_nonPayableBeneficiary_receivesWeth() public {
        DummyPositionManager pm = new DummyPositionManager();
        MMQueueCustodian cust = new MMQueueCustodian(address(pm));

        MockWETH9 weth = new MockWETH9();
        MockHubForWeth hub = new MockHubForWeth(address(weth));
        MockLccNative lccNative = new MockLccNative(address(hub));

        NonPayableBeneficiary beneficiary = new NonPayableBeneficiary();

        vm.startPrank(address(pm));
        cust.record(TOKEN_ID, address(lccNative), address(beneficiary), AMOUNT);
        vm.stopPrank();

        vm.deal(address(cust), AMOUNT);

        vm.prank(address(pm));
        cust.collectUnderlyingToBeneficiary(TOKEN_ID, address(lccNative), address(beneficiary), AMOUNT);

        assertEq(IERC20(address(weth)).balanceOf(address(beneficiary)), AMOUNT);
        assertEq(address(beneficiary).balance, 0);
        assertTrue(cust.isBucketEmpty(TOKEN_ID));
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
    }
}
