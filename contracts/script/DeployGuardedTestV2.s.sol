// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IGuardedV2Factory} from "../src/interfaces/dex/IGuardedV2Factory.sol";
import {IV2Router02} from "../src/interfaces/dex/IV2Router02.sol";
import {TestWrappedNative} from "../src/mocks/TestWrappedNative.sol";

/// @notice Deploys the Phase 4 guarded V2 stack for local Anvil testing.
/// @dev The broadcasting EOA is the temporary local launch authority. Production deployment must
///      instead pass the deployed BabyNoxaFactory address to GuardedV2Factory.
contract DeployGuardedTestV2 is Script {
    bytes32 internal constant GUARDED_PAIR_INIT_CODE_HASH =
        0x4e1cd411c31bb2545eccb2defb64f19d44df82a6f3dd81fa61e200b4b0a3fa2a;

    error DeploymentFailed(string artifact);
    error PairInitCodeHashMismatch(bytes32 expected, bytes32 actual);
    error InvalidDeployment();

    function run() external returns (address factory, address router, address wrappedNative) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address localLaunchAuthority = vm.addr(deployerPrivateKey);

        bytes memory factoryCreationCode = vm.getCode("GuardedV2Factory.sol:GuardedV2Factory");
        bytes memory pairCreationCode = vm.getCode("GuardedV2Pair.sol:GuardedV2Pair");
        bytes memory routerCreationCode = vm.getCode("GuardedV2Router02.sol:GuardedV2Router02");

        bytes32 actualPairInitCodeHash = keccak256(pairCreationCode);
        if (actualPairInitCodeHash != GUARDED_PAIR_INIT_CODE_HASH) {
            revert PairInitCodeHashMismatch(GUARDED_PAIR_INIT_CODE_HASH, actualPairInitCodeHash);
        }

        vm.startBroadcast(deployerPrivateKey);
        wrappedNative = address(new TestWrappedNative());
        factory = _deploy(factoryCreationCode, abi.encode(localLaunchAuthority), "GuardedV2Factory");
        router = _deploy(routerCreationCode, abi.encode(factory, wrappedNative), "GuardedV2Router02");
        vm.stopBroadcast();

        if (
            factory.code.length == 0 || router.code.length == 0 || wrappedNative.code.length == 0
                || IGuardedV2Factory(factory).launchFactory() != localLaunchAuthority
                || IGuardedV2Factory(factory).feeTo() != address(0)
                || IGuardedV2Factory(factory).feeToSetter() != address(0) || IV2Router02(router).factory() != factory
                || IV2Router02(router).WETH() != wrappedNative
        ) revert InvalidDeployment();

        console2.log("Guarded V2 factory", factory);
        console2.log("Guarded Router02", router);
        console2.log("Test wrapped native", wrappedNative);
        console2.log("Temporary local launch authority", localLaunchAuthority);
        console2.log("Optional protocol fee permanently disabled");
    }

    function _deploy(bytes memory creationCode, bytes memory constructorArgs, string memory artifact)
        internal
        returns (address deployed)
    {
        bytes memory initCode = bytes.concat(creationCode, constructorArgs);
        assembly ("memory-safe") {
            deployed := create(0, add(initCode, 0x20), mload(initCode))
        }
        if (deployed == address(0)) revert DeploymentFailed(artifact);
    }
}
