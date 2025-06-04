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
import { CustomLPUniswapV3Locker } from "src/extensions/CustomLPUniswapV3Locker.sol";
import { ImmutableAirlock } from "src/base/ImmutableAirlock.sol";

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
    CustomLPUniswapV3Locker public immutable CUSTOM_V3_LOCKER;
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
        CUSTOM_V3_LOCKER = new CustomLPUniswapV3Locker(airlock_, FACTORY, this, owner, dopplerFeeReceiver_);
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
        poolFeeReceivers[pool] = integratorFeeReceiver;

        (address token0, address token1) = asset < numeraire ? (asset, numeraire) : (numeraire, asset);

        pool = FACTORY.getPool(token0, token1, FEE_TIER);
        if (pool == address(0)) {
            pool = FACTORY.createPool(token0, token1, FEE_TIER);
        }

        bool isToken0 = asset == token0;

        int24 tickSpacing = FACTORY.feeAmountTickSpacing(FEE_TIER);
        int24 lowerTick = (TickMath.MIN_TICK / tickSpacing) * tickSpacing;
        int24 upperTick = (TickMath.MAX_TICK / tickSpacing) * tickSpacing;
        _checkTickDivisible(lowerTick, tickSpacing);
        _checkTickDivisible(upperTick, tickSpacing);
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(isToken0 ? lowerTick : upperTick);

        IUniswapV3Pool(pool).initialize(sqrtPriceX96);

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
    ) external payable onlyAirlock returns (uint256) { }

    function _checkTickDivisible(int24 tick, int24 tickSpacing) internal pure {
        if (tick % tickSpacing != 0) revert TickNotDivisible(tick, tickSpacing);
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
