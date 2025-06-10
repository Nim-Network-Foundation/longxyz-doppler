// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test, console } from "forge-std/Test.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { ERC20 } from "@openzeppelin/token/ERC20/ERC20.sol";
import { IERC721 } from "@openzeppelin/token/ERC721/IERC721.sol";
import { CustomUniswapV3Migrator } from "src/extensions/CustomUniswapV3Migrator.sol";
import { ICustomUniswapV3Migrator } from "src/extensions/interfaces/ICustomUniswapV3Migrator.sol";
import { INonfungiblePositionManager } from "src/extensions/interfaces/INonfungiblePositionManager.sol";
import { IUniswapV3Factory, IBaseSwapRouter02 } from "src/extensions/CustomUniswapV3Migrator.sol";
import { IUniswapV3Pool } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import { SenderNotAirlock } from "src/base/ImmutableAirlock.sol";
import { CustomUniswapV3Locker } from "src/extensions/CustomUniswapV3Locker.sol";
import {
    UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER_BASE,
    UNISWAP_V3_FACTORY_BASE,
    WETH_BASE,
    UNISWAP_V3_ROUTER_02_BASE
} from "test/shared/Addresses.sol";

contract CustomUniswapV3MigratorTest is Test {
    CustomUniswapV3Migrator public migrator;
    IUniswapV3Factory public factory;
    INonfungiblePositionManager public nfpm;

    uint24 constant FEE_TIER = 10_000;
    address constant LOCKER_OWNER = address(0xb055);
    address constant DOPPLER_FEE_RECEIVER = address(0x2222);
    address constant INTEGRATOR_FEE_RECEIVER = address(0x1111);

    bytes public liquidityMigratorData = abi.encode(INTEGRATOR_FEE_RECEIVER);

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_MAINNET_RPC_URL"), 31_118_046);

        factory = IUniswapV3Factory(UNISWAP_V3_FACTORY_BASE);
        nfpm = INonfungiblePositionManager(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER_BASE);

        migrator = new CustomUniswapV3Migrator(
            address(this),
            nfpm,
            IBaseSwapRouter02(UNISWAP_V3_ROUTER_02_BASE),
            LOCKER_OWNER,
            DOPPLER_FEE_RECEIVER,
            FEE_TIER
        );
    }

    function test_receive_ReceivesETHFromAirlock() public {
        uint256 preBalance = address(migrator).balance;
        deal(address(this), 1 ether);
        payable(address(migrator)).transfer(1 ether);
        assertEq(address(migrator).balance, preBalance + 1 ether, "Wrong balance");
    }

    function test_migrate_RevertsWhenSenderNotAirlock() public {
        vm.prank(address(0xbeef));
        vm.expectRevert(SenderNotAirlock.selector);
        migrator.migrate(uint160(0), address(0x1111), address(0x2222), address(0));
    }

    function test_initialize_CreatesPair() public {
        address token0 = address(0x1111);
        address token1 = address(0x2222);
        address pair = migrator.initialize(token0, token1, liquidityMigratorData);
        assertEq(pair, IUniswapV3Factory(UNISWAP_V3_FACTORY_BASE).getPool(token0, token1, FEE_TIER), "Wrong pair");
    }

    function test_initialize_DoesNotFailWhenPairIsAlreadyCreated() public {
        address token0 = address(0x1111);
        address token1 = address(0x2222);
        IUniswapV3Factory(UNISWAP_V3_FACTORY_BASE).createPool(token0, token1, FEE_TIER);
        address pair = migrator.initialize(token0, token1, liquidityMigratorData);
        assertEq(pair, IUniswapV3Factory(UNISWAP_V3_FACTORY_BASE).getPool(token0, token1, FEE_TIER), "Wrong pair");
    }

    function test_initialize_RevertsWithEmptyData() public {
        vm.expectRevert(abi.encodeWithSelector(ICustomUniswapV3Migrator.EmptyLiquidityMigratorData.selector));
        migrator.initialize(address(0x1111), address(0x2222), "");
    }

    function test_initialize_RevertsWithZeroFeeReceiver() public {
        bytes memory invalidData = abi.encode(address(0));
        vm.expectRevert(abi.encodeWithSelector(ICustomUniswapV3Migrator.ZeroFeeReceiverAddress.selector));
        migrator.initialize(address(0x1111), address(0x2222), invalidData);
    }

    function test_initialize_UsesWETHForNumeraireZero() public {
        TestERC20 token = new TestERC20(1e30);

        address pool = migrator.initialize(address(token), address(0), liquidityMigratorData);

        address weth = address(migrator.WETH());
        (address token0, address token1) = address(token) < weth ? (address(token), weth) : (weth, address(token));

        assertEq(pool, IUniswapV3Factory(UNISWAP_V3_FACTORY_BASE).getPool(token0, token1, FEE_TIER), "Wrong pool");
    }

    function test_initialize_InitializesPoolAtExtremePrice() public {
        TestERC20 tokenA = new TestERC20(1e30);
        TestERC20 tokenB = new TestERC20(1e30);

        (address token0, address token1) =
            address(tokenA) < address(tokenB) ? (address(tokenA), address(tokenB)) : (address(tokenB), address(tokenA));

        address pool = migrator.initialize(token0, token1, liquidityMigratorData);

        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

        // Should be at extreme tick (min or max depending on token order)
        int24 tickSpacing = 200; // for 10000 fee tier
        int24 expectedTick = address(tokenA) == token0
            ? TickMath.minUsableTick(tickSpacing) + tickSpacing
            : TickMath.maxUsableTick(tickSpacing) - tickSpacing;

        assertEq(tick, expectedTick, "Pool should be initialized at extreme tick");
    }

    function test_onERC721Received() public view {
        bytes4 result = migrator.onERC721Received(address(0), address(0), 0, "");
        assertEq(result, migrator.onERC721Received.selector, "Wrong selector returned");
    }

    function test_poolFeeReceivers() public {
        address token0 = address(0x3333);
        address token1 = address(0x4444);

        address pool = migrator.initialize(token0, token1, liquidityMigratorData);
        assertEq(migrator.poolFeeReceivers(pool), INTEGRATOR_FEE_RECEIVER, "Wrong fee receiver");
    }

    function test_constantValues() public view {
        assertEq(address(migrator.NONFUNGIBLE_POSITION_MANAGER()), UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER_BASE);
        assertEq(address(migrator.FACTORY()), UNISWAP_V3_FACTORY_BASE);
        assertEq(address(migrator.ROUTER()), UNISWAP_V3_ROUTER_02_BASE);
        assertEq(address(migrator.WETH()), WETH_BASE);
        assertEq(migrator.FEE_TIER(), FEE_TIER);
        assertTrue(address(migrator.CUSTOM_V3_LOCKER()) != address(0), "Locker should be deployed");
    }

    function test_migrate_BasicScenario() public {
        uint24 testFeeTier = 3000;
        CustomUniswapV3Migrator testMigrator = new CustomUniswapV3Migrator(
            address(this),
            INonfungiblePositionManager(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER_BASE),
            IBaseSwapRouter02(UNISWAP_V3_ROUTER_02_BASE),
            LOCKER_OWNER,
            DOPPLER_FEE_RECEIVER,
            testFeeTier
        );

        TestERC20 token0 = new TestERC20(type(uint256).max);
        TestERC20 token1 = new TestERC20(type(uint256).max);

        address factory = address(testMigrator.FACTORY());
        (address tokenA, address tokenB) =
            address(token0) < address(token1) ? (address(token0), address(token1)) : (address(token1), address(token0));

        IUniswapV3Factory(factory).createPool(tokenA, tokenB, testFeeTier);
        address pool = IUniswapV3Factory(factory).getPool(tokenA, tokenB, testFeeTier);

        testMigrator.initialize(tokenA, tokenB, liquidityMigratorData);

        token0.transfer(address(testMigrator), 1e24);
        token1.transfer(address(testMigrator), 1e24);

        uint160 sqrtPriceX96_1_1 = 79_228_162_514_264_337_593_543_950_336; // sqrt(1) * 2^96
        uint256 liquidity = testMigrator.migrate(sqrtPriceX96_1_1, tokenA, tokenB, address(0xbeef));

        assertGt(liquidity, 0, "Should have created liquidity");

        assertEq(
            IERC721(address(testMigrator.CUSTOM_V3_LOCKER().NONFUNGIBLE_POSITION_MANAGER())).balanceOf(
                address(testMigrator.CUSTOM_V3_LOCKER())
            ),
            1,
            "Locker should have 1 NFT"
        );
    }

    function test_migrate_RevertsWhenPoolDoesNotExist() public {
        TestERC20 token0 = new TestERC20(1e30);
        TestERC20 token1 = new TestERC20(1e30);

        token0.transfer(address(migrator), 1e28);
        token1.transfer(address(migrator), 1e28);

        uint160 sqrtPriceX96_1_1 = 79_228_162_514_264_337_593_543_950_336; // sqrt(1) * 2^96
        vm.expectRevert(abi.encodeWithSelector(ICustomUniswapV3Migrator.PoolDoesNotExist.selector));
        migrator.migrate(sqrtPriceX96_1_1, address(token0), address(token1), address(0xbeef));
    }

    function test_migrate_RefundExcessTokens() public {
        uint24 testFeeTier = 3000;
        CustomUniswapV3Migrator testMigrator = new CustomUniswapV3Migrator(
            address(this),
            INonfungiblePositionManager(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER_BASE),
            IBaseSwapRouter02(UNISWAP_V3_ROUTER_02_BASE),
            LOCKER_OWNER,
            DOPPLER_FEE_RECEIVER,
            testFeeTier
        );

        TestERC20 token0 = new TestERC20(type(uint256).max);
        TestERC20 token1 = new TestERC20(type(uint256).max);

        address factory = address(testMigrator.FACTORY());
        (address tokenA, address tokenB) =
            address(token0) < address(token1) ? (address(token0), address(token1)) : (address(token1), address(token0));
        IUniswapV3Factory(factory).createPool(tokenA, tokenB, testFeeTier);

        testMigrator.initialize(tokenA, tokenB, liquidityMigratorData);

        uint256 amount0 = 1e24;
        uint256 amount1 = 1.1e24;
        token0.transfer(address(testMigrator), amount0);
        token1.transfer(address(testMigrator), amount1);

        uint256 airlockToken0BalanceBefore = token0.balanceOf(address(this));
        uint256 airlockToken1BalanceBefore = token1.balanceOf(address(this));

        uint160 sqrtPriceX96_1_1 = 79_228_162_514_264_337_593_543_950_336; // sqrt(1) * 2^96
        testMigrator.migrate(sqrtPriceX96_1_1, tokenA, tokenB, address(0xbeef));

        assertTrue(
            token0.balanceOf(address(this)) > airlockToken0BalanceBefore
                || token1.balanceOf(address(this)) > airlockToken1BalanceBefore,
            "Should have received some token refund"
        );
    }

    function test_migrate_SimpleCase_NoRebalance() public {
        TestERC20 tokenA = new TestERC20(type(uint256).max);
        TestERC20 tokenB = new TestERC20(type(uint256).max);

        (address token0, address token1) =
            address(tokenA) < address(tokenB) ? (address(tokenA), address(tokenB)) : (address(tokenB), address(tokenA));

        factory.createPool(token0, token1, FEE_TIER);
        address pool = factory.getPool(token0, token1, FEE_TIER);

        migrator.initialize(token0, token1, liquidityMigratorData);

        tokenA.transfer(address(migrator), 1e24);
        tokenB.transfer(address(migrator), 1e24);

        uint160 targetPrice = 79_228_162_514_264_337_593_543_950_336;
        uint256 liquidity = migrator.migrate(targetPrice, token0, token1, address(0xbeef));

        assertGt(liquidity, 0, "Should have created liquidity");

        (uint160 poolPrice,,,,,,) = IUniswapV3Pool(pool).slot0();
        assertEq(poolPrice, targetPrice, "Pool should be at target price");

        CustomUniswapV3Locker locker = migrator.CUSTOM_V3_LOCKER();
        assertEq(IERC721(address(nfpm)).balanceOf(address(locker)), 1, "Locker should have 1 NFT");

        assertEq(tokenA.balanceOf(address(migrator)), 0, "No tokenA left");
        assertEq(tokenB.balanceOf(address(migrator)), 0, "No tokenB left");
    }

    function test_migrate_WithRebalance() public {
        uint24 testFeeTier = 100;

        CustomUniswapV3Migrator testMigrator = new CustomUniswapV3Migrator(
            address(this),
            nfpm,
            IBaseSwapRouter02(UNISWAP_V3_ROUTER_02_BASE),
            LOCKER_OWNER,
            DOPPLER_FEE_RECEIVER,
            testFeeTier
        );

        TestERC20 tokenA = new TestERC20(type(uint256).max);
        TestERC20 tokenB = new TestERC20(type(uint256).max);

        (address token0, address token1) =
            address(tokenA) < address(tokenB) ? (address(tokenA), address(tokenB)) : (address(tokenB), address(tokenA));

        address pool = testMigrator.initialize(token0, token1, liquidityMigratorData);

        (uint160 initialPrice,,,,,,) = IUniswapV3Pool(pool).slot0();
        int24 initialTick = TickMath.getTickAtSqrtPrice(initialPrice);
        console.log("Initial tick:", initialTick);

        uint256 amount0 = 1000e18;
        uint256 amount1 = 1000e18;

        if (address(tokenA) == token0) {
            tokenA.transfer(address(testMigrator), amount0);
            tokenB.transfer(address(testMigrator), amount1);
        } else {
            tokenA.transfer(address(testMigrator), amount1);
            tokenB.transfer(address(testMigrator), amount0);
        }

        uint160 targetPrice = 79_228_162_514_264_337_593_543_950_336;

        uint256 liquidity = testMigrator.migrate(targetPrice, token0, token1, address(0xbeef));

        assertGt(liquidity, 0, "Should have created liquidity");

        CustomUniswapV3Locker locker = testMigrator.CUSTOM_V3_LOCKER();
        assertEq(IERC721(address(nfpm)).balanceOf(address(locker)), 1, "Locker should have 1 NFT after migration");
    }

    function test_migrate_ETHHandling() public {
        address weth = address(migrator.WETH());
        TestERC20 token = new TestERC20(type(uint256).max);

        (address token0, address token1) = address(token) < weth ? (address(token), weth) : (weth, address(token));

        factory.createPool(token0, token1, FEE_TIER);

        migrator.initialize(address(token), address(0), liquidityMigratorData);

        deal(address(migrator), 10 ether);

        token.transfer(address(migrator), 10e18);

        uint256 ethBefore = address(migrator).balance;
        assertEq(ethBefore, 10 ether, "Should have ETH");

        uint160 targetPrice = 79_228_162_514_264_337_593_543_950_336;
        uint256 liquidity = migrator.migrate(targetPrice, token0, token1, address(0xbeef));

        assertGt(liquidity, 0, "Should have created liquidity");
        assertEq(address(migrator).balance, 0, "ETH should be wrapped");
    }

    function test_migrate_DustRefund() public {
        TestERC20 tokenA = new TestERC20(type(uint256).max);
        TestERC20 tokenB = new TestERC20(type(uint256).max);

        (address token0, address token1) =
            address(tokenA) < address(tokenB) ? (address(tokenA), address(tokenB)) : (address(tokenB), address(tokenA));

        factory.createPool(token0, token1, FEE_TIER);

        migrator.initialize(token0, token1, liquidityMigratorData);

        uint256 amount0 = 1e24 + 123_456_789;
        uint256 amount1 = 1e24 + 987_654_321;

        if (address(tokenA) == token0) {
            tokenA.transfer(address(migrator), amount0);
            tokenB.transfer(address(migrator), amount1);
        } else {
            tokenA.transfer(address(migrator), amount1);
            tokenB.transfer(address(migrator), amount0);
        }

        uint256 balance0Before = ERC20(token0).balanceOf(address(this));
        uint256 balance1Before = ERC20(token1).balanceOf(address(this));

        uint160 targetPrice = 79_228_162_514_264_337_593_543_950_336;
        migrator.migrate(targetPrice, token0, token1, address(0xbeef));

        uint256 balance0After = ERC20(token0).balanceOf(address(this));
        uint256 balance1After = ERC20(token1).balanceOf(address(this));

        assertTrue(balance0After > balance0Before || balance1After > balance1Before, "Should have received dust refund");
    }

    function test_migrate_VerifyPositionDetails() public {
        TestERC20 tokenA = new TestERC20(type(uint256).max);
        TestERC20 tokenB = new TestERC20(type(uint256).max);

        (address token0, address token1) =
            address(tokenA) < address(tokenB) ? (address(tokenA), address(tokenB)) : (address(tokenB), address(tokenA));

        factory.createPool(token0, token1, FEE_TIER);

        migrator.initialize(token0, token1, liquidityMigratorData);

        tokenA.transfer(address(migrator), 1e24);
        tokenB.transfer(address(migrator), 1e24);

        uint160 targetPrice = 79_228_162_514_264_337_593_543_950_336;
        migrator.migrate(targetPrice, token0, token1, address(0xbeef));

        CustomUniswapV3Locker locker = migrator.CUSTOM_V3_LOCKER();

        uint256 balance = IERC721(address(nfpm)).balanceOf(address(locker));
        assertGt(balance, 0, "Locker should have NFT");
    }

    function testFuzz_initialize_WithVariousAddresses(
        address asset,
        address numeraire,
        address integratorFeeReceiver
    ) public {
        vm.assume(asset != address(0));
        vm.assume(integratorFeeReceiver != address(0));
        vm.assume(asset != numeraire);

        vm.assume(uint160(asset) > 255);
        vm.assume(uint160(numeraire) > 255 || numeraire == address(0));
        vm.assume(uint160(integratorFeeReceiver) > 255);

        bytes memory fuzzData = abi.encode(integratorFeeReceiver);

        address pool = migrator.initialize(asset, numeraire, fuzzData);

        // Verify pool was created/found
        address expectedNumeraire = numeraire == address(0) ? address(migrator.WETH()) : numeraire;
        (address token0, address token1) =
            asset < expectedNumeraire ? (asset, expectedNumeraire) : (expectedNumeraire, asset);

        assertEq(pool, factory.getPool(token0, token1, FEE_TIER), "Pool address mismatch");
        assertEq(migrator.poolFeeReceivers(pool), integratorFeeReceiver, "Fee receiver mismatch");
    }

    function testFuzz_migrate_WithVariousPrices(
        uint160 targetSqrtPriceX96
    ) public {
        uint256 bounded = bound(
            uint256(targetSqrtPriceX96),
            uint256(79_228_162_514_264_337_593_543_950_336) / 100, // 0.01x price
            uint256(79_228_162_514_264_337_593_543_950_336) * 100 // 100x price
        );
        targetSqrtPriceX96 = uint160(bounded);

        TestERC20 tokenA = new TestERC20(type(uint256).max);
        TestERC20 tokenB = new TestERC20(type(uint256).max);

        (address token0, address token1) =
            address(tokenA) < address(tokenB) ? (address(tokenA), address(tokenB)) : (address(tokenB), address(tokenA));

        migrator.initialize(token0, token1, liquidityMigratorData);

        uint256 amount = 1e24;
        tokenA.transfer(address(migrator), amount);
        tokenB.transfer(address(migrator), amount);

        uint256 liquidity = migrator.migrate(targetSqrtPriceX96, token0, token1, address(0xbeef));

        assertGt(liquidity, 0, "Should have created liquidity");

        CustomUniswapV3Locker locker = migrator.CUSTOM_V3_LOCKER();
        assertEq(IERC721(address(nfpm)).balanceOf(address(locker)), 1, "Locker should have 1 NFT");
    }

    function testFuzz_migrate_WithVariousAmounts(uint128 amount0, uint128 amount1) public {
        amount0 = uint128(bound(amount0, 1e18, 1e30));
        amount1 = uint128(bound(amount1, 1e18, 1e30));

        TestERC20 tokenA = new TestERC20(type(uint256).max);
        TestERC20 tokenB = new TestERC20(type(uint256).max);

        (address token0, address token1) =
            address(tokenA) < address(tokenB) ? (address(tokenA), address(tokenB)) : (address(tokenB), address(tokenA));

        migrator.initialize(token0, token1, liquidityMigratorData);

        if (address(tokenA) == token0) {
            tokenA.transfer(address(migrator), amount0);
            tokenB.transfer(address(migrator), amount1);
        } else {
            tokenA.transfer(address(migrator), amount1);
            tokenB.transfer(address(migrator), amount0);
        }

        uint256 balanceBefore0 = ERC20(token0).balanceOf(address(this));
        uint256 balanceBefore1 = ERC20(token1).balanceOf(address(this));

        uint160 sqrtPriceX96_1_1 = 79_228_162_514_264_337_593_543_950_336;
        uint256 liquidity = migrator.migrate(sqrtPriceX96_1_1, token0, token1, address(0xbeef));

        assertGt(liquidity, 0, "Should have created liquidity");

        uint256 balanceAfter0 = ERC20(token0).balanceOf(address(this));
        uint256 balanceAfter1 = ERC20(token1).balanceOf(address(this));

        if (amount0 != amount1) {
            assertTrue(
                balanceAfter0 > balanceBefore0 || balanceAfter1 > balanceBefore1,
                "Should have received refund when amounts differ"
            );
        }
    }

    function testFuzz_migrate_AtVariousTicks(
        int24 targetTick
    ) public {
        uint24 testFeeTier = 500;
        int24 tickSpacing = 10;

        targetTick = int24(bound(targetTick, -46_000, 46_000));

        targetTick = (targetTick / tickSpacing) * tickSpacing;

        CustomUniswapV3Migrator testMigrator = new CustomUniswapV3Migrator(
            address(this),
            nfpm,
            IBaseSwapRouter02(UNISWAP_V3_ROUTER_02_BASE),
            LOCKER_OWNER,
            DOPPLER_FEE_RECEIVER,
            testFeeTier
        );

        TestERC20 tokenA = new TestERC20(type(uint256).max);
        TestERC20 tokenB = new TestERC20(type(uint256).max);

        (address token0, address token1) =
            address(tokenA) < address(tokenB) ? (address(tokenA), address(tokenB)) : (address(tokenB), address(tokenA));

        testMigrator.initialize(token0, token1, liquidityMigratorData);

        tokenA.transfer(address(testMigrator), 1e24);
        tokenB.transfer(address(testMigrator), 1e24);

        uint160 targetSqrtPriceX96 = TickMath.getSqrtPriceAtTick(targetTick);

        uint256 liquidity = testMigrator.migrate(targetSqrtPriceX96, token0, token1, address(0xbeef));

        assertGt(liquidity, 0, "Should have created liquidity");

        address pool = factory.getPool(token0, token1, testFeeTier);
        (uint160 currentSqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
        assertEq(currentSqrtPriceX96, targetSqrtPriceX96, "Pool should be at target price");
    }

    function testFuzz_refundDust_WithVariousAmounts(uint256 excessAmount0, uint256 excessAmount1) public {
        excessAmount0 = bound(excessAmount0, 0, 1e20);
        excessAmount1 = bound(excessAmount1, 0, 1e20);

        vm.assume(excessAmount0 != 0 || excessAmount1 != 0);

        uint256 baseAmount = 1e24;

        TestERC20 tokenA = new TestERC20(type(uint256).max);
        TestERC20 tokenB = new TestERC20(type(uint256).max);

        (address token0, address token1) =
            address(tokenA) < address(tokenB) ? (address(tokenA), address(tokenB)) : (address(tokenB), address(tokenA));

        migrator.initialize(token0, token1, liquidityMigratorData);

        uint256 totalAmount0 = baseAmount + excessAmount0;
        uint256 totalAmount1 = baseAmount + excessAmount1;

        if (address(tokenA) == token0) {
            tokenA.transfer(address(migrator), totalAmount0);
            tokenB.transfer(address(migrator), totalAmount1);
        } else {
            tokenA.transfer(address(migrator), totalAmount1);
            tokenB.transfer(address(migrator), totalAmount0);
        }

        uint256 balanceBefore0 = ERC20(token0).balanceOf(address(this));
        uint256 balanceBefore1 = ERC20(token1).balanceOf(address(this));

        uint160 sqrtPriceX96_1_1 = 79_228_162_514_264_337_593_543_950_336;
        migrator.migrate(sqrtPriceX96_1_1, token0, token1, address(0xbeef));

        uint256 refund0 = ERC20(token0).balanceOf(address(this)) - balanceBefore0;
        uint256 refund1 = ERC20(token1).balanceOf(address(this)) - balanceBefore1;

        assertTrue(refund0 > 0 || refund1 > 0, "Should receive some refund");

        assertEq(ERC20(token0).balanceOf(address(migrator)), 0, "Migrator should have no token0");
        assertEq(ERC20(token1).balanceOf(address(migrator)), 0, "Migrator should have no token1");
    }
}
