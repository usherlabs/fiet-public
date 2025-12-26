// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {LiquidityHubTestBase} from "./base/LiquidityHubTestBase.sol";
import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";
import {Errors} from "../src/libraries/Errors.sol";

contract MockMarketVaultForEthReceive {
    address internal _lcc0;
    address internal _lcc1;

    constructor(address lcc0_, address lcc1_) {
        _lcc0 = lcc0_;
        _lcc1 = lcc1_;
    }

    function lccs() external view returns (address, address) {
        return (_lcc0, _lcc1);
    }

    function sendEth(address payable to, uint256 amount) external {
        (bool ok, bytes memory data) = to.call{value: amount}("");
        if (!ok) {
            // Bubble revert data so tests can assert on the underlying custom error.
            assembly {
                revert(add(data, 0x20), mload(data))
            }
        }
    }

    receive() external payable {}
}

/**
 * @title LiquidityHubTest
 * @notice Core unit tests for LiquidityHub admin/accessors and edge cases.
 */
contract LiquidityHubTest is LiquidityHubTestBase {
    event LiquidityAvailable(address indexed lcc, address underlyingAsset, uint256 amount, bytes32 marketId);

    function test_setFactory_revertsWhenNotOwner() public {
        vm.prank(makeAddr("notOwner"));
        vm.expectRevert();
        liquidityHub.setFactory(makeAddr("factory"), true);
    }

    function test_createLCCPair_revertsWhenNotFactory() public {
        vm.prank(makeAddr("notFactory"));
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSender.selector));
        liquidityHub.createLCCPair(
            abi.encodePacked(address(0x1234)),
            address(underlyingAsset1),
            address(underlyingAsset2),
            "",
            new address[](0)
        );
    }

    function test_initialize_revertsWhenNotFactory() public {
        vm.prank(makeAddr("notFactory"));
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSender.selector));
        liquidityHub.initialize(lccToken1, lccToken2, bytes32("m"), abi.encodePacked(address(0x1234)));
    }

    function test_getFactory_revertsWhenFactoriesMismatch() public {
        // Create an additional market from a second factory address.
        address factory2 = makeAddr("FACTORY_2");
        liquidityHub.setFactory(factory2, true);

        // Mock oracleHelper() for factory2.
        vm.mockCall(
            factory2, abi.encodeWithSelector(IMarketFactory.oracleHelper.selector), abi.encode(address(oracleHelper))
        );

        address lccA;
        address lccB;
        vm.startPrank(factory2);
        address[] memory issuers = new address[](1);
        issuers[0] = factory2;
        (lccA, lccB) = liquidityHub.createLCCPair(
            abi.encodePacked(address(0x5678)),
            address(underlyingAsset1),
            address(underlyingAsset2),
            "Test Market 2",
            issuers
        );
        liquidityHub.initialize(lccA, lccB, bytes32("market2"), abi.encodePacked(address(0x5678)));
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(Errors.InvariantViolated.selector, "LCCs are not from the same market"));
        liquidityHub.getFactory(lccToken1, lccA);
    }

    function test_marketLiquidity_returnsZeroWhenMarketMissing() public view {
        assertEq(liquidityHub.marketLiquidity(address(0xDEAD)), 0);
    }

    function test_prepareSettle_revertsWithZeroAmount() public {
        vm.prank(factory);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector, uint256(0), uint256(0)));
        liquidityHub.prepareSettle(lccToken1, 0);
    }

    function test_prepareSettle_revertsWhenReserveInsufficient() public {
        vm.prank(factory);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector, uint256(1), uint256(0)));
        liquidityHub.prepareSettle(lccToken1, 1);
    }

    function test_prepareSettle_approvesErc20AndDecrementsReserve() public {
        uint256 amount = 10 ether;
        _wrapDirectLCC(user1, lccToken1, amount);

        uint256 reserveBefore = liquidityHub.reserveOfUnderlying(lccToken1);
        assertEq(reserveBefore, amount);

        vm.prank(factory);
        liquidityHub.prepareSettle(lccToken1, 3 ether);

        assertEq(liquidityHub.reserveOfUnderlying(lccToken1), reserveBefore - 3 ether);
        assertEq(underlyingAsset1.allowance(address(liquidityHub), factory), 3 ether);
    }

    function test_receive_revertsFromEoaSender() public {
        vm.deal(user1, 1 ether);
        vm.prank(user1);
        (bool ok,) = payable(address(liquidityHub)).call{value: 1}("");
        assertFalse(ok);
    }

    function test_receive_revertsWhenNoNativeLcc() public {
        MockMarketVaultForEthReceive vault = new MockMarketVaultForEthReceive(lccToken1, lccToken2);
        vm.deal(address(vault), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidEthSender.selector));
        vault.sendEth(payable(address(liquidityHub)), 1);
    }

    function test_receive_acceptsFromMarketVaultWithNativeLcc() public {
        // Create a market where one LCC is native-asset-backed.
        address lccNative;
        address lccErc20;
        vm.startPrank(factory);
        address[] memory issuers = new address[](1);
        issuers[0] = factory;
        (lccNative, lccErc20) = liquidityHub.createLCCPair(
            abi.encodePacked(address(0xBEEF)), address(0), address(underlyingAsset1), "Native Market", issuers
        );
        liquidityHub.initialize(lccNative, lccErc20, bytes32("nativeMarket"), abi.encodePacked(address(0xBEEF)));
        vm.stopPrank();

        MockMarketVaultForEthReceive vault = new MockMarketVaultForEthReceive(lccNative, lccErc20);
        vm.deal(address(vault), 1 ether);

        // Should not revert.
        vault.sendEth(payable(address(liquidityHub)), 1);
    }

    function test_confirmTake_emitsLiquidityAvailableWhenShouldEmitAndNotFullyConsumedByHubQueue() public {
        uint256 hubQueue = 5;
        uint256 amount = 10;

        // Create a queue entry for the Hub itself.
        _createSettlementQueueEntry(lccToken1, address(liquidityHub), hubQueue);

        vm.expectEmit(true, false, false, true, address(liquidityHub));
        emit LiquidityAvailable(lccToken1, address(underlyingAsset1), amount, marketId1);

        vm.prank(factory);
        liquidityHub.confirmTake(lccToken1, amount, true);
    }
}

