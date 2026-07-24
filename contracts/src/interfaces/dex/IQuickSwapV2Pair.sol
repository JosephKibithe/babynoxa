// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {IV2Pair} from "./IV2Pair.sol";

/// @notice Canonical Uniswap V2 pair surface used by the QuickSwap graduation manager.
/// @dev QuickSwap pairs are stock Uniswap V2 pairs: liquidity is minted with the low-level
///      `mint(to)` after assets are transferred in, and stray balances can be flushed with `skim`.
interface IQuickSwapV2Pair is IV2Pair {
    function factory() external view returns (address);
    function mint(address to) external returns (uint256 liquidity);
    function skim(address to) external;
}
