// StubContract.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";

contract VRLManagerStub {
    uint256 lockedVRL;
    address hookContract;
    // define the unlocked/available balance of the user i.e user => currency => amount
    mapping(address => mapping(bytes32 => uint256)) public balanceOf;

    constructor() {}

    /**
     * @notice Verifies and Signals liquidty
     * @dev Called to signal verified liquidity only after staking
     *      can only be called by liquidity verifier
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

    function getUserCurrencyVRL(
        address owner,
        bytes32 currency
    ) external view returns (uint256) {
        return balanceOf[owner][currency];
    }

    // withdraw VRL from a previously made deposit by the user
    function withdrawVRL(
        address owner,
        bytes32 currencyHash,
        uint256 delta,
        bool lock
    ) public returns (uint256) {
        // this function should only be callable by the HOOK
        // require(msg.sender == hookContract, "INVALID_CALLER");

        // check if the provided owner has some VRL
        require(
            balanceOf[owner][currencyHash] >= delta,
            "INSUFFICIENT_BALANCE"
        );

        // if they have enough, move the requested amount into locked VRL ifi there is a locked option
        lockedVRL += lock ? delta : 0;
        balanceOf[owner][currencyHash] -= delta;

        return delta;
    }

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
    ) external returns (uint256) {
        // create a deposit for the user to represent a VRL unlocked position for a particular currencyc
        // struct needs user and amount locked
        lockedVRL -= delta;
        balanceOf[owner][currency] += delta;
        return delta;
    }

    /**
     * @notice returns the volatility fee of a particular currency in e6
     * @dev calculates the volatility
     * @param currency The currency we want to get the volitility of
     */
    function getVolatilityFee(bytes32 currency) external pure returns (uint256) {
        return 50000; // it amounts to 5%
    }
}
