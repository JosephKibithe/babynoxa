// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BabyNoxaConstants} from "./BabyNoxaConstants.sol";

/// @title FeeMath
/// @notice Pure fee and refund accounting for BabyNoxa V1.
/// @dev Total fees round down. An indivisible odd fee wei is assigned to treasury.
library FeeMath {
    struct TradeFeeQuote {
        uint256 grossAmount;
        uint256 totalFee;
        uint256 creatorFee;
        uint256 treasuryFee;
        uint256 netAmount;
    }

    struct FinalBuyFeeQuote {
        uint256 grossBaseAvailable;
        uint256 grossBaseUsed;
        uint256 grossBaseRefund;
        uint256 totalFee;
        uint256 creatorFee;
        uint256 treasuryFee;
        uint256 netBaseToCurve;
    }

    struct GraduationFeeQuote {
        uint256 graduationReserve;
        uint256 treasuryAllocation;
        uint256 keeperReimbursement;
        uint256 liquidityBase;
    }

    error ZeroAmount();
    error InsufficientGrossAmount(uint256 available, uint256 required);
    error GrossUpInvariantFailed(uint256 requiredNet, uint256 actualNet);

    /// @notice Calculates the 1% trading fee and its creator/treasury split.
    /// @dev Creator gets floor(fee / 2); treasury receives the remainder.
    function quoteTrade(uint256 grossAmount) internal pure returns (TradeFeeQuote memory quote) {
        if (grossAmount == 0) revert ZeroAmount();

        uint256 totalFee = Math.mulDiv(
            grossAmount, BabyNoxaConstants.TRADE_FEE_BPS, BabyNoxaConstants.BPS_DENOMINATOR, Math.Rounding.Floor
        );
        uint256 creatorFee = totalFee / 2;
        uint256 treasuryFee = totalFee - creatorFee;

        quote = TradeFeeQuote({
            grossAmount: grossAmount,
            totalFee: totalFee,
            creatorFee: creatorFee,
            treasuryFee: treasuryFee,
            netAmount: grossAmount - totalFee
        });
    }

    /// @notice Returns a gross amount whose post-fee net is exactly `netAmount`.
    /// @dev Rounding down is required to invert a fee that itself rounds down.
    function grossFromNet(uint256 netAmount) internal pure returns (uint256 grossAmount) {
        if (netAmount == 0) revert ZeroAmount();

        uint256 feeAmount = Math.mulDiv(
            netAmount,
            BabyNoxaConstants.TRADE_FEE_BPS,
            BabyNoxaConstants.BPS_DENOMINATOR - BabyNoxaConstants.TRADE_FEE_BPS,
            Math.Rounding.Floor
        );
        grossAmount = netAmount + feeAmount;

        TradeFeeQuote memory check = quoteTrade(grossAmount);
        if (check.netAmount != netAmount) {
            revert GrossUpInvariantFailed(netAmount, check.netAmount);
        }
    }

    /// @notice Charges fees only on the gross amount required by a clipped final buy.
    function quoteFinalBuy(uint256 grossBaseAvailable, uint256 netBaseRequired)
        internal
        pure
        returns (FinalBuyFeeQuote memory quote)
    {
        if (grossBaseAvailable == 0 || netBaseRequired == 0) revert ZeroAmount();

        uint256 grossBaseUsed = grossFromNet(netBaseRequired);
        if (grossBaseUsed > grossBaseAvailable) {
            revert InsufficientGrossAmount(grossBaseAvailable, grossBaseUsed);
        }

        TradeFeeQuote memory trade = quoteTrade(grossBaseUsed);
        quote = FinalBuyFeeQuote({
            grossBaseAvailable: grossBaseAvailable,
            grossBaseUsed: grossBaseUsed,
            grossBaseRefund: grossBaseAvailable - grossBaseUsed,
            totalFee: trade.totalFee,
            creatorFee: trade.creatorFee,
            treasuryFee: trade.treasuryFee,
            netBaseToCurve: trade.netAmount
        });
    }

    /// @notice Allocates 10% of the graduation reserve to treasury.
    /// @dev Treasury rounds down; liquidity receives the exact remainder. V1 keeper reimbursement is zero.
    function quoteGraduation(uint256 graduationReserve) internal pure returns (GraduationFeeQuote memory quote) {
        if (graduationReserve == 0) revert ZeroAmount();

        uint256 treasuryAllocation = Math.mulDiv(
            graduationReserve,
            BabyNoxaConstants.GRADUATION_FEE_BPS,
            BabyNoxaConstants.BPS_DENOMINATOR,
            Math.Rounding.Floor
        );

        quote = GraduationFeeQuote({
            graduationReserve: graduationReserve,
            treasuryAllocation: treasuryAllocation,
            keeperReimbursement: 0,
            liquidityBase: graduationReserve - treasuryAllocation
        });
    }
}
