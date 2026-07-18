// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {BabyNoxaFactory} from "../../src/BabyNoxaFactory.sol";
import {BondingCurve} from "../../src/BondingCurve.sol";
import {GraduationManagerV1} from "../../src/GraduationManagerV1.sol";
import {IGraduationManager} from "../../src/interfaces/IGraduationManager.sol";
import {IGuardedV2Factory} from "../../src/interfaces/dex/IGuardedV2Factory.sol";
import {IGuardedV2Pair} from "../../src/interfaces/dex/IGuardedV2Pair.sol";
import {IV2Router02} from "../../src/interfaces/dex/IV2Router02.sol";
import {BabyNoxaConstants} from "../../src/libraries/BabyNoxaConstants.sol";
import {TestWrappedNative} from "../../src/mocks/TestWrappedNative.sol";
import {
    CreateLaunchParams,
    GraduationParams,
    GraduationResult,
    LaunchRecord,
    LaunchState
} from "../../src/types/BabyNoxaTypes.sol";

contract Phase9RevertingGraduationManager is IGraduationManager {
    address public constant override burnAddress = 0x000000000000000000000000000000000000dEaD;

    address public immutable override factory;
    address public immutable override v2Factory;
    address public immutable override router;
    address public immutable override wrappedNative;

    error DeliberateGraduationFailure();

    constructor(address factory_, address v2Factory_, address router_, address wrappedNative_) {
        factory = factory_;
        v2Factory = v2Factory_;
        router = router_;
        wrappedNative = wrappedNative_;
    }

    function graduate(GraduationParams calldata) external payable override returns (GraduationResult memory) {
        revert DeliberateGraduationFailure();
    }
}

    contract Phase9AdversarialTest is Test {
        uint256 internal constant MAX_LAUNCH_GAS = 8_000_000;
        uint256 internal constant MAX_BUY_GAS = 275_000;
        uint256 internal constant MAX_SELL_GAS = 300_000;
        uint256 internal constant MAX_FINAL_BUY_AND_GRADUATION_GAS = 1_500_000;

        address internal owner = makeAddr("phase9 adversarial owner");
        address internal treasury = makeAddr("phase9 adversarial treasury");
        address internal creator = makeAddr("phase9 adversarial creator");
        address internal trader = makeAddr("phase9 adversarial trader");

        TestWrappedNative internal wrappedNative;
        IGuardedV2Factory internal v2Factory;
        IV2Router02 internal router;
        BabyNoxaFactory internal factory;
        GraduationManagerV1 internal manager;
        uint256 internal metadataNonce;

        event GasMeasured(bytes32 indexed operation, uint256 gasUsed, uint256 maximumGas);

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

            manager =
                new GraduationManagerV1(address(factory), address(v2Factory), address(router), address(wrappedNative));
            vm.prank(owner);
            factory.setActiveGraduationManager(address(manager));
            vm.deal(creator, 100 ether);
            vm.deal(trader, 100 ether);
        }

        function testFuzz_NoProfitableRoundingOnlyBuySellLoop(uint96 grossSeed) public {
            LaunchRecord memory record = _createLaunch("rounding loop");
            BondingCurve curve = BondingCurve(payable(record.curve));
            IERC20 token = IERC20(record.token);
            uint256 gross = bound(uint256(grossSeed), 1 gwei, 1 ether);
            uint256 traderBaseBefore = trader.balance;

            vm.prank(trader);
            uint256 tokensBought = curve.buy{value: gross}(0, type(uint256).max);
            assertGt(tokensBought, 0);

            vm.startPrank(trader);
            token.approve(address(curve), tokensBought);
            uint256 sellCredit = curve.sell(tokensBought, 0, type(uint256).max);
            uint256 claimed = curve.claimBaseCredit();
            vm.stopPrank();

            assertEq(claimed, sellCredit);
            assertEq(token.balanceOf(trader), 0);
            assertEq(curve.curveTokenInventory(), BabyNoxaConstants.CURVE_TOKEN_ALLOCATION);
            assertLt(trader.balance, traderBaseBefore);
            assertLe(trader.balance, traderBaseBefore - 1);
        }

        function test_FactoryCreatedFinalBuyRollsBackWhenSnapshottedManagerFails() public {
            Phase9RevertingGraduationManager revertingManager = new Phase9RevertingGraduationManager(
                address(factory), address(v2Factory), address(router), address(wrappedNative)
            );
            vm.prank(owner);
            factory.setActiveGraduationManager(address(revertingManager));
            LaunchRecord memory record = _createLaunch("failing graduation");
            BondingCurve curve = BondingCurve(payable(record.curve));
            IERC20 token = IERC20(record.token);
            IGuardedV2Pair pair = IGuardedV2Pair(record.officialPair);
            uint256 traderBaseBefore = trader.balance;

            vm.expectRevert(Phase9RevertingGraduationManager.DeliberateGraduationFailure.selector);
            vm.prank(trader);
            curve.buy{value: 10 ether}(0, type(uint256).max);

            assertEq(trader.balance, traderBaseBefore);
            assertEq(token.balanceOf(trader), 0);
            assertEq(token.balanceOf(address(curve)), BabyNoxaConstants.TOTAL_SUPPLY);
            assertEq(token.balanceOf(address(revertingManager)), 0);
            assertEq(token.balanceOf(record.officialPair), 0);
            assertEq(token.totalSupply(), BabyNoxaConstants.TOTAL_SUPPLY);
            assertEq(uint256(curve.state()), uint256(LaunchState.Trading));
            assertEq(curve.curveTokenInventory(), BabyNoxaConstants.CURVE_TOKEN_ALLOCATION);
            assertEq(curve.graduationTokenReserve(), BabyNoxaConstants.GRADUATION_TOKEN_RESERVE);
            assertEq(curve.realBaseReserve(), 0);
            assertEq(curve.creatorTradingFees(), 0);
            assertEq(curve.treasuryTradingFees(), 0);
            assertEq(curve.claimableRefundOf(trader), 0);
            assertEq(address(curve).balance, 0);
            assertTrue(pair.bootstrapLocked());
            assertEq(pair.bootstrapManager(), address(revertingManager));
            assertEq(pair.totalSupply(), 0);
        }

        function test_GasRegressionThresholdsForProductionLifecycle() public {
            CreateLaunchParams memory params = _params("gas regression");
            vm.prank(creator);
            uint256 gasBefore = gasleft();
            LaunchRecord memory record = factory.createLaunch(params);
            uint256 launchGas = gasBefore - gasleft();
            emit GasMeasured("LAUNCH", launchGas, MAX_LAUNCH_GAS);
            assertLt(launchGas, MAX_LAUNCH_GAS);

            BondingCurve curve = BondingCurve(payable(record.curve));
            IERC20 token = IERC20(record.token);
            vm.prank(trader);
            gasBefore = gasleft();
            uint256 tokensBought = curve.buy{value: 0.25 ether}(0, type(uint256).max);
            uint256 buyGas = gasBefore - gasleft();
            emit GasMeasured("BUY", buyGas, MAX_BUY_GAS);
            assertLt(buyGas, MAX_BUY_GAS);

            vm.prank(trader);
            token.approve(address(curve), tokensBought / 4);
            vm.prank(trader);
            gasBefore = gasleft();
            curve.sell(tokensBought / 4, 0, type(uint256).max);
            uint256 sellGas = gasBefore - gasleft();
            emit GasMeasured("SELL", sellGas, MAX_SELL_GAS);
            assertLt(sellGas, MAX_SELL_GAS);

            vm.prank(trader);
            gasBefore = gasleft();
            curve.buy{value: 10 ether}(0, type(uint256).max);
            uint256 graduationGas = gasBefore - gasleft();
            emit GasMeasured("FINAL_BUY_AND_GRADUATION", graduationGas, MAX_FINAL_BUY_AND_GRADUATION_GAS);
            assertLt(graduationGas, MAX_FINAL_BUY_AND_GRADUATION_GAS);
            assertEq(uint256(curve.state()), uint256(LaunchState.Graduated));
        }

        function _createLaunch(string memory label) private returns (LaunchRecord memory record) {
            CreateLaunchParams memory params = _params(label);
            vm.prank(creator);
            record = factory.createLaunch(params);
        }

        function _params(string memory label) private returns (CreateLaunchParams memory params) {
            uint256 nonce = ++metadataNonce;
            params = CreateLaunchParams({
                name: "Phase 9 Adversarial Token",
                symbol: "P9A",
                metadataURI: string.concat("ipfs://phase9-adversarial/", vm.toString(nonce)),
                metadataHash: keccak256(abi.encode(label, nonce)),
                minimumCreatorTokensOut: 0,
                deadline: type(uint256).max
            });
        }
    }
