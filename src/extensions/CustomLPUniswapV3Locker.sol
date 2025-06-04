// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { SafeTransferLib, ERC20 } from "@solmate/utils/SafeTransferLib.sol";
import { FixedPointMathLib } from "@solmate/utils/FixedPointMathLib.sol";
import { IERC721Receiver } from "@openzeppelin/token/ERC721/IERC721Receiver.sol";
import { IUniswapV3Factory } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import { INonfungiblePositionManager } from "src/extensions/interfaces/INonfungiblePositionManager.sol";
import { ICustomUniswapV3Locker } from "src/extensions/interfaces/ICustomUniswapV3Locker.sol";
import { CustomUniswapV3Migrator } from "src/extensions/CustomUniswapV3Migrator.sol";
import { ImmutableAirlock } from "src/base/ImmutableAirlock.sol";

contract CustomLPUniswapV3Locker is ICustomUniswapV3Locker, Ownable, ImmutableAirlock, IERC721Receiver {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;
    using FixedPointMathLib for uint160;

    uint256 constant ONE_YEAR = 365 days;

    /// @notice Address of the Uniswap V3 factory
    IUniswapV3Factory public immutable FACTORY;

    /// @notice Address of the Uniswap V3 migrator
    CustomUniswapV3Migrator public immutable MIGRATOR;

    /// @notice Address of the Uniswap V3 nonfungible position manager
    INonfungiblePositionManager public immutable NONFUNGIBLE_POSITION_MANAGER;

    address public immutable DOPPLER_FEE_RECEIVER;

    /// @notice Returns the state of a pool
    mapping(uint256 tokenId => PositionState state) public positionStates;

    /**
     * @param migrator_ Address of the Custom Uniswap V3 migrator
     * @param dopplerFeeReceiver_ Address of the doppler fee receiver
     */
    constructor(
        address airlock_,
        IUniswapV3Factory factory_,
        CustomUniswapV3Migrator migrator_,
        address owner_,
        address dopplerFeeReceiver_
    ) Ownable(owner_) ImmutableAirlock(airlock_) {
        FACTORY = factory_;
        MIGRATOR = migrator_;
        DOPPLER_FEE_RECEIVER = dopplerFeeReceiver_;
    }

    /**
     * @notice Registers the LP tokens held by this contract with a fixed lock up period
     * @param tokenId Token ID of the NFT position
     * @param amount0 Amount of token0
     * @param amount1 Amount of token1
     * @param integratorFeeReceiver Address of the integrator fee receiver
     * @param timelock Address of the timelock
     */
    function register(
        uint256 tokenId,
        uint256 amount0,
        uint256 amount1,
        address integratorFeeReceiver,
        address timelock
    ) external {
        require(msg.sender == address(MIGRATOR), SenderNotMigrator());
        require(positionStates[tokenId].minUnlockDate == 0, PoolAlreadyInitialized());

        address owner = NONFUNGIBLE_POSITION_MANAGER.ownerOf(tokenId);
        require(owner == address(this), NFTPositionNotFound(tokenId));

        positionStates[tokenId] = PositionState({
            amount0: amount0,
            amount1: amount1,
            minUnlockDate: uint64(block.timestamp + ONE_YEAR),
            integratorFeeReceiver: integratorFeeReceiver,
            recipient: timelock
        });
    }

    function harvest(
        uint256 tokenId
    ) external {
        // set amount0Max and amount1Max to uint256.max to collect all fees
        // alternatively can set recipient to msg.sender and avoid another transaction in `sendToOwner`
        INonfungiblePositionManager.CollectParams memory params = INonfungiblePositionManager.CollectParams({
            tokenId: tokenId,
            recipient: address(this),
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });

        (uint256 collectedAmount0, uint256 collectedAmount1) = NONFUNGIBLE_POSITION_MANAGER.collect(params);

        // distribute fees - 95% to integratorFeeReceiver, 5% to DOPPLER_FEE_RECEIVER
        uint256 dopplerFee0 = collectedAmount0 * 5 / 100;
        uint256 dopplerFee1 = collectedAmount1 * 5 / 100;

        (,, address token0, address token1,,,,,,,,) = NONFUNGIBLE_POSITION_MANAGER.positions(tokenId);
        address integratorFeeReceiver = positionStates[tokenId].integratorFeeReceiver;

        ERC20(token0).safeTransfer(integratorFeeReceiver, collectedAmount0 - dopplerFee0);
        ERC20(token1).safeTransfer(integratorFeeReceiver, collectedAmount1 - dopplerFee1);
        ERC20(token0).safeTransfer(DOPPLER_FEE_RECEIVER, dopplerFee0);
        ERC20(token1).safeTransfer(DOPPLER_FEE_RECEIVER, dopplerFee1);
    }

    /**
     * @notice Unlocks the LP tokens by burning them after the lockup period, fees are sent to the owner
     * and the principal tokens to the recipient i.e. Timelock contract by default
     * @param tokenId Token ID of the NFT position
     */
    function claimFeesAndExit(
        uint256 tokenId
    ) external {
        PositionState memory state = positionStates[tokenId];

        require(state.minUnlockDate > 0, PoolNotInitialized());
        require(block.timestamp >= state.minUnlockDate, MinUnlockDateNotReached());

        // TODO: replace v2 with v3 whole liquidity withdrawal
        // // get previous reserves and share of invariant
        // uint256 kLast = uint256(state.amount0) * uint256(state.amount1);

        // (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(pool).getReserves();

        // uint256 balance = IUniswapV2Pair(pool).balanceOf(address(this));
        // IUniswapV2Pair(pool).transfer(pool, balance);

        // (uint256 amount0, uint256 amount1) = IUniswapV2Pair(pool).burn(address(this));

        // uint256 position0 = kLast.mulDivDown(reserve0, reserve1).sqrt();
        // uint256 position1 = kLast.mulDivDown(reserve1, reserve0).sqrt();

        // uint256 fees0 = amount0 > position0 ? amount0 - position0 : 0;
        // uint256 fees1 = amount1 > position1 ? amount1 - position1 : 0;

        // address token0 = IUniswapV2Pair(pool).token0();
        // address token1 = IUniswapV2Pair(pool).token1();

        // if (fees0 > 0) {
        //     SafeTransferLib.safeTransfer(ERC20(token0), owner(), fees0);
        // }
        // if (fees1 > 0) {
        //     SafeTransferLib.safeTransfer(ERC20(token1), owner(), fees1);
        // }

        // uint256 principal0 = fees0 > 0 ? amount0 - fees0 : amount0;
        // uint256 principal1 = fees1 > 0 ? amount1 - fees1 : amount1;

        // if (principal0 > 0) {
        //     SafeTransferLib.safeTransfer(ERC20(token0), state.recipient, principal0);
        // }
        // if (principal1 > 0) {
        //     SafeTransferLib.safeTransfer(ERC20(token1), state.recipient, principal1);
        // }
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
