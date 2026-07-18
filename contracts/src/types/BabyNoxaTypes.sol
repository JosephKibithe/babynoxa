// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

enum LaunchState {
    Created,
    Trading,
    GraduationReady,
    Graduated
}

/// @notice Creator-provided inputs for one atomic factory launch.
struct CreateLaunchParams {
    string name;
    string symbol;
    string metadataURI;
    bytes32 metadataHash;
    uint256 minimumCreatorTokensOut;
    uint256 deadline;
}

/// @notice Immutable addresses and curve geometry snapshotted for a launch.
struct LaunchConfig {
    uint256 launchId;
    address creator;
    address token;
    address treasury;
    address graduationManager;
    address officialPair;
    uint256 initialVirtualBaseReserve;
    uint256 initialVirtualTokenReserve;
}

/// @notice Factory registry record. Lifecycle state remains authoritative on the curve.
struct LaunchRecord {
    uint256 launchId;
    address creator;
    address token;
    address curve;
    address officialPair;
    address treasury;
    address graduationManager;
    bytes32 metadataHash;
    string metadataURI;
}

/// @notice Terminal curve values passed atomically to the snapshotted graduation manager.
struct GraduationParams {
    address token;
    address officialPair;
    uint256 realBaseReserve;
    uint256 terminalVirtualBaseReserve;
    uint256 terminalVirtualTokenReserve;
    uint256 graduationTokenReserve;
    uint256 minimumBaseForLiquidity;
    uint256 minimumTokensForLiquidity;
    uint256 deadline;
}

/// @notice Assets consumed and destroyed by an atomic V1 graduation.
struct GraduationResult {
    address officialPair;
    uint256 treasuryAllocation;
    uint256 liquidityBase;
    uint256 liquidityTokens;
    uint256 burnedTokens;
    uint256 burnedLp;
}
