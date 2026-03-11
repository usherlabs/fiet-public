// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * @title IVaultCoreActionHandler
 * @notice Factory-scoped handler surface for reconciled direct-core actions.
 * @dev Methods are intentionally broad (`handleAddLiquidity`, `handleSwap`) but contract-scoped:
 *      they are not general router entrypoints and must only be called by `MarketFactory` after sequencing.
 */
interface IVaultCoreActionHandler {
    /**
     * @notice Handles a reconciled direct core swap reaction for this vault.
     * @param lccTokenIn The LCC lane whose underlying enters from Hub to vault.
     * @param wrappedAmountIn Wrapped-only portion eligible for Hub -> vault settlement.
     */
    function handleSwap(address lccTokenIn, uint256 wrappedAmountIn) external;

    /**
     * @notice Handles a reconciled direct core liquidity-add reaction for this vault.
     * @param wrappedAmount0 Wrapped-only portion for lane token0.
     * @param wrappedAmount1 Wrapped-only portion for lane token1.
     */
    function handleAddLiquidity(uint256 wrappedAmount0, uint256 wrappedAmount1) external;
}

