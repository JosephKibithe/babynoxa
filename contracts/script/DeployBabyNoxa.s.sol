// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {BabyNoxaFactory} from "../src/BabyNoxaFactory.sol";
import {BabyNoxaFactoryQS} from "../src/BabyNoxaFactoryQS.sol";
import {GraduationManagerV1} from "../src/GraduationManagerV1.sol";
import {GraduationManagerV2} from "../src/GraduationManagerV2.sol";
import {IBabyNoxaFactory} from "../src/interfaces/IBabyNoxaFactory.sol";
import {IGraduationManager} from "../src/interfaces/IGraduationManager.sol";
import {IGuardedV2Factory} from "../src/interfaces/dex/IGuardedV2Factory.sol";
import {IV2Router02} from "../src/interfaces/dex/IV2Router02.sol";
import {BabyNoxaConstants} from "../src/libraries/BabyNoxaConstants.sol";
import {TestWrappedNative} from "../src/mocks/TestWrappedNative.sol";

/// @notice Deploys and wires the complete BabyNoxa V1 contract stack.
/// @dev Local Anvil always deploys TestWrappedNative. Amoy can explicitly deploy the same
///      test-only wrapper with DEPLOY_TEST_WRAPPED_NATIVE=true, or use a supplied WRAPPED_NATIVE.
///      Polygon mainnet is pinned to canonical WPOL and requires an explicit unapproved-test acknowledgement.
contract DeployBabyNoxa is Script {
    uint256 internal constant LOCAL_CHAIN_ID = 31_337;
    uint256 internal constant AMOY_CHAIN_ID = 80_002;
    uint256 internal constant POLYGON_MAINNET_CHAIN_ID = 137;
    address internal constant POLYGON_WPOL = 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270;
    // Canonical QuickSwap V2 (stock Uniswap V2) deployment on Polygon mainnet.
    address internal constant QUICKSWAP_V2_FACTORY = 0x5757371414417b8C6CAad45bAeF941aBc7d3Ab32;
    address internal constant QUICKSWAP_V2_ROUTER = 0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff;
    string internal constant MAINNET_TEST_ACKNOWLEDGEMENT = "I_ACKNOWLEDGE_UNAUDITED_MAINNET_TEST";

    struct Deployment {
        address factory;
        address manager;
        address v2Factory;
        address router;
        address wrappedNative;
        address owner;
        address treasury;
        address deployer;
        bool testWrappedNative;
        bool unapprovedMainnetTest;
        bool quickSwap;
    }

    error UnsupportedChain(uint256 chainId);
    error InvalidAddress(string field);
    error InvalidDeployment();
    error DeploymentFailed(string artifact);
    error MainnetTestAcknowledgementRequired();

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
        bool amoy = block.chainid == AMOY_CHAIN_ID;
        deployment.unapprovedMainnetTest = block.chainid == POLYGON_MAINNET_CHAIN_ID;
        // Polygon mainnet graduates onto QuickSwap so tokens are discoverable on QuickSwap/DexScreener.
        deployment.quickSwap = deployment.unapprovedMainnetTest;
        if (!local && !amoy && !deployment.unapprovedMainnetTest) revert UnsupportedChain(block.chainid);

        bool deployTestWrappedNative = vm.envOr("DEPLOY_TEST_WRAPPED_NATIVE", false);
        if (deployment.unapprovedMainnetTest) {
            if (deployTestWrappedNative) revert InvalidAddress("TEST_WRAPPED_NATIVE_FORBIDDEN_ON_MAINNET");
            _requireMainnetTestAcknowledgement();
            deployment.wrappedNative = POLYGON_WPOL;
            _validatePolygonWpol();
        } else {
            deployment.testWrappedNative = local || deployTestWrappedNative;
        }
        if (!deployment.unapprovedMainnetTest && !deployment.testWrappedNative) {
            deployment.wrappedNative = vm.envAddress("WRAPPED_NATIVE");
            if (deployment.wrappedNative == address(0) || deployment.wrappedNative.code.length == 0) {
                revert InvalidAddress("WRAPPED_NATIVE");
            }
        }

        if (deployment.quickSwap) {
            _deployQuickSwapStack(deployment, privateKey);
            _validateDeploymentQS(deployment);
            _writeArtifact(deployment);
            console2.log("BabyNoxa factory (QuickSwap)", deployment.factory);
            console2.log("GraduationManagerV2", deployment.manager);
            console2.log("QuickSwap V2 factory", deployment.v2Factory);
            console2.log("QuickSwap V2 router", deployment.router);
            console2.log("Wrapped native", deployment.wrappedNative);
            console2.log("Treasury beneficiary", deployment.treasury);
            return;
        }

        uint256 firstNonce = vm.getNonce(deployment.deployer);
        address predictedFactory =
            vm.computeCreateAddress(deployment.deployer, firstNonce + (deployment.testWrappedNative ? 3 : 2));
        bytes memory guardedFactoryCode = vm.getCode("GuardedV2Factory.sol:GuardedV2Factory");
        bytes memory guardedRouterCode = vm.getCode("GuardedV2Router02.sol:GuardedV2Router02");

        vm.startBroadcast(privateKey);
        if (deployment.testWrappedNative) deployment.wrappedNative = address(new TestWrappedNative());
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

    /// @dev Polygon mainnet path: wire the BabyNoxa curve stack onto the canonical QuickSwap V2 deployment.
    function _deployQuickSwapStack(Deployment memory deployment, uint256 privateKey) private {
        deployment.v2Factory = vm.envOr("QUICKSWAP_V2_FACTORY", QUICKSWAP_V2_FACTORY);
        deployment.router = vm.envOr("QUICKSWAP_V2_ROUTER", QUICKSWAP_V2_ROUTER);
        if (deployment.v2Factory.code.length == 0 || deployment.router.code.length == 0) {
            revert InvalidAddress("QUICKSWAP_VENUE_CODE");
        }
        if (
            IV2Router02(deployment.router).factory() != deployment.v2Factory
                || IV2Router02(deployment.router).WETH() != deployment.wrappedNative
        ) revert InvalidAddress("QUICKSWAP_ROUTER_TOPOLOGY");

        vm.startBroadcast(privateKey);
        deployment.factory = address(
            new BabyNoxaFactoryQS(
                deployment.owner,
                deployment.treasury,
                deployment.v2Factory,
                deployment.wrappedNative,
                BabyNoxaConstants.INITIAL_VIRTUAL_BASE_RESERVE,
                BabyNoxaConstants.INITIAL_VIRTUAL_TOKEN_RESERVE
            )
        );
        deployment.manager = address(
            new GraduationManagerV2(
                deployment.factory, deployment.v2Factory, deployment.router, deployment.wrappedNative
            )
        );
        IBabyNoxaFactory(deployment.factory).setActiveGraduationManager(deployment.manager);
        vm.stopBroadcast();
    }

    function _validateDeploymentQS(Deployment memory deployment) private view {
        if (
            deployment.factory.code.length == 0 || deployment.manager.code.length == 0
                || deployment.v2Factory.code.length == 0 || deployment.router.code.length == 0
                || deployment.wrappedNative.code.length == 0
                || IBabyNoxaFactory(deployment.factory).owner() != deployment.owner
                || IBabyNoxaFactory(deployment.factory).defaultTreasury() != deployment.treasury
                || IBabyNoxaFactory(deployment.factory).activeGraduationManager() != deployment.manager
                || IBabyNoxaFactory(deployment.factory).v2Factory() != deployment.v2Factory
                || IBabyNoxaFactory(deployment.factory).wrappedNative() != deployment.wrappedNative
                || IV2Router02(deployment.router).factory() != deployment.v2Factory
                || IV2Router02(deployment.router).WETH() != deployment.wrappedNative
                || IGraduationManager(deployment.manager).factory() != deployment.factory
                || IGraduationManager(deployment.manager).v2Factory() != deployment.v2Factory
                || IGraduationManager(deployment.manager).router() != deployment.router
                || IGraduationManager(deployment.manager).wrappedNative() != deployment.wrappedNative
        ) revert InvalidDeployment();
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

    function _requireMainnetTestAcknowledgement() private view {
        string memory acknowledgement = vm.envOr("MAINNET_TEST_ACK", string(""));
        if (keccak256(bytes(acknowledgement)) != keccak256(bytes(MAINNET_TEST_ACKNOWLEDGEMENT))) {
            revert MainnetTestAcknowledgementRequired();
        }
    }

    function _validatePolygonWpol() private view {
        if (POLYGON_WPOL.code.length == 0) revert InvalidAddress("POLYGON_WPOL");
        (bool nameSuccess, bytes memory nameResult) = POLYGON_WPOL.staticcall(abi.encodeWithSignature("name()"));
        (bool symbolSuccess, bytes memory symbolResult) = POLYGON_WPOL.staticcall(abi.encodeWithSignature("symbol()"));
        if (
            !nameSuccess || !symbolSuccess
                || keccak256(bytes(abi.decode(nameResult, (string))))
                    != keccak256(bytes("Wrapped Polygon Ecosystem Token"))
                || keccak256(bytes(abi.decode(symbolResult, (string)))) != keccak256(bytes("WPOL"))
        ) revert InvalidAddress("POLYGON_WPOL_METADATA");
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
        vm.serializeBool(object, "unapprovedMainnetTest", deployment.unapprovedMainnetTest);
        vm.serializeString(
            object,
            "releaseStatus",
            deployment.unapprovedMainnetTest ? "UNAPPROVED_MAINNET_TEST" : "NON_PRODUCTION_DEPLOYMENT"
        );
        vm.serializeBool(object, "testWrappedNative", deployment.testWrappedNative);
        vm.serializeString(object, "graduationVenue", deployment.quickSwap ? "QUICKSWAP_V2" : "GUARDED_V2");
        vm.serializeAddress(object, "wrappedNative", deployment.wrappedNative);
        vm.serializeAddress(
            object, deployment.quickSwap ? "quickSwapV2Factory" : "guardedV2Factory", deployment.v2Factory
        );
        vm.serializeAddress(
            object, deployment.quickSwap ? "quickSwapV2Router02" : "guardedV2Router02", deployment.router
        );
        vm.serializeAddress(object, "babyNoxaFactory", deployment.factory);
        string memory json = vm.serializeAddress(
            object, deployment.quickSwap ? "graduationManagerV2" : "graduationManagerV1", deployment.manager
        );
        string memory defaultPath = string.concat("deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(json, vm.envOr("DEPLOYMENT_OUTPUT", defaultPath));
    }
}
