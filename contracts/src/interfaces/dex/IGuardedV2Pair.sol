// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IV2Pair} from "./IV2Pair.sol";

interface IGuardedV2Pair is IV2Pair {
    function LP_BURN_ADDRESS() external pure returns (address);
    function factory() external view returns (address);
    function bootstrapManager() external view returns (address);
    function bootstrapLocked() external view returns (bool);
    function bootstrapMint(uint256 amount0, uint256 amount1) external returns (uint256 liquidity);
    function mint(address to) external returns (uint256 liquidity);
    function burn(address to) external returns (uint256 amount0, uint256 amount1);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function skim(address to) external;
}
