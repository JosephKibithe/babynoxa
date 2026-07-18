// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BabyNoxaToken} from "./BabyNoxaToken.sol";
import {BondingCurve} from "./BondingCurve.sol";
import {LaunchConfig} from "./types/BabyNoxaTypes.sol";

/// @title BabyNoxaLaunchDeployer
/// @notice Immutable factory-owned constructor helper that keeps deployment bytecode out of factory runtime.
/// @dev This is not an upgrade path or proxy. It can only perform ordinary constructor deployments for its factory.
contract BabyNoxaLaunchDeployer {
    address public immutable factory;

    error FactoryOnly(address caller);
    error ZeroFactory();

    constructor(address factory_) {
        if (factory_ == address(0)) revert ZeroFactory();
        factory = factory_;
    }

    function deployToken(string calldata name, string calldata symbol) external returns (BabyNoxaToken token) {
        _requireFactory();
        token = new BabyNoxaToken(name, symbol, factory);
    }

    function deployCurve(LaunchConfig calldata config) external returns (BondingCurve curve) {
        _requireFactory();
        curve = new BondingCurve(config, factory);
    }

    function _requireFactory() private view {
        if (msg.sender != factory) revert FactoryOnly(msg.sender);
    }
}
