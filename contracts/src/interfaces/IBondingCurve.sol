// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LaunchState} from "../types/BabyNoxaTypes.sol";

/// @title IBondingCurve
/// @notice Production boundary for one BabyNoxa pre-graduation market.
interface IBondingCurve {
    event TokensPurchased(
        address indexed buyer,
        uint256 grossBaseSubmitted,
        uint256 grossBaseExecuted,
        uint256 netBaseToCurve,
        uint256 tokensOut,
        uint256 creatorFee,
        uint256 treasuryFee,
        uint256 grossBaseRefund
    );
    event TokensSold(
        address indexed seller,
        uint256 tokensIn,
        uint256 grossBaseOut,
        uint256 netBaseCredit,
        uint256 creatorFee,
        uint256 treasuryFee
    );
    event CreatorFeeAccrued(address indexed beneficiary, address indexed trader, uint256 amount, bool isBuy);
    event TreasuryFeeAccrued(address indexed beneficiary, address indexed trader, uint256 amount, bool isBuy);
    event GraduationReady(
        address indexed token,
        address indexed graduationManager,
        uint256 realBaseReserve,
        uint256 graduationTokenReserve
    );
    event RefundAccrued(address indexed buyer, uint256 amount);
    event SellCreditAccrued(address indexed seller, uint256 amount);
    event EtherClaimed(
        address indexed beneficiary, address indexed recipient, uint256 amount, bytes32 indexed claimType
    );
    /// @notice Launch-aware claim telemetry added without replacing the frozen V1 EtherClaimed event.
    event LaunchEtherClaimed(
        uint256 indexed launchId,
        address indexed beneficiary,
        address indexed recipient,
        bytes32 claimType,
        uint256 amount
    );

    function factory() external view returns (address);
    function token() external view returns (address);
    function creator() external view returns (address);
    function treasury() external view returns (address);
    function graduationManager() external view returns (address);
    function officialPair() external view returns (address);
    function state() external view returns (LaunchState);

    function virtualBaseReserve() external view returns (uint256);
    function virtualTokenReserve() external view returns (uint256);
    function realBaseReserve() external view returns (uint256);
    function curveTokenInventory() external view returns (uint256);
    function graduationTokenReserve() external view returns (uint256);
    function creatorTradingFees() external view returns (uint256);
    function treasuryTradingFees() external view returns (uint256);
    function graduationTreasuryAllocation() external view returns (uint256);
    function claimableBaseOf(address account) external view returns (uint256);
    function claimableRefundOf(address account) external view returns (uint256);

    /// @notice Opens trading and optionally performs the creator purchase. Callable only by the factory.
    function launch(uint256 minimumCreatorTokensOut, uint256 deadline)
        external
        payable
        returns (uint256 creatorTokensOut);

    function buy(uint256 minimumTokensOut, uint256 deadline) external payable returns (uint256 tokensOut);
    function sell(uint256 tokenAmount, uint256 minimumBaseOut, uint256 deadline)
        external
        returns (uint256 netBaseCredit);

    function claimRefund() external returns (uint256 amount);
    function claimRefundTo(address payable recipient) external returns (uint256 amount);
    function claimBaseCredit() external returns (uint256 amount);
    function claimBaseCreditTo(address payable recipient) external returns (uint256 amount);
    function claimCreatorFees() external returns (uint256 amount);
    function claimCreatorFeesTo(address payable recipient) external returns (uint256 amount);
    function claimTreasuryFees() external returns (uint256 amount);
    function claimTreasuryFeesTo(address payable recipient) external returns (uint256 amount);

    function accountedExecutedBase() external view returns (uint256);
    function accountedContractBalance() external view returns (uint256);
    function accountedTokenSupply() external view returns (uint256);
}
