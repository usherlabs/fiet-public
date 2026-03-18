// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * @title IVaultCoreActionHandler
 * @notice Factory-scoped handler surface for ingress settlement and direct-core follow-up.
 * @dev Methods are intentionally broad but contract-scoped: they are not general router entrypoints and
 *      must only be called by `MarketFactory`.
 */
interface IVaultCoreActionHandler {
    /**
     * @notice Handles wrapped ingress observed on LCC -> PoolManager transfer paths.
     * @param lcc The LCC lane where wrapped ingress occurred.
     * @param wrappedAmount Wrapped-only portion eligible for Hub -> vault settlement.
     */
    function handleIngress(address lcc, uint256 wrappedAmount) external;

    /**
     * @notice Handles a direct core swap follow-up for this vault.
     * @param lccTokenIn The input-side LCC lane for the direct swap.
     */
    function handleSwap(address lccTokenIn) external;

    /**
     * @notice Handles a direct core liquidity-add follow-up for this vault.
     */
    function handleAddLiquidity() external;
}

