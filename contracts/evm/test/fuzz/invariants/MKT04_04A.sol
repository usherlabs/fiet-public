// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {LiquidityHub} from "../../../src/LiquidityHub.sol";
import {LiquidityCommitmentCertificate} from "../../../src/LCC.sol";
import {MockOracleHelper} from "../mocks/MockOracleHelper.sol";
import {MockERC20Transferable} from "../mocks/MockERC20Transferable.sol";
import {Bounds} from "../../../src/libraries/Bounds.sol";
import {BoundRegistry} from "../../../src/modules/BoundRegistry.sol";
import {EchidnaLinkedLibs} from "../base/EchidnaLinkedLibs.sol";

/// @notice Echidna harness for MKT-04 and MKT-04A.
contract MKT04_04A {
    uint256 internal constant MAX_VACUOUS_ATTEMPTS = 14;
    LiquidityHub internal hub;
    LiquidityCommitmentCertificate internal lcc;
    MKT04Actor internal actor;
    BoundRegistryHarness internal registryHarness;

    bool internal checked;
    bool internal lastOk;
    uint256 internal attempts;
    uint256 internal mkt04Checks;
    uint256 internal mkt04aChecks;

    constructor() {
        EchidnaLinkedLibs.deployLCCFactoryLinkedLib();
        EchidnaLinkedLibs.deployLiquidityHubLinkedLib();
        MockOracleHelper oracleHelper = new MockOracleHelper(address(0));
        hub = new LiquidityHub(address(oracleHelper), "Ether", "ETH", 18, address(this));
        hub.setFactory(address(this), true);
        hub.setBoundLevel(address(hub), Bounds.BOUND_EXEMPT);
        actor = new MKT04Actor();
        registryHarness = new BoundRegistryHarness();

        address[] memory issuers = new address[](1);
        issuers[0] = address(this);
        MockERC20Transferable u0 = new MockERC20Transferable();
        MockERC20Transferable u1 = new MockERC20Transferable();
        bytes memory marketRef = abi.encodePacked(address(this));
        (address l0, address l1) = hub.createLCCPair(marketRef, address(u0), address(u1), "MKT04", issuers);
        hub.initialize(l0, l1, bytes32(uint256(1)), marketRef);
        lcc = LiquidityCommitmentCertificate(l0);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function action_mkt_04_factory_and_issuer_gating(uint96 amountRaw) external {
        unchecked {
            attempts++;
        }
        checked = false;
        lastOk = true;
        uint256 amount = uint256(amountRaw % 1e18) + 1;

        bool nonFactoryCreate = actor.tryCreatePair(address(hub));
        bool nonIssuerIssue = actor.tryIssue(address(hub), address(lcc), amount);
        bool nonIssuerCancel = actor.tryCancel(address(hub), address(lcc), amount);
        bool nonIssuerCancelWithQueue = actor.tryCancelWithQueue(address(hub), address(lcc), amount);
        bool nonIssuerPrepareSettle = actor.tryPrepareSettle(address(hub), address(lcc), amount);
        bool nonIssuerConfirmTake = actor.tryConfirmTake(address(hub), address(lcc), amount);
        bool factoryIssueOk = true;
        try hub.issue(address(lcc), address(this), amount) {}
        catch {
            factoryIssueOk = false;
        }

        checked = true;
        mkt04Checks++;
        lastOk = !nonFactoryCreate && !nonIssuerIssue && !nonIssuerCancel && !nonIssuerCancelWithQueue
            && !nonIssuerPrepareSettle && !nonIssuerConfirmTake && factoryIssueOk;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function action_mkt_04a_bound_lifecycle(address who) external {
        unchecked {
            attempts++;
        }
        checked = false;
        lastOk = true;
        if (who == address(0)) who = address(0xBEEF);
        bool noneToEndpoint = registryHarness.trySet(who, Bounds.BOUND_ENDPOINT);
        bool endpointToExempt = registryHarness.trySet(who, Bounds.BOUND_EXEMPT);
        bool endpointToNone = registryHarness.trySet(who, Bounds.BOUND_NONE);
        bool noneToExempt = registryHarness.trySet(who, Bounds.BOUND_EXEMPT);
        bool exemptToEndpoint = registryHarness.trySet(who, Bounds.BOUND_ENDPOINT);

        checked = true;
        mkt04aChecks++;
        lastOk = noneToEndpoint && !endpointToExempt && endpointToNone && noneToExempt && !exemptToEndpoint;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_mkt_04_04a_hold() external view returns (bool) {
        if (mkt04Checks == 0 || mkt04aChecks == 0) {
            return attempts < MAX_VACUOUS_ATTEMPTS;
        }
        return !checked || lastOk;
    }

    /// @dev No-liquidity callback for LiquidityHub issuer path.
    function useMarketLiquidity(address, bytes32, uint256) external view returns (uint256) {
        if (msg.sender != address(hub)) revert();
        return 0;
    }
}

contract MKT04Actor {
    function tryCreatePair(address hub_) external returns (bool ok) {
        MockERC20Transferable u0 = new MockERC20Transferable();
        MockERC20Transferable u1 = new MockERC20Transferable();
        address[] memory issuers = new address[](1);
        issuers[0] = address(this);
        (ok,) = hub_.call(
            abi.encodeWithSignature(
                "createLCCPair(bytes,address,address,string,address[])",
                abi.encodePacked(address(this)),
                address(u0),
                address(u1),
                "FAIL",
                issuers
            )
        );
    }

    function tryIssue(address hub_, address lcc, uint256 amount) external returns (bool ok) {
        (ok,) = hub_.call(abi.encodeWithSignature("issue(address,address,uint256)", lcc, address(this), amount));
    }

    function tryCancel(address hub_, address lcc, uint256 amount) external returns (bool ok) {
        (ok,) = hub_.call(abi.encodeWithSignature("cancel(address,address,uint256)", lcc, address(this), amount));
    }

    function tryCancelWithQueue(address hub_, address lcc, uint256 amount) external returns (bool ok) {
        (ok,) = hub_.call(
            abi.encodeWithSignature(
                "cancelWithQueue(address,address,uint256,uint256,address)",
                lcc,
                address(this),
                amount,
                amount / 2,
                address(this)
            )
        );
    }

    function tryPrepareSettle(address hub_, address lcc, uint256 amount) external returns (bool ok) {
        (ok,) = hub_.call(abi.encodeWithSignature("prepareSettle(address,uint256)", lcc, amount));
    }

    function tryConfirmTake(address hub_, address lcc, uint256 amount) external returns (bool ok) {
        (ok,) = hub_.call(abi.encodeWithSignature("confirmTake(address,uint256,bool)", lcc, amount, false));
    }
}

contract BoundRegistryHarness is BoundRegistry {
    address internal constant FACTORY = address(0xFAc7);

    function _lccMarket(address) internal pure override returns (bytes32 id, address factory) {
        return (bytes32(uint256(1)), FACTORY);
    }

    function setBoundLevel(address who, uint8 level) external override {
        _setBoundLevel(FACTORY, who, level);
    }

    function setBoundLevels(address[] calldata who, uint8 level) external override {
        for (uint256 i = 0; i < who.length; i++) {
            _setBoundLevel(FACTORY, who[i], level);
        }
    }

    function trySet(address who, uint8 level) external returns (bool ok) {
        try this.setBoundLevel(who, level) {
            ok = true;
        } catch {
            ok = false;
        }
    }
}

