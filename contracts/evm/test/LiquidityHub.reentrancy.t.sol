// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {LiquidityHubTestBase} from "./base/LiquidityHubTestBase.sol";
import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";
import {LiquidityHub} from "../src/LiquidityHub.sol";
import {ILCC} from "../src/interfaces/ILCC.sol";
import {MockERC20} from "./_mocks/MockERC20.sol";
import {CustomRevert} from "v4-periphery/lib/v4-core/src/libraries/CustomRevert.sol";

/**
 * @dev Minimal malicious ERC20 that attempts to re-enter into the hub during:
 * - transferFrom (when wrapping / pulling underlying)
 * - transfer (when unwrapping / paying underlying)
 * - approve (when prepareSettle approves)
 */
contract ReentrantERC20 is MockERC20 {
    address public hub;
    address public lcc;
    bool internal reenterOnTransferFrom;
    bool internal reenterOnTransfer;
    bool internal reenterOnApprove;

    constructor(string memory name, string memory symbol, uint8 decimals_) MockERC20(name, symbol, decimals_) {}

    function configure(address hub_, address lcc_) external {
        hub = hub_;
        lcc = lcc_;
    }

    function armTransferFromReentry(uint256 amountToMintAndApprove) external {
        _mint(address(this), amountToMintAndApprove);
        _approve(address(this), hub, amountToMintAndApprove);
        reenterOnTransferFrom = true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool ok = super.transferFrom(from, to, amount);
        if (reenterOnTransferFrom) {
            reenterOnTransferFrom = false;
            LiquidityHub(payable(hub)).wrap(lcc, 1);
        }
        return ok;
    }

    function armTransferReentry(uint256 amountToMintAndApprove) external {
        _mint(address(this), amountToMintAndApprove);
        _approve(address(this), hub, amountToMintAndApprove);
        reenterOnTransfer = true;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool ok = super.transfer(to, amount);
        if (reenterOnTransfer) {
            reenterOnTransfer = false;
            LiquidityHub(payable(hub)).wrap(lcc, 1);
        }
        return ok;
    }

    function armApproveReentry(uint256 amountToMintAndApprove) external {
        _mint(address(this), amountToMintAndApprove);
        _approve(address(this), hub, amountToMintAndApprove);
        reenterOnApprove = true;
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        bool ok = super.approve(spender, amount);
        if (reenterOnApprove) {
            reenterOnApprove = false;
            LiquidityHub(payable(hub)).wrap(lcc, 1);
        }
        return ok;
    }
}

contract LiquidityHubReentrancyTest is LiquidityHubTestBase {
    function _assertWrappedError(bytes memory revertData) internal pure {
        require(revertData.length >= 4, "missing revert selector");
        bytes4 sel;
        assembly ("memory-safe") {
            sel := mload(add(revertData, 0x20))
        }
        assertEq(sel, CustomRevert.WrappedError.selector, "expected WrappedError selector");
    }

    function _unwrapSelector() internal pure returns (bytes4) {
        return bytes4(keccak256("unwrap(address,uint256)"));
    }

    function _unwrapByUnderlyingSelector() internal pure returns (bytes4) {
        return bytes4(keccak256("unwrap(address,bytes32,uint256)"));
    }

    function _unwrapToSelector() internal pure returns (bytes4) {
        return bytes4(keccak256("unwrapTo(address,address,uint256)"));
    }

    function _unwrapToByUnderlyingSelector() internal pure returns (bytes4) {
        return bytes4(keccak256("unwrapTo(address,bytes32,address,uint256)"));
    }

    function test_wrapTo_revertsOnReentrancyAttempt() public {
        // Create a market where token0 underlying is malicious and attempts to re-enter.
        ReentrantERC20 evil = new ReentrantERC20("Evil", "EVL", 18);

        vm.startPrank(factory);
        address[] memory issuers = new address[](1);
        issuers[0] = factory;
        (address evilLcc, address otherLcc) = liquidityHub.createLCCPair(
            abi.encodePacked(address(0xE11)), address(evil), address(underlyingAsset2), "EvilM", issuers
        );
        liquidityHub.initialize(evilLcc, otherLcc, bytes32("evilMarket"), abi.encodePacked(address(0xE11)));
        vm.stopPrank();

        evil.configure(address(liquidityHub), evilLcc);

        // Fund user1 and arm the malicious token to attempt a re-entrant call.
        uint256 amount = 5;
        evil.mint(user1, amount);
        evil.armTransferFromReentry(1);

        vm.startPrank(user1);
        evil.approve(address(liquidityHub), amount);
        // The inner call reverts, but the outer pull uses safeTransferFrom2 (Permit2 fallback) which wraps failures.
        vm.expectRevert(abi.encodeWithSignature("TransferFromFailed()"));
        liquidityHub.wrapTo(evilLcc, user2, amount);
        vm.stopPrank();
    }

    function test_wrap_revertsOnReentrancyAttempt() public {
        ReentrantERC20 evil = new ReentrantERC20("Evil", "EVL", 18);

        vm.startPrank(factory);
        address[] memory issuers = new address[](1);
        issuers[0] = factory;
        (address evilLcc, address otherLcc) = liquidityHub.createLCCPair(
            abi.encodePacked(address(0xE12)), address(evil), address(underlyingAsset2), "EvilM2", issuers
        );
        liquidityHub.initialize(evilLcc, otherLcc, bytes32("evilMarket2"), abi.encodePacked(address(0xE12)));
        vm.stopPrank();

        evil.configure(address(liquidityHub), evilLcc);

        uint256 amount = 5;
        evil.mint(user1, amount);
        evil.armTransferFromReentry(1);

        vm.startPrank(user1);
        evil.approve(address(liquidityHub), amount);
        vm.expectRevert(abi.encodeWithSignature("TransferFromFailed()"));
        liquidityHub.wrap(evilLcc, amount);
        vm.stopPrank();
    }

    function test_wrapTo_overloadByUnderlyingMarketId_revertsOnReentrancyAttempt() public {
        ReentrantERC20 evil = new ReentrantERC20("Evil", "EVL", 18);
        bytes32 marketId = bytes32("evilMarket3");

        vm.startPrank(factory);
        address[] memory issuers = new address[](1);
        issuers[0] = factory;
        (address evilLcc, address otherLcc) = liquidityHub.createLCCPair(
            abi.encodePacked(address(0xE13)), address(evil), address(underlyingAsset2), "EvilM3", issuers
        );
        liquidityHub.initialize(evilLcc, otherLcc, marketId, abi.encodePacked(address(0xE13)));
        vm.stopPrank();

        evil.configure(address(liquidityHub), evilLcc);

        uint256 amount = 5;
        evil.mint(user1, amount);
        evil.armTransferFromReentry(1);

        vm.startPrank(user1);
        evil.approve(address(liquidityHub), amount);
        vm.expectRevert(abi.encodeWithSignature("TransferFromFailed()"));
        liquidityHub.wrapTo(address(evil), marketId, user2, amount);
        vm.stopPrank();
    }

    function test_wrap_overloadByUnderlyingMarketId_revertsOnReentrancyAttempt() public {
        ReentrantERC20 evil = new ReentrantERC20("Evil", "EVL", 18);
        bytes32 marketId = bytes32("evilMarket4");

        vm.startPrank(factory);
        address[] memory issuers = new address[](1);
        issuers[0] = factory;
        (address evilLcc, address otherLcc) = liquidityHub.createLCCPair(
            abi.encodePacked(address(0xE14)), address(evil), address(underlyingAsset2), "EvilM4", issuers
        );
        liquidityHub.initialize(evilLcc, otherLcc, marketId, abi.encodePacked(address(0xE14)));
        vm.stopPrank();

        evil.configure(address(liquidityHub), evilLcc);

        uint256 amount = 5;
        evil.mint(user1, amount);
        evil.armTransferFromReentry(1);

        vm.startPrank(user1);
        evil.approve(address(liquidityHub), amount);
        vm.expectRevert(abi.encodeWithSignature("TransferFromFailed()"));
        liquidityHub.wrap(address(evil), marketId, amount);
        vm.stopPrank();
    }

    function test_unwrap_revertsOnReentrancyAttempt() public {
        ReentrantERC20 evil = new ReentrantERC20("Evil", "EVL", 18);

        vm.startPrank(factory);
        address[] memory issuers = new address[](1);
        issuers[0] = factory;
        (address evilLcc, address otherLcc) = liquidityHub.createLCCPair(
            abi.encodePacked(address(0xE15)), address(evil), address(underlyingAsset2), "EvilM5", issuers
        );
        liquidityHub.initialize(evilLcc, otherLcc, bytes32("evilMarket5"), abi.encodePacked(address(0xE15)));
        vm.stopPrank();

        evil.configure(address(liquidityHub), evilLcc);

        uint256 amount = 5;
        evil.mint(user1, amount);
        vm.startPrank(user1);
        evil.approve(address(liquidityHub), amount);
        liquidityHub.wrap(evilLcc, amount);
        vm.stopPrank();

        evil.armTransferReentry(1);

        vm.prank(user1);
        (bool ok, bytes memory data) =
            address(liquidityHub).call(abi.encodeWithSelector(_unwrapSelector(), evilLcc, amount));
        assertFalse(ok);
        _assertWrappedError(data);
    }

    function test_unwrap_overloadByUnderlyingMarketId_revertsOnReentrancyAttempt() public {
        ReentrantERC20 evil = new ReentrantERC20("Evil", "EVL", 18);
        bytes32 marketId = bytes32("evilMarket6");

        vm.startPrank(factory);
        address[] memory issuers = new address[](1);
        issuers[0] = factory;
        (address evilLcc, address otherLcc) = liquidityHub.createLCCPair(
            abi.encodePacked(address(0xE16)), address(evil), address(underlyingAsset2), "EvilM6", issuers
        );
        liquidityHub.initialize(evilLcc, otherLcc, marketId, abi.encodePacked(address(0xE16)));
        vm.stopPrank();

        evil.configure(address(liquidityHub), evilLcc);

        uint256 amount = 5;
        evil.mint(user1, amount);
        vm.startPrank(user1);
        evil.approve(address(liquidityHub), amount);
        liquidityHub.wrap(address(evil), marketId, amount);
        vm.stopPrank();

        evil.armTransferReentry(1);

        vm.prank(user1);
        (bool ok, bytes memory data) = address(liquidityHub)
            .call(abi.encodeWithSelector(_unwrapByUnderlyingSelector(), address(evil), marketId, amount));
        assertFalse(ok);
        _assertWrappedError(data);
    }

    function test_unwrapTo_revertsOnReentrancyAttempt() public {
        ReentrantERC20 evil = new ReentrantERC20("Evil", "EVL", 18);

        vm.startPrank(factory);
        address[] memory issuers = new address[](1);
        issuers[0] = factory;
        (address evilLcc, address otherLcc) = liquidityHub.createLCCPair(
            abi.encodePacked(address(0xE17)), address(evil), address(underlyingAsset2), "EvilM7", issuers
        );
        liquidityHub.initialize(evilLcc, otherLcc, bytes32("evilMarket7"), abi.encodePacked(address(0xE17)));
        vm.stopPrank();

        evil.configure(address(liquidityHub), evilLcc);

        uint256 amount = 5;
        evil.mint(user1, amount);
        vm.startPrank(user1);
        evil.approve(address(liquidityHub), amount);
        liquidityHub.wrap(evilLcc, amount);
        vm.stopPrank();

        evil.armTransferReentry(1);

        vm.prank(user1);
        (bool ok, bytes memory data) =
            address(liquidityHub).call(abi.encodeWithSelector(_unwrapToSelector(), evilLcc, user2, amount));
        assertFalse(ok);
        _assertWrappedError(data);
    }

    function test_unwrapTo_overloadByUnderlyingMarketId_revertsOnReentrancyAttempt() public {
        ReentrantERC20 evil = new ReentrantERC20("Evil", "EVL", 18);
        bytes32 marketId = bytes32("evilMarket8");

        vm.startPrank(factory);
        address[] memory issuers = new address[](1);
        issuers[0] = factory;
        (address evilLcc, address otherLcc) = liquidityHub.createLCCPair(
            abi.encodePacked(address(0xE18)), address(evil), address(underlyingAsset2), "EvilM8", issuers
        );
        liquidityHub.initialize(evilLcc, otherLcc, marketId, abi.encodePacked(address(0xE18)));
        vm.stopPrank();

        evil.configure(address(liquidityHub), evilLcc);

        uint256 amount = 5;
        evil.mint(user1, amount);
        vm.startPrank(user1);
        evil.approve(address(liquidityHub), amount);
        liquidityHub.wrap(address(evil), marketId, amount);
        vm.stopPrank();

        evil.armTransferReentry(1);

        vm.prank(user1);
        (bool ok, bytes memory data) = address(liquidityHub)
            .call(abi.encodeWithSelector(_unwrapToByUnderlyingSelector(), address(evil), marketId, user2, amount));
        assertFalse(ok);
        _assertWrappedError(data);
    }

    function test_prepareSettle_revertsOnReentrancyAttempt() public {
        ReentrantERC20 evil = new ReentrantERC20("Evil", "EVL", 18);

        vm.startPrank(factory);
        address[] memory issuers = new address[](1);
        issuers[0] = factory;
        (address evilLcc, address otherLcc) = liquidityHub.createLCCPair(
            abi.encodePacked(address(0xE19)), address(evil), address(underlyingAsset2), "EvilM9", issuers
        );
        liquidityHub.initialize(evilLcc, otherLcc, bytes32("evilMarket9"), abi.encodePacked(address(0xE19)));
        vm.stopPrank();

        evil.configure(address(liquidityHub), evilLcc);

        // Seed some reserve: wrap without arming.
        uint256 amount = 5;
        evil.mint(user1, amount);
        vm.startPrank(user1);
        evil.approve(address(liquidityHub), amount);
        liquidityHub.wrap(evilLcc, amount);
        vm.stopPrank();

        // Arm reentry on approve (prepareSettle approves the caller to pull funds).
        evil.armApproveReentry(1);

        vm.prank(factory);
        vm.expectRevert(abi.encodeWithSignature("ApproveFailed()"));
        liquidityHub.prepareSettle(evilLcc, 1);
    }

    function test_processSettlementFor_revertsOnReentrancyAttempt() public {
        ReentrantERC20 evil = new ReentrantERC20("Evil", "EVL", 18);

        vm.startPrank(factory);
        address[] memory issuers = new address[](1);
        issuers[0] = factory;
        (address evilLcc, address otherLcc) = liquidityHub.createLCCPair(
            abi.encodePacked(address(0xE20)), address(evil), address(underlyingAsset2), "EvilM10", issuers
        );
        liquidityHub.initialize(evilLcc, otherLcc, bytes32("evilMarket10"), abi.encodePacked(address(0xE20)));
        vm.stopPrank();

        evil.configure(address(liquidityHub), evilLcc);

        uint256 queued = 5;
        _createSettlementQueueEntry(evilLcc, user1, queued);

        // Provide reserve so settlement attempts to pay underlying to user.
        evil.mint(address(liquidityHub), queued);
        vm.prank(factory);
        liquidityHub.confirmTake(evilLcc, queued, false);

        evil.armTransferReentry(1);

        (bool ok, bytes memory data) = address(liquidityHub)
            .call(abi.encodeWithSelector(liquidityHub.processSettlementFor.selector, evilLcc, user1, queued));
        assertFalse(ok);
        _assertWrappedError(data);
    }
}

