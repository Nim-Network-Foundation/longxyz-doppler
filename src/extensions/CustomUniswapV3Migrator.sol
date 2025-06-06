// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SafeTransferLib, ERC20 } from "@solmate/utils/SafeTransferLib.sol";
import { WETH as IWETH } from "@solmate/tokens/WETH.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { IUniswapV3Factory } from "@v3-core/interfaces/IUniswapV3Factory.sol";
import { IUniswapV3Pool } from "@v3-core/interfaces/IUniswapV3Pool.sol";
import { INonfungiblePositionManager } from "src/extensions/interfaces/INonfungiblePositionManager.sol";
import { ICustomUniswapV3Migrator } from "src/extensions/interfaces/ICustomUniswapV3Migrator.sol";
import { ISwapRouter02 } from "src/extensions/interfaces/ISwapRouter02.sol";
import { CustomUniswapV3Locker } from "src/extensions/CustomUniswapV3Locker.sol";
import { ImmutableAirlock } from "src/base/ImmutableAirlock.sol";
import { console } from "forge-std/console.sol";

/**
 * @author ant
 * @notice An extension built on top of UniswapV2Migrator to enable locking LP for a custom period
 */
contract CustomUniswapV3Migrator is ICustomUniswapV3Migrator, ImmutableAirlock {
    using SafeTransferLib for ERC20;

    /// @dev Constant used to increase precision during calculations
    uint256 constant WAD = 1 ether;
    uint256 constant MAX_SLIPPAGE_WAD = 0.05 ether; // 5% slippage

    INonfungiblePositionManager public immutable NONFUNGIBLE_POSITION_MANAGER;
    IUniswapV3Factory public immutable FACTORY;
    IWETH public immutable WETH;
    CustomUniswapV3Locker public immutable CUSTOM_V3_LOCKER;
    uint24 public immutable FEE_TIER;

    mapping(address pool => address integratorFeeReceiver) public poolFeeReceivers;

    receive() external payable onlyAirlock { }

    constructor(
        address airlock_,
        INonfungiblePositionManager positionManager_,
        ISwapRouter02 router,
        address owner,
        address dopplerFeeReceiver_,
        uint24 feeTier_
    ) ImmutableAirlock(airlock_) {
        NONFUNGIBLE_POSITION_MANAGER = positionManager_;
        FACTORY = IUniswapV3Factory(router.factory());
        WETH = IWETH(payable(router.WETH9()));
        CUSTOM_V3_LOCKER = new CustomUniswapV3Locker(airlock_, FACTORY, this, owner, dopplerFeeReceiver_, positionManager_);
        FEE_TIER = feeTier_;
    }

    function initialize(
        address asset,
        address numeraire,
        bytes calldata liquidityMigratorData
    ) external onlyAirlock returns (address pool) {
        require(liquidityMigratorData.length > 0, EmptyLiquidityMigratorData());

        (int24 tickLower, int24 tickUpper, address integratorFeeReceiver) =
            abi.decode(liquidityMigratorData, (int24, int24, address));
        require(integratorFeeReceiver != address(0), ZeroFeeReceiverAddress());

        (address token0, address token1) = asset < numeraire ? (asset, numeraire) : (numeraire, asset);

        pool = FACTORY.getPool(token0, token1, FEE_TIER);
        if (pool == address(0)) {
            pool = FACTORY.createPool(token0, token1, FEE_TIER);
        }
        poolFeeReceivers[pool] = integratorFeeReceiver;

        int24 tickSpacing = FACTORY.feeAmountTickSpacing(FEE_TIER);
        // int24 finalTickLower = _getDivisibleTick(tickLower, tickSpacing, false);
        // int24 finalTickUpper = _getDivisibleTick(tickUpper, tickSpacing, true);
        int24 lowerTick = TickMath.minUsableTick(tickSpacing);
        int24 upperTick = TickMath.maxUsableTick(tickSpacing);
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(asset == token0 ? lowerTick : upperTick);

        // IUniswapV3Pool(pool).initialize(sqrtPriceX96);

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
        address pool = FACTORY.getPool(token0, token1, FEE_TIER);
        require(pool != address(0), PoolDoesNotExist());

        // if the pool is not initialized, initialize it with the given sqrtPriceX96
        (uint160 currentSqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
        if (currentSqrtPriceX96 == 0) {
            IUniswapV3Pool(pool).initialize(sqrtPriceX96);
        }

        uint256 balance0;
        uint256 balance1 = ERC20(token1).balanceOf(address(this));

        if (token0 == address(0)) {
            token0 = address(WETH);
            WETH.deposit{ value: address(this).balance }();
            balance0 = WETH.balanceOf(address(this));
        } else {
            balance0 = ERC20(token0).balanceOf(address(this));
        }

        if (token0 > token1) {
            (token0, token1) = (token1, token0);
            (balance0, balance1) = (balance1, balance0);
        }

        int24 tickSpacing = FACTORY.feeAmountTickSpacing(FEE_TIER);
        int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        // int24 lowerTick = (TickMath.MIN_TICK / tickSpacing) * tickSpacing;
        // int24 upperTick = (TickMath.MAX_TICK / tickSpacing) * tickSpacing;

        console.log("currentTick", currentTick);
        int24 finalTickLower = _getDivisibleTick(currentTick, tickSpacing, false);
        int24 finalTickUpper = _getDivisibleTick(currentTick, tickSpacing, true);
        // require(currentTick >= lowerTick && currentTick <= upperTick, TickOutOfRange(currentTick, lowerTick, upperTick));

        // Approve the position manager
        ERC20(token0).safeApprove(address(NONFUNGIBLE_POSITION_MANAGER), balance0);
        ERC20(token1).safeApprove(address(NONFUNGIBLE_POSITION_MANAGER), balance1);

        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            fee: FEE_TIER,
            tickLower: finalTickLower,
            tickUpper: finalTickUpper,
            amount0Desired: balance0,
            amount1Desired: balance1,
            amount0Min: balance0 * (WAD - MAX_SLIPPAGE_WAD) / WAD,
            amount1Min: balance1 * (WAD - MAX_SLIPPAGE_WAD) / WAD,
            recipient: address(this),
            deadline: block.timestamp + 3600 // 1 hour
         });

        // NOTE: the pool defined by token0/token1 must already be created and initialized in order to mint
        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) =
            NONFUNGIBLE_POSITION_MANAGER.mint(params);

        // Call to safeTransfer will trigger `onERC721Received` which must return the selector else transfer will fail
        NONFUNGIBLE_POSITION_MANAGER.safeTransferFrom(address(this), address(CUSTOM_V3_LOCKER), tokenId);
        CUSTOM_V3_LOCKER.register(tokenId, amount0, amount1, poolFeeReceivers[pool], recipient);

        _refundDustAndRevokeAllowances(token0, token1, balance0, balance1, amount0, amount1, recipient);

        return liquidity;
    }

    function _getDivisibleTick(int24 tick, int24 tickSpacing, bool isUpper) internal pure returns (int24 finalTick) {
        finalTick = tick;

        if (tick % tickSpacing != 0) {
            if (isUpper) {
                finalTick = (tick + tickSpacing) / tickSpacing * tickSpacing; // Math.ceil(currentTick / tickSpacing) * tickSpacing;
            } else {
                finalTick = (tick / tickSpacing) * tickSpacing;
            }
        }

        if (tick == 0 && isUpper) finalTick = tickSpacing;
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
}
