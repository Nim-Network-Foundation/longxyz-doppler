// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { console } from "forge-std/console.sol";

import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { IPositionManager } from "@v4-periphery/interfaces/IPositionManager.sol";
import { ERC721 } from "@solady/tokens/ERC721.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { BaseTest } from "test/shared/BaseTest.sol";
import { MineV4Params, mineV4 } from "test/shared/AirlockMiner.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { Airlock, ModuleState, CreateParams } from "src/Airlock.sol";
import { DopplerDeployer, UniswapV4Initializer, IPoolInitializer } from "src/UniswapV4Initializer.sol";
import { CustomUniswapV3Migrator, ISwapRouter02 } from "src/extensions/CustomUniswapV3Migrator.sol";
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
    uint24 constant FEE_TIER = 10_000;
    address constant LOCKER_OWNER = address(0xb055);
    address constant DOPPLER_FEE_RECEIVER = address(0x2222);
    address constant INTEGRATOR_FEE_RECEIVER = address(0x1111);

    INonfungiblePositionManager public NFPM;
    ISwapRouter02 public ROUTER_02;

    CustomUniswapV3Migrator public migrator;
    Airlock public airlock;
    DopplerDeployer public deployer;
    UniswapV4Initializer public initializer;
    TokenFactory public tokenFactory;
    GovernanceFactory public governanceFactory;

    function test_migrate_v3() public {
        vm.createSelectFork(vm.envString("BASE_MAINNET_RPC_URL"), 31_118_046);

        airlock = new Airlock(address(this));
        deployer = new DopplerDeployer(manager);
        initializer = new UniswapV4Initializer(address(airlock), manager, deployer);
        NFPM = INonfungiblePositionManager(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER_BASE);
        ROUTER_02 = ISwapRouter02(UNISWAP_V3_ROUTER_02_BASE);
        migrator =
            new CustomUniswapV3Migrator(address(airlock), NFPM, ROUTER_02, LOCKER_OWNER, DOPPLER_FEE_RECEIVER, FEE_TIER);
        tokenFactory = new TokenFactory(address(airlock));
        governanceFactory = new GovernanceFactory(address(airlock));

        address integrator = makeAddr("integrator");

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

        uint256 initialSupply = 1_000_000_000 ether;

        bytes memory tokenFactoryData =
            abi.encode("Test Token", "TEST", 0, 0, new address[](0), new uint256[](0), "TOKEN_URI");
        bytes memory poolInitializerData = abi.encode(
            DEFAULT_MINIMUM_PROCEEDS,
            DEFAULT_MAXIMUM_PROCEEDS,
            block.timestamp,
            block.timestamp + 1 days,
            DEFAULT_START_TICK,
            DEFAULT_END_TICK,
            DEFAULT_EPOCH_LENGTH,
            DEFAULT_GAMMA,
            false,
            DEFAULT_NUM_PD_SLUGS,
            DEFAULT_FEE,
            DEFAULT_TICK_SPACING
        );

        bytes memory liquidityMigratorData = abi.encode(INTEGRATOR_FEE_RECEIVER);

        MineV4Params memory params = MineV4Params({
            airlock: address(airlock),
            poolManager: address(manager),
            initialSupply: initialSupply,
            numTokensToSell: DEFAULT_NUM_TOKENS_TO_SELL,
            numeraire: address(0),
            tokenFactory: ITokenFactory(address(tokenFactory)),
            tokenFactoryData: tokenFactoryData,
            poolInitializer: UniswapV4Initializer(address(initializer)),
            poolInitializerData: poolInitializerData
        });

        (bytes32 salt, address hook, address asset) = mineV4(params);

        CreateParams memory createParams = CreateParams({
            initialSupply: initialSupply,
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

        (, address pool, address governance, address timelock, address migrationPool) = airlock.create(createParams);

        bool canMigrated;

        uint256 i;

        do {
            i++;
            deal(address(this), 0.1 ether);

            (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks) =
                Doppler(payable(hook)).poolKey();

            BalanceDelta delta = swapRouter.swap{ value: 0.0001 ether }(
                PoolKey({ currency0: currency0, currency1: currency1, hooks: hooks, fee: fee, tickSpacing: tickSpacing }),
                IPoolManager.SwapParams(true, -int256(0.0001 ether), TickMath.MIN_SQRT_PRICE + 1),
                PoolSwapTest.TestSettings(false, false),
                ""
            );

            (,,, uint256 totalProceeds,,) = Doppler(payable(hook)).state();
            canMigrated = totalProceeds > Doppler(payable(hook)).minimumProceeds();

            vm.warp(block.timestamp + 200);
        } while (!canMigrated);

        // goToEndingTime();
        airlock.migrate(asset);

        assertEq(ERC721(address(NFPM)).balanceOf(timelock), 1, "Timelock should have one token");
        assertEq(ERC721(address(NFPM)).ownerOf(2), timelock, "Timelock should be the owner of the token");
        assertEq(
            ERC721(address(NFPM)).balanceOf(address(migrator.CUSTOM_V3_LOCKER())), 1, "Locker should have one token"
        );
        assertEq(
            ERC721(address(NFPM)).ownerOf(1),
            address(migrator.CUSTOM_V3_LOCKER()),
            "Locker should be the owner of the token"
        );
    }
}
