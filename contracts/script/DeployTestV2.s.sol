// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IV2Factory} from "../src/interfaces/dex/IV2Factory.sol";
import {IV2Router02} from "../src/interfaces/dex/IV2Router02.sol";
import {TestWrappedNative} from "../src/mocks/TestWrappedNative.sol";

contract DeployTestV2 is Script {
    bytes32 internal constant PINNED_PAIR_INIT_CODE_HASH =
        0xd92ee51a660a9709fb1c23d4105ba4d858e55c93974dbafeadb98052027833c0;

    error DeploymentFailed(string artifact);
    error PairInitCodeHashMismatch(bytes32 expected, bytes32 actual);
    error InvalidDeployment();

    function run() external returns (address factory, address router, address wrappedNative) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address feeToSetter = address(0);

        bytes memory factoryCreationCode = vm.getCode("UniswapV2Factory.sol:UniswapV2Factory");
        bytes memory pairCreationCode = vm.getCode("UniswapV2Pair.sol:UniswapV2Pair");
        bytes memory routerCreationCode = vm.getCode("UniswapV2Router02.sol:UniswapV2Router02");

        bytes32 actualPairInitCodeHash = keccak256(pairCreationCode);
        if (actualPairInitCodeHash != PINNED_PAIR_INIT_CODE_HASH) {
            revert PairInitCodeHashMismatch(PINNED_PAIR_INIT_CODE_HASH, actualPairInitCodeHash);
        }

        vm.startBroadcast(deployerPrivateKey);
        wrappedNative = address(new TestWrappedNative());
        factory = _deploy(factoryCreationCode, abi.encode(feeToSetter), "UniswapV2Factory");
        router = _deploy(routerCreationCode, abi.encode(factory, wrappedNative), "UniswapV2Router02");
        vm.stopBroadcast();

        if (
            factory.code.length == 0 || router.code.length == 0 || wrappedNative.code.length == 0
                || IV2Factory(factory).feeToSetter() != feeToSetter || IV2Factory(factory).feeTo() != address(0)
                || IV2Router02(router).factory() != factory || IV2Router02(router).WETH() != wrappedNative
        ) revert InvalidDeployment();

        console2.log("V2 factory", factory);
        console2.log("V2 router", router);
        console2.log("Test wrapped native", wrappedNative);
        console2.log("Fee-to setter (permanently disabled)", feeToSetter);
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
