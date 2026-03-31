// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

/// @notice Echidna harness for MKT-03 and MKT-06 structural market ordering constraints.
contract MKT03_06 {
    uint256 internal constant MAX_VACUOUS_ATTEMPTS = 14;
    uint256 internal attempts;
    uint256 internal uniqChecks;
    uint256 internal orderChecks;
    bool internal uniqAllOk = true;
    bool internal orderAllOk = true;

    constructor() {}

    // forge-lint: disable-next-line(mixed-case-function)
    function action_mkt_03_core_pool_unique(bytes32 corePoolId, address c0, address c1) external {
        unchecked {
            attempts++;
        }
        if (c0 == c1 || c0 == address(0) || c1 == address(0)) {
            c0 = address(0x100);
            c1 = address(0x200);
        }
        MarketRegistryHarness registry = new MarketRegistryHarness();
        bool first = registry.tryCreate(corePoolId, c0, c1);
        bool second = registry.tryCreate(corePoolId, c0, c1);
        uniqChecks++;
        uniqAllOk = uniqAllOk && first && !second;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function action_mkt_06_core_order_canonical(bytes32 corePoolId, address c0, address c1) external {
        unchecked {
            attempts++;
        }
        if (c0 == c1 || c0 == address(0) || c1 == address(0)) {
            c0 = address(0x1111);
            c1 = address(0x2222);
        }
        MarketRegistryHarness registry = new MarketRegistryHarness();
        bool created = registry.tryCreate(corePoolId, c0, c1);
        (address got0, address got1) = registry.corePoolToCurrencyPair(corePoolId);
        (address expected0, address expected1) = _canonicalPair(c0, c1);
        orderChecks++;
        orderAllOk = orderAllOk && (!created || (got0 == expected0 && got1 == expected1));
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_mkt_03_06_hold() external view returns (bool) {
        if (uniqChecks == 0 || orderChecks == 0) {
            return attempts < MAX_VACUOUS_ATTEMPTS;
        }
        return uniqAllOk && orderAllOk;
    }

    function _canonicalPair(address c0, address c1) internal pure returns (address expected0, address expected1) {
        return c0 < c1 ? (c0, c1) : (c1, c0);
    }
}

contract MarketRegistryHarness {
    mapping(bytes32 => bool) internal created;
    mapping(bytes32 => address[2]) internal pairByCore;

    function createMarket(bytes32 corePoolId, address c0, address c1) external {
        if (created[corePoolId]) revert("CorePoolAlreadyExists");
        created[corePoolId] = true;
        (address canonical0, address canonical1) = c0 < c1 ? (c0, c1) : (c1, c0);
        pairByCore[corePoolId] = [canonical0, canonical1];
    }

    function tryCreate(bytes32 corePoolId, address c0, address c1) external returns (bool ok) {
        try this.createMarket(corePoolId, c0, c1) {
            ok = true;
        } catch {
            ok = false;
        }
    }

    function corePoolToCurrencyPair(bytes32 corePoolId) external view returns (address, address) {
        return (pairByCore[corePoolId][0], pairByCore[corePoolId][1]);
    }
}

