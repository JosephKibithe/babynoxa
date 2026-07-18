// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {BabyNoxaConstants} from "../../src/libraries/BabyNoxaConstants.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";
import {DeadlinePolicy} from "../../src/libraries/DeadlinePolicy.sol";
import {FeeMath} from "../../src/libraries/FeeMath.sol";

contract DeadlinePolicyHarness {
    function enforce(uint256 deadline) external view {
        DeadlinePolicy.enforce(deadline);
    }
}

/// @notice Makes the confirmed Phase 0 policy boundaries reproducible.
contract V1PolicySimulationTest is Test {
    DeadlinePolicyHarness internal deadlineHarness = new DeadlinePolicyHarness();

    function test_TradeFeeDustBoundaries() public pure {
        uint256 minimum = BabyNoxaConstants.MIN_GROSS_TRADE_VALUE;

        FeeMath.TradeFeeQuote memory belowFeeBoundary = FeeMath.quoteTrade(99);
        assertEq(belowFeeBoundary.totalFee, 0);
        assertEq(belowFeeBoundary.creatorFee, 0);
        assertEq(belowFeeBoundary.treasuryFee, 0);

        FeeMath.TradeFeeQuote memory firstFeeWei = FeeMath.quoteTrade(100);
        assertEq(firstFeeWei.totalFee, 1);
        assertEq(firstFeeWei.creatorFee, 0);
        assertEq(firstFeeWei.treasuryFee, 1);

        FeeMath.TradeFeeQuote memory belowTwoFeeWei = FeeMath.quoteTrade(minimum - 1);
        assertEq(belowTwoFeeWei.totalFee, 1);
        assertEq(belowTwoFeeWei.creatorFee, 0);
        assertEq(belowTwoFeeWei.treasuryFee, 1);

        FeeMath.TradeFeeQuote memory bothRecipientsPaid = FeeMath.quoteTrade(minimum);
        assertEq(bothRecipientsPaid.totalFee, 2);
        assertEq(bothRecipientsPaid.creatorFee, 1);
        assertEq(bothRecipientsPaid.treasuryFee, 1);

        FeeMath.TradeFeeQuote memory aboveBoundary = FeeMath.quoteTrade(minimum + 1);
        assertEq(aboveBoundary.totalFee, 2);
        assertEq(aboveBoundary.creatorFee, 1);
        assertEq(aboveBoundary.treasuryFee, 1);
    }

    function test_InitialSellAmountNeededForTwoHundredWeiGross() public pure {
        uint256 firstAmountReturningTwoHundredWei = 149_707_602_386;

        CurveMath.SellQuote memory belowBoundary = CurveMath.quoteSell(
            BabyNoxaConstants.INITIAL_VIRTUAL_BASE_RESERVE,
            BabyNoxaConstants.INITIAL_VIRTUAL_TOKEN_RESERVE,
            firstAmountReturningTwoHundredWei - 1,
            type(uint256).max
        );
        CurveMath.SellQuote memory atBoundary = CurveMath.quoteSell(
            BabyNoxaConstants.INITIAL_VIRTUAL_BASE_RESERVE,
            BabyNoxaConstants.INITIAL_VIRTUAL_TOKEN_RESERVE,
            firstAmountReturningTwoHundredWei,
            type(uint256).max
        );
        CurveMath.SellQuote memory aboveBoundary = CurveMath.quoteSell(
            BabyNoxaConstants.INITIAL_VIRTUAL_BASE_RESERVE,
            BabyNoxaConstants.INITIAL_VIRTUAL_TOKEN_RESERVE,
            firstAmountReturningTwoHundredWei + 1,
            type(uint256).max
        );

        assertEq(belowBoundary.grossBaseOut, BabyNoxaConstants.MIN_GROSS_TRADE_VALUE - 1);
        assertEq(atBoundary.grossBaseOut, BabyNoxaConstants.MIN_GROSS_TRADE_VALUE);
        assertGe(aboveBoundary.grossBaseOut, BabyNoxaConstants.MIN_GROSS_TRADE_VALUE);
    }

    function testFuzz_SellDustFloorRemainsValueBasedAcrossReachableStates(uint256 rawTokensSold) public pure {
        uint256 tokensSold = rawTokensSold % (BabyNoxaConstants.CURVE_TOKEN_ALLOCATION + 1);
        uint256 virtualBase = BabyNoxaConstants.INITIAL_VIRTUAL_BASE_RESERVE;
        uint256 virtualTokens = BabyNoxaConstants.INITIAL_VIRTUAL_TOKEN_RESERVE;

        if (tokensSold != 0) {
            (, virtualBase, virtualTokens) = CurveMath.netBaseForExactTokensOut(
                BabyNoxaConstants.INITIAL_VIRTUAL_BASE_RESERVE,
                BabyNoxaConstants.INITIAL_VIRTUAL_TOKEN_RESERVE,
                tokensSold
            );
        }

        uint256 low = 1;
        uint256 high = 1 ether;
        while (low < high) {
            uint256 middle = (low + high) / 2;
            if (_grossSellOutput(virtualBase, virtualTokens, middle) >= BabyNoxaConstants.MIN_GROSS_TRADE_VALUE) {
                high = middle;
            } else {
                low = middle + 1;
            }
        }

        CurveMath.SellQuote memory atFloor = CurveMath.quoteSell(virtualBase, virtualTokens, low, type(uint256).max);
        assertGe(atFloor.grossBaseOut, BabyNoxaConstants.MIN_GROSS_TRADE_VALUE);
        if (low > 1) {
            assertLt(_grossSellOutput(virtualBase, virtualTokens, low - 1), BabyNoxaConstants.MIN_GROSS_TRADE_VALUE);
        }
    }

    function test_DeadlineIsValidBeforeAndExactlyAtTimestamp() public {
        uint256 deadline = 1_000_000;

        vm.warp(deadline - 1);
        deadlineHarness.enforce(deadline);

        vm.warp(deadline);
        deadlineHarness.enforce(deadline);
    }

    function test_DeadlineRevertsOneSecondAfterTimestamp() public {
        uint256 deadline = 1_000_000;
        vm.warp(deadline + 1);

        vm.expectRevert(abi.encodeWithSelector(DeadlinePolicy.DeadlineExpired.selector, deadline, deadline + 1));
        deadlineHarness.enforce(deadline);
    }

    function test_LargeBuyIsBoundedByInventoryAndRefundsExcessInsteadOfUsingProtocolMaximum() public pure {
        CurveMath.BuyQuote memory quote = CurveMath.quoteBuy(
            BabyNoxaConstants.INITIAL_VIRTUAL_BASE_RESERVE,
            BabyNoxaConstants.INITIAL_VIRTUAL_TOKEN_RESERVE,
            BabyNoxaConstants.CURVE_TOKEN_ALLOCATION,
            type(uint128).max
        );

        assertTrue(quote.completesCurve);
        assertEq(quote.tokensOut, BabyNoxaConstants.CURVE_TOKEN_ALLOCATION);
        assertEq(quote.remainingTokenInventory, 0);
        assertGt(quote.netBaseRefund, 0);
    }

    function test_LargeReachableSellIsBoundedByOwnedTokensAndRealReserve() public pure {
        uint256 tokensBought = 400_000_000 ether;
        (uint256 realBaseReserve, uint256 virtualBase, uint256 virtualTokens) = CurveMath.netBaseForExactTokensOut(
            BabyNoxaConstants.INITIAL_VIRTUAL_BASE_RESERVE,
            BabyNoxaConstants.INITIAL_VIRTUAL_TOKEN_RESERVE,
            tokensBought
        );

        CurveMath.SellQuote memory quote =
            CurveMath.quoteSell(virtualBase, virtualTokens, tokensBought, realBaseReserve);

        assertGt(quote.grossBaseOut, 0);
        assertLe(quote.grossBaseOut, realBaseReserve);
        assertEq(quote.newVirtualTokenReserve, BabyNoxaConstants.INITIAL_VIRTUAL_TOKEN_RESERVE);
    }

    function test_ConfirmedGeometryHasExactDisplayedPriceContinuity() public pure {
        (uint256 netReserve, uint256 terminalVirtualBase, uint256 terminalVirtualToken) = CurveMath.netBaseForExactTokensOut(
            BabyNoxaConstants.INITIAL_VIRTUAL_BASE_RESERVE,
            BabyNoxaConstants.INITIAL_VIRTUAL_TOKEN_RESERVE,
            BabyNoxaConstants.CURVE_TOKEN_ALLOCATION
        );
        FeeMath.GraduationFeeQuote memory graduation = FeeMath.quoteGraduation(netReserve);
        uint256 liquidityTokens =
            CurveMath.tokensForLiquidity(graduation.liquidityBase, terminalVirtualBase, terminalVirtualToken);

        uint256 terminalPrice = CurveMath.spotPrice(terminalVirtualBase, terminalVirtualToken);
        uint256 initialPoolPrice = Math.mulDiv(graduation.liquidityBase, 1 ether, liquidityTokens);

        assertEq(terminalPrice, 21_374_999_953);
        assertEq(initialPoolPrice, terminalPrice);
    }

    function _grossSellOutput(uint256 virtualBase, uint256 virtualTokens, uint256 tokenIn)
        private
        pure
        returns (uint256)
    {
        uint256 newVirtualBase = Math.mulDiv(virtualBase, virtualTokens, virtualTokens + tokenIn, Math.Rounding.Ceil);
        return virtualBase - newVirtualBase;
    }
}
