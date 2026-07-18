// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CreateLaunchParams, LaunchRecord} from "../types/BabyNoxaTypes.sol";

/// @title IBabyNoxaFactory
/// @notice Atomic launch deployment and immutable launch-registry boundary.
interface IBabyNoxaFactory {
    event LaunchCreated(
        uint256 indexed launchId,
        address indexed creator,
        address indexed token,
        address curve,
        address officialPair,
        address treasury,
        address graduationManager
    );
    event MetadataCommitted(
        uint256 indexed launchId, address indexed token, bytes32 indexed metadataHash, string metadataURI
    );
    event DefaultTreasuryUpdated(address indexed previousTreasury, address indexed newTreasury);
    event GraduationManagerActivated(address indexed previousManager, address indexed newManager);

    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;

    function defaultTreasury() external view returns (address);
    function activeGraduationManager() external view returns (address);
    function v2Factory() external view returns (address);
    function wrappedNative() external view returns (address);
    function launchCount() external view returns (uint256);

    function createLaunch(CreateLaunchParams calldata params) external payable returns (LaunchRecord memory record);
    function getLaunch(uint256 launchId) external view returns (LaunchRecord memory record);
    function launchIdOfToken(address token) external view returns (uint256 launchId);
    function launchIdOfCurve(address curve) external view returns (uint256 launchId);
    function isRegisteredCurve(address curve) external view returns (bool);

    /// @dev Updates only the snapshot used by launches created after this transaction.
    function setDefaultTreasury(address newTreasury) external;

    /// @dev Updates only the snapshot used by launches created after this transaction.
    function setActiveGraduationManager(address newManager) external;
}
