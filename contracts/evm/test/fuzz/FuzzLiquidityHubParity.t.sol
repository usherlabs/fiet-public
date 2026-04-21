// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {LiquidityHub} from "../../src/LiquidityHub.sol";
import {FuzzLiquidityHub} from "./harnesses/FuzzLiquidityHub.sol";
import {IEndpointUnwrapAdmission} from "../../src/interfaces/IEndpointUnwrapAdmission.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {Bounds} from "../../src/libraries/Bounds.sol";
import {MockOracleHelper} from "./mocks/MockOracleHelper.sol";
import {MockERC20Transferable} from "./mocks/MockERC20Transferable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
        assertEq(FuzzLiquidityHub.settleFromCustodian.selector, LiquidityHub.settleFromCustodian.selector);
        assertEq(FuzzLiquidityHub.executePlannedCancel.selector, LiquidityHub.executePlannedCancel.selector);
        assertEq(
            FuzzLiquidityHub.annulSettlementBeforeTransfer.selector, LiquidityHub.annulSettlementBeforeTransfer.selector
        );
    }

    /// @dev Mirror of the production Hub regression: endpoint-reported admission credit is capped by the queue and
    ///      restores the same unwrap headroom in the fuzz adapter.
    function test_unwrapTo_endpointAdmissionCredit_inflatedReportedCredit_stillAllowsUnwrapUpToLiveBalance() public {
        uint256 queuedAmt = 15;
        uint256 endpointBalance = 10;
        uint256 unwrapAmt = 5;

        _createSettlementQueueEntry(address(0xBEEF), queuedAmt);

        FuzzEndpointUnwrapAdmission endpoint = new FuzzEndpointUnwrapAdmission();
        hub.issue(lcc0, address(endpoint), endpointBalance);
        hub.setBoundLevel(address(endpoint), Bounds.BOUND_ENDPOINT);
        endpoint.setAdmissionCredit(type(uint256).max);

        underlying0.mint(address(hub), unwrapAmt);
        hub.confirmTake(lcc0, unwrapAmt, false);
        mockedUsedMarketLiquidity = unwrapAmt;

        uint256 toBefore = underlying0.balanceOf(address(0xCAFE));
        vm.prank(address(endpoint));
        endpoint.callUnwrapTo(hub, lcc0, address(0xCAFE), address(0xBEEF), unwrapAmt);

        assertEq(underlying0.balanceOf(address(0xCAFE)) - toBefore, unwrapAmt);
        assertEq(IERC20(lcc0).balanceOf(address(endpoint)), endpointBalance - unwrapAmt);
    }

    function test_unwrapTo_endpointAdmissionCredit_zeroCredit_revertsWhenLiveBalanceBelowQueue() public {
        uint256 queuedAmt = 15;
        uint256 endpointBalance = 10;

        _createSettlementQueueEntry(address(0xBEEF), queuedAmt);

        FuzzEndpointUnwrapAdmission endpoint = new FuzzEndpointUnwrapAdmission();
        hub.issue(lcc0, address(endpoint), endpointBalance);
        hub.setBoundLevel(address(endpoint), Bounds.BOUND_ENDPOINT);
        endpoint.setAdmissionCredit(0);

        vm.prank(address(endpoint));
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector, uint256(5), uint256(0)));
        endpoint.callUnwrapTo(hub, lcc0, address(0xCAFE), address(0xBEEF), 5);
    }

    function test_unwrapTo_endpointAdmissionCredit_staticcallNoInterface_zeroCredit_revertsWhenLiveBalanceBelowQueue()
        public
    {
        uint256 queuedAmt = 15;
        uint256 endpointBalance = 10;

        _createSettlementQueueEntry(address(0xBEEF), queuedAmt);

        FuzzEndpointCallerSansAdmission endpoint = new FuzzEndpointCallerSansAdmission();
        hub.issue(lcc0, address(endpoint), endpointBalance);
        hub.setBoundLevel(address(endpoint), Bounds.BOUND_ENDPOINT);

        vm.prank(address(endpoint));
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector, uint256(1), uint256(0)));
        endpoint.callUnwrapTo(hub, lcc0, address(0xCAFE), address(0xBEEF), 1);
    }
}

contract FuzzEndpointUnwrapAdmission is IEndpointUnwrapAdmission {
    uint256 private _admissionCredit;

    function setAdmissionCredit(uint256 credit) external {
        _admissionCredit = credit;
    }

    function unwrapAdmissionCredit(address, address) external view returns (uint256) {
        return _admissionCredit;
    }

    function callUnwrapTo(FuzzLiquidityHub target, address lcc, address to, address queueTo, uint256 amount) external {
        target.unwrapTo(lcc, to, queueTo, amount);
    }
}

contract FuzzEndpointCallerSansAdmission {
    function callUnwrapTo(FuzzLiquidityHub target, address lcc, address to, address queueTo, uint256 amount) external {
        target.unwrapTo(lcc, to, queueTo, amount);
    }
}
