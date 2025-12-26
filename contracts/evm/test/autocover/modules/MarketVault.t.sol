// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {OlympixUnitTest} from "../tools/OlympixUnitTest.sol";
import {MarketVaultBase} from "../../base/MarketVaultBase.sol";
import {MarketVault} from "../../../src/modules/MarketVault.sol";
import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ILCC} from "../../../src/interfaces/ILCC.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Errors} from "../../../src/libraries/Errors.sol";

/// @dev Minimal mock MarketFactory used only to satisfy `MarketVault` constructor wiring in the harness.
contract MarketVaultHarness_MockFactory {
    address internal _hub;
    mapping(address => bool) internal _isBound;

    constructor(address hub_) {
        _hub = hub_;
    }

    function liquidityHub() external view returns (address) {
        return _hub;
    }

    /// @notice Test helper: configure whether an address is considered protocol-bound.
    function setBound(address who, bool isBound) external {
        _isBound[who] = isBound;
    }

    /// @notice Protocol-bound check used by `MarketVault.onlyProtocolBounds`.
    /// @dev Defaults to false so unit tests can assert `InvalidSender` without needing a PoolManager.
    function bounds(address who) external view returns (bool) {
        return _isBound[who];
    }
}

/**
 * @title MarketVaultHarness (autocover target)
 * @notice `MarketVault` is abstract and relies on hook-provided context in production (see `ProxyHook`).
 *         This harness adopts the same override pattern as `ProxyHook` to provide mock values for:
 *         - `_underlying()` (the underlying currency pair)
 *         - `_lccs()`       (the LCC pair backing the market)
 *         - `_marketId()`   (the market identifier)
 *
 * The harness is intentionally minimal: it exists so tooling can target a concrete contract, and so tests
 * can optionally drive `MarketVault` behaviour by setting the mock values.
 */
contract MarketVaultHarness is MarketVault {
    Currency internal _mockCurrency0;
    Currency internal _mockCurrency1;
    ILCC internal _mockLcc0;
    ILCC internal _mockLcc1;
    bytes32 internal _mockMarketId;

    constructor()
        // `MarketVault` ultimately depends on `ImmutableState.poolManager`; for the harness we don't execute
        // PoolManager interactions, so `address(0)` is sufficient.
        ImmutableState(IPoolManager(address(0)))
        // Provide a non-zero MarketFactory address; its only requirement in the constructor is `liquidityHub()`.
        MarketVault(address(new MarketVaultHarness_MockFactory(address(0xBEEF))))
    {}

    /// @notice Set mock override values (optional; useful for direct harness-based unit tests).
    function setMockContext(Currency currency0, Currency currency1, ILCC lcc0, ILCC lcc1, bytes32 marketId) external {
        _mockCurrency0 = currency0;
        _mockCurrency1 = currency1;
        _mockLcc0 = lcc0;
        _mockLcc1 = lcc1;
        _mockMarketId = marketId;
    }

    /// @inheritdoc MarketVault
    function _underlying() internal view override returns (Currency currency0, Currency currency1) {
        return (_mockCurrency0, _mockCurrency1);
    }

    /// @inheritdoc MarketVault
    function _lccs() internal view override returns (ILCC lccToken0, ILCC lccToken1) {
        return (_mockLcc0, _mockLcc1);
    }

    /// @inheritdoc MarketVault
    function _marketId() internal view override returns (bytes32) {
        return _mockMarketId;
    }
}

contract MarketVaultTest_Autocover is MarketVaultBase, OlympixUnitTest("MarketVaultHarness") {
    MarketVaultHarness internal vault;

    function setUp() public override {
        super.setUp();
        vault = new MarketVaultHarness();
    }

    function test_onlyProtocolBounds_revertsWhenNotBound() public {
        vm.expectRevert(Errors.InvalidSender.selector);
        vault.tryModifyLiquidities(toBalanceDelta(int128(1), int128(0)));
    }
}

