// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {LiquidityHubTestBase} from "./base/LiquidityHubTestBase.sol";
import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";
import {LiquidityHub} from "../src/LiquidityHub.sol";
import {ILCC} from "../src/interfaces/ILCC.sol";
import {MockERC20} from "./_mocks/MockERC20.sol";
import {Errors} from "../src/libraries/Errors.sol";
import {CustomRevert} from "v4-periphery/lib/v4-core/src/libraries/CustomRevert.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

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

/**
 * @dev Minimal malicious LCC admin that attempts to re-enter issuer-only functions during mint/burn.
 */
contract ReentrantLccAdmin {
    enum ReentryKind {
        None,
        Issue,
        Cancel,
        CancelWithQueue,
        PlanCancel,
        PlanCancelWithQueue
    }

    address public hub;
    address public lcc;
    ReentryKind internal reentry;

    function configure(address hub_, address lcc_) external {
        hub = hub_;
        lcc = lcc_;
    }

    function armIssueReentry() external {
        reentry = ReentryKind.Issue;
    }

    function armCancelReentry() external {
        reentry = ReentryKind.Cancel;
    }

    function armCancelWithQueueReentry() external {
        reentry = ReentryKind.CancelWithQueue;
    }

    function armPlanCancelReentry() external {
        reentry = ReentryKind.PlanCancel;
    }

    function armPlanCancelWithQueueReentry() external {
        reentry = ReentryKind.PlanCancelWithQueue;
    }

    function mint(address, uint256, uint256) external {
        if (reentry == ReentryKind.Issue) {
            reentry = ReentryKind.None;
            LiquidityHub(payable(hub)).issue(lcc, address(this), 1);
        } else if (reentry == ReentryKind.PlanCancel) {
            reentry = ReentryKind.None;
            LiquidityHub(payable(hub)).planCancel(lcc, address(this), address(this), 1);
        } else if (reentry == ReentryKind.PlanCancelWithQueue) {
            reentry = ReentryKind.None;
            LiquidityHub(payable(hub)).planCancelWithQueue(lcc, address(this), address(this), 1, 1, address(this));
        }
    }

    function burn(address, uint256, uint256) external {
        if (reentry == ReentryKind.Cancel) {
            reentry = ReentryKind.None;
            LiquidityHub(payable(hub)).cancel(lcc, address(this), 1);
        } else if (reentry == ReentryKind.CancelWithQueue) {
            reentry = ReentryKind.None;
            LiquidityHub(payable(hub)).cancelWithQueue(lcc, address(this), 1, 1, address(this));
        }
    }
}

/**
 * @dev Malicious "factory" used to trigger a re-entrant call from inside `useMarketLiquidity`, which is the only
 *      practical hook point to test `nonReentrant` on wrapWith/wrapWithTo (since those don't call underlying ERC20s).
 */
contract ReentrantMarketFactory {
    address public immutable hub;
    address public immutable oracleHelper;

    uint8 internal constant BOUND_NONE = 0;
    uint8 internal constant BOUND_ENDPOINT = 1;
    uint8 internal constant BOUND_EXEMPT = 2;

    bool internal armed;
    address internal lccToReenter;

    constructor(address hub_, address oracleHelper_) {
        hub = hub_;
        oracleHelper = oracleHelper_;
    }

    function setBound(address who, bool isBound) external {
        // Using BOUND_EXEMPT here is OK - as this unit test is dedicated to testing reentrancy.
        LiquidityHub(payable(hub)).setBoundLevel(who, isBound ? BOUND_EXEMPT : BOUND_NONE);
    }

    function armReenterOnUseMarketLiquidity(address lcc_) external {
        armed = true;
        lccToReenter = lcc_;
    }

    // -------- Functions called by LiquidityHub / LCC --------

    function marketLiquidity(address, bytes32) external pure returns (uint256) {
        return 0;
    }

    function useMarketLiquidity(address, bytes32, uint256) external returns (uint256) {
        if (armed) {
            armed = false;
            // Intentionally attempt to fabricate reserves via a re-entrant `confirmTake`.
            // Production flows allow vault -> hub `confirmTake` callbacks without `nonReentrant`,
            // but `confirmTake` must remain balance-backed and revert if unbacked.
            LiquidityHub(payable(hub)).confirmTake(lccToReenter, 1, false);
        }
        return 0;
    }
}

contract LiquidityHubReentrancyTest is LiquidityHubTestBase {
    using stdStorage for StdStorage;

    StdStorage internal _store;

    function _configureReentrantLcc(address lcc) internal returns (ReentrantLccAdmin evil) {
        ReentrantLccAdmin impl = new ReentrantLccAdmin();
        vm.etch(lcc, address(impl).code);
        evil = ReentrantLccAdmin(lcc);
        evil.configure(address(liquidityHub), lcc);
        _store.target(address(liquidityHub)).sig("issuers(address,address)").with_key(lcc).with_key(lcc)
            .checked_write(true);
    }

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

    function _unwrapToWithQueueSelector() internal pure returns (bytes4) {
        return bytes4(keccak256("unwrapTo(address,address,address,uint256)"));
    }

    function _unwrapToWithQueueByUnderlyingSelector() internal pure returns (bytes4) {
        return bytes4(keccak256("unwrapTo(address,bytes32,address,address,uint256)"));
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

    function test_unwrapTo_withQueueTo_revertsOnReentrancyAttempt() public {
        ReentrantERC20 evil = new ReentrantERC20("Evil", "EVL", 18);

        vm.startPrank(factory);
        address[] memory issuers = new address[](1);
        issuers[0] = factory;
        (address evilLcc, address otherLcc) = liquidityHub.createLCCPair(
            abi.encodePacked(address(0xE21)), address(evil), address(underlyingAsset2), "EvilM11", issuers
        );
        liquidityHub.initialize(evilLcc, otherLcc, bytes32("evilMarket11"), abi.encodePacked(address(0xE21)));
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
        (bool ok, bytes memory data) = address(liquidityHub)
            .call(abi.encodeWithSelector(_unwrapToWithQueueSelector(), evilLcc, user2, user3, amount));
        assertFalse(ok);
        _assertWrappedError(data);
    }

    function test_unwrapTo_withQueueTo_overloadByUnderlyingMarketId_revertsOnReentrancyAttempt() public {
        ReentrantERC20 evil = new ReentrantERC20("Evil", "EVL", 18);
        bytes32 marketId = bytes32("evilMarket12");

        vm.startPrank(factory);
        address[] memory issuers = new address[](1);
        issuers[0] = factory;
        (address evilLcc, address otherLcc) = liquidityHub.createLCCPair(
            abi.encodePacked(address(0xE22)), address(evil), address(underlyingAsset2), "EvilM12", issuers
        );
        liquidityHub.initialize(evilLcc, otherLcc, marketId, abi.encodePacked(address(0xE22)));
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
            .call(
                abi.encodeWithSelector(
                    _unwrapToWithQueueByUnderlyingSelector(), address(evil), marketId, user2, user3, amount
                )
            );
        assertFalse(ok);
        _assertWrappedError(data);
    }

    function test_wrapWith_revertsOnReentrancyAttempt_viaMarketFactory() public {
        // Create markets under a malicious factory and ensure wrapWith hits `useMarketLiquidity`,
        // which re-enters into the hub during the outer nonReentrant call.
        ReentrantMarketFactory mf = new ReentrantMarketFactory(address(liquidityHub), address(oracleHelper));
        liquidityHub.setFactory(address(mf), true);
        mf.setBound(address(mf), true); // protocol-bound sender so transfers to users create market-derived balance
        mf.setBound(address(liquidityHub), true); // allow user -> hub transferFrom of LCC during wrapWith

        address[] memory issuers = new address[](1);
        issuers[0] = address(mf);

        // Market A
        vm.startPrank(address(mf));
        (address lccA0, address lccA1) = liquidityHub.createLCCPair(
            abi.encodePacked(address(0xE30)), address(underlyingAsset1), address(underlyingAsset2), "MF-A", issuers
        );
        liquidityHub.initialize(lccA0, lccA1, bytes32("mfA"), abi.encodePacked(address(0xE30)));
        vm.stopPrank();

        // Market B (same underlying assets so wrapWith is allowed)
        vm.startPrank(address(mf));
        (address lccB0, address lccB1) = liquidityHub.createLCCPair(
            abi.encodePacked(address(0xE31)), address(underlyingAsset1), address(underlyingAsset2), "MF-B", issuers
        );
        liquidityHub.initialize(lccB0, lccB1, bytes32("mfB"), abi.encodePacked(address(0xE31)));
        vm.stopPrank();

        // Give user1 market-derived balance in withLCC = lccB0 by transferring from protocol-bound factory.
        uint256 amount = 5;
        _wrapDirectLCC(address(mf), lccB0, amount);
        vm.prank(address(mf));
        ILCC(lccB0).transfer(user1, amount);

        // Arm re-entry when wrapWith tries to use market liquidity (it will request it for market-derived portion).
        mf.armReenterOnUseMarketLiquidity(lccB0);

        vm.startPrank(user1);
        ILCC(lccB0).approve(address(liquidityHub), amount);
        // `confirmTake` is intentionally callable during nested flows, but it must be balance-backed.
        // This malicious factory attempts an unbacked `confirmTake`, which must revert.
        vm.expectRevert(abi.encodeWithSelector(Errors.InsufficientBalance.selector, 5, 6));
        liquidityHub.wrapWith(lccA0, lccB0, amount);
        vm.stopPrank();
    }

    function test_wrapWithTo_revertsOnReentrancyAttempt_viaMarketFactory() public {
        ReentrantMarketFactory mf = new ReentrantMarketFactory(address(liquidityHub), address(oracleHelper));
        liquidityHub.setFactory(address(mf), true);
        mf.setBound(address(mf), true);
        mf.setBound(address(liquidityHub), true);

        address[] memory issuers = new address[](1);
        issuers[0] = address(mf);

        vm.startPrank(address(mf));
        (address lccA0, address lccA1) = liquidityHub.createLCCPair(
            abi.encodePacked(address(0xE32)), address(underlyingAsset1), address(underlyingAsset2), "MF-A2", issuers
        );
        liquidityHub.initialize(lccA0, lccA1, bytes32("mfA2"), abi.encodePacked(address(0xE32)));
        vm.stopPrank();

        vm.startPrank(address(mf));
        (address lccB0, address lccB1) = liquidityHub.createLCCPair(
            abi.encodePacked(address(0xE33)), address(underlyingAsset1), address(underlyingAsset2), "MF-B2", issuers
        );
        liquidityHub.initialize(lccB0, lccB1, bytes32("mfB2"), abi.encodePacked(address(0xE33)));
        vm.stopPrank();

        uint256 amount = 5;
        _wrapDirectLCC(address(mf), lccB0, amount);
        vm.prank(address(mf));
        ILCC(lccB0).transfer(user1, amount);

        mf.armReenterOnUseMarketLiquidity(lccB0);

        vm.startPrank(user1);
        ILCC(lccB0).approve(address(liquidityHub), amount);
        vm.expectRevert(abi.encodeWithSelector(Errors.InsufficientBalance.selector, 5, 6));
        liquidityHub.wrapWithTo(lccA0, lccB0, user2, amount);
        vm.stopPrank();
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

    function test_issue_revertsOnReentrancyAttempt_viaLccMint() public {
        address lcc = lccToken1;
        ReentrantLccAdmin evil = _configureReentrantLcc(lcc);
        evil.armIssueReentry();

        vm.prank(vtsOrchestrator);
        vm.expectRevert(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        liquidityHub.issue(lcc, user1, 1);
    }

    function test_cancel_revertsOnReentrancyAttempt_viaLccBurn() public {
        address lcc = lccToken1;
        ReentrantLccAdmin evil = _configureReentrantLcc(lcc);
        evil.armCancelReentry();

        vm.prank(vtsOrchestrator);
        vm.expectRevert(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        liquidityHub.cancel(lcc, user1, 1);
    }

    function test_cancelWithQueue_revertsOnReentrancyAttempt_viaLccBurn() public {
        address lcc = lccToken1;
        ReentrantLccAdmin evil = _configureReentrantLcc(lcc);
        evil.armCancelWithQueueReentry();

        vm.prank(vtsOrchestrator);
        vm.expectRevert(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        liquidityHub.cancelWithQueue(lcc, user1, 2, 1, user2);
    }

    function test_planCancel_revertsOnReentrancyAttempt_viaLccMint() public {
        address lcc = lccToken1;
        ReentrantLccAdmin evil = _configureReentrantLcc(lcc);
        evil.armPlanCancelReentry();

        vm.prank(vtsOrchestrator);
        vm.expectRevert(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        liquidityHub.issue(lcc, user1, 1);
    }

    function test_planCancelWithQueue_revertsOnReentrancyAttempt_viaLccMint() public {
        address lcc = lccToken1;
        ReentrantLccAdmin evil = _configureReentrantLcc(lcc);
        evil.armPlanCancelWithQueueReentry();

        vm.prank(vtsOrchestrator);
        vm.expectRevert(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        liquidityHub.issue(lcc, user1, 1);
    }
}

