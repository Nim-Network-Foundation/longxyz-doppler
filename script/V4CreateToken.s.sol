// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { IUniswapV2Router02 } from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Router02.sol";
import {
    Airlock,
    ModuleState,
    CreateParams,
    ITokenFactory,
    IGovernanceFactory,
    IPoolInitializer,
    ILiquidityMigrator
} from "src/Airlock.sol";
import { TokenFactory } from "src/TokenFactory.sol";
import { GovernanceFactory } from "src/GovernanceFactory.sol";
import { UniswapV4Initializer } from "src/UniswapV4Initializer.sol";
import { IUniswapV2Router02 } from "src/UniswapV2Migrator.sol";
import { DERC20 } from "src/DERC20.sol";
import { MineV4Params, mineV4 } from "test/shared/AirlockMiner.sol";

struct Params {
    Airlock airlock;
    ITokenFactory tokenFactory;
    IGovernanceFactory governanceFactory;
    IPoolInitializer poolInitializer;
    ILiquidityMigrator liquidityMigrator;
    address weth;
}

string constant NAME = "WL_LONG";
string constant SYMBOL = "WL_LONG";
string constant TOKEN_URI = "https://ipfs.io/ipfs/QmNcnhCp2P1sM7K44aBhzcdDGAhS4Jvagqofi5Cfs46n6d";

uint256 constant INITIAL_SUPPLY = 1_000_000_000 ether;
uint256 constant MAX_SHARE_TO_BE_SOLD = 0.9 ether;

uint256 constant DEFAULT_MINIMUM_PROCEEDS = 6.65 ether;
uint256 constant DEFAULT_MAXIMUM_PROCEEDS = 9.2 ether;

uint256 constant SALE_DURATION = 6 hours;
uint256 constant DEFAULT_EPOCH_LENGTH = 200 seconds;
uint256 constant DEFAULT_NUM_PD_SLUGS = 10;

int24 constant DEFAULT_START_TICK = 175_848;
int24 constant DEFAULT_END_TICK = 186_840;
int24 constant DEFAULT_TICK_SPACING = 8;
int24 constant DEFAULT_GAMMA = 800;
uint24 constant DEFAULT_FEE = 20_000;
uint256 constant DEFAULT_NUM_TOKENS_TO_SELL = 600_000_000 ether;

address constant UNISWAP_V4_POOL_MANAGER_BASE_SEPOLIA = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
address constant UNISWAP_V4_POOL_MANAGER_BASE = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
address constant LONG_INTEGRATOR = 0xCCF7582371b4d6e3a77FFD423D1E9500EBD041Ac;

contract V4CreateTokenScript is Script {
    function run() public {
        Params memory params = Params({
            airlock: Airlock(payable(address(0xAa7f55aB611Ea07A6D4F4D58a05F4338C52e494b))),
            tokenFactory: ITokenFactory(address(0x3cc915e3cee3fE5cfce02eDb86835AEe4F64d076)),
            governanceFactory: IGovernanceFactory(address(0xA7a3b84EF1C52a442fCFaA02acaf8b1DF2DCE3b6)),
            poolInitializer: IPoolInitializer(address(0x7727f8353A30f9753CF8bF7489dAF0ef038900bA)),
            liquidityMigrator: ILiquidityMigrator(address(0x2c8afbc476421649215AD1eC1AE20345e2510dd5)),
            weth: address(0x4200000000000000000000000000000000000006)
        });
        require(SALE_DURATION % DEFAULT_EPOCH_LENGTH == 0, "Sale duration must be divisible by epoch length");

        vm.startBroadcast();
        _deployToken(params);
        vm.stopBroadcast();
    }

    function _deployToken(
        Params memory params
    ) internal {
        // Will be set later on
        bool isToken0 = false;

        /**
         * Governance data is encoded as follows:
         * string memory name,
         * uint48 initialVotingDelay,
         * uint32 initialVotingPeriod,
         * uint256 initialProposalThreshold
         */
        bytes memory governanceData = abi.encode(NAME, 7200, 50_400, INITIAL_SUPPLY / 1000);

        /**
         * Token factory data is encoded as follows:
         * string memory name,
         * string memory symbol,
         * uint256 yearlyMintCap,
         * uint256 vestingDuration,
         * address[] memory recipients,
         * uint256[] memory amounts,
         * string memory tokenURI
         */
        bytes memory tokenFactoryData = abi.encode(NAME, SYMBOL, 0, 0, new address[](0), new uint256[](0), TOKEN_URI);

        /**
         * V4 Pool initializer data is encoded as follows:
         * uint256 minimumProceeds,
         * uint256 maximumProceeds,
         * uint256 startingTime,
         * uint256 endingTime,
         * int24 startingTick,
         * int24 endingTick,
         * uint256 epochLength,
         * int24 gamma,
         * bool isToken0,
         * uint256 numPDSlugs,
         * uint24 lpFee,
         * int24 tickSpacing
         */
        bytes memory poolInitializerData = abi.encode(
            DEFAULT_MINIMUM_PROCEEDS,
            DEFAULT_MAXIMUM_PROCEEDS,
            block.timestamp + 30 seconds,
            block.timestamp + SALE_DURATION + 30 seconds,
            DEFAULT_START_TICK,
            DEFAULT_END_TICK,
            DEFAULT_EPOCH_LENGTH,
            DEFAULT_GAMMA,
            isToken0,
            DEFAULT_NUM_PD_SLUGS,
            DEFAULT_FEE,
            DEFAULT_TICK_SPACING
        );

        bytes memory liquidityMigratorData = abi.encode(0.05 ether, 0xCCF7582371b4d6e3a77FFD423D1E9500EBD041Ac, 30 days);

        (bytes32 salt,,) = mineV4(
            MineV4Params({
                airlock: address(params.airlock),
                poolManager: UNISWAP_V4_POOL_MANAGER_BASE,
                initialSupply: INITIAL_SUPPLY,
                numTokensToSell: DEFAULT_NUM_TOKENS_TO_SELL,
                numeraire: address(0),
                tokenFactory: params.tokenFactory,
                tokenFactoryData: tokenFactoryData,
                poolInitializer: UniswapV4Initializer(address(params.poolInitializer)),
                poolInitializerData: poolInitializerData
            })
        );

        (address asset, address doppler, address governance, address timelock, address migrationPool) = params
            .airlock
            .create(
            CreateParams({
                initialSupply: INITIAL_SUPPLY,
                numTokensToSell: DEFAULT_NUM_TOKENS_TO_SELL,
                numeraire: address(0),
                tokenFactory: params.tokenFactory,
                tokenFactoryData: tokenFactoryData,
                governanceFactory: params.governanceFactory,
                governanceFactoryData: governanceData,
                poolInitializer: params.poolInitializer,
                poolInitializerData: poolInitializerData,
                liquidityMigrator: params.liquidityMigrator,
                liquidityMigratorData: liquidityMigratorData,
                integrator: LONG_INTEGRATOR,
                salt: salt
            })
        );

        console.log("\n");
        console.log("Token deployed at: %s", asset);
        console.log("Doppler deployed at: %s", doppler);
        console.log("Governance deployed at: %s", governance);
        console.log("Timelock deployed at: %s", timelock);
        console.log("Migration pool deployed at: %s", migrationPool);
    }
}
