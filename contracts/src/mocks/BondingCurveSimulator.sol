// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BabyNoxaConstants} from "../libraries/BabyNoxaConstants.sol";
import {CurveMath} from "../libraries/CurveMath.sol";
import {FeeMath} from "../libraries/FeeMath.sol";
import {LaunchState} from "../types/BabyNoxaTypes.sol";

/// @title BondingCurveSimulator
/// @notice Deterministic, non-payable reference state machine for the BabyNoxa V1 curve.
/// @dev Uses internal accounting only. It never receives or transfers ETH or ERC-20 tokens.
contract BondingCurveSimulator {
    address public immutable creator;
    address public immutable treasury;

    LaunchState public state;
    uint256 public virtualBaseReserve;
    uint256 public virtualTokenReserve;
    uint256 public realBaseReserve;
    uint256 public curveTokenInventory;
    uint256 public graduationTokenReserve;

    uint256 public creatorTradingFees;
    uint256 public treasuryTradingFees;
    uint256 public graduationTreasuryAllocation;

    uint256 public liquidityBase;
    uint256 public liquidityTokens;
    uint256 public burnedTokens;
    uint256 public mockTotalLp;
    uint256 public mockBurnedLp;
    uint256 public mockTreasuryLp;

    uint256 public totalUserTokenBalances;
    uint256 public totalMockBaseCredits;
    uint256 public totalGrossBaseSubmitted;
    uint256 public totalGrossBaseExecuted;
    uint256 public totalGrossBaseRefunded;

    bool public tradingStarted;
    bool public creatorInitialBuyExecuted;

    mapping(address user => uint256 balance) public tokenBalanceOf;
    mapping(address user => uint256 credit) public mockBaseCreditOf;
    mapping(address user => uint256 refund) public mockRefundOf;

    error ZeroAddress();
    error InvalidState(LaunchState current, LaunchState required);
    error CreatorOnly(address caller);
    error InitialBuyClosed();
    error CreatorInitialBuyCapExceeded(uint256 tokensOut, uint256 cap);
    error InsufficientTokenBalance(uint256 available, uint256 required);
    error TokenSlippageExceeded(uint256 minimum, uint256 actual);
    error BaseSlippageExceeded(uint256 minimum, uint256 actual);
    error GraduationTokenReserveExceeded(uint256 available, uint256 required);
    error AccountingInvariantFailed();

    event TokensPurchased(
        address indexed buyer,
        uint256 grossBaseUsed,
        uint256 netBaseToCurve,
        uint256 tokensOut,
        uint256 creatorFee,
        uint256 treasuryFee
    );
    event TokensSold(
        address indexed seller,
        uint256 tokensIn,
        uint256 grossBaseOut,
        uint256 netBaseCredit,
        uint256 creatorFee,
        uint256 treasuryFee
    );
    event MockRefundRecorded(address indexed buyer, uint256 grossBaseRefund);
    event GraduationExecuted(
        uint256 treasuryAllocation,
        uint256 liquidityBase,
        uint256 liquidityTokens,
        uint256 burnedTokens,
        uint256 burnedLp
    );

    constructor(address creator_, address treasury_) {
        if (creator_ == address(0) || treasury_ == address(0)) revert ZeroAddress();

        creator = creator_;
        treasury = treasury_;
        state = LaunchState.Trading;
        virtualBaseReserve = BabyNoxaConstants.INITIAL_VIRTUAL_BASE_RESERVE;
        virtualTokenReserve = BabyNoxaConstants.INITIAL_VIRTUAL_TOKEN_RESERVE;
        curveTokenInventory = BabyNoxaConstants.CURVE_TOKEN_ALLOCATION;
        graduationTokenReserve = BabyNoxaConstants.GRADUATION_TOKEN_RESERVE;
    }

    /// @notice Executes the optional creator purchase before any public trade.
    function creatorInitialBuy(uint256 grossBaseAvailable, uint256 minimumTokensOut)
        external
        returns (uint256 tokensOut)
    {
        if (msg.sender != creator) revert CreatorOnly(msg.sender);
        if (tradingStarted || creatorInitialBuyExecuted) revert InitialBuyClosed();

        tokensOut = _buy(msg.sender, grossBaseAvailable, minimumTokensOut, true);
        creatorInitialBuyExecuted = true;
    }

    function buy(uint256 grossBaseAvailable, uint256 minimumTokensOut) external returns (uint256 tokensOut) {
        tokensOut = _buy(msg.sender, grossBaseAvailable, minimumTokensOut, false);
    }

    function sell(uint256 tokenAmount, uint256 minimumBaseOut) external returns (uint256 netBaseCredit) {
        _requireTrading();

        uint256 userBalance = tokenBalanceOf[msg.sender];
        if (tokenAmount > userBalance) revert InsufficientTokenBalance(userBalance, tokenAmount);

        CurveMath.SellQuote memory curve =
            CurveMath.quoteSell(virtualBaseReserve, virtualTokenReserve, tokenAmount, realBaseReserve);
        FeeMath.TradeFeeQuote memory fee = FeeMath.quoteTrade(curve.grossBaseOut);
        if (fee.netAmount < minimumBaseOut) revert BaseSlippageExceeded(minimumBaseOut, fee.netAmount);

        virtualBaseReserve = curve.newVirtualBaseReserve;
        virtualTokenReserve = curve.newVirtualTokenReserve;
        realBaseReserve -= curve.grossBaseOut;
        curveTokenInventory += tokenAmount;

        tokenBalanceOf[msg.sender] = userBalance - tokenAmount;
        totalUserTokenBalances -= tokenAmount;
        creatorTradingFees += fee.creatorFee;
        treasuryTradingFees += fee.treasuryFee;
        mockBaseCreditOf[msg.sender] += fee.netAmount;
        totalMockBaseCredits += fee.netAmount;

        emit TokensSold(msg.sender, tokenAmount, curve.grossBaseOut, fee.netAmount, fee.creatorFee, fee.treasuryFee);

        _assertAccounting();
        return fee.netAmount;
    }

    /// @notice Total executed buy input, partitioned across all current and terminal destinations.
    function accountedExecutedBase() public view returns (uint256) {
        return realBaseReserve + creatorTradingFees + treasuryTradingFees + graduationTreasuryAllocation + liquidityBase
            + totalMockBaseCredits;
    }

    /// @notice All minted token units remain assigned to users, curve, graduation, pool, or burn buckets.
    function accountedTokenSupply() public view returns (uint256) {
        return totalUserTokenBalances + curveTokenInventory + graduationTokenReserve + liquidityTokens + burnedTokens;
    }

    function _buy(address buyer, uint256 grossBaseAvailable, uint256 minimumTokensOut, bool isCreatorInitialBuy)
        private
        returns (uint256 tokensOut)
    {
        _requireTrading();

        FeeMath.TradeFeeQuote memory fullFee = FeeMath.quoteTrade(grossBaseAvailable);
        CurveMath.BuyQuote memory curve =
            CurveMath.quoteBuy(virtualBaseReserve, virtualTokenReserve, curveTokenInventory, fullFee.netAmount);

        uint256 grossBaseUsed;
        uint256 grossBaseRefund;
        uint256 creatorFee;
        uint256 treasuryFee;

        if (curve.completesCurve) {
            FeeMath.FinalBuyFeeQuote memory finalFee = FeeMath.quoteFinalBuy(grossBaseAvailable, curve.netBaseUsed);
            grossBaseUsed = finalFee.grossBaseUsed;
            grossBaseRefund = finalFee.grossBaseRefund;
            creatorFee = finalFee.creatorFee;
            treasuryFee = finalFee.treasuryFee;
            if (finalFee.netBaseToCurve != curve.netBaseUsed) revert AccountingInvariantFailed();
        } else {
            grossBaseUsed = grossBaseAvailable;
            creatorFee = fullFee.creatorFee;
            treasuryFee = fullFee.treasuryFee;
            if (fullFee.netAmount != curve.netBaseUsed) revert AccountingInvariantFailed();
        }

        if (isCreatorInitialBuy && curve.tokensOut > BabyNoxaConstants.CREATOR_INITIAL_BUY_CAP) {
            revert CreatorInitialBuyCapExceeded(curve.tokensOut, BabyNoxaConstants.CREATOR_INITIAL_BUY_CAP);
        }
        if (curve.tokensOut < minimumTokensOut) {
            revert TokenSlippageExceeded(minimumTokensOut, curve.tokensOut);
        }

        tradingStarted = true;
        virtualBaseReserve = curve.newVirtualBaseReserve;
        virtualTokenReserve = curve.newVirtualTokenReserve;
        realBaseReserve += curve.netBaseUsed;
        curveTokenInventory = curve.remainingTokenInventory;
        tokenBalanceOf[buyer] += curve.tokensOut;
        totalUserTokenBalances += curve.tokensOut;
        creatorTradingFees += creatorFee;
        treasuryTradingFees += treasuryFee;
        totalGrossBaseSubmitted += grossBaseAvailable;
        totalGrossBaseExecuted += grossBaseUsed;

        if (grossBaseRefund != 0) {
            mockRefundOf[buyer] += grossBaseRefund;
            totalGrossBaseRefunded += grossBaseRefund;
            emit MockRefundRecorded(buyer, grossBaseRefund);
        }

        emit TokensPurchased(buyer, grossBaseUsed, curve.netBaseUsed, curve.tokensOut, creatorFee, treasuryFee);

        if (curve.completesCurve) _graduate();
        _assertAccounting();
        return curve.tokensOut;
    }

    function _graduate() private {
        state = LaunchState.GraduationReady;

        FeeMath.GraduationFeeQuote memory fee = FeeMath.quoteGraduation(realBaseReserve);
        uint256 tokensForPool = CurveMath.tokensForLiquidity(fee.liquidityBase, virtualBaseReserve, virtualTokenReserve);
        if (tokensForPool > graduationTokenReserve) {
            revert GraduationTokenReserveExceeded(graduationTokenReserve, tokensForPool);
        }

        graduationTreasuryAllocation = fee.treasuryAllocation;
        liquidityBase = fee.liquidityBase;
        liquidityTokens = tokensForPool;
        burnedTokens = graduationTokenReserve - tokensForPool;
        graduationTokenReserve = 0;
        realBaseReserve = 0;

        mockTotalLp = Math.sqrt(liquidityBase * liquidityTokens);
        mockBurnedLp = mockTotalLp;
        mockTreasuryLp = 0;
        state = LaunchState.Graduated;

        emit GraduationExecuted(
            graduationTreasuryAllocation, liquidityBase, liquidityTokens, burnedTokens, mockBurnedLp
        );
    }

    function _requireTrading() private view {
        if (state != LaunchState.Trading) revert InvalidState(state, LaunchState.Trading);
    }

    function _assertAccounting() private view {
        if (accountedExecutedBase() != totalGrossBaseExecuted) revert AccountingInvariantFailed();
        if (totalGrossBaseSubmitted != totalGrossBaseExecuted + totalGrossBaseRefunded) {
            revert AccountingInvariantFailed();
        }
        if (accountedTokenSupply() != BabyNoxaConstants.TOTAL_SUPPLY) revert AccountingInvariantFailed();
        if (curveTokenInventory > BabyNoxaConstants.CURVE_TOKEN_ALLOCATION) revert AccountingInvariantFailed();
    }
}
