// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {VTSAdmin} from "../../src/modules/VTSAdmin.sol";
import {IVTSAdmin} from "../../src/interfaces/IVTSAdmin.sol";
import {IVRLSignalManager} from "../../src/interfaces/IVRLSignalManager.sol";
import {IVRLSettlementObserver} from "../../src/interfaces/IVRLSettlementObserver.sol";
import {VTSStorage, MarketVTSConfiguration} from "../../src/types/VTS.sol";
import {VTSConfigs} from "../../src/libraries/VTSConfigs.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {PositionId} from "../../src/types/Position.sol";

contract MockSignalManagerForAdmin is IVRLSignalManager {
    address public immutable override submitter;

    constructor(address _submitter) {
        submitter = _submitter;
    }

    function getVerifier() external pure returns (address) {
        return address(0);
    }

    function mmNonce(address) external pure returns (uint256) {
        return 0;
    }

    function submitAuthNonce(address) external pure returns (uint256) {
        return 0;
    }

    function setVerifier(address) external {}

    function verifyLiquiditySignal(address, bytes memory, bool) external pure returns (bool, uint256) {
        return (false, 0);
    }

    function verifyLiquiditySignalRelayed(address, uint256, bytes memory, uint256, uint256, bytes memory, bool)
        external
        pure
        returns (bool, uint256)
    {
        return (false, 0);
    }
}

    contract MockSettlementObserverForAdmin is IVRLSettlementObserver {
        address public immutable override submitter;

        constructor(address _submitter) {
            submitter = _submitter;
        }

        function addVerifier(address) external pure returns (uint32) {
            return 0;
        }

        function nullifyVerifier(uint32) external {}

        function allowVerifierForTokens(uint32, address[] memory) external {}

        function disallowVerifierForTokens(uint32, address[] memory) external {}

        function verifySettlementProof(PoolKey memory, uint8, uint32, PositionId, bytes memory, bool)
            external
            pure
            returns (bool isProofValid)
        {
            return false;
        }
    }

        contract VTSAdminHarness is VTSAdmin {
            address internal _owner;
            VTSStorage internal _s;

            constructor(address owner_) {
                _owner = owner_;
            }

            function _checkOwner() internal view override {
                if (msg.sender != _owner) revert Errors.InvalidSender();
            }

            function _vtsStorage() internal view override returns (VTSStorage storage) {
                return _s;
            }

            function _assertValidMarketVTSConfiguration(MarketVTSConfiguration memory cfg) internal pure override {
                if (cfg.token0.maxGracePeriodTime < cfg.token0.gracePeriodTime) {
                    revert Errors.InvalidVTSConfiguration(cfg.token0.gracePeriodTime, cfg.token0.maxGracePeriodTime);
                }
            }

            function exposeOnlyIfVRLHandlersRegistered() external view {
                _onlyIfVRLHandlersRegistered();
            }

            function getConfig(PoolId poolId) external view returns (MarketVTSConfiguration memory) {
                return _s.pools[poolId].vtsConfig;
            }
        }

        contract VTSAdminTest is Test {
            VTSAdminHarness internal harness;
            address internal owner = makeAddr("owner");
            address internal attacker = makeAddr("attacker");
            PoolId internal constant POOL_ID = PoolId.wrap(bytes32(uint256(123)));

            function setUp() public {
                harness = new VTSAdminHarness(owner);
            }

            function _register(address signalSubmitter, address settlementSubmitter) internal {
                MockSignalManagerForAdmin signal = new MockSignalManagerForAdmin(signalSubmitter);
                MockSettlementObserverForAdmin settlement = new MockSettlementObserverForAdmin(settlementSubmitter);

                vm.prank(owner);
                harness.registerVRLProofHandlers(address(signal), address(settlement));
            }

            function test_registerVRLProofHandlers_revertsWhenNotOwner() public {
                vm.prank(attacker);
                vm.expectRevert(Errors.InvalidSender.selector);
                harness.registerVRLProofHandlers(address(1), address(2));
            }

            function test_registerVRLProofHandlers_revertsWhenSignalManagerIsZero() public {
                vm.prank(owner);
                vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
                harness.registerVRLProofHandlers(address(0), address(1));
            }

            function test_registerVRLProofHandlers_revertsWhenSettlementObserverIsZero() public {
                vm.prank(owner);
                vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
                harness.registerVRLProofHandlers(address(1), address(0));
            }

            function test_registerVRLProofHandlers_revertsWhenSignalSubmitterIsNotThis() public {
                MockSignalManagerForAdmin signal = new MockSignalManagerForAdmin(address(999));
                MockSettlementObserverForAdmin settlement = new MockSettlementObserverForAdmin(address(harness));

                vm.prank(owner);
                vm.expectRevert(Errors.InvalidSender.selector);
                harness.registerVRLProofHandlers(address(signal), address(settlement));
            }

            function test_registerVRLProofHandlers_revertsWhenSettlementSubmitterIsNotThis() public {
                MockSignalManagerForAdmin signal = new MockSignalManagerForAdmin(address(harness));
                MockSettlementObserverForAdmin settlement = new MockSettlementObserverForAdmin(address(999));

                vm.prank(owner);
                vm.expectRevert(Errors.InvalidSender.selector);
                harness.registerVRLProofHandlers(address(signal), address(settlement));
            }

            function test_registerVRLProofHandlers_setsHandlersAndEmitsEvent() public {
                MockSignalManagerForAdmin signal = new MockSignalManagerForAdmin(address(harness));
                MockSettlementObserverForAdmin settlement = new MockSettlementObserverForAdmin(address(harness));

                vm.expectEmit(true, true, false, true, address(harness));
                emit IVTSAdmin.VRLProofHandlersRegistered(address(signal), address(settlement));

                vm.prank(owner);
                harness.registerVRLProofHandlers(address(signal), address(settlement));

                assertEq(address(harness.signalManager()), address(signal));
                assertEq(address(harness.settlementObserver()), address(settlement));
            }

            function test_onlyIfVRLHandlersRegistered_revertsBeforeRegistration() public {
                vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
                harness.exposeOnlyIfVRLHandlersRegistered();
            }

            function test_onlyIfVRLHandlersRegistered_passesAfterRegistration() public {
                _register(address(harness), address(harness));
                harness.exposeOnlyIfVRLHandlersRegistered();
            }

            function test_setMarketVTSConfiguration_revertsWhenNotOwner() public {
                MarketVTSConfiguration memory cfg = VTSConfigs.getDefaultConfig();

                vm.prank(attacker);
                vm.expectRevert(Errors.InvalidSender.selector);
                harness.setMarketVTSConfiguration(POOL_ID, cfg);
            }

            function test_setMarketVTSConfiguration_revertsWhenConfigInvalid() public {
                MarketVTSConfiguration memory cfg = VTSConfigs.getDefaultConfig();
                cfg.token0.gracePeriodTime = 10;
                cfg.token0.maxGracePeriodTime = 9;

                vm.prank(owner);
                vm.expectRevert(abi.encodeWithSelector(Errors.InvalidVTSConfiguration.selector, 10, 9));
                harness.setMarketVTSConfiguration(POOL_ID, cfg);
            }

            function test_setMarketVTSConfiguration_updatesStorageAndEmitsEvent() public {
                MarketVTSConfiguration memory cfg = VTSConfigs.getDefaultConfig();
                cfg.token0.baseVTSRate += 1;

                vm.expectEmit(true, false, false, true, address(harness));
                emit IVTSAdmin.VTSConfigSet(PoolId.unwrap(POOL_ID), cfg);

                vm.prank(owner);
                harness.setMarketVTSConfiguration(POOL_ID, cfg);

                MarketVTSConfiguration memory stored = harness.getConfig(POOL_ID);
                assertEq(stored.token0.baseVTSRate, cfg.token0.baseVTSRate);
                assertEq(stored.token1.baseVTSRate, cfg.token1.baseVTSRate);
            }
        }
