// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";

interface ICustomUniswapV3Migrator is ILiquidityMigrator {
    error EmptyLiquidityMigratorData();
    error ZeroFeeReceiverAddress();
    error PoolDoesNotExist();
    error RebalanceFailed();
    error InvalidPoolCallback();
}
