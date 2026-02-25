// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IMarketFactory} from "../interfaces/IMarketFactory.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Errors} from "../libraries/Errors.sol";
import {IMarketVault} from "../interfaces/IMarketVault.sol";

/// @notice Library for market operations. Provides internal functions for accessing market factory data.
library MarketHandlerLib {
    /// @notice Gets the currency pair for a core pool
    /// @param marketFactory The market factory instance
    /// @param poolId The core pool ID
    /// @return The currency pair [token0, token1]
    function currenciesInMarket(IMarketFactory marketFactory, PoolId poolId) internal view returns (address[2] memory) {
        return marketFactory.corePoolToCurrencyPair(poolId);
    }

    /// @notice Gets the currency pair for a vault (proxy hook)
    /// @param marketFactory The market factory instance
    /// @param vault The vault address
    /// @return The currency pair [token0, token1]
    function vaultToCurrencyPair(IMarketFactory marketFactory, address vault)
        internal
        view
        returns (address[2] memory)
    {
        return marketFactory.proxyHookToCurrencyPair(vault);
    }

    /// @notice Gets the vault for a core pool
    /// @param marketFactory The market factory instance
    /// @param poolId The core pool ID
    /// @return The market vault instance
    function getVault(IMarketFactory marketFactory, PoolId poolId) internal view returns (IMarketVault) {
        return IMarketVault(marketFactory.corePoolToProxyHook(poolId));
    }

    /// @notice Gets the proxy hook address for a core pool
    /// @param marketFactory The market factory instance
    /// @param corePoolId The core pool ID
    /// @return The proxy hook address
    function getProxyHook(IMarketFactory marketFactory, PoolId corePoolId) internal view returns (address) {
        PoolId proxyPoolId = marketFactory.coreToProxy(corePoolId);
        return marketFactory.proxyToHook(proxyPoolId);
    }

    /// @notice Gets the proxy hook address from a core pool key
    /// @param marketFactory The market factory instance
    /// @param corePoolKey The core pool key
    /// @return The proxy hook address
    function getProxyHook(IMarketFactory marketFactory, PoolKey memory corePoolKey) internal view returns (address) {
        return getProxyHook(marketFactory, corePoolKey.toId());
    }

    /// @notice Gets the core hook address
    /// @param marketFactory The market factory instance
    /// @return The core hook address
    function getCoreHook(IMarketFactory marketFactory) internal view returns (address) {
        return marketFactory.coreHook();
    }

    /// @notice Checks if an address is a protocol bound
    /// @param marketFactory The market factory instance
    /// @param bound The address to check
    /// @return True if the address is a protocol bound
    function isBounds(IMarketFactory marketFactory, address bound) internal view returns (bool) {
        return marketFactory.bounds(bound);
    }

    /// @notice Validates that a token is part of a currency pair
    /// @param token The token to validate
    /// @param currencies The currency pair [token0, token1]
    /// @return The index of the token (0 or 1)
    function validateToken(address token, address[2] memory currencies) internal pure returns (uint8) {
        // Order-sensitive helper:
        // - If `currencies` are core/LCC-ordered, the result can safely be treated as a canonical `(0,1)` lane index.
        // - If `currencies` are proxy/underlying-ordered, the result is only meaningful in that proxy context and MUST
        //   not be used to index core-lane accounting (e.g. VTS `tokenIndex`).
        if (token == currencies[0]) {
            return 0;
        } else if (token == currencies[1]) {
            return 1;
        } else {
            revert Errors.InvalidSender();
        }
    }

    /// @notice Gets the token index for a token in a pool
    /// @param marketFactory The market factory instance
    /// @param poolId The core pool ID
    /// @param token The token address
    /// @return The token index (0 or 1)
    function getTokenIndex(IMarketFactory marketFactory, PoolId poolId, address token) internal view returns (uint8) {
        // This helper is intentionally tied to the CORE pool ordering because it reads `corePoolToCurrencyPair`.
        // It is currently unused in core protocol flows, but exists for future adoption (e.g. explicit lane selection).
        address[2] memory currencies = currenciesInMarket(marketFactory, poolId);
        return validateToken(token, currencies);
    }

    /// @notice Asserts that the caller is the core hook
    /// @param marketFactory The market factory instance
    /// @param sender The address of the sender
    function assertCoreHook(IMarketFactory marketFactory, address sender) internal view {
        address coreHook = marketFactory.coreHook();
        if (coreHook == address(0)) {
            revert Errors.InvalidAddress(coreHook);
        }
        if (sender != coreHook) revert Errors.InvalidSender();
    }
}

