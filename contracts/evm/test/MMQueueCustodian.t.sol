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
    address internal beneficiaryAddr = makeAddr("beneficiary");

    function setUp() public {
        positionManager = new DummyPositionManager();
        custodian = new MMQueueCustodian(address(positionManager), beneficiaryAddr);
        lcc = new MockERC20("LCC", "LCC", 18);
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
}

/// @dev No `receive` / `fallback`: native ETH transfer to PM fails; WETH fallback must apply (see HUB-02C).
contract NonPayablePositionManager {}

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

/// @dev Minimal ERC20 “LCC” with native underlying and hub pointer (enough for `releaseSettledUnderlyingToManager` + `totalQueuedLcc`).
contract MockLccNative is ERC20 {
    address public immutable hubAddr;

    constructor(address _hub) ERC20("LCC", "LCC") {
        hubAddr = _hub;
    }

    function underlying() external pure returns (address) {
        return address(0);
    }

    function hub() external view returns (address) {
        return hubAddr;
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

/// @notice Regression: non-payable position manager receives WETH when native push fails (mirrors `LiquidityHubLib.transferUnderlying`).
contract MMQueueCustodianNativeWethFallbackTest is Test {
    uint256 internal constant AMOUNT = 1 ether;

    function test_releaseSettledUnderlyingToManager_nonPayablePm_receivesWeth() public {
        NonPayablePositionManager pm = new NonPayablePositionManager();
        address ben = makeAddr("ben");
        MMQueueCustodian cust = new MMQueueCustodian(address(pm), ben);

        MockWETH9 weth = new MockWETH9();
        MockHubForWeth hub = new MockHubForWeth(address(weth));
        MockLccNative lccNative = new MockLccNative(address(hub));

        vm.deal(address(cust), AMOUNT);

        vm.prank(address(pm));
        cust.releaseSettledUnderlyingToManager(address(lccNative), AMOUNT);

        assertEq(IERC20(address(weth)).balanceOf(address(pm)), AMOUNT);
        assertEq(address(pm).balance, 0);
        assertEq(cust.totalQueuedLcc(address(lccNative)), 0);
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
