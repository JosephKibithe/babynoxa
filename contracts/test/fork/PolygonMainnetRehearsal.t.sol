// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {BabyNoxaFactory} from "../../src/BabyNoxaFactory.sol";
import {BabyNoxaToken} from "../../src/BabyNoxaToken.sol";
import {BondingCurve} from "../../src/BondingCurve.sol";
import {GraduationManagerV1} from "../../src/GraduationManagerV1.sol";
import {IGuardedV2Factory} from "../../src/interfaces/dex/IGuardedV2Factory.sol";
import {IGuardedV2Pair} from "../../src/interfaces/dex/IGuardedV2Pair.sol";
import {IV2Router02} from "../../src/interfaces/dex/IV2Router02.sol";
import {BabyNoxaConstants} from "../../src/libraries/BabyNoxaConstants.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";
import {FeeMath} from "../../src/libraries/FeeMath.sol";
import {CreateLaunchParams, LaunchRecord, LaunchState} from "../../src/types/BabyNoxaTypes.sol";

/// @notice No-spend rehearsal of the frozen V1 candidate against Polygon mainnet state.
/// @dev This test never broadcasts. It proves canonical WPOL compatibility and preserves the guarded first-liquidity path.
contract PolygonMainnetRehearsalTest is Test {
    uint256 internal constant POLYGON_MAINNET_CHAIN_ID = 137;
    address internal constant WPOL = 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270;
    address internal constant QUICKSWAP_V2_FACTORY = 0x5757371414417b8C6CAad45bAeF941aBc7d3Ab32;
    address internal constant QUICKSWAP_V2_ROUTER = 0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff;
    address internal constant LP_BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    function testPolygonMainnetGuardedLifecycleWhenConfigured() external {
        string memory rpcUrl = vm.envOr("POLYGON_MAINNET_RPC_URL", string(""));
        bool forkRequired = vm.envOr("POLYGON_MAINNET_FORK_REQUIRED", false);
        if (bytes(rpcUrl).length == 0) {
            assertFalse(forkRequired, "required Polygon mainnet fork RPC is missing");
            return;
        }

        vm.createSelectFork(rpcUrl);
        assertEq(block.chainid, POLYGON_MAINNET_CHAIN_ID);
        assertGt(WPOL.code.length, 0, "canonical WPOL bytecode missing");
        assertEq(_readString(WPOL, "name()"), "Wrapped Polygon Ecosystem Token");
        assertEq(_readString(WPOL, "symbol()"), "WPOL");
        assertEq(IV2Router02(QUICKSWAP_V2_ROUTER).factory(), QUICKSWAP_V2_FACTORY);
        assertEq(IV2Router02(QUICKSWAP_V2_ROUTER).WETH(), WPOL);

        // A standard permissionless V2 factory cannot satisfy BabyNoxa's guarded-bootstrap constructor boundary.
        vm.expectRevert();
        new BabyNoxaFactory(
            address(this),
            address(this),
            QUICKSWAP_V2_FACTORY,
            WPOL,
            BabyNoxaConstants.INITIAL_VIRTUAL_BASE_RESERVE,
            BabyNoxaConstants.INITIAL_VIRTUAL_TOKEN_RESERVE
        );

        uint256 nextNonce = vm.getNonce(address(this));
        address predictedFactory = vm.computeCreateAddress(address(this), nextNonce + 2);
        IGuardedV2Factory guardedFactory =
            IGuardedV2Factory(vm.deployCode("GuardedV2Factory.sol:GuardedV2Factory", abi.encode(predictedFactory)));
        IV2Router02 guardedRouter = IV2Router02(
            vm.deployCode("GuardedV2Router02.sol:GuardedV2Router02", abi.encode(address(guardedFactory), WPOL))
        );
        BabyNoxaFactory factory = new BabyNoxaFactory(
            address(this),
            address(this),
            address(guardedFactory),
            WPOL,
            BabyNoxaConstants.INITIAL_VIRTUAL_BASE_RESERVE,
            BabyNoxaConstants.INITIAL_VIRTUAL_TOKEN_RESERVE
        );
        assertEq(address(factory), predictedFactory);

        GraduationManagerV1 manager =
            new GraduationManagerV1(address(factory), address(guardedFactory), address(guardedRouter), WPOL);
        factory.setActiveGraduationManager(address(manager));

        CreateLaunchParams memory params = CreateLaunchParams({
            name: "BabyNoxa Mainnet Fork",
            symbol: "BNXFORK",
            metadataURI: "ipfs://babynoxa-mainnet-fork-rehearsal",
            metadataHash: keccak256("babynoxa-mainnet-fork-rehearsal"),
            minimumCreatorTokensOut: 0,
            deadline: type(uint256).max
        });
        LaunchRecord memory record = factory.createLaunch(params);
        BondingCurve curve = BondingCurve(record.curve);
        BabyNoxaToken token = BabyNoxaToken(record.token);
        IGuardedV2Pair pair = IGuardedV2Pair(record.officialPair);

        (uint256 netToGraduate,,) = CurveMath.netBaseForExactTokensOut(
            BabyNoxaConstants.INITIAL_VIRTUAL_BASE_RESERVE,
            BabyNoxaConstants.INITIAL_VIRTUAL_TOKEN_RESERVE,
            BabyNoxaConstants.CURVE_TOKEN_ALLOCATION
        );
        uint256 grossToGraduate = FeeMath.grossFromNet(netToGraduate);
        address buyer = makeAddr("polygon mainnet fork buyer");
        vm.deal(buyer, grossToGraduate + 1 ether);
        vm.prank(buyer);
        curve.buy{value: grossToGraduate}(0, type(uint256).max);

        assertEq(uint256(curve.state()), uint256(LaunchState.Graduated));
        assertFalse(pair.bootstrapLocked());
        assertEq(pair.bootstrapManager(), address(0));
        assertGt(pair.balanceOf(LP_BURN_ADDRESS), 0);
        assertEq(pair.totalSupply(), pair.balanceOf(LP_BURN_ADDRESS) + pair.balanceOf(address(0)));
        assertEq(IERC20(WPOL).balanceOf(address(manager)), 0);

        address swapper = makeAddr("polygon mainnet fork swapper");
        uint256 swapInput = 0.01 ether;
        vm.deal(swapper, swapInput);
        address[] memory path = new address[](2);
        path[0] = WPOL;
        path[1] = address(token);
        uint256 minimumTokensOut = guardedRouter.getAmountsOut(swapInput, path)[1];
        vm.prank(swapper);
        guardedRouter.swapExactETHForTokens{value: swapInput}(minimumTokensOut, path, swapper, type(uint256).max);
        assertEq(token.balanceOf(swapper), minimumTokensOut);
    }

    function _readString(address target, string memory signature) private view returns (string memory value) {
        (bool success, bytes memory result) = target.staticcall(abi.encodeWithSignature(signature));
        assertTrue(success, "metadata read failed");
        value = abi.decode(result, (string));
    }
}
