// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";

contract MockContract is Ownable {
    constructor() Ownable(msg.sender) {}

    function addTwoToNumber(uint256 _number) public view onlyOwner returns (uint256 number) {
        number = _number + 2;
    }
}
