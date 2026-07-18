// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IV2Pair {
    function MINIMUM_LIQUIDITY() external pure returns (uint256);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function sync() external;
}
