// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {BabyNoxaFactory} from "../src/BabyNoxaFactory.sol";
import {GraduationManagerV1} from "../src/GraduationManagerV1.sol";
import {IGraduationManager} from "../src/interfaces/IGraduationManager.sol";
import {IGuardedV2Factory} from "../src/interfaces/dex/IGuardedV2Factory.sol";
import {IV2Router02} from "../src/interfaces/dex/IV2Router02.sol";
import {BabyNoxaConstants} from "../src/libraries/BabyNoxaConstants.sol";
import {TestWrappedNative} from "../src/mocks/TestWrappedNative.sol";

/// @notice Deploys and wires the complete BabyNoxa V1 contract stack.
/// @dev Local Anvil deploys TestWrappedNative. Amoy requires WRAPPED_NATIVE to be supplied explicitly.
contract DeployBabyNoxa is Script {
    uint256 internal constant LOCAL_CHAIN_ID = 31_337;
    uint256 internal constant AMOY_CHAIN_ID = 80_002;

    struct Deployment {
        address factory;
        address manager;
        address v2Factory;
        address router;
        address wrappedNative;
        address owner;
        address treasury;
        address deployer;
    }

    error UnsupportedChain(uint256 chainId);
    error InvalidAddress(string field);
    error InvalidDeployment();
    error DeploymentFailed(string artifact);

    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        Deployment memory deployment;
        deployment.deployer = vm.addr(privateKey);
        deployment.owner = vm.envOr("BABYNOXA_OWNER", deployment.deployer);
        deployment.treasury = vm.envOr("BABYNOXA_TREASURY", deployment.deployer);
        _validateAccount("BABYNOXA_OWNER", deployment.owner);
        _validateAccount("BABYNOXA_TREASURY", deployment.treasury);
        if (deployment.owner != deployment.deployer) revert InvalidAddress("BABYNOXA_OWNER_MUST_BE_DEPLOYER");

        bool local = block.chainid == LOCAL_CHAIN_ID;
        if (!local && block.chainid != AMOY_CHAIN_ID) revert UnsupportedChain(block.chainid);
        if (!local) {
            deployment.wrappedNative = vm.envAddress("WRAPPED_NATIVE");
            if (deployment.wrappedNative == address(0) || deployment.wrappedNative.code.length == 0) {
                revert InvalidAddress("WRAPPED_NATIVE");
            }
        }

        uint256 firstNonce = vm.getNonce(deployment.deployer);
        address predictedFactory = vm.computeCreateAddress(deployment.deployer, firstNonce + (local ? 3 : 2));
        bytes memory guardedFactoryCode = vm.getCode("GuardedV2Factory.sol:GuardedV2Factory");
        bytes memory guardedRouterCode = vm.getCode("GuardedV2Router02.sol:GuardedV2Router02");

        vm.startBroadcast(privateKey);
        if (local) deployment.wrappedNative = address(new TestWrappedNative());
        deployment.v2Factory = _deploy(guardedFactoryCode, abi.encode(predictedFactory), "GuardedV2Factory");
        deployment.router =
            _deploy(guardedRouterCode, abi.encode(deployment.v2Factory, deployment.wrappedNative), "GuardedV2Router02");
        deployment.factory = address(
            new BabyNoxaFactory(
                deployment.owner,
                deployment.treasury,
                deployment.v2Factory,
                deployment.wrappedNative,
                BabyNoxaConstants.INITIAL_VIRTUAL_BASE_RESERVE,
                BabyNoxaConstants.INITIAL_VIRTUAL_TOKEN_RESERVE
            )
        );
        deployment.manager = address(
            new GraduationManagerV1(
                deployment.factory, deployment.v2Factory, deployment.router, deployment.wrappedNative
            )
        );
        BabyNoxaFactory(deployment.factory).setActiveGraduationManager(deployment.manager);
        vm.stopBroadcast();

        _validateDeployment(deployment, predictedFactory);
        _writeArtifact(deployment);
        console2.log("BabyNoxa factory", deployment.factory);
        console2.log("GraduationManagerV1", deployment.manager);
        console2.log("Guarded V2 factory", deployment.v2Factory);
        console2.log("Guarded Router02", deployment.router);
        console2.log("Wrapped native", deployment.wrappedNative);
        console2.log("Treasury beneficiary", deployment.treasury);
    }

    function _validateDeployment(Deployment memory deployment, address predictedFactory) private view {
        if (
            deployment.factory != predictedFactory || deployment.factory.code.length == 0
                || deployment.manager.code.length == 0 || deployment.v2Factory.code.length == 0
                || deployment.router.code.length == 0 || deployment.wrappedNative.code.length == 0
                || BabyNoxaFactory(deployment.factory).owner() != deployment.owner
                || BabyNoxaFactory(deployment.factory).defaultTreasury() != deployment.treasury
                || BabyNoxaFactory(deployment.factory).activeGraduationManager() != deployment.manager
                || BabyNoxaFactory(deployment.factory).v2Factory() != deployment.v2Factory
                || BabyNoxaFactory(deployment.factory).wrappedNative() != deployment.wrappedNative
                || IGuardedV2Factory(deployment.v2Factory).launchFactory() != deployment.factory
                || IGuardedV2Factory(deployment.v2Factory).feeTo() != address(0)
                || IGuardedV2Factory(deployment.v2Factory).feeToSetter() != address(0)
                || IV2Router02(deployment.router).factory() != deployment.v2Factory
                || IV2Router02(deployment.router).WETH() != deployment.wrappedNative
                || IGraduationManager(deployment.manager).factory() != deployment.factory
                || IGraduationManager(deployment.manager).v2Factory() != deployment.v2Factory
                || IGraduationManager(deployment.manager).router() != deployment.router
                || IGraduationManager(deployment.manager).wrappedNative() != deployment.wrappedNative
        ) revert InvalidDeployment();
    }

    function _validateAccount(string memory field, address account) private pure {
        if (account == address(0)) revert InvalidAddress(field);
    }

    function _deploy(bytes memory creationCode, bytes memory constructorArgs, string memory artifact)
        private
        returns (address deployed)
    {
        bytes memory initCode = bytes.concat(creationCode, constructorArgs);
        assembly ("memory-safe") {
            deployed := create(0, add(initCode, 0x20), mload(initCode))
        }
        if (deployed == address(0)) revert DeploymentFailed(artifact);
    }

    function _writeArtifact(Deployment memory deployment) private {
        string memory object = "deployment";
        vm.serializeUint(object, "chainId", block.chainid);
        vm.serializeAddress(object, "deployer", deployment.deployer);
        vm.serializeAddress(object, "owner", deployment.owner);
        vm.serializeAddress(object, "treasury", deployment.treasury);
        vm.serializeAddress(object, "wrappedNative", deployment.wrappedNative);
        vm.serializeAddress(object, "guardedV2Factory", deployment.v2Factory);
        vm.serializeAddress(object, "guardedV2Router02", deployment.router);
        vm.serializeAddress(object, "babyNoxaFactory", deployment.factory);
        string memory json = vm.serializeAddress(object, "graduationManagerV1", deployment.manager);
        string memory defaultPath = string.concat("deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(json, vm.envOr("DEPLOYMENT_OUTPUT", defaultPath));
    }
}
