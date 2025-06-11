// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SafeTransferLib, ERC20 } from "@solmate/utils/SafeTransferLib.sol";
import { FixedPointMathLib } from "@solmate/utils/FixedPointMathLib.sol";
import { IERC721Receiver } from "@openzeppelin/token/ERC721/IERC721Receiver.sol";
import { INonfungiblePositionManager } from "src/extensions/interfaces/INonfungiblePositionManager.sol";
import { ICustomUniswapV3Locker } from "src/extensions/interfaces/ICustomUniswapV3Locker.sol";
import { CustomUniswapV3Migrator } from "src/extensions/CustomUniswapV3Migrator.sol";
import { ImmutableAirlock } from "src/base/ImmutableAirlock.sol";

/**
 * @author ant
 * @notice An extension built on top of CustomUniswapV3Migrator to enable real-time fee streaming by escrowing LP for a fixed period
 */
contract CustomUniswapV3Locker is ICustomUniswapV3Locker, IERC721Receiver {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;
    using FixedPointMathLib for uint160;

    uint256 constant ONE_YEAR = 365 days;
    uint256 constant DOPPLER_FEE_WAD = 0.05 ether;
    uint256 constant WAD = 1 ether;

    /// @notice Address of the Uniswap V3 nonfungible position manager
    INonfungiblePositionManager public immutable NONFUNGIBLE_POSITION_MANAGER;

    /// @notice Address of the Uniswap V3 migrator
    CustomUniswapV3Migrator public immutable MIGRATOR;

    address public immutable DOPPLER_FEE_RECEIVER;

    /// @notice Returns the state of a pool
    mapping(uint256 tokenId => PositionState state) public positionStates;

    /**
     * @param migrator_ Address of the Custom Uniswap V3 migrator
     * @param dopplerFeeReceiver_ Address of the doppler fee receiver
     */
    constructor(
        INonfungiblePositionManager nonfungiblePositionManager_,
        CustomUniswapV3Migrator migrator_,
        address dopplerFeeReceiver_
    ) {
        NONFUNGIBLE_POSITION_MANAGER = nonfungiblePositionManager_;
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
        require(integratorFeeReceiver != address(0), ZeroFeeReceiverAddress());

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
    ) public returns (uint256 collectedAmount0, uint256 collectedAmount1) {
        // set amount0Max and amount1Max to uint256.max to collect all fees
        (collectedAmount0, collectedAmount1) = NONFUNGIBLE_POSITION_MANAGER.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        _distributeFees(collectedAmount0, collectedAmount1, tokenId);
    }

    /**
     * @notice Transfers the whole LP to the recipient i.e. Timelock contract after the lockup period, fees are distributed once more before unlocking
     * @param tokenId Token ID of the NFT position
     */
    function unlock(
        uint256 tokenId
    ) external {
        PositionState memory state = positionStates[tokenId];

        require(state.minUnlockDate > 0, PoolNotInitialized());
        require(block.timestamp >= state.minUnlockDate, MinUnlockDateNotReached());

        harvest(tokenId);
        // TimelockController is safe to receive ERC721 tokens
        NONFUNGIBLE_POSITION_MANAGER.safeTransferFrom(address(this), state.recipient, tokenId);
    }

    function _distributeFees(uint256 collectedAmount0, uint256 collectedAmount1, uint256 tokenId) internal {
        (,, address token0, address token1,,,,,,,,) = NONFUNGIBLE_POSITION_MANAGER.positions(tokenId);
        address integratorFeeReceiver = positionStates[tokenId].integratorFeeReceiver;

        // distribute fees - 95% to integratorFeeReceiver, 5% to DOPPLER_FEE_RECEIVER
        if (collectedAmount0 > 0) {
            uint256 dopplerFee0 = collectedAmount0 * DOPPLER_FEE_WAD / WAD;
            ERC20(token0).safeTransfer(integratorFeeReceiver, collectedAmount0 - dopplerFee0);
            ERC20(token0).safeTransfer(DOPPLER_FEE_RECEIVER, dopplerFee0);
        }

        if (collectedAmount1 > 0) {
            uint256 dopplerFee1 = collectedAmount1 * DOPPLER_FEE_WAD / WAD;
            ERC20(token1).safeTransfer(integratorFeeReceiver, collectedAmount1 - dopplerFee1);
            ERC20(token1).safeTransfer(DOPPLER_FEE_RECEIVER, dopplerFee1);
        }
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
