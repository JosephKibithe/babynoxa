// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {IV2Factory} from "../../src/interfaces/dex/IV2Factory.sol";
import {IV2Pair} from "../../src/interfaces/dex/IV2Pair.sol";
import {IV2Router02} from "../../src/interfaces/dex/IV2Router02.sol";
import {BabyNoxaConstants} from "../../src/libraries/BabyNoxaConstants.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";
import {FeeMath} from "../../src/libraries/FeeMath.sol";
import {TestWrappedNative} from "../../src/mocks/TestWrappedNative.sol";

contract V2TestToken is ERC20 {
    constructor() ERC20("V2 Test Token", "V2TEST") {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}

contract TestV2DeploymentTest is Test {
    bytes32 internal constant PINNED_PAIR_INIT_CODE_HASH =
        0xd92ee51a660a9709fb1c23d4105ba4d858e55c93974dbafeadb98052027833c0;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IV2Factory internal factory;
    IV2Router02 internal router;
    TestWrappedNative internal wrappedNative;
    V2TestToken internal token;

    receive() external payable {}

    function setUp() public {
        assertEq(
            keccak256(vm.getCode("UniswapV2Pair.sol:UniswapV2Pair")),
            PINNED_PAIR_INIT_CODE_HASH,
            "Router02 pair hash mismatch"
        );

        wrappedNative = new TestWrappedNative();
        factory = IV2Factory(vm.deployCode("UniswapV2Factory.sol:UniswapV2Factory", abi.encode(address(0))));
        router = IV2Router02(
            vm.deployCode(
                "UniswapV2Router02.sol:UniswapV2Router02", abi.encode(address(factory), address(wrappedNative))
            )
        );
        token = new V2TestToken();
        token.approve(address(router), type(uint256).max);
        vm.deal(address(this), 100 ether);
    }

    function test_DeploymentWiresFactoryRouterAndWrappedNative() public view {
        assertGt(address(factory).code.length, 0);
        assertGt(address(router).code.length, 0);
        assertGt(address(wrappedNative).code.length, 0);
        assertEq(factory.feeToSetter(), address(0));
        assertEq(factory.feeTo(), address(0));
        assertEq(router.factory(), address(factory));
        assertEq(router.WETH(), address(wrappedNative));
    }

    function test_FirstLiquidityBurnsUsableLpAndLocksMinimumLiquidity() public {
        (uint256 netCurveReserve, uint256 terminalVirtualBase, uint256 terminalVirtualToken) = CurveMath.netBaseForExactTokensOut(
            BabyNoxaConstants.INITIAL_VIRTUAL_BASE_RESERVE,
            BabyNoxaConstants.INITIAL_VIRTUAL_TOKEN_RESERVE,
            BabyNoxaConstants.CURVE_TOKEN_ALLOCATION
        );
        FeeMath.GraduationFeeQuote memory graduation = FeeMath.quoteGraduation(netCurveReserve);
        uint256 desiredBase = graduation.liquidityBase;
        uint256 desiredTokens = CurveMath.tokensForLiquidity(desiredBase, terminalVirtualBase, terminalVirtualToken);

        assertApproxEqAbs(desiredTokens, 180_000_000 ether, 1 ether);

        (uint256 usedTokens, uint256 usedBase, uint256 liquidity) = router.addLiquidityETH{value: desiredBase}(
            address(token), desiredTokens, desiredTokens, desiredBase, DEAD, block.timestamp
        );

        address pairAddress = factory.getPair(address(token), address(wrappedNative));
        IV2Pair pair = IV2Pair(pairAddress);

        assertNotEq(pairAddress, address(0));
        assertEq(factory.allPairsLength(), 1);
        assertEq(usedTokens, desiredTokens);
        assertEq(usedBase, desiredBase);
        assertEq(pair.balanceOf(DEAD), liquidity);
        assertEq(pair.balanceOf(address(0)), pair.MINIMUM_LIQUIDITY());
        assertEq(pair.totalSupply(), liquidity + pair.MINIMUM_LIQUIDITY());

        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        uint256 poolBase;
        uint256 poolTokens;
        if (pair.token0() == address(token)) {
            assertEq(reserve0, desiredTokens);
            assertEq(reserve1, desiredBase);
            poolTokens = reserve0;
            poolBase = reserve1;
        } else {
            assertEq(reserve0, desiredBase);
            assertEq(reserve1, desiredTokens);
            poolBase = reserve0;
            poolTokens = reserve1;
        }

        uint256 terminalPrice = CurveMath.spotPrice(terminalVirtualBase, terminalVirtualToken);
        uint256 initialPoolPrice = Math.mulDiv(poolBase, 1 ether, poolTokens);
        uint256 absoluteDifference =
            terminalPrice >= initialPoolPrice ? terminalPrice - initialPoolPrice : initialPoolPrice - terminalPrice;
        uint256 relativeDifferenceBps = Math.mulDiv(absoluteDifference, 10_000, terminalPrice, Math.Rounding.Ceil);

        assertLe(absoluteDifference, 1, "absolute price-continuity tolerance");
        assertLe(relativeDifferenceBps, 1, "relative price-continuity tolerance");
    }

    function test_RouterUsesOptimalAmountsAndRefundsUnusedNativeBase() public {
        router.addLiquidityETH{value: 1 ether}(
            address(token), 2_000_000 ether, 2_000_000 ether, 1 ether, DEAD, block.timestamp
        );

        uint256 balanceBefore = address(this).balance;
        (uint256 usedTokens, uint256 usedBase,) = router.addLiquidityETH{value: 2 ether}(
            address(token), 2_000_000 ether, 2_000_000 ether, 1 ether, DEAD, block.timestamp
        );

        assertEq(usedTokens, 2_000_000 ether);
        assertEq(usedBase, 1 ether);
        assertEq(address(this).balance, balanceBefore - 1 ether);
    }

    function test_RouterExecutesNativeToTokenSwap() public {
        router.addLiquidityETH{value: 10 ether}(
            address(token), 10_000_000 ether, 10_000_000 ether, 10 ether, DEAD, block.timestamp
        );

        address buyer = makeAddr("buyer");
        vm.deal(buyer, 2 ether);
        address[] memory path = new address[](2);
        path[0] = address(wrappedNative);
        path[1] = address(token);
        uint256 expectedOut = router.getAmountsOut(1 ether, path)[1];

        vm.prank(buyer);
        uint256[] memory amounts =
            router.swapExactETHForTokens{value: 1 ether}(expectedOut, path, buyer, block.timestamp);

        assertEq(amounts[0], 1 ether);
        assertEq(amounts[1], expectedOut);
        assertEq(token.balanceOf(buyer), expectedOut);
    }

    function test_StandardFactoryAllowsAttackerToPrecreateOfficialPair() public {
        address attacker = makeAddr("pair attacker");

        vm.prank(attacker);
        address pair = factory.createPair(address(token), address(wrappedNative));

        assertNotEq(pair, address(0));
        assertEq(factory.getPair(address(token), address(wrappedNative)), pair);
    }

    function test_OneSidedDonationAndSyncCanBlockStandardRouterInitialization() public {
        address attacker = makeAddr("reserve poisoner");
        vm.deal(attacker, 1 ether);

        vm.prank(attacker);
        address pairAddress = factory.createPair(address(token), address(wrappedNative));

        vm.startPrank(attacker);
        wrappedNative.deposit{value: 1 wei}();
        wrappedNative.transfer(pairAddress, 1 wei);
        IV2Pair(pairAddress).sync();
        vm.stopPrank();

        (uint112 reserve0, uint112 reserve1,) = IV2Pair(pairAddress).getReserves();
        assertTrue((reserve0 == 0 && reserve1 == 1) || (reserve0 == 1 && reserve1 == 0));

        vm.expectRevert();
        router.addLiquidityETH{value: 1 ether}(address(token), 1_000_000 ether, 0, 0, DEAD, block.timestamp);
    }

    function test_StandardRouterAllowsAttackerToOwnFirstLiquidity() public {
        address attacker = makeAddr("first liquidity attacker");
        token.transfer(attacker, 1_000_000 ether);
        vm.deal(attacker, 2 ether);

        vm.startPrank(attacker);
        token.approve(address(router), type(uint256).max);
        (,, uint256 attackerLiquidity) = router.addLiquidityETH{value: 1 ether}(
            address(token), 1_000_000 ether, 1_000_000 ether, 1 ether, attacker, block.timestamp
        );
        vm.stopPrank();

        address pairAddress = factory.getPair(address(token), address(wrappedNative));
        assertGt(attackerLiquidity, 0);
        assertEq(IV2Pair(pairAddress).balanceOf(attacker), attackerLiquidity);
    }
}
