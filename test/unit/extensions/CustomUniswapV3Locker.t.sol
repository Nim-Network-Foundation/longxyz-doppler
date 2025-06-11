// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { Constants } from "@v4-core-test/utils/Constants.sol";
import { IUniswapV3Pool } from "@v3-core/interfaces/IUniswapV3Pool.sol";
import { IQuoterV2 } from "@uniswap/v3-periphery/contracts/interfaces/IQuoterV2.sol";
import { ERC20, IERC20 } from "@openzeppelin/token/ERC20/ERC20.sol";

import { CustomUniswapV3Migrator } from "src/extensions/CustomUniswapV3Migrator.sol";
import { CustomUniswapV3Locker, ICustomUniswapV3Locker } from "src/extensions/CustomUniswapV3Locker.sol";
import { INonfungiblePositionManager } from "src/extensions/interfaces/INonfungiblePositionManager.sol";
import { IUniswapV3Factory, IBaseSwapRouter02 } from "src/extensions/CustomUniswapV3Migrator.sol";
import { Airlock } from "src/Airlock.sol";
import { SenderNotAirlock } from "src/base/ImmutableAirlock.sol";
import {
    UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER_BASE,
    UNISWAP_V3_FACTORY_BASE,
    WETH_BASE,
    UNISWAP_V3_ROUTER_02_BASE,
    UNISWAP_V3_QUOTER_V2_BASE
} from "test/shared/Addresses.sol";
import { console } from "forge-std/console.sol";

contract CustomUniswapV3LockerTest is Test {
    uint24 constant FEE_TIER = 10_000;
    address constant DOPPLER_FEE_RECEIVER = address(0x2222);
    address constant INTEGRATOR_FEE_RECEIVER = address(0x1111);
    int24 constant DEFAULT_LOWER_TICK = 0;
    int24 constant DEFAULT_UPPER_TICK = 200;

    INonfungiblePositionManager public NFPM = INonfungiblePositionManager(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER_BASE);
    IUniswapV3Factory public FACTORY = IUniswapV3Factory(UNISWAP_V3_FACTORY_BASE);
    IBaseSwapRouter02 public ROUTER_02 = IBaseSwapRouter02(UNISWAP_V3_ROUTER_02_BASE);
    IQuoterV2 public QUOTER_V2 = IQuoterV2(UNISWAP_V3_QUOTER_V2_BASE);

    CustomUniswapV3Locker public locker;
    CustomUniswapV3Migrator public migrator;
    Airlock public airlock = Airlock(payable(address(0xdeadbeef)));
    IUniswapV3Pool public pool;

    bytes public liquidityMigratorData = abi.encode(DEFAULT_LOWER_TICK, DEFAULT_UPPER_TICK, INTEGRATOR_FEE_RECEIVER);

    TestERC20 public tokenFoo;
    TestERC20 public tokenBar;

    address public timelock = makeAddr("timelock");

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_MAINNET_RPC_URL"), 31_118_046);

        tokenFoo = new TestERC20(1e25);
        tokenBar = new TestERC20(1e25);

        migrator = new CustomUniswapV3Migrator(
            address(this), // airlock
            NFPM,
            ROUTER_02,
            DOPPLER_FEE_RECEIVER,
            FEE_TIER
        );
        locker = new CustomUniswapV3Locker(NFPM, migrator, DOPPLER_FEE_RECEIVER);
    }

    function test_constructor() public view {
        assertEq(address(locker.NONFUNGIBLE_POSITION_MANAGER()), UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER_BASE);
        assertEq(address(locker.MIGRATOR()), address(migrator));
        assertEq(locker.DOPPLER_FEE_RECEIVER(), DOPPLER_FEE_RECEIVER);
    }

    function test_register_WithLockUpPeriod_InitializesPool()
        public
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        tokenFoo.transfer(address(this), 1000e18);
        tokenBar.transfer(address(this), 1000e18);

        (address token0, address token1) = address(tokenFoo) > address(tokenBar)
            ? (address(tokenBar), address(tokenFoo))
            : (address(tokenFoo), address(tokenBar));

        pool = IUniswapV3Pool(FACTORY.createPool(token0, token1, FEE_TIER));
        pool.initialize(Constants.SQRT_PRICE_1_1);

        IERC20(token0).approve(address(NFPM), 1000e18);
        IERC20(token1).approve(address(NFPM), 1000e18);
        (tokenId, liquidity, amount0, amount1) = NFPM.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: FEE_TIER,
                tickLower: -200,
                tickUpper: 200,
                amount0Desired: 1000e18,
                amount1Desired: 1000e18,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(locker),
                deadline: block.timestamp + 3600 // 1 hour
             })
        );
        vm.prank(address(migrator));
        locker.register(tokenId, amount0, amount1, INTEGRATOR_FEE_RECEIVER, timelock);

        (uint256 _amount0, uint256 _amount1, uint64 _minUnlockDate, address _integratorFeeReceiver, address _recipient)
        = locker.positionStates(tokenId);
        assertEq(_amount0, amount0);
        assertEq(_amount1, amount1);
        assertEq(_minUnlockDate, block.timestamp + 365 days);
        assertEq(_integratorFeeReceiver, INTEGRATOR_FEE_RECEIVER);
        assertEq(_recipient, timelock);
    }

    function test_register_RevertsWhenPoolAlreadyInitialized() public {
        (uint256 tokenId,, uint256 amount0, uint256 amount1) = test_register_WithLockUpPeriod_InitializesPool();
        vm.prank(address(migrator));
        vm.expectRevert(ICustomUniswapV3Locker.PoolAlreadyInitialized.selector);
        locker.register(tokenId, amount0, amount1, INTEGRATOR_FEE_RECEIVER, timelock);
    }

    function test_harvest() public {
        (uint256 tokenId,,,) = test_register_WithLockUpPeriod_InitializesPool();

        (,, address token0, address token1,,,,,,,,) = NFPM.positions(tokenId);

        uint160 priceLimit = TickMath.getSqrtPriceAtTick(
            token0 == address(WETH_BASE)
                ? TickMath.maxUsableTick(FACTORY.feeAmountTickSpacing(FEE_TIER))
                : TickMath.minUsableTick(FACTORY.feeAmountTickSpacing(FEE_TIER))
        );

        // (uint256 amountOut, uint160 sqrtPriceX96After,,) = QUOTER_V2.quoteExactInputSingle(
        //     IQuoterV2.QuoteExactInputSingleParams({
        //         tokenIn: token0,
        //         tokenOut: token1,
        //         fee: FEE_TIER,
        //         amountIn: 1e18,
        //         sqrtPriceLimitX96: priceLimit
        //     })
        // );

        // console.log("amountOut", amountOut);
        // console.log("sqrtPriceX96After", sqrtPriceX96After);

        IERC20(token0).approve(address(ROUTER_02), type(uint256).max);
        ROUTER_02.exactInputSingle(
            IBaseSwapRouter02.ExactInputSingleParams({
                tokenIn: token0,
                tokenOut: token1,
                fee: FEE_TIER,
                recipient: address(this),
                amountIn: 1e18,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: priceLimit
            })
        );

        // only token0 can be collected since only one side of the pool is swapped
        (uint256 collectedAmount0,) = locker.harvest(tokenId);

        assertGt(collectedAmount0, 0);
        assertEq(IERC20(token0).balanceOf(DOPPLER_FEE_RECEIVER), collectedAmount0 * 5 / 100);
        assertEq(IERC20(token0).balanceOf(INTEGRATOR_FEE_RECEIVER), collectedAmount0 - collectedAmount0 * 5 / 100);
    }

    function test_unlock() public {
        (uint256 tokenId,,,) = test_register_WithLockUpPeriod_InitializesPool();
        vm.warp(block.timestamp + 365 days);
        locker.unlock(tokenId);

        assertEq(INonfungiblePositionManager(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER_BASE).ownerOf(tokenId), timelock);
    }

    function test_unlock_RevertsWhenMinUnlockDateNotReached() public {
        (uint256 tokenId,,,) = test_register_WithLockUpPeriod_InitializesPool();
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(ICustomUniswapV3Locker.MinUnlockDateNotReached.selector);
        locker.unlock(tokenId);
    }

    function test_register_RevertsWhenNotCalledByMigrator() public {
        uint256 tokenId = 12_345;
        vm.expectRevert(abi.encodeWithSignature("SenderNotMigrator()"));
        locker.register(tokenId, 1000e18, 1000e18, INTEGRATOR_FEE_RECEIVER, timelock);
    }

    function test_register_RevertsWhenNFTPositionNotOwned() public {
        tokenFoo.transfer(address(this), 1000e18);
        tokenBar.transfer(address(this), 1000e18);

        (address token0, address token1) = address(tokenFoo) > address(tokenBar)
            ? (address(tokenBar), address(tokenFoo))
            : (address(tokenFoo), address(tokenBar));

        pool = IUniswapV3Pool(FACTORY.createPool(token0, token1, FEE_TIER));
        pool.initialize(Constants.SQRT_PRICE_1_1);

        IERC20(token0).approve(address(NFPM), 1000e18);
        IERC20(token1).approve(address(NFPM), 1000e18);

        (uint256 tokenId,, uint256 amount0, uint256 amount1) = NFPM.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: FEE_TIER,
                tickLower: -200,
                tickUpper: 200,
                amount0Desired: 1000e18,
                amount1Desired: 1000e18,
                amount0Min: 0,
                amount1Min: 0,
                recipient: alice,
                deadline: block.timestamp + 3600
            })
        );

        vm.prank(address(migrator));
        vm.expectRevert(abi.encodeWithSelector(ICustomUniswapV3Locker.NFTPositionNotFound.selector, tokenId));
        locker.register(tokenId, amount0, amount1, INTEGRATOR_FEE_RECEIVER, timelock);
    }

    function test_harvest_WithNoFeesToCollect() public {
        (uint256 tokenId,,,) = test_register_WithLockUpPeriod_InitializesPool();

        (uint256 collectedAmount0, uint256 collectedAmount1) = locker.harvest(tokenId);

        assertEq(collectedAmount0, 0);
        assertEq(collectedAmount1, 0);
        assertEq(tokenFoo.balanceOf(DOPPLER_FEE_RECEIVER), 0);
        assertEq(tokenBar.balanceOf(DOPPLER_FEE_RECEIVER), 0);
        assertEq(tokenFoo.balanceOf(INTEGRATOR_FEE_RECEIVER), 0);
        assertEq(tokenBar.balanceOf(INTEGRATOR_FEE_RECEIVER), 0);
    }

    function test_harvest_WithBothTokenFees() public {
        (uint256 tokenId,,,) = test_register_WithLockUpPeriod_InitializesPool();

        (,, address token0, address token1,,,,,,,,) = NFPM.positions(tokenId);

        IERC20(token0).approve(address(ROUTER_02), type(uint256).max);
        ROUTER_02.exactInputSingle(
            IBaseSwapRouter02.ExactInputSingleParams({
                tokenIn: token0,
                tokenOut: token1,
                fee: FEE_TIER,
                recipient: address(this),
                amountIn: 1e18,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        IERC20(token1).approve(address(ROUTER_02), type(uint256).max);
        ROUTER_02.exactInputSingle(
            IBaseSwapRouter02.ExactInputSingleParams({
                tokenIn: token1,
                tokenOut: token0,
                fee: FEE_TIER,
                recipient: address(this),
                amountIn: 1e18,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        (uint256 collectedAmount0, uint256 collectedAmount1) = locker.harvest(tokenId);

        assertGt(collectedAmount0, 0);
        assertGt(collectedAmount1, 0);

        assertEq(IERC20(token0).balanceOf(DOPPLER_FEE_RECEIVER), collectedAmount0 * 5 / 100);
        assertEq(IERC20(token1).balanceOf(DOPPLER_FEE_RECEIVER), collectedAmount1 * 5 / 100);
        assertEq(IERC20(token0).balanceOf(INTEGRATOR_FEE_RECEIVER), collectedAmount0 - collectedAmount0 * 5 / 100);
        assertEq(IERC20(token1).balanceOf(INTEGRATOR_FEE_RECEIVER), collectedAmount1 - collectedAmount1 * 5 / 100);
    }

    function test_unlock_RevertsWhenPoolNotInitialized() public {
        uint256 nonExistentTokenId = 99_999;
        vm.expectRevert(ICustomUniswapV3Locker.PoolNotInitialized.selector);
        locker.unlock(nonExistentTokenId);
    }

    function test_register_WithZeroAmounts() public {
        tokenFoo.transfer(address(this), 1000e18);
        tokenBar.transfer(address(this), 1000e18);

        (address token0, address token1) = address(tokenFoo) > address(tokenBar)
            ? (address(tokenBar), address(tokenFoo))
            : (address(tokenFoo), address(tokenBar));

        pool = IUniswapV3Pool(FACTORY.createPool(token0, token1, FEE_TIER));
        pool.initialize(Constants.SQRT_PRICE_1_1);

        IERC20(token0).approve(address(NFPM), 1000e18);
        IERC20(token1).approve(address(NFPM), 1000e18);

        (uint256 tokenId,,,) = NFPM.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: FEE_TIER,
                tickLower: -200,
                tickUpper: 200,
                amount0Desired: 1000e18,
                amount1Desired: 1000e18,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(locker),
                deadline: block.timestamp + 3600
            })
        );

        vm.prank(address(migrator));
        locker.register(tokenId, 0, 0, INTEGRATOR_FEE_RECEIVER, timelock);

        (uint256 _amount0, uint256 _amount1,,,) = locker.positionStates(tokenId);
        assertEq(_amount0, 0);
        assertEq(_amount1, 0);
    }

    function test_unlock_CollectsFeesBeforeUnlocking() public {
        (uint256 tokenId,,,) = test_register_WithLockUpPeriod_InitializesPool();

        (,, address token0, address token1,,,,,,,,) = NFPM.positions(tokenId);

        IERC20(token0).approve(address(ROUTER_02), type(uint256).max);
        ROUTER_02.exactInputSingle(
            IBaseSwapRouter02.ExactInputSingleParams({
                tokenIn: token0,
                tokenOut: token1,
                fee: FEE_TIER,
                recipient: address(this),
                amountIn: 1e18,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        vm.warp(block.timestamp + 365 days);

        uint256 dopplerBalanceBefore = IERC20(token0).balanceOf(DOPPLER_FEE_RECEIVER);
        uint256 integratorBalanceBefore = IERC20(token0).balanceOf(INTEGRATOR_FEE_RECEIVER);

        locker.unlock(tokenId);

        assertGt(IERC20(token0).balanceOf(DOPPLER_FEE_RECEIVER), dopplerBalanceBefore);
        assertGt(IERC20(token0).balanceOf(INTEGRATOR_FEE_RECEIVER), integratorBalanceBefore);

        assertEq(NFPM.ownerOf(tokenId), timelock);
    }

    function test_multipleHarvests() public {
        (uint256 tokenId,,,) = test_register_WithLockUpPeriod_InitializesPool();

        (,, address token0, address token1,,,,,,,,) = NFPM.positions(tokenId);

        IERC20(token0).approve(address(ROUTER_02), type(uint256).max);
        ROUTER_02.exactInputSingle(
            IBaseSwapRouter02.ExactInputSingleParams({
                tokenIn: token0,
                tokenOut: token1,
                fee: FEE_TIER,
                recipient: address(this),
                amountIn: 1e18,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        (uint256 firstCollected0,) = locker.harvest(tokenId);
        assertGt(firstCollected0, 0);

        ROUTER_02.exactInputSingle(
            IBaseSwapRouter02.ExactInputSingleParams({
                tokenIn: token0,
                tokenOut: token1,
                fee: FEE_TIER,
                recipient: address(this),
                amountIn: 2e18,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        (uint256 secondCollected0,) = locker.harvest(tokenId);
        assertGt(secondCollected0, 0);

        uint256 totalCollected = firstCollected0 + secondCollected0;
        uint256 expectedDopplerFee = totalCollected * 5 / 100;
        uint256 actualDopplerBalance = IERC20(token0).balanceOf(DOPPLER_FEE_RECEIVER);
        uint256 actualIntegratorBalance = IERC20(token0).balanceOf(INTEGRATOR_FEE_RECEIVER);

        assertApproxEqAbs(actualDopplerBalance, expectedDopplerFee, 1);
        assertApproxEqAbs(actualIntegratorBalance, totalCollected - expectedDopplerFee, 1);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
