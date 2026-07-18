// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title BabyNoxaConstants
/// @notice Confirmed economic constants for the BabyNoxa V1 curve model.
library BabyNoxaConstants {
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 internal constant CURVE_TOKEN_ALLOCATION = 800_000_000 ether;
    uint256 internal constant GRADUATION_TOKEN_RESERVE = 200_000_000 ether;
    uint256 internal constant CREATOR_INITIAL_BUY_CAP = 20_000_000 ether;
    uint256 internal constant MIN_GROSS_TRADE_VALUE = 200;

    uint256 internal constant INITIAL_VIRTUAL_BASE_RESERVE = 1.425 ether;
    uint256 internal constant INITIAL_VIRTUAL_TOKEN_RESERVE = 1_066_666_667 ether;
    uint256 internal constant TERMINAL_VIRTUAL_TOKEN_RESERVE = INITIAL_VIRTUAL_TOKEN_RESERVE - CURVE_TOKEN_ALLOCATION;

    uint16 internal constant TRADE_FEE_BPS = 100;
    uint16 internal constant GRADUATION_FEE_BPS = 1_000;
    uint16 internal constant LIQUIDITY_SHARE_BPS = 9_000;
}
