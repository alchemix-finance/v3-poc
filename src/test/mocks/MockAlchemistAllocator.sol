// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AlchemistAllocator} from "../../AlchemistAllocator.sol";

contract MockAlchemistAllocator is AlchemistAllocator {
    constructor(address _myt, address _admin, address _operator) AlchemistAllocator(_myt, _admin, _operator) {}
}
