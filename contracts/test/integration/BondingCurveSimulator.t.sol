// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {BabyNoxaConstants} from "../../src/libraries/BabyNoxaConstants.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";
import {DeadlinePolicy} from "../../src/libraries/DeadlinePolicy.sol";
import {FeeMath} from "../../src/libraries/FeeMath.sol";
import {BondingCurveSimulator} from "../../src/mocks/BondingCurveSimulator.sol";
import {LaunchState} from "../../src/types/BabyNoxaTypes.sol";

contract ForceEther {
    constructor() payable {}

    function force(address payable recipient) external {
        selfdestruct(recipient);
    }
}

contract RejectEther {
    receive() external payable {
        revert("ETH_REJECTED");
    }
}

contract ReentrantClaimReceiver {
    BondingCurveSimulator public simulator;
    bool public callbackEntered;
    bool public buySucceeded;
    bool public sellSucceeded;
    bool public launchSucceeded;
    bool public claimSucceeded;

    function setSimulator(BondingCurveSimulator simulator_) external {
        simulator = simulator_;
    }

    function launchWithCreatorBuy() external payable {
        simulator.launch{value: msg.value}(0, type(uint256).max);
    }

    function claimCreatorFees() external {
        simulator.claimCreatorFeesTo(payable(address(this)));
    }

    receive() external payable {
        if (callbackEntered) return;
        callbackEntered = true;

        (buySucceeded,) =
            address(simulator).call{value: 200}(abi.encodeCall(BondingCurveSimulator.buy, (0, type(uint256).max)));
        (sellSucceeded,) =
            address(simulator).call(abi.encodeCall(BondingCurveSimulator.sell, (1, 0, type(uint256).max)));
        (launchSucceeded,) =
            address(simulator).call(abi.encodeCall(BondingCurveSimulator.launch, (0, type(uint256).max)));
        (claimSucceeded,) = address(simulator).call(abi.encodeCall(BondingCurveSimulator.claimCreatorFees, ()));
    }
}

contract BondingCurveSimulatorTest is Test {
    uint256 internal constant VALID_DEADLINE = type(uint256).max;

    address internal creator = makeAddr("creator");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    BondingCurveSimulator internal simulator;

    event CreatorFeeAccrued(address indexed beneficiary, address indexed trader, uint256 amount, bool isBuy);
    event TreasuryFeeAccrued(address indexed beneficiary, address indexed trader, uint256 amount, bool isBuy);

    function setUp() public {
        simulator = new BondingCurveSimulator(creator, treasury);
        vm.deal(creator, 100 ether);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);

        vm.prank(creator);
        simulator.launch(0, VALID_DEADLINE);
    }

    function test_LaunchWithoutCreatorBuyOpensTradingAndAccountsForEntireSupply() public view {
        assertEq(uint256(simulator.state()), uint256(LaunchState.Trading));
        assertFalse(simulator.creatorInitialBuyExecuted());
        assertEq(simulator.virtualBaseReserve(), BabyNoxaConstants.INITIAL_VIRTUAL_BASE_RESERVE);
        assertEq(simulator.virtualTokenReserve(), BabyNoxaConstants.INITIAL_VIRTUAL_TOKEN_RESERVE);
        assertEq(simulator.curveTokenInventory(), BabyNoxaConstants.CURVE_TOKEN_ALLOCATION);
        assertEq(simulator.graduationTokenReserve(), BabyNoxaConstants.GRADUATION_TOKEN_RESERVE);
        assertEq(simulator.accountedTokenSupply(), BabyNoxaConstants.TOTAL_SUPPLY);
        assertEq(simulator.accountedExecutedBase(), 0);
    }

    function test_OnlyCreatorCanOpenLaunch() public {
        simulator = new BondingCurveSimulator(creator, treasury);

        vm.expectPartialRevert(BondingCurveSimulator.CreatorOnly.selector);
        vm.prank(alice);
        simulator.launch(0, VALID_DEADLINE);

        assertEq(uint256(simulator.state()), uint256(LaunchState.Created));
    }

    function test_BuyUpdatesBalancesReservesAndSeparateFeeBuckets() public {
        vm.prank(alice);
        uint256 tokensOut = simulator.buy{value: 1 ether}(0, VALID_DEADLINE);

        assertEq(simulator.tokenBalanceOf(alice), tokensOut);
        assertEq(simulator.totalUserTokenBalances(), tokensOut);
        assertEq(simulator.realBaseReserve(), 0.99 ether);
        assertEq(simulator.creatorTradingFees(), 0.005 ether);
        assertEq(simulator.treasuryTradingFees(), 0.005 ether);
        assertEq(simulator.curveTokenInventory(), BabyNoxaConstants.CURVE_TOKEN_ALLOCATION - tokensOut);
        assertEq(simulator.totalGrossBaseSubmitted(), 1 ether);
        assertEq(simulator.totalGrossBaseExecuted(), 1 ether);
        assertEq(simulator.accountedExecutedBase(), 1 ether);
        assertEq(simulator.accountedTokenSupply(), BabyNoxaConstants.TOTAL_SUPPLY);
        assertEq(address(simulator).balance, 1 ether);
        assertEq(simulator.accountedContractBalance(), 1 ether);
    }

    function test_ForcedEtherCreatesOnlyUntrackedSurplusAndCannotWeakenLiabilityAccounting() public {
        vm.prank(alice);
        simulator.buy{value: 1 ether}(0, VALID_DEADLINE);

        FeeMath.TradeFeeQuote memory nextFee = FeeMath.quoteTrade(0.5 ether);
        CurveMath.BuyQuote memory expectedNextBuy = CurveMath.quoteBuy(
            simulator.virtualBaseReserve(),
            simulator.virtualTokenReserve(),
            simulator.curveTokenInventory(),
            nextFee.netAmount
        );

        uint256 forcedSurplus = 0.25 ether;
        ForceEther forceEther = new ForceEther{value: forcedSurplus}();
        forceEther.force(payable(address(simulator)));
        assertEq(address(simulator).balance - simulator.accountedContractBalance(), forcedSurplus);

        vm.prank(bob);
        uint256 bobTokens = simulator.buy{value: 0.5 ether}(0, VALID_DEADLINE);
        assertEq(bobTokens, expectedNextBuy.tokensOut);

        vm.prank(creator);
        simulator.claimCreatorFees();
        assertEq(address(simulator).balance - simulator.accountedContractBalance(), forcedSurplus);

        vm.prank(alice);
        simulator.buy{value: 10 ether}(0, VALID_DEADLINE);

        assertEq(address(simulator).balance - simulator.accountedContractBalance(), forcedSurplus);
        assertEq(uint256(simulator.state()), uint256(LaunchState.Graduated));
        assertGe(address(simulator).balance, simulator.accountedContractBalance());
    }

    function test_SellRestoresInventoryAndRecordsClaimableBase() public {
        vm.prank(alice);
        uint256 bought = simulator.buy{value: 1 ether}(0, VALID_DEADLINE);
        uint256 inventoryBeforeSell = simulator.curveTokenInventory();
        uint256 creatorFeesBeforeSell = simulator.creatorTradingFees();
        uint256 sellAmount = bought / 2;

        vm.prank(alice);
        uint256 netBaseCredit = simulator.sell(sellAmount, 0, VALID_DEADLINE);

        assertEq(simulator.tokenBalanceOf(alice), bought - sellAmount);
        assertEq(simulator.curveTokenInventory(), inventoryBeforeSell + sellAmount);
        assertEq(simulator.claimableBaseOf(alice), netBaseCredit);
        assertEq(simulator.totalClaimableBase(), netBaseCredit);
        assertGt(simulator.creatorTradingFees(), creatorFeesBeforeSell);
        assertEq(simulator.accountedExecutedBase(), simulator.totalGrossBaseExecuted());
        assertEq(simulator.accountedTokenSupply(), BabyNoxaConstants.TOTAL_SUPPLY);
    }

    function test_ClaimsTransferRealEtherAndClearLiabilities() public {
        vm.prank(alice);
        uint256 bought = simulator.buy{value: 1 ether}(0, VALID_DEADLINE);

        vm.prank(alice);
        simulator.sell(bought / 2, 0, VALID_DEADLINE);

        uint256 sellerCredit = simulator.claimableBaseOf(alice);
        uint256 aliceBalanceBefore = alice.balance;
        vm.prank(alice);
        simulator.claimBaseCredit();
        assertEq(alice.balance, aliceBalanceBefore + sellerCredit);
        assertEq(simulator.claimableBaseOf(alice), 0);

        uint256 creatorFees = simulator.creatorTradingFees();
        uint256 creatorBalanceBefore = creator.balance;
        vm.prank(creator);
        simulator.claimCreatorFees();
        assertEq(creator.balance, creatorBalanceBefore + creatorFees);
        assertEq(simulator.creatorTradingFees(), 0);

        uint256 treasuryFees = simulator.treasuryTradingFees();
        uint256 treasuryBalanceBefore = treasury.balance;
        vm.prank(treasury);
        simulator.claimTreasuryFees();
        assertEq(treasury.balance, treasuryBalanceBefore + treasuryFees);
        assertEq(simulator.treasuryTradingFees(), 0);

        assertEq(address(simulator).balance, simulator.accountedContractBalance());
    }

    function test_UserClaimsAreOwnedByTheCreditedAddress() public {
        vm.prank(alice);
        uint256 bought = simulator.buy{value: 1 ether}(0, VALID_DEADLINE);

        vm.prank(alice);
        simulator.sell(bought / 2, 0, VALID_DEADLINE);
        uint256 aliceCredit = simulator.claimableBaseOf(alice);

        vm.expectPartialRevert(BondingCurveSimulator.NoClaimableAmount.selector);
        vm.prank(bob);
        simulator.claimBaseCredit();

        assertEq(simulator.claimableBaseOf(alice), aliceCredit);
        assertEq(simulator.claimableBaseOf(bob), 0);
    }

    function test_OnlyCreatorCanClaimCreatorFees() public {
        vm.prank(alice);
        simulator.buy{value: 1 ether}(0, VALID_DEADLINE);

        vm.expectPartialRevert(BondingCurveSimulator.CreatorOnly.selector);
        vm.prank(bob);
        simulator.claimCreatorFees();

        assertGt(simulator.creatorTradingFees(), 0);
    }

    function test_OnlyTreasuryCanClaimTreasuryFees() public {
        vm.prank(alice);
        simulator.buy{value: 1 ether}(0, VALID_DEADLINE);

        vm.expectPartialRevert(BondingCurveSimulator.TreasuryOnly.selector);
        vm.prank(creator);
        simulator.claimTreasuryFees();

        assertGt(simulator.treasuryTradingFees(), 0);
    }

    function test_FinalBuyerCanClaimRealEtherRefund() public {
        vm.prank(alice);
        simulator.buy{value: 10 ether}(0, VALID_DEADLINE);

        uint256 refund = simulator.claimableRefundOf(alice);
        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        simulator.claimRefund();

        assertEq(alice.balance, balanceBefore + refund);
        assertEq(simulator.claimableRefundOf(alice), 0);
        assertEq(simulator.totalOutstandingRefunds(), 0);
        assertEq(address(simulator).balance, simulator.accountedContractBalance());
    }

    function test_FinalBuyRefundCannotBeClaimedByAnotherAddress() public {
        vm.prank(alice);
        simulator.buy{value: 10 ether}(0, VALID_DEADLINE);
        uint256 aliceRefund = simulator.claimableRefundOf(alice);

        vm.expectPartialRevert(BondingCurveSimulator.NoClaimableAmount.selector);
        vm.prank(bob);
        simulator.claimRefund();

        assertEq(simulator.claimableRefundOf(alice), aliceRefund);
        assertEq(simulator.claimableRefundOf(bob), 0);
    }

    function test_CreatorInitialBuyMustOccurFirstAndStayBelowCap() public {
        simulator = new BondingCurveSimulator(creator, treasury);

        (uint256 netForNineteenMillion,,) = CurveMath.netBaseForExactTokensOut(
            BabyNoxaConstants.INITIAL_VIRTUAL_BASE_RESERVE,
            BabyNoxaConstants.INITIAL_VIRTUAL_TOKEN_RESERVE,
            19_000_000 ether
        );

        uint256 grossInitialBuy = FeeMath.grossFromNet(netForNineteenMillion);
        vm.prank(creator);
        uint256 tokensOut = simulator.launch{value: grossInitialBuy}(0, VALID_DEADLINE);

        assertLe(tokensOut, BabyNoxaConstants.CREATOR_INITIAL_BUY_CAP);
        assertTrue(simulator.creatorInitialBuyExecuted());
        assertEq(uint256(simulator.state()), uint256(LaunchState.Trading));
        assertEq(simulator.tokenBalanceOf(creator), tokensOut);

        vm.expectPartialRevert(BondingCurveSimulator.InvalidState.selector);
        vm.prank(creator);
        simulator.launch{value: 1 ether}(0, VALID_DEADLINE);
    }

    function test_RevertWhenCreatorInitialBuyExceedsCap() public {
        simulator = new BondingCurveSimulator(creator, treasury);

        vm.expectPartialRevert(BondingCurveSimulator.CreatorInitialBuyCapExceeded.selector);
        vm.prank(creator);
        simulator.launch{value: 1 ether}(0, VALID_DEADLINE);

        assertEq(uint256(simulator.state()), uint256(LaunchState.Created));
    }

    function test_PublicTradeCannotFrontRunFundedCreatorLaunch() public {
        simulator = new BondingCurveSimulator(creator, treasury);

        vm.expectPartialRevert(BondingCurveSimulator.InvalidState.selector);
        vm.prank(alice);
        simulator.buy{value: 0.1 ether}(0, VALID_DEADLINE);

        vm.prank(creator);
        uint256 creatorTokens = simulator.launch{value: 0.01 ether}(0, VALID_DEADLINE);

        vm.prank(alice);
        uint256 aliceTokens = simulator.buy{value: 0.1 ether}(0, VALID_DEADLINE);

        assertGt(creatorTokens, 0);
        assertGt(aliceTokens, 0);
        assertEq(simulator.tokenBalanceOf(creator), creatorTokens);
        assertTrue(simulator.creatorInitialBuyExecuted());
    }

    function test_FinalBuyRefundsExcessAndGraduatesAtomically() public {
        vm.prank(alice);
        uint256 tokensOut = simulator.buy{value: 10 ether}(0, VALID_DEADLINE);

        assertEq(tokensOut, BabyNoxaConstants.CURVE_TOKEN_ALLOCATION);
        assertEq(uint256(simulator.state()), uint256(LaunchState.Graduated));
        assertEq(simulator.curveTokenInventory(), 0);
        assertEq(simulator.graduationTokenReserve(), 0);
        assertEq(simulator.realBaseReserve(), 0);
        assertEq(simulator.tokenBalanceOf(alice), BabyNoxaConstants.CURVE_TOKEN_ALLOCATION);
        assertGt(simulator.claimableRefundOf(alice), 5 ether);
        assertEq(
            simulator.totalGrossBaseSubmitted(), simulator.totalGrossBaseExecuted() + simulator.totalGrossBaseRefunded()
        );

        assertGt(simulator.mockTotalLp(), 0);
        assertEq(simulator.mockBurnedLp(), simulator.mockTotalLp());
        assertEq(simulator.mockTreasuryLp(), 0);
        assertEq(simulator.liquidityTokens() + simulator.burnedTokens(), BabyNoxaConstants.GRADUATION_TOKEN_RESERVE);
        assertEq(simulator.accountedExecutedBase(), simulator.totalGrossBaseExecuted());
        assertEq(simulator.accountedTokenSupply(), BabyNoxaConstants.TOTAL_SUPPLY);
    }

    function test_BuySellThenFinalBuyMaintainsAccountingAndGraduates() public {
        vm.prank(alice);
        uint256 aliceBought = simulator.buy{value: 1 ether}(0, VALID_DEADLINE);

        vm.prank(alice);
        simulator.sell(aliceBought / 2, 0, VALID_DEADLINE);

        vm.prank(bob);
        simulator.buy{value: 10 ether}(0, VALID_DEADLINE);

        assertEq(uint256(simulator.state()), uint256(LaunchState.Graduated));
        assertGt(simulator.tokenBalanceOf(alice), 0);
        assertGt(simulator.tokenBalanceOf(bob), 0);
        assertGt(simulator.claimableBaseOf(alice), 0);
        assertGt(simulator.claimableRefundOf(bob), 0);
        assertEq(simulator.accountedExecutedBase(), simulator.totalGrossBaseExecuted());
        assertEq(simulator.accountedTokenSupply(), BabyNoxaConstants.TOTAL_SUPPLY);
    }

    function test_GraduatedCurveRejectsFurtherTrading() public {
        vm.prank(alice);
        simulator.buy{value: 10 ether}(0, VALID_DEADLINE);

        vm.expectPartialRevert(BondingCurveSimulator.InvalidState.selector);
        vm.prank(bob);
        simulator.buy{value: 1 ether}(0, VALID_DEADLINE);

        vm.expectPartialRevert(BondingCurveSimulator.InvalidState.selector);
        vm.prank(alice);
        simulator.sell(1 ether, 0, VALID_DEADLINE);
    }

    function test_RevertOnBuyAndSellSlippage() public {
        vm.expectPartialRevert(BondingCurveSimulator.TokenSlippageExceeded.selector);
        vm.prank(alice);
        simulator.buy{value: 0.1 ether}(BabyNoxaConstants.CURVE_TOKEN_ALLOCATION, VALID_DEADLINE);

        vm.prank(alice);
        uint256 bought = simulator.buy{value: 0.1 ether}(0, VALID_DEADLINE);

        vm.expectPartialRevert(BondingCurveSimulator.BaseSlippageExceeded.selector);
        vm.prank(alice);
        simulator.sell(bought, 1 ether, VALID_DEADLINE);
    }

    function test_ExpiredBuyRevertsWithoutChangingAccounting() public {
        uint256 deadline = 1_000;
        vm.warp(deadline + 1);

        vm.expectRevert(abi.encodeWithSelector(DeadlinePolicy.DeadlineExpired.selector, deadline, deadline + 1));
        vm.prank(alice);
        simulator.buy{value: 1 ether}(0, deadline);

        assertEq(simulator.totalGrossBaseSubmitted(), 0);
        assertEq(simulator.totalUserTokenBalances(), 0);
        assertEq(address(simulator).balance, 0);
    }

    function test_ExpiredSellRevertsWithoutChangingAccounting() public {
        vm.prank(alice);
        uint256 bought = simulator.buy{value: 1 ether}(0, VALID_DEADLINE);

        uint256 deadline = 1_000;
        vm.warp(deadline + 1);
        uint256 inventoryBefore = simulator.curveTokenInventory();
        uint256 reserveBefore = simulator.realBaseReserve();

        vm.expectRevert(abi.encodeWithSelector(DeadlinePolicy.DeadlineExpired.selector, deadline, deadline + 1));
        vm.prank(alice);
        simulator.sell(bought / 2, 0, deadline);

        assertEq(simulator.tokenBalanceOf(alice), bought);
        assertEq(simulator.curveTokenInventory(), inventoryBefore);
        assertEq(simulator.realBaseReserve(), reserveBefore);
    }

    function test_DeadlineEqualityKeepsBuyQuoteAndAccountingExact() public {
        uint256 grossBase = 1 ether;
        FeeMath.TradeFeeQuote memory expectedFee = FeeMath.quoteTrade(grossBase);
        CurveMath.BuyQuote memory expectedCurve = CurveMath.quoteBuy(
            simulator.virtualBaseReserve(),
            simulator.virtualTokenReserve(),
            simulator.curveTokenInventory(),
            expectedFee.netAmount
        );

        uint256 deadline = 10_000;
        vm.warp(deadline);
        vm.prank(alice);
        uint256 tokensOut = simulator.buy{value: grossBase}(expectedCurve.tokensOut, deadline);

        assertEq(tokensOut, expectedCurve.tokensOut);
        assertEq(simulator.virtualBaseReserve(), expectedCurve.newVirtualBaseReserve);
        assertEq(simulator.virtualTokenReserve(), expectedCurve.newVirtualTokenReserve);
        assertEq(simulator.realBaseReserve(), expectedFee.netAmount);
        assertEq(simulator.accountedExecutedBase(), grossBase);
    }

    function test_ExpiredCreatorLaunchReverts() public {
        simulator = new BondingCurveSimulator(creator, treasury);
        uint256 deadline = 500;
        vm.warp(deadline + 1);

        vm.expectRevert(abi.encodeWithSelector(DeadlinePolicy.DeadlineExpired.selector, deadline, deadline + 1));
        vm.prank(creator);
        simulator.launch(0, deadline);

        assertEq(uint256(simulator.state()), uint256(LaunchState.Created));
    }

    function test_BuyRejectsExecutedGrossBelowFloorAndAcceptsFloor() public {
        uint256 minimum = BabyNoxaConstants.MIN_GROSS_TRADE_VALUE;

        vm.expectRevert(
            abi.encodeWithSelector(BondingCurveSimulator.TradeValueBelowMinimum.selector, minimum - 1, minimum)
        );
        vm.prank(alice);
        simulator.buy{value: minimum - 1}(0, VALID_DEADLINE);

        vm.prank(alice);
        uint256 tokensOut = simulator.buy{value: minimum}(0, VALID_DEADLINE);

        assertGt(tokensOut, 0);
        assertEq(simulator.totalGrossBaseExecuted(), minimum);
        assertEq(simulator.creatorTradingFees(), 1);
        assertEq(simulator.treasuryTradingFees(), 1);
    }

    function test_SellRejectsQuotedGrossBelowFloorAndAcceptsFloor() public {
        vm.prank(alice);
        simulator.buy{value: 1 ether}(0, VALID_DEADLINE);

        uint256 minimumTokenInput = _minimumSellTokensForGross(
            simulator.virtualBaseReserve(), simulator.virtualTokenReserve(), BabyNoxaConstants.MIN_GROSS_TRADE_VALUE
        );
        uint256 belowGross =
            _grossSellOutput(simulator.virtualBaseReserve(), simulator.virtualTokenReserve(), minimumTokenInput - 1);
        assertEq(belowGross, BabyNoxaConstants.MIN_GROSS_TRADE_VALUE - 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                BondingCurveSimulator.TradeValueBelowMinimum.selector,
                belowGross,
                BabyNoxaConstants.MIN_GROSS_TRADE_VALUE
            )
        );
        vm.prank(alice);
        simulator.sell(minimumTokenInput - 1, 0, VALID_DEADLINE);

        vm.prank(alice);
        uint256 netCredit = simulator.sell(minimumTokenInput, 0, VALID_DEADLINE);
        assertEq(netCredit, 198);
    }

    function test_BuyCannotStrandAnUnfillableSubMinimumCurveRemainder() public {
        (uint256 exactNetBase,,) = CurveMath.netBaseForExactTokensOut(
            BabyNoxaConstants.INITIAL_VIRTUAL_BASE_RESERVE,
            BabyNoxaConstants.INITIAL_VIRTUAL_TOKEN_RESERVE,
            BabyNoxaConstants.CURVE_TOKEN_ALLOCATION
        );
        uint256 exactGrossBase = FeeMath.grossFromNet(exactNetBase);

        vm.expectPartialRevert(BondingCurveSimulator.UnfillableCurveRemainder.selector);
        vm.prank(alice);
        simulator.buy{value: exactGrossBase - 1}(0, VALID_DEADLINE);

        assertEq(simulator.curveTokenInventory(), BabyNoxaConstants.CURVE_TOKEN_ALLOCATION);
        assertEq(simulator.totalGrossBaseSubmitted(), 0);

        vm.prank(alice);
        simulator.buy{value: exactGrossBase}(0, VALID_DEADLINE);
        assertEq(uint256(simulator.state()), uint256(LaunchState.Graduated));
    }

    function test_UserCanRedirectOnlyTheirOwnSellCredit() public {
        vm.prank(alice);
        uint256 bought = simulator.buy{value: 1 ether}(0, VALID_DEADLINE);
        vm.prank(alice);
        simulator.sell(bought / 2, 0, VALID_DEADLINE);

        uint256 credit = simulator.claimableBaseOf(alice);
        vm.expectPartialRevert(BondingCurveSimulator.NoClaimableAmount.selector);
        vm.prank(bob);
        simulator.claimBaseCreditTo(payable(bob));
        assertEq(simulator.claimableBaseOf(alice), credit);

        uint256 bobBalanceBefore = bob.balance;
        vm.prank(alice);
        simulator.claimBaseCreditTo(payable(bob));
        assertEq(bob.balance, bobBalanceBefore + credit);
        assertEq(simulator.claimableBaseOf(alice), 0);
    }

    function test_FinalBuyerCanRedirectOnlyTheirOwnRefund() public {
        vm.prank(alice);
        simulator.buy{value: 10 ether}(0, VALID_DEADLINE);
        uint256 refund = simulator.claimableRefundOf(alice);

        vm.expectPartialRevert(BondingCurveSimulator.NoClaimableAmount.selector);
        vm.prank(bob);
        simulator.claimRefundTo(payable(bob));
        assertEq(simulator.claimableRefundOf(alice), refund);

        uint256 bobBalanceBefore = bob.balance;
        vm.prank(alice);
        simulator.claimRefundTo(payable(bob));
        assertEq(bob.balance, bobBalanceBefore + refund);
        assertEq(simulator.claimableRefundOf(alice), 0);
    }

    function test_CreatorAndTreasuryCanRedirectTheirOwnFees() public {
        vm.prank(alice);
        simulator.buy{value: 1 ether}(0, VALID_DEADLINE);

        uint256 creatorFees = simulator.creatorTradingFees();
        uint256 treasuryFees = simulator.treasuryTradingFees();
        uint256 bobBalanceBefore = bob.balance;

        vm.prank(creator);
        simulator.claimCreatorFeesTo(payable(bob));
        vm.prank(treasury);
        simulator.claimTreasuryFeesTo(payable(bob));

        assertEq(bob.balance, bobBalanceBefore + creatorFees + treasuryFees);
        assertEq(simulator.creatorTradingFees(), 0);
        assertEq(simulator.treasuryTradingFees(), 0);
    }

    function test_RedirectedRoleClaimsRemainRestricted() public {
        vm.prank(alice);
        simulator.buy{value: 1 ether}(0, VALID_DEADLINE);

        vm.expectPartialRevert(BondingCurveSimulator.CreatorOnly.selector);
        vm.prank(bob);
        simulator.claimCreatorFeesTo(payable(bob));

        vm.expectPartialRevert(BondingCurveSimulator.TreasuryOnly.selector);
        vm.prank(bob);
        simulator.claimTreasuryFeesTo(payable(bob));
    }

    function test_RejectingClaimRecipientRollsBackClaimState() public {
        RejectEther rejectEther = new RejectEther();
        vm.prank(alice);
        uint256 bought = simulator.buy{value: 1 ether}(0, VALID_DEADLINE);
        vm.prank(alice);
        simulator.sell(bought / 2, 0, VALID_DEADLINE);
        uint256 credit = simulator.claimableBaseOf(alice);

        vm.expectRevert(
            abi.encodeWithSelector(BondingCurveSimulator.EtherTransferFailed.selector, address(rejectEther), credit)
        );
        vm.prank(alice);
        simulator.claimBaseCreditTo(payable(address(rejectEther)));

        assertEq(simulator.claimableBaseOf(alice), credit);
        assertEq(simulator.totalClaimableBase(), credit);
    }

    function test_ClaimToRejectsZeroRecipient() public {
        vm.prank(alice);
        uint256 bought = simulator.buy{value: 1 ether}(0, VALID_DEADLINE);
        vm.prank(alice);
        simulator.sell(bought / 2, 0, VALID_DEADLINE);

        vm.expectRevert(BondingCurveSimulator.ZeroAddress.selector);
        vm.prank(alice);
        simulator.claimBaseCreditTo(payable(address(0)));
    }

    function test_BuyAndSellEmitSeparateFeeAccrualEvents() public {
        vm.expectEmit(true, true, false, true, address(simulator));
        emit CreatorFeeAccrued(creator, alice, 0.005 ether, true);
        vm.expectEmit(true, true, false, true, address(simulator));
        emit TreasuryFeeAccrued(treasury, alice, 0.005 ether, true);
        vm.prank(alice);
        uint256 bought = simulator.buy{value: 1 ether}(0, VALID_DEADLINE);

        uint256 sellAmount = bought / 2;
        CurveMath.SellQuote memory curve = CurveMath.quoteSell(
            simulator.virtualBaseReserve(), simulator.virtualTokenReserve(), sellAmount, simulator.realBaseReserve()
        );
        FeeMath.TradeFeeQuote memory fee = FeeMath.quoteTrade(curve.grossBaseOut);

        vm.expectEmit(true, true, false, true, address(simulator));
        emit CreatorFeeAccrued(creator, alice, fee.creatorFee, false);
        vm.expectEmit(true, true, false, true, address(simulator));
        emit TreasuryFeeAccrued(treasury, alice, fee.treasuryFee, false);
        vm.prank(alice);
        simulator.sell(sellAmount, 0, VALID_DEADLINE);
    }

    function test_ClaimCallbackCannotReenterTradingLaunchOrClaims() public {
        ReentrantClaimReceiver receiver = new ReentrantClaimReceiver();
        simulator = new BondingCurveSimulator(address(receiver), treasury);
        receiver.setSimulator(simulator);

        vm.deal(address(this), 1 ether);
        receiver.launchWithCreatorBuy{value: 0.01 ether}();
        vm.prank(alice);
        simulator.buy{value: 1 ether}(0, VALID_DEADLINE);

        uint256 virtualBaseBefore = simulator.virtualBaseReserve();
        uint256 virtualTokensBefore = simulator.virtualTokenReserve();
        uint256 inventoryBefore = simulator.curveTokenInventory();
        uint256 submittedBefore = simulator.totalGrossBaseSubmitted();
        uint256 executedBefore = simulator.totalGrossBaseExecuted();
        uint256 creatorTokensBefore = simulator.tokenBalanceOf(address(receiver));
        uint256 claimedFees = simulator.creatorTradingFees();

        receiver.claimCreatorFees();

        assertTrue(receiver.callbackEntered());
        assertFalse(receiver.buySucceeded());
        assertFalse(receiver.sellSucceeded());
        assertFalse(receiver.launchSucceeded());
        assertFalse(receiver.claimSucceeded());
        assertEq(uint256(simulator.state()), uint256(LaunchState.Trading));
        assertEq(simulator.virtualBaseReserve(), virtualBaseBefore);
        assertEq(simulator.virtualTokenReserve(), virtualTokensBefore);
        assertEq(simulator.curveTokenInventory(), inventoryBefore);
        assertEq(simulator.totalGrossBaseSubmitted(), submittedBefore);
        assertEq(simulator.totalGrossBaseExecuted(), executedBefore);
        assertEq(simulator.tokenBalanceOf(address(receiver)), creatorTokensBefore);
        assertEq(simulator.creatorTradingFees(), 0);
        assertEq(address(receiver).balance, claimedFees);
        assertEq(address(simulator).balance, simulator.accountedContractBalance());
    }

    function testFuzz_BuyThenPartialSellPreservesAllAccounting(uint96 rawGrossBuy, uint96 rawSell) public {
        uint256 grossBuy = bound(uint256(rawGrossBuy), 0.001 ether, 1 ether);

        vm.prank(alice);
        uint256 bought = simulator.buy{value: grossBuy}(0, VALID_DEADLINE);
        uint256 sellAmount = bound(uint256(rawSell), 1 ether, bought);

        vm.prank(alice);
        simulator.sell(sellAmount, 0, VALID_DEADLINE);

        assertEq(simulator.accountedExecutedBase(), simulator.totalGrossBaseExecuted());
        assertEq(simulator.accountedTokenSupply(), BabyNoxaConstants.TOTAL_SUPPLY);
        assertEq(
            simulator.totalGrossBaseSubmitted(), simulator.totalGrossBaseExecuted() + simulator.totalGrossBaseRefunded()
        );
    }

    function _minimumSellTokensForGross(uint256 virtualBase, uint256 virtualTokens, uint256 minimumGross)
        private
        pure
        returns (uint256 tokenInput)
    {
        uint256 low = 1;
        uint256 high = 1 ether;
        while (low < high) {
            uint256 middle = (low + high) / 2;
            if (_grossSellOutput(virtualBase, virtualTokens, middle) >= minimumGross) {
                high = middle;
            } else {
                low = middle + 1;
            }
        }
        return low;
    }

    function _grossSellOutput(uint256 virtualBase, uint256 virtualTokens, uint256 tokenInput)
        private
        pure
        returns (uint256)
    {
        uint256 newVirtualBase = Math.mulDiv(virtualBase, virtualTokens, virtualTokens + tokenInput, Math.Rounding.Ceil);
        return virtualBase - newVirtualBase;
    }
}
