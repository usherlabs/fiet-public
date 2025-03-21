// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

// Interface for VRLManagerStub
interface IVRLManager {
    /**
     * @notice Verifies and Signals liquidity
     * @dev Called to signal verified liquidity only after staking
     * @param owner The owner of the deposit
     * @param currency The currency being deposited
     * @param amount The amount being deposited
     */
    function depositVerifiedFiat(
        address owner,
        bytes32 currency,
        uint256 amount
    ) external;

    /**
     * @notice Retrieves the VRL balance of a user for a specific currency
     * @param owner The address of the user
     * @param currency The currency hash to query
     * @return The amount of VRL for the specified currency
     */
    function getUserCurrencyVRL(
        address owner,
        bytes32 currency
    ) external view returns (uint256);

    /**
     * @notice Withdraws VRL from a previously made deposit by the user
     * @param owner The address of the owner whose VRL is being withdrawn
     * @param currencyHash The hash of the currency to withdraw from
     * @param delta The amount of VRL to withdraw
     * @return The amount withdrawn
     */
    function withdrawVRL(
        address owner,
        bytes32 currencyHash,
        uint256 delta,
        bool lock
    ) external returns (uint256);

    /**
     * @notice Moves delta from the LD to a user's balance record
     * @dev Called to signal verified liquidity only after staking
     *      can only be called by hook contract
     * @param owner The owner of the deposit
     * @param currency The currency being deposited
     * @param delta The amount being deposited
     */
    function unlockLiquidityDelta(
        address owner,
        bytes32 currency,
        uint256 delta
    ) external returns (uint256);

    /**
     * @notice returns the volatility fee of a particular currency in e6
     * @dev calculates the volatility
     * @param currency The currency we want to get the volitility of
     */
    function getVolatilityFee(bytes32 currency) external returns (uint256);
}
