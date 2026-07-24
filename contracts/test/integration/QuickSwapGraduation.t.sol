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
import {TestWrappedNative} from "../../src/mocks/TestWrappedNative.sol";
import {CreateLaunchParams, LaunchRecord, LaunchState} from "../../src/types/BabyNoxaTypes.sol";

/// @notice Lifecycle and griefing coverage for the QuickSwap (stock Uniswap V2) graduation path.
/// @dev Uses the vendored stock UniswapV2Factory/Router02 to model QuickSwap's permissionless AMM locally.
contract QuickSwapGraduationTest is Test {
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    TestWrappedNative internal wrappedNative;
    IV2Factory internal v2Factory;
    IV2Router02 internal router;
    BabyNoxaFactoryQS internal factory;
    GraduationManagerV2 internal manager;

    receive() external payable {}

    function setUp() public {
        wrappedNative = new TestWrappedNative();
        v2Factory = IV2Factory(vm.deployCode("UniswapV2Factory.sol:UniswapV2Factory", abi.encode(address(0))));
        router = IV2Router02(
            vm.deployCode(
                "UniswapV2Router02.sol:UniswapV2Router02", abi.encode(address(v2Factory), address(wrappedNative))
            )
        );
        factory = new BabyNoxaFactoryQS(
            address(this),
            address(this),
            address(v2Factory),
            address(wrappedNative),
            BabyNoxaConstants.INITIAL_VIRTUAL_BASE_RESERVE,
            BabyNoxaConstants.INITIAL_VIRTUAL_TOKEN_RESERVE
        );
        manager = new GraduationManagerV2(address(factory), address(v2Factory), address(router), address(wrappedNative));
        factory.setActiveGraduationManager(address(manager));
    }

    function _createLaunch(bytes32 salt) private returns (BondingCurve curve, BabyNoxaToken token, address pair) {
        CreateLaunchParams memory params = CreateLaunchParams({
            name: "QuickSwap Graduation",
            symbol: "QSGRAD",
            metadataURI: "ipfs://quickswap-graduation",
            metadataHash: salt,
            minimumCreatorTokensOut: 0,
            deadline: type(uint256).max
        });
        LaunchRecord memory record = factory.createLaunch(params);
        curve = BondingCurve(record.curve);
        token = BabyNoxaToken(record.token);
        pair = record.officialPair;
    }

    function _grossToGraduate() private pure returns (uint256) {
        (uint256 netToGraduate,,) = CurveMath.netBaseForExactTokensOut(
            BabyNoxaConstants.INITIAL_VIRTUAL_BASE_RESERVE,
            BabyNoxaConstants.INITIAL_VIRTUAL_TOKEN_RESERVE,
            BabyNoxaConstants.CURVE_TOKEN_ALLOCATION
        );
        return FeeMath.grossFromNet(netToGraduate);
    }

    function test_GraduatesIntoQuickSwapPairAndBurnsAllUsableLp() public {
        (BondingCurve curve, BabyNoxaToken token, address pairAddress) = _createLaunch(keccak256("happy"));
        IQuickSwapV2Pair pair = IQuickSwapV2Pair(pairAddress);

        uint256 gross = _grossToGraduate();
        address buyer = makeAddr("buyer");
        vm.deal(buyer, gross + 1 ether);
        vm.prank(buyer);
        curve.buy{value: gross}(0, type(uint256).max);

        assertEq(uint256(curve.state()), uint256(LaunchState.Graduated));
        assertGt(pair.balanceOf(DEAD), 0, "usable LP not burned");
        assertEq(pair.balanceOf(address(0)), pair.MINIMUM_LIQUIDITY());
        assertEq(pair.totalSupply(), pair.balanceOf(DEAD) + pair.MINIMUM_LIQUIDITY());
        assertEq(pair.balanceOf(address(manager)), 0);
        assertEq(IERC20(address(wrappedNative)).balanceOf(address(manager)), 0);
        assertEq(token.balanceOf(address(manager)), 0);
        assertEq(v2Factory.getPair(address(token), address(wrappedNative)), pairAddress);

        // The graduated token is tradeable on the QuickSwap router.
        address swapper = makeAddr("swapper");
        uint256 swapInput = 0.01 ether;
        vm.deal(swapper, swapInput);
        address[] memory path = new address[](2);
        path[0] = address(wrappedNative);
        path[1] = address(token);
        uint256 expectedOut = router.getAmountsOut(swapInput, path)[1];
        vm.prank(swapper);
        router.swapExactETHForTokens{value: swapInput}(expectedOut, path, swapper, type(uint256).max);
        assertEq(token.balanceOf(swapper), expectedOut);
    }

    function test_DonationToEmptyPairIsSkimmedAndGraduationSucceeds() public {
        (BondingCurve curve,, address pairAddress) = _createLaunch(keccak256("donation"));

        // Attacker donates wrapped base to the empty pair WITHOUT syncing (reserves stay zero).
        address attacker = makeAddr("donor");
        vm.deal(attacker, 1 ether);
        vm.startPrank(attacker);
        wrappedNative.deposit{value: 0.5 ether}();
        wrappedNative.transfer(pairAddress, 0.5 ether);
        vm.stopPrank();

        uint256 gross = _grossToGraduate();
        address buyer = makeAddr("buyer");
        vm.deal(buyer, gross + 1 ether);
        vm.prank(buyer);
        curve.buy{value: gross}(0, type(uint256).max);

        // Graduation still completes; the donation was skimmed to the burn address.
        assertEq(uint256(curve.state()), uint256(LaunchState.Graduated));
        assertGt(IQuickSwapV2Pair(pairAddress).balanceOf(DEAD), 0);
        assertEq(IERC20(address(wrappedNative)).balanceOf(address(manager)), 0);
    }

    function test_SyncPoisonedReservesBlockGraduation() public {
        (BondingCurve curve,, address pairAddress) = _createLaunch(keccak256("sync-poison"));

        // Attacker donates and syncs, forcing nonzero reserves that a stock V2 pair cannot un-sync.
        address attacker = makeAddr("poisoner");
        vm.deal(attacker, 1 ether);
        vm.startPrank(attacker);
        wrappedNative.deposit{value: 1 wei}();
        wrappedNative.transfer(pairAddress, 1 wei);
        IQuickSwapV2Pair(pairAddress).sync();
        vm.stopPrank();

        uint256 gross = _grossToGraduate();
        address buyer = makeAddr("buyer");
        vm.deal(buyer, gross + 1 ether);
        vm.prank(buyer);
        vm.expectRevert(); // GraduationManagerV2.PairNotEmpty bubbles up through the completing buy.
        curve.buy{value: gross}(0, type(uint256).max);
    }

    function test_AttackerOwnedFirstLiquidityBlocksGraduation() public {
        (BondingCurve curve, BabyNoxaToken token, address pairAddress) = _createLaunch(keccak256("first-lp"));

        // Attacker buys curve tokens, then seeds the official pair with real LP that they own.
        address attacker = makeAddr("first-lp attacker");
        vm.deal(attacker, 2 ether);
        vm.prank(attacker);
        curve.buy{value: 1 ether}(0, type(uint256).max);
        uint256 attackerTokens = token.balanceOf(attacker);
        assertGt(attackerTokens, 0);

        vm.startPrank(attacker);
        token.approve(address(router), type(uint256).max);
        router.addLiquidityETH{value: 0.5 ether}(address(token), attackerTokens, 0, 0, attacker, type(uint256).max);
        vm.stopPrank();

        assertGt(IQuickSwapV2Pair(pairAddress).totalSupply(), 0);

        uint256 gross = _grossToGraduate();
        address buyer = makeAddr("buyer");
        vm.deal(buyer, gross + 1 ether);
        vm.prank(buyer);
        vm.expectRevert(); // Pre-existing LP supply is a hard stop for the standard-pair seed.
        curve.buy{value: gross}(0, type(uint256).max);
    }
}
