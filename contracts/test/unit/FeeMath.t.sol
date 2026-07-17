// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BabyNoxaConstants} from "../../src/libraries/BabyNoxaConstants.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";
import {FeeMath} from "../../src/libraries/FeeMath.sol";

contract FeeMathHarness {
    function quoteTrade(uint256 grossAmount) external pure returns (FeeMath.TradeFeeQuote memory) {
        return FeeMath.quoteTrade(grossAmount);
    }

    function quoteFinalBuy(uint256 grossAvailable, uint256 netRequired)
        external
        pure
        returns (FeeMath.FinalBuyFeeQuote memory)
    {
        return FeeMath.quoteFinalBuy(grossAvailable, netRequired);
    }

    function quoteGraduation(uint256 reserve) external pure returns (FeeMath.GraduationFeeQuote memory) {
        return FeeMath.quoteGraduation(reserve);
    }
}

contract FeeMathTest is Test {
    FeeMathHarness internal harness;

    function setUp() public {
        harness = new FeeMathHarness();
    }

    function test_OneEtherTradeChargesOnePercentAndSplitsEvenly() public pure {
        FeeMath.TradeFeeQuote memory quote = FeeMath.quoteTrade(1 ether);

        assertEq(quote.totalFee, 0.01 ether);
        assertEq(quote.creatorFee, 0.005 ether);
        assertEq(quote.treasuryFee, 0.005 ether);
        assertEq(quote.netAmount, 0.99 ether);
        _assertTradeConserved(quote);
    }

    function test_OddFeeWeiGoesToTreasuryWithoutBreakingConservation() public pure {
        FeeMath.TradeFeeQuote memory quote = FeeMath.quoteTrade(101);

        assertEq(quote.totalFee, 1);
        assertEq(quote.creatorFee, 0);
        assertEq(quote.treasuryFee, 1);
        assertEq(quote.netAmount, 100);
        _assertTradeConserved(quote);
    }

    function test_GrossFromNetExactlyInvertsTradeFee() public pure {
        uint256 grossAmount = FeeMath.grossFromNet(0.99 ether);
        FeeMath.TradeFeeQuote memory quote = FeeMath.quoteTrade(grossAmount);

        assertEq(grossAmount, 1 ether);
        assertEq(quote.netAmount, 0.99 ether);
    }

    function test_FinalBuyChargesOnlyExecutedGrossAndRefundsRemainder() public pure {
        (uint256 netRequired,,) = CurveMath.netBaseForExactTokensOut(
            BabyNoxaConstants.INITIAL_VIRTUAL_BASE_RESERVE,
            BabyNoxaConstants.INITIAL_VIRTUAL_TOKEN_RESERVE,
            BabyNoxaConstants.CURVE_TOKEN_ALLOCATION
        );
        FeeMath.FinalBuyFeeQuote memory quote = FeeMath.quoteFinalBuy(10 ether, netRequired);

        assertEq(quote.netBaseToCurve, netRequired);
        assertEq(quote.grossBaseUsed + quote.grossBaseRefund, quote.grossBaseAvailable);
        assertEq(quote.creatorFee + quote.treasuryFee, quote.totalFee);
        assertEq(quote.netBaseToCurve + quote.totalFee, quote.grossBaseUsed);
        assertGt(quote.grossBaseRefund, 5 ether);
    }

    function test_GraduationAllocatesTenPercentAndConservesReserve() public pure {
        uint256 reserve = 4_274_999_994_656_250_007;
        FeeMath.GraduationFeeQuote memory quote = FeeMath.quoteGraduation(reserve);

        assertEq(quote.treasuryAllocation, 427_499_999_465_625_000);
        assertEq(quote.keeperReimbursement, 0);
        assertEq(quote.treasuryAllocation + quote.liquidityBase, reserve);
    }

    function test_RevertWhenFinalBuyGrossIsInsufficient() public {
        uint256 netRequired = 1 ether;
        uint256 grossRequired = FeeMath.grossFromNet(netRequired);

        vm.expectPartialRevert(FeeMath.InsufficientGrossAmount.selector);
        harness.quoteFinalBuy(grossRequired - 1, netRequired);
    }

    function test_RevertWhenAmountIsZero() public {
        vm.expectRevert(FeeMath.ZeroAmount.selector);
        harness.quoteTrade(0);

        vm.expectRevert(FeeMath.ZeroAmount.selector);
        harness.quoteFinalBuy(1, 0);

        vm.expectRevert(FeeMath.ZeroAmount.selector);
        harness.quoteGraduation(0);
    }

    function testFuzz_GrossFromNetReturnsExactNet(uint128 rawNetAmount) public pure {
        uint256 netAmount = bound(uint256(rawNetAmount), 1, 1_000 ether);
        uint256 grossAmount = FeeMath.grossFromNet(netAmount);
        FeeMath.TradeFeeQuote memory quote = FeeMath.quoteTrade(grossAmount);

        assertEq(quote.netAmount, netAmount);
        _assertTradeConserved(quote);
    }

    function testFuzz_NetAmountIsMonotonic(uint128 rawGrossAmount) public pure {
        uint256 grossAmount = bound(uint256(rawGrossAmount), 1, 1_000 ether);
        FeeMath.TradeFeeQuote memory current = FeeMath.quoteTrade(grossAmount);
        FeeMath.TradeFeeQuote memory next = FeeMath.quoteTrade(grossAmount + 1);

        assertGe(next.netAmount, current.netAmount);
    }

    function testFuzz_GraduationAlwaysConservesReserve(uint128 rawReserve) public pure {
        uint256 reserve = bound(uint256(rawReserve), 1, 1_000 ether);
        FeeMath.GraduationFeeQuote memory quote = FeeMath.quoteGraduation(reserve);

        assertEq(quote.treasuryAllocation + quote.liquidityBase, reserve);
        assertEq(quote.keeperReimbursement, 0);
    }

    function _assertTradeConserved(FeeMath.TradeFeeQuote memory quote) internal pure {
        assertEq(quote.creatorFee + quote.treasuryFee, quote.totalFee);
        assertEq(quote.netAmount + quote.totalFee, quote.grossAmount);
    }
}
