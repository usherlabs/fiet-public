// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {LiquidityHubTestBase} from "./base/LiquidityHubTestBase.sol";
import {AbstractBatchProcessSettlement} from "../src/periphery/BatchProcessSettlement.sol";
import {ILCC} from "../src/interfaces/ILCC.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {INativeSettlementReceiver} from "../src/interfaces/INativeSettlementReceiver.sol";

/// @dev Burns far more than `LiquidityHubLib.NATIVE_PUSH_GAS_STIPEND` in `receive()` so the stipended raw ETH push fails and the Hub falls back to WETH (HUB-02C).
contract GasGriefingOptInReceiver is ERC165, INativeSettlementReceiver {
    uint256 private _sink;

    function supportsNativeSettlementFromFiet() external pure override returns (bool) {
        return true;
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(INativeSettlementReceiver).interfaceId || super.supportsInterface(interfaceId);
    }

    receive() external payable {
        for (uint256 i; i < 400; i++) {
            _sink = i;
        }
    }
}

/// @dev Thin wrapper matching destination `BatchProcessSettlement` (reactive) batch entrypoint.
contract BatchProcessSettlementGriefingHarness is AbstractBatchProcessSettlement {
    constructor(address _liquidityHub) AbstractBatchProcessSettlement(_liquidityHub) {}

    function process(address[] memory lcc, address[] memory recipient, uint256[] memory maxAmount) external {
        processSettlements(lcc, recipient, maxAmount);
    }
}

/// @notice E2E coverage for batched settlement resilience to native payout griefing (per-item gas cap + native stipend).
contract BatchProcessSettlementGriefingTest is LiquidityHubTestBase {
    bytes32 internal constant SETTLEMENT_SUCCEEDED_TOPIC = keccak256("SettlementSucceeded(address,address,uint256)");

    struct GriefScenario {
        address lccNative;
        address griefer;
        address honest;
        uint256 amtG;
        uint256 amtH;
        address weth;
        uint256 grieferWethBefore;
        uint256 honestEthBefore;
        BatchProcessSettlementGriefingHarness harness;
    }

    function _setupGriefBatchScenario() internal returns (GriefScenario memory s) {
        address lccErc20;
        vm.startPrank(factory);
        address[] memory issuers = new address[](1);
        issuers[0] = proxyHook;
        (s.lccNative, lccErc20) = liquidityHub.createLCCPair(
            abi.encodePacked(address(0xD29C)),
            address(0),
            address(underlyingAsset1),
            "Native Batch Grief Market",
            issuers
        );
        liquidityHub.initialize(s.lccNative, lccErc20, bytes32("nativeBatchGrief"), abi.encodePacked(address(0xD29C)));
        vm.stopPrank();

        GasGriefingOptInReceiver grieferC = new GasGriefingOptInReceiver();
        s.griefer = address(grieferC);
        s.honest = makeAddr("HONEST_BATCH_EOA");

        s.amtG = 5;
        s.amtH = 7;
        uint256 total = s.amtG + s.amtH;

        vm.prank(proxyHook);
        liquidityHub.issue(s.lccNative, proxyHook, total);
        vm.prank(proxyHook);
        ILCC(s.lccNative).transfer(s.griefer, s.amtG);
        vm.prank(proxyHook);
        ILCC(s.lccNative).transfer(s.honest, s.amtH);

        vm.prank(proxyHook);
        liquidityHub.queueForTransferRecipient(s.lccNative, s.griefer, s.amtG);
        vm.prank(proxyHook);
        liquidityHub.queueForTransferRecipient(s.lccNative, s.honest, s.amtH);

        vm.deal(address(liquidityHub), total);
        vm.prank(proxyHook);
        liquidityHub.confirmTake(s.lccNative, total, false);

        s.harness = new BatchProcessSettlementGriefingHarness(address(liquidityHub));
        s.weth = address(liquidityHub.weth9());
        s.grieferWethBefore = IERC20(s.weth).balanceOf(s.griefer);
        s.honestEthBefore = s.honest.balance;
    }

    /// @notice Two queued native settlements in one batch: first recipient is an opt-in contract whose `receive()` tries
    ///         to burn unbounded gas; second is an EOA. Without per-item batch gas limits and without a native push stipend
    ///         for contracts, the first payout could exhaust the outer transaction and prevent the second settlement.
    function test_e2e_batch_nativeGasGriefingRecipient_doesNotStarveSecondSettlement() public {
        GriefScenario memory s = _setupGriefBatchScenario();

        address[] memory lccs = new address[](2);
        lccs[0] = s.lccNative;
        lccs[1] = s.lccNative;
        address[] memory recipients = new address[](2);
        recipients[0] = s.griefer;
        recipients[1] = s.honest;
        uint256[] memory maxAmounts = new uint256[](2);
        maxAmounts[0] = type(uint256).max;
        maxAmounts[1] = type(uint256).max;

        vm.recordLogs();
        s.harness.process(lccs, recipients, maxAmounts);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 successEvents;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == SETTLEMENT_SUCCEEDED_TOPIC) {
                successEvents++;
            }
        }
        assertEq(successEvents, 2, "expected two per-item successes");

        assertEq(liquidityHub.settleQueue(s.lccNative, s.griefer), 0);
        assertEq(liquidityHub.settleQueue(s.lccNative, s.honest), 0);
        assertEq(ILCC(s.lccNative).balanceOf(s.griefer), 0);
        assertEq(ILCC(s.lccNative).balanceOf(s.honest), 0);

        assertEq(IERC20(s.weth).balanceOf(s.griefer) - s.grieferWethBefore, s.amtG);
        assertEq(s.honest.balance - s.honestEthBefore, s.amtH);
    }
}
