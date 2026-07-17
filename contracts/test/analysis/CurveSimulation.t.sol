// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {BabyNoxaConstants} from "../../src/libraries/BabyNoxaConstants.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";
import {FeeMath} from "../../src/libraries/FeeMath.sol";

/// @notice Reports the confirmed V1 terminal curve and graduation geometry.
contract CurveSimulationTest is Test {
    function test_ConfirmedV1Geometry() public pure {
        (uint256 netReserve, uint256 terminalVirtualBase, uint256 terminalVirtualToken) = CurveMath.netBaseForExactTokensOut(
            BabyNoxaConstants.INITIAL_VIRTUAL_BASE_RESERVE,
            BabyNoxaConstants.INITIAL_VIRTUAL_TOKEN_RESERVE,
            BabyNoxaConstants.CURVE_TOKEN_ALLOCATION
        );
        FeeMath.FinalBuyFeeQuote memory finalBuy = FeeMath.quoteFinalBuy(10 ether, netReserve);
        FeeMath.GraduationFeeQuote memory graduation = FeeMath.quoteGraduation(netReserve);
        uint256 liquidityTokens =
            CurveMath.tokensForLiquidity(graduation.liquidityBase, terminalVirtualBase, terminalVirtualToken);
        uint256 burnedTokens = BabyNoxaConstants.GRADUATION_TOKEN_RESERVE - liquidityTokens;

        assertEq(terminalVirtualToken, BabyNoxaConstants.TERMINAL_VIRTUAL_TOKEN_RESERVE);
        assertEq(netReserve, 4_274_999_994_656_250_007);
        assertEq(finalBuy.netBaseToCurve, netReserve);
        assertEq(finalBuy.grossBaseUsed + finalBuy.grossBaseRefund, finalBuy.grossBaseAvailable);
        assertEq(liquidityTokens, 180_000_000_168_749_999_983_385_874);
        assertEq(liquidityTokens + burnedTokens, BabyNoxaConstants.GRADUATION_TOKEN_RESERVE);

        console2.log("Confirmed BabyNoxa V1 curve");
        console2.log("  final gross base used (wei)", finalBuy.grossBaseUsed);
        console2.log("  final trading fee (wei)", finalBuy.totalFee);
        console2.log("  net graduation reserve (wei)", netReserve);
        console2.log("  treasury allocation (wei)", graduation.treasuryAllocation);
        console2.log("  liquidity base (wei)", graduation.liquidityBase);
        console2.log("  liquidity tokens (token wei)", liquidityTokens);
        console2.log("  burned tokens (token wei)", burnedTokens);
        console2.log("  terminal price (wei/token)", CurveMath.spotPrice(terminalVirtualBase, terminalVirtualToken));
    }
}
