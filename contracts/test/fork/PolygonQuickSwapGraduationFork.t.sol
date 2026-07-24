// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {BabyNoxaFactoryQS} from "../../src/BabyNoxaFactoryQS.sol";
import {BabyNoxaToken} from "../../src/BabyNoxaToken.sol";
import {BondingCurve} from "../../src/BondingCurve.sol";
import {GraduationManagerV2} from "../../src/GraduationManagerV2.sol";
import {IQuickSwapV2Pair} from "../../src/interfaces/dex/IQuickSwapV2Pair.sol";
import {IV2Factory} from "../../src/interfaces/dex/IV2Factory.sol";
import {IV2Router02} from "../../src/interfaces/dex/IV2Router02.sol";
import {BabyNoxaConstants} from "../../src/libraries/BabyNoxaConstants.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";
import {FeeMath} from "../../src/libraries/FeeMath.sol";
import {CreateLaunchParams, LaunchRecord, LaunchState} from "../../src/types/BabyNoxaTypes.sol";

/// @notice No-spend rehearsal of the QuickSwap graduation path against real Polygon mainnet state.
/// @dev Never broadcasts. Proves a full curve->QuickSwap-pair->tradeable lifecycle on canonical QuickSwap+WPOL.
contract PolygonQuickSwapGraduationForkTest is Test {
    uint256 internal constant POLYGON_MAINNET_CHAIN_ID = 137;
    address internal constant WPOL = 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270;
    address internal constant QUICKSWAP_V2_FACTORY = 0x5757371414417b8C6CAad45bAeF941aBc7d3Ab32;
    address internal constant QUICKSWAP_V2_ROUTER = 0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff;
    address internal constant LP_BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    function testPolygonMainnetQuickSwapGraduationWhenConfigured() external {
        string memory rpcUrl = vm.envOr("POLYGON_MAINNET_RPC_URL", string(""));
        bool forkRequired = vm.envOr("POLYGON_MAINNET_FORK_REQUIRED", false);
        if (bytes(rpcUrl).length == 0) {
            assertFalse(forkRequired, "required Polygon mainnet fork RPC is missing");
            return;
        }

        vm.createSelectFork(rpcUrl);
        assertEq(block.chainid, POLYGON_MAINNET_CHAIN_ID);
        assertEq(IV2Router02(QUICKSWAP_V2_ROUTER).factory(), QUICKSWAP_V2_FACTORY);
        assertEq(IV2Router02(QUICKSWAP_V2_ROUTER).WETH(), WPOL);

        BabyNoxaFactoryQS factory = new BabyNoxaFactoryQS(
            address(this),
            address(this),
            QUICKSWAP_V2_FACTORY,
            WPOL,
            BabyNoxaConstants.INITIAL_VIRTUAL_BASE_RESERVE,
            BabyNoxaConstants.INITIAL_VIRTUAL_TOKEN_RESERVE
        );
        GraduationManagerV2 manager =
            new GraduationManagerV2(address(factory), QUICKSWAP_V2_FACTORY, QUICKSWAP_V2_ROUTER, WPOL);
        factory.setActiveGraduationManager(address(manager));

        CreateLaunchParams memory params = CreateLaunchParams({
            name: "BabyNoxa QuickSwap Fork",
            symbol: "BNXQS",
            metadataURI: "ipfs://babynoxa-quickswap-fork-rehearsal",
            metadataHash: keccak256("babynoxa-quickswap-fork-rehearsal"),
            minimumCreatorTokensOut: 0,
            deadline: type(uint256).max
        });
        LaunchRecord memory record = factory.createLaunch(params);
        BondingCurve curve = BondingCurve(record.curve);
        BabyNoxaToken token = BabyNoxaToken(record.token);
        IQuickSwapV2Pair pair = IQuickSwapV2Pair(record.officialPair);
        assertEq(pair.factory(), QUICKSWAP_V2_FACTORY, "official pair is not a QuickSwap pair");

        (uint256 netToGraduate,,) = CurveMath.netBaseForExactTokensOut(
            BabyNoxaConstants.INITIAL_VIRTUAL_BASE_RESERVE,
            BabyNoxaConstants.INITIAL_VIRTUAL_TOKEN_RESERVE,
            BabyNoxaConstants.CURVE_TOKEN_ALLOCATION
        );
        uint256 grossToGraduate = FeeMath.grossFromNet(netToGraduate);
        address buyer = makeAddr("polygon quickswap fork buyer");
        vm.deal(buyer, grossToGraduate + 1 ether);
        vm.prank(buyer);
        curve.buy{value: grossToGraduate}(0, type(uint256).max);

        assertEq(uint256(curve.state()), uint256(LaunchState.Graduated));
        assertGt(pair.balanceOf(LP_BURN_ADDRESS), 0);
        assertEq(pair.totalSupply(), pair.balanceOf(LP_BURN_ADDRESS) + pair.balanceOf(address(0)));
        assertEq(IERC20(WPOL).balanceOf(address(manager)), 0);
        assertEq(token.balanceOf(address(manager)), 0);

        address swapper = makeAddr("polygon quickswap fork swapper");
        uint256 swapInput = 0.01 ether;
        vm.deal(swapper, swapInput);
        address[] memory path = new address[](2);
        path[0] = WPOL;
        path[1] = address(token);
        uint256 minimumTokensOut = IV2Router02(QUICKSWAP_V2_ROUTER).getAmountsOut(swapInput, path)[1];
        vm.prank(swapper);
        IV2Router02(QUICKSWAP_V2_ROUTER).swapExactETHForTokens{value: swapInput}(
            minimumTokensOut, path, swapper, type(uint256).max
        );
        assertEq(token.balanceOf(swapper), minimumTokensOut);
    }
}
