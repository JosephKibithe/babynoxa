// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Wrapped native asset for local and public-testnet V2 deployments.
/// @dev This is test infrastructure and must not be reused as a production-chain wrapped-native token.
contract TestWrappedNative is ERC20, ReentrancyGuard {
    error NativeTransferFailed(address recipient, uint256 amount);

    event Deposit(address indexed account, uint256 amount);
    event Withdrawal(address indexed account, uint256 amount);

    constructor() ERC20("BabyNoxa Test Wrapped Native", "tWNATIVE") {}

    receive() external payable {
        deposit();
    }

    function deposit() public payable {
        _mint(msg.sender, msg.value);
        emit Deposit(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external nonReentrant {
        _burn(msg.sender, amount);

        (bool success,) = msg.sender.call{value: amount}("");
        if (!success) revert NativeTransferFailed(msg.sender, amount);

        emit Withdrawal(msg.sender, amount);
    }
}
