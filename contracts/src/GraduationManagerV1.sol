// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IBabyNoxaFactory} from "./interfaces/IBabyNoxaFactory.sol";
import {IBabyNoxaToken} from "./interfaces/IBabyNoxaToken.sol";
import {IBondingCurve} from "./interfaces/IBondingCurve.sol";
import {IGraduationManager} from "./interfaces/IGraduationManager.sol";
import {IGuardedV2Factory} from "./interfaces/dex/IGuardedV2Factory.sol";
import {IGuardedV2Pair} from "./interfaces/dex/IGuardedV2Pair.sol";
import {IV2Router02} from "./interfaces/dex/IV2Router02.sol";
import {IWrappedNative} from "./interfaces/dex/IWrappedNative.sol";
import {BabyNoxaConstants} from "./libraries/BabyNoxaConstants.sol";
import {CurveMath} from "./libraries/CurveMath.sol";
import {DeadlinePolicy} from "./libraries/DeadlinePolicy.sol";
import {FeeMath} from "./libraries/FeeMath.sol";
import {GraduationParams, GraduationResult, LaunchState} from "./types/BabyNoxaTypes.sol";

/// @title GraduationManagerV1
/// @notice Atomically converts one completed BabyNoxa curve into permanently locked guarded-V2 liquidity.
/// @dev Treasury base never enters this contract. The curve retains that amount as a pull-payment liability.
contract GraduationManagerV1 is IGraduationManager, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public constant override burnAddress = 0x000000000000000000000000000000000000dEaD;

    address public immutable override factory;
    address public immutable override v2Factory;
    address public immutable override router;
    address public immutable override wrappedNative;

    mapping(address curve => bool graduated) public graduatedCurve;

    error ZeroAddress();
    error InvalidDeploymentConfiguration();
    error UnauthorizedCurve(address curve);
    error CurveAlreadyGraduated(address curve);
    error InvalidCurveSnapshot();
    error InvalidOfficialPair(address expected, address actual);
    error PairNotReady();
    error IncorrectBaseValue(uint256 expected, uint256 actual);
    error GraduationTokenBalanceTooLow(uint256 expected, uint256 actual);
    error GraduationTokenReserveExceeded(uint256 available, uint256 required);
    error LiquidityMinimumNotMet(uint256 minimum, uint256 actual);
    error PriceContinuityFailed(
        uint256 terminalPrice, uint256 poolPrice, uint256 absoluteDifference, uint256 relativeDifferenceBps
    );
    error ManagerBalanceNotCleared(address asset, uint256 balance);
    error InvalidLiquidityResult();

    constructor(address factory_, address v2Factory_, address router_, address wrappedNative_) {
        if (factory_ == address(0) || v2Factory_ == address(0) || router_ == address(0) || wrappedNative_ == address(0))
        {
            revert ZeroAddress();
        }
        if (
            factory_.code.length == 0 || v2Factory_.code.length == 0 || router_.code.length == 0
                || wrappedNative_.code.length == 0
        ) revert InvalidDeploymentConfiguration();
        if (
            IGuardedV2Factory(v2Factory_).launchFactory() != factory_
                || IGuardedV2Factory(v2Factory_).feeTo() != address(0)
                || IGuardedV2Factory(v2Factory_).feeToSetter() != address(0)
                || IV2Router02(router_).factory() != v2Factory_ || IV2Router02(router_).WETH() != wrappedNative_
        ) revert InvalidDeploymentConfiguration();

        factory = factory_;
        v2Factory = v2Factory_;
        router = router_;
        wrappedNative = wrappedNative_;
    }

    /// @inheritdoc IGraduationManager
    function graduate(GraduationParams calldata params)
        external
        payable
        override
        nonReentrant
        returns (GraduationResult memory result)
    {
        if (!IBabyNoxaFactory(factory).isRegisteredCurve(msg.sender)) revert UnauthorizedCurve(msg.sender);
        if (graduatedCurve[msg.sender]) revert CurveAlreadyGraduated(msg.sender);
        DeadlinePolicy.enforce(params.deadline);
        _validateCurveSnapshot(params);

        FeeMath.GraduationFeeQuote memory fee = FeeMath.quoteGraduation(params.realBaseReserve);
        if (msg.value != fee.liquidityBase) revert IncorrectBaseValue(fee.liquidityBase, msg.value);
        if (fee.liquidityBase < params.minimumBaseForLiquidity) {
            revert LiquidityMinimumNotMet(params.minimumBaseForLiquidity, fee.liquidityBase);
        }

        uint256 liquidityTokens = CurveMath.tokensForLiquidity(
            fee.liquidityBase, params.terminalVirtualBaseReserve, params.terminalVirtualTokenReserve
        );
        if (liquidityTokens > params.graduationTokenReserve) {
            revert GraduationTokenReserveExceeded(params.graduationTokenReserve, liquidityTokens);
        }
        if (liquidityTokens < params.minimumTokensForLiquidity) {
            revert LiquidityMinimumNotMet(params.minimumTokensForLiquidity, liquidityTokens);
        }

        IGuardedV2Pair pair = _validatedPair(params);
        graduatedCurve[msg.sender] = true;

        uint256 tokenBalance = IERC20(params.token).balanceOf(address(this));
        if (tokenBalance < params.graduationTokenReserve) {
            revert GraduationTokenBalanceTooLow(params.graduationTokenReserve, tokenBalance);
        }
        uint256 unsolicitedTokens = tokenBalance - params.graduationTokenReserve;
        if (unsolicitedTokens != 0) {
            IERC20(params.token).safeTransfer(burnAddress, unsolicitedTokens);
            emit UnsolicitedAssetSentToBurn(params.token, unsolicitedTokens);
        }

        uint256 unsolicitedWrappedBase = IERC20(wrappedNative).balanceOf(address(this));
        if (unsolicitedWrappedBase != 0) {
            IERC20(wrappedNative).safeTransfer(burnAddress, unsolicitedWrappedBase);
            emit UnsolicitedAssetSentToBurn(wrappedNative, unsolicitedWrappedBase);
        }

        uint256 burnedTokens = params.graduationTokenReserve - liquidityTokens;
        if (burnedTokens != 0) IBabyNoxaToken(params.token).burn(burnedTokens);
        IWrappedNative(wrappedNative).deposit{value: fee.liquidityBase}();

        IERC20(params.token).forceApprove(params.officialPair, liquidityTokens);
        IERC20(wrappedNative).forceApprove(params.officialPair, fee.liquidityBase);
        (uint256 amount0, uint256 amount1) = _orderedAmounts(pair, params.token, liquidityTokens, fee.liquidityBase);
        uint256 burnedLp = pair.bootstrapMint(amount0, amount1);

        _validateBootstrapResult(pair, params, fee.liquidityBase, liquidityTokens, burnedLp);
        _validatePriceContinuity(pair, params);

        uint256 remainingTokenBalance = IERC20(params.token).balanceOf(address(this));
        if (remainingTokenBalance != 0) revert ManagerBalanceNotCleared(params.token, remainingTokenBalance);
        uint256 remainingWrappedBalance = IERC20(wrappedNative).balanceOf(address(this));
        if (remainingWrappedBalance != 0) revert ManagerBalanceNotCleared(wrappedNative, remainingWrappedBalance);

        result = GraduationResult({
            officialPair: params.officialPair,
            treasuryAllocation: fee.treasuryAllocation,
            liquidityBase: fee.liquidityBase,
            liquidityTokens: liquidityTokens,
            burnedTokens: burnedTokens,
            burnedLp: burnedLp
        });

        _emitGraduationEvents(params.token, msg.sender, result);
    }

    function _emitGraduationEvents(address token, address curve, GraduationResult memory result) private {
        emit GraduationTokensBurned(token, curve, result.burnedTokens);
        emit LiquidityCreated(token, result.officialPair, result.liquidityBase, result.liquidityTokens, result.burnedLp);
        emit LiquidityBurned(token, result.officialPair, burnAddress, result.burnedLp);
        emit GraduationExecuted(
            token,
            curve,
            result.officialPair,
            result.treasuryAllocation,
            result.liquidityBase,
            result.liquidityTokens,
            result.burnedTokens
        );
    }

    function _validateCurveSnapshot(GraduationParams calldata params) private view {
        IBondingCurve curve = IBondingCurve(msg.sender);
        if (
            params.token == address(0) || params.officialPair == address(0) || curve.factory() != factory
                || curve.token() != params.token || curve.graduationManager() != address(this)
                || curve.officialPair() != params.officialPair || curve.state() != LaunchState.GraduationReady
                || curve.curveTokenInventory() != 0 || curve.realBaseReserve() != 0
                || curve.graduationTokenReserve() != 0
                || curve.virtualBaseReserve() != params.terminalVirtualBaseReserve
                || curve.virtualTokenReserve() != params.terminalVirtualTokenReserve
                || params.graduationTokenReserve != BabyNoxaConstants.GRADUATION_TOKEN_RESERVE
        ) revert InvalidCurveSnapshot();
    }

    function _validatedPair(GraduationParams calldata params) private view returns (IGuardedV2Pair pair) {
        address expectedPair = IGuardedV2Factory(v2Factory).getPair(params.token, wrappedNative);
        if (expectedPair != params.officialPair) revert InvalidOfficialPair(expectedPair, params.officialPair);

        pair = IGuardedV2Pair(params.officialPair);
        address token0 = pair.token0();
        address token1 = pair.token1();
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        bool assetsMatch =
            (token0 == params.token && token1 == wrappedNative) || (token0 == wrappedNative && token1 == params.token);
        if (
            !assetsMatch || pair.factory() != v2Factory || pair.bootstrapManager() != address(this)
                || !pair.bootstrapLocked() || pair.LP_BURN_ADDRESS() != burnAddress || pair.totalSupply() != 0
                || reserve0 != 0 || reserve1 != 0 || IGuardedV2Factory(v2Factory).feeTo() != address(0)
                || IGuardedV2Factory(v2Factory).feeToSetter() != address(0)
        ) revert PairNotReady();
    }

    function _orderedAmounts(IGuardedV2Pair pair, address token, uint256 tokenAmount, uint256 baseAmount)
        private
        view
        returns (uint256 amount0, uint256 amount1)
    {
        if (pair.token0() == token) return (tokenAmount, baseAmount);
        return (baseAmount, tokenAmount);
    }

    function _validateBootstrapResult(
        IGuardedV2Pair pair,
        GraduationParams calldata params,
        uint256 liquidityBase,
        uint256 liquidityTokens,
        uint256 burnedLp
    ) private view {
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        (uint256 expected0, uint256 expected1) = _orderedAmounts(pair, params.token, liquidityTokens, liquidityBase);
        uint256 minimumLiquidity = pair.MINIMUM_LIQUIDITY();
        if (
            pair.bootstrapLocked() || pair.bootstrapManager() != address(0) || reserve0 != expected0
                || reserve1 != expected1 || burnedLp == 0 || pair.balanceOf(burnAddress) != burnedLp
                || pair.balanceOf(address(0)) != minimumLiquidity || pair.totalSupply() != burnedLp + minimumLiquidity
                || pair.balanceOf(address(this)) != 0 || pair.balanceOf(msg.sender) != 0
        ) revert InvalidLiquidityResult();
    }

    function _validatePriceContinuity(IGuardedV2Pair pair, GraduationParams calldata params) private view {
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        uint256 poolTokens;
        uint256 poolBase;
        if (pair.token0() == params.token) {
            poolTokens = reserve0;
            poolBase = reserve1;
        } else {
            poolTokens = reserve1;
            poolBase = reserve0;
        }

        uint256 terminalPrice =
            CurveMath.spotPrice(params.terminalVirtualBaseReserve, params.terminalVirtualTokenReserve);
        uint256 poolPrice = Math.mulDiv(poolBase, 1 ether, poolTokens, Math.Rounding.Floor);
        uint256 absoluteDifference = terminalPrice >= poolPrice ? terminalPrice - poolPrice : poolPrice - terminalPrice;
        uint256 relativeDifferenceBps = terminalPrice == 0
            ? type(uint256).max
            : Math.mulDiv(absoluteDifference, BabyNoxaConstants.BPS_DENOMINATOR, terminalPrice, Math.Rounding.Ceil);
        if (
            absoluteDifference > BabyNoxaConstants.MAX_PRICE_DIFFERENCE_WEI_PER_TOKEN
                || relativeDifferenceBps > BabyNoxaConstants.MAX_PRICE_DIFFERENCE_BPS
        ) {
            revert PriceContinuityFailed(terminalPrice, poolPrice, absoluteDifference, relativeDifferenceBps);
        }
    }
}
