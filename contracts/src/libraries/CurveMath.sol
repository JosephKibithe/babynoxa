// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title CurveMath
/// @notice Pure arithmetic for BabyNoxa's virtual-reserve constant-product curve.
/// @dev Reserve updates round upward so the constant product cannot decrease.
library CurveMath {
    uint256 internal constant PRICE_SCALE = 1e18;

    error ZeroAmount();
    error ZeroReserve();

    function ceilDiv(uint256 numerator, uint256 denominator) internal pure returns (uint256) {
        if (denominator == 0) revert ZeroReserve();
        if (numerator == 0) return 0;

        return ((numerator - 1) / denominator) + 1;
    }

    /// @return tokensOut Tokens released by the virtual token reserve.
    /// @return newBaseReserve Virtual base reserve after the buy.
    /// @return newTokenReserve Virtual token reserve after the buy.
    function quoteBuy(uint256 baseReserve, uint256 tokenReserve, uint256 baseIn)
        internal
        pure
        returns (uint256 tokensOut, uint256 newBaseReserve, uint256 newTokenReserve)
    {
        _requireReserves(baseReserve, tokenReserve);
        if (baseIn == 0) revert ZeroAmount();

        uint256 invariant = baseReserve * tokenReserve;
        newBaseReserve = baseReserve + baseIn;
        newTokenReserve = ceilDiv(invariant, newBaseReserve);
        tokensOut = tokenReserve - newTokenReserve;
    }

    /// @return baseOut Base units released by the virtual base reserve.
    /// @return newBaseReserve Virtual base reserve after the sell.
    /// @return newTokenReserve Virtual token reserve after the sell.
    function quoteSell(uint256 baseReserve, uint256 tokenReserve, uint256 tokenIn)
        internal
        pure
        returns (uint256 baseOut, uint256 newBaseReserve, uint256 newTokenReserve)
    {
        _requireReserves(baseReserve, tokenReserve);
        if (tokenIn == 0) revert ZeroAmount();

        uint256 invariant = baseReserve * tokenReserve;
        newTokenReserve = tokenReserve + tokenIn;
        newBaseReserve = ceilDiv(invariant, newTokenReserve);
        baseOut = baseReserve - newBaseReserve;
    }

    /// @notice Returns base units per token, scaled by 1e18.
    function spotPrice(uint256 baseReserve, uint256 tokenReserve) internal pure returns (uint256) {
        _requireReserves(baseReserve, tokenReserve);
        return (baseReserve * PRICE_SCALE) / tokenReserve;
    }

    /// @notice Calculates tokens to pair with base liquidity at the curve's terminal price.
    function tokensForLiquidity(uint256 baseLiquidity, uint256 terminalBaseReserve, uint256 terminalTokenReserve)
        internal
        pure
        returns (uint256)
    {
        _requireReserves(terminalBaseReserve, terminalTokenReserve);
        if (baseLiquidity == 0) revert ZeroAmount();

        return ceilDiv(baseLiquidity * terminalTokenReserve, terminalBaseReserve);
    }

    function _requireReserves(uint256 baseReserve, uint256 tokenReserve) private pure {
        if (baseReserve == 0 || tokenReserve == 0) revert ZeroReserve();
    }
}
