// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {BabyNoxaFactory} from "../../src/BabyNoxaFactory.sol";
import {BabyNoxaLaunchDeployer} from "../../src/BabyNoxaLaunchDeployer.sol";
import {BabyNoxaToken} from "../../src/BabyNoxaToken.sol";
import {BondingCurve} from "../../src/BondingCurve.sol";
import {GraduationManagerV1} from "../../src/GraduationManagerV1.sol";
import {IGuardedV2Factory} from "../../src/interfaces/dex/IGuardedV2Factory.sol";
import {IGuardedV2Pair} from "../../src/interfaces/dex/IGuardedV2Pair.sol";
import {IV2Router02} from "../../src/interfaces/dex/IV2Router02.sol";
import {BabyNoxaConstants} from "../../src/libraries/BabyNoxaConstants.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";
import {FeeMath} from "../../src/libraries/FeeMath.sol";
import {TestWrappedNative} from "../../src/mocks/TestWrappedNative.sol";
import {CreateLaunchParams, LaunchRecord, LaunchState} from "../../src/types/BabyNoxaTypes.sol";

contract Phase9AcceptingRecipient {
    receive() external payable {}
}

contract Phase9RejectingRecipient {
    receive() external payable {
        revert("Phase9RejectingRecipient: REJECTED");
    }
}

contract Phase9ReentrantRecipient {
    BondingCurve internal target;
    bool internal refundClaim;
    bool internal entered;

    bool public claimReentrySucceeded;
    bool public tradeReentrySucceeded;

    function configure(BondingCurve target_, bool refundClaim_) external {
        target = target_;
        refundClaim = refundClaim_;
        entered = false;
        claimReentrySucceeded = false;
        tradeReentrySucceeded = false;
    }

    receive() external payable {
        if (entered) return;
        entered = true;

        bytes memory claimCall = refundClaim
            ? abi.encodeCall(BondingCurve.claimRefund, ())
            : abi.encodeCall(BondingCurve.claimBaseCredit, ());
        (claimReentrySucceeded,) = address(target).call(claimCall);

        if (address(this).balance >= BabyNoxaConstants.MIN_GROSS_TRADE_VALUE) {
            (tradeReentrySucceeded,) = address(target).call{value: BabyNoxaConstants.MIN_GROSS_TRADE_VALUE}(
                abi.encodeCall(BondingCurve.buy, (0, type(uint256).max))
            );
        }
    }
}

contract Phase9ForceEther {
    constructor(address payable recipient) payable {
        selfdestruct(recipient);
    }
}

contract FactoryLifecycleHandler is Test {
    uint256 internal constant MAX_LAUNCHES = 4;
    uint256 internal constant ACTOR_COUNT = 5;
    address internal constant LP_BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    struct TrackedLaunch {
        uint256 launchId;
        address creator;
        address token;
        address curve;
        address pair;
        address treasury;
        address manager;
        bytes32 metadataHash;
        bytes32 metadataUriHash;
        uint256 creatorInitialTokens;
    }

    struct GhostLaunch {
        uint256 supply;
        uint256 inventory;
        uint256 realReserve;
        uint256 creatorFees;
        uint256 treasuryFees;
        uint256 graduationTreasuryAllocation;
        uint256 sellCredits;
        uint256 refunds;
        uint256 protocolBurnedTokens;
        uint256 poolTokens;
        uint256 poolBase;
        uint256 burnedLp;
        uint256 previousVirtualProduct;
        uint256 graduationTransitions;
        uint256 forcedEther;
        LaunchState previousState;
        bool productDecreased;
        bool invalidSellSucceeded;
        bool postGraduationTradeSucceeded;
        bool reentrySucceeded;
    }

    BabyNoxaFactory public immutable factory;
    GraduationManagerV1 public immutable managerV1;
    GraduationManagerV1 public immutable managerV2;
    TestWrappedNative public immutable wrappedNative;
    address public immutable factoryOwner;
    address public immutable treasuryV1;
    address public immutable treasuryV2;

    Phase9AcceptingRecipient public immutable acceptingRecipient;
    Phase9RejectingRecipient public immutable rejectingRecipient;
    Phase9ReentrantRecipient public immutable reentrantRecipient;

    address[ACTOR_COUNT] public actors;
    TrackedLaunch[] internal trackedLaunches;
    GhostLaunch[] internal ghosts;
    uint256 internal metadataNonce;

    constructor(
        BabyNoxaFactory factory_,
        GraduationManagerV1 managerV1_,
        GraduationManagerV1 managerV2_,
        TestWrappedNative wrappedNative_,
        address factoryOwner_,
        address treasuryV1_,
        address treasuryV2_
    ) {
        factory = factory_;
        managerV1 = managerV1_;
        managerV2 = managerV2_;
        wrappedNative = wrappedNative_;
        factoryOwner = factoryOwner_;
        treasuryV1 = treasuryV1_;
        treasuryV2 = treasuryV2_;

        acceptingRecipient = new Phase9AcceptingRecipient();
        rejectingRecipient = new Phase9RejectingRecipient();
        reentrantRecipient = new Phase9ReentrantRecipient();

        actors[0] = makeAddr("phase9 creator one");
        actors[1] = makeAddr("phase9 creator two");
        actors[2] = makeAddr("phase9 alice");
        actors[3] = makeAddr("phase9 bob");
        actors[4] = makeAddr("phase9 carol");
        for (uint256 i; i < ACTOR_COUNT; ++i) {
            vm.deal(actors[i], 1_000_000 ether);
        }
        vm.deal(address(this), 1_000_000 ether);

        _createLaunch(0, false);
        _createLaunch(1, true);
    }

    function createLaunch(uint256 creatorSeed, bool withCreatorBuy) external {
        _createLaunch(creatorSeed, withCreatorBuy);
    }

    function rotateDefaults(uint256 seed) external {
        address nextManager = seed % 2 == 0 ? address(managerV1) : address(managerV2);
        address nextTreasury = seed % 2 == 0 ? treasuryV1 : treasuryV2;

        vm.startPrank(factoryOwner);
        factory.setActiveGraduationManager(nextManager);
        factory.setDefaultTreasury(nextTreasury);
        vm.stopPrank();
    }

    function approve(uint256 launchSeed, uint256 actorSeed, uint256 amountSeed) external {
        uint256 index = _launchIndex(launchSeed);
        if (index == type(uint256).max) return;
        TrackedLaunch memory tracked = trackedLaunches[index];
        address actor = _actor(actorSeed);
        uint256 balance = IERC20(tracked.token).balanceOf(actor);
        uint256 amount = balance == type(uint256).max ? amountSeed : amountSeed % (balance + 1);

        vm.prank(actor);
        IERC20(tracked.token).approve(tracked.curve, amount);
        _snapshot(index);
    }

    function buy(uint256 launchSeed, uint256 actorSeed, uint256 grossSeed) external {
        uint256 index = _launchIndex(launchSeed);
        if (index == type(uint256).max) return;
        TrackedLaunch memory tracked = trackedLaunches[index];
        BondingCurve curve = BondingCurve(payable(tracked.curve));
        address actor = _actor(actorSeed);
        uint256 gross = bound(grossSeed, BabyNoxaConstants.MIN_GROSS_TRADE_VALUE, 6 ether);
        LaunchState beforeState = curve.state();

        vm.prank(actor);
        (bool success,) = address(curve).call{value: gross}(abi.encodeCall(BondingCurve.buy, (0, type(uint256).max)));
        if (beforeState == LaunchState.Graduated && success) ghosts[index].postGraduationTradeSucceeded = true;
        _snapshot(index);
    }

    function finalBuy(uint256 launchSeed, uint256 actorSeed) external {
        uint256 index = _launchIndex(launchSeed);
        if (index == type(uint256).max) return;
        TrackedLaunch memory tracked = trackedLaunches[index];
        BondingCurve curve = BondingCurve(payable(tracked.curve));
        address actor = _actor(actorSeed);
        LaunchState beforeState = curve.state();

        vm.prank(actor);
        (bool success,) = address(curve).call{value: 10 ether}(abi.encodeCall(BondingCurve.buy, (0, type(uint256).max)));
        if (beforeState == LaunchState.Graduated && success) ghosts[index].postGraduationTradeSucceeded = true;
        _snapshot(index);
    }

    function sell(uint256 launchSeed, uint256 actorSeed, uint256 amountSeed) external {
        uint256 index = _launchIndex(launchSeed);
        if (index == type(uint256).max) return;
        TrackedLaunch memory tracked = trackedLaunches[index];
        BondingCurve curve = BondingCurve(payable(tracked.curve));
        address actor = _actor(actorSeed);
        uint256 balance = IERC20(tracked.token).balanceOf(actor);
        if (balance == 0) return;
        uint256 amount = bound(amountSeed, 1, balance);
        LaunchState beforeState = curve.state();

        vm.prank(actor);
        (bool success,) = address(curve).call(abi.encodeCall(BondingCurve.sell, (amount, 0, type(uint256).max)));
        if (beforeState == LaunchState.Graduated && success) ghosts[index].postGraduationTradeSucceeded = true;
        _snapshot(index);
    }

    function attemptInvalidSell(uint256 launchSeed, uint256 actorSeed, uint256 amountSeed, bool exceedBalance)
        external
    {
        uint256 index = _launchIndex(launchSeed);
        if (index == type(uint256).max) return;
        TrackedLaunch memory tracked = trackedLaunches[index];
        address actor = _actor(actorSeed);
        uint256 balance = IERC20(tracked.token).balanceOf(actor);
        uint256 amount;

        vm.startPrank(actor);
        if (exceedBalance || balance == 0) {
            amount = balance + 1;
            IERC20(tracked.token).approve(tracked.curve, amount);
        } else {
            amount = bound(amountSeed, 1, balance);
            IERC20(tracked.token).approve(tracked.curve, amount - 1);
        }
        (bool success,) = tracked.curve.call(abi.encodeCall(BondingCurve.sell, (amount, 0, type(uint256).max)));
        vm.stopPrank();

        if (success) ghosts[index].invalidSellSucceeded = true;
        _snapshot(index);
    }

    function claimUser(uint256 launchSeed, uint256 actorSeed, uint256 recipientSeed, bool refund) external {
        uint256 index = _launchIndex(launchSeed);
        if (index == type(uint256).max) return;
        TrackedLaunch memory tracked = trackedLaunches[index];
        BondingCurve curve = BondingCurve(payable(tracked.curve));
        address actor = _actor(actorSeed);
        address payable recipient = _recipient(recipientSeed, curve, refund);
        bytes memory claimCall = refund
            ? abi.encodeCall(BondingCurve.claimRefundTo, (recipient))
            : abi.encodeCall(BondingCurve.claimBaseCreditTo, (recipient));

        vm.prank(actor);
        (bool claimSucceeded,) = address(curve).call(claimCall);
        claimSucceeded;
        _captureReentryResult(index, recipient);
        _snapshot(index);
    }

    function claimRole(uint256 launchSeed, uint256 recipientSeed, bool creatorClaim) external {
        uint256 index = _launchIndex(launchSeed);
        if (index == type(uint256).max) return;
        TrackedLaunch memory tracked = trackedLaunches[index];
        BondingCurve curve = BondingCurve(payable(tracked.curve));
        address claimant = creatorClaim ? tracked.creator : tracked.treasury;
        address payable recipient = _recipient(recipientSeed, curve, false);
        bytes memory claimCall = creatorClaim
            ? abi.encodeCall(BondingCurve.claimCreatorFeesTo, (recipient))
            : abi.encodeCall(BondingCurve.claimTreasuryFeesTo, (recipient));

        vm.prank(claimant);
        (bool claimSucceeded,) = address(curve).call(claimCall);
        claimSucceeded;
        _captureReentryResult(index, recipient);
        _snapshot(index);
    }

    function forceEther(uint256 launchSeed, uint256 amountSeed) external {
        uint256 index = _launchIndex(launchSeed);
        if (index == type(uint256).max) return;
        uint256 amount = bound(amountSeed, 1, 0.1 ether);
        new Phase9ForceEther{value: amount}(payable(trackedLaunches[index].curve));
        ghosts[index].forcedEther += amount;
        _snapshot(index);
    }

    function donateTokens(uint256 launchSeed, uint256 actorSeed, uint256 amountSeed, uint256 destinationSeed) external {
        uint256 index = _launchIndex(launchSeed);
        if (index == type(uint256).max) return;
        TrackedLaunch memory tracked = trackedLaunches[index];
        if (BondingCurve(payable(tracked.curve)).state() != LaunchState.Trading) return;
        address actor = _actor(actorSeed);
        uint256 balance = IERC20(tracked.token).balanceOf(actor);
        if (balance == 0) return;
        uint256 amount = bound(amountSeed, 1, balance);
        address destination;
        if (destinationSeed % 3 == 0) destination = tracked.curve;
        else if (destinationSeed % 3 == 1) destination = tracked.manager;
        else destination = tracked.pair;

        vm.prank(actor);
        IERC20(tracked.token).transfer(destination, amount);
        _snapshot(index);
    }

    function launchesLength() external view returns (uint256) {
        return trackedLaunches.length;
    }

    function trackedAt(uint256 index) external view returns (TrackedLaunch memory) {
        return trackedLaunches[index];
    }

    function ghostAt(uint256 index) external view returns (GhostLaunch memory) {
        return ghosts[index];
    }

    function actorAt(uint256 index) external view returns (address) {
        return actors[index];
    }

    function _createLaunch(uint256 creatorSeed, bool withCreatorBuy) private {
        if (trackedLaunches.length >= MAX_LAUNCHES) return;
        address creator = _actor(creatorSeed);
        uint256 serial = ++metadataNonce;
        string memory metadataURI = string.concat("ipfs://phase9/", vm.toString(serial));
        bytes32 metadataHash = keccak256(abi.encodePacked("phase9 metadata", serial));
        uint256 creatorGross;
        uint256 minimumCreatorTokensOut;

        if (withCreatorBuy) {
            minimumCreatorTokensOut =
                bound(uint256(keccak256(abi.encode(creatorSeed, serial))), 1_000_000 ether, 19_000_000 ether);
            (uint256 requiredNet,,) = CurveMath.netBaseForExactTokensOut(
                BabyNoxaConstants.INITIAL_VIRTUAL_BASE_RESERVE,
                BabyNoxaConstants.INITIAL_VIRTUAL_TOKEN_RESERVE,
                minimumCreatorTokensOut
            );
            creatorGross = FeeMath.grossFromNet(requiredNet);
        }

        CreateLaunchParams memory params = CreateLaunchParams({
            name: "Phase 9 Token",
            symbol: "P9",
            metadataURI: metadataURI,
            metadataHash: metadataHash,
            minimumCreatorTokensOut: minimumCreatorTokensOut,
            deadline: type(uint256).max
        });

        vm.prank(creator);
        try factory.createLaunch{value: creatorGross}(params) returns (LaunchRecord memory record) {
            uint256 initialTokens = IERC20(record.token).balanceOf(creator);
            trackedLaunches.push(
                TrackedLaunch({
                    launchId: record.launchId,
                    creator: record.creator,
                    token: record.token,
                    curve: record.curve,
                    pair: record.officialPair,
                    treasury: record.treasury,
                    manager: record.graduationManager,
                    metadataHash: record.metadataHash,
                    metadataUriHash: keccak256(bytes(record.metadataURI)),
                    creatorInitialTokens: initialTokens
                })
            );
            ghosts.push();
            _snapshot(trackedLaunches.length - 1);
        } catch {}
    }

    function _snapshot(uint256 index) private {
        TrackedLaunch memory tracked = trackedLaunches[index];
        GhostLaunch storage ghost = ghosts[index];
        BondingCurve curve = BondingCurve(payable(tracked.curve));
        IGuardedV2Pair pair = IGuardedV2Pair(tracked.pair);

        LaunchState currentState = curve.state();
        uint256 product = curve.virtualBaseReserve() * curve.virtualTokenReserve();
        if (ghost.previousVirtualProduct != 0 && product < ghost.previousVirtualProduct) {
            ghost.productDecreased = true;
        }
        if (ghost.previousState != LaunchState.Graduated && currentState == LaunchState.Graduated) {
            ghost.graduationTransitions++;
        }

        ghost.supply = IERC20(tracked.token).totalSupply();
        ghost.inventory = curve.curveTokenInventory();
        ghost.realReserve = curve.realBaseReserve();
        ghost.creatorFees = curve.creatorTradingFees();
        ghost.treasuryFees = curve.treasuryTradingFees();
        ghost.graduationTreasuryAllocation = curve.graduationTreasuryAllocation();
        ghost.sellCredits = curve.totalClaimableBase();
        ghost.refunds = curve.totalOutstandingRefunds();
        ghost.protocolBurnedTokens = curve.graduatedBurnedTokens() + curve.unsolicitedTokenBurned();
        ghost.poolTokens = IERC20(tracked.token).balanceOf(tracked.pair);
        ghost.poolBase = wrappedNative.balanceOf(tracked.pair);
        ghost.burnedLp = pair.balanceOf(LP_BURN_ADDRESS);
        ghost.previousVirtualProduct = product;
        ghost.previousState = currentState;
    }

    function _captureReentryResult(uint256 index, address recipient) private {
        if (recipient != address(reentrantRecipient)) return;
        if (reentrantRecipient.claimReentrySucceeded() || reentrantRecipient.tradeReentrySucceeded()) {
            ghosts[index].reentrySucceeded = true;
        }
    }

    function _recipient(uint256 seed, BondingCurve curve, bool refund) private returns (address payable recipient) {
        uint256 kind = seed % 4;
        if (kind == 0) return payable(_actor(seed));
        if (kind == 1) return payable(address(acceptingRecipient));
        if (kind == 2) return payable(address(rejectingRecipient));
        reentrantRecipient.configure(curve, refund);
        return payable(address(reentrantRecipient));
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % ACTOR_COUNT];
    }

    function _launchIndex(uint256 seed) private view returns (uint256) {
        uint256 length = trackedLaunches.length;
        return length == 0 ? type(uint256).max : seed % length;
    }
}

contract FactoryLifecycleInvariantTest is StdInvariant, Test {
    address internal constant LP_BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    address internal owner = makeAddr("phase9 owner");
    address internal treasuryV1 = makeAddr("phase9 treasury v1");
    address internal treasuryV2 = makeAddr("phase9 treasury v2");

    TestWrappedNative internal wrappedNative;
    IGuardedV2Factory internal v2Factory;
    IV2Router02 internal router;
    BabyNoxaFactory internal factory;
    GraduationManagerV1 internal managerV1;
    GraduationManagerV1 internal managerV2;
    FactoryLifecycleHandler internal handler;

    function setUp() public {
        wrappedNative = new TestWrappedNative();
        address predictedFactory = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        v2Factory =
            IGuardedV2Factory(vm.deployCode("GuardedV2Factory.sol:GuardedV2Factory", abi.encode(predictedFactory)));
        router = IV2Router02(
            vm.deployCode(
                "GuardedV2Router02.sol:GuardedV2Router02", abi.encode(address(v2Factory), address(wrappedNative))
            )
        );
        factory = new BabyNoxaFactory(
            owner,
            treasuryV1,
            address(v2Factory),
            address(wrappedNative),
            BabyNoxaConstants.INITIAL_VIRTUAL_BASE_RESERVE,
            BabyNoxaConstants.INITIAL_VIRTUAL_TOKEN_RESERVE
        );
        assertEq(address(factory), predictedFactory);

        managerV1 =
            new GraduationManagerV1(address(factory), address(v2Factory), address(router), address(wrappedNative));
        managerV2 =
            new GraduationManagerV1(address(factory), address(v2Factory), address(router), address(wrappedNative));
        vm.prank(owner);
        factory.setActiveGraduationManager(address(managerV1));

        handler =
            new FactoryLifecycleHandler(factory, managerV1, managerV2, wrappedNative, owner, treasuryV1, treasuryV2);

        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = FactoryLifecycleHandler.createLaunch.selector;
        selectors[1] = FactoryLifecycleHandler.rotateDefaults.selector;
        selectors[2] = FactoryLifecycleHandler.approve.selector;
        selectors[3] = FactoryLifecycleHandler.buy.selector;
        selectors[4] = FactoryLifecycleHandler.finalBuy.selector;
        selectors[5] = FactoryLifecycleHandler.sell.selector;
        selectors[6] = FactoryLifecycleHandler.attemptInvalidSell.selector;
        selectors[7] = FactoryLifecycleHandler.claimUser.selector;
        selectors[8] = FactoryLifecycleHandler.claimRole.selector;
        selectors[9] = FactoryLifecycleHandler.forceEther.selector;
        selectors[10] = FactoryLifecycleHandler.donateTokens.selector;

        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_RegistryMetadataAndLaunchSnapshotsRemainImmutable() public view {
        uint256 length = handler.launchesLength();
        assertEq(factory.launchCount(), length);
        for (uint256 i; i < length; ++i) {
            FactoryLifecycleHandler.TrackedLaunch memory tracked = handler.trackedAt(i);
            LaunchRecord memory record = factory.getLaunch(tracked.launchId);
            BondingCurve curve = BondingCurve(payable(tracked.curve));

            assertEq(record.launchId, tracked.launchId);
            assertEq(record.creator, tracked.creator);
            assertEq(record.token, tracked.token);
            assertEq(record.curve, tracked.curve);
            assertEq(record.officialPair, tracked.pair);
            assertEq(record.treasury, tracked.treasury);
            assertEq(record.graduationManager, tracked.manager);
            assertEq(record.metadataHash, tracked.metadataHash);
            assertEq(keccak256(bytes(record.metadataURI)), tracked.metadataUriHash);
            assertEq(factory.launchIdOfToken(tracked.token), tracked.launchId);
            assertEq(factory.launchIdOfCurve(tracked.curve), tracked.launchId);
            assertEq(factory.launchIdOfMetadataHash(tracked.metadataHash), tracked.launchId);
            assertTrue(factory.isRegisteredCurve(tracked.curve));
            assertEq(curve.factory(), address(factory));
            assertEq(curve.creator(), tracked.creator);
            assertEq(curve.treasury(), tracked.treasury);
            assertEq(curve.graduationManager(), tracked.manager);
            assertEq(curve.officialPair(), tracked.pair);
            assertLe(tracked.creatorInitialTokens, BabyNoxaConstants.CREATOR_INITIAL_BUY_CAP);
            assertEq(IERC20(tracked.token).balanceOf(address(factory)), 0);
            assertEq(IERC20(tracked.token).balanceOf(address(factory.launchDeployer())), 0);
        }
    }

    function invariant_SupplyInventoryAndGhostAccountingRemainExact() public view {
        uint256 length = handler.launchesLength();
        for (uint256 i; i < length; ++i) {
            FactoryLifecycleHandler.TrackedLaunch memory tracked = handler.trackedAt(i);
            FactoryLifecycleHandler.GhostLaunch memory ghost = handler.ghostAt(i);
            BondingCurve curve = BondingCurve(payable(tracked.curve));
            IERC20 token = IERC20(tracked.token);

            assertEq(token.totalSupply(), ghost.supply);
            assertEq(curve.curveTokenInventory(), ghost.inventory);
            assertEq(curve.realBaseReserve(), ghost.realReserve);
            assertEq(curve.creatorTradingFees(), ghost.creatorFees);
            assertEq(curve.treasuryTradingFees(), ghost.treasuryFees);
            assertEq(curve.graduationTreasuryAllocation(), ghost.graduationTreasuryAllocation);
            assertEq(curve.totalClaimableBase(), ghost.sellCredits);
            assertEq(curve.totalOutstandingRefunds(), ghost.refunds);
            assertEq(curve.graduatedBurnedTokens() + curve.unsolicitedTokenBurned(), ghost.protocolBurnedTokens);
            assertEq(token.balanceOf(tracked.pair), ghost.poolTokens);
            assertEq(wrappedNative.balanceOf(tracked.pair), ghost.poolBase);
            assertEq(IGuardedV2Pair(tracked.pair).balanceOf(LP_BURN_ADDRESS), ghost.burnedLp);
            assertEq(curve.accountedTokenSupply(), BabyNoxaConstants.TOTAL_SUPPLY);
            assertEq(token.totalSupply() + ghost.protocolBurnedTokens, BabyNoxaConstants.TOTAL_SUPPLY);
            assertLe(curve.curveTokenInventory(), BabyNoxaConstants.CURVE_TOKEN_ALLOCATION);

            uint256 knownBalances = token.balanceOf(tracked.curve) + token.balanceOf(tracked.pair)
                + token.balanceOf(address(managerV1)) + token.balanceOf(address(managerV2))
                + token.balanceOf(LP_BURN_ADDRESS) + token.balanceOf(address(factory))
                + token.balanceOf(address(factory.launchDeployer()));
            for (uint256 actorIndex; actorIndex < 5; ++actorIndex) {
                knownBalances += token.balanceOf(handler.actorAt(actorIndex));
            }
            assertEq(knownBalances, token.totalSupply());

            if (curve.state() == LaunchState.Trading) {
                assertGe(token.balanceOf(tracked.curve), curve.curveTokenInventory() + curve.graduationTokenReserve());
            } else if (curve.state() == LaunchState.Graduated) {
                assertEq(token.balanceOf(tracked.curve), 0);
                assertEq(curve.curveTokenInventory(), 0);
                assertEq(curve.graduationTokenReserve(), 0);
            }
        }
    }

    function invariant_BaseReservesFeesAndLiabilitiesRemainSolvent() public view {
        uint256 length = handler.launchesLength();
        for (uint256 i; i < length; ++i) {
            FactoryLifecycleHandler.TrackedLaunch memory tracked = handler.trackedAt(i);
            FactoryLifecycleHandler.GhostLaunch memory ghost = handler.ghostAt(i);
            BondingCurve curve = BondingCurve(payable(tracked.curve));

            assertGe(address(curve).balance, curve.accountedContractBalance());
            assertEq(address(curve).balance - curve.accountedContractBalance(), ghost.forcedEther);
            assertEq(curve.totalGrossBaseSubmitted(), curve.totalGrossBaseExecuted() + curve.totalGrossBaseRefunded());
            assertEq(curve.totalGrossBaseExecuted(), curve.accountedExecutedBase() + curve.totalExecutedBaseWithdrawn());
            assertEq(curve.totalGrossBaseRefunded(), curve.totalOutstandingRefunds() + curve.totalRefundBaseWithdrawn());
            assertEq(curve.totalSellCreditsAccrued(), curve.totalClaimableBase() + curve.totalSellCreditsClaimed());
            assertEq(curve.totalCreatorFeesAccrued(), curve.creatorTradingFees() + curve.totalCreatorFeesClaimed());
            assertEq(
                curve.totalTreasuryFeesAccrued(),
                curve.treasuryTradingFees() + curve.graduationTreasuryAllocation() + curve.totalTreasuryFeesClaimed()
            );
            assertEq(
                curve.accountedExecutedBase(),
                curve.realBaseReserve() + curve.creatorTradingFees() + curve.treasuryTradingFees()
                    + curve.graduationTreasuryAllocation() + curve.totalClaimableBase()
            );
            assertEq(FeeMath.quoteGraduation(1).keeperReimbursement, 0);
            assertFalse(ghost.productDecreased);
            assertFalse(ghost.invalidSellSucceeded);
            assertFalse(ghost.reentrySucceeded);
        }
    }

    function invariant_GraduationIsAtomicPermanentAndBurnsEveryUsableLpToken() public view {
        uint256 length = handler.launchesLength();
        for (uint256 i; i < length; ++i) {
            FactoryLifecycleHandler.TrackedLaunch memory tracked = handler.trackedAt(i);
            FactoryLifecycleHandler.GhostLaunch memory ghost = handler.ghostAt(i);
            BondingCurve curve = BondingCurve(payable(tracked.curve));
            IGuardedV2Pair pair = IGuardedV2Pair(tracked.pair);

            assertLe(ghost.graduationTransitions, 1);
            assertFalse(ghost.postGraduationTradeSucceeded);
            if (curve.state() == LaunchState.Graduated) {
                assertEq(ghost.graduationTransitions, 1);
                assertTrue(GraduationManagerV1(tracked.manager).graduatedCurve(tracked.curve));
                assertFalse(pair.bootstrapLocked());
                assertEq(pair.bootstrapManager(), address(0));
                assertEq(curve.realBaseReserve(), 0);
                assertEq(curve.graduatedLiquidityTokens() + curve.graduatedBurnedTokens(), 200_000_000 ether);

                (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
                uint256 poolTokens = pair.token0() == tracked.token ? reserve0 : reserve1;
                uint256 poolBase = pair.token0() == tracked.token ? reserve1 : reserve0;
                assertEq(poolTokens, curve.graduatedLiquidityTokens());
                assertEq(poolBase, curve.graduatedLiquidityBase());
                assertEq(IERC20(tracked.token).balanceOf(tracked.pair), poolTokens);
                assertEq(wrappedNative.balanceOf(tracked.pair), poolBase);

                uint256 minimumLiquidity = pair.MINIMUM_LIQUIDITY();
                assertEq(pair.balanceOf(LP_BURN_ADDRESS), curve.graduatedBurnedLp());
                assertEq(pair.balanceOf(address(0)), minimumLiquidity);
                assertEq(pair.totalSupply(), curve.graduatedBurnedLp() + minimumLiquidity);
                assertEq(pair.balanceOf(tracked.treasury), 0);
                assertEq(pair.balanceOf(tracked.creator), 0);
                assertEq(pair.balanceOf(tracked.curve), 0);
                assertEq(pair.balanceOf(tracked.manager), 0);

                uint256 terminalPrice = CurveMath.spotPrice(curve.virtualBaseReserve(), curve.virtualTokenReserve());
                uint256 poolPrice = Math.mulDiv(poolBase, 1 ether, poolTokens, Math.Rounding.Floor);
                uint256 difference = terminalPrice >= poolPrice ? terminalPrice - poolPrice : poolPrice - terminalPrice;
                assertLe(difference, BabyNoxaConstants.MAX_PRICE_DIFFERENCE_WEI_PER_TOKEN);
            } else {
                assertEq(ghost.graduationTransitions, 0);
                assertTrue(pair.bootstrapLocked());
                assertEq(pair.bootstrapManager(), tracked.manager);
                assertEq(pair.totalSupply(), 0);
                assertFalse(GraduationManagerV1(tracked.manager).graduatedCurve(tracked.curve));
            }
        }
    }
}
