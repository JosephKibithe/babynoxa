// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Test} from "forge-std/Test.sol";
import {BabyNoxaToken} from "../../src/BabyNoxaToken.sol";
import {BabyNoxaConstants} from "../../src/libraries/BabyNoxaConstants.sol";

contract BabyNoxaTokenDeploymentHarness {
    error HandoffFailed();
    error FactoryRetainedTokens(uint256 balance);

    function deployAndHandoff(string calldata name, string calldata symbol, address curve)
        external
        returns (BabyNoxaToken token)
    {
        token = new BabyNoxaToken(name, symbol, address(this));
        if (!token.transfer(curve, token.totalSupply())) revert HandoffFailed();

        uint256 retainedBalance = token.balanceOf(address(this));
        if (retainedBalance != 0) revert FactoryRetainedTokens(retainedBalance);
    }
}

contract BabyNoxaTokenTest is Test {
    address internal initialSupplyRecipient = makeAddr("initialSupplyRecipient");
    address internal creator = makeAddr("creatorWithoutFreeAllocation");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal curve = makeAddr("curve");

    BabyNoxaToken internal token;

    function setUp() public {
        token = new BabyNoxaToken("Baby Noxa Test", "BNOXA", initialSupplyRecipient);
    }

    function test_MetadataDecimalsAndInitialSupplyAreExact() public view {
        assertEq(token.name(), "Baby Noxa Test");
        assertEq(token.symbol(), "BNOXA");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), BabyNoxaConstants.TOTAL_SUPPLY);
        assertEq(token.balanceOf(initialSupplyRecipient), BabyNoxaConstants.TOTAL_SUPPLY);
        assertEq(token.balanceOf(address(token)), 0);
    }

    function test_CreatorReceivesNoFreeAllocation() public view {
        assertEq(token.balanceOf(creator), 0);
        assertEq(token.balanceOf(initialSupplyRecipient), BabyNoxaConstants.TOTAL_SUPPLY);
    }

    function test_TransferMovesTheExactAmountWithoutTax() public {
        uint256 amount = 123_456_789 ether;

        vm.prank(initialSupplyRecipient);
        assertTrue(token.transfer(bob, amount));

        assertEq(token.balanceOf(bob), amount);
        assertEq(token.balanceOf(initialSupplyRecipient), BabyNoxaConstants.TOTAL_SUPPLY - amount);
        assertEq(token.totalSupply(), BabyNoxaConstants.TOTAL_SUPPLY);
    }

    function test_AllowanceAndTransferFromFollowStandardErc20Behavior() public {
        uint256 allowanceAmount = 100 ether;
        uint256 transferAmount = 40 ether;

        vm.prank(initialSupplyRecipient);
        assertTrue(token.approve(bob, allowanceAmount));
        vm.prank(bob);
        assertTrue(token.transferFrom(initialSupplyRecipient, carol, transferAmount));

        assertEq(token.balanceOf(carol), transferAmount);
        assertEq(token.allowance(initialSupplyRecipient, bob), allowanceAmount - transferAmount);
        assertEq(token.totalSupply(), BabyNoxaConstants.TOTAL_SUPPLY);
    }

    function test_InfiniteAllowanceIsNotDecremented() public {
        vm.prank(initialSupplyRecipient);
        token.approve(bob, type(uint256).max);
        vm.prank(bob);
        token.transferFrom(initialSupplyRecipient, carol, 1 ether);

        assertEq(token.allowance(initialSupplyRecipient, bob), type(uint256).max);
        assertEq(token.balanceOf(carol), 1 ether);
    }

    function test_BurnDestroysOnlyTheCallersTokens() public {
        uint256 burnAmount = 25_000_000 ether;

        vm.prank(initialSupplyRecipient);
        token.burn(burnAmount);

        assertEq(token.balanceOf(initialSupplyRecipient), BabyNoxaConstants.TOTAL_SUPPLY - burnAmount);
        assertEq(token.totalSupply(), BabyNoxaConstants.TOTAL_SUPPLY - burnAmount);
        assertEq(token.balanceOf(creator), 0);
    }

    function test_ApprovalDoesNotCreateABurnFromAuthority() public {
        vm.prank(initialSupplyRecipient);
        token.approve(bob, 100 ether);

        vm.prank(bob);
        (bool success,) =
            address(token).call(abi.encodeWithSignature("burnFrom(address,uint256)", initialSupplyRecipient, 100 ether));

        assertFalse(success);
        assertEq(token.balanceOf(initialSupplyRecipient), BabyNoxaConstants.TOTAL_SUPPLY);
        assertEq(token.totalSupply(), BabyNoxaConstants.TOTAL_SUPPLY);
        assertEq(token.allowance(initialSupplyRecipient, bob), 100 ether);
    }

    function test_AdministrativeAndPostConstructionMintSelectorsDoNotExist() public {
        bytes[] memory prohibitedCalls = new bytes[](12);
        prohibitedCalls[0] = abi.encodeWithSignature("mint(address,uint256)", creator, 1 ether);
        prohibitedCalls[1] = abi.encodeWithSignature("pause()");
        prohibitedCalls[2] = abi.encodeWithSignature("unpause()");
        prohibitedCalls[3] = abi.encodeWithSignature("setBlacklist(address,bool)", creator, true);
        prohibitedCalls[4] = abi.encodeWithSignature("setTax(uint256)", 100);
        prohibitedCalls[5] = abi.encodeWithSignature("setTransferTax(uint256)", 100);
        prohibitedCalls[6] = abi.encodeWithSignature("confiscate(address,uint256)", initialSupplyRecipient, 1 ether);
        prohibitedCalls[7] = abi.encodeWithSignature("setBalance(address,uint256)", creator, 1 ether);
        prohibitedCalls[8] = abi.encodeWithSignature("setTradingEnabled(bool)", false);
        prohibitedCalls[9] = abi.encodeWithSignature("owner()");
        prohibitedCalls[10] = abi.encodeWithSignature("transferOwnership(address)", creator);
        prohibitedCalls[11] = abi.encodeWithSignature("burnFrom(address,uint256)", initialSupplyRecipient, 1 ether);

        for (uint256 index; index < prohibitedCalls.length; index++) {
            (bool success,) = address(token).call(prohibitedCalls[index]);
            assertFalse(success);
        }

        assertEq(token.totalSupply(), BabyNoxaConstants.TOTAL_SUPPLY);
        assertEq(token.balanceOf(initialSupplyRecipient), BabyNoxaConstants.TOTAL_SUPPLY);
        assertEq(token.balanceOf(creator), 0);
    }

    function test_ZeroInitialSupplyRecipientReverts() public {
        vm.expectRevert(BabyNoxaToken.ZeroSupplyRecipient.selector);
        new BabyNoxaToken("Baby Noxa Test", "BNOXA", address(0));
    }

    function test_ZeroAddressTransferAndApprovalRevert() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(initialSupplyRecipient);
        token.transfer(address(0), 1 ether);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(initialSupplyRecipient);
        token.approve(address(0), 1 ether);
    }

    function test_InsufficientTransferAndBurnRevert() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, bob, 0, 1));
        vm.prank(bob);
        token.transfer(carol, 1);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, bob, 0, 1));
        vm.prank(bob);
        token.burn(1);
    }

    function test_FactoryStyleDeploymentHandsOffAllTokensWithoutStranding() public {
        BabyNoxaTokenDeploymentHarness factoryHarness = new BabyNoxaTokenDeploymentHarness();
        BabyNoxaToken launchedToken = factoryHarness.deployAndHandoff("Handoff Test", "HANDOFF", curve);

        assertEq(launchedToken.totalSupply(), BabyNoxaConstants.TOTAL_SUPPLY);
        assertEq(launchedToken.balanceOf(curve), BabyNoxaConstants.TOTAL_SUPPLY);
        assertEq(launchedToken.balanceOf(address(factoryHarness)), 0);
        assertEq(launchedToken.balanceOf(creator), 0);
    }

    function testFuzz_TransfersConserveSupply(uint256 rawFirstTransfer, uint256 rawSecondTransfer) public {
        uint256 firstTransfer = bound(rawFirstTransfer, 0, BabyNoxaConstants.TOTAL_SUPPLY);
        vm.prank(initialSupplyRecipient);
        token.transfer(bob, firstTransfer);

        uint256 secondTransfer = bound(rawSecondTransfer, 0, firstTransfer);
        vm.prank(bob);
        token.transfer(carol, secondTransfer);

        assertEq(token.totalSupply(), BabyNoxaConstants.TOTAL_SUPPLY);
        assertEq(
            token.balanceOf(initialSupplyRecipient) + token.balanceOf(bob) + token.balanceOf(carol),
            BabyNoxaConstants.TOTAL_SUPPLY
        );
    }

    function testFuzz_CallerOwnedBurnNeverAffectsAnotherBalance(uint256 rawTransfer, uint256 rawBurn) public {
        uint256 bobTokens = bound(rawTransfer, 0, BabyNoxaConstants.TOTAL_SUPPLY);
        vm.prank(initialSupplyRecipient);
        token.transfer(bob, bobTokens);

        uint256 burnAmount = bound(rawBurn, 0, bobTokens);
        uint256 initialRecipientBalanceBefore = token.balanceOf(initialSupplyRecipient);
        vm.prank(bob);
        token.burn(burnAmount);

        assertEq(token.balanceOf(initialSupplyRecipient), initialRecipientBalanceBefore);
        assertEq(token.balanceOf(bob), bobTokens - burnAmount);
        assertEq(token.totalSupply(), BabyNoxaConstants.TOTAL_SUPPLY - burnAmount);
    }
}
