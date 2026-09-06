// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script } from "forge-std/Script.sol";

import { ForkPareFactory } from "../src/ForkPareFactory.sol";
import { INonfungiblePositionManager, IPancakeV3Factory } from "../src/interfaces/IPancakeV3.sol";

contract DeployForkPare is Script {
    address internal constant PANCAKE_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address internal constant PANCAKE_V3_POSITION_MANAGER =
        0x46A15B0b27311cedF172AB29E4f4766fbE7F4364;

    error WrongChain();
    error MissingCanonicalContract();

    function run() external returns (ForkPareFactory factory) {
        if (block.chainid != 56) revert WrongChain();
        if (PANCAKE_V3_FACTORY.code.length == 0 || PANCAKE_V3_POSITION_MANAGER.code.length == 0) {
            revert MissingCanonicalContract();
        }

        address treasury = vm.envAddress("FORKPARE_TREASURY");
        uint256 creationFee = vm.envUint("FORKPARE_CREATION_FEE_WEI");

        vm.startBroadcast();
        factory = new ForkPareFactory(
            IPancakeV3Factory(PANCAKE_V3_FACTORY),
            INonfungiblePositionManager(PANCAKE_V3_POSITION_MANAGER),
            treasury,
            creationFee
        );
        vm.stopBroadcast();
    }
}
