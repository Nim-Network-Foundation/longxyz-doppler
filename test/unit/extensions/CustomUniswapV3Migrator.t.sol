// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { ERC20 } from "@openzeppelin/token/ERC20/ERC20.sol";
import { CustomUniswapV3Migrator } from "src/extensions/CustomUniswapV3Migrator.sol";
import { INonfungiblePositionManager } from "src/extensions/interfaces/INonfungiblePositionManager.sol";
import { IUniswapV3Factory, ISwapRouter02 } from "src/extensions/CustomUniswapV3Migrator.sol";
import { MigrationMath } from "src/UniswapV2Migrator.sol";
import { SenderNotAirlock } from "src/base/ImmutableAirlock.sol";
import {
    UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER_BASE,
    UNISWAP_V3_FACTORY_BASE,
    WETH_BASE,
    UNISWAP_V3_ROUTER_02_BASE
} from "test/shared/Addresses.sol";
import { console } from "forge-std/console.sol";
import { Constants } from "@v4-core-test/utils/Constants.sol";

contract CustomUniswapV3MigratorTest is Test {
    CustomUniswapV3Migrator public migrator;

    uint24 constant FEE_TIER = 10_000;
    address constant LOCKER_OWNER = address(0xb055);
    address constant DOPPLER_FEE_RECEIVER = address(0x2222);
    address constant INTEGRATOR_FEE_RECEIVER = address(0x1111);
    int24 constant DEFAULT_LOWER_TICK = 174_312;
    int24 constant DEFAULT_UPPER_TICK = 186_840;
    // int24 constant DEFAULT_LOWER_TICK = 167_520;
    // int24 constant DEFAULT_UPPER_TICK = 200_040;

    bytes public liquidityMigratorData = abi.encode(DEFAULT_LOWER_TICK, DEFAULT_UPPER_TICK, INTEGRATOR_FEE_RECEIVER);

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_MAINNET_RPC_URL"), 31_118_046);
        migrator = new CustomUniswapV3Migrator(
            address(this), // airlock
            INonfungiblePositionManager(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER_BASE),
            ISwapRouter02(UNISWAP_V3_ROUTER_02_BASE),
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

    function test_receive_RevertsWhenETHSenderNotAirlock() public {
        deal(address(0xbeef), 1 ether);
        vm.startPrank(address(0xbeef));
        vm.expectRevert(SenderNotAirlock.selector);
        payable(address(migrator)).transfer(1 ether);
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

    function test_migrate_RevertsWhenSenderNotAirlock() public {
        vm.prank(address(0xbeef));
        vm.expectRevert(SenderNotAirlock.selector);
        migrator.migrate(uint160(0), address(0x1111), address(0x2222), address(0));
    }

    function test_migrate() public {
        TestERC20 token0 = new TestERC20(1000 ether);
        TestERC20 token1 = new TestERC20(1000 ether);

        address pool = migrator.initialize(address(token0), address(token1), liquidityMigratorData);

        token0.transfer(address(migrator), 1000 ether);
        token1.transfer(address(migrator), 1000 ether);

        uint256 liquidity =
            migrator.migrate(Constants.SQRT_PRICE_1_1, address(token0), address(token1), address(0xbeef));

        assertEq(token0.balanceOf(address(migrator)), 0, "Wrong migrator token0 balance");
        assertEq(token1.balanceOf(address(migrator)), 0, "Wrong migrator token1 balance");

        assertEq(token0.balanceOf(pool), 1000 ether, "Wrong pool token0 balance");
        assertEq(token1.balanceOf(pool), 1000 ether, "Wrong pool token1 balance");
    }

    // function test_migrate_KeepsCorrectPrice() public {
    //     TestERC20 token0 = new TestERC20(131_261_409_265_385_327_997_940);
    //     TestERC20 token1 = new TestERC20(16_622_742_685_037);

    //     uint160 sqrtPriceX96 = 3_893_493_510_706_508_098_175_185;

    //     address pool = migrator.initialize(address(token0), address(token1), liquidityMigratorData);

    //     token0.transfer(address(migrator), 13_126_140_926_538_532_799_794);
    //     token1.transfer(address(migrator), 16_622_742_685_037);
    //     migrator.migrate(sqrtPriceX96, address(token0), address(token1), address(0xbeef));
    //     assertEq(token0.balanceOf(address(migrator)), 0, "Wrong migrator token0 balance");
    //     assertEq(token1.balanceOf(address(migrator)), 0, "Wrong migrator token1 balance");
    //     (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(pool).getReserves();
    //     uint256 price = uint256(reserve1) * 2 ** 192 / uint256(reserve0);
    //     assertApproxEqRel(price, uint256(sqrtPriceX96) * uint256(sqrtPriceX96), 0.00000001e18);
    // }

    // function test_migrate(uint256 balance0, uint256 balance1, uint160 sqrtPriceX96) public {
    //     vm.skip(true);
    //     uint256 max = uint256(int256(type(int128).max));

    //     vm.assume(balance0 > 0 && balance0 <= max);
    //     vm.assume(balance1 > 0 && balance1 <= max);
    //     vm.assume(sqrtPriceX96 > TickMath.MIN_SQRT_PRICE && sqrtPriceX96 <= TickMath.MAX_SQRT_PRICE);

    //     TestERC20 token0 = new TestERC20(balance0);
    //     TestERC20 token1 = new TestERC20(balance1);

    //     address pool = migrator.initialize(address(token0), address(token1), liquidityMigratorData);

    //     token0.transfer(address(migrator), balance0);
    //     token1.transfer(address(migrator), balance1);
    //     uint256 liquidity = migrator.migrate(sqrtPriceX96, address(token0), address(token1), address(0xbeef));

    //     assertEq(token0.balanceOf(address(migrator)), 0, "Wrong migrator token0 balance");
    //     assertEq(token1.balanceOf(address(migrator)), 0, "Wrong migrator token1 balance");

    //     assertEq(token0.balanceOf(pool), balance0, "Wrong pool token0 balance");
    //     assertEq(token1.balanceOf(pool), balance1, "Wrong pool token1 balance");

    //     uint256 lockedLiquidity = liquidity / 20;
    //     assertEq(liquidity - lockedLiquidity, IUniswapV2Pair(pool).balanceOf(address(0xbeef)), "Wrong liquidity");
    //     assertEq(lockedLiquidity, IUniswapV2Pair(pool).balanceOf(address(migrator.locker())), "Wrong locked liquidity");
    // }
}
