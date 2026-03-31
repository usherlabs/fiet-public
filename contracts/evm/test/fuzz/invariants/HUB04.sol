// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {LiquidityHub} from "../../../src/LiquidityHub.sol";
import {LiquidityCommitmentCertificate} from "../../../src/LCC.sol";
import {MockOracleHelper} from "../mocks/MockOracleHelper.sol";
import {MockERC20Transferable} from "../mocks/MockERC20Transferable.sol";
import {Bounds} from "../../../src/libraries/Bounds.sol";
import {EchidnaLinkedLibs} from "../base/EchidnaLinkedLibs.sol";

/// @dev Minimal second factory so Market B LCCs have a different factory address.
contract HUB04FactoryB {
    function createPair(
        LiquidityHub hub,
        bytes memory ref,
        address underlying,
        address other,
        string memory name,
        address[] memory issuers
    ) external returns (address, address) {
        return hub.createLCCPair(ref, underlying, other, name, issuers);
    }

    function initializePair(LiquidityHub hub, address lcc0, address lcc1, bytes32 marketId, bytes memory ref) external {
        hub.initialize(lcc0, lcc1, marketId, ref);
    }

    function useMarketLiquidity(address, bytes32, uint256) external pure returns (uint256) {
        return 0;
    }
}

/// @notice Echidna harness for HUB-04: LCC pairs must be from the same market factory.
/// @dev "Operations that treat an LCC pair as a market must ensure both LCCs belong to the same factory."
///
/// Properties tested:
///   1. getFactory(lccA, lccB) from the SAME market succeeds and returns the correct factory
///   2. getFactory(lccA, lccFromDifferentFactory) always reverts
///   3. getFactory(lccA, randomNonLcc) always reverts (mismatched zero vs real factory)
contract HUB04 {
    LiquidityHub internal hub;
    HUB04FactoryB internal factoryB;

    // Market A: two LCCs from factory = address(this).
    LiquidityCommitmentCertificate internal lccA0;
    LiquidityCommitmentCertificate internal lccA1;

    // Market B: two LCCs from factory = address(factoryB) — a different factory.
    LiquidityCommitmentCertificate internal lccB0;
    LiquidityCommitmentCertificate internal lccB1;

    address internal constant RANDOM_ADDR = address(0xDEAD);

    // Action/result: same-market pair succeeds.
    bool internal checkedSameMarket;
    bool internal lastSameMarketOk;

    // Action/result: cross-factory pair reverts.
    bool internal checkedCrossFactory;
    bool internal lastCrossFactoryOk;

    // Action/result: non-LCC pair reverts.
    bool internal checkedNonLcc;
    bool internal lastNonLccOk;

    constructor() {
        EchidnaLinkedLibs.deployLCCFactoryLinkedLib();
        EchidnaLinkedLibs.deployLiquidityHubLinkedLib();

        MockOracleHelper oracleHelper = new MockOracleHelper(address(0));
        hub = new LiquidityHub(address(oracleHelper), "Ether", "ETH", 18, address(this));

        // Register two factory addresses.
        hub.setFactory(address(this), true);
        factoryB = new HUB04FactoryB();
        hub.setFactory(address(factoryB), true);

        hub.setBoundLevel(address(hub), Bounds.BOUND_EXEMPT);

        address[] memory issuers = new address[](1);
        issuers[0] = address(this);

        _createMarketA(issuers);
        _createMarketB(issuers);
        _seedAll();
    }

    function _createMarketA(address[] memory issuers) internal {
        MockERC20Transferable underlyingA = new MockERC20Transferable();
        MockERC20Transferable otherA = new MockERC20Transferable();
        bytes memory refA = abi.encodePacked(address(this), bytes1(0x01));
        (address a0, address a1) = hub.createLCCPair(refA, address(underlyingA), address(otherA), "MKT_A", issuers);
        hub.initialize(a0, a1, bytes32(uint256(1)), refA);
        lccA0 = LiquidityCommitmentCertificate(a0);
        lccA1 = LiquidityCommitmentCertificate(a1);
    }

    function _createMarketB(address[] memory issuers) internal {
        MockERC20Transferable underlyingB = new MockERC20Transferable();
        MockERC20Transferable otherB = new MockERC20Transferable();
        bytes memory refB = abi.encodePacked(address(factoryB), bytes1(0x02));
        (address b0, address b1) =
            factoryB.createPair(hub, refB, address(underlyingB), address(otherB), "MKT_B", issuers);
        factoryB.initializePair(hub, b0, b1, bytes32(uint256(2)), refB);
        lccB0 = LiquidityCommitmentCertificate(b0);
        lccB1 = LiquidityCommitmentCertificate(b1);
    }

    function _seedAll() internal {
        // Seed same-market: getFactory(lccA0, lccA1) must succeed and return factoryA.
        (bool ok, bytes memory ret) = address(hub)
            .staticcall(abi.encodeWithSignature("getFactory(address,address)", address(lccA0), address(lccA1)));
        address factory;
        if (ok && ret.length >= 32) {
            factory = abi.decode(ret, (address));
        }
        checkedSameMarket = true;
        lastSameMarketOk = ok && (factory == address(this));

        // Seed same-market B: getFactory(lccB0, lccB1) must succeed and return factoryB.
        (ok, ret) = address(hub)
            .staticcall(abi.encodeWithSignature("getFactory(address,address)", address(lccB0), address(lccB1)));
        if (ok && ret.length >= 32) {
            factory = abi.decode(ret, (address));
        }
        lastSameMarketOk = lastSameMarketOk && ok && (factory == address(factoryB));

        // Seed cross-factory: getFactory(lccA0, lccB0) must revert.
        (ok,) = address(hub)
            .staticcall(abi.encodeWithSignature("getFactory(address,address)", address(lccA0), address(lccB0)));
        checkedCrossFactory = true;
        lastCrossFactoryOk = !ok;

        // Seed non-LCC: getFactory(lccA0, RANDOM_ADDR) must revert.
        (ok,) = address(hub)
            .staticcall(abi.encodeWithSignature("getFactory(address,address)", address(lccA0), RANDOM_ADDR));
        checkedNonLcc = true;
        lastNonLccOk = !ok;
    }

    /// @dev No-liquidity factory callback.
    function useMarketLiquidity(address, bytes32, uint256) external view returns (uint256) {
        if (msg.sender != address(hub)) revert();
        return 0;
    }

    // ================================================================
    // Actions — same-market (positive path)
    // ================================================================

    /// @dev getFactory with both LCCs from Market A must succeed and return factory A.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_hub_04_same_market_a(bool flip) external {
        address a = flip ? address(lccA1) : address(lccA0);
        address b = flip ? address(lccA0) : address(lccA1);

        (bool ok, bytes memory ret) =
            address(hub).staticcall(abi.encodeWithSignature("getFactory(address,address)", a, b));
        address factory;
        if (ok && ret.length >= 32) factory = abi.decode(ret, (address));

        checkedSameMarket = true;
        lastSameMarketOk = ok && (factory == address(this));
    }

    /// @dev getFactory with both LCCs from Market B must succeed and return factory B.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_hub_04_same_market_b(bool flip) external {
        address a = flip ? address(lccB1) : address(lccB0);
        address b = flip ? address(lccB0) : address(lccB1);

        (bool ok, bytes memory ret) =
            address(hub).staticcall(abi.encodeWithSignature("getFactory(address,address)", a, b));
        address factory;
        if (ok && ret.length >= 32) factory = abi.decode(ret, (address));

        checkedSameMarket = true;
        lastSameMarketOk = ok && (factory == address(factoryB));
    }

    // ================================================================
    // Actions — cross-factory (must revert)
    // ================================================================

    /// @dev getFactory with LCCs from different factories must revert.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_hub_04_cross_factory(uint8 combo) external {
        address a;
        address b;
        uint8 c = combo % 4;
        if (c == 0) {
            a = address(lccA0);
            b = address(lccB0);
        } else if (c == 1) {
            a = address(lccA0);
            b = address(lccB1);
        } else if (c == 2) {
            a = address(lccA1);
            b = address(lccB0);
        } else {
            a = address(lccA1);
            b = address(lccB1);
        }

        (bool ok,) = address(hub).staticcall(abi.encodeWithSignature("getFactory(address,address)", a, b));
        checkedCrossFactory = true;
        lastCrossFactoryOk = !ok;
    }

    // ================================================================
    // Actions — non-LCC (must revert)
    // ================================================================

    /// @dev getFactory with a non-LCC address must revert (factory mismatch: real vs zero).
    // forge-lint: disable-next-line(mixed-case-function)
    function action_hub_04_non_lcc(bool useValidFirst) external {
        address a = useValidFirst ? address(lccA0) : RANDOM_ADDR;
        address b = useValidFirst ? RANDOM_ADDR : address(lccA0);

        (bool ok,) = address(hub).staticcall(abi.encodeWithSignature("getFactory(address,address)", a, b));
        checkedNonLcc = true;
        lastNonLccOk = !ok;
    }

    // ================================================================
    // Properties
    // ================================================================

    /// @dev Same-market LCC pair must always resolve to the correct factory.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_hub_04_same_market_resolves() external view returns (bool) {
        return !checkedSameMarket || lastSameMarketOk;
    }

    /// @dev Cross-factory LCC pair must always revert.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_hub_04_cross_factory_reverts() external view returns (bool) {
        return !checkedCrossFactory || lastCrossFactoryOk;
    }

    /// @dev Non-LCC address in pair must always revert (when paired with a valid LCC).
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_hub_04_non_lcc_reverts() external view returns (bool) {
        return !checkedNonLcc || lastNonLccOk;
    }
}
