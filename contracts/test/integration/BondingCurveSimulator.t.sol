// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BabyNoxaConstants} from "../../src/libraries/BabyNoxaConstants.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";
import {FeeMath} from "../../src/libraries/FeeMath.sol";
import {BondingCurveSimulator} from "../../src/mocks/BondingCurveSimulator.sol";
import {LaunchState} from "../../src/types/BabyNoxaTypes.sol";

contract ForceEther {
    constructor() payable {}

    function force(address payable recipient) external {
        selfdestruct(recipient);
    }
}

contract BondingCurveSimulatorTest is Test {
    address internal creator = makeAddr("creator");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    BondingCurveSimulator internal simulator;

    function setUp() public {
        simulator = new BondingCurveSimulator(creator, treasury);
        vm.deal(creator, 100 ether);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);

        vm.prank(creator);
        simulator.launch(0);
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
        simulator.launch(0);

        assertEq(uint256(simulator.state()), uint256(LaunchState.Created));
    }

    function test_BuyUpdatesBalancesReservesAndSeparateFeeBuckets() public {
        vm.prank(alice);
        uint256 tokensOut = simulator.buy{value: 1 ether}(0);

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
        simulator.buy{value: 1 ether}(0);

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
        uint256 bobTokens = simulator.buy{value: 0.5 ether}(0);
        assertEq(bobTokens, expectedNextBuy.tokensOut);

        vm.prank(creator);
        simulator.claimCreatorFees();
        assertEq(address(simulator).balance - simulator.accountedContractBalance(), forcedSurplus);

        vm.prank(alice);
        simulator.buy{value: 10 ether}(0);

        assertEq(address(simulator).balance - simulator.accountedContractBalance(), forcedSurplus);
        assertEq(uint256(simulator.state()), uint256(LaunchState.Graduated));
        assertGe(address(simulator).balance, simulator.accountedContractBalance());
    }

    function test_SellRestoresInventoryAndRecordsClaimableBase() public {
        vm.prank(alice);
        uint256 bought = simulator.buy{value: 1 ether}(0);
        uint256 inventoryBeforeSell = simulator.curveTokenInventory();
        uint256 creatorFeesBeforeSell = simulator.creatorTradingFees();
        uint256 sellAmount = bought / 2;

        vm.prank(alice);
        uint256 netBaseCredit = simulator.sell(sellAmount, 0);

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
        uint256 bought = simulator.buy{value: 1 ether}(0);

        vm.prank(alice);
        simulator.sell(bought / 2, 0);

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
        uint256 bought = simulator.buy{value: 1 ether}(0);

        vm.prank(alice);
        simulator.sell(bought / 2, 0);
        uint256 aliceCredit = simulator.claimableBaseOf(alice);

        vm.expectPartialRevert(BondingCurveSimulator.NoClaimableAmount.selector);
        vm.prank(bob);
        simulator.claimBaseCredit();

        assertEq(simulator.claimableBaseOf(alice), aliceCredit);
        assertEq(simulator.claimableBaseOf(bob), 0);
    }

    function test_OnlyCreatorCanClaimCreatorFees() public {
        vm.prank(alice);
        simulator.buy{value: 1 ether}(0);

        vm.expectPartialRevert(BondingCurveSimulator.CreatorOnly.selector);
        vm.prank(bob);
        simulator.claimCreatorFees();

        assertGt(simulator.creatorTradingFees(), 0);
    }

    function test_OnlyTreasuryCanClaimTreasuryFees() public {
        vm.prank(alice);
        simulator.buy{value: 1 ether}(0);

        vm.expectPartialRevert(BondingCurveSimulator.TreasuryOnly.selector);
        vm.prank(creator);
        simulator.claimTreasuryFees();

        assertGt(simulator.treasuryTradingFees(), 0);
    }

    function test_FinalBuyerCanClaimRealEtherRefund() public {
        vm.prank(alice);
        simulator.buy{value: 10 ether}(0);

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
        simulator.buy{value: 10 ether}(0);
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
        uint256 tokensOut = simulator.launch{value: grossInitialBuy}(0);

        assertLe(tokensOut, BabyNoxaConstants.CREATOR_INITIAL_BUY_CAP);
        assertTrue(simulator.creatorInitialBuyExecuted());
        assertEq(uint256(simulator.state()), uint256(LaunchState.Trading));
        assertEq(simulator.tokenBalanceOf(creator), tokensOut);

        vm.expectPartialRevert(BondingCurveSimulator.InvalidState.selector);
        vm.prank(creator);
        simulator.launch{value: 1 ether}(0);
    }

    function test_RevertWhenCreatorInitialBuyExceedsCap() public {
        simulator = new BondingCurveSimulator(creator, treasury);

        vm.expectPartialRevert(BondingCurveSimulator.CreatorInitialBuyCapExceeded.selector);
        vm.prank(creator);
        simulator.launch{value: 1 ether}(0);

        assertEq(uint256(simulator.state()), uint256(LaunchState.Created));
    }

    function test_PublicTradeCannotFrontRunFundedCreatorLaunch() public {
        simulator = new BondingCurveSimulator(creator, treasury);

        vm.expectPartialRevert(BondingCurveSimulator.InvalidState.selector);
        vm.prank(alice);
        simulator.buy{value: 0.1 ether}(0);

        vm.prank(creator);
        uint256 creatorTokens = simulator.launch{value: 0.01 ether}(0);

        vm.prank(alice);
        uint256 aliceTokens = simulator.buy{value: 0.1 ether}(0);

        assertGt(creatorTokens, 0);
        assertGt(aliceTokens, 0);
        assertEq(simulator.tokenBalanceOf(creator), creatorTokens);
        assertTrue(simulator.creatorInitialBuyExecuted());
    }

    function test_FinalBuyRefundsExcessAndGraduatesAtomically() public {
        vm.prank(alice);
        uint256 tokensOut = simulator.buy{value: 10 ether}(0);

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
        uint256 aliceBought = simulator.buy{value: 1 ether}(0);

        vm.prank(alice);
        simulator.sell(aliceBought / 2, 0);

        vm.prank(bob);
        simulator.buy{value: 10 ether}(0);

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
        simulator.buy{value: 10 ether}(0);

        vm.expectPartialRevert(BondingCurveSimulator.InvalidState.selector);
        vm.prank(bob);
        simulator.buy{value: 1 ether}(0);

        vm.expectPartialRevert(BondingCurveSimulator.InvalidState.selector);
        vm.prank(alice);
        simulator.sell(1 ether, 0);
    }

    function test_RevertOnBuyAndSellSlippage() public {
        vm.expectPartialRevert(BondingCurveSimulator.TokenSlippageExceeded.selector);
        vm.prank(alice);
        simulator.buy{value: 0.1 ether}(BabyNoxaConstants.CURVE_TOKEN_ALLOCATION);

        vm.prank(alice);
        uint256 bought = simulator.buy{value: 0.1 ether}(0);

        vm.expectPartialRevert(BondingCurveSimulator.BaseSlippageExceeded.selector);
        vm.prank(alice);
        simulator.sell(bought, 1 ether);
    }

    function testFuzz_BuyThenPartialSellPreservesAllAccounting(uint96 rawGrossBuy, uint96 rawSell) public {
        uint256 grossBuy = bound(uint256(rawGrossBuy), 0.001 ether, 1 ether);

        vm.prank(alice);
        uint256 bought = simulator.buy{value: grossBuy}(0);
        uint256 sellAmount = bound(uint256(rawSell), 1 ether, bought);

        vm.prank(alice);
        simulator.sell(sellAmount, 0);

        assertEq(simulator.accountedExecutedBase(), simulator.totalGrossBaseExecuted());
        assertEq(simulator.accountedTokenSupply(), BabyNoxaConstants.TOTAL_SUPPLY);
        assertEq(
            simulator.totalGrossBaseSubmitted(), simulator.totalGrossBaseExecuted() + simulator.totalGrossBaseRefunded()
        );
    }
}
