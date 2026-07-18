// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {BabyNoxaToken} from "../../src/BabyNoxaToken.sol";
import {BondingCurve} from "../../src/BondingCurve.sol";
import {GraduationManagerV1} from "../../src/GraduationManagerV1.sol";
import {IGuardedV2Factory} from "../../src/interfaces/dex/IGuardedV2Factory.sol";
import {IGuardedV2Pair} from "../../src/interfaces/dex/IGuardedV2Pair.sol";
import {IV2Router02} from "../../src/interfaces/dex/IV2Router02.sol";
import {BabyNoxaConstants} from "../../src/libraries/BabyNoxaConstants.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";
import {DeadlinePolicy} from "../../src/libraries/DeadlinePolicy.sol";
import {FeeMath} from "../../src/libraries/FeeMath.sol";
import {TestWrappedNative} from "../../src/mocks/TestWrappedNative.sol";
import {GraduationParams, LaunchConfig, LaunchState} from "../../src/types/BabyNoxaTypes.sol";

contract Phase5LaunchFactoryHarness {
    IGuardedV2Factory public guardedFactory;
    GraduationManagerV1 public manager;
    address public wrappedNative;
    uint256 public launchCount;

    mapping(address curve => bool registered) internal registeredCurve;

    function bind(IGuardedV2Factory guardedFactory_, GraduationManagerV1 manager_, address wrappedNative_) external {
        require(address(guardedFactory) == address(0), "Phase5Factory: ALREADY_BOUND");
        guardedFactory = guardedFactory_;
        manager = manager_;
        wrappedNative = wrappedNative_;
    }

    function isRegisteredCurve(address curve) external view returns (bool) {
        return registeredCurve[curve];
    }

    function registerBoundaryCurve(address curve) external {
        registeredCurve[curve] = true;
    }

    function deployLaunch(address creator, address treasury, address pairBootstrapManager)
        external
        returns (BabyNoxaToken token, BondingCurve curve, IGuardedV2Pair pair)
    {
        token = new BabyNoxaToken("Phase 5 Production Token", "P5TOKEN", address(this));
        pair = IGuardedV2Pair(guardedFactory.createPair(address(token), wrappedNative, pairBootstrapManager));
        LaunchConfig memory config = LaunchConfig({
            launchId: ++launchCount,
            creator: creator,
            token: address(token),
            treasury: treasury,
            graduationManager: address(manager),
            officialPair: address(pair),
            initialVirtualBaseReserve: BabyNoxaConstants.INITIAL_VIRTUAL_BASE_RESERVE,
            initialVirtualTokenReserve: BabyNoxaConstants.INITIAL_VIRTUAL_TOKEN_RESERVE
        });
        curve = new BondingCurve(config, address(this));
        require(token.transfer(address(curve), token.totalSupply()), "Phase5Factory: FUNDING_FAILED");
        registeredCurve[address(curve)] = true;
        curve.launch(0, type(uint256).max);
    }
}

contract Phase5RegisteredCurveCaller {
    address public factory;
    address public token;
    address public graduationManager;
    address public officialPair;
    LaunchState public state = LaunchState.GraduationReady;
    uint256 public curveTokenInventory;
    uint256 public realBaseReserve;
    uint256 public graduationTokenReserve;
    uint256 public virtualBaseReserve;
    uint256 public virtualTokenReserve;

    constructor(
        address factory_,
        address token_,
        address graduationManager_,
        address officialPair_,
        uint256 virtualBaseReserve_,
        uint256 virtualTokenReserve_
    ) {
        factory = factory_;
        token = token_;
        graduationManager = graduationManager_;
        officialPair = officialPair_;
        virtualBaseReserve = virtualBaseReserve_;
        virtualTokenReserve = virtualTokenReserve_;
    }

    function callGraduate(GraduationParams calldata params) external payable returns (bool completed) {
        GraduationManagerV1(graduationManager).graduate{value: msg.value}(params);
        return true;
    }
}

contract GraduationManagerV1Test is Test {
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address internal creator = makeAddr("phase 5 creator");
    address internal treasury = makeAddr("phase 5 treasury");
    address internal alice = makeAddr("phase 5 alice");
    address internal bob = makeAddr("phase 5 bob");
    address internal attacker = makeAddr("phase 5 attacker");

    Phase5LaunchFactoryHarness internal launchFactory;
    IGuardedV2Factory internal v2Factory;
    IV2Router02 internal router;
    TestWrappedNative internal wrappedNative;
    GraduationManagerV1 internal manager;
    BabyNoxaToken internal token;
    BondingCurve internal curve;
    IGuardedV2Pair internal pair;

    function setUp() public {
        launchFactory = new Phase5LaunchFactoryHarness();
        wrappedNative = new TestWrappedNative();
        v2Factory = IGuardedV2Factory(
            vm.deployCode("GuardedV2Factory.sol:GuardedV2Factory", abi.encode(address(launchFactory)))
        );
        router = IV2Router02(
            vm.deployCode(
                "GuardedV2Router02.sol:GuardedV2Router02", abi.encode(address(v2Factory), address(wrappedNative))
            )
        );
        manager = new GraduationManagerV1(
            address(launchFactory), address(v2Factory), address(router), address(wrappedNative)
        );
        launchFactory.bind(v2Factory, manager, address(wrappedNative));
        (token, curve, pair) = launchFactory.deployLaunch(creator, treasury, address(manager));

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(address(this), 100 ether);
    }

    function test_RealCurveGraduatesIntoGuardedPairWithExactBurnsAndPriceContinuity() public {
        vm.warp(1_000);
        vm.recordLogs();
        vm.prank(alice);
        curve.buy{value: 10 ether}(0, block.timestamp);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(manager.factory(), address(launchFactory));
        assertEq(manager.v2Factory(), address(v2Factory));
        assertEq(manager.router(), address(router));
        assertEq(manager.wrappedNative(), address(wrappedNative));
        assertEq(manager.burnAddress(), DEAD);
        assertTrue(manager.graduatedCurve(address(curve)));
        assertEq(uint256(curve.state()), uint256(LaunchState.Graduated));
        assertFalse(pair.bootstrapLocked());
        assertEq(pair.bootstrapManager(), address(0));

        uint256 liquidityTokens = curve.graduatedLiquidityTokens();
        uint256 liquidityBase = curve.graduatedLiquidityBase();
        uint256 burnedTokens = curve.graduatedBurnedTokens();
        uint256 burnedLp = curve.graduatedBurnedLp();
        assertEq(liquidityTokens, 180_000_000_168_749_999_983_385_874);
        assertEq(liquidityTokens + burnedTokens, BabyNoxaConstants.GRADUATION_TOKEN_RESERVE);
        assertEq(token.totalSupply() + burnedTokens, BabyNoxaConstants.TOTAL_SUPPLY);
        assertEq(pair.balanceOf(DEAD), burnedLp);
        assertEq(pair.balanceOf(address(0)), pair.MINIMUM_LIQUIDITY());
        assertEq(pair.totalSupply(), burnedLp + pair.MINIMUM_LIQUIDITY());
        assertEq(pair.balanceOf(address(manager)), 0);
        assertEq(pair.balanceOf(address(curve)), 0);
        assertEq(pair.balanceOf(creator), 0);
        assertEq(pair.balanceOf(treasury), 0);
        assertEq(token.balanceOf(address(manager)), 0);
        assertEq(wrappedNative.balanceOf(address(manager)), 0);
        assertEq(token.allowance(address(manager), address(pair)), 0);
        assertEq(wrappedNative.allowance(address(manager), address(pair)), 0);
        assertEq(address(manager).balance, 0);
        _assertPairReserves(liquidityTokens, liquidityBase);
        _assertPriceContinuity();
        _assertManagerEvents(logs);

        FeeMath.GraduationFeeQuote memory expected = FeeMath.quoteGraduation(4_274_999_994_656_250_007);
        assertEq(expected.keeperReimbursement, 0);
        assertEq(curve.graduationTreasuryAllocation(), expected.treasuryAllocation);
        assertEq(liquidityBase, expected.liquidityBase);

        uint256 treasuryTradingFees = curve.treasuryTradingFees();
        uint256 treasuryBefore = treasury.balance;
        vm.prank(treasury);
        uint256 treasuryClaim = curve.claimTreasuryFees();
        assertEq(treasuryClaim - treasuryTradingFees, expected.treasuryAllocation);
        assertEq(treasury.balance, treasuryBefore + treasuryClaim);
    }

    function test_OnlyRegisteredCurveCanGraduateAndSuccessfulCurveCannotGraduateTwice() public {
        GraduationParams memory params = _terminalParams();

        vm.expectRevert(abi.encodeWithSelector(GraduationManagerV1.UnauthorizedCurve.selector, attacker));
        vm.prank(attacker);
        manager.graduate(params);

        vm.prank(alice);
        curve.buy{value: 10 ether}(0, type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(GraduationManagerV1.CurveAlreadyGraduated.selector, address(curve)));
        vm.prank(address(curve));
        manager.graduate(params);
    }

    function test_ManagerDeadlineAndLiquidityMinimumChecksPrecedeAssetMutation() public {
        GraduationParams memory params = _terminalParams();
        FeeMath.GraduationFeeQuote memory fee = FeeMath.quoteGraduation(params.realBaseReserve);
        Phase5RegisteredCurveCaller boundaryCaller = new Phase5RegisteredCurveCaller(
            address(launchFactory),
            address(token),
            address(manager),
            address(pair),
            params.terminalVirtualBaseReserve,
            params.terminalVirtualTokenReserve
        );
        launchFactory.registerBoundaryCurve(address(boundaryCaller));

        vm.warp(1_001);
        params.deadline = 1_000;
        vm.expectRevert(abi.encodeWithSelector(DeadlinePolicy.DeadlineExpired.selector, 1_000, 1_001));
        boundaryCaller.callGraduate(params);

        params.deadline = type(uint256).max;
        params.minimumBaseForLiquidity = fee.liquidityBase + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                GraduationManagerV1.LiquidityMinimumNotMet.selector, fee.liquidityBase + 1, fee.liquidityBase
            )
        );
        boundaryCaller.callGraduate{value: fee.liquidityBase}(params);

        assertFalse(manager.graduatedCurve(address(boundaryCaller)));
        assertTrue(pair.bootstrapLocked());
        assertEq(pair.totalSupply(), 0);
        assertEq(token.balanceOf(address(manager)), 0);
        assertEq(wrappedNative.balanceOf(address(manager)), 0);
    }

    function test_RegisteredCurveCannotGraduateBeforeItsLifecycleIsReady() public {
        GraduationParams memory params = _terminalParams();
        FeeMath.GraduationFeeQuote memory fee = FeeMath.quoteGraduation(params.realBaseReserve);
        vm.deal(address(curve), fee.liquidityBase);

        vm.expectRevert(GraduationManagerV1.InvalidCurveSnapshot.selector);
        vm.prank(address(curve));
        manager.graduate{value: fee.liquidityBase}(params);

        assertFalse(manager.graduatedCurve(address(curve)));
        assertEq(uint256(curve.state()), uint256(LaunchState.Trading));
        assertTrue(pair.bootstrapLocked());
        assertEq(pair.totalSupply(), 0);
    }

    function test_GraduatedPairImmediatelySupportsPermissionlessRouterSwaps() public {
        vm.prank(alice);
        curve.buy{value: 10 ether}(0, type(uint256).max);

        address[] memory path = new address[](2);
        path[0] = address(wrappedNative);
        path[1] = address(token);
        uint256 swapInput = 0.1 ether;
        uint256 expectedTokens = router.getAmountsOut(swapInput, path)[1];
        uint256 bobTokensBefore = token.balanceOf(bob);

        vm.prank(bob);
        uint256[] memory amounts =
            router.swapExactETHForTokens{value: swapInput}(expectedTokens, path, bob, type(uint256).max);

        assertEq(amounts[0], swapInput);
        assertEq(amounts[1], expectedTokens);
        assertEq(token.balanceOf(bob), bobTokensBefore + expectedTokens);
        assertFalse(pair.bootstrapLocked());
        assertEq(pair.bootstrapManager(), address(0));
    }

    function test_PairAndManagerDonationsAreClearedWithoutPoisoningOfficialReserves() public {
        vm.prank(alice);
        curve.buy{value: 1 ether}(0, type(uint256).max);

        uint256 tokenDonationToManager = 2 ether;
        uint256 tokenDonationToPair = 3 ether;
        vm.startPrank(alice);
        token.transfer(address(manager), tokenDonationToManager);
        token.transfer(address(pair), tokenDonationToPair);
        vm.stopPrank();

        uint256 baseDonationToManager = 700;
        uint256 baseDonationToPair = 900;
        wrappedNative.deposit{value: baseDonationToManager + baseDonationToPair}();
        wrappedNative.transfer(address(manager), baseDonationToManager);
        wrappedNative.transfer(address(pair), baseDonationToPair);

        vm.expectRevert(bytes("BabyNoxaV2: BOOTSTRAP_LOCKED"));
        vm.prank(attacker);
        pair.sync();
        vm.expectRevert(bytes("BabyNoxaV2: BOOTSTRAP_LOCKED"));
        vm.prank(attacker);
        pair.mint(attacker);

        uint256 deadTokensBefore = token.balanceOf(DEAD);
        uint256 deadBaseBefore = wrappedNative.balanceOf(DEAD);
        vm.prank(bob);
        curve.buy{value: 10 ether}(0, type(uint256).max);

        assertEq(token.balanceOf(DEAD), deadTokensBefore + tokenDonationToManager + tokenDonationToPair);
        assertEq(wrappedNative.balanceOf(DEAD), deadBaseBefore + baseDonationToManager + baseDonationToPair);
        assertEq(token.balanceOf(address(manager)), 0);
        assertEq(wrappedNative.balanceOf(address(manager)), 0);
        assertEq(token.balanceOf(address(pair)), curve.graduatedLiquidityTokens());
        assertEq(wrappedNative.balanceOf(address(pair)), curve.graduatedLiquidityBase());
        _assertPairReserves(curve.graduatedLiquidityTokens(), curve.graduatedLiquidityBase());
    }

    function test_InvalidBootstrapManagerRevertsEntireFinalPurchase() public {
        (BabyNoxaToken brokenToken, BondingCurve brokenCurve, IGuardedV2Pair brokenPair) =
            launchFactory.deployLaunch(creator, treasury, attacker);
        uint256 aliceBefore = alice.balance;

        vm.expectRevert(GraduationManagerV1.PairNotReady.selector);
        vm.prank(alice);
        brokenCurve.buy{value: 10 ether}(0, type(uint256).max);

        assertEq(alice.balance, aliceBefore);
        assertEq(uint256(brokenCurve.state()), uint256(LaunchState.Trading));
        assertEq(brokenCurve.curveTokenInventory(), BabyNoxaConstants.CURVE_TOKEN_ALLOCATION);
        assertEq(brokenCurve.realBaseReserve(), 0);
        assertEq(brokenCurve.creatorTradingFees(), 0);
        assertEq(brokenCurve.treasuryTradingFees(), 0);
        assertEq(brokenToken.balanceOf(address(brokenCurve)), BabyNoxaConstants.TOTAL_SUPPLY);
        assertEq(brokenToken.balanceOf(address(manager)), 0);
        assertEq(brokenToken.totalSupply(), BabyNoxaConstants.TOTAL_SUPPLY);
        assertFalse(manager.graduatedCurve(address(brokenCurve)));
        assertTrue(brokenPair.bootstrapLocked());
        assertEq(brokenPair.totalSupply(), 0);
        assertEq(brokenPair.balanceOf(DEAD), 0);
    }

    function _terminalParams() internal view returns (GraduationParams memory params) {
        (uint256 netReserve, uint256 terminalBase, uint256 terminalTokens) = CurveMath.netBaseForExactTokensOut(
            BabyNoxaConstants.INITIAL_VIRTUAL_BASE_RESERVE,
            BabyNoxaConstants.INITIAL_VIRTUAL_TOKEN_RESERVE,
            BabyNoxaConstants.CURVE_TOKEN_ALLOCATION
        );
        FeeMath.GraduationFeeQuote memory fee = FeeMath.quoteGraduation(netReserve);
        uint256 liquidityTokens = CurveMath.tokensForLiquidity(fee.liquidityBase, terminalBase, terminalTokens);
        params = GraduationParams({
            token: address(token),
            officialPair: address(pair),
            realBaseReserve: netReserve,
            terminalVirtualBaseReserve: terminalBase,
            terminalVirtualTokenReserve: terminalTokens,
            graduationTokenReserve: BabyNoxaConstants.GRADUATION_TOKEN_RESERVE,
            minimumBaseForLiquidity: fee.liquidityBase,
            minimumTokensForLiquidity: liquidityTokens,
            deadline: type(uint256).max
        });
    }

    function _assertPairReserves(uint256 expectedTokens, uint256 expectedBase) internal view {
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        if (pair.token0() == address(token)) {
            assertEq(reserve0, expectedTokens);
            assertEq(reserve1, expectedBase);
        } else {
            assertEq(reserve0, expectedBase);
            assertEq(reserve1, expectedTokens);
        }
    }

    function _assertPriceContinuity() internal view {
        uint256 terminalPrice = CurveMath.spotPrice(curve.virtualBaseReserve(), curve.virtualTokenReserve());
        uint256 poolPrice =
            Math.mulDiv(curve.graduatedLiquidityBase(), 1 ether, curve.graduatedLiquidityTokens(), Math.Rounding.Floor);
        uint256 absoluteDifference = terminalPrice >= poolPrice ? terminalPrice - poolPrice : poolPrice - terminalPrice;
        uint256 relativeDifferenceBps = Math.mulDiv(absoluteDifference, 10_000, terminalPrice, Math.Rounding.Ceil);
        assertLe(absoluteDifference, 1);
        assertLe(relativeDifferenceBps, 1);
    }

    function _assertManagerEvents(Vm.Log[] memory logs) internal view {
        bytes32 graduation = keccak256("GraduationExecuted(address,address,address,uint256,uint256,uint256,uint256)");
        bytes32 liquidityCreated = keccak256("LiquidityCreated(address,address,uint256,uint256,uint256)");
        bytes32 liquidityBurned = keccak256("LiquidityBurned(address,address,address,uint256)");
        bytes32 tokensBurned = keccak256("GraduationTokensBurned(address,address,uint256)");
        bool sawGraduation;
        bool sawLiquidityCreated;
        bool sawLiquidityBurned;
        bool sawTokensBurned;

        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(manager)) continue;
            bytes32 topic = logs[i].topics[0];
            if (topic == graduation) sawGraduation = true;
            if (topic == liquidityCreated) sawLiquidityCreated = true;
            if (topic == liquidityBurned) sawLiquidityBurned = true;
            if (topic == tokensBurned) sawTokensBurned = true;
        }
        assertTrue(sawGraduation);
        assertTrue(sawLiquidityCreated);
        assertTrue(sawLiquidityBurned);
        assertTrue(sawTokensBurned);
    }
}
