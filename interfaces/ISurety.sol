// ISuretyStub.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

interface ISurety {
    /**
     * @notice Verifies and signals liquidity
     * @dev Called by the custodian to signal liquidity after staking
     * @param proof The proof to be verified
     * @param currency The currency being deposited
     * @param recipient The recipient of the crypto equivalent of the deposit
     */
    function depositFiat(
        string calldata proof,
        bytes32 currency,
        address recipient
    ) external;

    /**
     * @notice Gets the available VRL for a given custodian
     * @dev Called by the custodian to signal liquidity after staking
     * @param currencyHash The currency in question
     */
    function getLiquidityDepth(
        bytes32 currencyHash
    ) external view returns (uint256);

    /**
     * @notice Removes some locked VRL and assigns to the recipient
     * @param recipient The recipient of this withdrawal
     * @param currency The currency being withdrawn
     * @param amount The amount being withdrawn
     */
    function withdraw(
        address recipient,
        bytes32 currency,
        uint256 amount
    ) external;
}
