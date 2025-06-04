// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";

interface ICustomUniswapV3Migrator is ILiquidityMigrator {
    error EmptyLiquidityMigratorData();
    error ZeroFeeReceiverAddress();
    error PoolDoesNotExist();
    error TickNotDivisible(int24 tick, int24 tickSpacing);
    error TickOutOfRange(int24 tick, int24 lowerTick, int24 upperTick);
}
