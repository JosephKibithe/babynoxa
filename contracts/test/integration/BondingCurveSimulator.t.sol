// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BabyNoxaConstants} from "../../src/libraries/BabyNoxaConstants.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";
import {FeeMath} from "../../src/libraries/FeeMath.sol";
import {BondingCurveSimulator} from "../../src/mocks/BondingCurveSimulator.sol";
import {LaunchState} from "../../src/types/BabyNoxaTypes.sol";

contract BondingCurveSimulatorTest is Test {
    address internal creator = makeAddr("creator");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    BondingCurveSimulator internal simulator;

    function setUp() public {
        simulator = new BondingCurveSimulator(creator, treasury);
    }

    function test_InitialStateAccountsForEntireSupply() public view {
        assertEq(uint256(simulator.state()), uint256(LaunchState.Trading));
        assertEq(simulator.virtualBaseReserve(), BabyNoxaConstants.INITIAL_VIRTUAL_BASE_RESERVE);
        assertEq(simulator.virtualTokenReserve(), BabyNoxaConstants.INITIAL_VIRTUAL_TOKEN_RESERVE);
        assertEq(simulator.curveTokenInventory(), BabyNoxaConstants.CURVE_TOKEN_ALLOCATION);
        assertEq(simulator.graduationTokenReserve(), BabyNoxaConstants.GRADUATION_TOKEN_RESERVE);
        assertEq(simulator.accountedTokenSupply(), BabyNoxaConstants.TOTAL_SUPPLY);
        assertEq(simulator.accountedExecutedBase(), 0);
    }

    function test_BuyUpdatesBalancesReservesAndSeparateFeeBuckets() public {
        vm.prank(alice);
        uint256 tokensOut = simulator.buy(1 ether, 0);

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
    }

    function test_SellRestoresInventoryAndRecordsMockBaseCredit() public {
        vm.prank(alice);
        uint256 bought = simulator.buy(1 ether, 0);
        uint256 inventoryBeforeSell = simulator.curveTokenInventory();
        uint256 creatorFeesBeforeSell = simulator.creatorTradingFees();
        uint256 sellAmount = bought / 2;

        vm.prank(alice);
        uint256 netBaseCredit = simulator.sell(sellAmount, 0);

        assertEq(simulator.tokenBalanceOf(alice), bought - sellAmount);
        assertEq(simulator.curveTokenInventory(), inventoryBeforeSell + sellAmount);
        assertEq(simulator.mockBaseCreditOf(alice), netBaseCredit);
        assertEq(simulator.totalMockBaseCredits(), netBaseCredit);
        assertGt(simulator.creatorTradingFees(), creatorFeesBeforeSell);
        assertEq(simulator.accountedExecutedBase(), simulator.totalGrossBaseExecuted());
        assertEq(simulator.accountedTokenSupply(), BabyNoxaConstants.TOTAL_SUPPLY);
    }

    function test_CreatorInitialBuyMustOccurFirstAndStayBelowCap() public {
        (uint256 netForNineteenMillion,,) = CurveMath.netBaseForExactTokensOut(
            BabyNoxaConstants.INITIAL_VIRTUAL_BASE_RESERVE,
            BabyNoxaConstants.INITIAL_VIRTUAL_TOKEN_RESERVE,
            19_000_000 ether
        );

        vm.prank(creator);
        uint256 tokensOut = simulator.creatorInitialBuy(FeeMath.grossFromNet(netForNineteenMillion), 0);

        assertLe(tokensOut, BabyNoxaConstants.CREATOR_INITIAL_BUY_CAP);
        assertTrue(simulator.creatorInitialBuyExecuted());

        vm.expectRevert(BondingCurveSimulator.InitialBuyClosed.selector);
        vm.prank(creator);
        simulator.creatorInitialBuy(1 ether, 0);
    }

    function test_RevertWhenCreatorInitialBuyExceedsCap() public {
        vm.expectPartialRevert(BondingCurveSimulator.CreatorInitialBuyCapExceeded.selector);
        vm.prank(creator);
        simulator.creatorInitialBuy(1 ether, 0);
    }

    function test_PublicTradeClosesCreatorInitialBuyWindow() public {
        vm.prank(alice);
        simulator.buy(0.1 ether, 0);

        vm.expectRevert(BondingCurveSimulator.InitialBuyClosed.selector);
        vm.prank(creator);
        simulator.creatorInitialBuy(0.01 ether, 0);
    }

    function test_FinalBuyRefundsExcessAndGraduatesAtomically() public {
        vm.prank(alice);
        uint256 tokensOut = simulator.buy(10 ether, 0);

        assertEq(tokensOut, BabyNoxaConstants.CURVE_TOKEN_ALLOCATION);
        assertEq(uint256(simulator.state()), uint256(LaunchState.Graduated));
        assertEq(simulator.curveTokenInventory(), 0);
        assertEq(simulator.graduationTokenReserve(), 0);
        assertEq(simulator.realBaseReserve(), 0);
        assertEq(simulator.tokenBalanceOf(alice), BabyNoxaConstants.CURVE_TOKEN_ALLOCATION);
        assertGt(simulator.mockRefundOf(alice), 5 ether);
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
        uint256 aliceBought = simulator.buy(1 ether, 0);

        vm.prank(alice);
        simulator.sell(aliceBought / 2, 0);

        vm.prank(bob);
        simulator.buy(10 ether, 0);

        assertEq(uint256(simulator.state()), uint256(LaunchState.Graduated));
        assertGt(simulator.tokenBalanceOf(alice), 0);
        assertGt(simulator.tokenBalanceOf(bob), 0);
        assertGt(simulator.mockBaseCreditOf(alice), 0);
        assertGt(simulator.mockRefundOf(bob), 0);
        assertEq(simulator.accountedExecutedBase(), simulator.totalGrossBaseExecuted());
        assertEq(simulator.accountedTokenSupply(), BabyNoxaConstants.TOTAL_SUPPLY);
    }

    function test_GraduatedCurveRejectsFurtherTrading() public {
        vm.prank(alice);
        simulator.buy(10 ether, 0);

        vm.expectPartialRevert(BondingCurveSimulator.InvalidState.selector);
        vm.prank(bob);
        simulator.buy(1 ether, 0);

        vm.expectPartialRevert(BondingCurveSimulator.InvalidState.selector);
        vm.prank(alice);
        simulator.sell(1 ether, 0);
    }

    function test_RevertOnBuyAndSellSlippage() public {
        vm.expectPartialRevert(BondingCurveSimulator.TokenSlippageExceeded.selector);
        vm.prank(alice);
        simulator.buy(0.1 ether, BabyNoxaConstants.CURVE_TOKEN_ALLOCATION);

        vm.prank(alice);
        uint256 bought = simulator.buy(0.1 ether, 0);

        vm.expectPartialRevert(BondingCurveSimulator.BaseSlippageExceeded.selector);
        vm.prank(alice);
        simulator.sell(bought, 1 ether);
    }

    function testFuzz_BuyThenPartialSellPreservesAllAccounting(uint96 rawGrossBuy, uint96 rawSell) public {
        uint256 grossBuy = bound(uint256(rawGrossBuy), 0.001 ether, 1 ether);

        vm.prank(alice);
        uint256 bought = simulator.buy(grossBuy, 0);
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
