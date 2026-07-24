// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Test} from "forge-std/Test.sol";
import {BabyNoxaFactory} from "../../src/BabyNoxaFactory.sol";
import {GraduationManagerV1} from "../../src/GraduationManagerV1.sol";
import {IGuardedV2Factory} from "../../src/interfaces/dex/IGuardedV2Factory.sol";
import {IV2Router02} from "../../src/interfaces/dex/IV2Router02.sol";

/// @notice Public-testnet wiring gate. Local runs may omit Amoy values; CI is configured to require them.
contract AmoyDeploymentForkTest is Test {
    address internal constant LP_BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    function testAmoyDeploymentWiringWhenConfigured() external {
        string memory rpcUrl = vm.envOr("AMOY_RPC_URL", string(""));
        address factoryAddress = vm.envOr("AMOY_FACTORY", address(0));
        address managerAddress = vm.envOr("AMOY_MANAGER", address(0));
        address v2FactoryAddress = vm.envOr("AMOY_V2_FACTORY", address(0));
        address routerAddress = vm.envOr("AMOY_ROUTER", address(0));
        address wrappedNativeAddress = vm.envOr("AMOY_WRAPPED_NATIVE", address(0));
        bool forkRequired = vm.envOr("AMOY_FORK_REQUIRED", false);

        bool configurationMissing = bytes(rpcUrl).length == 0 || factoryAddress == address(0)
            || managerAddress == address(0) || v2FactoryAddress == address(0) || routerAddress == address(0)
            || wrappedNativeAddress == address(0);
        if (configurationMissing) {
            assertFalse(forkRequired, "required Amoy fork configuration is incomplete");
            return;
        }

        vm.createSelectFork(rpcUrl);
        assertEq(block.chainid, 80002, "fork must be Polygon Amoy");
        assertGt(factoryAddress.code.length, 0, "factory bytecode missing");
        assertGt(managerAddress.code.length, 0, "manager bytecode missing");
        assertGt(v2FactoryAddress.code.length, 0, "V2 factory bytecode missing");
        assertGt(routerAddress.code.length, 0, "router bytecode missing");
        assertGt(wrappedNativeAddress.code.length, 0, "wrapped-native bytecode missing");

        BabyNoxaFactory factory = BabyNoxaFactory(factoryAddress);
        GraduationManagerV1 manager = GraduationManagerV1(payable(managerAddress));
        IGuardedV2Factory v2Factory = IGuardedV2Factory(v2FactoryAddress);
        IV2Router02 router = IV2Router02(routerAddress);

        assertEq(factory.v2Factory(), v2FactoryAddress);
        assertEq(factory.wrappedNative(), wrappedNativeAddress);
        assertEq(factory.activeGraduationManager(), managerAddress);
        assertEq(manager.factory(), factoryAddress);
        assertEq(manager.v2Factory(), v2FactoryAddress);
        assertEq(manager.router(), routerAddress);
        assertEq(manager.wrappedNative(), wrappedNativeAddress);
        assertEq(manager.burnAddress(), LP_BURN_ADDRESS);
        assertEq(v2Factory.launchFactory(), factoryAddress);
        assertEq(v2Factory.feeTo(), address(0));
        assertEq(v2Factory.feeToSetter(), address(0));
        assertEq(router.factory(), v2FactoryAddress);
        assertEq(router.WETH(), wrappedNativeAddress);
    }
}
