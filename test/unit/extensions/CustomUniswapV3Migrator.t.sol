// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";
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
import {
    UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER_BASE,
    UNISWAP_V3_FACTORY_BASE,
    WETH_BASE,
    UNISWAP_V3_ROUTER_02_BASE
} from "test/shared/Addresses.sol";

contract CustomUniswapV3MigratorHarness is CustomUniswapV3Migrator {
    constructor(
        address airlock_,
        INonfungiblePositionManager positionManager_,
        IBaseSwapRouter02 router,
        address owner,
        address dopplerFeeReceiver_,
        uint24 feeTier_
    ) CustomUniswapV3Migrator(airlock_, positionManager_, router, owner, dopplerFeeReceiver_, feeTier_) {}
    
    function getDivisibleTick(int24 tick, int24 tickSpacing, bool isUpper) external pure returns (int24) {
        return _getDivisibleTick(tick, tickSpacing, isUpper);
    }
}

contract CustomUniswapV3MigratorTest is Test {
    CustomUniswapV3Migrator public migrator;

    uint24 constant FEE_TIER = 10_000;
    address constant LOCKER_OWNER = address(0xb055);
    address constant DOPPLER_FEE_RECEIVER = address(0x2222);
    address constant INTEGRATOR_FEE_RECEIVER = address(0x1111);

    bytes public liquidityMigratorData = abi.encode(INTEGRATOR_FEE_RECEIVER);

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_MAINNET_RPC_URL"), 31_118_046);
        migrator = new CustomUniswapV3Migrator(
            address(this), // airlock
            INonfungiblePositionManager(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER_BASE),
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

    function test_receive_RevertsWhenETHSenderNotAirlock() public {
        deal(address(0xbeef), 1 ether);
        vm.startPrank(address(0xbeef));
        vm.expectRevert("Only Airlock or Router");
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

    function test_migrate_RevertsWhenPoolDoesNotExist() public {
        TestERC20 token0 = new TestERC20(1e30);
        TestERC20 token1 = new TestERC20(1e30);

        token0.transfer(address(migrator), 1e28);
        token1.transfer(address(migrator), 1e28);
        
        uint160 sqrtPriceX96_1_1 = 79228162514264337593543950336; // sqrt(1) * 2^96
        vm.expectRevert(abi.encodeWithSelector(ICustomUniswapV3Migrator.PoolDoesNotExist.selector));
        migrator.migrate(sqrtPriceX96_1_1, address(token0), address(token1), address(0xbeef));
    }

    function test_onERC721Received() public view {
        bytes4 result = migrator.onERC721Received(address(0), address(0), 0, "");
        assertEq(result, migrator.onERC721Received.selector, "Wrong selector returned");
    }

    function test_getDivisibleTick() public {
        CustomUniswapV3MigratorHarness harness = new CustomUniswapV3MigratorHarness(
            address(this),
            INonfungiblePositionManager(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER_BASE),
            IBaseSwapRouter02(UNISWAP_V3_ROUTER_02_BASE),
            LOCKER_OWNER,
            DOPPLER_FEE_RECEIVER,
            FEE_TIER
        );
        
        int24 tickSpacing = 200;
        
        // Test tick already divisible
        assertEq(harness.getDivisibleTick(400, tickSpacing, false), 400);
        assertEq(harness.getDivisibleTick(400, tickSpacing, true), 400);
        
        // Test rounding down
        assertEq(harness.getDivisibleTick(450, tickSpacing, false), 400);
        
        // Test rounding up
        assertEq(harness.getDivisibleTick(450, tickSpacing, true), 600);
        
        // Test zero tick
        assertEq(harness.getDivisibleTick(0, tickSpacing, false), 0);
        assertEq(harness.getDivisibleTick(0, tickSpacing, true), tickSpacing);
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

    function test_poolFeeReceivers() public {
        address token0 = address(0x3333);
        address token1 = address(0x4444);

        address pool = migrator.initialize(token0, token1, liquidityMigratorData);
        assertEq(migrator.poolFeeReceivers(pool), INTEGRATOR_FEE_RECEIVER, "Wrong fee receiver");
    }

    function test_initialize_UsesWETHForNumeraireZero() public {
        TestERC20 token = new TestERC20(1e30);

        address pool = migrator.initialize(address(token), address(0), liquidityMigratorData);
        
        address weth = address(migrator.WETH());
        (address token0, address token1) = address(token) < weth ? (address(token), weth) : (weth, address(token));
        
        assertEq(pool, IUniswapV3Factory(UNISWAP_V3_FACTORY_BASE).getPool(token0, token1, FEE_TIER), "Wrong pool");
    }
}