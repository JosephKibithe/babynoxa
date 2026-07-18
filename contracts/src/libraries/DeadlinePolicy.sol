// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title DeadlinePolicy
/// @notice Shared absolute-timestamp deadline rule for BabyNoxa V1 transactions.
library DeadlinePolicy {
    error DeadlineExpired(uint256 deadline, uint256 currentTimestamp);

    /// @dev Equality is valid: a call expires only after its absolute Unix timestamp deadline.
    function enforce(uint256 deadline) internal view {
        if (block.timestamp > deadline) revert DeadlineExpired(deadline, block.timestamp);
    }
}
