// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IBabyNoxaToken} from "./interfaces/IBabyNoxaToken.sol";
import {IBondingCurve} from "./interfaces/IBondingCurve.sol";
import {IGraduationManager} from "./interfaces/IGraduationManager.sol";
import {BabyNoxaConstants} from "./libraries/BabyNoxaConstants.sol";
import {CurveMath} from "./libraries/CurveMath.sol";
import {DeadlinePolicy} from "./libraries/DeadlinePolicy.sol";
import {FeeMath} from "./libraries/FeeMath.sol";
import {GraduationParams, GraduationResult, LaunchConfig, LaunchState} from "./types/BabyNoxaTypes.sol";

/// @title BondingCurve
/// @notice One fixed-supply BabyNoxa token's production pre-graduation market.
/// @dev The deploying factory must fund this contract with the complete token supply before calling launch.
contract BondingCurve is IBondingCurve, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 internal constant REFUND_CLAIM = keccak256("REFUND");
    bytes32 internal constant SELL_PROCEEDS_CLAIM = keccak256("SELL_PROCEEDS");
    bytes32 internal constant CREATOR_FEES_CLAIM = keccak256("CREATOR_FEES");
    bytes32 internal constant TREASURY_FEES_CLAIM = keccak256("TREASURY_FEES");

    uint256 public immutable launchId;
    address public immutable override factory;
    address public immutable override token;
    address public immutable override creator;
    address public immutable override treasury;
    address public immutable override graduationManager;
    address public immutable override officialPair;

    LaunchState public override state;
    uint256 public override virtualBaseReserve;
    uint256 public override virtualTokenReserve;
    uint256 public override realBaseReserve;
    uint256 public override curveTokenInventory;
    uint256 public override graduationTokenReserve;
    uint256 public override creatorTradingFees;
    uint256 public override treasuryTradingFees;
    uint256 public override graduationTreasuryAllocation;

    mapping(address account => uint256 amount) public override claimableBaseOf;
    mapping(address account => uint256 amount) public override claimableRefundOf;

    uint256 public totalClaimableBase;
    uint256 public totalOutstandingRefunds;
    uint256 public totalGrossBaseSubmitted;
    uint256 public totalGrossBaseExecuted;
    uint256 public totalGrossBaseRefunded;
    uint256 public totalExecutedBaseWithdrawn;
    uint256 public totalRefundBaseWithdrawn;

    uint256 public totalSellCreditsAccrued;
    uint256 public totalSellCreditsClaimed;
    uint256 public totalCreatorFeesAccrued;
    uint256 public totalCreatorFeesClaimed;
    uint256 public totalTreasuryFeesAccrued;
    uint256 public totalTreasuryFeesClaimed;

    uint256 public graduatedLiquidityBase;
    uint256 public graduatedLiquidityTokens;
    uint256 public graduatedBurnedTokens;
    uint256 public graduatedBurnedLp;
    uint256 public unsolicitedTokenBurned;

    bool public tradingStarted;
    bool public creatorInitialBuyExecuted;

    error ZeroAddress();
    error InvalidLaunchId();
    error InvalidVirtualReserves(uint256 virtualBase, uint256 virtualTokens);
    error FactoryOnly(address caller);
    error CreatorOnly(address caller);
    error TreasuryOnly(address caller);
    error InvalidState(LaunchState current, LaunchState required);
    error TokenSupplyMismatch(uint256 expected, uint256 actual);
    error TokenFundingMismatch(uint256 expected, uint256 actual);
    error TokenTransferAmountMismatch(uint256 expected, uint256 actual);
    error CreatorInitialBuyCapExceeded(uint256 tokensOut, uint256 cap);
    error InsufficientTokenBalance(uint256 available, uint256 required);
    error TokenSlippageExceeded(uint256 minimum, uint256 actual);
    error BaseSlippageExceeded(uint256 minimum, uint256 actual);
    error GraduationTokenReserveExceeded(uint256 available, uint256 required);
    error TradeValueBelowMinimum(uint256 actual, uint256 minimum);
    error UnfillableCurveRemainder(uint256 remainingTokens, uint256 requiredGrossBase);
    error InvalidGraduationResult();
    error AccountingInvariantFailed();
    error NoClaimableAmount(address account);
    error EtherTransferFailed(address recipient, uint256 amount);

    event LaunchOpened(bool creatorPurchased, uint256 grossBaseSubmitted, uint256 creatorTokensOut);
    event UnsolicitedTokensBurned(uint256 amount);

    modifier onlyFactory() {
        if (msg.sender != factory) revert FactoryOnly(msg.sender);
        _;
    }

    modifier onlyCreator() {
        if (msg.sender != creator) revert CreatorOnly(msg.sender);
        _;
    }

    modifier onlyTreasury() {
        if (msg.sender != treasury) revert TreasuryOnly(msg.sender);
        _;
    }

    constructor(LaunchConfig memory config, address factory_) {
        if (
            factory_ == address(0) || config.creator == address(0) || config.token == address(0)
                || config.treasury == address(0) || config.graduationManager == address(0)
                || config.officialPair == address(0)
        ) revert ZeroAddress();
        if (config.launchId == 0) revert InvalidLaunchId();
        if (
            config.initialVirtualBaseReserve == 0
                || config.initialVirtualTokenReserve <= BabyNoxaConstants.CURVE_TOKEN_ALLOCATION
        ) {
            revert InvalidVirtualReserves(config.initialVirtualBaseReserve, config.initialVirtualTokenReserve);
        }

        launchId = config.launchId;
        factory = factory_;
        token = config.token;
        creator = config.creator;
        treasury = config.treasury;
        graduationManager = config.graduationManager;
        officialPair = config.officialPair;
        state = LaunchState.Created;
        virtualBaseReserve = config.initialVirtualBaseReserve;
        virtualTokenReserve = config.initialVirtualTokenReserve;
        curveTokenInventory = BabyNoxaConstants.CURVE_TOKEN_ALLOCATION;
        graduationTokenReserve = BabyNoxaConstants.GRADUATION_TOKEN_RESERVE;
    }

    /// @inheritdoc IBondingCurve
    function launch(uint256 minimumCreatorTokensOut, uint256 deadline)
        external
        payable
        override
        onlyFactory
        nonReentrant
        returns (uint256 creatorTokensOut)
    {
        if (state != LaunchState.Created) revert InvalidState(state, LaunchState.Created);
        DeadlinePolicy.enforce(deadline);

        uint256 supply = IERC20(token).totalSupply();
        if (supply != BabyNoxaConstants.TOTAL_SUPPLY) {
            revert TokenSupplyMismatch(BabyNoxaConstants.TOTAL_SUPPLY, supply);
        }
        uint256 funding = IERC20(token).balanceOf(address(this));
        if (funding != BabyNoxaConstants.TOTAL_SUPPLY) {
            revert TokenFundingMismatch(BabyNoxaConstants.TOTAL_SUPPLY, funding);
        }
        if (msg.value == 0 && minimumCreatorTokensOut != 0) {
            revert TokenSlippageExceeded(minimumCreatorTokensOut, 0);
        }

        state = LaunchState.Trading;
        if (msg.value != 0) {
            creatorTokensOut = _buy(creator, minimumCreatorTokensOut, true, deadline);
            creatorInitialBuyExecuted = true;
        } else {
            _assertAccounting();
        }

        emit LaunchOpened(msg.value != 0, msg.value, creatorTokensOut);
    }

    /// @inheritdoc IBondingCurve
    function buy(uint256 minimumTokensOut, uint256 deadline)
        external
        payable
        override
        nonReentrant
        returns (uint256 tokensOut)
    {
        return _buy(msg.sender, minimumTokensOut, false, deadline);
    }

    /// @inheritdoc IBondingCurve
    function sell(uint256 tokenAmount, uint256 minimumBaseOut, uint256 deadline)
        external
        override
        nonReentrant
        returns (uint256 netBaseCredit)
    {
        _requireTrading();
        DeadlinePolicy.enforce(deadline);

        uint256 sellerBalance = IERC20(token).balanceOf(msg.sender);
        if (tokenAmount > sellerBalance) revert InsufficientTokenBalance(sellerBalance, tokenAmount);

        CurveMath.SellQuote memory curve =
            CurveMath.quoteSell(virtualBaseReserve, virtualTokenReserve, tokenAmount, realBaseReserve);
        _enforceMinimumTrade(curve.grossBaseOut);
        FeeMath.TradeFeeQuote memory fee = FeeMath.quoteTrade(curve.grossBaseOut);
        if (fee.netAmount < minimumBaseOut) revert BaseSlippageExceeded(minimumBaseOut, fee.netAmount);

        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);
        uint256 received = IERC20(token).balanceOf(address(this)) - balanceBefore;
        if (received != tokenAmount) revert TokenTransferAmountMismatch(tokenAmount, received);

        virtualBaseReserve = curve.newVirtualBaseReserve;
        virtualTokenReserve = curve.newVirtualTokenReserve;
        realBaseReserve -= curve.grossBaseOut;
        curveTokenInventory += tokenAmount;
        creatorTradingFees += fee.creatorFee;
        treasuryTradingFees += fee.treasuryFee;
        claimableBaseOf[msg.sender] += fee.netAmount;
        totalClaimableBase += fee.netAmount;
        totalSellCreditsAccrued += fee.netAmount;
        totalCreatorFeesAccrued += fee.creatorFee;
        totalTreasuryFeesAccrued += fee.treasuryFee;

        emit CreatorFeeAccrued(creator, msg.sender, fee.creatorFee, false);
        emit TreasuryFeeAccrued(treasury, msg.sender, fee.treasuryFee, false);
        emit SellCreditAccrued(msg.sender, fee.netAmount);
        emit TokensSold(msg.sender, tokenAmount, curve.grossBaseOut, fee.netAmount, fee.creatorFee, fee.treasuryFee);

        _assertAccounting();
        return fee.netAmount;
    }

    /// @inheritdoc IBondingCurve
    function accountedExecutedBase() public view override returns (uint256) {
        return
            realBaseReserve + creatorTradingFees + treasuryTradingFees + graduationTreasuryAllocation
                + totalClaimableBase;
    }

    /// @inheritdoc IBondingCurve
    function accountedContractBalance() public view override returns (uint256) {
        return accountedExecutedBase() + totalOutstandingRefunds;
    }

    /// @inheritdoc IBondingCurve
    function accountedTokenSupply() public view override returns (uint256) {
        return IERC20(token).totalSupply() + graduatedBurnedTokens + unsolicitedTokenBurned;
    }

    /// @inheritdoc IBondingCurve
    function claimRefund() external override nonReentrant returns (uint256 amount) {
        return _claimRefund(msg.sender, payable(msg.sender));
    }

    /// @inheritdoc IBondingCurve
    function claimRefundTo(address payable recipient) external override nonReentrant returns (uint256 amount) {
        return _claimRefund(msg.sender, recipient);
    }

    /// @inheritdoc IBondingCurve
    function claimBaseCredit() external override nonReentrant returns (uint256 amount) {
        return _claimBaseCredit(msg.sender, payable(msg.sender));
    }

    /// @inheritdoc IBondingCurve
    function claimBaseCreditTo(address payable recipient) external override nonReentrant returns (uint256 amount) {
        return _claimBaseCredit(msg.sender, recipient);
    }

    /// @inheritdoc IBondingCurve
    function claimCreatorFees() external override onlyCreator nonReentrant returns (uint256 amount) {
        return _claimCreatorFees(payable(msg.sender));
    }

    /// @inheritdoc IBondingCurve
    function claimCreatorFeesTo(address payable recipient)
        external
        override
        onlyCreator
        nonReentrant
        returns (uint256 amount)
    {
        return _claimCreatorFees(recipient);
    }

    /// @inheritdoc IBondingCurve
    function claimTreasuryFees() external override onlyTreasury nonReentrant returns (uint256 amount) {
        return _claimTreasuryFees(payable(msg.sender));
    }

    /// @inheritdoc IBondingCurve
    function claimTreasuryFeesTo(address payable recipient)
        external
        override
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
        if (grossBaseAvailable < BabyNoxaConstants.MIN_GROSS_TRADE_VALUE) {
            revert TradeValueBelowMinimum(grossBaseAvailable, BabyNoxaConstants.MIN_GROSS_TRADE_VALUE);
        }

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
        creatorTradingFees += creatorFee;
        treasuryTradingFees += treasuryFee;
        totalCreatorFeesAccrued += creatorFee;
        totalTreasuryFeesAccrued += treasuryFee;
        totalGrossBaseSubmitted += grossBaseAvailable;
        totalGrossBaseExecuted += grossBaseUsed;

        if (grossBaseRefund != 0) {
            claimableRefundOf[buyer] += grossBaseRefund;
            totalGrossBaseRefunded += grossBaseRefund;
            totalOutstandingRefunds += grossBaseRefund;
            emit RefundAccrued(buyer, grossBaseRefund);
        }

        emit CreatorFeeAccrued(creator, buyer, creatorFee, true);
        emit TreasuryFeeAccrued(treasury, buyer, treasuryFee, true);
        emit TokensPurchased(
            buyer,
            grossBaseAvailable,
            grossBaseUsed,
            curve.netBaseUsed,
            curve.tokensOut,
            creatorFee,
            treasuryFee,
            grossBaseRefund
        );

        IERC20(token).safeTransfer(buyer, curve.tokensOut);
        if (curve.completesCurve) _graduate(deadline);
        _assertAccounting();
        return curve.tokensOut;
    }

    function _graduate(uint256 deadline) private {
        state = LaunchState.GraduationReady;

        uint256 graduationReserveBase = realBaseReserve;
        FeeMath.GraduationFeeQuote memory fee = FeeMath.quoteGraduation(graduationReserveBase);
        uint256 tokensForPool = CurveMath.tokensForLiquidity(fee.liquidityBase, virtualBaseReserve, virtualTokenReserve);
        uint256 tokenReserve = graduationTokenReserve;
        if (tokensForPool > tokenReserve) {
            revert GraduationTokenReserveExceeded(tokenReserve, tokensForPool);
        }
        uint256 tokensToBurn = tokenReserve - tokensForPool;

        emit GraduationReady(token, graduationManager, graduationReserveBase, tokenReserve);

        graduationTreasuryAllocation = fee.treasuryAllocation;
        totalTreasuryFeesAccrued += fee.treasuryAllocation;
        graduatedLiquidityBase = fee.liquidityBase;
        realBaseReserve = 0;
        graduationTokenReserve = 0;
        totalExecutedBaseWithdrawn += fee.liquidityBase;

        uint256 curveBalance = IERC20(token).balanceOf(address(this));
        if (curveBalance < tokenReserve) revert AccountingInvariantFailed();
        uint256 unsolicitedTokens = curveBalance - tokenReserve;
        if (unsolicitedTokens != 0) {
            unsolicitedTokenBurned += unsolicitedTokens;
            IBabyNoxaToken(token).burn(unsolicitedTokens);
            emit UnsolicitedTokensBurned(unsolicitedTokens);
        }

        uint256 supplyBefore = IERC20(token).totalSupply();
        IERC20(token).safeTransfer(graduationManager, tokenReserve);

        GraduationParams memory params = GraduationParams({
            token: token,
            officialPair: officialPair,
            realBaseReserve: graduationReserveBase,
            terminalVirtualBaseReserve: virtualBaseReserve,
            terminalVirtualTokenReserve: virtualTokenReserve,
            graduationTokenReserve: tokenReserve,
            minimumBaseForLiquidity: fee.liquidityBase,
            minimumTokensForLiquidity: tokensForPool,
            deadline: deadline
        });

        GraduationResult memory result =
            IGraduationManager(graduationManager).graduate{value: fee.liquidityBase}(params);
        if (
            result.officialPair != officialPair || result.treasuryAllocation != fee.treasuryAllocation
                || result.liquidityBase != fee.liquidityBase || result.liquidityTokens != tokensForPool
                || result.burnedTokens != tokensToBurn || result.burnedLp == 0
                || IERC20(token).balanceOf(graduationManager) != 0
                || IERC20(token).balanceOf(officialPair) != tokensForPool
                || IERC20(token).totalSupply() != supplyBefore - tokensToBurn
        ) revert InvalidGraduationResult();

        graduatedLiquidityTokens = result.liquidityTokens;
        graduatedBurnedTokens = result.burnedTokens;
        graduatedBurnedLp = result.burnedLp;
        state = LaunchState.Graduated;
    }

    function _claimRefund(address account, address payable recipient) private returns (uint256 amount) {
        _requireRecipient(recipient);
        amount = claimableRefundOf[account];
        if (amount == 0) revert NoClaimableAmount(account);

        claimableRefundOf[account] = 0;
        totalOutstandingRefunds -= amount;
        totalRefundBaseWithdrawn += amount;
        _sendEther(account, recipient, amount, REFUND_CLAIM);
        _assertAccounting();
    }

    function _claimBaseCredit(address account, address payable recipient) private returns (uint256 amount) {
        _requireRecipient(recipient);
        amount = claimableBaseOf[account];
        if (amount == 0) revert NoClaimableAmount(account);

        claimableBaseOf[account] = 0;
        totalClaimableBase -= amount;
        totalSellCreditsClaimed += amount;
        totalExecutedBaseWithdrawn += amount;
        _sendEther(account, recipient, amount, SELL_PROCEEDS_CLAIM);
        _assertAccounting();
    }

    function _claimCreatorFees(address payable recipient) private returns (uint256 amount) {
        _requireRecipient(recipient);
        amount = creatorTradingFees;
        if (amount == 0) revert NoClaimableAmount(msg.sender);

        creatorTradingFees = 0;
        totalCreatorFeesClaimed += amount;
        totalExecutedBaseWithdrawn += amount;
        _sendEther(msg.sender, recipient, amount, CREATOR_FEES_CLAIM);
        _assertAccounting();
    }

    function _claimTreasuryFees(address payable recipient) private returns (uint256 amount) {
        _requireRecipient(recipient);
        amount = treasuryTradingFees + graduationTreasuryAllocation;
        if (amount == 0) revert NoClaimableAmount(msg.sender);

        treasuryTradingFees = 0;
        graduationTreasuryAllocation = 0;
        totalTreasuryFeesClaimed += amount;
        totalExecutedBaseWithdrawn += amount;
        _sendEther(msg.sender, recipient, amount, TREASURY_FEES_CLAIM);
        _assertAccounting();
    }

    function _requireTrading() private view {
        if (state != LaunchState.Trading) revert InvalidState(state, LaunchState.Trading);
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
        emit LaunchEtherClaimed(launchId, account, recipient, claimType, amount);
        emit EtherClaimed(account, recipient, amount, claimType);
    }

    function _assertAccounting() private view {
        if (address(this).balance < accountedContractBalance()) revert AccountingInvariantFailed();
        if (totalGrossBaseSubmitted != totalGrossBaseExecuted + totalGrossBaseRefunded) {
            revert AccountingInvariantFailed();
        }
        if (totalGrossBaseRefunded != totalOutstandingRefunds + totalRefundBaseWithdrawn) {
            revert AccountingInvariantFailed();
        }
        if (totalGrossBaseExecuted != accountedExecutedBase() + totalExecutedBaseWithdrawn) {
            revert AccountingInvariantFailed();
        }
        if (totalSellCreditsAccrued != totalClaimableBase + totalSellCreditsClaimed) {
            revert AccountingInvariantFailed();
        }
        if (totalCreatorFeesAccrued != creatorTradingFees + totalCreatorFeesClaimed) {
            revert AccountingInvariantFailed();
        }
        if (totalTreasuryFeesAccrued != treasuryTradingFees + graduationTreasuryAllocation + totalTreasuryFeesClaimed) {
            revert AccountingInvariantFailed();
        }
        if (curveTokenInventory > BabyNoxaConstants.CURVE_TOKEN_ALLOCATION) revert AccountingInvariantFailed();

        uint256 curveBalance = IERC20(token).balanceOf(address(this));
        if (state == LaunchState.Trading && curveBalance < curveTokenInventory + graduationTokenReserve) {
            revert AccountingInvariantFailed();
        }
        if (state == LaunchState.Graduated && curveBalance != 0) revert AccountingInvariantFailed();
    }
}
