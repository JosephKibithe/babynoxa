// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {BabyNoxaToken} from "../../src/BabyNoxaToken.sol";
import {BondingCurve} from "../../src/BondingCurve.sol";
import {IBabyNoxaToken} from "../../src/interfaces/IBabyNoxaToken.sol";
import {IGraduationManager} from "../../src/interfaces/IGraduationManager.sol";
import {BabyNoxaConstants} from "../../src/libraries/BabyNoxaConstants.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";
import {FeeMath} from "../../src/libraries/FeeMath.sol";
import {GraduationParams, GraduationResult, LaunchConfig, LaunchState} from "../../src/types/BabyNoxaTypes.sol";

contract InvariantGraduationManager is IGraduationManager {
    address public override factory = address(this);
    address public override v2Factory = address(0x2001);
    address public override router = address(0x2002);
    address public override wrappedNative = address(0x2003);
    address public override burnAddress = 0x000000000000000000000000000000000000dEaD;
    uint256 public graduationCalls;

    function graduate(GraduationParams calldata params)
        external
        payable
        override
        returns (GraduationResult memory result)
    {
        graduationCalls++;
        FeeMath.GraduationFeeQuote memory fee = FeeMath.quoteGraduation(params.realBaseReserve);
        uint256 liquidityTokens = CurveMath.tokensForLiquidity(
            fee.liquidityBase, params.terminalVirtualBaseReserve, params.terminalVirtualTokenReserve
        );
        uint256 burnedTokens = params.graduationTokenReserve - liquidityTokens;
        require(msg.value == fee.liquidityBase, "InvariantManager: VALUE");

        IBabyNoxaToken(params.token).burn(burnedTokens);
        require(IERC20(params.token).transfer(params.officialPair, liquidityTokens), "InvariantManager: TRANSFER");

        result = GraduationResult({
            officialPair: params.officialPair,
            treasuryAllocation: fee.treasuryAllocation,
            liquidityBase: fee.liquidityBase,
            liquidityTokens: liquidityTokens,
            burnedTokens: burnedTokens,
            burnedLp: 1
        });
    }
}

contract InvariantCurveFactory {
    function deploy(address creator, address treasury, address manager, address pair)
        external
        returns (BabyNoxaToken token, BondingCurve curve)
    {
        token = new BabyNoxaToken("Invariant Token", "INVARIANT", address(this));
        LaunchConfig memory config = LaunchConfig({
            launchId: 1,
            creator: creator,
            token: address(token),
            treasury: treasury,
            graduationManager: manager,
            officialPair: pair,
            initialVirtualBaseReserve: BabyNoxaConstants.INITIAL_VIRTUAL_BASE_RESERVE,
            initialVirtualTokenReserve: BabyNoxaConstants.INITIAL_VIRTUAL_TOKEN_RESERVE
        });
        curve = new BondingCurve(config, address(this));
        require(token.transfer(address(curve), token.totalSupply()), "InvariantFactory: FUNDING");
    }

    function launch(BondingCurve curve) external {
        curve.launch(0, type(uint256).max);
    }
}

contract BondingCurveHandler is Test {
    BondingCurve public immutable curve;
    BabyNoxaToken public immutable token;
    address public immutable creator;
    address public immutable treasury;

    address[] internal actors;
    bool public tradeSucceededAfterGraduation;

    constructor(BondingCurve curve_, BabyNoxaToken token_, address creator_, address treasury_) {
        curve = curve_;
        token = token_;
        creator = creator_;
        treasury = treasury_;

        actors.push(makeAddr("production invariant alice"));
        actors.push(makeAddr("production invariant bob"));
        actors.push(makeAddr("production invariant carol"));
        actors.push(makeAddr("production invariant dave"));
        for (uint256 i; i < actors.length; ++i) {
            vm.deal(actors[i], 1_000_000 ether);
        }
    }

    function buy(uint256 actorSeed, uint256 grossSeed) external {
        address actor = _actor(actorSeed);
        uint256 gross = bound(grossSeed, BabyNoxaConstants.MIN_GROSS_TRADE_VALUE, 1 ether);
        LaunchState beforeState = curve.state();

        vm.prank(actor);
        (bool success,) = address(curve).call{value: gross}(abi.encodeCall(BondingCurve.buy, (0, type(uint256).max)));
        if (beforeState == LaunchState.Graduated && success) tradeSucceededAfterGraduation = true;
    }

    function sell(uint256 actorSeed, uint256 amountSeed) external {
        address actor = _actor(actorSeed);
        uint256 balance = token.balanceOf(actor);
        if (balance == 0) return;
        uint256 amount = bound(amountSeed, 1, balance);
        LaunchState beforeState = curve.state();

        vm.startPrank(actor);
        token.approve(address(curve), amount);
        (bool success,) = address(curve).call(abi.encodeCall(BondingCurve.sell, (amount, 0, type(uint256).max)));
        vm.stopPrank();
        if (beforeState == LaunchState.Graduated && success) tradeSucceededAfterGraduation = true;
    }

    function donateTokens(uint256 actorSeed, uint256 amountSeed) external {
        if (curve.state() != LaunchState.Trading) return;
        address actor = _actor(actorSeed);
        uint256 balance = token.balanceOf(actor);
        if (balance == 0) return;
        uint256 amount = bound(amountSeed, 1, balance);
        vm.prank(actor);
        token.transfer(address(curve), amount);
    }

    function claimUserFunds(uint256 actorSeed, bool refund) external {
        address actor = _actor(actorSeed);
        vm.prank(actor);
        if (refund) {
            (bool success,) = address(curve).call(abi.encodeCall(BondingCurve.claimRefund, ()));
            if (!success) return;
        } else {
            (bool success,) = address(curve).call(abi.encodeCall(BondingCurve.claimBaseCredit, ()));
            if (!success) return;
        }
    }

    function claimRoleFees(bool creatorClaim) external {
        if (creatorClaim) {
            vm.prank(creator);
            (bool success,) = address(curve).call(abi.encodeCall(BondingCurve.claimCreatorFees, ()));
            if (!success) return;
        } else {
            vm.prank(treasury);
            (bool success,) = address(curve).call(abi.encodeCall(BondingCurve.claimTreasuryFees, ()));
            if (!success) return;
        }
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }
}

contract BondingCurveInvariantTest is Test {
    address internal creator = makeAddr("production invariant creator");
    address internal treasury = makeAddr("production invariant treasury");
    address internal officialPair = makeAddr("production invariant pair");

    BondingCurve internal curve;
    BabyNoxaToken internal token;
    InvariantGraduationManager internal manager;
    BondingCurveHandler internal handler;

    function setUp() public {
        manager = new InvariantGraduationManager();
        InvariantCurveFactory factory = new InvariantCurveFactory();
        (token, curve) = factory.deploy(creator, treasury, address(manager), officialPair);
        factory.launch(curve);
        handler = new BondingCurveHandler(curve, token, creator, treasury);
        targetContract(address(handler));
    }

    function invariant_EthBucketsRemainSolventAndConserved() public view {
        assertGe(address(curve).balance, curve.accountedContractBalance());
        assertEq(curve.totalGrossBaseSubmitted(), curve.totalGrossBaseExecuted() + curve.totalGrossBaseRefunded());
        assertEq(curve.totalGrossBaseExecuted(), curve.accountedExecutedBase() + curve.totalExecutedBaseWithdrawn());
        assertEq(curve.totalGrossBaseRefunded(), curve.totalOutstandingRefunds() + curve.totalRefundBaseWithdrawn());
        assertEq(curve.totalCreatorFeesAccrued(), curve.creatorTradingFees() + curve.totalCreatorFeesClaimed());
        assertEq(
            curve.totalTreasuryFeesAccrued(),
            curve.treasuryTradingFees() + curve.graduationTreasuryAllocation() + curve.totalTreasuryFeesClaimed()
        );
        assertEq(curve.totalSellCreditsAccrued(), curve.totalClaimableBase() + curve.totalSellCreditsClaimed());
    }

    function invariant_RealTokenCustodyMatchesLifecycleBuckets() public view {
        assertLe(curve.curveTokenInventory(), BabyNoxaConstants.CURVE_TOKEN_ALLOCATION);
        if (curve.state() == LaunchState.Trading) {
            assertGe(token.balanceOf(address(curve)), curve.curveTokenInventory() + curve.graduationTokenReserve());
        } else if (curve.state() == LaunchState.Graduated) {
            assertEq(token.balanceOf(address(curve)), 0);
            assertEq(token.balanceOf(officialPair), curve.graduatedLiquidityTokens());
        }
        assertEq(curve.accountedTokenSupply(), BabyNoxaConstants.TOTAL_SUPPLY);
    }

    function invariant_GraduationOccursAtMostOnceAndPermanentlyClosesTrading() public view {
        assertLe(manager.graduationCalls(), 1);
        assertFalse(handler.tradeSucceededAfterGraduation());
        if (curve.state() == LaunchState.Graduated) {
            assertEq(curve.curveTokenInventory(), 0);
            assertEq(curve.graduationTokenReserve(), 0);
            assertEq(curve.realBaseReserve(), 0);
            assertEq(curve.graduatedLiquidityTokens() + curve.graduatedBurnedTokens(), 200_000_000 ether);
        }
    }
}
