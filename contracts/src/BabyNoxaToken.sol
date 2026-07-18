// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IBabyNoxaToken} from "./interfaces/IBabyNoxaToken.sol";
import {BabyNoxaConstants} from "./libraries/BabyNoxaConstants.sol";

/// @title BabyNoxaToken
/// @notice Fixed-supply, tax-free ERC-20 deployed once for a BabyNoxa launch.
/// @dev The constructor performs the only mint. Burning is limited to the caller's own balance.
contract BabyNoxaToken is ERC20, IBabyNoxaToken {
    error ZeroSupplyRecipient();

    constructor(string memory name_, string memory symbol_, address initialSupplyRecipient) ERC20(name_, symbol_) {
        if (initialSupplyRecipient == address(0)) revert ZeroSupplyRecipient();
        _mint(initialSupplyRecipient, BabyNoxaConstants.TOTAL_SUPPLY);
    }

    /// @inheritdoc IBabyNoxaToken
    function burn(uint256 amount) external override {
        _burn(msg.sender, amount);
    }
}
