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
    function test_buy_EmptyFixedEpochs_Buy1ETHAtNextEpoch() public {
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
        console.log("\n");
        console.log("numeraire ", numeraire);
        console.log("asset ", asset);
        console.log("isToken0 ", isToken0);
        console.log("usingEth ", usingEth);
        console.log("current epoch", hook.getCurrentEpoch());

        // no buys for `emptyEpochs`
        uint256 emptyEpochs = 20;
        // time travel to half of the sale
        vm.warp(hook.startingTime() + hook.epochLength() * emptyEpochs - 1);

        (uint160 quotedSqrtPriceX96, int24 quotedTick) = lensQuoter.quoteDopplerLensData(
            IV4Quoter.QuoteExactSingleParams({ poolKey: key, zeroForOne: !isToken0, exactAmount: 1, hookData: "" })
        );

        console.log("\n");
        console.log("quotedSqrtPriceX96", quotedSqrtPriceX96);
        console.log("quotedTick", quotedTick);

        vm.warp(hook.startingTime() + hook.epochLength() * emptyEpochs);

        (uint256 tokenBought,) = buy(-int256(1 ether));

        (,, uint256 totalTokensSold, uint256 totalProceeds,,) = hook.state();

        (uint160 sqrtPriceX96, int24 tick) = lensQuoter.quoteDopplerLensData(
            IV4Quoter.QuoteExactSingleParams({ poolKey: key, zeroForOne: !isToken0, exactAmount: 1, hookData: "" })
        );

        console.log("\n-------------- SALE ------------------");
        console.log("current epoch", hook.getCurrentEpoch());
        console.log("token bought", tokenBought);
        console.log("totalTokensSold / circulating supply", totalTokensSold);
        console.log("totalProceeds", totalProceeds);
        console.log("\n");
        console.log("sqrtPriceX96(ethPerOneToken)", sqrtPriceX96);
        console.log("tick(tokenPerOneETH)", tick);
    }

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
        uint256 buyEthAmount = DEFAULT_MAXIMUM_PROCEEDS / halfOfSaleEpochs + 1;

        vm.warp(hook.startingTime() + hook.epochLength() * halfOfSaleEpochs);

        // consecutive buy in each epoch
        for (uint256 i; i < halfOfSaleEpochs; i++) {
            uint256 tokenBought;

            (tokenBought,) = buy(-int256(buyEthAmount));

            (,, uint256 totalTokensSold, uint256 totalProceeds,,) = hook.state();

            uint160 sqrtPriceX96;
            int24 tick;

            if (i == halfOfSaleEpochs - 1) {
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
            uint256 tokenPerOneETH = sqrtPriceX96;

            console.log("\n-------------- SALE No. %d ------------------", i);
            console.log("tick", tick);
            console.log("token bought", tokenBought);
            console.log("\n");
            console.log("totalTokensSold / circulating supply", totalTokensSold);
            console.log("totalProceeds", totalProceeds);
            console.log("\n");
            console.log("token / ETH (sqrtPriceX96)", tokenPerOneETH);
            console.log("isEarlyExit", hook.earlyExit());
            console.log("current epoch", hook.getCurrentEpoch());

            vm.warp(hook.startingTime() + hook.epochLength() * (halfOfSaleEpochs + i + 1)); // go to next epoch
        }

        vm.prank(hook.initializer());
        hook.migrate(address(0xbeef));

        console.log("\nToken migrated: ", IERC20(asset).balanceOf(address(0xbeef)));
        console.log("ETH migrated: ", address(0xbeef).balance);
    }

    function test_buy_60EmptyEpochs_30EpochsSameSizeUntilMaxProceed() public {
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
        uint256 skipNumOfEpochs = 60;
        uint256 tradeNum = 30;
        uint256 buyEthAmount = DEFAULT_MAXIMUM_PROCEEDS / tradeNum + 1;

        vm.warp(hook.startingTime() + hook.epochLength() * skipNumOfEpochs);

        // consecutive buy in each epoch
        for (uint256 i; i < tradeNum; i++) {
            uint256 tokenBought;
            (tokenBought,) = buy(-int256(buyEthAmount));

            // if (i == tradeNum - 1) {
            //     (tokenBought,) = buy(-int256(buyEthAmount));
            // } else {
            //     (tokenBought,) = buy(-int256(buyEthAmount));
            //     sellExactIn(tokenBought / 2);
            //     buyExactOut(tokenBought / 2);
            // }

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
            uint256 tokenPerOneETH = sqrtPriceX96;

            console.log("\n-------------- SALE No. %d ------------------", i);
            console.log("tick", tick);
            console.log("token bought", tokenBought);
            console.log("\n");
            console.log("totalTokensSold / circulating supply", totalTokensSold);
            console.log("totalProceeds", totalProceeds);
            console.log("\n");
            console.log("token / ETH (sqrtPriceX96)", tokenPerOneETH);
            console.log("isEarlyExit", hook.earlyExit());
            console.log("current epoch", hook.getCurrentEpoch());

            vm.warp(hook.startingTime() + hook.epochLength() * (skipNumOfEpochs + i + 1)); // go to next epoch
        }

        vm.prank(hook.initializer());
        hook.migrate(address(0xbeef));

        console.log("\nToken migrated: ", IERC20(asset).balanceOf(address(0xbeef)));
        console.log("ETH migrated: ", address(0xbeef).balance);
    }

    function test_buy_70emptyEpochs_20EpochsSameSizeUntilMaxProceed() public {
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
        uint256 skipNumOfEpochs = 70;
        uint256 tradeNum = 20;
        uint256 buyEthAmount = DEFAULT_MAXIMUM_PROCEEDS / tradeNum + 1;

        vm.warp(hook.startingTime() + hook.epochLength() * skipNumOfEpochs);

        // consecutive buy in each epoch
        for (uint256 i; i < tradeNum; i++) {
            (uint256 tokenBought,) = buy(-int256(buyEthAmount));

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
            uint256 tokenPerOneETH = sqrtPriceX96;

            console.log("\n-------------- SALE No. %d ------------------", i);
            console.log("tick", tick);
            console.log("token bought", tokenBought);
            console.log("\n");
            console.log("totalTokensSold / circulating supply", totalTokensSold);
            console.log("totalProceeds", totalProceeds);
            console.log("\n");
            console.log("token / ETH (sqrtPriceX96)", tokenPerOneETH);
            console.log("isEarlyExit", hook.earlyExit());
            console.log("current epoch", hook.getCurrentEpoch());

            vm.warp(hook.startingTime() + hook.epochLength() * (skipNumOfEpochs + i + 1)); // go to next epoch
        }

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

        vm.prank(hook.initializer());
        hook.migrate(address(0xbeef));

        console.log("\nToken migrated: ", IERC20(asset).balanceOf(address(0xbeef)));
        console.log("ETH migrated: ", address(0xbeef).balance);
    }

    function test_buy_FixedBuyUntilMaxProceed() public {
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

        uint256 buyEthAmount = 0.15 ether;

        uint256 totalEthProceeds;
        uint256 count;

        // consecutive buy with same size in each epoch
        while (totalEthProceeds < DEFAULT_MAXIMUM_PROCEEDS) {
            (uint256 tokenBought,) = buy(-int256(buyEthAmount));

            (,, uint256 totalTokensSold, uint256 totalProceeds,,) = hook.state();

            totalEthProceeds = totalProceeds;

            uint160 sqrtPriceX96;
            int24 tick;

            // (sqrtPriceX96, tick,,) = manager.getSlot0(key.toId());
            if (totalEthProceeds + buyEthAmount >= DEFAULT_MAXIMUM_PROCEEDS) {
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

            console.log("\n-------------- SALE No. %d ------------------", count + 1);
            console.log("current epoch", hook.getCurrentEpoch());
            console.log("token bought", tokenBought);
            console.log("totalTokensSold / circulating supply", totalTokensSold);
            console.log("totalProceeds", totalProceeds);
            console.log("\n");
            console.log("sqrtPriceX96(ethPerOneToken)", sqrtPriceX96);
            console.log("tick(tokenPerOneETH)", tick);
            console.log("isEarlyExit", hook.earlyExit());

            vm.warp(hook.startingTime() + hook.epochLength() * (count + 1)); // go to next epoch
            count++;
        }

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
        uint256 fixedEpochs = 50;

        // time travel by `emptyEpochs`
        vm.warp(hook.startingTime() + hook.epochLength() * emptyEpochs);

        (uint160 quotedSqrtPriceX96, int24 quotedTick) = lensQuoter.quoteDopplerLensData(
            IV4Quoter.QuoteExactSingleParams({ poolKey: key, zeroForOne: !isToken0, exactAmount: 1, hookData: "" })
        );

        console.log("\n");
        console.log("quotedSqrtPriceX96", quotedSqrtPriceX96);
        console.log("quotedTick", quotedTick);

        uint256 buyEthAmount = DEFAULT_MAXIMUM_PROCEEDS / fixedEpochs + 1; // in case max proceed is not divisible by the number of epochs
        // uint256 buyEthAmount = 0.5 ether;

        // consecutive buy with same size in each epoch
        for (uint256 i; i < fixedEpochs; i++) {
            uint256 tokenBought;

            (tokenBought,) = buy(-int256(buyEthAmount));

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

            vm.warp(hook.startingTime() + hook.epochLength() * (emptyEpochs + i + 1)); // go to next epoch
        }

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
        uint256 oriTokenBalance = IERC20(asset).balanceOf(address(this));

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
            uint256 tokenBalB4 = IERC20(asset).balanceOf(address(this)) - oriTokenBalance;

            uint256 tokenBought;

            (tokenBought,) = buy(-int256(buyEtherAmount));
            sellExactIn(sellEtherAmount);
            buyExactOut(buyBackEtherAmount);

            uint256 tokenBalAfter = IERC20(asset).balanceOf(address(this)) - oriTokenBalance;
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
            uint256 tokenPerOneETH = sqrtPriceX96;

            console.log("\n-------------- SALE No. %d ------------------", i);
            console.log("tick", tick);
            console.log("token bal b4", tokenBalB4);
            console.log("token bal af", tokenBalAfter);
            console.log("token bought", tokenBought);
            console.log("\n");
            console.log("totalTokensSold / circulating supply", totalTokensSold);
            console.log("totalProceeds", totalProceeds);
            console.log("\n");
            console.log("token / ETH (sqrtPriceX96)", tokenPerOneETH);
            console.log("current epoch", hook.getCurrentEpoch());

            vm.warp(hook.startingTime() + hook.epochLength() * (skipNumOfEpochs + i + 1)); // go to next epoch
        }

        vm.prank(hook.initializer());
        hook.migrate(address(0xbeef));

        console.log("\nToken migrated: ", IERC20(asset).balanceOf(address(0xbeef)));
        console.log("ETH migrated: ", address(0xbeef).balance);
    }
}
