// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {BabyNoxaToken} from "./BabyNoxaToken.sol";
import {BondingCurve} from "./BondingCurve.sol";
import {BabyNoxaLaunchDeployer} from "./BabyNoxaLaunchDeployer.sol";
import {IBabyNoxaFactory} from "./interfaces/IBabyNoxaFactory.sol";
import {IGraduationManager} from "./interfaces/IGraduationManager.sol";
import {IGuardedV2Factory} from "./interfaces/dex/IGuardedV2Factory.sol";
import {IGuardedV2Pair} from "./interfaces/dex/IGuardedV2Pair.sol";
import {IV2Router02} from "./interfaces/dex/IV2Router02.sol";
import {BabyNoxaConstants} from "./libraries/BabyNoxaConstants.sol";
import {DeadlinePolicy} from "./libraries/DeadlinePolicy.sol";
import {CreateLaunchParams, LaunchConfig, LaunchRecord, LaunchState} from "./types/BabyNoxaTypes.sol";

/// @title BabyNoxaFactory
/// @notice Deploys, funds, opens, and permanently registers one complete BabyNoxa launch atomically.
/// @dev Guarded V2 must be deployed first with this contract's predicted ordinary CREATE address.
contract BabyNoxaFactory is IBabyNoxaFactory, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address internal constant LP_BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    address public override defaultTreasury;
    address public override activeGraduationManager;
    address public immutable override v2Factory;
    address public immutable override wrappedNative;
    uint256 public immutable initialVirtualBaseReserve;
    uint256 public immutable initialVirtualTokenReserve;
    BabyNoxaLaunchDeployer public immutable launchDeployer;
    uint256 public override launchCount;

    mapping(uint256 launchId => LaunchRecord record) private launches;
    mapping(address token => uint256 launchId) public override launchIdOfToken;
    mapping(address curve => uint256 launchId) public override launchIdOfCurve;
    mapping(bytes32 metadataHash => uint256 launchId) public launchIdOfMetadataHash;

    error ZeroAddress();
    error InvalidVirtualReserves(uint256 virtualBase, uint256 virtualTokens);
    error InvalidV2Configuration();
    error InvalidGraduationManager();
    error GraduationManagerNotConfigured();
    error EmptyTokenName();
    error EmptyTokenSymbol();
    error EmptyMetadataURI();
    error ZeroMetadataHash();
    error DuplicateMetadataHash(bytes32 metadataHash, uint256 existingLaunchId);
    error InvalidZeroValueCreatorMinimum(uint256 minimumCreatorTokensOut);
    error InvalidOfficialPair();
    error TokenHandoffInvariantFailed();
    error BaseHandoffInvariantFailed(uint256 expectedBalance, uint256 actualBalance);
    error LaunchNotFound(uint256 launchId);
    error LaunchInitializationFailed();

    constructor(
        address initialOwner,
        address defaultTreasury_,
        address v2Factory_,
        address wrappedNative_,
        uint256 initialVirtualBaseReserve_,
        uint256 initialVirtualTokenReserve_
    ) Ownable(initialOwner) {
        if (defaultTreasury_ == address(0) || v2Factory_ == address(0) || wrappedNative_ == address(0)) revert ZeroAddress();
        if (initialVirtualBaseReserve_ == 0 || initialVirtualTokenReserve_ <= BabyNoxaConstants.CURVE_TOKEN_ALLOCATION)
        {
            revert InvalidVirtualReserves(initialVirtualBaseReserve_, initialVirtualTokenReserve_);
        }
        if (
            v2Factory_.code.length == 0 || wrappedNative_.code.length == 0
                || IGuardedV2Factory(v2Factory_).launchFactory() != address(this)
                || IGuardedV2Factory(v2Factory_).feeTo() != address(0)
                || IGuardedV2Factory(v2Factory_).feeToSetter() != address(0)
        ) revert InvalidV2Configuration();

        defaultTreasury = defaultTreasury_;
        v2Factory = v2Factory_;
        wrappedNative = wrappedNative_;
        initialVirtualBaseReserve = initialVirtualBaseReserve_;
        initialVirtualTokenReserve = initialVirtualTokenReserve_;
        launchDeployer = new BabyNoxaLaunchDeployer(address(this));
    }

    /// @inheritdoc IBabyNoxaFactory
    function createLaunch(CreateLaunchParams calldata params)
        external
        payable
        override
        nonReentrant
        returns (LaunchRecord memory record)
    {
        _validateLaunchInputs(params);
        address manager = activeGraduationManager;
        if (manager == address(0)) revert GraduationManagerNotConfigured();

        uint256 preexistingBaseBalance = address(this).balance - msg.value;
        uint256 launchId = ++launchCount;
        address treasury = defaultTreasury;
        BabyNoxaToken token = launchDeployer.deployToken(params.name, params.symbol);
        address officialPair = IGuardedV2Factory(v2Factory).createPair(address(token), wrappedNative, manager);
        _validateNewPair(address(token), officialPair, manager);

        LaunchConfig memory config = LaunchConfig({
            launchId: launchId,
            creator: msg.sender,
            token: address(token),
            treasury: treasury,
            graduationManager: manager,
            officialPair: officialPair,
            initialVirtualBaseReserve: initialVirtualBaseReserve,
            initialVirtualTokenReserve: initialVirtualTokenReserve
        });
        BondingCurve curve = launchDeployer.deployCurve(config);

        IERC20(address(token)).safeTransfer(address(curve), BabyNoxaConstants.TOTAL_SUPPLY);
        if (
            token.totalSupply() != BabyNoxaConstants.TOTAL_SUPPLY || token.balanceOf(address(this)) != 0
                || token.balanceOf(address(curve)) != BabyNoxaConstants.TOTAL_SUPPLY
        ) revert TokenHandoffInvariantFailed();

        record = LaunchRecord({
            launchId: launchId,
            creator: msg.sender,
            token: address(token),
            curve: address(curve),
            officialPair: officialPair,
            treasury: treasury,
            graduationManager: manager,
            metadataHash: params.metadataHash,
            metadataURI: params.metadataURI
        });
        launches[launchId] = record;
        launchIdOfToken[address(token)] = launchId;
        launchIdOfCurve[address(curve)] = launchId;
        launchIdOfMetadataHash[params.metadataHash] = launchId;

        uint256 creatorTokensOut = curve.launch{value: msg.value}(params.minimumCreatorTokensOut, params.deadline);
        if (
            curve.state() != LaunchState.Trading || token.balanceOf(address(this)) != 0
                || token.balanceOf(address(curve)) + token.balanceOf(msg.sender) != BabyNoxaConstants.TOTAL_SUPPLY
                || token.balanceOf(msg.sender) != creatorTokensOut
        ) revert LaunchInitializationFailed();
        if (address(this).balance != preexistingBaseBalance) {
            revert BaseHandoffInvariantFailed(preexistingBaseBalance, address(this).balance);
        }

        emit MetadataCommitted(launchId, address(token), params.metadataHash, params.metadataURI);
        emit LaunchCreated(launchId, msg.sender, address(token), address(curve), officialPair, treasury, manager);
    }

    /// @inheritdoc IBabyNoxaFactory
    function getLaunch(uint256 launchId) external view override returns (LaunchRecord memory record) {
        record = launches[launchId];
        if (record.launchId == 0) revert LaunchNotFound(launchId);
    }

    /// @inheritdoc IBabyNoxaFactory
    function isRegisteredCurve(address curve) external view override returns (bool) {
        return launchIdOfCurve[curve] != 0;
    }

    /// @inheritdoc IBabyNoxaFactory
    function setDefaultTreasury(address newTreasury) external override onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        address previousTreasury = defaultTreasury;
        defaultTreasury = newTreasury;
        emit DefaultTreasuryUpdated(previousTreasury, newTreasury);
    }

    /// @inheritdoc IBabyNoxaFactory
    function setActiveGraduationManager(address newManager) external override onlyOwner {
        if (newManager == address(0)) revert ZeroAddress();
        if (newManager.code.length == 0) revert InvalidGraduationManager();
        address managerRouter = IGraduationManager(newManager).router();
        if (
            IGraduationManager(newManager).factory() != address(this)
                || IGraduationManager(newManager).v2Factory() != v2Factory
                || IGraduationManager(newManager).wrappedNative() != wrappedNative
                || IGraduationManager(newManager).burnAddress() != LP_BURN_ADDRESS || managerRouter.code.length == 0
                || IV2Router02(managerRouter).factory() != v2Factory
                || IV2Router02(managerRouter).WETH() != wrappedNative
        ) revert InvalidGraduationManager();

        address previousManager = activeGraduationManager;
        activeGraduationManager = newManager;
        emit GraduationManagerActivated(previousManager, newManager);
    }

    function owner() public view override(IBabyNoxaFactory, Ownable) returns (address) {
        return super.owner();
    }

    function pendingOwner() public view override(IBabyNoxaFactory, Ownable2Step) returns (address) {
        return super.pendingOwner();
    }

    function transferOwnership(address newOwner) public override(IBabyNoxaFactory, Ownable2Step) {
        super.transferOwnership(newOwner);
    }

    function acceptOwnership() public override(IBabyNoxaFactory, Ownable2Step) {
        super.acceptOwnership();
    }

    function _validateLaunchInputs(CreateLaunchParams calldata params) private view {
        if (bytes(params.name).length == 0) revert EmptyTokenName();
        if (bytes(params.symbol).length == 0) revert EmptyTokenSymbol();
        if (bytes(params.metadataURI).length == 0) revert EmptyMetadataURI();
        if (params.metadataHash == bytes32(0)) revert ZeroMetadataHash();
        uint256 existingLaunchId = launchIdOfMetadataHash[params.metadataHash];
        if (existingLaunchId != 0) revert DuplicateMetadataHash(params.metadataHash, existingLaunchId);
        if (msg.value == 0 && params.minimumCreatorTokensOut != 0) {
            revert InvalidZeroValueCreatorMinimum(params.minimumCreatorTokensOut);
        }
        DeadlinePolicy.enforce(params.deadline);
    }

    function _validateNewPair(address token, address officialPair, address manager) private view {
        if (
            officialPair == address(0) || officialPair.code.length == 0
                || IGuardedV2Factory(v2Factory).getPair(token, wrappedNative) != officialPair
        ) revert InvalidOfficialPair();

        IGuardedV2Pair pair = IGuardedV2Pair(officialPair);
        address token0 = pair.token0();
        address token1 = pair.token1();
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        bool assetsMatch = (token0 == token && token1 == wrappedNative) || (token0 == wrappedNative && token1 == token);
        if (
            !assetsMatch || pair.factory() != v2Factory || pair.bootstrapManager() != manager || !pair.bootstrapLocked()
                || pair.totalSupply() != 0 || reserve0 != 0 || reserve1 != 0
        ) revert InvalidOfficialPair();
    }
}
