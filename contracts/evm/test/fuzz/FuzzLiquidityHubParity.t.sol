// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {LiquidityHub} from "../../src/LiquidityHub.sol";
import {FuzzLiquidityHub} from "./harnesses/FuzzLiquidityHub.sol";
import {Bounds} from "../../src/libraries/Bounds.sol";
import {MockOracleHelper} from "./mocks/MockOracleHelper.sol";
import {MockERC20Transferable} from "./mocks/MockERC20Transferable.sol";

contract FuzzLiquidityHubParityTest is Test {
    FuzzLiquidityHub internal hub;
    MockOracleHelper internal oracleHelperMock;
    MockERC20Transferable internal underlying0;
    MockERC20Transferable internal underlying1;

    address internal lcc0;
    address internal lcc1;

    bytes32 internal constant MARKET_ID = bytes32(uint256(29));

    uint256 internal mockedUsedMarketLiquidity;

    function setUp() public {
        oracleHelperMock = new MockOracleHelper(address(0xB0B));
        hub = new FuzzLiquidityHub(address(oracleHelperMock), "Ether", "ETH", 18, address(0), address(this));

        underlying0 = new MockERC20Transferable();
        underlying1 = new MockERC20Transferable();

        hub.setFactory(address(this), true);
        hub.setBoundLevel(address(hub), Bounds.BOUND_EXEMPT);

        address[] memory issuers = new address[](1);
        issuers[0] = address(this);
        (lcc0, lcc1) = hub.createLCCPair(
            abi.encodePacked(address(this), bytes1(0x29)), address(underlying0), address(underlying1), "Parity", issuers
        );
        hub.initialize(lcc0, lcc1, MARKET_ID, abi.encodePacked(address(this), bytes1(0x29)));
    }

    function useMarketLiquidity(address, bytes32, uint256) external view returns (uint256 used) {
        if (msg.sender != address(hub)) revert();
        return mockedUsedMarketLiquidity;
    }

    function oracleHelper() external view returns (address) {
        return address(oracleHelperMock);
    }

    function _createSettlementQueueEntry(address recipient, uint256 amount) internal {
        hub.issue(lcc0, recipient, amount);
        mockedUsedMarketLiquidity = 0;
        vm.prank(recipient);
        hub.unwrap(lcc0, amount);
        assertEq(hub.settleQueue(lcc0, recipient), amount);
    }

    function test_selectorParity_matchesLiquidityHubBoundedSurface() public pure {
        assertEq(FuzzLiquidityHub.setBoundLevel.selector, LiquidityHub.setBoundLevel.selector);
        assertEq(FuzzLiquidityHub.setBoundLevels.selector, LiquidityHub.setBoundLevels.selector);
        assertEq(FuzzLiquidityHub.marketUnderlyingToLCC.selector, LiquidityHub.marketUnderlyingToLCC.selector);
        assertEq(FuzzLiquidityHub.lccToUnderlying.selector, LiquidityHub.lccToUnderlying.selector);
        assertEq(FuzzLiquidityHub.lccToMarket.selector, LiquidityHub.lccToMarket.selector);
        assertEq(FuzzLiquidityHub.getFactory.selector, LiquidityHub.getFactory.selector);
        assertEq(FuzzLiquidityHub.issuers.selector, LiquidityHub.issuers.selector);
        assertEq(FuzzLiquidityHub.getLCC.selector, LiquidityHub.getLCC.selector);
        assertEq(FuzzLiquidityHub.getUnderlying.selector, LiquidityHub.getUnderlying.selector);
        assertEq(FuzzLiquidityHub.isLCC.selector, LiquidityHub.isLCC.selector);
        assertEq(FuzzLiquidityHub.directSupply.selector, LiquidityHub.directSupply.selector);
        assertEq(FuzzLiquidityHub.reserveOfUnderlying.selector, LiquidityHub.reserveOfUnderlying.selector);
        assertEq(FuzzLiquidityHub.reserveOfUnderlyingTuple.selector, LiquidityHub.reserveOfUnderlyingTuple.selector);
        assertEq(FuzzLiquidityHub.settleQueue.selector, LiquidityHub.settleQueue.selector);
        assertEq(FuzzLiquidityHub.totalQueued.selector, LiquidityHub.totalQueued.selector);
        assertEq(FuzzLiquidityHub.queueOfUnderlying.selector, LiquidityHub.queueOfUnderlying.selector);
        assertEq(FuzzLiquidityHub.unfundedQueueOfUnderlying.selector, LiquidityHub.unfundedQueueOfUnderlying.selector);
        assertEq(FuzzLiquidityHub.setFactory.selector, LiquidityHub.setFactory.selector);
        assertEq(FuzzLiquidityHub.createLCCPair.selector, LiquidityHub.createLCCPair.selector);
        assertEq(FuzzLiquidityHub.initialize.selector, LiquidityHub.initialize.selector);
        assertEq(FuzzLiquidityHub.wrapWith.selector, LiquidityHub.wrapWith.selector);
        assertEq(FuzzLiquidityHub.wrapWithTo.selector, LiquidityHub.wrapWithTo.selector);
        assertEq(FuzzLiquidityHub.marketLiquidity.selector, LiquidityHub.marketLiquidity.selector);
        assertEq(FuzzLiquidityHub.issue.selector, LiquidityHub.issue.selector);
        assertEq(FuzzLiquidityHub.cancel.selector, LiquidityHub.cancel.selector);
        assertEq(FuzzLiquidityHub.cancelWithQueue.selector, LiquidityHub.cancelWithQueue.selector);
        assertEq(FuzzLiquidityHub.queueForTransferRecipient.selector, LiquidityHub.queueForTransferRecipient.selector);
        assertEq(FuzzLiquidityHub.planCancel.selector, LiquidityHub.planCancel.selector);
        assertEq(FuzzLiquidityHub.planCancelWithQueue.selector, LiquidityHub.planCancelWithQueue.selector);
        assertEq(FuzzLiquidityHub.confirmTake.selector, LiquidityHub.confirmTake.selector);
        assertEq(FuzzLiquidityHub.prepareSettle.selector, LiquidityHub.prepareSettle.selector);
        assertEq(FuzzLiquidityHub.processSettlementFor.selector, LiquidityHub.processSettlementFor.selector);
        assertEq(FuzzLiquidityHub.executePlannedCancel.selector, LiquidityHub.executePlannedCancel.selector);
        assertEq(
            FuzzLiquidityHub.annulSettlementBeforeTransfer.selector, LiquidityHub.annulSettlementBeforeTransfer.selector
        );
    }
}
