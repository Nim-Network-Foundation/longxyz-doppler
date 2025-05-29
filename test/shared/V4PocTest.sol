// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolManager, IPoolManager } from "@v4-core/PoolManager.sol";
import { IV4Quoter } from "@v4-periphery/lens/V4Quoter.sol";
import { DopplerLensTest } from "test/unit/DopplerLens.t.sol";
import { BaseTest } from "test/shared/BaseTest.sol";
import { State } from "src/Doppler.sol";
import { MigrationMath } from "src/libs/MigrationMath.sol";
import { DopplerLensReturnData } from "src/lens/DopplerLens.sol";

interface IERC20 {
    function balanceOf(
        address account
    ) external view returns (uint256);
}

using StateLibrary for IPoolManager;

contract V4PocTest is DopplerLensTest {
    function test_buy_InitHighDemandThenFixedBuyUntilMaxProceed() public {
        // Go to starting time
        vm.warp(hook.startingTime());

        DopplerLensReturnData memory oriLensData = lensQuoter.quoteDopplerLensData(
            IV4Quoter.QuoteExactSingleParams({ poolKey: key, zeroForOne: !isToken0, exactAmount: 1, hookData: "" })
        );

        uint160 oriSqrtPriceX96 = oriLensData.sqrtPriceX96;

        console.log("\n-------------- CURRENT CONFIG ------------------");
        console.log("ori token left in pool", IERC20(asset).balanceOf(address(manager)));
        console.log("ori token left in hook", IERC20(asset).balanceOf(address(hook)));
        console.log("ori sqrtPriceX96", oriSqrtPriceX96);
        console.log("starting tick", hook.startingTick());
        console.log("ending tick", hook.endingTick());
        console.log("gamma", hook.gamma());
        console.log("\n");
        console.log("numeraire ", numeraire);
        console.log("asset ", asset);
        console.log("isToken0 ", isToken0);
        console.log("usingEth ", usingEth);
        console.log("total epochs", hook.getTotalEpochs());
        console.log("current epoch", hook.getCurrentEpoch());

        uint256 totalEpochs = SALE_DURATION / DEFAULT_EPOCH_LENGTH;

        uint256 HIGH_DEMAND_BUY_AMOUNT = 1 ether;
        uint256 HIGH_DEMAND_EPOCHS = 3;
        uint256 BUY_ETH_AMOUNT = 0.5 ether;

        uint256 totalEthProceeds;
        uint256 count = 1;

        // consecutive buy with same size in each epoch
        while (totalEthProceeds < DEFAULT_MAXIMUM_PROCEEDS) {
            require(
                count <= totalEpochs,
                string.concat(
                    "exceeding num of total epochs ", vm.toString(totalEpochs), ", please use a bigger BUY_ETH_AMOUNT"
                )
            );

            uint256 tokenBought;
            try lensQuoter.quoteDopplerLensData(
                IV4Quoter.QuoteExactSingleParams({
                    poolKey: key,
                    zeroForOne: !isToken0,
                    exactAmount: count <= HIGH_DEMAND_EPOCHS ? uint128(HIGH_DEMAND_BUY_AMOUNT) : uint128(BUY_ETH_AMOUNT),
                    hookData: ""
                })
            ) {
                (tokenBought,) =
                    count <= HIGH_DEMAND_EPOCHS ? buy(-int256(HIGH_DEMAND_BUY_AMOUNT)) : buy(-int256(BUY_ETH_AMOUNT));
            } catch (bytes memory) {
                console.log("\n");
                console.log("REVERTED, stopped the simulation.");
                break;
            }

            (,, uint256 totalTokensSold, uint256 totalProceeds,,) = hook.state();

            totalEthProceeds = totalProceeds;

            uint160 sqrtPriceX96;
            int24 tick;

            try lensQuoter.quoteDopplerLensData(
                IV4Quoter.QuoteExactSingleParams({ poolKey: key, zeroForOne: !isToken0, exactAmount: 1, hookData: "" })
            ) {
                DopplerLensReturnData memory lensData = lensQuoter.quoteDopplerLensData(
                    IV4Quoter.QuoteExactSingleParams({
                        poolKey: key,
                        zeroForOne: !isToken0,
                        exactAmount: 1,
                        hookData: ""
                    })
                );
                sqrtPriceX96 = lensData.sqrtPriceX96;
                tick = lensData.tick;
            } catch (bytes memory) {
                (sqrtPriceX96, tick,,) = manager.getSlot0(key.toId());
            }

            console.log("\n-------------- SALE No. %d ------------------", count);
            console.log("current epoch", hook.getCurrentEpoch());
            console.log("token bought", tokenBought);
            console.log("totalTokensSold / circulating supply", totalTokensSold);
            console.log("totalProceeds", totalProceeds);
            console.log("\n");
            console.log("sqrtPriceX96(ethPerOneToken)", sqrtPriceX96);
            console.log("tick(tokenPerOneETH)", tick);
            console.log("isEarlyExit", hook.earlyExit());

            vm.warp(hook.startingTime() + hook.epochLength() * count); // go to next epoch
            count++;
        }

        require(hook.earlyExit(), "didn't migrate as expected");
        vm.prank(hook.initializer());
        (uint160 migrationSqrtPriceX96,, uint128 fees0,,, uint128 fees1,) = hook.migrate(address(0xbeef));

        uint256 tokenMigrated = IERC20(asset).balanceOf(address(0xbeef));
        uint256 ethMigrated = address(0xbeef).balance;

        console.log("\n-------------- MIGRATION RESULT ------------------");
        console.log("ETH migrated: ", ethMigrated);
        console.log("Token migrated: ", tokenMigrated);

        uint256 ethMigratedMinusFee = ethMigrated - fees0;
        uint256 tokenMigratedMinusFee = tokenMigrated - fees1;

        (uint256 depositAmount0, uint256 depositAmount1) =
            MigrationMath.computeDepositAmounts(ethMigratedMinusFee, tokenMigratedMinusFee, migrationSqrtPriceX96);

        if (depositAmount1 > tokenMigrated) {
            (, depositAmount1) =
                MigrationMath.computeDepositAmounts(depositAmount0, tokenMigrated, migrationSqrtPriceX96);
        } else {
            (depositAmount0,) =
                MigrationMath.computeDepositAmounts(ethMigratedMinusFee, depositAmount1, migrationSqrtPriceX96);
        }

        // uint256 ethLQToLock = depositAmount0 / 20;
        // uint256 tokenLQToLock = depositAmount1 / 20;
        // uint256 liquidity = sqrt(depositAmount0 * depositAmount1);

        // console.log("ethLQToLock LP for Locker", ethLQToLock);
        // console.log("tokenLQToLock LP for Locker", tokenLQToLock);
        console.log("\n");
        console.log("total ETH in v2 LP: ", depositAmount0);
        console.log("total token in v2 LP: ", depositAmount1);
        console.log("\n");
        console.log("ETH in timelock: ", ethMigratedMinusFee - depositAmount0);
        console.log("token in timelock: ", tokenMigratedMinusFee - depositAmount1);
        // console.log("ETH in Uni v2 LP for timelock", depositAmount0 - ethLQToLock);
        // console.log("token in Uni v2 LP for timelock", depositAmount1 - tokenLQToLock);
        // console.log("liquidity", liquidity);
    }

    function test_buy_FixedBuyAtEachEpochUntilMaxProceed() public {
        // Go to starting time
        vm.warp(hook.startingTime());

        DopplerLensReturnData memory oriLensData = lensQuoter.quoteDopplerLensData(
            IV4Quoter.QuoteExactSingleParams({ poolKey: key, zeroForOne: !isToken0, exactAmount: 1, hookData: "" })
        );

        uint160 oriSqrtPriceX96 = oriLensData.sqrtPriceX96;

        console.log("\n-------------- CURRENT CONFIG ------------------");
        console.log("ori token left in pool", IERC20(asset).balanceOf(address(manager)));
        console.log("ori token left in hook", IERC20(asset).balanceOf(address(hook)));
        console.log("ori sqrtPriceX96", oriSqrtPriceX96);
        console.log("starting tick", hook.startingTick());
        console.log("ending tick", hook.endingTick());
        console.log("gamma", hook.gamma());
        console.log("\n");
        console.log("numeraire ", numeraire);
        console.log("asset ", asset);
        console.log("isToken0 ", isToken0);
        console.log("usingEth ", usingEth);
        console.log("total epochs", hook.getTotalEpochs());
        console.log("current epoch", hook.getCurrentEpoch());

        uint256 totalEpochs = SALE_DURATION / DEFAULT_EPOCH_LENGTH;

        uint256 BUY_ETH_AMOUNT = 0.5 ether;

        uint256 totalEthProceeds;
        uint256 count = 1;

        // consecutive buy with same size in each epoch
        while (totalEthProceeds < DEFAULT_MAXIMUM_PROCEEDS) {
            require(
                count <= totalEpochs,
                string.concat(
                    "exceeding num of total epochs ", vm.toString(totalEpochs), ", please use a bigger BUY_ETH_AMOUNT"
                )
            );

            uint256 tokenBought;
            try lensQuoter.quoteDopplerLensData(
                IV4Quoter.QuoteExactSingleParams({
                    poolKey: key,
                    zeroForOne: !isToken0,
                    exactAmount: uint128(BUY_ETH_AMOUNT),
                    hookData: ""
                })
            ) {
                (tokenBought,) = buy(-int256(BUY_ETH_AMOUNT));
            } catch (bytes memory) {
                console.log("\n");
                console.log("REVERTED, stopped the simulation.");
                break;
            }

            (,, uint256 totalTokensSold, uint256 totalProceeds,,) = hook.state();

            totalEthProceeds = totalProceeds;

            uint160 sqrtPriceX96;
            int24 tick;

            try lensQuoter.quoteDopplerLensData(
                IV4Quoter.QuoteExactSingleParams({ poolKey: key, zeroForOne: !isToken0, exactAmount: 1, hookData: "" })
            ) {
                DopplerLensReturnData memory lensData = lensQuoter.quoteDopplerLensData(
                    IV4Quoter.QuoteExactSingleParams({
                        poolKey: key,
                        zeroForOne: !isToken0,
                        exactAmount: 1,
                        hookData: ""
                    })
                );
                sqrtPriceX96 = lensData.sqrtPriceX96;
                tick = lensData.tick;
            } catch (bytes memory) {
                (sqrtPriceX96, tick,,) = manager.getSlot0(key.toId());
            }

            console.log("\n-------------- SALE No. %d ------------------", count);
            console.log("current epoch", hook.getCurrentEpoch());
            console.log("token bought", tokenBought);
            console.log("totalTokensSold / circulating supply", totalTokensSold);
            console.log("totalProceeds", totalProceeds);
            console.log("\n");
            console.log("sqrtPriceX96(ethPerOneToken)", sqrtPriceX96);
            console.log("tick(tokenPerOneETH)", tick);
            console.log("isEarlyExit", hook.earlyExit());

            vm.warp(hook.startingTime() + hook.epochLength() * count); // go to next epoch
            count++;
        }

        require(hook.earlyExit(), "didn't migrate as expected");
        vm.prank(hook.initializer());

        uint256 tokenMigrateB4 = IERC20(asset).balanceOf(address(0xbeef));
        uint256 ethMigrateB4 = address(0xbeef).balance;

        (uint160 migrationSqrtPriceX96,, uint128 fees0,,, uint128 fees1,) = hook.migrate(address(0xbeef));

        uint256 tokenMigrated = IERC20(asset).balanceOf(address(0xbeef));
        uint256 ethMigrated = address(0xbeef).balance;

        console.log("\n-------------- MIGRATION RESULT ------------------");
        console.log("ETH migrated: ", ethMigrated - ethMigrateB4);
        console.log("Token migrated: ", tokenMigrated - tokenMigrateB4);

        uint256 ethMigratedMinusFee = ethMigrated - fees0;
        uint256 tokenMigratedMinusFee = tokenMigrated - fees1;

        (uint256 depositAmount0, uint256 depositAmount1) =
            MigrationMath.computeDepositAmounts(ethMigratedMinusFee, tokenMigratedMinusFee, migrationSqrtPriceX96);

        if (depositAmount1 > tokenMigrated) {
            (, depositAmount1) =
                MigrationMath.computeDepositAmounts(depositAmount0, tokenMigrated, migrationSqrtPriceX96);
        } else {
            (depositAmount0,) =
                MigrationMath.computeDepositAmounts(ethMigratedMinusFee, depositAmount1, migrationSqrtPriceX96);
        }

        // uint256 ethLQToLock = depositAmount0 / 20;
        // uint256 tokenLQToLock = depositAmount1 / 20;
        // uint256 liquidity = sqrt(depositAmount0 * depositAmount1);

        console.log("\n");
        // console.log("ethLQToLock LP for Locker", ethLQToLock);
        // console.log("tokenLQToLock LP for Locker", tokenLQToLock);
        // console.log("\n");
        console.log("total ETH in v2 LP", depositAmount0);
        console.log("total token in v2 LP", depositAmount1);
        console.log("\n");
        console.log("ETH in timelock", ethMigratedMinusFee - depositAmount0);
        console.log("token in timelock", tokenMigratedMinusFee - depositAmount1);
        // console.log("ETH in Uni v2 LP for timelock", depositAmount0 - ethLQToLock);
        // console.log("token in Uni v2 LP for timelock", depositAmount1 - tokenLQToLock);
        // console.log("liquidity", liquidity);
    }

    function test_buy_FixedBuyWithinFixedEpochsUntilMinOrMaxProceed() public {
        // Go to starting time
        vm.warp(hook.startingTime());

        DopplerLensReturnData memory oriLensData = lensQuoter.quoteDopplerLensData(
            IV4Quoter.QuoteExactSingleParams({ poolKey: key, zeroForOne: !isToken0, exactAmount: 1, hookData: "" })
        );

        uint160 oriSqrtPriceX96 = oriLensData.sqrtPriceX96;

        console.log("\n-------------- CURRENT CONFIG ------------------");
        console.log("ori token left in pool", IERC20(asset).balanceOf(address(manager)));
        console.log("ori token left in hook", IERC20(asset).balanceOf(address(hook)));
        console.log("ori sqrtPriceX96", oriSqrtPriceX96);
        console.log("starting tick", hook.startingTick());
        console.log("ending tick", hook.endingTick());
        console.log("gamma", hook.gamma());
        console.log("\n");
        console.log("numeraire ", numeraire);
        console.log("asset ", asset);
        console.log("isToken0 ", isToken0);
        console.log("usingEth ", usingEth);
        console.log("total epochs", hook.getTotalEpochs());
        console.log("current epoch", hook.getCurrentEpoch());

        uint256 totalEpochs = SALE_DURATION / DEFAULT_EPOCH_LENGTH;
        bool isMaxProceed = false;

        uint256 FIXED_EPOCHS = 70;
        uint256 BUY_ETH_AMOUNT = isMaxProceed
            ? DEFAULT_MAXIMUM_PROCEEDS / (FIXED_EPOCHS - 1) + 1
            : DEFAULT_MINIMUM_PROCEEDS / (FIXED_EPOCHS - 1) + 1;

        for (uint256 i; i < FIXED_EPOCHS; i++) {
            require(
                i <= totalEpochs,
                string.concat(
                    "exceeding num of total epochs ", vm.toString(totalEpochs), ", please use a bigger BUY_ETH_AMOUNT"
                )
            );

            uint256 tokenBought;
            // try lensQuoter.quoteDopplerLensData(
            //     IV4Quoter.QuoteExactSingleParams({
            //         poolKey: key,
            //         zeroForOne: !isToken0,
            //         exactAmount: uint128(BUY_ETH_AMOUNT),
            //         hookData: ""
            //     })
            // ) {
            //     (tokenBought,) = buy(-int256(BUY_ETH_AMOUNT));
            // } catch (bytes memory) {
            //     console.log("\n");
            //     console.log("REVERTED, stopped the simulation.");
            //     break;
            // }
            (tokenBought,) = buy(-int256(BUY_ETH_AMOUNT));

            (,, uint256 totalTokensSold, uint256 totalProceeds,,) = hook.state();

            uint160 sqrtPriceX96;
            int24 tick;

            try lensQuoter.quoteDopplerLensData(
                IV4Quoter.QuoteExactSingleParams({ poolKey: key, zeroForOne: !isToken0, exactAmount: 1, hookData: "" })
            ) {
                DopplerLensReturnData memory lensData = lensQuoter.quoteDopplerLensData(
                    IV4Quoter.QuoteExactSingleParams({
                        poolKey: key,
                        zeroForOne: !isToken0,
                        exactAmount: 1,
                        hookData: ""
                    })
                );
                sqrtPriceX96 = lensData.sqrtPriceX96;
                tick = lensData.tick;
            } catch (bytes memory) {
                (sqrtPriceX96, tick,,) = manager.getSlot0(key.toId());
            }

            console.log("\n-------------- SALE No. %d ------------------", i + 1);
            console.log("current epoch", hook.getCurrentEpoch());
            console.log("token bought", tokenBought);
            console.log("totalTokensSold / circulating supply", totalTokensSold);
            console.log("totalProceeds", totalProceeds);
            console.log("\n");
            console.log("sqrtPriceX96(ethPerOneToken)", sqrtPriceX96);
            console.log("tick(tokenPerOneETH)", tick);
            console.log("isEarlyExit", hook.earlyExit());

            vm.warp(hook.startingTime() + hook.epochLength() * (i + 1)); // go to next epoch
        }

        if (isMaxProceed) {
            require(hook.earlyExit(), "didn't migrate as expected");
            vm.prank(hook.initializer());
            (uint160 migrationSqrtPriceX96,, uint128 fees0,,, uint128 fees1,) = hook.migrate(address(0xbeef));

            uint256 tokenMigrated = IERC20(asset).balanceOf(address(0xbeef));
            uint256 ethMigrated = address(0xbeef).balance;

            console.log("\n-------------- MIGRATION RESULT ------------------");
            console.log("ETH migrated: ", ethMigrated);
            console.log("Token migrated: ", tokenMigrated);

            uint256 ethMigratedMinusFee = ethMigrated - fees0;
            uint256 tokenMigratedMinusFee = tokenMigrated - fees1;

            (uint256 depositAmount0, uint256 depositAmount1) =
                MigrationMath.computeDepositAmounts(ethMigratedMinusFee, tokenMigratedMinusFee, migrationSqrtPriceX96);

            if (depositAmount1 > tokenMigrated) {
                (, depositAmount1) =
                    MigrationMath.computeDepositAmounts(depositAmount0, tokenMigrated, migrationSqrtPriceX96);
            } else {
                (depositAmount0,) =
                    MigrationMath.computeDepositAmounts(ethMigratedMinusFee, depositAmount1, migrationSqrtPriceX96);
            }

            console.log("\n");
            console.log("total ETH in v2 LP", depositAmount0);
            console.log("total token in v2 LP", depositAmount1);
            console.log("\n");
            console.log("ETH in timelock", ethMigratedMinusFee - depositAmount0);
            console.log("token in timelock", tokenMigratedMinusFee - depositAmount1);
        }
    }

    function test_buy_EmptyFixedEpochs_BuyWithinFixedEpochsUntilMinOrMaxProceed() public {
        // Go to starting time
        vm.warp(hook.startingTime());

        DopplerLensReturnData memory oriLensData = lensQuoter.quoteDopplerLensData(
            IV4Quoter.QuoteExactSingleParams({ poolKey: key, zeroForOne: !isToken0, exactAmount: 1, hookData: "" })
        );

        uint160 oriSqrtPriceX96 = oriLensData.sqrtPriceX96;

        console.log("\n-------------- CURRENT CONFIG ------------------");
        console.log("ori token left in pool", IERC20(asset).balanceOf(address(manager)));
        console.log("ori token left in hook", IERC20(asset).balanceOf(address(hook)));
        console.log("ori sqrtPriceX96", oriSqrtPriceX96);
        console.log("starting tick", hook.startingTick());
        console.log("ending tick", hook.endingTick());
        console.log("gamma", hook.gamma());
        console.log("\n");
        console.log("numeraire ", numeraire);
        console.log("asset ", asset);
        console.log("isToken0 ", isToken0);
        console.log("usingEth ", usingEth);
        console.log("total epochs", hook.getTotalEpochs());
        console.log("current epoch", hook.getCurrentEpoch());

        // no buys for N epochs
        uint256 emptyEpochs = 20;
        // buy with same size for N epochs
        uint256 fixedEpochs = (hook.getTotalEpochs() - emptyEpochs) / 2;
        bool isMaxProceed = true;

        uint256 BUY_ETH_AMOUNT =
            isMaxProceed ? DEFAULT_MAXIMUM_PROCEEDS / (fixedEpochs - 1) : DEFAULT_MINIMUM_PROCEEDS / (fixedEpochs - 1); // need one more buy to reach target so - 1
        // uint256 BUY_ETH_AMOUNT = 0.2 ether;

        // time travel by `emptyEpochs`
        vm.warp(hook.startingTime() + hook.epochLength() * emptyEpochs);

        DopplerLensReturnData memory quotedLensData = lensQuoter.quoteDopplerLensData(
            IV4Quoter.QuoteExactSingleParams({ poolKey: key, zeroForOne: !isToken0, exactAmount: 1, hookData: "" })
        );

        uint160 quotedSqrtPriceX96 = quotedLensData.sqrtPriceX96;
        int24 quotedTick = quotedLensData.tick;

        console.log("\n");
        console.log("quotedSqrtPriceX96", quotedSqrtPriceX96);
        console.log("quotedTick", quotedTick);

        // consecutive buy with same size in each epoch
        for (uint256 i; i < fixedEpochs; i++) {
            uint256 tokenBought;

            // try lensQuoter.quoteDopplerLensData(
            //     IV4Quoter.QuoteExactSingleParams({
            //         poolKey: key,
            //         zeroForOne: !isToken0,
            //         exactAmount: uint128(BUY_ETH_AMOUNT),
            //         hookData: ""
            //     })
            // ) {
            //     (tokenBought,) = buy(-int256(BUY_ETH_AMOUNT));
            // } catch (bytes memory) {
            //     console.log("\n");
            //     console.log("REVERTED, stopped the simulation.");
            //     break;
            // }
            (tokenBought,) = buy(-int256(BUY_ETH_AMOUNT));

            (,, uint256 totalTokensSold, uint256 totalProceeds,,) = hook.state();

            uint160 sqrtPriceX96;
            int24 tick;

            try lensQuoter.quoteDopplerLensData(
                IV4Quoter.QuoteExactSingleParams({ poolKey: key, zeroForOne: !isToken0, exactAmount: 1, hookData: "" })
            ) {
                DopplerLensReturnData memory lensData = lensQuoter.quoteDopplerLensData(
                    IV4Quoter.QuoteExactSingleParams({
                        poolKey: key,
                        zeroForOne: !isToken0,
                        exactAmount: 1,
                        hookData: ""
                    })
                );
                sqrtPriceX96 = lensData.sqrtPriceX96;
                tick = lensData.tick;
            } catch (bytes memory) {
                (sqrtPriceX96, tick,,) = manager.getSlot0(key.toId());
            }

            console.log("\n-------------- SALE No. %d ------------------", i + 1);
            console.log("current epoch", hook.getCurrentEpoch());
            console.log("token bought", tokenBought);
            console.log("totalTokensSold / circulating supply", totalTokensSold);
            console.log("totalProceeds", totalProceeds);
            console.log("\n");
            console.log("sqrtPriceX96(ethPerOneToken)", sqrtPriceX96);
            console.log("tick(tokenPerOneETH)", tick);
            console.log("isEarlyExit", hook.earlyExit());

            vm.warp(hook.startingTime() + hook.epochLength() * (emptyEpochs + i + 1)); // go to next epoch
        }

        if (isMaxProceed) {
            require(hook.earlyExit(), "didn't migrate as expected");
            vm.prank(hook.initializer());
            (uint160 migrationSqrtPriceX96,, uint128 fees0,,, uint128 fees1,) = hook.migrate(address(0xbeef));

            uint256 tokenMigrated = IERC20(asset).balanceOf(address(0xbeef));
            uint256 ethMigrated = address(0xbeef).balance;

            console.log("\n-------------- MIGRATION RESULT ------------------");
            console.log("ETH migrated: ", ethMigrated);
            console.log("Token migrated: ", tokenMigrated);

            uint256 ethMigratedMinusFee = ethMigrated - fees0;
            uint256 tokenMigratedMinusFee = tokenMigrated - fees1;

            (uint256 depositAmount0, uint256 depositAmount1) =
                MigrationMath.computeDepositAmounts(ethMigratedMinusFee, tokenMigratedMinusFee, migrationSqrtPriceX96);

            if (depositAmount1 > tokenMigrated) {
                (, depositAmount1) =
                    MigrationMath.computeDepositAmounts(depositAmount0, tokenMigrated, migrationSqrtPriceX96);
            } else {
                (depositAmount0,) =
                    MigrationMath.computeDepositAmounts(ethMigratedMinusFee, depositAmount1, migrationSqrtPriceX96);
            }

            console.log("\n");
            console.log("total ETH in v2 LP", depositAmount0);
            console.log("total token in v2 LP", depositAmount1);
            console.log("\n");
            console.log("ETH in timelock", ethMigratedMinusFee - depositAmount0);
            console.log("token in timelock", tokenMigratedMinusFee - depositAmount1);
        }
    }

    function sqrt(
        uint256 y
    ) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}
