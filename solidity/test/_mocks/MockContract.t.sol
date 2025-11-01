// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";

contract MockContract is Ownable {
    constructor() Ownable(msg.sender) {}

    function addTwoToNumber(uint256 _number) public view onlyOwner returns (uint256 number) {
        number = _number + 2;
    }
}
