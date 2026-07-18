// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {BabyNoxaFactory} from "../../src/BabyNoxaFactory.sol";
import {BabyNoxaLaunchDeployer} from "../../src/BabyNoxaLaunchDeployer.sol";
import {BabyNoxaToken} from "../../src/BabyNoxaToken.sol";
import {BondingCurve} from "../../src/BondingCurve.sol";
import {GraduationManagerV1} from "../../src/GraduationManagerV1.sol";
import {IGraduationManager} from "../../src/interfaces/IGraduationManager.sol";
import {IGuardedV2Factory} from "../../src/interfaces/dex/IGuardedV2Factory.sol";
import {IGuardedV2Pair} from "../../src/interfaces/dex/IGuardedV2Pair.sol";
import {IV2Router02} from "../../src/interfaces/dex/IV2Router02.sol";
import {BabyNoxaConstants} from "../../src/libraries/BabyNoxaConstants.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";
import {DeadlinePolicy} from "../../src/libraries/DeadlinePolicy.sol";
import {FeeMath} from "../../src/libraries/FeeMath.sol";
import {TestWrappedNative} from "../../src/mocks/TestWrappedNative.sol";
import {
    CreateLaunchParams,
    GraduationParams,
    GraduationResult,
    LaunchRecord,
    LaunchState
} from "../../src/types/BabyNoxaTypes.sol";

contract Phase8MockGuardedPair {
    address public factory;
    address public token0;
    address public token1;
    address public bootstrapManager;
    bool public bootstrapLocked = true;

    constructor(address factory_, address token0_, address token1_, address manager_) {
        factory = factory_;
        token0 = token0_;
        token1 = token1_;
        bootstrapManager = manager_;
    }

    function totalSupply() external pure returns (uint256) {
        return 0;
    }

    function getReserves() external pure returns (uint112 reserve0, uint112 reserve1, uint32 timestamp) {
        return (0, 0, 0);
    }
}

contract Phase8ReentrantV2Factory {
    address public launchFactory;
    address public feeTo;
    address public feeToSetter;
    uint256 public allPairsLength;
    bool public reentryAttempted;
    bool public reentrySucceeded;

    mapping(address tokenA => mapping(address tokenB => address pair)) public getPair;

    constructor(address launchFactory_) {
        launchFactory = launchFactory_;
    }

    function createPair(address, address) external pure returns (address pair) {
        pair;
        revert("Phase8ReentrantV2: MANAGER_REQUIRED");
    }

    function createPair(address tokenA, address tokenB, address manager) external returns (address pair) {
        require(msg.sender == launchFactory, "Phase8ReentrantV2: NOT_FACTORY");
        reentryAttempted = true;
        CreateLaunchParams memory params = CreateLaunchParams({
            name: "Reentrant",
            symbol: "REENTER",
            metadataURI: "ipfs://reentrant",
            metadataHash: keccak256("reentrant metadata"),
            minimumCreatorTokensOut: 0,
            deadline: type(uint256).max
        });
        (reentrySucceeded,) = launchFactory.call(abi.encodeCall(BabyNoxaFactory.createLaunch, (params)));

        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        pair = address(new Phase8MockGuardedPair(address(this), token0, token1, manager));
        getPair[tokenA][tokenB] = pair;
        getPair[tokenB][tokenA] = pair;
        allPairsLength++;
    }
}

contract Phase8ManagerConfigurationHarness is IGraduationManager {
    address public override factory;
    address public override v2Factory;
    address public override router;
    address public override wrappedNative;
    address public override burnAddress = 0x000000000000000000000000000000000000dEaD;

    constructor(address factory_, address v2Factory_, address router_, address wrappedNative_) {
        factory = factory_;
        v2Factory = v2Factory_;
        router = router_;
        wrappedNative = wrappedNative_;
    }

    function graduate(GraduationParams calldata) external payable override returns (GraduationResult memory) {
        revert("Phase8Manager: NOT_USED");
    }
}

    contract BabyNoxaFactoryTest is Test {
        address internal owner = makeAddr("phase 8 owner");
        address internal treasury = makeAddr("phase 8 treasury");
        address internal alice = makeAddr("phase 8 alice");
        address internal bob = makeAddr("phase 8 bob");
        address internal attacker = makeAddr("phase 8 attacker");

        TestWrappedNative internal wrappedNative;
        IGuardedV2Factory internal v2Factory;
        IV2Router02 internal router;
        BabyNoxaFactory internal factory;
        GraduationManagerV1 internal managerV1;

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
                treasury,
                address(v2Factory),
                address(wrappedNative),
                BabyNoxaConstants.INITIAL_VIRTUAL_BASE_RESERVE,
                BabyNoxaConstants.INITIAL_VIRTUAL_TOKEN_RESERVE
            );
            assertEq(address(factory), predictedFactory);

            managerV1 =
                new GraduationManagerV1(address(factory), address(v2Factory), address(router), address(wrappedNative));
            vm.prank(owner);
            factory.setActiveGraduationManager(address(managerV1));

            vm.deal(alice, 100 ether);
            vm.deal(bob, 100 ether);
            vm.deal(attacker, 100 ether);
        }

        function test_CreateLaunchWithoutCreatorBuyRegistersAndAssignsEntireSupply() public {
            CreateLaunchParams memory params = _params("First Token", "FIRST", keccak256("first metadata"));
            vm.recordLogs();
            vm.prank(alice);
            LaunchRecord memory record = factory.createLaunch(params);
            Vm.Log[] memory logs = vm.getRecordedLogs();

            BabyNoxaToken token = BabyNoxaToken(record.token);
            BondingCurve curve = BondingCurve(record.curve);
            IGuardedV2Pair pair = IGuardedV2Pair(record.officialPair);
            assertEq(record.launchId, 1);
            assertEq(record.creator, alice);
            assertEq(record.treasury, treasury);
            assertEq(record.graduationManager, address(managerV1));
            assertEq(record.metadataHash, params.metadataHash);
            assertEq(record.metadataURI, params.metadataURI);
            assertEq(factory.launchCount(), 1);
            assertEq(factory.launchIdOfToken(record.token), 1);
            assertEq(factory.launchIdOfCurve(record.curve), 1);
            assertEq(factory.launchIdOfMetadataHash(params.metadataHash), 1);
            assertTrue(factory.isRegisteredCurve(record.curve));
            assertEq(abi.encode(factory.getLaunch(1)), abi.encode(record));
            assertEq(token.name(), params.name);
            assertEq(token.symbol(), params.symbol);
            assertEq(token.totalSupply(), BabyNoxaConstants.TOTAL_SUPPLY);
            assertEq(token.balanceOf(address(factory)), 0);
            assertEq(token.balanceOf(address(factory.launchDeployer())), 0);
            assertEq(token.balanceOf(record.curve), BabyNoxaConstants.TOTAL_SUPPLY);
            assertEq(token.balanceOf(alice), 0);
            assertEq(uint256(curve.state()), uint256(LaunchState.Trading));
            assertEq(curve.factory(), address(factory));
            assertEq(curve.creator(), alice);
            assertEq(curve.treasury(), treasury);
            assertEq(curve.graduationManager(), address(managerV1));
            assertEq(curve.officialPair(), record.officialPair);
            assertEq(pair.bootstrapManager(), address(managerV1));
            assertTrue(pair.bootstrapLocked());
            assertEq(v2Factory.getPair(record.token, address(wrappedNative)), record.officialPair);
            _assertFactoryEvents(logs, record, params);
        }

        function test_AtomicCreatorBuyCannotBeFrontRunAndStaysBelowCap() public {
            BabyNoxaLaunchDeployer deployer = factory.launchDeployer();
            uint256 deployerNonce = vm.getNonce(address(deployer));
            address predictedCurve = vm.computeCreateAddress(address(deployer), deployerNonce + 1);
            assertEq(predictedCurve.code.length, 0);

            vm.prank(attacker);
            (bool prelaunchCallSucceeded,) =
                predictedCurve.call{value: 200}(abi.encodeCall(BondingCurve.buy, (0, type(uint256).max)));
            assertTrue(prelaunchCallSucceeded);

            (uint256 netForNineteenMillion,,) = CurveMath.netBaseForExactTokensOut(
                BabyNoxaConstants.INITIAL_VIRTUAL_BASE_RESERVE,
                BabyNoxaConstants.INITIAL_VIRTUAL_TOKEN_RESERVE,
                19_000_000 ether
            );
            uint256 creatorGrossBuy = FeeMath.grossFromNet(netForNineteenMillion);
            CreateLaunchParams memory params = _params("Creator Buy", "CBUY", keccak256("creator buy metadata"));
            params.minimumCreatorTokensOut = 19_000_000 ether;

            vm.recordLogs();
            uint256 aliceBaseBefore = alice.balance;
            vm.prank(alice);
            LaunchRecord memory record = factory.createLaunch{value: creatorGrossBuy}(params);
            Vm.Log[] memory logs = vm.getRecordedLogs();

            BabyNoxaToken token = BabyNoxaToken(record.token);
            BondingCurve curve = BondingCurve(record.curve);
            assertEq(record.curve, predictedCurve);
            assertEq(alice.balance, aliceBaseBefore - creatorGrossBuy);
            assertGe(token.balanceOf(alice), 19_000_000 ether);
            assertLe(token.balanceOf(alice), BabyNoxaConstants.CREATOR_INITIAL_BUY_CAP);
            assertEq(token.balanceOf(attacker), 0);
            assertTrue(curve.creatorInitialBuyExecuted());
            assertEq(token.balanceOf(record.curve) + token.balanceOf(alice), BabyNoxaConstants.TOTAL_SUPPLY);
            assertEq(address(curve).balance - curve.accountedContractBalance(), 200);
            _assertFirstPurchaseBelongsTo(logs, record.curve, alice);
        }

        function test_CreatorBuyAboveCapRevertsEveryDeploymentAndRegistryMutation() public {
            CreateLaunchParams memory params = _params("Too Large", "LARGE", keccak256("too large metadata"));
            uint256 launchCountBefore = factory.launchCount();
            uint256 pairCountBefore = v2Factory.allPairsLength();
            uint256 aliceBefore = alice.balance;

            vm.expectPartialRevert(BondingCurve.CreatorInitialBuyCapExceeded.selector);
            vm.prank(alice);
            factory.createLaunch{value: 1 ether}(params);

            assertEq(alice.balance, aliceBefore);
            assertEq(factory.launchCount(), launchCountBefore);
            assertEq(v2Factory.allPairsLength(), pairCountBefore);
            assertEq(factory.launchIdOfMetadataHash(params.metadataHash), 0);
        }

        function test_MalformedAndDuplicateInputsRevertWithoutPartialLaunches() public {
            CreateLaunchParams memory params = _params("Valid", "VALID", keccak256("malformed suite"));

            params.name = "";
            vm.expectRevert(BabyNoxaFactory.EmptyTokenName.selector);
            vm.prank(alice);
            factory.createLaunch(params);
            params.name = "Valid";

            params.symbol = "";
            vm.expectRevert(BabyNoxaFactory.EmptyTokenSymbol.selector);
            vm.prank(alice);
            factory.createLaunch(params);
            params.symbol = "VALID";

            params.metadataURI = "";
            vm.expectRevert(BabyNoxaFactory.EmptyMetadataURI.selector);
            vm.prank(alice);
            factory.createLaunch(params);
            params.metadataURI = "ipfs://malformed-suite";

            bytes32 metadataHash = params.metadataHash;
            params.metadataHash = bytes32(0);
            vm.expectRevert(BabyNoxaFactory.ZeroMetadataHash.selector);
            vm.prank(alice);
            factory.createLaunch(params);
            params.metadataHash = metadataHash;

            params.minimumCreatorTokensOut = 1;
            vm.expectRevert(abi.encodeWithSelector(BabyNoxaFactory.InvalidZeroValueCreatorMinimum.selector, 1));
            vm.prank(alice);
            factory.createLaunch(params);
            params.minimumCreatorTokensOut = 0;

            vm.warp(101);
            params.deadline = 100;
            vm.expectRevert(abi.encodeWithSelector(DeadlinePolicy.DeadlineExpired.selector, 100, 101));
            vm.prank(alice);
            factory.createLaunch(params);
            params.deadline = type(uint256).max;

            vm.prank(alice);
            factory.createLaunch(params);
            vm.expectRevert(abi.encodeWithSelector(BabyNoxaFactory.DuplicateMetadataHash.selector, metadataHash, 1));
            vm.prank(bob);
            factory.createLaunch(params);

            assertEq(factory.launchCount(), 1);
            assertEq(v2Factory.allPairsLength(), 1);
            vm.expectRevert(abi.encodeWithSelector(BabyNoxaFactory.LaunchNotFound.selector, 2));
            factory.getLaunch(2);
        }

        function test_ManagerAndTreasuryRotationAffectOnlyFutureLaunches() public {
            CreateLaunchParams memory firstParams = _params("Manager One", "MONE", keccak256("manager one"));
            vm.prank(alice);
            LaunchRecord memory first = factory.createLaunch(firstParams);

            GraduationManagerV1 managerV2 =
                new GraduationManagerV1(address(factory), address(v2Factory), address(router), address(wrappedNative));
            address treasuryV2 = makeAddr("phase 8 treasury v2");
            vm.startPrank(owner);
            factory.setDefaultTreasury(treasuryV2);
            factory.setActiveGraduationManager(address(managerV2));
            vm.stopPrank();

            CreateLaunchParams memory secondParams = _params("Manager Two", "MTWO", keccak256("manager two"));
            vm.prank(bob);
            LaunchRecord memory second = factory.createLaunch(secondParams);

            assertEq(first.graduationManager, address(managerV1));
            assertEq(BondingCurve(first.curve).graduationManager(), address(managerV1));
            assertEq(IGuardedV2Pair(first.officialPair).bootstrapManager(), address(managerV1));
            assertEq(first.treasury, treasury);
            assertEq(BondingCurve(first.curve).treasury(), treasury);
            assertEq(second.graduationManager, address(managerV2));
            assertEq(BondingCurve(second.curve).graduationManager(), address(managerV2));
            assertEq(IGuardedV2Pair(second.officialPair).bootstrapManager(), address(managerV2));
            assertEq(second.treasury, treasuryV2);
            assertEq(BondingCurve(second.curve).treasury(), treasuryV2);
            assertEq(factory.getLaunch(1).metadataHash, firstParams.metadataHash);
            assertEq(factory.getLaunch(2).metadataHash, secondParams.metadataHash);
        }

        function test_TwoStepOwnershipRestrictsFutureLaunchConfiguration() public {
            address nextOwner = makeAddr("phase 8 next owner");
            address nextTreasury = makeAddr("phase 8 next treasury");

            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
            vm.prank(attacker);
            factory.setDefaultTreasury(nextTreasury);

            vm.prank(owner);
            factory.transferOwnership(nextOwner);
            assertEq(factory.owner(), owner);
            assertEq(factory.pendingOwner(), nextOwner);

            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
            vm.prank(attacker);
            factory.acceptOwnership();
            vm.prank(nextOwner);
            factory.acceptOwnership();
            assertEq(factory.owner(), nextOwner);
            assertEq(factory.pendingOwner(), address(0));

            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
            vm.prank(owner);
            factory.setDefaultTreasury(nextTreasury);
            vm.prank(nextOwner);
            factory.setDefaultTreasury(nextTreasury);
            assertEq(factory.defaultTreasury(), nextTreasury);

            vm.expectRevert(BabyNoxaFactory.InvalidGraduationManager.selector);
            vm.prank(nextOwner);
            factory.setActiveGraduationManager(attacker);
        }

        function test_FactoryCreatedLaunchCompletesTheRealGraduationLifecycle() public {
            CreateLaunchParams memory params = _params("Full Lifecycle", "FULL", keccak256("full lifecycle"));
            vm.prank(alice);
            LaunchRecord memory record = factory.createLaunch(params);
            BondingCurve curve = BondingCurve(record.curve);
            IGuardedV2Pair pair = IGuardedV2Pair(record.officialPair);

            vm.prank(bob);
            curve.buy{value: 10 ether}(0, type(uint256).max);

            assertEq(uint256(curve.state()), uint256(LaunchState.Graduated));
            assertTrue(managerV1.graduatedCurve(record.curve));
            assertFalse(pair.bootstrapLocked());
            assertEq(pair.bootstrapManager(), address(0));
            assertEq(pair.balanceOf(managerV1.burnAddress()), curve.graduatedBurnedLp());
            assertEq(BabyNoxaToken(record.token).balanceOf(record.officialPair), curve.graduatedLiquidityTokens());
            assertEq(wrappedNative.balanceOf(record.officialPair), curve.graduatedLiquidityBase());
        }

        function test_ReentrantPairCreationCannotCreateANestedLaunch() public {
            TestWrappedNative localWrapped = new TestWrappedNative();
            uint256 currentNonce = vm.getNonce(address(this));
            address predictedFactory = vm.computeCreateAddress(address(this), currentNonce + 2);
            Phase8ReentrantV2Factory reentrantV2 = new Phase8ReentrantV2Factory(predictedFactory);
            IV2Router02 localRouter = IV2Router02(
                vm.deployCode(
                    "GuardedV2Router02.sol:GuardedV2Router02", abi.encode(address(reentrantV2), address(localWrapped))
                )
            );
            BabyNoxaFactory reentrantFactory = new BabyNoxaFactory(
                owner,
                treasury,
                address(reentrantV2),
                address(localWrapped),
                BabyNoxaConstants.INITIAL_VIRTUAL_BASE_RESERVE,
                BabyNoxaConstants.INITIAL_VIRTUAL_TOKEN_RESERVE
            );
            assertEq(address(reentrantFactory), predictedFactory);
            Phase8ManagerConfigurationHarness manager = new Phase8ManagerConfigurationHarness(
                address(reentrantFactory), address(reentrantV2), address(localRouter), address(localWrapped)
            );
            vm.prank(owner);
            reentrantFactory.setActiveGraduationManager(address(manager));

            CreateLaunchParams memory params = _params("Outer Launch", "OUTER", keccak256("outer launch"));
            vm.prank(alice);
            LaunchRecord memory record = reentrantFactory.createLaunch(params);

            assertTrue(reentrantV2.reentryAttempted());
            assertFalse(reentrantV2.reentrySucceeded());
            assertEq(reentrantFactory.launchCount(), 1);
            assertEq(reentrantV2.allPairsLength(), 1);
            assertTrue(reentrantFactory.isRegisteredCurve(record.curve));
            assertEq(uint256(BondingCurve(record.curve).state()), uint256(LaunchState.Trading));
        }

        function _params(string memory name, string memory symbol, bytes32 metadataHash)
            internal
            pure
            returns (CreateLaunchParams memory params)
        {
            params = CreateLaunchParams({
                name: name,
                symbol: symbol,
                metadataURI: string.concat("ipfs://", name),
                metadataHash: metadataHash,
                minimumCreatorTokensOut: 0,
                deadline: type(uint256).max
            });
        }

        function _assertFactoryEvents(
            Vm.Log[] memory logs,
            LaunchRecord memory record,
            CreateLaunchParams memory params
        ) internal view {
            bytes32 metadataTopic = keccak256("MetadataCommitted(uint256,address,bytes32,string)");
            bytes32 launchTopic = keccak256("LaunchCreated(uint256,address,address,address,address,address,address)");
            bool sawMetadata;
            bool sawLaunch;
            for (uint256 i; i < logs.length; ++i) {
                if (logs[i].emitter != address(factory)) continue;
                if (logs[i].topics[0] == metadataTopic) {
                    sawMetadata = true;
                    assertEq(uint256(logs[i].topics[1]), record.launchId);
                    assertEq(address(uint160(uint256(logs[i].topics[2]))), record.token);
                    assertEq(logs[i].topics[3], params.metadataHash);
                }
                if (logs[i].topics[0] == launchTopic) {
                    sawLaunch = true;
                    assertEq(uint256(logs[i].topics[1]), record.launchId);
                    assertEq(address(uint160(uint256(logs[i].topics[2]))), record.creator);
                    assertEq(address(uint160(uint256(logs[i].topics[3]))), record.token);
                }
            }
            assertTrue(sawMetadata);
            assertTrue(sawLaunch);
        }

        function _assertFirstPurchaseBelongsTo(Vm.Log[] memory logs, address curve, address expectedBuyer)
            internal
            pure
        {
            bytes32 purchaseTopic =
                keccak256("TokensPurchased(address,uint256,uint256,uint256,uint256,uint256,uint256,uint256)");
            uint256 purchases;
            for (uint256 i; i < logs.length; ++i) {
                if (logs[i].emitter != curve || logs[i].topics[0] != purchaseTopic) continue;
                purchases++;
                assertEq(address(uint160(uint256(logs[i].topics[1]))), expectedBuyer);
            }
            assertEq(purchases, 1);
        }
    }
