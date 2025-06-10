// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SafeTransferLib, ERC20 } from "@solmate/utils/SafeTransferLib.sol";
import { WETH as IWETH } from "@solmate/tokens/WETH.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { IUniswapV3Factory } from "@v3-core/interfaces/IUniswapV3Factory.sol";
import { IUniswapV3Pool } from "@v3-core/interfaces/IUniswapV3Pool.sol";
import { ICustomUniswapV3Migrator } from "src/extensions/interfaces/ICustomUniswapV3Migrator.sol";
import { INonfungiblePositionManager } from "src/extensions/interfaces/INonfungiblePositionManager.sol";
import { IBaseSwapRouter02 } from "src/extensions/interfaces/IBaseSwapRouter02.sol";
import { MigrationMath } from "src/libs/MigrationMath.sol";
import { CustomUniswapV3Locker } from "src/extensions/CustomUniswapV3Locker.sol";
import { ImmutableAirlock } from "src/base/ImmutableAirlock.sol";

/**
 * @author ant
 * @notice An extension for LiquidityMigrator to enable real-time fee streaming via Uniswap v3 pool & v3 locker contract
 */
contract CustomUniswapV3Migrator is ICustomUniswapV3Migrator, ImmutableAirlock {
    using SafeTransferLib for ERC20;

    INonfungiblePositionManager public immutable NONFUNGIBLE_POSITION_MANAGER;
    IUniswapV3Factory public immutable FACTORY;
    IWETH public immutable WETH;
    CustomUniswapV3Locker public immutable CUSTOM_V3_LOCKER;
    uint24 public immutable FEE_TIER;

    /// @dev Transient pool used for swap callback
    address private currentPool = address(1);

    mapping(address pool => address integratorFeeReceiver) public poolFeeReceivers;

    receive() external payable onlyAirlock { }

    constructor(
        address airlock_,
        INonfungiblePositionManager positionManager_,
        IBaseSwapRouter02 router,
        address dopplerFeeReceiver_,
        uint24 feeTier_
    ) ImmutableAirlock(airlock_) {
        NONFUNGIBLE_POSITION_MANAGER = positionManager_;
        FACTORY = IUniswapV3Factory(router.factory());
        WETH = IWETH(payable(router.WETH9()));
        CUSTOM_V3_LOCKER = new CustomUniswapV3Locker(positionManager_, this, dopplerFeeReceiver_);
        FEE_TIER = feeTier_;
    }

    function initialize(
        address asset,
        address numeraire,
        bytes calldata liquidityMigratorData
    ) external onlyAirlock returns (address pool) {
        require(liquidityMigratorData.length > 0, EmptyLiquidityMigratorData());

        (address integratorFeeReceiver) = abi.decode(liquidityMigratorData, (address));
        require(integratorFeeReceiver != address(0), ZeroFeeReceiverAddress());

        if (numeraire == address(0)) numeraire = address(WETH);
        (address token0, address token1) = asset < numeraire ? (asset, numeraire) : (numeraire, asset);

        pool = FACTORY.getPool(token0, token1, FEE_TIER);
        if (pool == address(0)) {
            pool = FACTORY.createPool(token0, token1, FEE_TIER);
        }
        poolFeeReceivers[pool] = integratorFeeReceiver;

        // NOTE: we are aware that anyone can initialize the pool with any sqrtPriceX96 after pool creation,
        // so we will initialize price ourselves and later on rebalance the price during migration
        int24 tickSpacing = FACTORY.feeAmountTickSpacing(FEE_TIER);
        int24 minTickWithSpacing = TickMath.minUsableTick(tickSpacing) + tickSpacing;
        int24 maxTickWithSpacing = TickMath.maxUsableTick(tickSpacing) - tickSpacing;
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(asset == token0 ? minTickWithSpacing : maxTickWithSpacing);

        try IUniswapV3Pool(pool).initialize(sqrtPriceX96) { } catch { }

        return pool;
    }

    /**
     * @notice Migrates the liquidity into a Uniswap V3 pool
     * @param sqrtPriceX96 Square root price of the pool as a Q64.96 value
     * @param token0 Smaller address of the two tokens
     * @param token1 Larger address of the two tokens
     * @param recipient Address receiving the liquidity pool tokens i.e. timelock
     */
    function migrate(
        uint160 sqrtPriceX96,
        address token0,
        address token1,
        address recipient
    ) external payable onlyAirlock returns (uint256) {
        if (token0 == address(0)) token0 = address(WETH);
        if (token0 > token1) (token0, token1) = (token1, token0);

        address pool = FACTORY.getPool(token0, token1, FEE_TIER);
        require(pool != address(0), PoolDoesNotExist());

        _rebalance(pool, sqrtPriceX96);

        uint256 balance0;
        uint256 balance1;

        if (token0 == address(WETH)) {
            WETH.deposit{ value: address(this).balance }();
            balance0 = WETH.balanceOf(address(this));
            balance1 = ERC20(token1).balanceOf(address(this));
        } else if (token1 == address(WETH)) {
            WETH.deposit{ value: address(this).balance }();
            balance1 = WETH.balanceOf(address(this));
            balance0 = ERC20(token0).balanceOf(address(this));
        } else {
            balance0 = ERC20(token0).balanceOf(address(this));
            balance1 = ERC20(token1).balanceOf(address(this));
        }

        (uint256 depositAmount0, uint256 depositAmount1) =
            MigrationMath.computeDepositAmounts(balance0, balance1, sqrtPriceX96);

        if (depositAmount1 > balance1) {
            (, depositAmount1) = MigrationMath.computeDepositAmounts(depositAmount0, balance1, sqrtPriceX96);
        } else {
            (depositAmount0,) = MigrationMath.computeDepositAmounts(balance0, depositAmount1, sqrtPriceX96);
        }

        int24 tickSpacing = FACTORY.feeAmountTickSpacing(FEE_TIER);

        ERC20(token0).safeApprove(address(NONFUNGIBLE_POSITION_MANAGER), depositAmount0);
        ERC20(token1).safeApprove(address(NONFUNGIBLE_POSITION_MANAGER), depositAmount1);

        (int24 finalTickLower, int24 finalTickUpper) = _calculateValidTicks(sqrtPriceX96, tickSpacing);

        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = NONFUNGIBLE_POSITION_MANAGER.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: FEE_TIER,
                tickLower: finalTickLower,
                tickUpper: finalTickUpper,
                amount0Desired: depositAmount0,
                amount1Desired: depositAmount1,
                amount0Min: 0, // no slippage protection as deposit amount is already calculated based on price, rest will be treated as dust as v2 migrator
                amount1Min: 0,
                recipient: address(CUSTOM_V3_LOCKER),
                deadline: block.timestamp
            })
        );

        CUSTOM_V3_LOCKER.register(tokenId, amount0, amount1, poolFeeReceivers[pool], recipient);

        _refundDustAndRevokeAllowances(token0, token1, balance0, balance1, depositAmount0, depositAmount1, recipient);

        return liquidity;
    }

    function _rebalance(address pool, uint160 targetSqrtPriceX96) internal {
        (uint160 currentSqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();

        if (currentSqrtPriceX96 == 0) {
            IUniswapV3Pool(pool).initialize(targetSqrtPriceX96);
            return;
        }

        if (currentSqrtPriceX96 == targetSqrtPriceX96) {
            return;
        }

        bool zeroForOne = targetSqrtPriceX96 < currentSqrtPriceX96;

        currentPool = pool;

        uint160 sqrtPriceLimitX96;
        if (zeroForOne) {
            // price is decreasing, limit must be between target and MIN
            sqrtPriceLimitX96 =
                targetSqrtPriceX96 > TickMath.MIN_SQRT_PRICE + 1 ? targetSqrtPriceX96 : TickMath.MIN_SQRT_PRICE + 1;
        } else {
            // Price is increasing, limit must be between target and MAX
            sqrtPriceLimitX96 =
                targetSqrtPriceX96 < TickMath.MAX_SQRT_PRICE - 1 ? targetSqrtPriceX96 : TickMath.MAX_SQRT_PRICE - 1;
        }

        // swap minimal amount to move price
        IUniswapV3Pool(pool).swap(
            address(this),
            zeroForOne,
            1, // minimal amount
            sqrtPriceLimitX96,
            ""
        );

        (uint160 newSqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
        require(newSqrtPriceX96 == targetSqrtPriceX96, RebalanceFailed());

        currentPool = address(1);
    }

    function _getDivisibleTick(int24 tick, int24 tickSpacing, bool isUpper) internal pure returns (int24 finalTick) {
        if (isUpper) {
            // round up to next tick spacing boundary
            finalTick = tick % tickSpacing == 0 ? tick + tickSpacing : ((tick / tickSpacing) + 1) * tickSpacing;
        } else {
            // round down to previous tick spacing boundary
            finalTick = tick % tickSpacing == 0 ? tick - tickSpacing : (tick / tickSpacing) * tickSpacing;
        }
    }

    function _calculateValidTicks(
        uint160 sqrtPriceX96,
        int24 tickSpacing
    ) internal pure returns (int24 finalTickLower, int24 finalTickUpper) {
        int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        finalTickLower = _getDivisibleTick(currentTick, tickSpacing, false);
        finalTickUpper = _getDivisibleTick(currentTick, tickSpacing, true);

        // ensure ticks are within usable bounds
        int24 minUsableTick = TickMath.minUsableTick(tickSpacing);
        int24 maxUsableTick = TickMath.maxUsableTick(tickSpacing);

        if (finalTickLower < minUsableTick) finalTickLower = minUsableTick;
        if (finalTickUpper > maxUsableTick) finalTickUpper = maxUsableTick;

        // if we're at extreme ticks, create a minimal valid range
        if (finalTickLower >= finalTickUpper) {
            if (currentTick >= maxUsableTick - tickSpacing) {
                finalTickUpper = maxUsableTick;
                finalTickLower = maxUsableTick - 2 * tickSpacing;
            } else if (currentTick <= minUsableTick + tickSpacing) {
                finalTickLower = minUsableTick;
                finalTickUpper = minUsableTick + 2 * tickSpacing;
            }
        }
    }

    function _refundDustAndRevokeAllowances(
        address token0,
        address token1,
        uint256 balance0,
        uint256 balance1,
        uint256 amount0,
        uint256 amount1,
        address recipient
    ) internal {
        if (address(this).balance > 0) {
            SafeTransferLib.safeTransferETH(recipient, address(this).balance);
        }

        if (amount0 < balance0) {
            ERC20(token0).safeApprove(address(NONFUNGIBLE_POSITION_MANAGER), 0);
            uint256 refund0 = balance0 - amount0;
            ERC20(token0).safeTransfer(msg.sender, refund0);
        }

        if (amount1 < balance1) {
            ERC20(token1).safeApprove(address(NONFUNGIBLE_POSITION_MANAGER), 0);
            uint256 refund1 = balance1 - amount1;
            ERC20(token1).safeTransfer(msg.sender, refund1);
        }
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        require(msg.sender == currentPool, InvalidPoolCallback());

        if (amount0Delta > 0) {
            ERC20(IUniswapV3Pool(msg.sender).token0()).safeTransfer(msg.sender, uint256(amount0Delta));
        } else if (amount1Delta > 0) {
            ERC20(IUniswapV3Pool(msg.sender).token1()).safeTransfer(msg.sender, uint256(amount1Delta));
        }
    }
}
