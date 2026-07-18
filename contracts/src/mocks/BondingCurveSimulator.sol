// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {BabyNoxaConstants} from "../libraries/BabyNoxaConstants.sol";
import {CurveMath} from "../libraries/CurveMath.sol";
import {DeadlinePolicy} from "../libraries/DeadlinePolicy.sol";
import {FeeMath} from "../libraries/FeeMath.sol";
import {LaunchState} from "../types/BabyNoxaTypes.sol";

/// @title BondingCurveSimulator
/// @notice Payable reference state machine for the BabyNoxa V1 curve.
/// @dev Custodies and transfers ETH, while token and LP balances remain simulated until token/AMM integration.
contract BondingCurveSimulator is ReentrancyGuard {
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
    uint256 public totalClaimableBase;
    uint256 public totalGrossBaseSubmitted;
    uint256 public totalGrossBaseExecuted;
    uint256 public totalGrossBaseRefunded;
    uint256 public totalOutstandingRefunds;

    bool public tradingStarted;
    bool public creatorInitialBuyExecuted;

    mapping(address user => uint256 balance) public tokenBalanceOf;
    mapping(address user => uint256 credit) public claimableBaseOf;
    mapping(address user => uint256 refund) public claimableRefundOf;

    error ZeroAddress();
    error InvalidState(LaunchState current, LaunchState required);
    error CreatorOnly(address caller);
    error TreasuryOnly(address caller);
    error CreatorInitialBuyCapExceeded(uint256 tokensOut, uint256 cap);
    error InsufficientTokenBalance(uint256 available, uint256 required);
    error TokenSlippageExceeded(uint256 minimum, uint256 actual);
    error BaseSlippageExceeded(uint256 minimum, uint256 actual);
    error GraduationTokenReserveExceeded(uint256 available, uint256 required);
    error TradeValueBelowMinimum(uint256 actual, uint256 minimum);
    error UnfillableCurveRemainder(uint256 remainingTokens, uint256 requiredGrossBase);
    error AccountingInvariantFailed();
    error NoClaimableAmount(address account);
    error EtherTransferFailed(address recipient, uint256 amount);

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
    event RefundRecorded(address indexed buyer, uint256 grossBaseRefund);
    event CreatorFeeAccrued(address indexed beneficiary, address indexed trader, uint256 amount, bool isBuy);
    event TreasuryFeeAccrued(address indexed beneficiary, address indexed trader, uint256 amount, bool isBuy);
    event LaunchOpened(bool creatorPurchased, uint256 grossBaseSubmitted, uint256 creatorTokensOut);
    event GraduationExecuted(
        uint256 treasuryAllocation,
        uint256 liquidityBase,
        uint256 liquidityTokens,
        uint256 burnedTokens,
        uint256 burnedLp
    );
    event EtherClaimed(address indexed account, address indexed recipient, uint256 amount, bytes32 indexed claimType);

    modifier onlyCreator() {
        if (msg.sender != creator) revert CreatorOnly(msg.sender);
        _;
    }

    modifier onlyTreasury() {
        if (msg.sender != treasury) revert TreasuryOnly(msg.sender);
        _;
    }

    constructor(address creator_, address treasury_) {
        if (creator_ == address(0) || treasury_ == address(0)) revert ZeroAddress();

        creator = creator_;
        treasury = treasury_;
        state = LaunchState.Created;
        virtualBaseReserve = BabyNoxaConstants.INITIAL_VIRTUAL_BASE_RESERVE;
        virtualTokenReserve = BabyNoxaConstants.INITIAL_VIRTUAL_TOKEN_RESERVE;
        curveTokenInventory = BabyNoxaConstants.CURVE_TOKEN_ALLOCATION;
        graduationTokenReserve = BabyNoxaConstants.GRADUATION_TOKEN_RESERVE;
    }

    /// @notice Atomically opens public trading with an optional creator purchase.
    /// @dev A zero-value launch skips the creator purchase. A funded launch executes the capped
    ///      creator purchase before this transaction completes, so no public buyer can front-run it.
    function launch(uint256 minimumCreatorTokensOut, uint256 deadline)
        external
        payable
        onlyCreator
        nonReentrant
        returns (uint256 creatorTokensOut)
    {
        if (state != LaunchState.Created) revert InvalidState(state, LaunchState.Created);
        DeadlinePolicy.enforce(deadline);
        if (msg.value == 0 && minimumCreatorTokensOut != 0) {
            revert TokenSlippageExceeded(minimumCreatorTokensOut, 0);
        }

        state = LaunchState.Trading;

        if (msg.value != 0) {
            creatorTokensOut = _buy(msg.sender, minimumCreatorTokensOut, true, deadline);
            creatorInitialBuyExecuted = true;
        } else {
            _assertAccounting();
        }

        emit LaunchOpened(msg.value != 0, msg.value, creatorTokensOut);
    }

    function buy(uint256 minimumTokensOut, uint256 deadline) external payable nonReentrant returns (uint256 tokensOut) {
        tokensOut = _buy(msg.sender, minimumTokensOut, false, deadline);
    }

    function sell(uint256 tokenAmount, uint256 minimumBaseOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 netBaseCredit)
    {
        _requireTrading();
        DeadlinePolicy.enforce(deadline);

        uint256 userBalance = tokenBalanceOf[msg.sender];
        if (tokenAmount > userBalance) revert InsufficientTokenBalance(userBalance, tokenAmount);

        CurveMath.SellQuote memory curve =
            CurveMath.quoteSell(virtualBaseReserve, virtualTokenReserve, tokenAmount, realBaseReserve);
        _enforceMinimumTrade(curve.grossBaseOut);
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
        claimableBaseOf[msg.sender] += fee.netAmount;
        totalClaimableBase += fee.netAmount;

        emit CreatorFeeAccrued(creator, msg.sender, fee.creatorFee, false);
        emit TreasuryFeeAccrued(treasury, msg.sender, fee.treasuryFee, false);
        emit TokensSold(msg.sender, tokenAmount, curve.grossBaseOut, fee.netAmount, fee.creatorFee, fee.treasuryFee);

        _assertAccounting();
        return fee.netAmount;
    }

    /// @notice Total executed buy input, partitioned across all current and terminal destinations.
    function accountedExecutedBase() public view returns (uint256) {
        return realBaseReserve + creatorTradingFees + treasuryTradingFees + graduationTreasuryAllocation + liquidityBase
            + totalClaimableBase;
    }

    /// @notice Current ETH liabilities and locked liquidity must equal the contract's ETH balance.
    function accountedContractBalance() public view returns (uint256) {
        return accountedExecutedBase() + totalOutstandingRefunds;
    }

    /// @notice All minted token units remain assigned to users, curve, graduation, pool, or burn buckets.
    function accountedTokenSupply() public view returns (uint256) {
        return totalUserTokenBalances + curveTokenInventory + graduationTokenReserve + liquidityTokens + burnedTokens;
    }

    function claimRefund() external nonReentrant returns (uint256 amount) {
        return _claimRefund(msg.sender, payable(msg.sender));
    }

    function claimRefundTo(address payable recipient) external nonReentrant returns (uint256 amount) {
        return _claimRefund(msg.sender, recipient);
    }

    function claimBaseCredit() external nonReentrant returns (uint256 amount) {
        return _claimBaseCredit(msg.sender, payable(msg.sender));
    }

    function claimBaseCreditTo(address payable recipient) external nonReentrant returns (uint256 amount) {
        return _claimBaseCredit(msg.sender, recipient);
    }

    function claimCreatorFees() external onlyCreator nonReentrant returns (uint256 amount) {
        return _claimCreatorFees(payable(msg.sender));
    }

    function claimCreatorFeesTo(address payable recipient) external onlyCreator nonReentrant returns (uint256 amount) {
        return _claimCreatorFees(recipient);
    }

    function claimTreasuryFees() external onlyTreasury nonReentrant returns (uint256 amount) {
        return _claimTreasuryFees(payable(msg.sender));
    }

    function claimTreasuryFeesTo(address payable recipient)
        external
        onlyTreasury
        nonReentrant
        returns (uint256 amount)
    {
        return _claimTreasuryFees(recipient);
    }

    function _buy(address buyer, uint256 minimumTokensOut, bool isCreatorInitialBuy, uint256 deadline)
        private
        returns (uint256 tokensOut)
    {
        _requireTrading();
        DeadlinePolicy.enforce(deadline);

        uint256 grossBaseAvailable = msg.value;

        FeeMath.TradeFeeQuote memory fullFee = FeeMath.quoteTrade(grossBaseAvailable);
        CurveMath.BuyQuote memory curve =
            CurveMath.quoteBuy(virtualBaseReserve, virtualTokenReserve, curveTokenInventory, fullFee.netAmount);

        uint256 grossBaseUsed;
        uint256 grossBaseRefund = 0;
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

        _enforceMinimumTrade(grossBaseUsed);
        if (!curve.completesCurve) _enforceFillableRemainder(curve);

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

        emit CreatorFeeAccrued(creator, buyer, creatorFee, true);
        emit TreasuryFeeAccrued(treasury, buyer, treasuryFee, true);

        if (grossBaseRefund != 0) {
            claimableRefundOf[buyer] += grossBaseRefund;
            totalGrossBaseRefunded += grossBaseRefund;
            totalOutstandingRefunds += grossBaseRefund;
            emit RefundRecorded(buyer, grossBaseRefund);
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

    function _claimRefund(address account, address payable recipient) private returns (uint256 amount) {
        _requireRecipient(recipient);
        amount = claimableRefundOf[account];
        if (amount == 0) revert NoClaimableAmount(account);

        claimableRefundOf[account] = 0;
        totalOutstandingRefunds -= amount;
        _sendEther(account, recipient, amount, keccak256("REFUND"));
        _assertAccounting();
    }

    function _claimBaseCredit(address account, address payable recipient) private returns (uint256 amount) {
        _requireRecipient(recipient);
        amount = claimableBaseOf[account];
        if (amount == 0) revert NoClaimableAmount(account);

        claimableBaseOf[account] = 0;
        totalClaimableBase -= amount;
        _sendEther(account, recipient, amount, keccak256("SELL_PROCEEDS"));
        _assertAccounting();
    }

    function _claimCreatorFees(address payable recipient) private returns (uint256 amount) {
        _requireRecipient(recipient);
        amount = creatorTradingFees;
        if (amount == 0) revert NoClaimableAmount(msg.sender);

        creatorTradingFees = 0;
        _sendEther(msg.sender, recipient, amount, keccak256("CREATOR_FEES"));
        _assertAccounting();
    }

    function _claimTreasuryFees(address payable recipient) private returns (uint256 amount) {
        _requireRecipient(recipient);
        amount = treasuryTradingFees + graduationTreasuryAllocation;
        if (amount == 0) revert NoClaimableAmount(msg.sender);

        treasuryTradingFees = 0;
        graduationTreasuryAllocation = 0;
        _sendEther(msg.sender, recipient, amount, keccak256("TREASURY_FEES"));
        _assertAccounting();
    }

    function _enforceMinimumTrade(uint256 grossBaseExecuted) private pure {
        if (grossBaseExecuted < BabyNoxaConstants.MIN_GROSS_TRADE_VALUE) {
            revert TradeValueBelowMinimum(grossBaseExecuted, BabyNoxaConstants.MIN_GROSS_TRADE_VALUE);
        }
    }

    function _enforceFillableRemainder(CurveMath.BuyQuote memory curve) private pure {
        (uint256 remainingNetBase,,) = CurveMath.netBaseForExactTokensOut(
            curve.newVirtualBaseReserve, curve.newVirtualTokenReserve, curve.remainingTokenInventory
        );
        uint256 remainingGrossBase = FeeMath.grossFromNet(remainingNetBase);
        if (remainingGrossBase < BabyNoxaConstants.MIN_GROSS_TRADE_VALUE) {
            revert UnfillableCurveRemainder(curve.remainingTokenInventory, remainingGrossBase);
        }
    }

    function _requireRecipient(address recipient) private pure {
        if (recipient == address(0)) revert ZeroAddress();
    }

    function _sendEther(address account, address recipient, uint256 amount, bytes32 claimType) private {
        (bool success,) = payable(recipient).call{value: amount}("");
        if (!success) revert EtherTransferFailed(recipient, amount);
        emit EtherClaimed(account, recipient, amount, claimType);
    }

    function _assertAccounting() private view {
        // ETH can be forced into a contract. Solvency requires at least the accounted liabilities.
        if (address(this).balance < accountedContractBalance()) revert AccountingInvariantFailed();
        if (totalGrossBaseSubmitted != totalGrossBaseExecuted + totalGrossBaseRefunded) {
            revert AccountingInvariantFailed();
        }
        if (accountedTokenSupply() != BabyNoxaConstants.TOTAL_SUPPLY) revert AccountingInvariantFailed();
        if (curveTokenInventory > BabyNoxaConstants.CURVE_TOKEN_ALLOCATION) revert AccountingInvariantFailed();
    }
}
