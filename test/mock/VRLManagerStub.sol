// StubContract.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

contract VRLManagerStub {

    // define the unlocked/available balance of the user i.e user => currency => amount
    mapping(address => mapping(bytes32 => uint256)) balanceOf; 
    constructor() {
    }

    /**
     * @notice Verifies and Signals liquidty
     * @dev Called to signal verified liquidity only after staking
     * @param amount The amount being deposited
     * @param currency The currency being deposited
     * @param owner The owner of the deposit
     */
    function depositVerifiedFiat(
        address owner,
        bytes32 currency,
        uint256 amount
    ) external {
        // create a deposit for the user to represent a VRL unlocked position for a particular currencyc
        // struct needs user and amount locked
        balanceOf[owner][currency] += amount;
    }

    // /**
    //  * @notice Gets the available VRL for a given custodian
    //  * @dev Called by the custodian to signal liquidity after staking
    //  * @param currencyHash The currency being deposited
    //  */
    // function getLiquidityDepth(
    //     bytes32 currencyHash
    // ) public view returns (uint256) {
    //     return VRL[currencyHash];
    // }

    // /**
    //  * @notice Removes some locked VRL and assigns to the recipient
    //  * @param recipient The recipient of this withdrawal
    //  * @param currency The currency being withdrawn
    //  * @param amount The amount being withdrawn
    //  */
    // function withdraw(
    //     address recipient,
    //     bytes32 currency,
    //     uint256 amount
    // ) external {
    //     // reduce LD and assign user some VRL
    // }
}
