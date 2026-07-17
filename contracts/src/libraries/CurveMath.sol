// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

/// @title CurveMath
/// @notice Full-precision arithmetic for BabyNoxa's virtual constant-product curve.
/// @dev Inputs and outputs use 18-decimal base and token units. Fees are handled separately.
library CurveMath {
    uint256 internal constant PRICE_SCALE = 1e18;

    struct BuyQuote {
        uint256 tokensOut;
        uint256 netBaseUsed;
        uint256 netBaseRefund;
        uint256 newVirtualBaseReserve;
        uint256 newVirtualTokenReserve;
        uint256 remainingTokenInventory;
        bool completesCurve;
    }

    struct SellQuote {
        uint256 grossBaseOut;
        uint256 newVirtualBaseReserve;
        uint256 newVirtualTokenReserve;
    }

    error ZeroAmount();
    error ZeroReserve();
    error ZeroInventory();
    error ZeroOutput();
    error InvalidInventory(uint256 inventory, uint256 virtualTokenReserve);
    error InvalidTokenOutput(uint256 tokensOut, uint256 virtualTokenReserve);
    error InsufficientRealReserve(uint256 available, uint256 required);

    /// @notice Quotes an exact-input buy and clips a curve-completing buy to real inventory.
    /// @param netBaseAvailable Base input after trading fees.
    function quoteBuy(
        uint256 virtualBaseReserve,
        uint256 virtualTokenReserve,
        uint256 tokenInventory,
        uint256 netBaseAvailable
    ) internal pure returns (BuyQuote memory quote) {
        _requireReserves(virtualBaseReserve, virtualTokenReserve);
        if (tokenInventory == 0) revert ZeroInventory();
        if (tokenInventory >= virtualTokenReserve) {
            revert InvalidInventory(tokenInventory, virtualTokenReserve);
        }
        if (netBaseAvailable == 0) revert ZeroAmount();

        uint256 candidateVirtualBase = virtualBaseReserve + netBaseAvailable;
        uint256 candidateVirtualToken =
            Math.mulDiv(virtualBaseReserve, virtualTokenReserve, candidateVirtualBase, Math.Rounding.Ceil);
        uint256 candidateTokensOut = virtualTokenReserve - candidateVirtualToken;
        if (candidateTokensOut == 0) revert ZeroOutput();

        if (candidateTokensOut < tokenInventory) {
            return BuyQuote({
                tokensOut: candidateTokensOut,
                netBaseUsed: netBaseAvailable,
                netBaseRefund: 0,
                newVirtualBaseReserve: candidateVirtualBase,
                newVirtualTokenReserve: candidateVirtualToken,
                remainingTokenInventory: tokenInventory - candidateTokensOut,
                completesCurve: false
            });
        }

        (uint256 requiredBase, uint256 finalVirtualBase, uint256 finalVirtualToken) =
            netBaseForExactTokensOut(virtualBaseReserve, virtualTokenReserve, tokenInventory);

        quote = BuyQuote({
            tokensOut: tokenInventory,
            netBaseUsed: requiredBase,
            netBaseRefund: netBaseAvailable - requiredBase,
            newVirtualBaseReserve: finalVirtualBase,
            newVirtualTokenReserve: finalVirtualToken,
            remainingTokenInventory: 0,
            completesCurve: true
        });
    }

    /// @notice Calculates the minimum net base input for an exact token output.
    /// @dev The resulting reserve product is greater than or equal to the previous product.
    function netBaseForExactTokensOut(uint256 virtualBaseReserve, uint256 virtualTokenReserve, uint256 tokensOut)
        internal
        pure
        returns (uint256 netBaseIn, uint256 newVirtualBaseReserve, uint256 newVirtualTokenReserve)
    {
        _requireReserves(virtualBaseReserve, virtualTokenReserve);
        if (tokensOut == 0) revert ZeroAmount();
        if (tokensOut >= virtualTokenReserve) {
            revert InvalidTokenOutput(tokensOut, virtualTokenReserve);
        }

        newVirtualTokenReserve = virtualTokenReserve - tokensOut;
        newVirtualBaseReserve =
            Math.mulDiv(virtualBaseReserve, virtualTokenReserve, newVirtualTokenReserve, Math.Rounding.Ceil);
        netBaseIn = newVirtualBaseReserve - virtualBaseReserve;
        if (netBaseIn == 0) revert ZeroOutput();
    }

    /// @notice Quotes an exact-input sell and checks that real reserves cover gross output.
    function quoteSell(
        uint256 virtualBaseReserve,
        uint256 virtualTokenReserve,
        uint256 tokenIn,
        uint256 realBaseReserve
    ) internal pure returns (SellQuote memory quote) {
        _requireReserves(virtualBaseReserve, virtualTokenReserve);
        if (tokenIn == 0) revert ZeroAmount();

        uint256 newVirtualTokenReserve = virtualTokenReserve + tokenIn;
        uint256 newVirtualBaseReserve =
            Math.mulDiv(virtualBaseReserve, virtualTokenReserve, newVirtualTokenReserve, Math.Rounding.Ceil);
        uint256 grossBaseOut = virtualBaseReserve - newVirtualBaseReserve;
        if (grossBaseOut == 0) revert ZeroOutput();
        if (grossBaseOut > realBaseReserve) {
            revert InsufficientRealReserve(realBaseReserve, grossBaseOut);
        }

        quote = SellQuote({
            grossBaseOut: grossBaseOut,
            newVirtualBaseReserve: newVirtualBaseReserve,
            newVirtualTokenReserve: newVirtualTokenReserve
        });
    }

    /// @notice Returns base units per whole token, scaled by 1e18.
    function spotPrice(uint256 virtualBaseReserve, uint256 virtualTokenReserve) internal pure returns (uint256) {
        _requireReserves(virtualBaseReserve, virtualTokenReserve);
        return Math.mulDiv(virtualBaseReserve, PRICE_SCALE, virtualTokenReserve, Math.Rounding.Floor);
    }

    /// @notice Calculates tokens paired at the terminal curve price, rounded up.
    function tokensForLiquidity(
        uint256 baseLiquidity,
        uint256 terminalVirtualBaseReserve,
        uint256 terminalVirtualTokenReserve
    ) internal pure returns (uint256) {
        _requireReserves(terminalVirtualBaseReserve, terminalVirtualTokenReserve);
        if (baseLiquidity == 0) revert ZeroAmount();

        return Math.mulDiv(baseLiquidity, terminalVirtualTokenReserve, terminalVirtualBaseReserve, Math.Rounding.Ceil);
    }

    function _requireReserves(uint256 virtualBaseReserve, uint256 virtualTokenReserve) private pure {
        if (virtualBaseReserve == 0 || virtualTokenReserve == 0) revert ZeroReserve();
    }
}
