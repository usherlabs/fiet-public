// StubContract.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;


contract ALM {
    // LiquidityVerifierStub verifier;
    // define currency VRL mapping
    mapping(bytes32 => uint256) VRL; //locked

    constructor() {
    }

    /**
     * @notice Verifies and Signals liquidty
     * @dev Called by the custodian to signal liquidity only after staking
     * @param proof The proof to be verified
     * @param currency The currency being deposited
     * @param _recipient The recipient of the crypto equivalent of the deposit
     */
    function depositFiat(
        string calldata proof,
        bytes32 currency,
        address _recipient
    ) external {
        // verify the proof by calling the verifier contract
        // uint256 value = verifier.verify(proof);

        // signal VRL
        // VRL[currency] += value;

        // perform the swap and send the corresponding USD to the user of interest
    }

    /**
     * @notice Gets the available VRL for a given custodian
     * @dev Called by the custodian to signal liquidity after staking
     * @param currencyHash The currency being deposited
     */
    function getLiquidityDepth(
        bytes32 currencyHash
    ) public view returns (uint256) {
        return VRL[currencyHash];
    }

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
    ) external {
        // reduce LD and assign user some VRL
    }
}
