// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SafeTransferLib, ERC20 } from "@solmate/utils/SafeTransferLib.sol";
import { WETH as IWETH } from "@solmate/tokens/WETH.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { IUniswapV3Factory } from "@v3-core/interfaces/IUniswapV3Factory.sol";
import { IUniswapV3Pool } from "@v3-core/interfaces/IUniswapV3Pool.sol";
import { INonfungiblePositionManager } from "src/extensions/interfaces/INonfungiblePositionManager.sol";
import { ICustomUniswapV3Migrator } from "src/extensions/interfaces/ICustomUniswapV3Migrator.sol";
import { IBaseSwapRouter02 } from "src/extensions/interfaces/IBaseSwapRouter02.sol";
import { CustomUniswapV3Locker } from "src/extensions/CustomUniswapV3Locker.sol";
import { ImmutableAirlock } from "src/base/ImmutableAirlock.sol";
import { console } from "forge-std/console.sol";

/**
 * @author ant
 * @notice An extension for LiquidityMigrator to enable real-time fee streaming via Uniswap v3 pool & v3 locker contract
 */
contract CustomUniswapV3Migrator is ICustomUniswapV3Migrator, ImmutableAirlock {
    using SafeTransferLib for ERC20;

    /// @dev Constant used to increase precision during calculations
    uint256 constant WAD = 1 ether;
    uint256 constant MAX_SLIPPAGE_WAD = 0.15 ether; // 15% slippage
    uint256 constant REBALANCE_AMOUNT_WAD = 0.00001 ether; // 0.001% of liquidity used for rebalancing

    INonfungiblePositionManager public immutable NONFUNGIBLE_POSITION_MANAGER;
    IUniswapV3Factory public immutable FACTORY;
    IBaseSwapRouter02 public immutable ROUTER;
    IWETH public immutable WETH;
    CustomUniswapV3Locker public immutable CUSTOM_V3_LOCKER;
    uint24 public immutable FEE_TIER;

    mapping(address pool => address integratorFeeReceiver) public poolFeeReceivers;

    receive() external payable onlyAirlockOrRouter { }

    modifier onlyAirlockOrRouter() {
        require(msg.sender == address(airlock) || msg.sender == address(ROUTER), "Only Airlock or Router");
        _;
    }

    constructor(
        address airlock_,
        INonfungiblePositionManager positionManager_,
        IBaseSwapRouter02 router,
        address owner,
        address dopplerFeeReceiver_,
        uint24 feeTier_
    ) ImmutableAirlock(airlock_) {
        NONFUNGIBLE_POSITION_MANAGER = positionManager_;
        FACTORY = IUniswapV3Factory(router.factory());
        ROUTER = router;
        WETH = IWETH(payable(router.WETH9()));
        CUSTOM_V3_LOCKER =
            new CustomUniswapV3Locker(airlock_, FACTORY, positionManager_, this, owner, dopplerFeeReceiver_);
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

        // v3 pool only allows WETH
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
        int24 minTick = TickMath.minUsableTick(tickSpacing) + tickSpacing;
        int24 maxTick = TickMath.maxUsableTick(tickSpacing) - tickSpacing;
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(asset == token0 ? minTick : maxTick);
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
    ) external payable onlyAirlock returns (uint256) {
        // v3 pool only allows WETH, smaller address will be passed as token0 from Airlock so only need to check if token0 is address(0)
        if (token0 == address(0)) token0 = address(WETH);
        if (token0 > token1) (token0, token1) = (token1, token0);

        address pool = FACTORY.getPool(token0, token1, FEE_TIER);
        require(pool != address(0), PoolDoesNotExist());

        // in case the pool failed to initialize sqrtPriceX96 during `initialize`, initialize it with the given sqrtPriceX96
        (uint160 initializedSqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
        if (initializedSqrtPriceX96 == 0) {
            IUniswapV3Pool(pool).initialize(sqrtPriceX96);
        }

        // not sure if WETH is token0 or token1, so need to check both
        uint256 balance0;
        uint256 balance1;

        // only wrap ETH after confirming the pool exists to save gas
        if (token0 == address(WETH)) {
            WETH.deposit{ value: address(this).balance }();
            balance0 = WETH.balanceOf(address(this));
            balance1 = ERC20(token1).balanceOf(address(this));
        } else if (token1 == address(WETH)) {
            WETH.deposit{ value: address(this).balance }();
            balance1 = WETH.balanceOf(address(this));
            balance0 = ERC20(token0).balanceOf(address(this));
        }

        int24 tickSpacing = FACTORY.feeAmountTickSpacing(FEE_TIER);
        ERC20(token0).safeApprove(address(NONFUNGIBLE_POSITION_MANAGER), balance0);
        ERC20(token1).safeApprove(address(NONFUNGIBLE_POSITION_MANAGER), balance1);

        address integratorFeeReceiver = poolFeeReceivers[pool];
        if (initializedSqrtPriceX96 != 0) {
            (balance0, balance1) = _rebalance(
                token0,
                token1,
                balance0,
                balance1,
                initializedSqrtPriceX96,
                sqrtPriceX96,
                tickSpacing,
                integratorFeeReceiver,
                recipient
            );
        }

        int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        int24 finalTickLower = _getDivisibleTick(currentTick, tickSpacing, false);
        int24 finalTickUpper = _getDivisibleTick(currentTick, tickSpacing, true);

        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = NONFUNGIBLE_POSITION_MANAGER.mint(
            INonfungiblePositionManager.MintParams({
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
             })
        );

        // Call to safeTransfer will trigger `onERC721Received` which must return the selector else transfer will fail
        NONFUNGIBLE_POSITION_MANAGER.safeTransferFrom(address(this), address(CUSTOM_V3_LOCKER), tokenId);
        CUSTOM_V3_LOCKER.register(tokenId, amount0, amount1, integratorFeeReceiver, recipient);

        _refundDustAndRevokeAllowances(token0, token1, balance0, balance1, amount0, amount1, recipient);

        return liquidity;
    }

    function _rebalance(
        address token0,
        address token1,
        uint256 balance0,
        uint256 balance1,
        uint160 initializedSqrtPriceX96,
        uint160 targetSqrtPriceX96,
        int24 tickSpacing,
        address integratorFeeReceiver,
        address recipient
    ) internal returns (uint256 balance0AfterSwap, uint256 balance1AfterSwap) {
        uint256 rebalanceAmount0 = balance0 * REBALANCE_AMOUNT_WAD / WAD;
        uint256 rebalanceAmount1 = balance1 * REBALANCE_AMOUNT_WAD / WAD;

        int24 initTick = TickMath.getTickAtSqrtPrice(initializedSqrtPriceX96);

        // mint with current tick in order to have liquidity for swap
        (uint256 tokenId,, uint256 amount0, uint256 amount1) = NONFUNGIBLE_POSITION_MANAGER.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: FEE_TIER,
                tickLower: initTick - tickSpacing,
                tickUpper: initTick + tickSpacing,
                amount0Desired: rebalanceAmount0,
                amount1Desired: rebalanceAmount1,
                amount0Min: 1, // just need to make sure there is at least 1 liquidity for swap
                amount1Min: 1, // just need to make sure there is at least 1 liquidity for swap
                recipient: address(this),
                deadline: block.timestamp + 3600 // 1 hour
             })
        );
        // transfer the liquidity used for rebalancing to the locker as well
        NONFUNGIBLE_POSITION_MANAGER.safeTransferFrom(address(this), address(CUSTOM_V3_LOCKER), tokenId);
        CUSTOM_V3_LOCKER.register(tokenId, amount0, amount1, integratorFeeReceiver, recipient);

        // swap to rebalance the price
        uint256 amountIn = rebalanceAmount0 * MAX_SLIPPAGE_WAD / WAD; // just swap with 10% of the amount0 used for rebalancing to trigger price rebalancing
        ERC20(token0).safeApprove(address(ROUTER), amountIn);
        ROUTER.exactInputSingle(
            IBaseSwapRouter02.ExactInputSingleParams({
                tokenIn: token0,
                tokenOut: token1,
                fee: FEE_TIER,
                recipient: address(this),
                amountIn: amountIn,
                amountOutMinimum: rebalanceAmount1 * MAX_SLIPPAGE_WAD / WAD,
                sqrtPriceLimitX96: targetSqrtPriceX96
            })
        );

        balance0AfterSwap = balance0 - rebalanceAmount0;
        balance1AfterSwap = balance1 - rebalanceAmount1;
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

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
