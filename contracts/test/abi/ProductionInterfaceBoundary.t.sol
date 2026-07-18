// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IBabyNoxaFactory} from "../../src/interfaces/IBabyNoxaFactory.sol";
import {IBabyNoxaToken} from "../../src/interfaces/IBabyNoxaToken.sol";
import {IBondingCurve} from "../../src/interfaces/IBondingCurve.sol";
import {IGraduationManager} from "../../src/interfaces/IGraduationManager.sol";
import {
    CreateLaunchParams,
    GraduationParams,
    GraduationResult,
    LaunchConfig,
    LaunchRecord,
    LaunchState
} from "../../src/types/BabyNoxaTypes.sol";

/// @dev Minimal compile-time implementation. It is not production token logic.
contract BabyNoxaTokenBoundaryHarness is IBabyNoxaToken {
    string public override name = "Boundary";
    string public override symbol = "BOUNDARY";
    uint8 public constant override decimals = 18;
    uint256 public override totalSupply;
    mapping(address account => uint256 balance) public override balanceOf;
    mapping(address owner => mapping(address spender => uint256 amount)) public override allowance;

    constructor() {
        totalSupply = 1_000_000_000 ether;
        balanceOf[msg.sender] = totalSupply;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function burn(uint256 amount) external override {
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
        emit Transfer(msg.sender, address(0), amount);
    }
}

    /// @dev Minimal compile-time implementation. It is not production curve logic.
    contract BondingCurveBoundaryHarness is IBondingCurve {
        address public override factory;
        address public override token;
        address public override creator;
        address public override treasury;
        address public override graduationManager;
        address public override officialPair;
        LaunchState public override state;
        uint256 public override virtualBaseReserve;
        uint256 public override virtualTokenReserve;
        uint256 public override realBaseReserve;
        uint256 public override curveTokenInventory;
        uint256 public override graduationTokenReserve;
        uint256 public override creatorTradingFees;
        uint256 public override treasuryTradingFees;
        uint256 public override graduationTreasuryAllocation;
        mapping(address account => uint256 amount) public override claimableBaseOf;
        mapping(address account => uint256 amount) public override claimableRefundOf;

        function launch(uint256, uint256) external payable override returns (uint256 creatorTokensOut) {
            state = LaunchState.Trading;
            return 0;
        }

        function buy(uint256, uint256) external payable override returns (uint256 tokensOut) {
            return 0;
        }

        function sell(uint256, uint256, uint256) external pure override returns (uint256 netBaseCredit) {
            return 0;
        }

        function claimRefund() external pure override returns (uint256 amount) {
            return 0;
        }

        function claimRefundTo(address payable) external pure override returns (uint256 amount) {
            return 0;
        }

        function claimBaseCredit() external pure override returns (uint256 amount) {
            return 0;
        }

        function claimBaseCreditTo(address payable) external pure override returns (uint256 amount) {
            return 0;
        }

        function claimCreatorFees() external pure override returns (uint256 amount) {
            return 0;
        }

        function claimCreatorFeesTo(address payable) external pure override returns (uint256 amount) {
            return 0;
        }

        function claimTreasuryFees() external pure override returns (uint256 amount) {
            return 0;
        }

        function claimTreasuryFeesTo(address payable) external pure override returns (uint256 amount) {
            return 0;
        }

        function accountedExecutedBase() external pure override returns (uint256) {
            return 0;
        }

        function accountedContractBalance() external pure override returns (uint256) {
            return 0;
        }

        function accountedTokenSupply() external pure override returns (uint256) {
            return 1_000_000_000 ether;
        }

        function emitCanonicalEvents() external {
            emit TokensPurchased(address(0x01), 1, 2, 3, 4, 5, 6, 7);
            emit TokensSold(address(0x01), 1, 2, 3, 4, 5);
            emit CreatorFeeAccrued(address(0x02), address(0x01), 1, true);
            emit TreasuryFeeAccrued(address(0x03), address(0x01), 1, true);
            emit GraduationReady(address(0x04), address(0x05), 1, 2);
        }
    }

        /// @dev Minimal compile-time implementation. It is not production graduation logic.
        contract GraduationManagerBoundaryHarness is IGraduationManager {
            address public override factory;
            address public override v2Factory;
            address public override router;
            address public override wrappedNative;
            address public override burnAddress = 0x000000000000000000000000000000000000dEaD;

            function graduate(GraduationParams calldata params)
                external
                payable
                override
                returns (GraduationResult memory result)
            {
                result.officialPair = params.officialPair;
            }

            function emitCanonicalEvents() external {
                emit GraduationExecuted(address(0x01), address(0x02), address(0x03), 1, 2, 3, 4);
                emit LiquidityCreated(address(0x01), address(0x03), 1, 2, 3);
                emit LiquidityBurned(address(0x01), address(0x03), burnAddress, 1);
            }
        }

            /// @dev Minimal compile-time implementation. It is not production factory logic.
            contract BabyNoxaFactoryBoundaryHarness is IBabyNoxaFactory {
                address public override owner = msg.sender;
                address public override pendingOwner;
                address public override defaultTreasury;
                address public override activeGraduationManager;
                address public override v2Factory;
                address public override wrappedNative;
                uint256 public override launchCount;
                mapping(address token => uint256 launchId) public override launchIdOfToken;
                mapping(address curve => uint256 launchId) public override launchIdOfCurve;
                mapping(address curve => bool registered) public override isRegisteredCurve;

                function transferOwnership(address newOwner) external override {
                    pendingOwner = newOwner;
                }

                function acceptOwnership() external override {
                    owner = pendingOwner;
                    pendingOwner = address(0);
                }

                function createLaunch(CreateLaunchParams calldata params)
                    external
                    payable
                    override
                    returns (LaunchRecord memory record)
                {
                    record = LaunchRecord({
                        launchId: ++launchCount,
                        creator: msg.sender,
                        token: address(0),
                        curve: address(0),
                        officialPair: address(0),
                        treasury: defaultTreasury,
                        graduationManager: activeGraduationManager,
                        metadataHash: params.metadataHash,
                        metadataURI: params.metadataURI
                    });
                }

                function getLaunch(uint256 launchId) external pure override returns (LaunchRecord memory record) {
                    record.launchId = launchId;
                }

                function setDefaultTreasury(address newTreasury) external override {
                    defaultTreasury = newTreasury;
                }

                function setActiveGraduationManager(address newManager) external override {
                    activeGraduationManager = newManager;
                }

                function emitCanonicalEvents() external {
                    emit LaunchCreated(
                        1, address(0x01), address(0x02), address(0x03), address(0x04), address(0x05), address(0x06)
                    );
                    emit MetadataCommitted(1, address(0x02), bytes32(uint256(1)), "ipfs://boundary");
                }
            }

                contract ProductionInterfaceBoundaryTest is Test {
                    function test_ConcreteHarnessesConformToEveryProductionInterface() public {
                        IBabyNoxaToken token = new BabyNoxaTokenBoundaryHarness();
                        IBondingCurve curve = new BondingCurveBoundaryHarness();
                        IGraduationManager manager = new GraduationManagerBoundaryHarness();
                        IBabyNoxaFactory factory = new BabyNoxaFactoryBoundaryHarness();

                        assertEq(token.decimals(), 18);
                        assertEq(curve.accountedTokenSupply(), 1_000_000_000 ether);
                        assertEq(manager.burnAddress(), 0x000000000000000000000000000000000000dEaD);
                        assertEq(factory.owner(), address(this));
                    }

                    function test_SharedStructsRoundTripAcrossTheirFrozenFieldOrder() public pure {
                        LaunchConfig memory config = LaunchConfig({
                            launchId: 7,
                            creator: address(0x11),
                            token: address(0x12),
                            treasury: address(0x13),
                            graduationManager: address(0x14),
                            officialPair: address(0x15),
                            initialVirtualBaseReserve: 1.425 ether,
                            initialVirtualTokenReserve: 1_066_666_667 ether
                        });
                        LaunchConfig memory decodedConfig = abi.decode(abi.encode(config), (LaunchConfig));
                        assertEq(decodedConfig.launchId, config.launchId);
                        assertEq(decodedConfig.officialPair, config.officialPair);
                        assertEq(decodedConfig.initialVirtualTokenReserve, config.initialVirtualTokenReserve);

                        GraduationResult memory result = GraduationResult({
                            officialPair: address(0x21),
                            treasuryAllocation: 1,
                            liquidityBase: 2,
                            liquidityTokens: 3,
                            burnedTokens: 4,
                            burnedLp: 5
                        });
                        GraduationResult memory decodedResult = abi.decode(abi.encode(result), (GraduationResult));
                        assertEq(decodedResult.officialPair, result.officialPair);
                        assertEq(decodedResult.burnedLp, result.burnedLp);
                    }

                    function test_TokenAndCurveSelectorSnapshot() public pure {
                        assertEq(IBabyNoxaToken.burn.selector, bytes4(0x42966c68));

                        assertEq(IBondingCurve.factory.selector, bytes4(0xc45a0155));
                        assertEq(IBondingCurve.token.selector, bytes4(0xfc0c546a));
                        assertEq(IBondingCurve.creator.selector, bytes4(0x02d05d3f));
                        assertEq(IBondingCurve.treasury.selector, bytes4(0x61d027b3));
                        assertEq(IBondingCurve.graduationManager.selector, bytes4(0x0da3f62b));
                        assertEq(IBondingCurve.officialPair.selector, bytes4(0x2eab62e4));
                        assertEq(IBondingCurve.state.selector, bytes4(0xc19d93fb));
                        assertEq(IBondingCurve.virtualBaseReserve.selector, bytes4(0x6c569f21));
                        assertEq(IBondingCurve.virtualTokenReserve.selector, bytes4(0x343ee3b7));
                        assertEq(IBondingCurve.realBaseReserve.selector, bytes4(0x0b1bba24));
                        assertEq(IBondingCurve.curveTokenInventory.selector, bytes4(0x16189de7));
                        assertEq(IBondingCurve.graduationTokenReserve.selector, bytes4(0xb67961de));
                        assertEq(IBondingCurve.creatorTradingFees.selector, bytes4(0xa885b6b5));
                        assertEq(IBondingCurve.treasuryTradingFees.selector, bytes4(0xc357c3fb));
                        assertEq(IBondingCurve.graduationTreasuryAllocation.selector, bytes4(0x2ebcf1b5));
                        assertEq(IBondingCurve.claimableBaseOf.selector, bytes4(0xc51f00f3));
                        assertEq(IBondingCurve.claimableRefundOf.selector, bytes4(0x11bcc3ad));
                        assertEq(IBondingCurve.launch.selector, bytes4(0x82760cd2));
                        assertEq(IBondingCurve.buy.selector, bytes4(0xd6febde8));
                        assertEq(IBondingCurve.sell.selector, bytes4(0xd3c9727c));
                        assertEq(IBondingCurve.claimRefund.selector, bytes4(0xb5545a3c));
                        assertEq(IBondingCurve.claimRefundTo.selector, bytes4(0x38f83332));
                        assertEq(IBondingCurve.claimBaseCredit.selector, bytes4(0xad08ef03));
                        assertEq(IBondingCurve.claimBaseCreditTo.selector, bytes4(0x23d9f9f1));
                        assertEq(IBondingCurve.claimCreatorFees.selector, bytes4(0x351fee46));
                        assertEq(IBondingCurve.claimCreatorFeesTo.selector, bytes4(0x6a534fcb));
                        assertEq(IBondingCurve.claimTreasuryFees.selector, bytes4(0xd1ba24e7));
                        assertEq(IBondingCurve.claimTreasuryFeesTo.selector, bytes4(0xf04c136a));
                        assertEq(IBondingCurve.accountedExecutedBase.selector, bytes4(0xc439f3d8));
                        assertEq(IBondingCurve.accountedContractBalance.selector, bytes4(0x5eb323c5));
                        assertEq(IBondingCurve.accountedTokenSupply.selector, bytes4(0xd55d35b9));
                    }

                    function test_ManagerAndFactorySelectorSnapshot() public pure {
                        assertEq(IGraduationManager.factory.selector, bytes4(0xc45a0155));
                        assertEq(IGraduationManager.v2Factory.selector, bytes4(0xb4b57c39));
                        assertEq(IGraduationManager.router.selector, bytes4(0xf887ea40));
                        assertEq(IGraduationManager.wrappedNative.selector, bytes4(0xeb6d3a11));
                        assertEq(IGraduationManager.burnAddress.selector, bytes4(0x70d5ae05));
                        assertEq(IGraduationManager.graduate.selector, bytes4(0xe889792c));

                        assertEq(IBabyNoxaFactory.owner.selector, bytes4(0x8da5cb5b));
                        assertEq(IBabyNoxaFactory.pendingOwner.selector, bytes4(0xe30c3978));
                        assertEq(IBabyNoxaFactory.transferOwnership.selector, bytes4(0xf2fde38b));
                        assertEq(IBabyNoxaFactory.acceptOwnership.selector, bytes4(0x79ba5097));
                        assertEq(IBabyNoxaFactory.defaultTreasury.selector, bytes4(0x4021adb6));
                        assertEq(IBabyNoxaFactory.activeGraduationManager.selector, bytes4(0xb447f0cd));
                        assertEq(IBabyNoxaFactory.v2Factory.selector, bytes4(0xb4b57c39));
                        assertEq(IBabyNoxaFactory.wrappedNative.selector, bytes4(0xeb6d3a11));
                        assertEq(IBabyNoxaFactory.launchCount.selector, bytes4(0x27cca59f));
                        assertEq(IBabyNoxaFactory.createLaunch.selector, bytes4(0x297573eb));
                        assertEq(IBabyNoxaFactory.getLaunch.selector, bytes4(0x5930d3ce));
                        assertEq(IBabyNoxaFactory.launchIdOfToken.selector, bytes4(0xa27d865a));
                        assertEq(IBabyNoxaFactory.launchIdOfCurve.selector, bytes4(0x89b38786));
                        assertEq(IBabyNoxaFactory.isRegisteredCurve.selector, bytes4(0xa1d3e91d));
                        assertEq(IBabyNoxaFactory.setDefaultTreasury.selector, bytes4(0x8b99c616));
                        assertEq(IBabyNoxaFactory.setActiveGraduationManager.selector, bytes4(0x98100486));
                    }

                    function test_ActualCanonicalEventTopicsMatchSnapshot() public {
                        BabyNoxaFactoryBoundaryHarness factory = new BabyNoxaFactoryBoundaryHarness();
                        BondingCurveBoundaryHarness curve = new BondingCurveBoundaryHarness();
                        GraduationManagerBoundaryHarness manager = new GraduationManagerBoundaryHarness();

                        vm.recordLogs();
                        factory.emitCanonicalEvents();
                        curve.emitCanonicalEvents();
                        manager.emitCanonicalEvents();
                        Vm.Log[] memory logs = vm.getRecordedLogs();

                        assertEq(logs.length, 10);
                        assertEq(logs[0].topics[0], 0x3432280dfe49d8f5a950aa30aab4414b11126c2be8e4d4e980cbf9e2b594cb75);
                        assertEq(logs[1].topics[0], 0x21661af8c84dc927069a5f5d0f5d1e0e1c6508f144eab5859b4a6c05dfdfd826);
                        assertEq(logs[2].topics[0], 0x291f12d04188f815b2427f0fa9de76192bfb09ed3243391f31dafb23e80ed8f8);
                        assertEq(logs[3].topics[0], 0x0db49c84bba47806cd98c426100d458b5859594553fc51f0ce13852e9e1ca1c9);
                        assertEq(logs[4].topics[0], 0xe849771d4c6a15854de2e33c2d0d2051a3374458b3da1632a0dede6c766b6330);
                        assertEq(logs[5].topics[0], 0xc3a08d8e27fec46e54422cd318624abfccd0d89347e708f2f79ea57e64180103);
                        assertEq(logs[6].topics[0], 0xccb3d6c402af5a89aabe65d6691b3b5b23d03f5ebb29f07216c3c86274286a90);
                        assertEq(logs[7].topics[0], 0xe87d52c6eba7215db7013eac6d0a7c7398a29aac2dfa21a6d1af8a9209a5bc3a);
                        assertEq(logs[8].topics[0], 0x500a75bd0946fb90f5867d9bbab6d6134e52420169e962228e74602a62d24edb);
                        assertEq(logs[9].topics[0], 0xcb04f3061d21c7fdf6e58a8b9afb0d3686a94035525d74398c3ecba8c67f6fcc);
                    }

                    function test_CanonicalEventSignatureSnapshot() public pure {
                        assertEq(
                            keccak256("LaunchCreated(uint256,address,address,address,address,address,address)"),
                            bytes32(0x3432280dfe49d8f5a950aa30aab4414b11126c2be8e4d4e980cbf9e2b594cb75)
                        );
                        assertEq(
                            keccak256("MetadataCommitted(uint256,address,bytes32,string)"),
                            bytes32(0x21661af8c84dc927069a5f5d0f5d1e0e1c6508f144eab5859b4a6c05dfdfd826)
                        );
                        assertEq(
                            keccak256(
                                "TokensPurchased(address,uint256,uint256,uint256,uint256,uint256,uint256,uint256)"
                            ),
                            bytes32(0x291f12d04188f815b2427f0fa9de76192bfb09ed3243391f31dafb23e80ed8f8)
                        );
                        assertEq(
                            keccak256("TokensSold(address,uint256,uint256,uint256,uint256,uint256)"),
                            bytes32(0x0db49c84bba47806cd98c426100d458b5859594553fc51f0ce13852e9e1ca1c9)
                        );
                        assertEq(
                            keccak256("CreatorFeeAccrued(address,address,uint256,bool)"),
                            bytes32(0xe849771d4c6a15854de2e33c2d0d2051a3374458b3da1632a0dede6c766b6330)
                        );
                        assertEq(
                            keccak256("TreasuryFeeAccrued(address,address,uint256,bool)"),
                            bytes32(0xc3a08d8e27fec46e54422cd318624abfccd0d89347e708f2f79ea57e64180103)
                        );
                        assertEq(
                            keccak256("GraduationReady(address,address,uint256,uint256)"),
                            bytes32(0xccb3d6c402af5a89aabe65d6691b3b5b23d03f5ebb29f07216c3c86274286a90)
                        );
                        assertEq(
                            keccak256("GraduationExecuted(address,address,address,uint256,uint256,uint256,uint256)"),
                            bytes32(0xe87d52c6eba7215db7013eac6d0a7c7398a29aac2dfa21a6d1af8a9209a5bc3a)
                        );
                        assertEq(
                            keccak256("LiquidityCreated(address,address,uint256,uint256,uint256)"),
                            bytes32(0x500a75bd0946fb90f5867d9bbab6d6134e52420169e962228e74602a62d24edb)
                        );
                        assertEq(
                            keccak256("LiquidityBurned(address,address,address,uint256)"),
                            bytes32(0xcb04f3061d21c7fdf6e58a8b9afb0d3686a94035525d74398c3ecba8c67f6fcc)
                        );
                    }
                }
