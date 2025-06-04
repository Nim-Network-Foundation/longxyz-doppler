// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ISwapRouter } from "@v3-periphery/interfaces/ISwapRouter.sol";

interface ISwapRouter02 is ISwapRouter {
    function factory() external view returns (address);
    function WETH9() external view returns (address);
}
