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

interface IERC20 {
    function balanceOf(
        address account
    ) external view returns (uint256);
}

using StateLibrary for IPoolManager;

contract V4PocTest is DopplerLensTest {
    function test_buy_EmptyEpochsForHalfSale_HalfSameSizeUntilMaxProceed() public {
        // Go to starting time
        vm.warp(hook.startingTime());

        (uint160 oriSqrtPriceX96,) = lensQuoter.quoteDopplerLensData(
            IV4Quoter.QuoteExactSingleParams({ poolKey: key, zeroForOne: !isToken0, exactAmount: 1, hookData: "" })
        );

        console.log("\n-------------- CURRENT CONFIG ------------------");
        console.log("ori token left in hook", IERC20(asset).balanceOf(address(hook)));
        console.log("ori token left in pool", IERC20(asset).balanceOf(address(manager)));
        console.log("ori sqrtPriceX96", oriSqrtPriceX96);
        console.log("starting tick", hook.startingTick());
        console.log("ending tick", hook.endingTick());
        console.log("gamma", hook.gamma());

        // no buys for N epochs
        uint256 halfOfSaleEpochs = SALE_DURATION / DEFAULT_EPOCH_LENGTH / 2;
        uint256 BUY_ETH_AMOUNT = DEFAULT_MAXIMUM_PROCEEDS / halfOfSaleEpochs + 1;

        vm.warp(hook.startingTime() + hook.epochLength() * halfOfSaleEpochs);

        // consecutive buy in each epoch
        for (uint256 i; i < halfOfSaleEpochs; i++) {
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

            uint160 sqrtPriceX96;
            int24 tick;

            try lensQuoter.quoteDopplerLensData(
                IV4Quoter.QuoteExactSingleParams({ poolKey: key, zeroForOne: !isToken0, exactAmount: 1, hookData: "" })
            ) {
                (sqrtPriceX96, tick) = lensQuoter.quoteDopplerLensData(
                    IV4Quoter.QuoteExactSingleParams({
                        poolKey: key,
                        zeroForOne: !isToken0,
                        exactAmount: 1,
                        hookData: ""
                    })
                );
            } catch (bytes memory) {
                (sqrtPriceX96, tick,,) = manager.getSlot0(key.toId());
            }

            console.log("\n-------------- SALE No. %d ------------------", i);
            console.log("current epoch", hook.getCurrentEpoch());
            console.log("token bought", tokenBought);
            console.log("totalTokensSold / circulating supply", totalTokensSold);
            console.log("totalProceeds", totalProceeds);
            console.log("\n");
            console.log("sqrtPriceX96(ethPerOneToken)", sqrtPriceX96);
            console.log("tick(tokenPerOneETH)", tick);
            console.log("isEarlyExit", hook.earlyExit());

            vm.warp(hook.startingTime() + hook.epochLength() * (halfOfSaleEpochs + i + 1)); // go to next epoch
        }

        require(hook.earlyExit(), "didn't migrate as expected");
        vm.prank(hook.initializer());
        hook.migrate(address(0xbeef));

        console.log("\nToken migrated: ", IERC20(asset).balanceOf(address(0xbeef)));
        console.log("ETH migrated: ", address(0xbeef).balance);
    }

    function test_buy_FixedBuyWithinFixedEpochsUntilMaxProceed() public {
        // Go to starting time
        vm.warp(hook.startingTime());

        (uint160 oriSqrtPriceX96,) = lensQuoter.quoteDopplerLensData(
            IV4Quoter.QuoteExactSingleParams({ poolKey: key, zeroForOne: !isToken0, exactAmount: 1, hookData: "" })
        );

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
        console.log("current epoch", hook.getCurrentEpoch());

        uint256 totalEpochs = SALE_DURATION / DEFAULT_EPOCH_LENGTH;
        uint256 fixedEpochs = 10;
        assert(totalEpochs > fixedEpochs);

        // uint256 buyEthAmount = DEFAULT_MAXIMUM_PROCEEDS / fixedEpochs + 1; // in case max proceed is not divisible by the number of epochs
        uint256 buyEthAmount = 0.1 ether;

        // consecutive buy with same size in each epoch
        for (uint256 i; i < fixedEpochs; i++) {
            (uint256 tokenBought,) = buy(-int256(buyEthAmount));

            (,, uint256 totalTokensSold, uint256 totalProceeds,,) = hook.state();

            uint160 sqrtPriceX96;
            int24 tick;

            if (i == fixedEpochs - 1) {
                (sqrtPriceX96, tick,,) = manager.getSlot0(key.toId());
            } else {
                (sqrtPriceX96, tick) = lensQuoter.quoteDopplerLensData(
                    IV4Quoter.QuoteExactSingleParams({
                        poolKey: key,
                        zeroForOne: !isToken0,
                        exactAmount: 1,
                        hookData: ""
                    })
                );
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

        require(hook.earlyExit(), "didn't migrate as expected");
        vm.prank(hook.initializer());
        hook.migrate(address(0xbeef));

        console.log("\nToken migrated: ", IERC20(asset).balanceOf(address(0xbeef)));
        console.log("ETH migrated: ", address(0xbeef).balance);
    }

    function test_buy_FixedBuyAtEachEpochUntilMaxProceed() public {
        // Go to starting time
        vm.warp(hook.startingTime());

        (uint160 oriSqrtPriceX96,) = lensQuoter.quoteDopplerLensData(
            IV4Quoter.QuoteExactSingleParams({ poolKey: key, zeroForOne: !isToken0, exactAmount: 1, hookData: "" })
        );

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

        uint256 BUY_ETH_AMOUNT = 0.15 ether;

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
                (sqrtPriceX96, tick) = lensQuoter.quoteDopplerLensData(
                    IV4Quoter.QuoteExactSingleParams({
                        poolKey: key,
                        zeroForOne: !isToken0,
                        exactAmount: 1,
                        hookData: ""
                    })
                );
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
        hook.migrate(address(0xbeef));

        console.log("\nToken migrated: ", IERC20(asset).balanceOf(address(0xbeef)));
        console.log("ETH migrated: ", address(0xbeef).balance);
    }

    function test_buy_EmptyFixedEpochs_BuyWithinFixedEpochsUntilMaxProceed() public {
        // Go to starting time
        vm.warp(hook.startingTime());

        (uint160 oriSqrtPriceX96,) = lensQuoter.quoteDopplerLensData(
            IV4Quoter.QuoteExactSingleParams({ poolKey: key, zeroForOne: !isToken0, exactAmount: 1, hookData: "" })
        );

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
        uint256 fixedEpochs = 10;

        // time travel by `emptyEpochs`
        vm.warp(hook.startingTime() + hook.epochLength() * emptyEpochs);

        (uint160 quotedSqrtPriceX96, int24 quotedTick) = lensQuoter.quoteDopplerLensData(
            IV4Quoter.QuoteExactSingleParams({ poolKey: key, zeroForOne: !isToken0, exactAmount: 1, hookData: "" })
        );

        console.log("\n");
        console.log("quotedSqrtPriceX96", quotedSqrtPriceX96);
        console.log("quotedTick", quotedTick);

        uint256 BUY_ETH_AMOUNT = DEFAULT_MAXIMUM_PROCEEDS / fixedEpochs + 1; // in case max proceed is not divisible by the number of epochs

        // consecutive buy with same size in each epoch
        for (uint256 i; i < fixedEpochs; i++) {
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

            uint160 sqrtPriceX96;
            int24 tick;

            try lensQuoter.quoteDopplerLensData(
                IV4Quoter.QuoteExactSingleParams({ poolKey: key, zeroForOne: !isToken0, exactAmount: 1, hookData: "" })
            ) {
                (sqrtPriceX96, tick) = lensQuoter.quoteDopplerLensData(
                    IV4Quoter.QuoteExactSingleParams({
                        poolKey: key,
                        zeroForOne: !isToken0,
                        exactAmount: 1,
                        hookData: ""
                    })
                );
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

        require(hook.earlyExit(), "didn't migrate as expected");
        vm.prank(hook.initializer());
        hook.migrate(address(0xbeef));

        console.log("\nToken migrated: ", IERC20(asset).balanceOf(address(0xbeef)));
        console.log("ETH migrated: ", address(0xbeef).balance);
    }

    function testFuzz_buy_5EmptyEpoch_DiffSizeUntilMaxProceed(
        uint256 buyEtherAmount,
        uint256 sellEtherAmount,
        uint256 buyBackEtherAmount
    ) public {
        uint256 amount = 1.333 ether;
        buyEtherAmount = bound(buyEtherAmount, amount, amount + 0.05 ether);
        sellEtherAmount = bound(sellEtherAmount, 0.55 ether, amount / 2);
        buyBackEtherAmount = bound(buyBackEtherAmount, 0.55 ether, amount / 2);

        // Go to starting time
        vm.warp(hook.startingTime());

        (uint160 oriSqrtPriceX96,) = lensQuoter.quoteDopplerLensData(
            IV4Quoter.QuoteExactSingleParams({ poolKey: key, zeroForOne: !isToken0, exactAmount: 1, hookData: "" })
        );

        console.log("\n-------------- CURRENT CONFIG ------------------");
        console.log("ori token left in hook", IERC20(asset).balanceOf(address(hook)));
        console.log("ori token left in pool", IERC20(asset).balanceOf(address(manager)));
        console.log("ori sqrtPriceX96", oriSqrtPriceX96);
        console.log("starting tick", hook.startingTick());
        console.log("ending tick", hook.endingTick());
        console.log("gamma", hook.gamma());

        // no buys for N epochs
        uint256 skipNumOfEpochs = 5;
        uint256 tradeNum = 10;

        vm.warp(hook.startingTime() + hook.epochLength() * skipNumOfEpochs);

        // consecutive trades in each epoch
        for (uint256 i; i < tradeNum; i++) {
            uint256 tokenBought;

            (tokenBought,) = buy(-int256(buyEtherAmount));
            sellExactIn(sellEtherAmount);
            buyExactOut(buyBackEtherAmount);

            (,, uint256 totalTokensSold, uint256 totalProceeds,,) = hook.state();

            uint160 sqrtPriceX96;
            int24 tick;

            if (i == tradeNum - 1) {
                (sqrtPriceX96, tick,,) = manager.getSlot0(key.toId());
            } else {
                (sqrtPriceX96, tick) = lensQuoter.quoteDopplerLensData(
                    IV4Quoter.QuoteExactSingleParams({
                        poolKey: key,
                        zeroForOne: !isToken0,
                        exactAmount: 1,
                        hookData: ""
                    })
                );
            }

            console.log("\n-------------- SALE No. %d ------------------", i);
            console.log("current epoch", hook.getCurrentEpoch());
            console.log("token bought", tokenBought);
            console.log("totalTokensSold / circulating supply", totalTokensSold);
            console.log("totalProceeds", totalProceeds);
            console.log("\n");
            console.log("sqrtPriceX96(ethPerOneToken)", sqrtPriceX96);
            console.log("tick(tokenPerOneETH)", tick);
            console.log("isEarlyExit", hook.earlyExit());

            vm.warp(hook.startingTime() + hook.epochLength() * (skipNumOfEpochs + i + 1)); // go to next epoch
        }

        require(hook.earlyExit(), "didn't migrate as expected");
        vm.prank(hook.initializer());
        hook.migrate(address(0xbeef));

        console.log("\nToken migrated: ", IERC20(asset).balanceOf(address(0xbeef)));
        console.log("ETH migrated: ", address(0xbeef).balance);
    }
}
