// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BabyNoxaConstants} from "../../src/libraries/BabyNoxaConstants.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";

contract CurveMathHarness {
    function quoteBuy(uint256 virtualBase, uint256 virtualToken, uint256 inventory, uint256 netBaseAvailable)
        external
        pure
        returns (CurveMath.BuyQuote memory)
    {
        return CurveMath.quoteBuy(virtualBase, virtualToken, inventory, netBaseAvailable);
    }

    function quoteSell(uint256 virtualBase, uint256 virtualToken, uint256 tokenIn, uint256 realBase)
        external
        pure
        returns (CurveMath.SellQuote memory)
    {
        return CurveMath.quoteSell(virtualBase, virtualToken, tokenIn, realBase);
    }
}

contract CurveMathTest is Test {
    CurveMathHarness internal harness;

    function setUp() public {
        harness = new CurveMathHarness();
    }

    function test_ConfirmedSupplyAllocationIsComplete() public pure {
        assertEq(
            BabyNoxaConstants.CURVE_TOKEN_ALLOCATION + BabyNoxaConstants.GRADUATION_TOKEN_RESERVE,
            BabyNoxaConstants.TOTAL_SUPPLY
        );
        assertEq(BabyNoxaConstants.CREATOR_INITIAL_BUY_CAP, BabyNoxaConstants.TOTAL_SUPPLY * 2 / 100);
    }

    function test_PartialBuyUsesAllNetInput() public pure {
        uint256 netBaseIn = 0.1 ether;
        CurveMath.BuyQuote memory quote = CurveMath.quoteBuy(
            BabyNoxaConstants.INITIAL_VIRTUAL_BASE_RESERVE,
            BabyNoxaConstants.INITIAL_VIRTUAL_TOKEN_RESERVE,
            BabyNoxaConstants.CURVE_TOKEN_ALLOCATION,
            netBaseIn
        );

        assertGt(quote.tokensOut, 0);
        assertEq(quote.netBaseUsed, netBaseIn);
        assertEq(quote.netBaseRefund, 0);
        assertEq(quote.remainingTokenInventory, BabyNoxaConstants.CURVE_TOKEN_ALLOCATION - quote.tokensOut);
        assertFalse(quote.completesCurve);
        _assertInvariantDidNotDecrease(
            BabyNoxaConstants.INITIAL_VIRTUAL_BASE_RESERVE,
            BabyNoxaConstants.INITIAL_VIRTUAL_TOKEN_RESERVE,
            quote.newVirtualBaseReserve,
            quote.newVirtualTokenReserve
        );
    }

    function test_FinalBuyClipsToInventoryAndRefundsExcess() public pure {
        CurveMath.BuyQuote memory quote = CurveMath.quoteBuy(
            BabyNoxaConstants.INITIAL_VIRTUAL_BASE_RESERVE,
            BabyNoxaConstants.INITIAL_VIRTUAL_TOKEN_RESERVE,
            BabyNoxaConstants.CURVE_TOKEN_ALLOCATION,
            10 ether
        );

        assertEq(quote.tokensOut, BabyNoxaConstants.CURVE_TOKEN_ALLOCATION);
        assertEq(quote.netBaseUsed, 4_274_999_994_656_250_007);
        assertEq(quote.netBaseRefund, 10 ether - quote.netBaseUsed);
        assertEq(quote.newVirtualTokenReserve, BabyNoxaConstants.TERMINAL_VIRTUAL_TOKEN_RESERVE);
        assertEq(quote.remainingTokenInventory, 0);
        assertTrue(quote.completesCurve);
        _assertInvariantDidNotDecrease(
            BabyNoxaConstants.INITIAL_VIRTUAL_BASE_RESERVE,
            BabyNoxaConstants.INITIAL_VIRTUAL_TOKEN_RESERVE,
            quote.newVirtualBaseReserve,
            quote.newVirtualTokenReserve
        );
    }

    function test_GraduationLiquidityMatchesTerminalPrice() public pure {
        (uint256 netReserve, uint256 terminalVirtualBase, uint256 terminalVirtualToken) = CurveMath.netBaseForExactTokensOut(
            BabyNoxaConstants.INITIAL_VIRTUAL_BASE_RESERVE,
            BabyNoxaConstants.INITIAL_VIRTUAL_TOKEN_RESERVE,
            BabyNoxaConstants.CURVE_TOKEN_ALLOCATION
        );
        uint256 treasuryAllocation =
            Math.mulDiv(netReserve, BabyNoxaConstants.GRADUATION_FEE_BPS, BabyNoxaConstants.BPS_DENOMINATOR);
        uint256 liquidityBase = netReserve - treasuryAllocation;
        uint256 liquidityTokens = CurveMath.tokensForLiquidity(liquidityBase, terminalVirtualBase, terminalVirtualToken);
        uint256 unusedGraduationTokens = BabyNoxaConstants.GRADUATION_TOKEN_RESERVE - liquidityTokens;

        assertEq(treasuryAllocation + liquidityBase, netReserve);
        assertEq(liquidityTokens, 180_000_000_168_749_999_983_385_874);
        assertGt(unusedGraduationTokens, 19_999_999 ether);
        assertLt(unusedGraduationTokens, 20_000_000 ether);

        uint256 terminalPrice = CurveMath.spotPrice(terminalVirtualBase, terminalVirtualToken);
        uint256 poolPrice = Math.mulDiv(liquidityBase, 1 ether, liquidityTokens);
        assertApproxEqAbs(poolPrice, terminalPrice, 1);
    }

    function test_BuyThenSellCannotProfitFromRounding() public pure {
        CurveMath.BuyQuote memory buyQuote = CurveMath.quoteBuy(
            BabyNoxaConstants.INITIAL_VIRTUAL_BASE_RESERVE,
            BabyNoxaConstants.INITIAL_VIRTUAL_TOKEN_RESERVE,
            BabyNoxaConstants.CURVE_TOKEN_ALLOCATION,
            1 ether
        );
        CurveMath.SellQuote memory sellQuote = CurveMath.quoteSell(
            buyQuote.newVirtualBaseReserve, buyQuote.newVirtualTokenReserve, buyQuote.tokensOut, buyQuote.netBaseUsed
        );

        assertLe(sellQuote.grossBaseOut, buyQuote.netBaseUsed);
        _assertInvariantDidNotDecrease(
            buyQuote.newVirtualBaseReserve,
            buyQuote.newVirtualTokenReserve,
            sellQuote.newVirtualBaseReserve,
            sellQuote.newVirtualTokenReserve
        );
    }

    function test_FullPrecisionMathHandlesOverflowingIntermediateProduct() public pure {
        uint256 virtualBase = uint256(1) << 200;
        uint256 virtualToken = uint256(1) << 100;
        uint256 inventory = uint256(1) << 99;

        CurveMath.BuyQuote memory quote = CurveMath.quoteBuy(virtualBase, virtualToken, inventory, virtualBase);

        assertEq(quote.tokensOut, inventory);
        assertEq(quote.newVirtualTokenReserve, virtualToken - inventory);
        assertTrue(quote.completesCurve);
    }

    function test_RevertWhenSellExceedsRealReserve() public {
        vm.expectPartialRevert(CurveMath.InsufficientRealReserve.selector);
        harness.quoteSell(
            BabyNoxaConstants.INITIAL_VIRTUAL_BASE_RESERVE,
            BabyNoxaConstants.INITIAL_VIRTUAL_TOKEN_RESERVE,
            1_000_000 ether,
            0
        );
    }

    function test_RevertWhenInventoryIsNotBelowVirtualReserve() public {
        vm.expectPartialRevert(CurveMath.InvalidInventory.selector);
        harness.quoteBuy(1 ether, 100 ether, 100 ether, 1 ether);
    }

    function test_RevertWhenBuyProducesOnlyDust() public {
        vm.expectRevert(CurveMath.ZeroOutput.selector);
        harness.quoteBuy(1e36, 1 ether, 0.5 ether, 1);
    }

    function test_RevertWhenAmountIsZero() public {
        vm.expectRevert(CurveMath.ZeroAmount.selector);
        harness.quoteBuy(
            BabyNoxaConstants.INITIAL_VIRTUAL_BASE_RESERVE,
            BabyNoxaConstants.INITIAL_VIRTUAL_TOKEN_RESERVE,
            BabyNoxaConstants.CURVE_TOKEN_ALLOCATION,
            0
        );

        vm.expectRevert(CurveMath.ZeroAmount.selector);
        harness.quoteSell(
            BabyNoxaConstants.INITIAL_VIRTUAL_BASE_RESERVE, BabyNoxaConstants.INITIAL_VIRTUAL_TOKEN_RESERVE, 0, 1 ether
        );
    }

    function testFuzz_BuyNeverDecreasesInvariant(uint96 rawNetBaseIn) public pure {
        uint256 netBaseIn = bound(uint256(rawNetBaseIn), 1, 100 ether);
        CurveMath.BuyQuote memory quote = CurveMath.quoteBuy(
            BabyNoxaConstants.INITIAL_VIRTUAL_BASE_RESERVE,
            BabyNoxaConstants.INITIAL_VIRTUAL_TOKEN_RESERVE,
            BabyNoxaConstants.CURVE_TOKEN_ALLOCATION,
            netBaseIn
        );

        _assertInvariantDidNotDecrease(
            BabyNoxaConstants.INITIAL_VIRTUAL_BASE_RESERVE,
            BabyNoxaConstants.INITIAL_VIRTUAL_TOKEN_RESERVE,
            quote.newVirtualBaseReserve,
            quote.newVirtualTokenReserve
        );
        assertLe(quote.tokensOut, BabyNoxaConstants.CURVE_TOKEN_ALLOCATION);
    }

    function _assertInvariantDidNotDecrease(
        uint256 oldVirtualBase,
        uint256 oldVirtualToken,
        uint256 newVirtualBase,
        uint256 newVirtualToken
    ) internal pure {
        assertGe(newVirtualBase * newVirtualToken, oldVirtualBase * oldVirtualToken);
    }
}
