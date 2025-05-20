// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { CustomLPUniswapV2Migrator } from "src/extensions/CustomLPUniswapV2Migrator.sol";
import { IUniswapV2Factory, IUniswapV2Router02 } from "src/UniswapV2Migrator.sol";

contract V4DeployContract is Script {
    function run() public {
        address airlock = 0xAa7f55aB611Ea07A6D4F4D58a05F4338C52e494b;
        address uniswapV2Factory = 0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6;
        address uniswapV2Router02 = 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24;
        address owner = 0xCCF7582371b4d6e3a77FFD423D1E9500EBD041Ac;

        vm.startBroadcast();

        CustomLPUniswapV2Migrator migrator = new CustomLPUniswapV2Migrator(
            airlock, IUniswapV2Factory(uniswapV2Factory), IUniswapV2Router02(uniswapV2Router02), owner
        );

        console.log("migrator deployed at", address(migrator));

        vm.stopBroadcast();
    }
}
