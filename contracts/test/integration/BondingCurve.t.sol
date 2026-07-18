// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {BabyNoxaToken} from "../../src/BabyNoxaToken.sol";
import {BondingCurve} from "../../src/BondingCurve.sol";
import {IBabyNoxaToken} from "../../src/interfaces/IBabyNoxaToken.sol";
import {IGraduationManager} from "../../src/interfaces/IGraduationManager.sol";
import {BabyNoxaConstants} from "../../src/libraries/BabyNoxaConstants.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";
import {DeadlinePolicy} from "../../src/libraries/DeadlinePolicy.sol";
import {FeeMath} from "../../src/libraries/FeeMath.sol";
import {BondingCurveSimulator} from "../../src/mocks/BondingCurveSimulator.sol";
import {GraduationParams, GraduationResult, LaunchConfig, LaunchState} from "../../src/types/BabyNoxaTypes.sol";

contract CurveGraduationManagerHarness is IGraduationManager {
    address public override factory = address(this);
    address public override v2Factory = address(0x1001);
    address public override router = address(0x1002);
    address public override wrappedNative = address(0x1003);
    address public override burnAddress = 0x000000000000000000000000000000000000dEaD;

    bool public revertAfterProcessing;
    bool public returnInvalidResult;
    bool public attemptReentrancy;
    bool public reentrantBuySucceeded;
    uint256 public graduationCalls;
    address public lastCurve;
    uint256 public lastValue;
    GraduationParams internal lastGraduationParams;

    function setRevertAfterProcessing(bool enabled) external {
        revertAfterProcessing = enabled;
    }

    function setReturnInvalidResult(bool enabled) external {
        returnInvalidResult = enabled;
    }

    function setAttemptReentrancy(bool enabled) external {
        attemptReentrancy = enabled;
    }

    function getLastGraduationParams() external view returns (GraduationParams memory) {
        return lastGraduationParams;
    }

    function graduate(GraduationParams calldata params)
        external
        payable
        override
        returns (GraduationResult memory result)
    {
        graduationCalls++;
        lastCurve = msg.sender;
        lastValue = msg.value;
        lastGraduationParams = params;

        if (attemptReentrancy) {
            (reentrantBuySucceeded,) =
                msg.sender.call{value: 200}(abi.encodeCall(BondingCurve.buy, (0, type(uint256).max)));
        }

        FeeMath.GraduationFeeQuote memory fee = FeeMath.quoteGraduation(params.realBaseReserve);
        uint256 liquidityTokens = CurveMath.tokensForLiquidity(
            fee.liquidityBase, params.terminalVirtualBaseReserve, params.terminalVirtualTokenReserve
        );
        uint256 burnedTokens = params.graduationTokenReserve - liquidityTokens;

        require(msg.value == fee.liquidityBase, "ManagerHarness: INVALID_VALUE");
        require(params.minimumBaseForLiquidity == fee.liquidityBase, "ManagerHarness: INVALID_BASE_MINIMUM");
        require(params.minimumTokensForLiquidity == liquidityTokens, "ManagerHarness: INVALID_TOKEN_MINIMUM");

        IBabyNoxaToken(params.token).burn(burnedTokens);
        require(IERC20(params.token).transfer(params.officialPair, liquidityTokens), "ManagerHarness: TRANSFER_FAILED");

        if (revertAfterProcessing) revert("ManagerHarness: GRADUATION_FAILED");

        result = GraduationResult({
            officialPair: params.officialPair,
            treasuryAllocation: fee.treasuryAllocation,
            liquidityBase: fee.liquidityBase,
            liquidityTokens: liquidityTokens,
            burnedTokens: burnedTokens,
            burnedLp: returnInvalidResult ? 0 : 1
        });
    }
}

contract ProductionCurveFactoryHarness {
    uint256 public launchCount;

    function deployCurve(address creator, address treasury, address graduationManager, address officialPair)
        external
        returns (BabyNoxaToken token, BondingCurve curve)
    {
        token = new BabyNoxaToken("Production Curve Token", "PCT", address(this));
        curve = _deployCurve(address(token), creator, treasury, graduationManager, officialPair);
        require(token.transfer(address(curve), token.totalSupply()), "FactoryHarness: FUNDING_FAILED");
    }

    function deployReentrantCurve(address creator, address treasury, address graduationManager, address officialPair)
        external
        returns (ReentrantCurveToken token, BondingCurve curve)
    {
        token = new ReentrantCurveToken(address(this));
        curve = _deployCurve(address(token), creator, treasury, graduationManager, officialPair);
        token.setCurve(curve);
        require(token.transfer(address(curve), token.totalSupply()), "FactoryHarness: FUNDING_FAILED");
    }

    function deployUnfundedCurve(address creator, address treasury, address graduationManager, address officialPair)
        external
        returns (BabyNoxaToken token, BondingCurve curve)
    {
        token = new BabyNoxaToken("Unfunded Curve Token", "UCT", address(this));
        curve = _deployCurve(address(token), creator, treasury, graduationManager, officialPair);
    }

    function launchCurve(BondingCurve curve, uint256 minimumCreatorTokensOut, uint256 deadline)
        external
        payable
        returns (uint256 creatorTokensOut)
    {
        return curve.launch{value: msg.value}(minimumCreatorTokensOut, deadline);
    }

    function _deployCurve(
        address token,
        address creator,
        address treasury,
        address graduationManager,
        address officialPair
    ) private returns (BondingCurve curve) {
        LaunchConfig memory config = LaunchConfig({
            launchId: ++launchCount,
            creator: creator,
            token: token,
            treasury: treasury,
            graduationManager: graduationManager,
            officialPair: officialPair,
            initialVirtualBaseReserve: BabyNoxaConstants.INITIAL_VIRTUAL_BASE_RESERVE,
            initialVirtualTokenReserve: BabyNoxaConstants.INITIAL_VIRTUAL_TOKEN_RESERVE
        });
        curve = new BondingCurve(config, address(this));
    }
}

contract ReentrantCurveToken is ERC20 {
    BondingCurve public curve;
    bool public callbacksEnabled = true;
    bool public callbackEntered;
    bool public reentrantBuySucceeded;

    constructor(address recipient) ERC20("Reentrant Curve Token", "RCT") {
        _mint(recipient, BabyNoxaConstants.TOTAL_SUPPLY);
    }

    function setCurve(BondingCurve curve_) external {
        require(address(curve) == address(0), "ReentrantToken: CURVE_ALREADY_SET");
        curve = curve_;
    }

    function resetCallbackResult() external {
        callbackEntered = false;
        reentrantBuySucceeded = false;
    }

    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);
        if (callbacksEnabled && msg.sender == address(curve) && !callbackEntered) {
            callbackEntered = true;
            (reentrantBuySucceeded,) =
                address(curve).call{value: 200}(abi.encodeCall(BondingCurve.buy, (0, type(uint256).max)));
        }
    }
}

contract ProductionReentrantClaimReceiver {
    BondingCurve public curve;
    bool public callbackEntered;
    bool public claimSucceeded;
    bool public buySucceeded;

    function setCurve(BondingCurve curve_) external {
        curve = curve_;
    }

    function claimCreatorFees() external {
        curve.claimCreatorFeesTo(payable(address(this)));
    }

    receive() external payable {
        if (callbackEntered) return;
        callbackEntered = true;
        (claimSucceeded,) = address(curve).call(abi.encodeCall(BondingCurve.claimCreatorFees, ()));
        (buySucceeded,) = address(curve).call{value: 200}(abi.encodeCall(BondingCurve.buy, (0, type(uint256).max)));
    }
}

contract ProductionForceEther {
    constructor() payable {}

    function force(address payable recipient) external {
        selfdestruct(recipient);
    }
}

contract ProductionRejectEther {
    receive() external payable {
        revert("ProductionRejectEther: REJECTED");
    }
}

contract BondingCurveTest is Test {
    uint256 internal constant VALID_DEADLINE = type(uint256).max;

    address internal creator = makeAddr("production creator");
    address internal treasury = makeAddr("production treasury");
    address internal alice = makeAddr("production alice");
    address internal bob = makeAddr("production bob");
    address internal officialPair = makeAddr("official pair token sink");

    ProductionCurveFactoryHarness internal factoryHarness;
    CurveGraduationManagerHarness internal manager;
    BabyNoxaToken internal token;
    BondingCurve internal curve;

    event LaunchEtherClaimed(
        uint256 indexed launchId,
        address indexed beneficiary,
        address indexed recipient,
        bytes32 claimType,
        uint256 amount
    );

    function setUp() public {
        factoryHarness = new ProductionCurveFactoryHarness();
        manager = new CurveGraduationManagerHarness();
        (token, curve) = factoryHarness.deployCurve(creator, treasury, address(manager), officialPair);

        vm.deal(creator, 100 ether);
        vm.deal(treasury, 1 ether);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        factoryHarness.launchCurve(curve, 0, VALID_DEADLINE);
    }

    function test_DeploymentFundingAndFactoryOnlyOneTimeLaunch() public {
        assertEq(curve.factory(), address(factoryHarness));
        assertEq(curve.token(), address(token));
        assertEq(curve.creator(), creator);
        assertEq(curve.treasury(), treasury);
        assertEq(curve.graduationManager(), address(manager));
        assertEq(curve.officialPair(), officialPair);
        assertEq(uint256(curve.state()), uint256(LaunchState.Trading));
        assertEq(token.balanceOf(address(factoryHarness)), 0);
        assertEq(token.balanceOf(address(curve)), BabyNoxaConstants.TOTAL_SUPPLY);
        assertEq(curve.curveTokenInventory(), BabyNoxaConstants.CURVE_TOKEN_ALLOCATION);
        assertEq(curve.graduationTokenReserve(), BabyNoxaConstants.GRADUATION_TOKEN_RESERVE);
        assertEq(curve.accountedTokenSupply(), BabyNoxaConstants.TOTAL_SUPPLY);

        vm.expectPartialRevert(BondingCurve.FactoryOnly.selector);
        vm.prank(creator);
        curve.launch(0, VALID_DEADLINE);

        vm.expectPartialRevert(BondingCurve.InvalidState.selector);
        factoryHarness.launchCurve(curve, 0, VALID_DEADLINE);
    }

    function test_UnfundedCurveCannotOpenTrading() public {
        (, BondingCurve unfunded) =
            factoryHarness.deployUnfundedCurve(creator, treasury, address(manager), makeAddr("unfunded pair"));

        vm.expectPartialRevert(BondingCurve.TokenFundingMismatch.selector);
        factoryHarness.launchCurve(unfunded, 0, VALID_DEADLINE);

        assertEq(uint256(unfunded.state()), uint256(LaunchState.Created));
    }

    function test_PublicBuyerCannotFrontRunAtomicCreatorLaunchAndCreatorCapIsEnforced() public {
        (BabyNoxaToken freshToken, BondingCurve freshCurve) =
            factoryHarness.deployCurve(creator, treasury, address(manager), makeAddr("fresh official pair"));

        vm.expectPartialRevert(BondingCurve.InvalidState.selector);
        vm.prank(alice);
        freshCurve.buy{value: 1 ether}(0, VALID_DEADLINE);

        (uint256 netForNineteenMillion,,) = CurveMath.netBaseForExactTokensOut(
            BabyNoxaConstants.INITIAL_VIRTUAL_BASE_RESERVE,
            BabyNoxaConstants.INITIAL_VIRTUAL_TOKEN_RESERVE,
            19_000_000 ether
        );
        uint256 creatorGrossBuy = FeeMath.grossFromNet(netForNineteenMillion);

        vm.prank(creator);
        uint256 creatorTokens =
            factoryHarness.launchCurve{value: creatorGrossBuy}(freshCurve, 19_000_000 ether, VALID_DEADLINE);

        assertGe(creatorTokens, 19_000_000 ether);
        assertLe(creatorTokens, BabyNoxaConstants.CREATOR_INITIAL_BUY_CAP);
        assertEq(freshToken.balanceOf(creator), creatorTokens);
        assertTrue(freshCurve.creatorInitialBuyExecuted());

        (, BondingCurve cappedCurve) =
            factoryHarness.deployCurve(creator, treasury, address(manager), makeAddr("cap pair"));
        vm.expectPartialRevert(BondingCurve.CreatorInitialBuyCapExceeded.selector);
        vm.prank(creator);
        factoryHarness.launchCurve{value: 1 ether}(cappedCurve, 0, VALID_DEADLINE);
        assertEq(uint256(cappedCurve.state()), uint256(LaunchState.Created));
    }

    function test_BuyTransfersExactQuoteAndSeparatesFeesFromReserve() public {
        FeeMath.TradeFeeQuote memory expectedFee = FeeMath.quoteTrade(1 ether);
        CurveMath.BuyQuote memory expectedCurve = CurveMath.quoteBuy(
            curve.virtualBaseReserve(), curve.virtualTokenReserve(), curve.curveTokenInventory(), expectedFee.netAmount
        );

        vm.prank(alice);
        uint256 tokensOut = curve.buy{value: 1 ether}(expectedCurve.tokensOut, VALID_DEADLINE);

        assertEq(tokensOut, expectedCurve.tokensOut);
        assertEq(token.balanceOf(alice), tokensOut);
        assertEq(curve.realBaseReserve(), expectedFee.netAmount);
        assertEq(curve.creatorTradingFees(), expectedFee.creatorFee);
        assertEq(curve.treasuryTradingFees(), expectedFee.treasuryFee);
        assertEq(curve.realBaseReserve() + expectedFee.totalFee, 1 ether);
        assertEq(curve.curveTokenInventory(), BabyNoxaConstants.CURVE_TOKEN_ALLOCATION - tokensOut);
        assertEq(token.balanceOf(address(curve)), curve.curveTokenInventory() + curve.graduationTokenReserve());
        _assertBaseAccounting(curve);
    }

    function test_SellPullsApprovedTokensRestoresInventoryAndCreditsExactNetBase() public {
        vm.prank(alice);
        uint256 bought = curve.buy{value: 1 ether}(0, VALID_DEADLINE);
        uint256 sellAmount = bought / 2;
        uint256 inventoryBefore = curve.curveTokenInventory();
        CurveMath.SellQuote memory expectedCurve = CurveMath.quoteSell(
            curve.virtualBaseReserve(), curve.virtualTokenReserve(), sellAmount, curve.realBaseReserve()
        );
        FeeMath.TradeFeeQuote memory expectedFee = FeeMath.quoteTrade(expectedCurve.grossBaseOut);

        vm.prank(alice);
        token.approve(address(curve), sellAmount);
        vm.prank(alice);
        uint256 credit = curve.sell(sellAmount, expectedFee.netAmount, VALID_DEADLINE);

        assertEq(credit, expectedFee.netAmount);
        assertEq(token.balanceOf(alice), bought - sellAmount);
        assertEq(curve.curveTokenInventory(), inventoryBefore + sellAmount);
        assertEq(curve.claimableBaseOf(alice), credit);
        assertEq(curve.totalClaimableBase(), credit);
        assertEq(
            curve.realBaseReserve(),
            expectedCurve.newVirtualBaseReserve - BabyNoxaConstants.INITIAL_VIRTUAL_BASE_RESERVE
        );
        _assertBaseAccounting(curve);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        curve.claimBaseCredit();
        assertEq(alice.balance, balanceBefore + credit);
        assertEq(curve.claimableBaseOf(alice), 0);
        _assertBaseAccounting(curve);
    }

    function test_SellRejectsInsufficientBalanceAndAllowance() public {
        vm.prank(alice);
        uint256 bought = curve.buy{value: 1 ether}(0, VALID_DEADLINE);

        vm.expectPartialRevert(BondingCurve.InsufficientTokenBalance.selector);
        vm.prank(alice);
        curve.sell(bought + 1, 0, VALID_DEADLINE);

        vm.expectRevert();
        vm.prank(alice);
        curve.sell(bought / 2, 0, VALID_DEADLINE);

        assertEq(token.balanceOf(alice), bought);
        assertEq(curve.claimableBaseOf(alice), 0);
    }

    function test_DeadlinesSlippageZeroAndDustPoliciesApply() public {
        vm.expectPartialRevert(BondingCurve.TradeValueBelowMinimum.selector);
        vm.prank(alice);
        curve.buy{value: BabyNoxaConstants.MIN_GROSS_TRADE_VALUE - 1}(0, VALID_DEADLINE);

        vm.prank(alice);
        uint256 minimumTradeTokens = curve.buy{value: BabyNoxaConstants.MIN_GROSS_TRADE_VALUE}(0, VALID_DEADLINE);
        assertGt(minimumTradeTokens, 0);

        vm.expectPartialRevert(BondingCurve.TokenSlippageExceeded.selector);
        vm.prank(alice);
        curve.buy{value: 0.1 ether}(BabyNoxaConstants.CURVE_TOKEN_ALLOCATION, VALID_DEADLINE);

        uint256 deadline = 1_000;
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(DeadlinePolicy.DeadlineExpired.selector, deadline, deadline + 1));
        vm.prank(alice);
        curve.buy{value: 1 ether}(0, deadline);

        vm.warp(deadline + 2);
        vm.prank(alice);
        uint256 bought = curve.buy{value: 1 ether}(0, VALID_DEADLINE);
        vm.prank(alice);
        token.approve(address(curve), bought);

        vm.expectPartialRevert(BondingCurve.BaseSlippageExceeded.selector);
        vm.prank(alice);
        curve.sell(bought / 2, 1 ether, VALID_DEADLINE);

        vm.expectRevert(CurveMath.ZeroAmount.selector);
        vm.prank(alice);
        curve.sell(0, 0, VALID_DEADLINE);
    }

    function test_SellBeforeExpectedFinalBuyReplenishesInventoryAndDelaysGraduation() public {
        vm.prank(alice);
        uint256 bought = curve.buy{value: 1 ether}(0, VALID_DEADLINE);

        (uint256 preSellNetRequired,,) = CurveMath.netBaseForExactTokensOut(
            curve.virtualBaseReserve(), curve.virtualTokenReserve(), curve.curveTokenInventory()
        );
        uint256 preSellGrossRequired = FeeMath.grossFromNet(preSellNetRequired);

        vm.prank(alice);
        token.approve(address(curve), bought / 2);
        vm.prank(alice);
        curve.sell(bought / 2, 0, VALID_DEADLINE);

        vm.prank(bob);
        curve.buy{value: preSellGrossRequired}(0, VALID_DEADLINE);

        assertEq(uint256(curve.state()), uint256(LaunchState.Trading));
        assertGt(curve.curveTokenInventory(), 0);

        vm.prank(bob);
        curve.buy{value: 10 ether}(0, VALID_DEADLINE);
        assertEq(uint256(curve.state()), uint256(LaunchState.Graduated));
    }

    function test_FinalBuyClipsRefundsAndTransfersGraduationAssetsAtomically() public {
        uint256 aliceBalanceBefore = alice.balance;
        vm.prank(alice);
        uint256 tokensOut = curve.buy{value: 10 ether}(0, VALID_DEADLINE);

        assertEq(tokensOut, BabyNoxaConstants.CURVE_TOKEN_ALLOCATION);
        assertEq(token.balanceOf(alice), BabyNoxaConstants.CURVE_TOKEN_ALLOCATION);
        assertEq(uint256(curve.state()), uint256(LaunchState.Graduated));
        assertEq(curve.curveTokenInventory(), 0);
        assertEq(curve.graduationTokenReserve(), 0);
        assertEq(curve.realBaseReserve(), 0);
        assertGt(curve.claimableRefundOf(alice), 5 ether);
        assertEq(alice.balance, aliceBalanceBefore - 10 ether);

        GraduationParams memory params = manager.getLastGraduationParams();
        assertEq(manager.graduationCalls(), 1);
        assertEq(manager.lastCurve(), address(curve));
        assertEq(manager.lastValue(), curve.graduatedLiquidityBase());
        assertEq(params.token, address(token));
        assertEq(params.officialPair, officialPair);
        assertEq(params.graduationTokenReserve, BabyNoxaConstants.GRADUATION_TOKEN_RESERVE);
        assertEq(token.balanceOf(address(manager)), 0);
        assertEq(token.balanceOf(officialPair), curve.graduatedLiquidityTokens());
        assertEq(
            curve.graduatedLiquidityTokens() + curve.graduatedBurnedTokens(), BabyNoxaConstants.GRADUATION_TOKEN_RESERVE
        );
        assertEq(token.totalSupply() + curve.graduatedBurnedTokens(), BabyNoxaConstants.TOTAL_SUPPLY);
        assertEq(curve.accountedTokenSupply(), BabyNoxaConstants.TOTAL_SUPPLY);
        assertEq(address(manager).balance, curve.graduatedLiquidityBase());
        _assertBaseAccounting(curve);

        vm.expectPartialRevert(BondingCurve.InvalidState.selector);
        vm.prank(bob);
        curve.buy{value: 1 ether}(0, VALID_DEADLINE);
        vm.expectPartialRevert(BondingCurve.InvalidState.selector);
        vm.prank(alice);
        curve.sell(1 ether, 0, VALID_DEADLINE);
    }

    function test_FailedGraduationRevertsCompleteFinalPurchase() public {
        manager.setRevertAfterProcessing(true);
        uint256 aliceBaseBefore = alice.balance;

        vm.expectRevert(bytes("ManagerHarness: GRADUATION_FAILED"));
        vm.prank(alice);
        curve.buy{value: 10 ether}(0, VALID_DEADLINE);

        assertEq(alice.balance, aliceBaseBefore);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(curve)), BabyNoxaConstants.TOTAL_SUPPLY);
        assertEq(token.balanceOf(address(manager)), 0);
        assertEq(token.balanceOf(officialPair), 0);
        assertEq(token.totalSupply(), BabyNoxaConstants.TOTAL_SUPPLY);
        assertEq(uint256(curve.state()), uint256(LaunchState.Trading));
        assertEq(curve.curveTokenInventory(), BabyNoxaConstants.CURVE_TOKEN_ALLOCATION);
        assertEq(curve.realBaseReserve(), 0);
        assertEq(curve.creatorTradingFees(), 0);
        assertEq(curve.treasuryTradingFees(), 0);
        assertEq(curve.claimableRefundOf(alice), 0);
        assertEq(address(curve).balance, 0);
    }

    function test_InvalidGraduationResultAlsoRollsBackCompleteFinalPurchase() public {
        manager.setReturnInvalidResult(true);

        vm.expectPartialRevert(BondingCurve.InvalidGraduationResult.selector);
        vm.prank(alice);
        curve.buy{value: 10 ether}(0, VALID_DEADLINE);

        assertEq(uint256(curve.state()), uint256(LaunchState.Trading));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(curve)), BabyNoxaConstants.TOTAL_SUPPLY);
        assertEq(token.totalSupply(), BabyNoxaConstants.TOTAL_SUPPLY);
        assertEq(address(curve).balance, 0);
    }

    function test_TreasuryClaimsTradingFeesAndGraduationAllocationButNoOtherFunds() public {
        vm.prank(alice);
        curve.buy{value: 10 ether}(0, VALID_DEADLINE);

        uint256 expected = curve.treasuryTradingFees() + curve.graduationTreasuryAllocation();
        uint256 treasuryBefore = treasury.balance;
        vm.prank(treasury);
        uint256 claimed = curve.claimTreasuryFees();

        assertEq(claimed, expected);
        assertEq(treasury.balance, treasuryBefore + expected);
        assertEq(curve.treasuryTradingFees(), 0);
        assertEq(curve.graduationTreasuryAllocation(), 0);
        assertGt(curve.creatorTradingFees(), 0);
        assertGt(curve.claimableRefundOf(alice), 0);
        _assertBaseAccounting(curve);
    }

    function test_UserClaimsCanOnlyRedirectTheirOwnCreditsAndRefunds() public {
        vm.prank(alice);
        uint256 bought = curve.buy{value: 1 ether}(0, VALID_DEADLINE);
        vm.prank(alice);
        token.approve(address(curve), bought / 2);
        vm.prank(alice);
        curve.sell(bought / 2, 0, VALID_DEADLINE);

        uint256 credit = curve.claimableBaseOf(alice);
        vm.expectPartialRevert(BondingCurve.NoClaimableAmount.selector);
        vm.prank(bob);
        curve.claimBaseCreditTo(payable(bob));

        uint256 bobBefore = bob.balance;
        vm.prank(alice);
        curve.claimBaseCreditTo(payable(bob));
        assertEq(bob.balance, bobBefore + credit);

        vm.prank(alice);
        curve.buy{value: 10 ether}(0, VALID_DEADLINE);
        uint256 refund = curve.claimableRefundOf(alice);

        vm.expectPartialRevert(BondingCurve.NoClaimableAmount.selector);
        vm.prank(bob);
        curve.claimRefund();

        bobBefore = bob.balance;
        vm.prank(alice);
        curve.claimRefundTo(payable(bob));
        assertEq(bob.balance, bobBefore + refund);
        assertEq(curve.claimableRefundOf(alice), 0);
        _assertBaseAccounting(curve);
    }

    function test_CreatorAndTreasuryFeeClaimsRemainRoleRestricted() public {
        vm.prank(alice);
        curve.buy{value: 1 ether}(0, VALID_DEADLINE);

        vm.expectPartialRevert(BondingCurve.CreatorOnly.selector);
        vm.prank(bob);
        curve.claimCreatorFees();

        vm.expectPartialRevert(BondingCurve.TreasuryOnly.selector);
        vm.prank(creator);
        curve.claimTreasuryFees();

        vm.expectRevert(BondingCurve.ZeroAddress.selector);
        vm.prank(creator);
        curve.claimCreatorFeesTo(payable(address(0)));

        uint256 creatorFees = curve.creatorTradingFees();
        uint256 bobBefore = bob.balance;
        vm.prank(creator);
        curve.claimCreatorFeesTo(payable(bob));
        assertEq(bob.balance, bobBefore + creatorFees);
        assertEq(curve.creatorTradingFees(), 0);
    }

    function test_FeeOwnershipRemainsIsolatedAcrossCurvesAndFactoryHasNoClaimAuthority() public {
        address creatorB = makeAddr("production creator B");
        address treasuryB = makeAddr("production treasury B");
        (, BondingCurve curveB) =
            factoryHarness.deployCurve(creatorB, treasuryB, address(manager), makeAddr("production pair B"));
        factoryHarness.launchCurve(curveB, 0, VALID_DEADLINE);

        vm.prank(alice);
        curve.buy{value: 1 ether}(0, VALID_DEADLINE);
        vm.prank(bob);
        curveB.buy{value: 1 ether}(0, VALID_DEADLINE);

        vm.expectPartialRevert(BondingCurve.CreatorOnly.selector);
        vm.prank(creator);
        curveB.claimCreatorFeesTo(payable(creator));

        vm.expectPartialRevert(BondingCurve.TreasuryOnly.selector);
        vm.prank(treasury);
        curveB.claimTreasuryFeesTo(payable(treasury));

        vm.expectPartialRevert(BondingCurve.CreatorOnly.selector);
        vm.prank(address(factoryHarness));
        curve.claimCreatorFeesTo(payable(address(factoryHarness)));

        vm.expectPartialRevert(BondingCurve.TreasuryOnly.selector);
        vm.prank(address(factoryHarness));
        curve.claimTreasuryFeesTo(payable(address(factoryHarness)));

        uint256 creatorABefore = creator.balance;
        uint256 creatorBBefore = creatorB.balance;
        uint256 creatorAFees = curve.creatorTradingFees();
        uint256 creatorBFees = curveB.creatorTradingFees();
        vm.prank(creator);
        curve.claimCreatorFees();
        vm.prank(creatorB);
        curveB.claimCreatorFees();

        assertEq(creator.balance, creatorABefore + creatorAFees);
        assertEq(creatorB.balance, creatorBBefore + creatorBFees);
        assertEq(curve.creatorTradingFees(), 0);
        assertEq(curveB.creatorTradingFees(), 0);
        assertGt(curve.treasuryTradingFees(), 0);
        assertGt(curveB.treasuryTradingFees(), 0);
    }

    function test_RejectingRecipientPreservesClaimAndDoesNotBlockTradingOrOtherClaims() public {
        ProductionRejectEther rejecting = new ProductionRejectEther();

        vm.prank(alice);
        uint256 aliceBought = curve.buy{value: 1 ether}(0, VALID_DEADLINE);
        vm.prank(alice);
        token.approve(address(curve), aliceBought / 2);
        vm.prank(alice);
        curve.sell(aliceBought / 2, 0, VALID_DEADLINE);
        uint256 aliceCredit = curve.claimableBaseOf(alice);

        vm.expectRevert(
            abi.encodeWithSelector(BondingCurve.EtherTransferFailed.selector, address(rejecting), aliceCredit)
        );
        vm.prank(alice);
        curve.claimBaseCreditTo(payable(address(rejecting)));

        assertEq(curve.claimableBaseOf(alice), aliceCredit);
        assertEq(curve.totalSellCreditsClaimed(), 0);

        vm.prank(bob);
        uint256 bobBought = curve.buy{value: 0.5 ether}(0, VALID_DEADLINE);
        vm.prank(bob);
        token.approve(address(curve), bobBought / 2);
        vm.prank(bob);
        curve.sell(bobBought / 2, 0, VALID_DEADLINE);
        uint256 bobCredit = curve.claimableBaseOf(bob);
        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        curve.claimBaseCredit();

        assertEq(bob.balance, bobBefore + bobCredit);
        assertEq(curve.claimableBaseOf(bob), 0);
        assertEq(curve.claimableBaseOf(alice), aliceCredit);
        _assertBaseAccounting(curve);
    }

    function test_ClaimTelemetryIncludesLaunchAndCumulativeBucketsReconcile() public {
        vm.prank(alice);
        uint256 bought = curve.buy{value: 1 ether}(0, VALID_DEADLINE);
        vm.prank(alice);
        token.approve(address(curve), bought / 2);
        vm.prank(alice);
        curve.sell(bought / 2, 0, VALID_DEADLINE);
        vm.prank(bob);
        curve.buy{value: 10 ether}(0, VALID_DEADLINE);

        _assertFeeOperationAccounting(curve);

        uint256 creatorFees = curve.creatorTradingFees();
        vm.expectEmit(true, true, true, true, address(curve));
        emit LaunchEtherClaimed(curve.launchId(), creator, bob, keccak256("CREATOR_FEES"), creatorFees);
        vm.prank(creator);
        curve.claimCreatorFeesTo(payable(bob));

        vm.prank(treasury);
        curve.claimTreasuryFees();
        vm.prank(alice);
        curve.claimBaseCredit();
        vm.prank(bob);
        curve.claimRefund();

        _assertFeeOperationAccounting(curve);
        assertEq(curve.creatorTradingFees(), 0);
        assertEq(curve.treasuryTradingFees(), 0);
        assertEq(curve.graduationTreasuryAllocation(), 0);
        assertEq(curve.totalClaimableBase(), 0);
        assertEq(curve.totalOutstandingRefunds(), 0);
        assertEq(curve.totalCreatorFeesAccrued(), curve.totalCreatorFeesClaimed());
        assertEq(curve.totalTreasuryFeesAccrued(), curve.totalTreasuryFeesClaimed());
        assertEq(curve.totalSellCreditsAccrued(), curve.totalSellCreditsClaimed());
        assertEq(curve.totalGrossBaseRefunded(), curve.totalRefundBaseWithdrawn());
    }

    function test_UnsolicitedTokenDonationsDoNotChangePricingOrBlockGraduation() public {
        vm.prank(alice);
        curve.buy{value: 1 ether}(0, VALID_DEADLINE);

        uint256 donatedTokens = 1 ether;
        uint256 inventoryBefore = curve.curveTokenInventory();
        uint256 virtualBaseBefore = curve.virtualBaseReserve();
        uint256 virtualTokensBefore = curve.virtualTokenReserve();
        vm.prank(alice);
        token.transfer(address(curve), donatedTokens);

        assertEq(curve.curveTokenInventory(), inventoryBefore);
        assertEq(curve.virtualBaseReserve(), virtualBaseBefore);
        assertEq(curve.virtualTokenReserve(), virtualTokensBefore);

        vm.prank(bob);
        curve.buy{value: 10 ether}(0, VALID_DEADLINE);

        assertEq(uint256(curve.state()), uint256(LaunchState.Graduated));
        assertEq(curve.unsolicitedTokenBurned(), donatedTokens);
        assertEq(token.balanceOf(address(curve)), 0);
        assertEq(
            token.totalSupply() + curve.graduatedBurnedTokens() + curve.unsolicitedTokenBurned(),
            BabyNoxaConstants.TOTAL_SUPPLY
        );
        assertEq(curve.accountedTokenSupply(), BabyNoxaConstants.TOTAL_SUPPLY);
    }

    function test_ForcedEtherNeverChangesQuotesOrTrackedReserve() public {
        vm.prank(alice);
        curve.buy{value: 1 ether}(0, VALID_DEADLINE);

        FeeMath.TradeFeeQuote memory nextFee = FeeMath.quoteTrade(0.5 ether);
        CurveMath.BuyQuote memory nextQuote = CurveMath.quoteBuy(
            curve.virtualBaseReserve(), curve.virtualTokenReserve(), curve.curveTokenInventory(), nextFee.netAmount
        );
        uint256 reserveBefore = curve.realBaseReserve();
        uint256 forcedAmount = 0.25 ether;
        ProductionForceEther forceEther = new ProductionForceEther{value: forcedAmount}();
        forceEther.force(payable(address(curve)));

        assertEq(curve.realBaseReserve(), reserveBefore);
        assertEq(address(curve).balance - curve.accountedContractBalance(), forcedAmount);

        vm.prank(bob);
        uint256 tokensOut = curve.buy{value: 0.5 ether}(nextQuote.tokensOut, VALID_DEADLINE);
        assertEq(tokensOut, nextQuote.tokensOut);
        assertEq(address(curve).balance - curve.accountedContractBalance(), forcedAmount);
    }

    function test_ClaimReceiverAndManagerCallbacksCannotReenterStateTransitions() public {
        ProductionReentrantClaimReceiver receiver = new ProductionReentrantClaimReceiver();
        (BabyNoxaToken receiverToken, BondingCurve receiverCurve) =
            factoryHarness.deployCurve(address(receiver), treasury, address(manager), makeAddr("receiver pair"));
        receiver.setCurve(receiverCurve);
        factoryHarness.launchCurve(receiverCurve, 0, VALID_DEADLINE);

        vm.prank(alice);
        receiverCurve.buy{value: 1 ether}(0, VALID_DEADLINE);
        uint256 fees = receiverCurve.creatorTradingFees();
        receiver.claimCreatorFees();

        assertTrue(receiver.callbackEntered());
        assertFalse(receiver.claimSucceeded());
        assertFalse(receiver.buySucceeded());
        assertEq(address(receiver).balance, fees);
        assertEq(receiverCurve.creatorTradingFees(), 0);
        assertGt(receiverToken.balanceOf(alice), 0);

        manager.setAttemptReentrancy(true);
        vm.prank(alice);
        curve.buy{value: 10 ether}(0, VALID_DEADLINE);
        assertFalse(manager.reentrantBuySucceeded());
        assertEq(uint256(curve.state()), uint256(LaunchState.Graduated));
    }

    function test_MaliciousTokenCallbacksCannotReenterBuyOrSell() public {
        (ReentrantCurveToken reentrantToken, BondingCurve reentrantCurve) =
            factoryHarness.deployReentrantCurve(creator, treasury, address(manager), makeAddr("reentrant token pair"));
        vm.deal(address(reentrantToken), 1 ether);
        factoryHarness.launchCurve(reentrantCurve, 0, VALID_DEADLINE);

        vm.prank(alice);
        uint256 bought = reentrantCurve.buy{value: 1 ether}(0, VALID_DEADLINE);
        assertTrue(reentrantToken.callbackEntered());
        assertFalse(reentrantToken.reentrantBuySucceeded());

        reentrantToken.resetCallbackResult();
        vm.prank(alice);
        reentrantToken.approve(address(reentrantCurve), bought / 2);
        vm.prank(alice);
        reentrantCurve.sell(bought / 2, 0, VALID_DEADLINE);

        assertTrue(reentrantToken.callbackEntered());
        assertFalse(reentrantToken.reentrantBuySucceeded());
        assertEq(
            reentrantToken.balanceOf(address(reentrantCurve)),
            reentrantCurve.curveTokenInventory() + reentrantCurve.graduationTokenReserve()
        );
    }

    function test_ProductionCurveMatchesSimulatorAcrossEquivalentSequence() public {
        CurveGraduationManagerHarness differentialManager = new CurveGraduationManagerHarness();
        address differentialPair = makeAddr("differential pair");
        (BabyNoxaToken differentialToken, BondingCurve production) =
            factoryHarness.deployCurve(creator, treasury, address(differentialManager), differentialPair);
        BondingCurveSimulator simulator = new BondingCurveSimulator(creator, treasury);

        factoryHarness.launchCurve(production, 0, VALID_DEADLINE);
        vm.prank(creator);
        simulator.launch(0, VALID_DEADLINE);

        vm.prank(alice);
        uint256 productionBought = production.buy{value: 1 ether}(0, VALID_DEADLINE);
        vm.prank(alice);
        uint256 simulatorBought = simulator.buy{value: 1 ether}(0, VALID_DEADLINE);
        assertEq(productionBought, simulatorBought);
        _assertEquivalentTradingState(production, simulator);

        uint256 sellAmount = productionBought / 2;
        vm.prank(alice);
        differentialToken.approve(address(production), sellAmount);
        vm.prank(alice);
        uint256 productionCredit = production.sell(sellAmount, 0, VALID_DEADLINE);
        vm.prank(alice);
        uint256 simulatorCredit = simulator.sell(sellAmount, 0, VALID_DEADLINE);
        assertEq(productionCredit, simulatorCredit);
        _assertEquivalentTradingState(production, simulator);
        assertEq(production.claimableBaseOf(alice), simulator.claimableBaseOf(alice));

        vm.prank(bob);
        uint256 productionFinal = production.buy{value: 10 ether}(0, VALID_DEADLINE);
        vm.prank(bob);
        uint256 simulatorFinal = simulator.buy{value: 10 ether}(0, VALID_DEADLINE);
        assertEq(productionFinal, simulatorFinal);
        assertEq(uint256(production.state()), uint256(simulator.state()));
        assertEq(production.claimableRefundOf(bob), simulator.claimableRefundOf(bob));
        assertEq(production.creatorTradingFees(), simulator.creatorTradingFees());
        assertEq(production.treasuryTradingFees(), simulator.treasuryTradingFees());
        assertEq(production.graduationTreasuryAllocation(), simulator.graduationTreasuryAllocation());
        assertEq(production.graduatedLiquidityBase(), simulator.liquidityBase());
        assertEq(production.graduatedLiquidityTokens(), simulator.liquidityTokens());
        assertEq(production.graduatedBurnedTokens(), simulator.burnedTokens());
        assertEq(
            production.accountedExecutedBase() + production.totalExecutedBaseWithdrawn(),
            simulator.accountedExecutedBase()
        );
    }

    function _assertEquivalentTradingState(BondingCurve production, BondingCurveSimulator simulator) internal view {
        assertEq(uint256(production.state()), uint256(simulator.state()));
        assertEq(production.virtualBaseReserve(), simulator.virtualBaseReserve());
        assertEq(production.virtualTokenReserve(), simulator.virtualTokenReserve());
        assertEq(production.realBaseReserve(), simulator.realBaseReserve());
        assertEq(production.curveTokenInventory(), simulator.curveTokenInventory());
        assertEq(production.graduationTokenReserve(), simulator.graduationTokenReserve());
        assertEq(production.creatorTradingFees(), simulator.creatorTradingFees());
        assertEq(production.treasuryTradingFees(), simulator.treasuryTradingFees());
    }

    function _assertBaseAccounting(BondingCurve target) internal view {
        assertGe(address(target).balance, target.accountedContractBalance());
        assertEq(target.totalGrossBaseSubmitted(), target.totalGrossBaseExecuted() + target.totalGrossBaseRefunded());
        assertEq(target.totalGrossBaseExecuted(), target.accountedExecutedBase() + target.totalExecutedBaseWithdrawn());
        assertEq(target.totalGrossBaseRefunded(), target.totalOutstandingRefunds() + target.totalRefundBaseWithdrawn());
    }

    function _assertFeeOperationAccounting(BondingCurve target) internal view {
        assertEq(target.totalCreatorFeesAccrued(), target.creatorTradingFees() + target.totalCreatorFeesClaimed());
        assertEq(
            target.totalTreasuryFeesAccrued(),
            target.treasuryTradingFees() + target.graduationTreasuryAllocation() + target.totalTreasuryFeesClaimed()
        );
        assertEq(target.totalSellCreditsAccrued(), target.totalClaimableBase() + target.totalSellCreditsClaimed());
        assertEq(target.totalGrossBaseRefunded(), target.totalOutstandingRefunds() + target.totalRefundBaseWithdrawn());
    }
}
