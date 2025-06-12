// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SafeTransferLib, ERC20 } from "@solmate/utils/SafeTransferLib.sol";
import { WETH as IWETH } from "@solmate/tokens/WETH.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { FullMath } from "@v4-core/libraries/FullMath.sol";
import { FixedPoint96 } from "@v4-core/libraries/FixedPoint96.sol";
import { LiquidityAmounts } from "@v4-periphery/libraries/LiquidityAmounts.sol";
import { IUniswapV3Factory } from "@v3-core/interfaces/IUniswapV3Factory.sol";
import { IUniswapV3Pool } from "@v3-core/interfaces/IUniswapV3Pool.sol";
import { ICustomUniswapV3Migrator } from "src/extensions/interfaces/ICustomUniswapV3Migrator.sol";
import { INonfungiblePositionManager } from "src/extensions/interfaces/INonfungiblePositionManager.sol";
import { IBaseSwapRouter02 } from "src/extensions/interfaces/IBaseSwapRouter02.sol";
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

    mapping(address pool => address integratorFeeReceiver) public poolFeeReceivers;

    receive() external payable onlyAirlock { }

    /**
     * @notice Constructs the CustomUniswapV3Migrator and deploys a new CustomUniswapV3Locker
     * @param airlock_ Address of the Airlock contract that will call this migrator
     * @param positionManager_ Uniswap V3 NFT position manager for minting liquidity positions
     * @param router Uniswap V3 router to extract factory and WETH addresses
     * @param dopplerFeeReceiver_ Address that will receive the 5% protocol fee from collected LP fees
     * @param feeTier_ The fee tier (in basis points) for the V3 pools this migrator will create
     */
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

    /**
     * @notice Initializes a Uniswap V3 pool for future migration
     * @dev Creates the pool if it doesn't exist and initializes it at an extreme price.
     * @param asset The token being sold in the Doppler pool
     * @param numeraire The token used to purchase the asset (address(0) for ETH)
     * @param liquidityMigratorData Encoded integrator fee receiver address
     * @return pool The address of the created/existing V3 pool
     */
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

        (uint256 balance0, uint256 balance1) = _getTokenBalances(token0, token1);

        int24 tickSpacing = FACTORY.feeAmountTickSpacing(FEE_TIER);
        (int24 tickLower, int24 tickUpper) = _calculateValidTicks(sqrtPriceX96, tickSpacing);

        // (uint256 depositAmount0, uint256 depositAmount1) =
        //     MigrationMath.computeDepositAmounts(balance0, balance1, sqrtPriceX96);

        // if (depositAmount1 > balance1) {
        //     (, depositAmount1) = MigrationMath.computeDepositAmounts(depositAmount0, balance1, sqrtPriceX96);
        // } else {
        //     (depositAmount0,) = MigrationMath.computeDepositAmounts(balance0, depositAmount1, sqrtPriceX96);
        // }

        uint128 maxLiquidity = _computeMaxLiquidity(balance0, balance1, sqrtPriceX96, tickLower, tickUpper);
        (uint256 depositAmount0, uint256 depositAmount1) =
            _getTokenAmountsForLiquidity(maxLiquidity, sqrtPriceX96, tickLower, tickUpper);

        ERC20(token0).safeApprove(address(NONFUNGIBLE_POSITION_MANAGER), depositAmount0);
        ERC20(token1).safeApprove(address(NONFUNGIBLE_POSITION_MANAGER), depositAmount1);

        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = NONFUNGIBLE_POSITION_MANAGER.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: FEE_TIER,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: depositAmount0,
                amount1Desired: depositAmount1,
                amount0Min: depositAmount0 * 99 / 100, // 1% slippage
                amount1Min: depositAmount1 * 99 / 100, // 1% slippage
                recipient: address(CUSTOM_V3_LOCKER),
                deadline: block.timestamp
            })
        );

        CUSTOM_V3_LOCKER.register(tokenId, amount0, amount1, poolFeeReceivers[pool], recipient);

        _refundDustAndRevokeAllowances(token0, token1, recipient);

        return liquidity;
    }

    /**
     * @notice Rebalances the pool to the target sqrt price
     * @dev This is done by swapping any amount to move price - no tokens required as no liquidity
     * @param pool The pool to rebalance
     * @param targetSqrtPriceX96 The target sqrt price
     */
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

        // swap any amount to move price - no tokens required as no liquidity
        IUniswapV3Pool(pool).swap(address(this), zeroForOne, 1, sqrtPriceLimitX96, "");

        (uint160 newSqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
        require(newSqrtPriceX96 == targetSqrtPriceX96, RebalanceFailed());
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

    /**
     * @notice Calculates valid tick boundaries for a concentrated liquidity position
     * @dev Creates a narrow range around the current price, ensuring ticks are:
     *      1. Divisible by tickSpacing
     *      2. Within the usable tick range
     *      3. Properly ordered (lower < upper)
     *      Handles edge cases at price extremes by creating a minimal valid range.
     * @param sqrtPriceX96 The current sqrt price of the pool
     * @param tickSpacing The tick spacing of the pool
     * @return tickLower The lower tick boundary for the position
     * @return tickUpper The upper tick boundary for the position
     */
    function _calculateValidTicks(
        uint160 sqrtPriceX96,
        int24 tickSpacing
    ) internal pure returns (int24 tickLower, int24 tickUpper) {
        int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        tickLower = _getDivisibleTick(currentTick, tickSpacing, false);
        tickUpper = _getDivisibleTick(currentTick, tickSpacing, true);

        int24 minUsableTick = TickMath.minUsableTick(tickSpacing);
        int24 maxUsableTick = TickMath.maxUsableTick(tickSpacing);

        if (tickUpper > maxUsableTick) {
            tickUpper = maxUsableTick;
            tickLower = tickUpper - tickSpacing;
        }
        if (tickLower < minUsableTick) {
            tickLower = minUsableTick;
            tickUpper = tickLower + tickSpacing;
        }
    }

    /**
     * @notice Computes the maximum liquidity that can be created with the given balances
     * @dev Based on https://github.com/Uniswap/v4-core/blob/main/test/utils/LiquidityAmounts.sol
     * @param balance0 Balance of token0
     * @param balance1 Balance of token1
     * @param sqrtPriceX96 Current sqrt price of the pool
     * @param tickLower Lower tick boundary for the position
     * @param tickUpper Upper tick boundary for the position
     * @return liquidity The maximum liquidity that can be created
     */
    function _computeMaxLiquidity(
        uint256 balance0,
        uint256 balance1,
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper
    ) internal pure returns (uint128 liquidity) {
        uint160 sqrtRatioAX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtPriceAtTick(tickUpper);

        if (sqrtPriceX96 <= sqrtRatioAX96) {
            liquidity = LiquidityAmounts.getLiquidityForAmount0(sqrtRatioAX96, sqrtRatioBX96, balance0);
        } else if (sqrtPriceX96 < sqrtRatioBX96) {
            uint128 liquidity0 = LiquidityAmounts.getLiquidityForAmount0(sqrtPriceX96, sqrtRatioBX96, balance0);
            uint128 liquidity1 = LiquidityAmounts.getLiquidityForAmount1(sqrtRatioAX96, sqrtPriceX96, balance1);

            liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        } else {
            liquidity = LiquidityAmounts.getLiquidityForAmount1(sqrtRatioAX96, sqrtRatioBX96, balance1);
        }
    }

    /**
     * @notice Computes the exact token amounts needed for a given liquidity and a price range
     * @dev Based on https://github.com/Uniswap/v4-core/blob/main/test/utils/LiquidityAmounts.sol
     * @param liquidity The liquidity being valued
     * @param sqrtPriceX96 The current sqrt price of the pool
     * @param tickLower The lower tick boundary for the position
     * @param tickUpper The upper tick boundary for the position
     * @return amount0 The amount of token0 needed
     * @return amount1 The amount of token1 needed
     */
    function _getTokenAmountsForLiquidity(
        uint128 liquidity,
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        uint160 sqrtPriceAX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceBX96 = TickMath.getSqrtPriceAtTick(tickUpper);

        if (sqrtPriceX96 <= sqrtPriceAX96) {
            amount0 = _getAmount0ForLiquidity(sqrtPriceAX96, sqrtPriceBX96, liquidity);
        } else if (sqrtPriceX96 < sqrtPriceBX96) {
            amount0 = _getAmount0ForLiquidity(sqrtPriceX96, sqrtPriceBX96, liquidity);
            amount1 = _getAmount1ForLiquidity(sqrtPriceAX96, sqrtPriceX96, liquidity);
        } else {
            amount1 = _getAmount1ForLiquidity(sqrtPriceAX96, sqrtPriceBX96, liquidity);
        }
    }

    /**
     * @notice Computes the amount of token0 for a given amount of liquidity and a price range
     * @dev Based on https://github.com/Uniswap/v4-core/blob/main/test/utils/LiquidityAmounts.sol
     * @param sqrtPriceAX96 A sqrt price representing the first tick boundary
     * @param sqrtPriceBX96 A sqrt price representing the second tick boundary
     * @param liquidity The liquidity being valued
     * @return amount0 The amount of token0
     */
    function _getAmount0ForLiquidity(
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0) {
        if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);

        return FullMath.mulDiv(
            uint256(liquidity) << FixedPoint96.RESOLUTION, sqrtPriceBX96 - sqrtPriceAX96, sqrtPriceBX96
        ) / sqrtPriceAX96;
    }

    /**
     * @notice Computes the amount of token1 for a given amount of liquidity and a price range
     * @dev Based on https://github.com/Uniswap/v4-core/blob/main/test/utils/LiquidityAmounts.sol
     * @param sqrtPriceAX96 A sqrt price representing the first tick boundary
     * @param sqrtPriceBX96 A sqrt price representing the second tick boundary
     * @param liquidity The liquidity being valued
     * @return amount1 The amount of token1
     */
    function _getAmount1ForLiquidity(
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount1) {
        if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);

        return FullMath.mulDiv(liquidity, sqrtPriceBX96 - sqrtPriceAX96, FixedPoint96.Q96);
    }

    /**
     * @notice Refunds remaining tokens and ETH to the recipient and revokes allowances
     * @dev After minting the V3 position, any leftover tokens (dust) that couldn't be
     *      deposited due to price constraints are sent to the recipient.
     *      Also revokes token approvals.
     * @param token0 Address of token0
     * @param token1 Address of token1
     * @param recipient Address to receive the refunded tokens (timelock)
     */
    function _refundDustAndRevokeAllowances(address token0, address token1, address recipient) internal {
        if (address(this).balance > 0) {
            SafeTransferLib.safeTransferETH(recipient, address(this).balance);
        }

        uint256 balance0 = ERC20(token0).balanceOf(address(this));
        uint256 balance1 = ERC20(token1).balanceOf(address(this));

        if (balance0 != 0) {
            ERC20(token0).safeApprove(address(NONFUNGIBLE_POSITION_MANAGER), 0);
            ERC20(token0).safeTransfer(recipient, balance0);
        }

        if (balance1 != 0) {
            ERC20(token1).safeApprove(address(NONFUNGIBLE_POSITION_MANAGER), 0);
            ERC20(token1).safeTransfer(recipient, balance1);
        }
    }

    /**
     * @notice Gets the token balances for migration, considering WETH
     * @param token0 Address of token0
     * @param token1 Address of token1
     * @return balance0 Balance of token0
     * @return balance1 Balance of token1
     */
    function _getTokenBalances(address token0, address token1) internal returns (uint256 balance0, uint256 balance1) {
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
    }

    /**
     * @notice No-op callback for the rebalancing swap
     * @dev No transfers needed since the pool has no liquidity.
     */
    function uniswapV3SwapCallback(int256, int256, bytes calldata) external {
        // no-op - the rebalancing swap is done without any tokens
    }
}
