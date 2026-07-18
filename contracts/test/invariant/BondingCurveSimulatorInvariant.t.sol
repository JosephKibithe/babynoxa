// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {BabyNoxaConstants} from "../../src/libraries/BabyNoxaConstants.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";
import {FeeMath} from "../../src/libraries/FeeMath.sol";
import {BondingCurveSimulator} from "../../src/mocks/BondingCurveSimulator.sol";
import {LaunchState} from "../../src/types/BabyNoxaTypes.sol";

contract BondingCurveSimulatorHandler is Test {
    uint256 internal constant VALID_DEADLINE = type(uint256).max;
    uint256 internal constant ACTOR_COUNT = 4;

    BondingCurveSimulator public immutable simulator;
    address public immutable creator;
    address public immutable treasury;
    uint256 public immutable maximumCreatorGrossBuy;

    address[ACTOR_COUNT] public actors;

    uint256 public ghostEthSubmitted;
    uint256 public ghostEthExecuted;
    uint256 public ghostEthRefunded;
    uint256 public ghostSellCreditsCreated;
    uint256 public ghostRefundsWithdrawn;
    uint256 public ghostCreditsWithdrawn;
    uint256 public ghostExecutedBaseWithdrawn;
    uint256 public ghostTotalEthWithdrawn;

    uint256 public ghostCurveTokenInventory = BabyNoxaConstants.CURVE_TOKEN_ALLOCATION;
    uint256 public ghostTotalUserTokenBalances;
    uint256 public graduationCount;
    uint256 public successfulTradesAfterGraduation;

    mapping(address actor => uint256 balance) public ghostTokenBalanceOf;

    constructor(BondingCurveSimulator simulator_, address creator_, address treasury_, address[4] memory actors_) {
        simulator = simulator_;
        creator = creator_;
        treasury = treasury_;
        actors = actors_;

        (uint256 creatorNetBuy,,) = CurveMath.netBaseForExactTokensOut(
            BabyNoxaConstants.INITIAL_VIRTUAL_BASE_RESERVE,
            BabyNoxaConstants.INITIAL_VIRTUAL_TOKEN_RESERVE,
            19_000_000 ether
        );
        maximumCreatorGrossBuy = FeeMath.grossFromNet(creatorNetBuy);
    }

    function launchWithoutCreatorBuy() external {
        if (simulator.state() != LaunchState.Created) return;

        vm.prank(creator);
        try simulator.launch(0, VALID_DEADLINE) {} catch {}
    }

    function launchWithCreatorBuy(uint96 rawGrossBuy) external {
        if (simulator.state() != LaunchState.Created) return;

        uint256 grossBuy = bound(uint256(rawGrossBuy), BabyNoxaConstants.MIN_GROSS_TRADE_VALUE, maximumCreatorGrossBuy);
        uint256 executedBefore = simulator.totalGrossBaseExecuted();
        uint256 refundedBefore = simulator.totalGrossBaseRefunded();
        LaunchState stateBefore = simulator.state();

        vm.deal(creator, grossBuy);
        vm.prank(creator);
        try simulator.launch{value: grossBuy}(0, VALID_DEADLINE) returns (uint256 tokensOut) {
            _recordBuy(creator, grossBuy, tokensOut, executedBefore, refundedBefore, stateBefore);
        } catch {}
    }

    function buy(uint256 actorSeed, uint96 rawGrossBuy) external {
        address actor = _actor(actorSeed);
        uint256 grossBuy = bound(uint256(rawGrossBuy), BabyNoxaConstants.MIN_GROSS_TRADE_VALUE, 5 ether);
        uint256 executedBefore = simulator.totalGrossBaseExecuted();
        uint256 refundedBefore = simulator.totalGrossBaseRefunded();
        LaunchState stateBefore = simulator.state();

        vm.deal(actor, grossBuy);
        vm.prank(actor);
        try simulator.buy{value: grossBuy}(0, VALID_DEADLINE) returns (uint256 tokensOut) {
            if (stateBefore == LaunchState.Graduated) successfulTradesAfterGraduation++;
            _recordBuy(actor, grossBuy, tokensOut, executedBefore, refundedBefore, stateBefore);
        } catch {}
    }

    function sell(uint256 actorSeed, uint256 rawTokenAmount) external {
        address actor = _actor(actorSeed);
        uint256 balance = ghostTokenBalanceOf[actor];
        uint256 tokenAmount = balance == 0 ? 1 : bound(rawTokenAmount, 1, balance);
        LaunchState stateBefore = simulator.state();

        vm.prank(actor);
        try simulator.sell(tokenAmount, 0, VALID_DEADLINE) returns (uint256 netBaseCredit) {
            if (stateBefore == LaunchState.Graduated) successfulTradesAfterGraduation++;

            ghostTokenBalanceOf[actor] -= tokenAmount;
            ghostTotalUserTokenBalances -= tokenAmount;
            ghostCurveTokenInventory += tokenAmount;
            ghostSellCreditsCreated += netBaseCredit;
        } catch {}
    }

    function claimRefund(uint256 actorSeed, uint256 recipientSeed) external {
        address actor = _actor(actorSeed);
        address payable recipient = payable(_actor(recipientSeed));

        vm.prank(actor);
        try simulator.claimRefundTo(recipient) returns (uint256 amount) {
            ghostRefundsWithdrawn += amount;
            ghostTotalEthWithdrawn += amount;
        } catch {}
    }

    function claimBaseCredit(uint256 actorSeed, uint256 recipientSeed) external {
        address actor = _actor(actorSeed);
        address payable recipient = payable(_actor(recipientSeed));

        vm.prank(actor);
        try simulator.claimBaseCreditTo(recipient) returns (uint256 amount) {
            ghostCreditsWithdrawn += amount;
            ghostExecutedBaseWithdrawn += amount;
            ghostTotalEthWithdrawn += amount;
        } catch {}
    }

    function claimCreatorFees(uint256 recipientSeed) external {
        vm.prank(creator);
        try simulator.claimCreatorFeesTo(payable(_actor(recipientSeed))) returns (uint256 amount) {
            ghostExecutedBaseWithdrawn += amount;
            ghostTotalEthWithdrawn += amount;
        } catch {}
    }

    function claimTreasuryFees(uint256 recipientSeed) external {
        vm.prank(treasury);
        try simulator.claimTreasuryFeesTo(payable(_actor(recipientSeed))) returns (uint256 amount) {
            ghostExecutedBaseWithdrawn += amount;
            ghostTotalEthWithdrawn += amount;
        } catch {}
    }

    function actorAt(uint256 index) external view returns (address) {
        return actors[index];
    }

    function _recordBuy(
        address actor,
        uint256 grossBuy,
        uint256 tokensOut,
        uint256 executedBefore,
        uint256 refundedBefore,
        LaunchState stateBefore
    ) private {
        uint256 executed = simulator.totalGrossBaseExecuted() - executedBefore;
        uint256 refunded = simulator.totalGrossBaseRefunded() - refundedBefore;

        ghostEthSubmitted += grossBuy;
        ghostEthExecuted += executed;
        ghostEthRefunded += refunded;
        ghostTokenBalanceOf[actor] += tokensOut;
        ghostTotalUserTokenBalances += tokensOut;
        ghostCurveTokenInventory -= tokensOut;

        if (stateBefore != LaunchState.Graduated && simulator.state() == LaunchState.Graduated) {
            graduationCount++;
        }
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % ACTOR_COUNT];
    }
}

contract BondingCurveSimulatorInvariantTest is StdInvariant, Test {
    BondingCurveSimulator internal simulator;
    BondingCurveSimulatorHandler internal handler;
    address internal creator = makeAddr("invariantCreator");
    address internal treasury = makeAddr("invariantTreasury");
    address[4] internal actors;

    function setUp() public {
        actors[0] = creator;
        actors[1] = makeAddr("invariantAlice");
        actors[2] = makeAddr("invariantBob");
        actors[3] = makeAddr("invariantCarol");

        simulator = new BondingCurveSimulator(creator, treasury);
        handler = new BondingCurveSimulatorHandler(simulator, creator, treasury, actors);

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = BondingCurveSimulatorHandler.launchWithoutCreatorBuy.selector;
        selectors[1] = BondingCurveSimulatorHandler.launchWithCreatorBuy.selector;
        selectors[2] = BondingCurveSimulatorHandler.buy.selector;
        selectors[3] = BondingCurveSimulatorHandler.sell.selector;
        selectors[4] = BondingCurveSimulatorHandler.claimRefund.selector;
        selectors[5] = BondingCurveSimulatorHandler.claimBaseCredit.selector;
        selectors[6] = BondingCurveSimulatorHandler.claimCreatorFees.selector;
        selectors[7] = BondingCurveSimulatorHandler.claimTreasuryFees.selector;

        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_EthLiabilitiesNeverExceedAvailableEth() public view {
        assertGe(address(simulator).balance, simulator.accountedContractBalance());
        assertEq(simulator.accountedExecutedBase() + handler.ghostExecutedBaseWithdrawn(), handler.ghostEthExecuted());
        assertEq(simulator.totalOutstandingRefunds() + handler.ghostRefundsWithdrawn(), handler.ghostEthRefunded());
        assertEq(simulator.totalClaimableBase() + handler.ghostCreditsWithdrawn(), handler.ghostSellCreditsCreated());
        assertEq(address(simulator).balance + handler.ghostTotalEthWithdrawn(), handler.ghostEthSubmitted());
    }

    function invariant_SubmittedBaseAlwaysPartitionsIntoExecutionAndRefunds() public view {
        assertEq(
            simulator.totalGrossBaseSubmitted(), simulator.totalGrossBaseExecuted() + simulator.totalGrossBaseRefunded()
        );
        assertEq(handler.ghostEthSubmitted(), simulator.totalGrossBaseSubmitted());
        assertEq(handler.ghostEthExecuted(), simulator.totalGrossBaseExecuted());
        assertEq(handler.ghostEthRefunded(), simulator.totalGrossBaseRefunded());
        assertEq(handler.ghostEthSubmitted(), handler.ghostEthExecuted() + handler.ghostEthRefunded());
    }

    function invariant_AllOneBillionTokenUnitsRemainAccountedFor() public view {
        assertEq(simulator.accountedTokenSupply(), BabyNoxaConstants.TOTAL_SUPPLY);
        assertEq(handler.ghostTotalUserTokenBalances(), simulator.totalUserTokenBalances());
        assertEq(handler.ghostCurveTokenInventory(), simulator.curveTokenInventory());

        uint256 actorBalanceTotal;
        for (uint256 index; index < actors.length; index++) {
            address actor = actors[index];
            uint256 ghostBalance = handler.ghostTokenBalanceOf(actor);
            assertEq(ghostBalance, simulator.tokenBalanceOf(actor));
            actorBalanceTotal += ghostBalance;
        }
        assertEq(actorBalanceTotal, handler.ghostTotalUserTokenBalances());
        assertEq(
            handler.ghostTotalUserTokenBalances() + handler.ghostCurveTokenInventory()
                + simulator.graduationTokenReserve() + simulator.liquidityTokens() + simulator.burnedTokens(),
            BabyNoxaConstants.TOTAL_SUPPLY
        );
    }

    function invariant_CurveInventoryStaysWithinItsAllocation() public view {
        assertLe(simulator.curveTokenInventory(), BabyNoxaConstants.CURVE_TOKEN_ALLOCATION);
        assertLe(handler.ghostCurveTokenInventory(), BabyNoxaConstants.CURVE_TOKEN_ALLOCATION);
    }

    function invariant_GraduationOccursAtMostOnce() public view {
        assertLe(handler.graduationCount(), 1);
        if (simulator.state() == LaunchState.Graduated) assertEq(handler.graduationCount(), 1);
    }

    function invariant_NoTradeSucceedsAfterGraduation() public view {
        assertEq(handler.successfulTradesAfterGraduation(), 0);
    }
}
