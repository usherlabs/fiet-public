// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {ProxyHook} from "../../../src/ProxyHook.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Errors} from "../../../src/libraries/Errors.sol";

/// @notice Echidna harness for MKT-01 and MKT-02 proxy hook structural guards.
contract MKT01_02 {
    uint256 internal constant MAX_VACUOUS_ATTEMPTS = 12;

    MockMarketFactoryMkt internal factory;
    ProxyHookMktHarness internal hook;
    PoolKey internal key;

    uint256 internal addAttempts;
    uint256 internal writeAttempts;
    uint256 internal addChecks;
    uint256 internal writeChecks;
    bool internal addAllOk = true;
    bool internal writeAllOk = true;

    constructor() {
        factory = new MockMarketFactoryMkt();
        hook = new ProxyHookMktHarness(address(0x1234), address(factory));
        key = PoolKey({
            currency0: Currency.wrap(address(0x100)),
            currency1: Currency.wrap(address(0x200)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function action_mkt_01_proxy_rejects_add_liquidity(int24 tickLower, int24 tickUpper, int256 liquidityDelta)
        external
    {
        unchecked {
            addAttempts++;
        }
        ModifyLiquidityParams memory p = ModifyLiquidityParams({
            tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidityDelta, salt: 0
        });
        bool revertedWithExpectedSelector = false;
        try hook.exposedBeforeAddLiquidity(key, p, hex"") {
            revertedWithExpectedSelector = false;
        } catch (bytes memory data) {
            revertedWithExpectedSelector = _selector(data) == Errors.AddLiquidityThroughHookNotAllowed.selector;
        }
        addChecks++;
        addAllOk = addAllOk && revertedWithExpectedSelector;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function action_mkt_02_core_pool_key_write_once(address c0, address c1) external {
        unchecked {
            writeAttempts++;
        }
        if (c0 == c1 || c0 == address(0) || c1 == address(0)) {
            c0 = address(0x100);
            c1 = address(0x200);
        }

        PoolKey memory coreKey = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        address alt0 = c0 == address(0x1111) ? address(0x2222) : address(0x1111);
        address alt1 = c1 == address(0x3333) ? address(0x4444) : address(0x3333);
        if (alt0 == alt1) {
            alt1 = address(uint160(alt1) + 1);
        }
        PoolKey memory altKey = PoolKey({
            currency0: Currency.wrap(alt0),
            currency1: Currency.wrap(alt1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        bool wasSet = hook.isCorePoolKeySet();
        bool firstOk = true;
        try factory.callSetCorePoolKey(hook, coreKey) {}
        catch {
            firstOk = false;
        }
        bool secondRevertedWithExpectedSelector = false;
        try factory.callSetCorePoolKey(hook, altKey) {
            secondRevertedWithExpectedSelector = false;
        } catch (bytes memory data) {
            secondRevertedWithExpectedSelector = _selector(data) == Errors.CorePoolKeyAlreadySet.selector;
        }

        bool ok =
            wasSet ? (!firstOk && secondRevertedWithExpectedSelector) : (firstOk && secondRevertedWithExpectedSelector);
        writeChecks++;
        writeAllOk = writeAllOk && ok;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_mkt_01_proxy_rejects_add_liquidity() external view returns (bool) {
        if (addChecks == 0) {
            return addAttempts < MAX_VACUOUS_ATTEMPTS;
        }
        return addAllOk;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_mkt_02_core_pool_key_write_once() external view returns (bool) {
        if (writeChecks == 0) {
            return writeAttempts < MAX_VACUOUS_ATTEMPTS;
        }
        return writeAllOk;
    }

    function _selector(bytes memory data) internal pure returns (bytes4 sel) {
        if (data.length < 4) return bytes4(0);
        assembly {
            sel := mload(add(data, 32))
        }
    }
}

contract MockMarketFactoryMkt {
    function liquidityHub() external pure returns (address) {
        return address(0x1234);
    }

    function callSetCorePoolKey(ProxyHookMktHarness hook, PoolKey calldata coreKey) external {
        hook.setCorePoolKey(coreKey);
    }
}

contract ProxyHookMktHarness is ProxyHook {
    constructor(address poolManager_, address marketFactory_) ProxyHook(poolManager_, marketFactory_) {}

    function validateHookAddress(BaseHook) internal pure override {}

    function exposedBeforeAddLiquidity(PoolKey calldata key, ModifyLiquidityParams calldata p, bytes calldata hookData)
        external
        returns (bytes4)
    {
        return _beforeAddLiquidity(address(this), key, p, hookData);
    }

    function isCorePoolKeySet() external view returns (bool) {
        return Currency.unwrap(corePoolKey.currency0) != address(0);
    }
}

