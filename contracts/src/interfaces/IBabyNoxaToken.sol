// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title IBabyNoxaToken
/// @notice Fixed-supply, tax-free token boundary for a BabyNoxa launch.
/// @dev V1 deliberately exposes no mint, pause, blacklist, confiscation, or tax-management selectors.
interface IBabyNoxaToken is IERC20Metadata {
    /// @notice Permanently destroys tokens owned by the caller.
    function burn(uint256 amount) external;
}
