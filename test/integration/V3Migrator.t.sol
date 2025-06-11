// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { console } from "forge-std/console.sol";

import { ERC721 } from "@solady/tokens/ERC721.sol";
import { ERC20 } from "@solady/tokens/ERC20.sol";
import { WETH as IWETH } from "@solmate/tokens/WETH.sol";
import { IUniswapV3Factory } from "@v3-core/interfaces/IUniswapV3Factory.sol";
import { IUniswapV3Pool } from "@v3-core/interfaces/IUniswapV3Pool.sol";
import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { IPositionManager } from "@v4-periphery/interfaces/IPositionManager.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { BaseTest } from "test/shared/BaseTest.sol";
import { MineV4Params, mineV4 } from "test/shared/AirlockMiner.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { Airlock, ModuleState, CreateParams } from "src/Airlock.sol";
import { DopplerDeployer, UniswapV4Initializer, IPoolInitializer } from "src/UniswapV4Initializer.sol";
import { CustomUniswapV3Migrator, IBaseSwapRouter02 } from "src/extensions/CustomUniswapV3Migrator.sol";
import { TokenFactory, ITokenFactory } from "src/TokenFactory.sol";
import { GovernanceFactory, IGovernanceFactory } from "src/GovernanceFactory.sol";
import { Doppler } from "src/Doppler.sol";
import { CustomUniswapV3Locker } from "src/extensions/CustomUniswapV3Locker.sol";
import { INonfungiblePositionManager } from "src/extensions/interfaces/INonfungiblePositionManager.sol";
import {
    UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER_BASE,
    UNISWAP_V3_FACTORY_BASE,
    WETH_BASE,
    UNISWAP_V3_ROUTER_02_BASE
} from "test/shared/Addresses.sol";

contract V3MigratorTest is BaseTest {
    using StateLibrary for IPoolManager;

    uint24 constant FEE_TIER = 10_000;
    address constant DOPPLER_FEE_RECEIVER = address(0x2222);
    address constant INTEGRATOR_FEE_RECEIVER = address(0x1111);

    INonfungiblePositionManager public NFPM;
    IBaseSwapRouter02 public ROUTER_02;

    CustomUniswapV3Migrator public migrator;
    Airlock public airlock;
    DopplerDeployer public deployer;
    UniswapV4Initializer public initializer;
    TokenFactory public tokenFactory;
    GovernanceFactory public governanceFactory;

    // Test data
    uint256 constant INITIAL_SUPPLY = 1_000_000_000 ether;
    bytes tokenFactoryData;
    bytes poolInitializerData;

    function setUp() public override {
        vm.createSelectFork(vm.envString("BASE_MAINNET_RPC_URL"), 31_118_046);

        // Small hack here, requires cleanup
        DEFAULT_DOPPLER_CONFIG.startingTime = vm.getBlockTimestamp();
        DEFAULT_DOPPLER_CONFIG.endingTime = vm.getBlockTimestamp() + SALE_DURATION;
        super.setUp();

        // Initialize test data
        tokenFactoryData = abi.encode("Test Token", "TEST", 0, 0, new address[](0), new uint256[](0), "TOKEN_URI");
        poolInitializerData = abi.encode(
            DEFAULT_MINIMUM_PROCEEDS,
            DEFAULT_MAXIMUM_PROCEEDS,
            block.timestamp,
            block.timestamp + SALE_DURATION,
            DEFAULT_START_TICK,
            DEFAULT_END_TICK,
            DEFAULT_EPOCH_LENGTH,
            DEFAULT_GAMMA,
            false,
            DEFAULT_NUM_PD_SLUGS,
            DEFAULT_FEE,
            DEFAULT_TICK_SPACING
        );
    }

    function test_migrate_v3() public {
        address integrator = _setupContracts();
        bytes memory liquidityMigratorData = abi.encode(INTEGRATOR_FEE_RECEIVER);

        (, address hook, address asset,,,, address migrationPool) = _createPool(integrator, liquidityMigratorData);

        // (uint160 currentSqrtPriceX96,,,,,,) = IUniswapV3Pool(migrationPool).slot0();
        // console.log("Current sqrt price:", currentSqrtPriceX96);
        // console.log("Current tick:", TickMath.getTickAtSqrtPrice(currentSqrtPriceX96));

        // Perform enough swaps to reach minimum proceeds
        _executeSwapsToMinProceeds(hook);

        // Now advance to end time to allow migration
        vm.warp(vm.getBlockTimestamp() + SALE_DURATION + 1);

        (,,, uint256 finalProceeds,,) = Doppler(payable(hook)).state();
        console.log("Final proceeds:", finalProceeds, "Minimum:", Doppler(payable(hook)).minimumProceeds());
        console.log("Ending time:", Doppler(payable(hook)).endingTime());
        console.log("Warp-ed timestamp:", block.timestamp);

        airlock.migrate(asset);

        assertEq(ERC721(address(NFPM)).balanceOf(address(migrator.CUSTOM_V3_LOCKER())), 1, "Locker should have one NFT");
    }

    function test_migrate_v3_dustRefund() public {
        address integrator = _setupContracts();
        bytes memory liquidityMigratorData = abi.encode(INTEGRATOR_FEE_RECEIVER);

        (, address hook, address asset,,, address timelock,) = _createPool(integrator, liquidityMigratorData);

        // Execute minimal swaps
        _executeMinimalSwapsToMinProceeds(hook);

        // Advance to end time
        vm.warp(vm.getBlockTimestamp() + SALE_DURATION + 1);

        // Get balances before migration
        uint256 timelockAssetBalanceBefore = ERC20(asset).balanceOf(timelock);
        uint256 timelockWETHBalanceBefore = ERC20(address(migrator.WETH())).balanceOf(timelock);

        // Migrate
        airlock.migrate(asset);

        uint256 timelockAssetBalanceAfter = ERC20(asset).balanceOf(timelock);
        uint256 timelockWETHBalanceAfter = ERC20(address(migrator.WETH())).balanceOf(timelock);

        bool hasDust = (timelockAssetBalanceAfter > timelockAssetBalanceBefore)
            || (timelockWETHBalanceAfter > timelockWETHBalanceBefore);
        assertTrue(hasDust, "Timelock should receive dust tokens");
    }

    function test_migrate_v3_poolCreation() public {
        uint24 differentFeeTier = 500; // 0.05% - this tier should not exist yet
        (address integrator, CustomUniswapV3Migrator testMigrator) = _setupContractsWithCustomMigrator(differentFeeTier);

        bytes memory liquidityMigratorData = abi.encode(INTEGRATOR_FEE_RECEIVER);

        (,, address asset,,,, address migrationPool) = _createPool(integrator, liquidityMigratorData);

        // Verify pool was created during initialization
        address weth = address(testMigrator.WETH());
        address token0 = asset < weth ? asset : weth;
        address token1 = asset < weth ? weth : asset;
        address createdPool = IUniswapV3Factory(UNISWAP_V3_FACTORY_BASE).getPool(token0, token1, differentFeeTier);
        assertEq(createdPool, migrationPool, "Pool should have been created");
    }

    function test_migrate_v3_feeReceiverRegistration() public {
        address integrator = _setupContracts();
        address customIntegratorFeeReceiver = makeAddr("customIntegratorFeeReceiver");
        bytes memory liquidityMigratorData = abi.encode(customIntegratorFeeReceiver);

        (, address hook, address asset,,,, address migrationPool) = _createPool(integrator, liquidityMigratorData);

        // Verify fee receiver was registered
        assertEq(
            migrator.poolFeeReceivers(migrationPool), customIntegratorFeeReceiver, "Fee receiver should be registered"
        );

        // Execute swaps to reach minimum proceeds
        _executeMinimalSwapsToMinProceeds(hook);

        // Advance to end time and migrate
        vm.warp(vm.getBlockTimestamp() + SALE_DURATION + 1);
        airlock.migrate(asset);

        assertGt(
            ERC721(address(NFPM)).balanceOf(address(migrator.CUSTOM_V3_LOCKER())),
            0,
            "Locker should have received NFT position"
        );
    }

    function _setupContracts() internal returns (address integrator) {
        integrator = makeAddr("integrator");

        airlock = new Airlock(address(this));
        deployer = new DopplerDeployer(manager);
        initializer = new UniswapV4Initializer(address(airlock), manager, deployer);
        NFPM = INonfungiblePositionManager(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER_BASE);
        ROUTER_02 = IBaseSwapRouter02(UNISWAP_V3_ROUTER_02_BASE);
        migrator = new CustomUniswapV3Migrator(address(airlock), NFPM, ROUTER_02, DOPPLER_FEE_RECEIVER, FEE_TIER);
        tokenFactory = new TokenFactory(address(airlock));
        governanceFactory = new GovernanceFactory(address(airlock));

        _setupModules();
    }

    function _setupContractsWithCustomMigrator(
        uint24 feeTier
    ) internal returns (address integrator, CustomUniswapV3Migrator customMigrator) {
        integrator = makeAddr("integrator");

        airlock = new Airlock(address(this));
        deployer = new DopplerDeployer(manager);
        initializer = new UniswapV4Initializer(address(airlock), manager, deployer);
        NFPM = INonfungiblePositionManager(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER_BASE);
        ROUTER_02 = IBaseSwapRouter02(UNISWAP_V3_ROUTER_02_BASE);
        customMigrator = new CustomUniswapV3Migrator(address(airlock), NFPM, ROUTER_02, DOPPLER_FEE_RECEIVER, feeTier);
        tokenFactory = new TokenFactory(address(airlock));
        governanceFactory = new GovernanceFactory(address(airlock));

        migrator = customMigrator;
        _setupModules();
    }

    function _setupModules() internal {
        address[] memory modules = new address[](4);
        modules[0] = address(tokenFactory);
        modules[1] = address(governanceFactory);
        modules[2] = address(initializer);
        modules[3] = address(migrator);

        ModuleState[] memory states = new ModuleState[](4);
        states[0] = ModuleState.TokenFactory;
        states[1] = ModuleState.GovernanceFactory;
        states[2] = ModuleState.PoolInitializer;
        states[3] = ModuleState.LiquidityMigrator;

        airlock.setModuleState(modules, states);
    }

    function _createPool(
        address integrator,
        bytes memory liquidityMigratorData
    )
        internal
        returns (
            bytes32 salt,
            address hook,
            address asset,
            address pool,
            address governance,
            address timelock,
            address migrationPool
        )
    {
        MineV4Params memory params = MineV4Params({
            airlock: address(airlock),
            poolManager: address(manager),
            initialSupply: INITIAL_SUPPLY,
            numTokensToSell: DEFAULT_NUM_TOKENS_TO_SELL,
            numeraire: address(0),
            tokenFactory: ITokenFactory(address(tokenFactory)),
            tokenFactoryData: tokenFactoryData,
            poolInitializer: UniswapV4Initializer(address(initializer)),
            poolInitializerData: poolInitializerData
        });

        (salt, hook, asset) = mineV4(params);

        CreateParams memory createParams = CreateParams({
            initialSupply: INITIAL_SUPPLY,
            numTokensToSell: DEFAULT_NUM_TOKENS_TO_SELL,
            numeraire: address(0),
            tokenFactory: ITokenFactory(tokenFactory),
            tokenFactoryData: tokenFactoryData,
            governanceFactory: IGovernanceFactory(governanceFactory),
            governanceFactoryData: abi.encode("Test Token", 7200, 50_400, 0),
            poolInitializer: IPoolInitializer(initializer),
            poolInitializerData: poolInitializerData,
            liquidityMigrator: ILiquidityMigrator(migrator),
            liquidityMigratorData: liquidityMigratorData,
            integrator: integrator,
            salt: salt
        });

        (, pool, governance, timelock, migrationPool) = airlock.create(createParams);
    }

    function _executeSwapsToMinProceeds(
        address hook
    ) internal {
        (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks) =
            Doppler(payable(hook)).poolKey();

        PoolKey memory poolKey =
            PoolKey({ currency0: currency0, currency1: currency1, hooks: hooks, fee: fee, tickSpacing: tickSpacing });

        uint256 swapCount = 0;
        while (true) {
            swapCount++;
            if (swapCount > 100) {
                revert("Too many swaps, test failed");
            }

            uint256 swapAmount = 1 ether + (swapCount * 1 ether);
            deal(address(this), swapAmount);

            (uint160 currentSqrtPrice,,,) = manager.getSlot0(poolKey.toId());
            uint160 priceLimit = currentSqrtPrice > 1000 ? currentSqrtPrice - 1000 : TickMath.MIN_SQRT_PRICE + 1;

            swapRouter.swap{ value: swapAmount }(
                poolKey,
                IPoolManager.SwapParams(true, -int256(swapAmount), priceLimit),
                PoolSwapTest.TestSettings(false, false),
                ""
            );

            (,,, uint256 totalProceeds,,) = Doppler(payable(hook)).state();
            if (totalProceeds >= Doppler(payable(hook)).minimumProceeds()) {
                break;
            }

            vm.warp(vm.getBlockTimestamp() + 200);
        }
    }

    function _executeMinimalSwapsToMinProceeds(
        address hook
    ) internal {
        (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks) =
            Doppler(payable(hook)).poolKey();

        PoolKey memory poolKey =
            PoolKey({ currency0: currency0, currency1: currency1, hooks: hooks, fee: fee, tickSpacing: tickSpacing });

        while (true) {
            uint256 swapAmount = 10 ether;
            deal(address(this), swapAmount);

            (uint160 currentSqrtPrice,,,) = manager.getSlot0(poolKey.toId());
            uint160 priceLimit = currentSqrtPrice > 1000 ? currentSqrtPrice - 1000 : TickMath.MIN_SQRT_PRICE + 1;

            swapRouter.swap{ value: swapAmount }(
                poolKey,
                IPoolManager.SwapParams(true, -int256(swapAmount), priceLimit),
                PoolSwapTest.TestSettings(false, false),
                ""
            );

            (,,, uint256 totalProceeds,,) = Doppler(payable(hook)).state();
            if (totalProceeds >= Doppler(payable(hook)).minimumProceeds()) {
                break;
            }

            vm.warp(vm.getBlockTimestamp() + 200);
        }
    }

    function testFuzz_migrate_v3_withVariousFeeTiers(
        uint24 feeTier
    ) public {
        vm.assume(feeTier == 500 || feeTier == 3000 || feeTier == 10_000);

        (address integrator, CustomUniswapV3Migrator testMigrator) = _setupContractsWithCustomMigrator(feeTier);
        bytes memory liquidityMigratorData = abi.encode(INTEGRATOR_FEE_RECEIVER);

        (, address hook, address asset,,,, address migrationPool) = _createPool(integrator, liquidityMigratorData);

        address weth = address(testMigrator.WETH());
        address token0 = asset < weth ? asset : weth;
        address token1 = asset < weth ? weth : asset;
        address createdPool = IUniswapV3Factory(UNISWAP_V3_FACTORY_BASE).getPool(token0, token1, feeTier);
        assertEq(createdPool, migrationPool, "Pool should have been created with correct fee tier");

        _executeMinimalSwapsToMinProceeds(hook);
        vm.warp(vm.getBlockTimestamp() + SALE_DURATION + 1);
        airlock.migrate(asset);

        assertGt(
            ERC721(address(NFPM)).balanceOf(address(testMigrator.CUSTOM_V3_LOCKER())),
            0,
            "Locker should have NFT position"
        );
    }

    function testFuzz_migrate_v3_withVariousSwapAmounts(
        uint256 swapAmount1,
        uint256 swapAmount2,
        uint256 swapAmount3
    ) public {
        // Bound swap amounts to reasonable range
        swapAmount1 = bound(swapAmount1, 0.1 ether, 100 ether);
        swapAmount2 = bound(swapAmount2, 0.1 ether, 100 ether);
        swapAmount3 = bound(swapAmount3, 0.1 ether, 100 ether);

        address integrator = _setupContracts();
        bytes memory liquidityMigratorData = abi.encode(INTEGRATOR_FEE_RECEIVER);

        (, address hook, address asset,,,,) = _createPool(integrator, liquidityMigratorData);

        // Execute fuzzed swaps
        _executeFuzzedSwaps(hook, swapAmount1, swapAmount2, swapAmount3);

        // Advance to end time and migrate
        vm.warp(vm.getBlockTimestamp() + SALE_DURATION + 1);

        (,,, uint256 totalProceeds,,) = Doppler(payable(hook)).state();

        // Only migrate if minimum proceeds were reached
        if (totalProceeds >= Doppler(payable(hook)).minimumProceeds()) {
            airlock.migrate(asset);
            assertGt(
                ERC721(address(NFPM)).balanceOf(address(migrator.CUSTOM_V3_LOCKER())),
                0,
                "Locker should have NFT position"
            );
        }
    }

    function testFuzz_migrate_v3_withVariousFeeReceivers(
        address feeReceiver
    ) public {
        vm.assume(feeReceiver != address(0));
        vm.assume(uint160(feeReceiver) > 255); // Not a precompile

        address integrator = _setupContracts();
        bytes memory liquidityMigratorData = abi.encode(feeReceiver);

        (, address hook, address asset,,,, address migrationPool) = _createPool(integrator, liquidityMigratorData);

        // Verify fee receiver was registered
        assertEq(migrator.poolFeeReceivers(migrationPool), feeReceiver, "Fee receiver should match");

        // Execute swaps and migrate
        _executeMinimalSwapsToMinProceeds(hook);
        vm.warp(vm.getBlockTimestamp() + SALE_DURATION + 1);
        airlock.migrate(asset);

        assertGt(
            ERC721(address(NFPM)).balanceOf(address(migrator.CUSTOM_V3_LOCKER())), 0, "Locker should have NFT position"
        );
    }

    function testFuzz_migrate_v3_withVariousTimings(
        uint256 swapDelay1,
        uint256 swapDelay2,
        uint256 migrationDelay
    ) public {
        swapDelay1 = bound(swapDelay1, 100, 3600);
        swapDelay2 = bound(swapDelay2, 100, 3600);
        migrationDelay = bound(migrationDelay, 1, 86_400);

        address integrator = _setupContracts();
        bytes memory liquidityMigratorData = abi.encode(INTEGRATOR_FEE_RECEIVER);

        (, address hook, address asset,,,,) = _createPool(integrator, liquidityMigratorData);

        _executeSwapsWithDelays(hook, swapDelay1, swapDelay2);

        vm.warp(Doppler(payable(hook)).endingTime() + migrationDelay);

        (,,, uint256 totalProceeds,,) = Doppler(payable(hook)).state();

        if (totalProceeds >= Doppler(payable(hook)).minimumProceeds()) {
            airlock.migrate(asset);
            assertGt(
                ERC721(address(NFPM)).balanceOf(address(migrator.CUSTOM_V3_LOCKER())),
                0,
                "Locker should have NFT position"
            );
        }
    }

    function _executeFuzzedSwaps(address hook, uint256 amount1, uint256 amount2, uint256 amount3) internal {
        (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks) =
            Doppler(payable(hook)).poolKey();

        PoolKey memory poolKey =
            PoolKey({ currency0: currency0, currency1: currency1, hooks: hooks, fee: fee, tickSpacing: tickSpacing });

        uint256[3] memory amounts = [amount1, amount2, amount3];

        for (uint256 i = 0; i < 3; i++) {
            if (amounts[i] > 0) {
                deal(address(this), amounts[i]);

                (uint160 currentSqrtPrice,,,) = manager.getSlot0(poolKey.toId());
                uint160 priceLimit;
                if (currentSqrtPrice > TickMath.MIN_SQRT_PRICE + 1000) {
                    priceLimit = currentSqrtPrice - 1000;
                } else {
                    priceLimit = TickMath.MIN_SQRT_PRICE + 1;
                }

                try swapRouter.swap{ value: amounts[i] }(
                    poolKey,
                    IPoolManager.SwapParams(true, -int256(amounts[i]), priceLimit),
                    PoolSwapTest.TestSettings(false, false),
                    ""
                ) { } catch {
                    continue;
                }

                vm.warp(vm.getBlockTimestamp() + 200);
            }
        }
    }

    function _executeSwapsWithDelays(address hook, uint256 delay1, uint256 delay2) internal {
        (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks) =
            Doppler(payable(hook)).poolKey();

        PoolKey memory poolKey =
            PoolKey({ currency0: currency0, currency1: currency1, hooks: hooks, fee: fee, tickSpacing: tickSpacing });

        uint256 swapAmount = 5 ether;
        deal(address(this), swapAmount);

        (uint160 currentSqrtPrice,,,) = manager.getSlot0(poolKey.toId());
        uint160 priceLimit;
        if (currentSqrtPrice > TickMath.MIN_SQRT_PRICE + 1000) {
            priceLimit = currentSqrtPrice - 1000;
        } else {
            priceLimit = TickMath.MIN_SQRT_PRICE + 1;
        }

        try swapRouter.swap{ value: swapAmount }(
            poolKey,
            IPoolManager.SwapParams(true, -int256(swapAmount), priceLimit),
            PoolSwapTest.TestSettings(false, false),
            ""
        ) { } catch { }

        vm.warp(vm.getBlockTimestamp() + delay1);

        (,,, uint256 totalProceeds,,) = Doppler(payable(hook)).state();
        if (totalProceeds < Doppler(payable(hook)).minimumProceeds()) {
            // Second swap
            deal(address(this), swapAmount);
            (currentSqrtPrice,,,) = manager.getSlot0(poolKey.toId());
            if (currentSqrtPrice > TickMath.MIN_SQRT_PRICE + 1000) {
                priceLimit = currentSqrtPrice - 1000;
            } else {
                priceLimit = TickMath.MIN_SQRT_PRICE + 1;
            }

            try swapRouter.swap{ value: swapAmount }(
                poolKey,
                IPoolManager.SwapParams(true, -int256(swapAmount), priceLimit),
                PoolSwapTest.TestSettings(false, false),
                ""
            ) { } catch { }

            vm.warp(vm.getBlockTimestamp() + delay2);

            while (true) {
                (,,, totalProceeds,,) = Doppler(payable(hook)).state();
                if (totalProceeds >= Doppler(payable(hook)).minimumProceeds()) {
                    break;
                }

                deal(address(this), swapAmount);
                (currentSqrtPrice,,,) = manager.getSlot0(poolKey.toId());
                if (currentSqrtPrice > TickMath.MIN_SQRT_PRICE + 1000) {
                    priceLimit = currentSqrtPrice - 1000;
                } else {
                    priceLimit = TickMath.MIN_SQRT_PRICE + 1;
                }

                try swapRouter.swap{ value: swapAmount }(
                    poolKey,
                    IPoolManager.SwapParams(true, -int256(swapAmount), priceLimit),
                    PoolSwapTest.TestSettings(false, false),
                    ""
                ) { } catch {
                    break;
                }

                vm.warp(vm.getBlockTimestamp() + 200);
            }
        }
    }
}
