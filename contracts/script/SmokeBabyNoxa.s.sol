// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {BabyNoxaFactory} from "../src/BabyNoxaFactory.sol";
import {BondingCurve} from "../src/BondingCurve.sol";
import {IGuardedV2Pair} from "../src/interfaces/dex/IGuardedV2Pair.sol";
import {IV2Router02} from "../src/interfaces/dex/IV2Router02.sol";
import {CreateLaunchParams, LaunchRecord, LaunchState} from "../src/types/BabyNoxaTypes.sol";

/// @notice Runs the complete V1 lifecycle against an already deployed local Anvil stack.
contract SmokeBabyNoxa is Script {
    address internal constant LP_BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    error LocalAnvilOnly(uint256 chainId);
    error SmokeCheckFailed(string check);

    function run() external returns (uint256 graduatedLaunchId, uint256 creatorBuyLaunchId) {
        if (block.chainid != 31_337) revert LocalAnvilOnly(block.chainid);
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address actor = vm.addr(privateKey);
        string memory deploymentFile = vm.envOr("DEPLOYMENT_FILE", string("deployments/31337.json"));
        address factoryAddress = vm.parseJsonAddress(vm.readFile(deploymentFile), ".babyNoxaFactory");
        BabyNoxaFactory factory = BabyNoxaFactory(factoryAddress);
        IV2Router02 router =
            IV2Router02(factory.activeGraduationManager() == address(0) ? address(0) : _router(factory));

        vm.startBroadcast(privateKey);
        LaunchRecord memory first = factory.createLaunch(_params("Local Lifecycle", "LOCAL", "one", 0));
        BondingCurve curve = BondingCurve(payable(first.curve));
        uint256 bought = curve.buy{value: 0.25 ether}(0, type(uint256).max);
        IERC20(first.token).approve(first.curve, bought / 4);
        curve.sell(bought / 4, 0, type(uint256).max);
        curve.claimBaseCredit();
        curve.claimCreatorFees();
        curve.claimTreasuryFees();
        curve.buy{value: 10 ether}(0, type(uint256).max);
        if (curve.claimableRefundOf(actor) != 0) curve.claimRefund();
        if (curve.creatorTradingFees() != 0) curve.claimCreatorFees();
        if (curve.treasuryTradingFees() + curve.graduationTreasuryAllocation() != 0) curve.claimTreasuryFees();

        address[] memory path = new address[](2);
        path[0] = factory.wrappedNative();
        path[1] = first.token;
        router.swapExactETHForTokens{value: 0.001 ether}(0, path, actor, type(uint256).max);

        LaunchRecord memory second = factory.createLaunch{value: 0.01 ether}(_params("Creator Buy", "CBUY", "two", 1));
        vm.stopBroadcast();

        IGuardedV2Pair pair = IGuardedV2Pair(first.officialPair);
        if (curve.state() != LaunchState.Graduated) revert SmokeCheckFailed("curve not graduated");
        if (pair.bootstrapLocked()) revert SmokeCheckFailed("pair still locked");
        if (pair.balanceOf(LP_BURN_ADDRESS) == 0) revert SmokeCheckFailed("LP not burned");
        if (pair.balanceOf(first.treasury) != 0) revert SmokeCheckFailed("treasury received LP");
        if (IERC20(first.token).balanceOf(actor) == 0) revert SmokeCheckFailed("AMM swap produced no tokens");
        if (BondingCurve(payable(second.curve)).state() != LaunchState.Trading) {
            revert SmokeCheckFailed("creator-buy launch not trading");
        }
        if (IERC20(second.token).balanceOf(actor) == 0) revert SmokeCheckFailed("creator buy produced no tokens");

        graduatedLaunchId = first.launchId;
        creatorBuyLaunchId = second.launchId;
        console2.log("Graduated smoke launch", graduatedLaunchId);
        console2.log("Creator-buy smoke launch", creatorBuyLaunchId);
        console2.log("Burned LP", pair.balanceOf(LP_BURN_ADDRESS));
    }

    function _router(BabyNoxaFactory factory) private view returns (address) {
        return IManagerRouter(factory.activeGraduationManager()).router();
    }

    function _params(string memory name, string memory symbol, string memory salt, uint256 minimumCreatorTokensOut)
        private
        pure
        returns (CreateLaunchParams memory)
    {
        return CreateLaunchParams({
            name: name,
            symbol: symbol,
            metadataURI: string.concat("ipfs://babynoxa-local/", salt),
            metadataHash: keccak256(bytes(salt)),
            minimumCreatorTokensOut: minimumCreatorTokensOut,
            deadline: type(uint256).max
        });
    }
}

interface IManagerRouter {
    function router() external view returns (address);
}
