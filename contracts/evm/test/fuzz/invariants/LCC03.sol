// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {MarketLiquidityRouterLib} from "../../../src/libraries/MarketLiquidityRouterLib.sol";
import {IVaultCoreActionHandler} from "../../../src/interfaces/IVaultCoreActionHandler.sol";
import {MockPoolManagerTransient} from "../mocks/MockPoolManagerTransient.sol";
import {MockERC20Transferable} from "../mocks/MockERC20Transferable.sol";

/// @notice Echidna harness for LCC-03 nested ingress settlement windows.
contract LCC03 {
    uint256 internal constant MAX_VACUOUS_ATTEMPTS = 18;
    MockPoolManagerTransient internal poolManager;
    MockIngressHandler internal ingressHandler;
    MockLCCIngress internal lccErc20;
    MockLCCIngress internal lccNative;

    bool internal checkedSync;
    bool internal lastSyncOk;
    bool internal checkedRevert;
    bool internal lastRevertOk;
    uint256 internal syncAttempts;
    uint256 internal revertAttempts;
    uint256 internal syncChecks;
    uint256 internal revertChecks;

    constructor() {
        poolManager = new MockPoolManagerTransient();
        ingressHandler = new MockIngressHandler(address(poolManager));
        lccErc20 = new MockLCCIngress(address(0x1001));
        lccNative = new MockLCCIngress(address(0));
        poolManager.setLocked(false);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function action_lcc03_no_active_sync(uint96 wrappedAmountRaw, bool useNative) external {
        unchecked {
            syncAttempts++;
        }
        checkedSync = false;
        lastSyncOk = true;
        ingressHandler.setNestedSync(address(0), false);
        address lcc = useNative ? address(lccNative) : address(lccErc20);
        uint256 wrappedAmount = uint256(wrappedAmountRaw % 1e18);
        if (wrappedAmount == 0) wrappedAmount = 1;

        poolManager.setExttload(MarketLiquidityRouterLib.CURRENCY_SLOT, bytes32(0));
        uint256 beforeCalls = ingressHandler.calls();
        _prepare(lcc, wrappedAmount);

        checkedSync = true;
        syncChecks++;
        (address gotLcc, uint256 gotAmount) = ingressHandler.lastCall();
        lastSyncOk = ingressHandler.calls() == beforeCalls + 1 && gotLcc == lcc && gotAmount == wrappedAmount;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function action_lcc03_revert_on_currency_mismatch(address other) external {
        unchecked {
            revertAttempts++;
        }
        checkedRevert = false;
        lastRevertOk = true;
        if (other == address(0) || other == address(lccErc20)) {
            other = address(0xDEAD);
        }
        poolManager.setExttload(MarketLiquidityRouterLib.CURRENCY_SLOT, bytes32(uint256(uint160(other))));
        bool reverted = _prepareCatch(address(lccErc20), 1);
        checkedRevert = true;
        revertChecks++;
        lastRevertOk = reverted;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function action_lcc03_revert_on_unpaid_transfer(uint96 syncedRaw, uint96 extraRaw) external {
        unchecked {
            revertAttempts++;
        }
        checkedRevert = false;
        lastRevertOk = true;

        uint256 synced = uint256(syncedRaw % 1e18) + 10;
        uint256 extra = uint256(extraRaw % 1e17) + 1;
        lccErc20.mint(address(poolManager), synced + extra);
        poolManager.setExttload(MarketLiquidityRouterLib.CURRENCY_SLOT, bytes32(uint256(uint160(address(lccErc20)))));
        poolManager.setExttload(MarketLiquidityRouterLib.RESERVES_OF_SLOT, bytes32(synced));

        bool reverted = _prepareCatch(address(lccErc20), 1);
        checkedRevert = true;
        revertChecks++;
        lastRevertOk = reverted;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function action_lcc03_revert_on_invalid_snapshot(uint96 syncedRaw, uint96 balRaw) external {
        unchecked {
            revertAttempts++;
        }
        checkedRevert = false;
        lastRevertOk = true;

        uint256 synced = uint256(syncedRaw % 1e18) + 2;
        uint256 bal = uint256(balRaw % (synced - 1)) + 1;
        lccErc20.mint(address(poolManager), bal);
        poolManager.setExttload(MarketLiquidityRouterLib.CURRENCY_SLOT, bytes32(uint256(uint160(address(lccErc20)))));
        poolManager.setExttload(MarketLiquidityRouterLib.RESERVES_OF_SLOT, bytes32(synced));

        bool reverted = _prepareCatch(address(lccErc20), 1);
        checkedRevert = true;
        revertChecks++;
        lastRevertOk = reverted;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function action_lcc03_restore_sync_after_nested(bool nestedNative) external {
        unchecked {
            syncAttempts++;
        }
        checkedSync = false;
        lastSyncOk = true;

        MockLCCIngress lcc = nestedNative ? lccNative : lccErc20;
        lcc.mint(address(poolManager), 25);
        poolManager.setExttload(MarketLiquidityRouterLib.CURRENCY_SLOT, bytes32(uint256(uint160(address(lcc)))));
        poolManager.setExttload(MarketLiquidityRouterLib.RESERVES_OF_SLOT, bytes32(uint256(25)));
        ingressHandler.setNestedSync(nestedNative ? address(0) : address(lccErc20), true);

        _prepare(address(lcc), 2);
        ingressHandler.setNestedSync(address(0), false);

        checkedSync = true;
        syncChecks++;
        address restored = address(uint160(uint256(poolManager.extttloadCurrency())));
        uint256 reserves = poolManager.extttloadReserves();
        lastSyncOk = restored == address(lcc) && reserves == 25;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_lcc_03_sync_windows_hold() external view returns (bool) {
        if (syncChecks == 0) {
            return syncAttempts < MAX_VACUOUS_ATTEMPTS;
        }
        return !checkedSync || lastSyncOk;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_lcc_03_revert_guards_hold() external view returns (bool) {
        if (revertChecks == 0) {
            return revertAttempts < MAX_VACUOUS_ATTEMPTS;
        }
        return !checkedRevert || lastRevertOk;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_lcc_03_smoke() external pure returns (bool) {
        return true;
    }

    function _prepare(address lcc, uint256 wrappedAmount) internal {
        MarketLiquidityRouterLib.prepareMarketLiquidityIngress(
            MarketLiquidityRouterLib.PrepareMarketLiquidityContext({
                poolManager: IPoolManager(address(poolManager)),
                handler: address(ingressHandler),
                lcc: lcc,
                wrappedAmount: wrappedAmount
            })
        );
    }

    function _prepareCatch(address lcc, uint256 wrappedAmount) internal returns (bool reverted) {
        try this.exposed_prepare(lcc, wrappedAmount) {
            reverted = false;
        } catch {
            reverted = true;
        }
    }

    function exposed_prepare(address lcc, uint256 wrappedAmount) external {
        _prepare(lcc, wrappedAmount);
    }
}

contract MockIngressHandler is IVaultCoreActionHandler {
    MockPoolManagerTransient internal immutable poolManager;
    bool internal nestedSyncEnabled;
    address internal nestedCurrency;
    uint256 internal ingressCalls;
    address internal lastLcc;
    uint256 internal lastWrappedAmount;

    constructor(address poolManager_) {
        poolManager = MockPoolManagerTransient(poolManager_);
    }

    function setNestedSync(address currency, bool enabled) external {
        nestedCurrency = currency;
        nestedSyncEnabled = enabled;
    }

    function handleIngress(address lcc, uint256 wrappedAmount) external {
        ingressCalls++;
        lastLcc = lcc;
        lastWrappedAmount = wrappedAmount;
        if (nestedSyncEnabled) {
            poolManager.sync(Currency.wrap(nestedCurrency));
        }
    }

    function handleAddLiquidity() external pure {}

    function handleSwap(address) external pure {}

    function calls() external view returns (uint256) {
        return ingressCalls;
    }

    function lastCall() external view returns (address lcc, uint256 wrappedAmount) {
        return (lastLcc, lastWrappedAmount);
    }
}

contract MockLCCIngress is MockERC20Transferable {
    address internal immutable underlyingAsset;

    constructor(address underlying_) {
        underlyingAsset = underlying_;
    }

    function underlying() external view returns (address) {
        return underlyingAsset;
    }
}

