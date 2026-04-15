// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {IERC6909Claims} from "@uniswap/v4-core/src/interfaces/external/IERC6909Claims.sol";

import {MarketVaultBase} from "../base/MarketVaultBase.sol";
import {ICanonicalVault} from "../../src/interfaces/ICanonicalVault.sol";
import {IMarketFactory} from "../../src/interfaces/IMarketFactory.sol";
import {CanonicalVault} from "../../src/CanonicalVault.sol";

/// @dev Credits canonical vault via `settleFor`, then facade calls `takeUnderlyingClaims` (same unlock batch).
contract CanonicalVaultSeedTakeHelper is Test, IUnlockCallback {
    IPoolManager private immutable pm;

    constructor(IPoolManager _pm) {
        pm = _pm;
    }

    function run(address underlying, uint256 amount, address canonicalVault, bytes32 marketId, address facade)
        external
    {
        pm.unlock(abi.encode(underlying, amount, canonicalVault, marketId, facade));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (address underlying, uint256 amount, address canonicalVault, bytes32 marketId, address facade) =
            abi.decode(data, (address, uint256, address, bytes32, address));

        Currency c = Currency.wrap(underlying);
        pm.sync(c);
        IERC20Minimal(underlying).transfer(address(pm), amount);
        pm.settleFor(canonicalVault);

        vm.startPrank(facade);
        ICanonicalVault(canonicalVault).takeUnderlyingClaims(marketId, c, amount);
        vm.stopPrank();

        return "";
    }
}

/// @dev One unlock batch: seed delta + `takeUnderlyingClaims`, then `settleUnderlyingFromClaims` (nets PM deltas).
contract CanonicalVaultSeedThenSettleFromClaimsHelper is Test, IUnlockCallback {
    using CurrencySettler for Currency;

    IPoolManager private immutable pm;

    constructor(IPoolManager _pm) {
        pm = _pm;
    }

    function run(
        address underlying,
        uint256 seedAmount,
        uint256 burnAmount,
        address canonicalVault,
        bytes32 marketId,
        address facade
    ) external {
        pm.unlock(abi.encode(underlying, seedAmount, burnAmount, canonicalVault, marketId, facade));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (
            address underlying,
            uint256 seedAmount,
            uint256 burnAmount,
            address canonicalVault,
            bytes32 marketId,
            address facade
        ) = abi.decode(data, (address, uint256, uint256, address, bytes32, address));

        Currency c = Currency.wrap(underlying);
        pm.sync(c);
        IERC20Minimal(underlying).transfer(address(pm), seedAmount);
        pm.settleFor(canonicalVault);

        vm.startPrank(facade);
        ICanonicalVault(canonicalVault).takeUnderlyingClaims(marketId, c, seedAmount);
        ICanonicalVault(canonicalVault).settleUnderlyingFromClaims(marketId, c, burnAmount);
        vm.stopPrank();

        // Burning claims credits a positive PoolManager delta on the vault; pull underlying out to net the batch.
        vm.prank(canonicalVault);
        c.take(pm, canonicalVault, burnAmount, false);

        return "";
    }
}

/// @dev Facade calls `settleUnderlyingToVaultFromHub` under `unlock`.
contract CanonicalVaultSettleFromHubHelper is Test, IUnlockCallback {
    IPoolManager private immutable pm;

    constructor(IPoolManager _pm) {
        pm = _pm;
    }

    function run(address canonicalVault, bytes32 marketId, address facade, address lccToken, uint256 amount) external {
        pm.unlock(abi.encode(canonicalVault, marketId, facade, lccToken, amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (address canonicalVault, bytes32 marketId, address facade, address lccToken, uint256 amount) =
            abi.decode(data, (address, bytes32, address, address, uint256));

        vm.startPrank(facade);
        ICanonicalVault(canonicalVault).settleUnderlyingToVaultFromHub(marketId, lccToken, amount);
        vm.stopPrank();

        return "";
    }
}

/// @dev Facade calls `issueAndSettleLcc` then `takeLccFromPoolManager` in one unlock batch.
contract CanonicalVaultIssueTakeLccHelper is Test, IUnlockCallback {
    IPoolManager private immutable pm;

    constructor(IPoolManager _pm) {
        pm = _pm;
    }

    function run(address canonicalVault, bytes32 marketId, address facade, address lccToken, uint256 amount) external {
        pm.unlock(abi.encode(canonicalVault, marketId, facade, lccToken, amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (address canonicalVault, bytes32 marketId, address facade, address lccToken, uint256 amount) =
            abi.decode(data, (address, bytes32, address, address, uint256));

        vm.startPrank(facade);
        ICanonicalVault(canonicalVault).issueAndSettleLcc(marketId, lccToken, amount);
        ICanonicalVault(canonicalVault).takeLccFromPoolManager(marketId, lccToken, amount);
        vm.stopPrank();

        return "";
    }
}

/// @dev Facade calls `issueAndSettleLcc`; helper clears canonical delta so unlock can complete.
contract CanonicalVaultIssueSettleClearLccHelper is Test, IUnlockCallback {
    IPoolManager private immutable pm;

    constructor(IPoolManager _pm) {
        pm = _pm;
    }

    function run(address canonicalVault, bytes32 marketId, address facade, address lccToken, uint256 amount) external {
        pm.unlock(abi.encode(canonicalVault, marketId, facade, lccToken, amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (address canonicalVault, bytes32 marketId, address facade, address lccToken, uint256 amount) =
            abi.decode(data, (address, bytes32, address, address, uint256));

        vm.startPrank(facade);
        ICanonicalVault(canonicalVault).issueAndSettleLcc(marketId, lccToken, amount);
        vm.stopPrank();

        // `issueAndSettleLcc` leaves a positive LCC delta on CanonicalVault; clear it to satisfy unlock finality.
        vm.prank(canonicalVault);
        pm.clear(Currency.wrap(lccToken), amount);

        return "";
    }
}

/// @notice Claim-ownership and reserve mirroring tests for `CanonicalVault` (durable observables only).
contract CanonicalVaultClaimsTest is MarketVaultBase {
    CanonicalVaultSeedTakeHelper internal seedTakeHelper;
    CanonicalVaultSeedThenSettleFromClaimsHelper internal seedThenSettleHelper;
    CanonicalVaultSettleFromHubHelper internal settleHubHelper;
    CanonicalVaultIssueTakeLccHelper internal issueTakeLccHelper;
    CanonicalVaultIssueSettleClearLccHelper internal issueSettleClearLccHelper;

    function setUp() public override {
        super.setUp();
        IPoolManager pm = IPoolManager(address(manager));
        seedTakeHelper = new CanonicalVaultSeedTakeHelper(pm);
        seedThenSettleHelper = new CanonicalVaultSeedThenSettleFromClaimsHelper(pm);
        settleHubHelper = new CanonicalVaultSettleFromHubHelper(pm);
        issueTakeLccHelper = new CanonicalVaultIssueTakeLccHelper(pm);
        issueSettleClearLccHelper = new CanonicalVaultIssueSettleClearLccHelper(pm);
    }

    /// @dev Suite A (plan): `takeUnderlyingClaims` must mint durable claims to CanonicalVault and mirror reserves.
    function test_takeUnderlyingClaims_mintsClaimToCanonicalVault_andIncrementsReserve() public {
        address payable canonical = payable(IMarketFactory(marketFactory).canonicalVault());
        bytes32 marketId = _coreMarketId();
        address ua = Currency.unwrap(proxyPoolKey.currency0);
        vm.assume(ua != address(0));

        uint256 amount = 1e18;
        IERC20Minimal(ua).transfer(address(seedTakeHelper), amount);

        uint256 claimBefore = _underlying6909Balance(address(canonical), proxyPoolKey.currency0);
        uint256 reserveBefore = CanonicalVault(canonical).inMarketBalanceOf(marketId, proxyPoolKey.currency0);
        uint256 totalBefore = CanonicalVault(canonical).totalUnderlyingReserves(ua);
        uint256 hookClaimBefore = _underlying6909Balance(address(proxyHook), proxyPoolKey.currency0);

        seedTakeHelper.run(ua, amount, address(canonical), marketId, address(proxyHook));

        assertEq(_underlying6909Balance(address(canonical), proxyPoolKey.currency0), claimBefore + amount);
        assertEq(CanonicalVault(canonical).inMarketBalanceOf(marketId, proxyPoolKey.currency0), reserveBefore + amount);
        assertEq(CanonicalVault(canonical).totalUnderlyingReserves(ua), totalBefore + amount);
        assertEq(_underlying6909Balance(address(proxyHook), proxyPoolKey.currency0), hookClaimBefore);
    }

    /// @dev Suite A (plan): `settleUnderlyingFromClaims` must burn CanonicalVault claims and reduce durable reserves.
    function test_settleUnderlyingFromClaims_burnsClaimFromCanonicalVault_andDecrementsReserve() public {
        address payable canonical = payable(IMarketFactory(marketFactory).canonicalVault());
        bytes32 marketId = _coreMarketId();
        address ua = Currency.unwrap(proxyPoolKey.currency0);
        vm.assume(ua != address(0));

        uint256 seed = 5e18;
        uint256 burnAmount = 2e18;

        uint256 claimBefore = _underlying6909Balance(address(canonical), proxyPoolKey.currency0);
        uint256 reserveBefore = CanonicalVault(canonical).inMarketBalanceOf(marketId, proxyPoolKey.currency0);
        uint256 totalBefore = CanonicalVault(canonical).totalUnderlyingReserves(ua);
        uint256 hookClaimBefore = _underlying6909Balance(address(proxyHook), proxyPoolKey.currency0);

        IERC20Minimal(ua).transfer(address(seedThenSettleHelper), seed);
        seedThenSettleHelper.run(ua, seed, burnAmount, address(canonical), marketId, address(proxyHook));

        assertEq(_underlying6909Balance(address(canonical), proxyPoolKey.currency0), claimBefore + seed - burnAmount);
        assertEq(
            CanonicalVault(canonical).inMarketBalanceOf(marketId, proxyPoolKey.currency0),
            reserveBefore + seed - burnAmount
        );
        assertEq(CanonicalVault(canonical).totalUnderlyingReserves(ua), totalBefore + seed - burnAmount);
        assertEq(_underlying6909Balance(address(proxyHook), proxyPoolKey.currency0), hookClaimBefore);
    }

    /// @dev Suite A (plan): ingress settlement from Hub should increase CanonicalVault claim ownership by exact amount.
    function test_settleUnderlyingToVaultFromHub_routesClaimOwnershipToCanonicalVault() public {
        address payable canonical = payable(IMarketFactory(marketFactory).canonicalVault());
        bytes32 marketId = _coreMarketId();
        address ua = lcc0.underlying();
        vm.assume(ua != address(0));

        uint256 amount = 1e17;
        uint256 claimBefore = _underlying6909Balance(address(canonical), Currency.wrap(ua));
        uint256 reserveBefore = CanonicalVault(canonical).inMarketBalanceOf(marketId, Currency.wrap(ua));
        uint256 totalBefore = CanonicalVault(canonical).totalUnderlyingReserves(ua);
        uint256 hookClaimBefore = _underlying6909Balance(address(proxyHook), Currency.wrap(ua));

        settleHubHelper.run(address(canonical), marketId, address(proxyHook), address(lcc0), amount);

        assertEq(_underlying6909Balance(address(canonical), Currency.wrap(ua)), claimBefore + amount);
        assertEq(CanonicalVault(canonical).inMarketBalanceOf(marketId, Currency.wrap(ua)), reserveBefore + amount);
        assertEq(CanonicalVault(canonical).totalUnderlyingReserves(ua), totalBefore + amount);
        assertEq(_underlying6909Balance(address(proxyHook), Currency.wrap(ua)), hookClaimBefore);
    }

    /// @dev Suite A (plan): `issueAndSettleLcc` should route LCC custody into PoolManager without underlying claim leakage.
    function test_issueAndSettleLcc_routesLccIntoPoolManager_withoutUnderlyingClaimLeak() public {
        address payable canonical = payable(IMarketFactory(marketFactory).canonicalVault());
        bytes32 marketId = _coreMarketId();
        address ua0 = Currency.unwrap(proxyPoolKey.currency0);
        address ua1 = Currency.unwrap(proxyPoolKey.currency1);
        vm.assume(ua0 != address(0) && ua1 != address(0));

        uint256 amount = 1e16;
        uint256 managerLccBefore = IERC20Minimal(address(lcc0)).balanceOf(address(manager));
        uint256 canonicalLccBefore = IERC20Minimal(address(lcc0)).balanceOf(address(canonical));
        uint256 hookU0Before = _underlying6909Balance(address(proxyHook), Currency.wrap(ua0));
        uint256 hookU1Before = _underlying6909Balance(address(proxyHook), Currency.wrap(ua1));

        issueSettleClearLccHelper.run(address(canonical), marketId, address(proxyHook), address(lcc0), amount);

        assertEq(IERC20Minimal(address(lcc0)).balanceOf(address(manager)), managerLccBefore + amount);
        assertEq(IERC20Minimal(address(lcc0)).balanceOf(address(canonical)), canonicalLccBefore);
        assertEq(_underlying6909Balance(address(proxyHook), Currency.wrap(ua0)), hookU0Before);
        assertEq(_underlying6909Balance(address(proxyHook), Currency.wrap(ua1)), hookU1Before);
    }

    /// @dev Suite A (plan): `takeLccFromPoolManager` should move LCC out of manager to CanonicalVault without underlying leaks.
    function test_takeLccFromPoolManager_transfersLccOutWithoutCreatingUnderlyingClaimLeak() public {
        address payable canonical = payable(IMarketFactory(marketFactory).canonicalVault());
        bytes32 marketId = _coreMarketId();
        address ua0 = Currency.unwrap(proxyPoolKey.currency0);
        address ua1 = Currency.unwrap(proxyPoolKey.currency1);
        vm.assume(ua0 != address(0) && ua1 != address(0));

        uint256 amount = 1e16;
        uint256 managerLccBefore = IERC20Minimal(address(lcc0)).balanceOf(address(manager));
        uint256 canonicalLccBefore = IERC20Minimal(address(lcc0)).balanceOf(address(canonical));
        uint256 hookU0Before = _underlying6909Balance(address(proxyHook), Currency.wrap(ua0));
        uint256 hookU1Before = _underlying6909Balance(address(proxyHook), Currency.wrap(ua1));

        issueTakeLccHelper.run(address(canonical), marketId, address(proxyHook), address(lcc0), amount);

        assertEq(IERC20Minimal(address(lcc0)).balanceOf(address(manager)), managerLccBefore);
        assertEq(IERC20Minimal(address(lcc0)).balanceOf(address(canonical)), canonicalLccBefore + amount);
        assertEq(_underlying6909Balance(address(proxyHook), Currency.wrap(ua0)), hookU0Before);
        assertEq(_underlying6909Balance(address(proxyHook), Currency.wrap(ua1)), hookU1Before);
    }

    /// @dev Suite D (plan): operator permission should enable mediated burns while keeping durable ownership on CanonicalVault.
    function test_registerMarket_operatorPermission_doesNotChangeClaimOwnershipModel() public {
        address payable canonical = payable(IMarketFactory(marketFactory).canonicalVault());
        assertTrue(
            IERC6909Claims(address(manager)).isOperator(address(canonical), address(proxyHook)),
            "facade should be operator for CanonicalVault claims on PoolManager"
        );

        address ua = Currency.unwrap(proxyPoolKey.currency0);
        vm.assume(ua != address(0));

        uint256 swapAmount = 1e18;
        _executeSwap(proxyPoolKey, true, -int256(swapAmount), bytes(""));

        assertEq(_underlying6909Balance(address(proxyHook), proxyPoolKey.currency0), 0);
        assertEq(_underlying6909Balance(address(proxyHook), proxyPoolKey.currency1), 0);
        assertGt(_underlying6909Balance(address(canonical), proxyPoolKey.currency0), 0);
    }
}
