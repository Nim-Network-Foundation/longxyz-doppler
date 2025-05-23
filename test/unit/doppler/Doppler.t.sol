// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { BaseTest } from "test/shared/BaseTest.sol";

contract DopplerTest is BaseTest {
    // =========================================================================
    //                  _getMaxTickDeltaPerEpoch Unit Tests
    // =========================================================================

    function testGetMaxTickDeltaPerEpoch_ReturnsExpectedAmount() public view {
        int256 maxTickDeltaPerEpoch = hook.getMaxTickDeltaPerEpoch();

        assertApproxEqAbs(
            hook.endingTick(),
            (
                (
                    maxTickDeltaPerEpoch
                        * (int256((hook.endingTime() - hook.startingTime())) / int256(hook.epochLength()))
                ) / 1e18 + hook.startingTick()
            ),
            1
        );
    }

    // =========================================================================
    //                   _getTicksBasedOnState Unit Tests
    // =========================================================================

    // TODO: int16 accumulator might over/underflow with certain hook configurations
    //       Consider whether we need to protect against this in the contract or whether it's not a concern
    function testGetTicksBasedOnState_ReturnsExpectedAmountSold(
        int16 accumulator
    ) public view {
        (int24 tickLower, int24 tickUpper) = hook.getTicksBasedOnState(accumulator, key.tickSpacing);
        int24 gamma = hook.gamma();

        if (hook.startingTick() > hook.endingTick()) {
            assertEq(int256(gamma), tickUpper - tickLower);
        } else {
            assertEq(int256(gamma), tickLower - tickUpper);
        }
    }

    // =========================================================================
    //                     _getCurrentEpoch Unit Tests
    // =========================================================================

    function testGetCurrentEpoch_ReturnsCorrectEpoch() public {
        vm.warp(hook.startingTime());
        uint256 currentEpoch = hook.getCurrentEpoch();

        assertEq(currentEpoch, 1);

        vm.warp(hook.startingTime() + hook.epochLength());
        currentEpoch = hook.getCurrentEpoch();

        assertEq(currentEpoch, 2);

        vm.warp(hook.startingTime() + hook.epochLength() * 2);
        currentEpoch = hook.getCurrentEpoch();

        assertEq(currentEpoch, 3);
    }

    // =========================================================================
    //                  _getNormalizedTimeElapsed Unit Tests
    // =========================================================================

    function testGetNormalizedTimeElapsed(
        uint16 bps
    ) public view {
        vm.assume(bps <= 10_000);

        uint256 endingTime = hook.endingTime();
        uint256 startingTime = hook.startingTime();
        uint256 timestamp = (endingTime - startingTime) * bps / 10_000 + startingTime;

        // Assert that the result is within one bps of the expected value
        assertApproxEqAbs(hook.getNormalizedTimeElapsed(timestamp), uint256(bps) * 1e14, 0.5e14);
    }

    // =========================================================================
    //                       _getGammaShare Unit Tests
    // =========================================================================

    /*
    function testNormalizedEpochDelta() public view {
        uint256 endingTime = hook.endingTime();
        uint256 startingTime = hook.startingTime();
        uint256 epochLength = hook.epochLength();

        uint256 timeDelta = endingTime - startingTime;
        uint256 normalizedEpochDelta = FullMath.mulDiv(epochLength, WAD, timeDelta);
        assertApproxEqAbs(epochLength, uint256(hook.getNormalizedEpochDelta()) * (endingTime - startingTime) / 1e18, 1);
    }
    */

    // =========================================================================
    //                       _getEpochEndWithOffset Unit Tests
    // =========================================================================

    function testGetEpochEndWithOffset() public {
        uint256 startingTime = hook.startingTime();
        uint256 endingTime = hook.endingTime();
        uint256 epochLength = hook.epochLength();

        // Assert cases without offset

        vm.warp(startingTime - 1);
        uint256 epochEndWithOffset = hook.getEpochEndWithOffset(0);

        assertEq(epochEndWithOffset, startingTime + epochLength);

        vm.warp(startingTime);
        epochEndWithOffset = hook.getEpochEndWithOffset(0);

        assertEq(epochEndWithOffset, startingTime + epochLength);

        vm.warp(startingTime + epochLength);
        epochEndWithOffset = hook.getEpochEndWithOffset(0);

        assertEq(epochEndWithOffset, startingTime + epochLength * 2);

        vm.warp(startingTime + epochLength * 2);
        epochEndWithOffset = hook.getEpochEndWithOffset(0);

        assertEq(epochEndWithOffset, startingTime + epochLength * 3);

        vm.warp(endingTime - 1);
        epochEndWithOffset = hook.getEpochEndWithOffset(0);

        assertEq(epochEndWithOffset, endingTime);

        // Assert cases with epoch

        vm.warp(startingTime - 1);
        epochEndWithOffset = hook.getEpochEndWithOffset(1);

        assertEq(epochEndWithOffset, startingTime + epochLength * 2);

        vm.warp(startingTime);
        epochEndWithOffset = hook.getEpochEndWithOffset(1);

        assertEq(epochEndWithOffset, startingTime + epochLength * 2);

        vm.warp(startingTime + epochLength);
        epochEndWithOffset = hook.getEpochEndWithOffset(1);

        assertEq(epochEndWithOffset, startingTime + epochLength * 3);

        vm.warp(startingTime + epochLength * 2);
        epochEndWithOffset = hook.getEpochEndWithOffset(1);

        assertEq(epochEndWithOffset, startingTime + epochLength * 4);

        vm.warp(endingTime - epochLength - 1);
        epochEndWithOffset = hook.getEpochEndWithOffset(1);

        assertEq(epochEndWithOffset, endingTime);
    }

    // =========================================================================
    //               _alignComputedTickWithTickSpacing Unit Tests
    // =========================================================================

    function testAlignComputedTickWithTickSpacing(int24 tick, uint8 tickSpacing) public view {
        vm.assume(tickSpacing > 0);
        vm.assume(tickSpacing <= 30);

        int24 castTickSpacing = int24(int256(uint256(tickSpacing)));
        vm.assume(int256(tick) + int256(castTickSpacing) <= type(int24).max);
        vm.assume(int256(tick) - int256(castTickSpacing) >= type(int24).min);

        bool isToken0 = hook.isToken0();
        int24 alignedTick = hook.alignComputedTickWithTickSpacing(tick, castTickSpacing);

        // Validate that alignedTick is a multiple of tickSpacing
        assertEq(alignedTick % int24(int8(tickSpacing)), 0);

        // Validate that alignedTick is less than or equal to tick (depending on direction)
        if (isToken0) {
            assertLe(alignedTick, tick);
        } else {
            assertGe(alignedTick, tick);
        }
    }
}
