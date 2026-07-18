// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IV2Factory} from "./IV2Factory.sol";

interface IGuardedV2Factory is IV2Factory {
    function launchFactory() external view returns (address);
    function createPair(address tokenA, address tokenB, address bootstrapManager) external returns (address pair);
}
