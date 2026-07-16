// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";

contract CurveMathTest is Test {
    uint256 internal constant BASE_RESERVE = 10 ether;
    uint256 internal constant TOKEN_RESERVE = 800_000_000 ether;

    function exposedQuoteBuy(uint256 baseReserve, uint256 tokenReserve, uint256 baseIn)
        external
        pure
        returns (uint256, uint256, uint256)
    {
        return CurveMath.quoteBuy(baseReserve, tokenReserve, baseIn);
    }

    function exposedQuoteSell(uint256 baseReserve, uint256 tokenReserve, uint256 tokenIn)
        external
        pure
        returns (uint256, uint256, uint256)
    {
        return CurveMath.quoteSell(baseReserve, tokenReserve, tokenIn);
    }

    function test_CeilDivRoundsUp() public pure {
        assertEq(CurveMath.ceilDiv(10, 3), 4);
        assertEq(CurveMath.ceilDiv(9, 3), 3);
        assertEq(CurveMath.ceilDiv(0, 3), 0);
    }

    function test_BuyPreservesConstantProduct() public pure {
        (, uint256 newBaseReserve, uint256 newTokenReserve) = CurveMath.quoteBuy(BASE_RESERVE, TOKEN_RESERVE, 1 ether);

        assertGe(newBaseReserve * newTokenReserve, BASE_RESERVE * TOKEN_RESERVE);
    }

    function test_SellPreservesConstantProduct() public pure {
        (, uint256 newBaseReserve, uint256 newTokenReserve) =
            CurveMath.quoteSell(BASE_RESERVE, TOKEN_RESERVE, 1_000_000 ether);

        assertGe(newBaseReserve * newTokenReserve, BASE_RESERVE * TOKEN_RESERVE);
    }

    function test_LargerBuysHaveWorseAveragePrice() public pure {
        (uint256 smallTokens,,) = CurveMath.quoteBuy(BASE_RESERVE, TOKEN_RESERVE, 0.1 ether);
        (uint256 largeTokens,,) = CurveMath.quoteBuy(BASE_RESERVE, TOKEN_RESERVE, 1 ether);

        uint256 smallTokensPerBase = smallTokens * 1 ether / 0.1 ether;
        uint256 largeTokensPerBase = largeTokens * 1 ether / 1 ether;
        assertLt(largeTokensPerBase, smallTokensPerBase);
    }

    function test_BuyThenSellCannotProfitFromRounding() public pure {
        uint256 baseIn = 1 ether;
        (uint256 tokensOut, uint256 baseAfterBuy, uint256 tokensAfterBuy) =
            CurveMath.quoteBuy(BASE_RESERVE, TOKEN_RESERVE, baseIn);
        (uint256 baseOut,,) = CurveMath.quoteSell(baseAfterBuy, tokensAfterBuy, tokensOut);

        assertLe(baseOut, baseIn);
    }

    function test_LiquidityTokensMatchTerminalPrice() public pure {
        uint256 baseLiquidity = 9 ether;
        uint256 tokens = CurveMath.tokensForLiquidity(baseLiquidity, BASE_RESERVE, TOKEN_RESERVE);

        uint256 curvePrice = CurveMath.spotPrice(BASE_RESERVE, TOKEN_RESERVE);
        uint256 liquidityPrice = baseLiquidity * 1 ether / tokens;
        assertApproxEqAbs(liquidityPrice, curvePrice, 1);
    }

    function test_RevertWhenAmountIsZero() public {
        vm.expectRevert(CurveMath.ZeroAmount.selector);
        this.exposedQuoteBuy(BASE_RESERVE, TOKEN_RESERVE, 0);

        vm.expectRevert(CurveMath.ZeroAmount.selector);
        this.exposedQuoteSell(BASE_RESERVE, TOKEN_RESERVE, 0);
    }

    function test_RevertWhenAReserveIsZero() public {
        vm.expectRevert(CurveMath.ZeroReserve.selector);
        this.exposedQuoteBuy(0, TOKEN_RESERVE, 1 ether);

        vm.expectRevert(CurveMath.ZeroReserve.selector);
        this.exposedQuoteSell(BASE_RESERVE, 0, 1 ether);
    }

    function testFuzz_BuyNeverDecreasesInvariant(uint96 rawBaseIn) public pure {
        uint256 baseIn = bound(uint256(rawBaseIn), 1, 100 ether);
        (, uint256 newBaseReserve, uint256 newTokenReserve) = CurveMath.quoteBuy(BASE_RESERVE, TOKEN_RESERVE, baseIn);

        assertGe(newBaseReserve * newTokenReserve, BASE_RESERVE * TOKEN_RESERVE);
    }

    function testFuzz_BuyThenSellCannotProfit(uint96 rawBaseIn) public pure {
        uint256 baseIn = bound(uint256(rawBaseIn), 1, 100 ether);
        (uint256 tokensOut, uint256 baseAfterBuy, uint256 tokensAfterBuy) =
            CurveMath.quoteBuy(BASE_RESERVE, TOKEN_RESERVE, baseIn);

        if (tokensOut == 0) return;

        (uint256 baseOut,,) = CurveMath.quoteSell(baseAfterBuy, tokensAfterBuy, tokensOut);
        assertLe(baseOut, baseIn);
    }
}
