// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {GraduationParams, GraduationResult} from "../types/BabyNoxaTypes.sol";

/// @title IGraduationManager
/// @notice Versioned, snapshotted boundary for atomic curve-to-AMM graduation.
interface IGraduationManager {
    event GraduationExecuted(
        address indexed token,
        address indexed curve,
        address indexed officialPair,
        uint256 treasuryAllocation,
        uint256 liquidityBase,
        uint256 liquidityTokens,
        uint256 burnedTokens
    );
    event LiquidityCreated(
        address indexed token, address indexed officialPair, uint256 baseAmount, uint256 tokenAmount, uint256 liquidity
    );
    event LiquidityBurned(
        address indexed token, address indexed officialPair, address indexed burnAddress, uint256 liquidity
    );
    event GraduationTokensBurned(address indexed token, address indexed curve, uint256 amount);
    event UnsolicitedAssetSentToBurn(address indexed asset, uint256 amount);

    function factory() external view returns (address);
    function v2Factory() external view returns (address);
    function router() external view returns (address);
    function wrappedNative() external view returns (address);
    function burnAddress() external view returns (address);

    /// @dev Callable only by a registered curve whose snapshotted manager is this contract.
    function graduate(GraduationParams calldata params) external payable returns (GraduationResult memory result);
}
