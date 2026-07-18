// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {IGuardedV2Factory} from "../../src/interfaces/dex/IGuardedV2Factory.sol";
import {IGuardedV2Pair} from "../../src/interfaces/dex/IGuardedV2Pair.sol";
import {IV2Router02} from "../../src/interfaces/dex/IV2Router02.sol";
import {TestWrappedNative} from "../../src/mocks/TestWrappedNative.sol";

contract GuardedV2TestToken is ERC20 {
    constructor() ERC20("Guarded V2 Test Token", "GV2TEST") {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}

contract GuardedV2LaunchAuthorityHarness {
    IGuardedV2Factory public factory;
    uint256 public successfulLaunches;

    function bindFactory(IGuardedV2Factory factory_) external {
        require(address(factory) == address(0), "LaunchHarness: FACTORY_ALREADY_BOUND");
        require(address(factory_) != address(0), "LaunchHarness: ZERO_FACTORY");
        factory = factory_;
    }

    function createOfficialPair(address tokenA, address tokenB, address bootstrapManager)
        external
        returns (address pair)
    {
        successfulLaunches++;
        pair = factory.createPair(tokenA, tokenB, bootstrapManager);
    }
}

contract GuardedV2BootstrapManagerHarness {
    function bootstrap(address pairAddress, uint256 amount0, uint256 amount1, uint256 minimumLiquidity)
        external
        returns (uint256 liquidity)
    {
        IGuardedV2Pair pair = IGuardedV2Pair(pairAddress);
        IERC20 token0 = IERC20(pair.token0());
        IERC20 token1 = IERC20(pair.token1());

        require(token0.transferFrom(msg.sender, address(this), amount0), "ManagerHarness: TOKEN0_PULL_FAILED");
        require(token1.transferFrom(msg.sender, address(this), amount1), "ManagerHarness: TOKEN1_PULL_FAILED");
        require(token0.approve(pairAddress, amount0), "ManagerHarness: TOKEN0_APPROVE_FAILED");
        require(token1.approve(pairAddress, amount1), "ManagerHarness: TOKEN1_APPROVE_FAILED");

        liquidity = pair.bootstrapMint(amount0, amount1);
        require(liquidity >= minimumLiquidity, "ManagerHarness: MINIMUM_LIQUIDITY");
    }
}

contract GuardedV2BootstrapTest is Test {
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    bytes32 internal constant GUARDED_PAIR_INIT_CODE_HASH =
        0x4e1cd411c31bb2545eccb2defb64f19d44df82a6f3dd81fa61e200b4b0a3fa2a;
    uint256 internal constant INITIAL_TOKEN_LIQUIDITY = 1_000_000 ether;
    uint256 internal constant INITIAL_BASE_LIQUIDITY = 1 ether;

    GuardedV2LaunchAuthorityHarness internal launchAuthority;
    GuardedV2BootstrapManagerHarness internal bootstrapManager;
    IGuardedV2Factory internal factory;
    IV2Router02 internal router;
    GuardedV2TestToken internal token;
    TestWrappedNative internal wrappedNative;

    receive() external payable {}

    function setUp() public {
        assertEq(
            keccak256(vm.getCode("GuardedV2Pair.sol:GuardedV2Pair")),
            GUARDED_PAIR_INIT_CODE_HASH,
            "guarded pair artifact changed"
        );

        launchAuthority = new GuardedV2LaunchAuthorityHarness();
        bootstrapManager = new GuardedV2BootstrapManagerHarness();
        factory = IGuardedV2Factory(
            vm.deployCode("GuardedV2Factory.sol:GuardedV2Factory", abi.encode(address(launchAuthority)))
        );
        launchAuthority.bindFactory(factory);

        token = new GuardedV2TestToken();
        wrappedNative = new TestWrappedNative();
        router = IV2Router02(
            vm.deployCode(
                "GuardedV2Router02.sol:GuardedV2Router02", abi.encode(address(factory), address(wrappedNative))
            )
        );
        token.approve(address(bootstrapManager), type(uint256).max);
        wrappedNative.approve(address(bootstrapManager), type(uint256).max);
        token.approve(address(router), type(uint256).max);
        vm.deal(address(this), 100 ether);
    }

    function test_FactoryConfigurationPermanentlyDisablesOptionalProtocolFee() public view {
        assertEq(factory.launchFactory(), address(launchAuthority));
        assertEq(factory.feeTo(), address(0));
        assertEq(factory.feeToSetter(), address(0));
        assertEq(router.factory(), address(factory));
        assertEq(router.WETH(), address(wrappedNative));
    }

    function test_PairCreationFailureRollsBackFactoryAndLaunchState() public {
        vm.expectRevert(bytes("BabyNoxaV2: IDENTICAL_ADDRESSES"));
        launchAuthority.createOfficialPair(address(token), address(token), address(bootstrapManager));

        assertEq(launchAuthority.successfulLaunches(), 0);
        assertEq(factory.allPairsLength(), 0);
        assertEq(factory.getPair(address(token), address(wrappedNative)), address(0));

        address pairAddress = _createPair();
        assertEq(launchAuthority.successfulLaunches(), 1);

        vm.expectRevert(bytes("BabyNoxaV2: PAIR_EXISTS"));
        launchAuthority.createOfficialPair(address(token), address(wrappedNative), address(bootstrapManager));

        assertEq(launchAuthority.successfulLaunches(), 1);
        assertEq(factory.allPairsLength(), 1);
        assertEq(factory.getPair(address(token), address(wrappedNative)), pairAddress);
    }

    function test_OutsiderCannotPrecreateOrConfigureOfficialPair() public {
        address attacker = makeAddr("pair precreator");

        vm.prank(attacker);
        vm.expectRevert(bytes("BabyNoxaV2: NOT_LAUNCH_FACTORY"));
        factory.createPair(address(token), address(wrappedNative), attacker);

        vm.prank(attacker);
        vm.expectRevert(bytes("BabyNoxaV2: MANAGER_REQUIRED"));
        factory.createPair(address(token), address(wrappedNative));

        assertEq(factory.allPairsLength(), 0);
        assertEq(factory.getPair(address(token), address(wrappedNative)), address(0));
    }

    function test_NewPairSnapshotsManagerAndLocksAllReserveMutations() public {
        IGuardedV2Pair pair = IGuardedV2Pair(_createPair());
        address attacker = makeAddr("bootstrap attacker");

        assertEq(pair.factory(), address(factory));
        assertEq(pair.bootstrapManager(), address(bootstrapManager));
        assertTrue(pair.bootstrapLocked());
        assertEq(pair.LP_BURN_ADDRESS(), DEAD);

        vm.startPrank(attacker);
        vm.expectRevert(bytes("BabyNoxaV2: BOOTSTRAP_LOCKED"));
        pair.mint(attacker);
        vm.expectRevert(bytes("BabyNoxaV2: BOOTSTRAP_LOCKED"));
        pair.burn(attacker);
        vm.expectRevert(bytes("BabyNoxaV2: BOOTSTRAP_LOCKED"));
        pair.swap(1, 0, attacker, "");
        vm.expectRevert(bytes("BabyNoxaV2: BOOTSTRAP_LOCKED"));
        pair.skim(attacker);
        vm.expectRevert(bytes("BabyNoxaV2: BOOTSTRAP_LOCKED"));
        pair.sync();
        vm.expectRevert(bytes("BabyNoxaV2: NOT_BOOTSTRAP_MANAGER"));
        pair.bootstrapMint(1, 1);
        vm.stopPrank();
    }

    function test_AtomicBootstrapBurnsPoisonedBalancesAndMintsOnlyBurnedLp() public {
        IGuardedV2Pair pair = IGuardedV2Pair(_createPair());
        uint256 donatedTokens = 123 ether;
        uint256 donatedBase = 777 wei;

        assertTrue(token.transfer(address(pair), donatedTokens));
        wrappedNative.deposit{value: donatedBase}();
        assertTrue(wrappedNative.transfer(address(pair), donatedBase));

        vm.prank(makeAddr("reserve poisoner"));
        vm.expectRevert(bytes("BabyNoxaV2: BOOTSTRAP_LOCKED"));
        pair.sync();

        uint256 deadTokenBefore = token.balanceOf(DEAD);
        uint256 deadBaseBefore = wrappedNative.balanceOf(DEAD);
        wrappedNative.deposit{value: INITIAL_BASE_LIQUIDITY}();
        (uint256 amount0, uint256 amount1) = _orderedAmounts(pair, INITIAL_TOKEN_LIQUIDITY, INITIAL_BASE_LIQUIDITY);
        uint256 expectedLiquidity = Math.sqrt(amount0 * amount1) - pair.MINIMUM_LIQUIDITY();

        uint256 liquidity = bootstrapManager.bootstrap(address(pair), amount0, amount1, expectedLiquidity);

        assertEq(liquidity, expectedLiquidity);
        assertFalse(pair.bootstrapLocked());
        assertEq(pair.bootstrapManager(), address(0));
        assertEq(token.balanceOf(DEAD), deadTokenBefore + donatedTokens);
        assertEq(wrappedNative.balanceOf(DEAD), deadBaseBefore + donatedBase);
        assertEq(pair.balanceOf(DEAD), expectedLiquidity);
        assertEq(pair.balanceOf(address(0)), pair.MINIMUM_LIQUIDITY());
        assertEq(pair.totalSupply(), expectedLiquidity + pair.MINIMUM_LIQUIDITY());
        _assertReserves(pair, INITIAL_TOKEN_LIQUIDITY, INITIAL_BASE_LIQUIDITY);
    }

    function test_LiquiditySlippageFailureRollsBackDonationsAssetsLpAndUnlock() public {
        IGuardedV2Pair pair = IGuardedV2Pair(_createPair());
        uint256 donatedTokens = 5 ether;
        uint256 donatedBase = 9 wei;

        assertTrue(token.transfer(address(pair), donatedTokens));
        wrappedNative.deposit{value: donatedBase + INITIAL_BASE_LIQUIDITY}();
        assertTrue(wrappedNative.transfer(address(pair), donatedBase));

        (uint256 amount0, uint256 amount1) = _orderedAmounts(pair, INITIAL_TOKEN_LIQUIDITY, INITIAL_BASE_LIQUIDITY);
        uint256 tokenBalanceBefore = token.balanceOf(address(this));
        uint256 wrappedBalanceBefore = wrappedNative.balanceOf(address(this));
        uint256 deadTokenBefore = token.balanceOf(DEAD);
        uint256 deadBaseBefore = wrappedNative.balanceOf(DEAD);

        vm.expectRevert(bytes("ManagerHarness: MINIMUM_LIQUIDITY"));
        bootstrapManager.bootstrap(address(pair), amount0, amount1, type(uint256).max);

        assertTrue(pair.bootstrapLocked());
        assertEq(pair.bootstrapManager(), address(bootstrapManager));
        assertEq(pair.totalSupply(), 0);
        assertEq(token.balanceOf(address(pair)), donatedTokens);
        assertEq(wrappedNative.balanceOf(address(pair)), donatedBase);
        assertEq(token.balanceOf(address(this)), tokenBalanceBefore);
        assertEq(wrappedNative.balanceOf(address(this)), wrappedBalanceBefore);
        assertEq(token.balanceOf(DEAD), deadTokenBefore);
        assertEq(wrappedNative.balanceOf(DEAD), deadBaseBefore);
        _assertReserves(pair, 0, 0);
    }

    function test_InsufficientFirstLiquidityRollsBackManagerTransfers() public {
        IGuardedV2Pair pair = IGuardedV2Pair(_createPair());
        wrappedNative.deposit{value: 1}();
        (uint256 amount0, uint256 amount1) = _orderedAmounts(pair, 1, 1);
        uint256 tokenBalanceBefore = token.balanceOf(address(this));
        uint256 wrappedBalanceBefore = wrappedNative.balanceOf(address(this));

        vm.expectRevert(bytes("BabyNoxaV2: INSUFFICIENT_LIQUIDITY_MINTED"));
        bootstrapManager.bootstrap(address(pair), amount0, amount1, 0);

        assertTrue(pair.bootstrapLocked());
        assertEq(pair.bootstrapManager(), address(bootstrapManager));
        assertEq(pair.totalSupply(), 0);
        assertEq(token.balanceOf(address(pair)), 0);
        assertEq(wrappedNative.balanceOf(address(pair)), 0);
        assertEq(token.balanceOf(address(this)), tokenBalanceBefore);
        assertEq(wrappedNative.balanceOf(address(this)), wrappedBalanceBefore);
        _assertReserves(pair, 0, 0);
    }

    function test_BootstrapAuthorityIsErasedAndGuardedRouterSwapWorksAfterward() public {
        IGuardedV2Pair pair = IGuardedV2Pair(_createAndBootstrapPair());

        vm.expectRevert(bytes("BabyNoxaV2: ALREADY_BOOTSTRAPPED"));
        vm.prank(address(bootstrapManager));
        pair.bootstrapMint(1, 1);

        address buyer = makeAddr("post graduation buyer");
        uint256 amountIn = 0.1 ether;
        vm.deal(buyer, amountIn);
        (uint112 reserve0Before, uint112 reserve1Before,) = pair.getReserves();
        address[] memory path = new address[](2);
        path[0] = address(wrappedNative);
        path[1] = address(token);
        uint256 expectedOut = router.getAmountsOut(amountIn, path)[1];

        vm.prank(buyer);
        uint256[] memory amounts =
            router.swapExactETHForTokens{value: amountIn}(expectedOut, path, buyer, block.timestamp);

        assertEq(amounts[0], amountIn);
        assertEq(amounts[1], expectedOut);
        assertEq(token.balanceOf(buyer), expectedOut);
        assertGe(
            uint256(_reserveProduct(pair)),
            uint256(reserve0Before) * uint256(reserve1Before),
            "constant product decreased"
        );

        assertTrue(token.transfer(address(pair), 1));
        pair.sync();
        assertEq(pair.bootstrapManager(), address(0));
        assertFalse(pair.bootstrapLocked());
    }

    function test_GuardedRouterAddsPostBootstrapLiquidityAndRefundsUnusedNativeBase() public {
        IGuardedV2Pair pair = IGuardedV2Pair(_createAndBootstrapPair());
        uint256 nativeBalanceBefore = address(this).balance;

        (uint256 usedTokens, uint256 usedBase, uint256 liquidity) = router.addLiquidityETH{value: 2 ether}(
            address(token),
            INITIAL_TOKEN_LIQUIDITY,
            INITIAL_TOKEN_LIQUIDITY,
            INITIAL_BASE_LIQUIDITY,
            address(this),
            block.timestamp
        );

        assertEq(usedTokens, INITIAL_TOKEN_LIQUIDITY);
        assertEq(usedBase, INITIAL_BASE_LIQUIDITY);
        assertEq(address(this).balance, nativeBalanceBefore - INITIAL_BASE_LIQUIDITY);
        assertGt(liquidity, 0);
        assertEq(pair.balanceOf(address(this)), liquidity);
        _assertReserves(pair, INITIAL_TOKEN_LIQUIDITY * 2, INITIAL_BASE_LIQUIDITY * 2);
    }

    function _createPair() internal returns (address pairAddress) {
        pairAddress =
            launchAuthority.createOfficialPair(address(token), address(wrappedNative), address(bootstrapManager));
    }

    function _createAndBootstrapPair() internal returns (address pairAddress) {
        pairAddress = _createPair();
        IGuardedV2Pair pair = IGuardedV2Pair(pairAddress);
        wrappedNative.deposit{value: INITIAL_BASE_LIQUIDITY}();
        (uint256 amount0, uint256 amount1) = _orderedAmounts(pair, INITIAL_TOKEN_LIQUIDITY, INITIAL_BASE_LIQUIDITY);
        bootstrapManager.bootstrap(pairAddress, amount0, amount1, 0);
    }

    function _orderedAmounts(IGuardedV2Pair pair, uint256 tokenAmount, uint256 baseAmount)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        if (pair.token0() == address(token)) return (tokenAmount, baseAmount);
        return (baseAmount, tokenAmount);
    }

    function _assertReserves(IGuardedV2Pair pair, uint256 expectedTokens, uint256 expectedBase) internal view {
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        if (pair.token0() == address(token)) {
            assertEq(reserve0, expectedTokens);
            assertEq(reserve1, expectedBase);
        } else {
            assertEq(reserve0, expectedBase);
            assertEq(reserve1, expectedTokens);
        }
    }

    function _reserveProduct(IGuardedV2Pair pair) internal view returns (uint256 product) {
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        product = uint256(reserve0) * uint256(reserve1);
    }
}
