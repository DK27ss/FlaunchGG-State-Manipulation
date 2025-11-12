# flETH Technical Deep Dive: withdraw() Flow Analysis

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [withdraw() Execution Paths](#withdraw-execution-paths)
4. [_transferETH Trigger Conditions](#transfereth-trigger-conditions)
5. [Contract Interactions](#contract-interactions)
6. [Attack Vectors Analysis](#attack-vectors-analysis)

---

## Overview

This document provides a comprehensive technical analysis of the flETH `withdraw()` function, detailing:
- All 3 execution paths that trigger `_transferETH()`
- Conditions that determine which path is taken
- Complete interaction chain: flETH → Strategy → Gateway → Aave

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                         User/Attacker                        │
└────────────────────────┬────────────────────────────────────┘
                         │
                         │ withdraw(amount)
                         ▼
┌─────────────────────────────────────────────────────────────┐
│                    flETH (Main Contract)                     │
│  Address: 0x000000000D564D5be76f7f0d28fE52605afC7Cf8        │
│                                                              │
│  State:                                                      │
│  - balance: ETH held directly                               │
│  - totalSupply: Total flETH tokens                          │
│  - rebalanceThreshold: 0.1 ether (10%)                      │
└────────────────┬───────────────────────────┬─────────────────┘
                 │                           │
                 │ (Path 1/2)                │ (Path 3)
                 │ withdrawETH()             │ _transferETH()
                 ▼                           │
┌─────────────────────────────────────────────┐              │
│     AaveV3Strategy (Yield Manager)          │              │
│  Address: 0xd93855bab40a80Df2f8c...        │              │
│                                             │              │
│  State:                                     │              │
│  - aWETH balance in Aave                   │              │
└────────────────┬────────────────────────────┘              │
                 │                                            │
                 │ withdrawETH()                             │
                 ▼                                            │
┌─────────────────────────────────────────────┐              │
│    FlAaveV3WethGateway (Aave Wrapper)       │              │
│  Address: [Gateway Contract]                │              │
│                                             │              │
│  Actions:                                   │              │
│  1. Pull aWETH from Strategy               │              │
│  2. Withdraw WETH from Aave Pool           │              │
│  3. Unwrap WETH → ETH                      │              │
│  4. Send ETH to recipient                  │              │
└────────────────┬────────────────────────────┘              │
                 │                                            │
                 │ ETH transfer                              │
                 ▼                                            │
┌─────────────────────────────────────────────┐              │
│              Aave V3 Pool                   │              │
│  - Holds WETH deposits                     │              │
│  - Issues aWETH tokens                     │              │
│  - Generates yield                         │              │
└─────────────────────────────────────────────┘              │
                                                              │
                 ┌────────────────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────┐
│           User/Attacker receives ETH         │
└─────────────────────────────────────────────┘
```

---

## withdraw() Execution Paths

### Source Code Reference: flETH.sol (Lines 105-164)

```solidity
function withdraw(uint amount) external override {
    // STEP 1: Burn tokens (reduces totalSupply)
    _burn(msg.sender, amount);

    // STEP 2: Capture current ETH balance
    uint currentEthBalance = address(this).balance;

    // STEP 3: Determine execution path based on balance
    if (amount > currentEthBalance) {
        // PATH 1 or PATH 2: Need to withdraw from Strategy

        if (address(strategy) == address(0))
            revert AmountExceedsETHBalance();

        uint newTotalSupply = totalSupply();
        uint expectedNewEthBalance;
        unchecked {
            expectedNewEthBalance = (rebalanceThreshold * newTotalSupply) / 1 ether;
        }

        if (expectedNewEthBalance <= currentEthBalance) {
            // === PATH 1: Partial direct transfer + Strategy withdrawal ===

            uint rawEthToTransfer;
            unchecked {
                rawEthToTransfer = currentEthBalance - expectedNewEthBalance;
            }

            uint strategyETHToWithdraw = amount - rawEthToTransfer;

            // LINE 140: First _transferETH
            _transferETH(msg.sender, rawEthToTransfer);

            // LINE 143: Strategy withdraws directly to user
            strategy.withdrawETH(strategyETHToWithdraw, msg.sender);

        } else {
            // === PATH 2: Strategy withdraws to flETH first ===

            uint rawEthRequiredToReachThreshold = expectedNewEthBalance - currentEthBalance;

            // LINE 153: Strategy withdraws to address(this)
            strategy.withdrawETH(amount + rawEthRequiredToReachThreshold, address(this));

            // LINE 157: Second _transferETH (CRITICAL: Reentrancy point!)
            _transferETH(msg.sender, amount);
        }
    } else {
        // === PATH 3: Simple direct transfer ===

        // LINE 162: Third _transferETH
        _transferETH(msg.sender, amount);
    }
}
```

---

## _transferETH Trigger Conditions

### PATH 1: Split Transfer (Line 140 + Strategy to User)

**Condition Checker**:
```solidity
amount > currentEthBalance AND
expectedNewEthBalance <= currentEthBalance
```

**When it triggers**:
```
Given:
- amount to withdraw: 100 ETH
- currentEthBalance: 50 ETH
- totalSupply after burn: 600 ETH
- rebalanceThreshold: 0.1 ether (10%)

Calculate:
- expectedNewEthBalance = (0.1 * 600) = 60 ETH
- expectedNewEthBalance (60) <= currentEthBalance (50)? NO

This condition is FALSE, so PATH 1 doesn't trigger.
```

**Typical scenario where PATH 1 triggers**:
```
Given:
- amount to withdraw: 20 ETH
- currentEthBalance: 70 ETH
- totalSupply after burn: 600 ETH
- rebalanceThreshold: 0.1 ether (10%)

Calculate:
- expectedNewEthBalance = (0.1 * 600) = 60 ETH
- expectedNewEthBalance (60) <= currentEthBalance (70)? YES ✓

Execution:
1. rawEthToTransfer = 70 - 60 = 10 ETH
2. _transferETH(user, 10 ETH)           ← LINE 140
3. strategyETHToWithdraw = 20 - 10 = 10 ETH
4. strategy.withdrawETH(10, user)       ← Bypasses flETH
```

**Key insight**: User receives ETH from **TWO sources**:
- Part directly from flETH (line 140)
- Part directly from Strategy (line 143, bypasses flETH)

---

### PATH 2: Strategy → flETH → User (Line 153 + Line 157)

**Condition Checker**:
```solidity
amount > currentEthBalance AND
expectedNewEthBalance > currentEthBalance
```

**When it triggers**:
```
Given:
- amount to withdraw: 100 ETH
- currentEthBalance: 10 ETH
- totalSupply after burn: 600 ETH
- rebalanceThreshold: 0.1 ether (10%)

Calculate:
- expectedNewEthBalance = (0.1 * 600) = 60 ETH
- amount (100) > currentEthBalance (10)? YES ✓
- expectedNewEthBalance (60) > currentEthBalance (10)? YES ✓

Execution:
1. rawEthRequiredToReachThreshold = 60 - 10 = 50 ETH
2. strategy.withdrawETH(100 + 50 = 150 ETH, address(this)) ← LINE 153
   → Strategy sends 150 ETH to flETH
   → flETH balance becomes: 10 + 150 = 160 ETH
3. _transferETH(user, 100 ETH)                              ← LINE 157 ⚠️ REENTRANCY!
   → User receives 100 ETH
   → flETH balance becomes: 160 - 100 = 60 ETH (at threshold!)
```

**Key insight**: This is the **CRITICAL PATH** for our attack because:
- Strategy sends ETH to flETH **first** (line 153)
- Then flETH sends to user (line 157)
- **Reentrancy window** exists at line 157 when user receives ETH

**State during reentrancy** (between line 153 and 157):
```
✓ totalSupply: ALREADY REDUCED (burn happened at line 107)
✓ flETH.balance: INFLATED (just received from Strategy)
✗ User payment: NOT YET DONE (happens at line 157)

This creates a temporary imbalance exploitable via reentrancy!
```

---

### PATH 3: Simple Direct Transfer (Line 162)

**Condition Checker**:
```solidity
amount <= currentEthBalance
```

**When it triggers**:
```
Given:
- amount to withdraw: 50 ETH
- currentEthBalance: 100 ETH

Calculate:
- amount (50) <= currentEthBalance (100)? YES ✓

Execution:
1. _transferETH(user, 50 ETH)  ← LINE 162
   → User receives 50 ETH from flETH balance
   → flETH balance: 100 - 50 = 50 ETH
```

**Key insight**: Simplest case, no Strategy interaction needed.

---

## Contract Interactions

### Full Call Chain: withdraw() PATH 2 (Most Complex)

```
┌─────────────────────────────────────────────────────────────────┐
│ 1. User calls flETH.withdraw(100 ETH)                          │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│ flETH.sol::withdraw()                                           │
│                                                                 │
│ Line 107: _burn(msg.sender, 100 ETH)                          │
│           → totalSupply decreases by 100                       │
│                                                                 │
│ Line 109: currentEthBalance = 10 ETH                          │
│                                                                 │
│ Line 113: amount > currentEthBalance? 100 > 10 = TRUE         │
│                                                                 │
│ Line 120: newTotalSupply = 600 ETH (after burn)              │
│                                                                 │
│ Line 122-124: expectedNewEthBalance = (0.1 * 600) = 60 ETH   │
│                                                                 │
│ Line 149: expectedNewEthBalance > currentEthBalance?          │
│           60 > 10 = TRUE → Enter PATH 2                       │
│                                                                 │
│ Line 150: rawEthRequiredToReachThreshold = 60 - 10 = 50 ETH  │
│                                                                 │
│ Line 153: strategy.withdrawETH(150 ETH, address(this)) ───┐   │
│           Call external contract!                          │   │
└────────────────────────────────────────────────────────────┼───┘
                                                             │
                                                             ▼
┌─────────────────────────────────────────────────────────────────┐
│ AaveV3Strategy.sol::withdrawETH(150 ETH, flETH_address)        │
│                                                                 │
│ Line 77: require(msg.sender == flETH)                         │
│          Only flETH can call this ✓                           │
│                                                                 │
│ Line 78: _withdrawFromAave(150 ETH, flETH_address) ────┐      │
└─────────────────────────────────────────────────────────┼──────┘
                                                          │
                                                          ▼
┌─────────────────────────────────────────────────────────────────┐
│ AaveV3Strategy.sol::_withdrawFromAave()                        │
│                                                                 │
│ Line 106: aavePool = addressesProvider.getPool()              │
│                                                                 │
│ Line 109: aWETH.approve(wethGateway, 150 ETH)                │
│           Approve Gateway to spend our aWETH                   │
│                                                                 │
│ Line 112: wethGateway.withdrawETH(pool, 150, flETH) ───┐      │
│           Call Gateway contract!                        │      │
└─────────────────────────────────────────────────────────┼──────┘
                                                          │
                                                          ▼
┌─────────────────────────────────────────────────────────────────┐
│ FlAaveV3WethGateway.sol::withdrawETH(pool, 150, flETH)        │
│                                                                 │
│ Line 50: aWETH = POOL.getReserveData(WETH).aTokenAddress     │
│                                                                 │
│ Line 53: aWETH.transferFrom(Strategy, this, 150)             │
│          Pull 150 aWETH from Strategy to Gateway              │
│                                                                 │
│ Line 57-61: amountWithdrawn = POOL.withdraw(                 │
│               address(WETH),                                   │
│               type(uint256).max,  ← Withdraw ALL              │
│               address(this)                                    │
│             )                                                  │
│          → Aave Pool burns 150 aWETH                          │
│          → Aave Pool sends 150 WETH to Gateway                │
│                                                                 │
│ Line 63: WETH.withdraw(150)                                   │
│          → Unwrap 150 WETH to 150 ETH                         │
│                                                                 │
│ Line 64: _safeTransferETH(flETH, 150) ───────────┐            │
│          Send 150 ETH to flETH contract!         │            │
└──────────────────────────────────────────────────┼────────────┘
                                                    │
                                                    ▼
┌─────────────────────────────────────────────────────────────────┐
│ FlAaveV3WethGateway.sol::_safeTransferETH()                   │
│                                                                 │
│ Line 73: (bool success, ) = flETH.call{value: 150}("")       │
│                                                                 │
│          → Sends 150 ETH to flETH                             │
│          → Triggers flETH.receive()                           │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│ flETH.sol::receive() payable                                   │
│                                                                 │
│ Line 288: Just accepts ETH (no logic)                         │
│                                                                 │
│ STATE UPDATE:                                                  │
│ - flETH.balance: 10 → 160 ETH (+150)                         │
│ - totalSupply: 600 ETH (unchanged, burn already done)        │
└────────────────────────┬────────────────────────────────────────┘
                         │
         ┌───────────────┴─────────Return to flETH.withdraw()
         │
         ▼
┌─────────────────────────────────────────────────────────────────┐
│ flETH.sol::withdraw() (continued)                              │
│                                                                 │
│ Line 157: _transferETH(msg.sender, 100 ETH) ────────┐         │
│           ⚠️ REENTRANCY POINT!                       │         │
└──────────────────────────────────────────────────────┼─────────┘
                                                        │
                                                        ▼
┌─────────────────────────────────────────────────────────────────┐
│ flETH.sol::_transferETH()                                      │
│                                                                 │
│ Line 238: (bool success, ) = user.call{value: 100}("")       │
│                                                                 │
│           → Sends 100 ETH to user                             │
│           → Triggers user.receive() or user.fallback()        │
│           → ⚠️ User can REENTER any flETH function here!      │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│ User/Attacker.receive() payable                                │
│                                                                 │
│ ATTACK OPPORTUNITY HERE:                                       │
│                                                                 │
│ Current state when this is called:                            │
│ ✓ totalSupply: 600 ETH (reduced)                             │
│ ✓ flETH.balance: 60 ETH (160 - 100 just sent)               │
│ ✓ Original withdraw: STILL EXECUTING (not finished)          │
│                                                                 │
│ Attacker can:                                                  │
│ - Call flETH.deposit() → mint more flETH                     │
│ - Call flETH.withdraw() again → recursive reentrancy         │
│ - Call flETH.harvest() → manipulate yield                    │
│ - Check flETH.yieldAccumulated() → inflated temporarily      │
└─────────────────────────────────────────────────────────────────┘
```

---

## Attack Vectors Analysis

### Vector 1: Force PATH 2 with Flash Loan

**Objective**: Drain flETH contract to near-zero

**Attack Flow**:
```
1. Flashloan 100 ETH from Balancer (0% fee)

2. deposit(100 ETH) into flETH
   State:
   - totalSupply: 697 → 797 ETH
   - flETH.balance: 70 → 170 ETH
   - Triggers rebalance()
   - Sends ~80 ETH to Strategy
   - flETH.balance: 170 - 80 = 90 ETH

3. withdraw(100 ETH)
   Path determination:
   - amount (100) > currentEthBalance (90)? YES
   - newTotalSupply = 797 - 100 = 697 ETH
   - expectedNewEthBalance = 0.1 * 697 = 69.7 ETH
   - expectedNewEthBalance (69.7) > currentEthBalance (90)? NO

   → Takes PATH 1 (split transfer)

   Execution:
   - rawEthToTransfer = 90 - 69.7 = 20.3 ETH
   - _transferETH(attacker, 20.3) from flETH
   - strategyETHToWithdraw = 100 - 20.3 = 79.7 ETH
   - strategy.withdrawETH(79.7, attacker) directly to us

   Final state:
   - flETH.balance: 69.7 ETH (at threshold)
   - Strategy: withdrew 79.7 ETH
   - Attacker received: 100 ETH (20.3 + 79.7)

4. Repay flashloan: 100 ETH

Result:
- flETH.balance: 69.7 → NEAR MINIMUM
- Cost: Only gas (~$10)
- No profit, but protocol disrupted
```

### Vector 2: Recursive Reentrancy via PATH 2

**Objective**: Force multiple Strategy withdrawals

**Attack Flow**:
```
1. Flashloan 150 ETH

2. deposit(120 ETH)
   - Creates condition for PATH 2

3. withdraw(120 ETH)
   → PATH 2 triggered

   At line 153:
   - Strategy sends large amount to flETH

   At line 157:
   - User receives ETH → REENTRANCY!

4. Inside receive():
   - deposit(60 ETH) → rebalance()
   - withdraw(60 ETH) → PATH 2 again!

5. Nested receive():
   - deposit(30 ETH)
   - withdraw(30 ETH)

   ... recursive until depth limit

Result:
- Multiple Strategy ↔ flETH transfers
- Expensive Aave operations repeated
- Gas griefing attack vector
```

### Vector 3: Harvest Manipulation (Mitigated)

**Tested but FAILED**:
```
Hypothesis:
- During PATH 2 reentrancy
- totalSupply temporarily reduced
- flETH.balance temporarily inflated
- yieldAccumulated() = underlyingETH - totalSupply
- Should show inflated yield?

Reality:
- yield = (flETH.balance + strategy.balance) - totalSupply
- When flETH.balance ↑, strategy.balance ↓ by same amount
- Net: yield UNCHANGED

Test result:
- Yield before: 6.56 ETH
- Yield during reentrancy: 6.56 ETH (same!)
- Yield after: 6.56 ETH

Conclusion: Harvest manipulation not exploitable
```

---

## Key Insights

### 1. PATH 2 is the Critical Path

**Why**:
- Only path where Strategy sends to flETH first
- Creates temporary state imbalance
- Provides reentrancy window at line 157

**Condition to force PATH 2**:
```solidity
// Need: amount > currentEthBalance (requires Strategy)
// AND: expectedNewEthBalance > currentEthBalance (requires topping up flETH)

// This means:
withdraw_amount > flETH.balance
AND
(0.1 * (totalSupply - withdraw_amount)) > flETH.balance

// Simplifying:
flETH.balance must be LOW relative to totalSupply
```

### 2. Flash Loan Enabler

**Why flash loans are critical**:
```
Without flash loan:
- Need real capital (100+ ETH)
- Capital at risk during attack
- Expensive to execute

With flash loan (Balancer 0% fee):
- Borrow 100+ ETH
- Execute attack
- Repay same transaction
- Cost: Only gas (~$10)
```

### 3. Rebalancing Mechanism

**How rebalance() affects attack**:
```solidity
function rebalance() public {
    uint ethBalance = address(this).balance;
    uint ethThreshold = (rebalanceThreshold * totalSupply()) / 1 ether;

    if (ethBalance > ethThreshold) {
        strategy.convertETHToLST{value: ethBalance - ethThreshold}();
    }
}
```

**Implications**:
- Called automatically on deposit()
- Sends "excess" ETH to Strategy
- Reduces flETH.balance
- Makes PATH 2 more likely to trigger
- **Attacker can control this** by choosing deposit size

### 4. The 10% Threshold

**Significance**:
```
rebalanceThreshold = 0.1 ether = 10%

This means:
- flETH tries to keep balance = 10% of totalSupply
- If totalSupply = 700 ETH, target balance = 70 ETH
- Anything above 70 ETH → sent to Strategy
- Anything below 70 ETH → requires Strategy withdrawal

Attack strategy:
1. Deposit large amount → triggers rebalance → reduces flETH.balance
2. Withdraw large amount → forces PATH 2 → brings balance back to threshold
3. Repeat → forces ETH back and forth between contracts
```

---

## Recommended Fixes

### Fix 1: Reentrancy Guard (RECOMMENDED - No downsides)

**Severity**: Critical
**Impact**: Eliminates all reentrancy attack vectors
**Drawbacks**: None (best practice)

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Ownable} from '@solady/auth/Ownable.sol';
import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {ReentrancyGuard} from '@openzeppelin/contracts/security/ReentrancyGuard.sol'; // ← Add this

import {IFLETH} from '@fleth-interfaces/IFLETH.sol';
import {IFLETHStrategy} from '@fleth-interfaces/IFLETHStrategy.sol';
import {IWETH} from '@fleth-interfaces/IWETH.sol';

contract flETH is IFLETH, ERC20, Ownable, ReentrancyGuard { // ← Add ReentrancyGuard
    // ... existing state variables ...

    /**
     * Makes a deposit into the contract, taking ETH and/or WETH and returning flETH.
     */
    function deposit(uint wethAmount) external payable override nonReentrant { // ← Add modifier
        uint ethToDeposit = msg.value;

        if (wethAmount != 0) {
            weth.transferFrom(msg.sender, address(this), wethAmount);
            weth.withdraw(wethAmount);
            ethToDeposit += wethAmount;
        }

        _mintFLETHAndRebalance(msg.sender, ethToDeposit);
    }

    /**
     * Withdraw ETH by sending in flETH.
     */
    function withdraw(uint amount) external override nonReentrant { // ← Add modifier
        _burn(msg.sender, amount);

        uint currentEthBalance = address(this).balance;

        if (amount > currentEthBalance) {
            if (address(strategy) == address(0))
                revert AmountExceedsETHBalance();

            uint newTotalSupply = totalSupply();
            uint expectedNewEthBalance;
            unchecked {
                expectedNewEthBalance = (rebalanceThreshold * newTotalSupply) / 1 ether;
            }

            if (expectedNewEthBalance <= currentEthBalance) {
                uint rawEthToTransfer;
                unchecked {
                    rawEthToTransfer = currentEthBalance - expectedNewEthBalance;
                }

                uint strategyETHToWithdraw = amount - rawEthToTransfer;

                _transferETH(msg.sender, rawEthToTransfer);
                strategy.withdrawETH(strategyETHToWithdraw, msg.sender);

            } else {
                uint rawEthRequiredToReachThreshold = expectedNewEthBalance - currentEthBalance;

                strategy.withdrawETH(amount + rawEthRequiredToReachThreshold, address(this));

                // ✓ This line is now safe - nonReentrant prevents reentrancy
                _transferETH(msg.sender, amount);
            }
        } else {
            _transferETH(msg.sender, amount);
        }
    }

    /**
     * Harvest yield from the strategy and send it to our yield recipient
     */
    function harvest() external override nonReentrant { // ← Add modifier (defense in depth)
        uint ethYield = yieldAccumulated();
        uint strategyETHBalance = strategy.balanceInETH();

        if (strategyETHBalance >= ethYield) {
            strategy.withdrawETH(ethYield, yieldReceiver);
        } else {
            uint delta = ethYield - strategyETHBalance;
            strategy.withdrawETH(strategyETHBalance, yieldReceiver);
            _transferETH(yieldReceiver, delta);
        }
    }

    // ... rest of contract unchanged ...
}
```

**Why this works**:
- `nonReentrant` modifier sets a lock before function execution
- Any attempt to call `deposit()`, `withdraw()`, or `harvest()` again will revert
- Prevents all recursive calls during external interactions
- **Zero functional impact** on legitimate users
- Industry standard (OpenZeppelin)
- Gas overhead: ~2,300 gas per call (negligible)

**Attack prevention**:
```solidity
// Before fix:
User calls withdraw()
→ Line 157: _transferETH(user, amount)
  → User's receive() triggers
    → User calls withdraw() AGAIN ✓ (succeeds)
      → Reentrancy attack!

// After fix:
User calls withdraw() (sets lock)
→ Line 157: _transferETH(user, amount)
  → User's receive() triggers
    → User calls withdraw() AGAIN ✗ (reverts with "ReentrancyGuard: reentrant call")
      → Attack blocked!
```

---

### Fix 2: Flash Loan Protection with Balance Tracking

**Severity**: High
**Impact**: Prevents zero-cost state manipulation attacks
**Drawbacks**: Minimal (blocks only same-block deposit→withdraw)

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

contract flETH is IFLETH, ERC20, Ownable, ReentrancyGuard {

    // Add state variables for flash loan detection
    mapping(address => uint256) private lastDepositBlock;
    mapping(address => uint256) private lastDepositAmount;
    mapping(address => uint256) private maxWithdrawSameBlock;

    uint256 public constant SAME_BLOCK_WITHDRAW_LIMIT = 0.1 ether; // 10% of deposit

    /**
     * Enhanced deposit with flash loan tracking
     */
    function deposit(uint wethAmount) external payable override nonReentrant {
        uint ethToDeposit = msg.value;

        if (wethAmount != 0) {
            weth.transferFrom(msg.sender, address(this), wethAmount);
            weth.withdraw(wethAmount);
            ethToDeposit += wethAmount;
        }

        // Track deposit for flash loan detection
        if (lastDepositBlock[msg.sender] == block.number) {
            // Multiple deposits in same block - accumulate
            lastDepositAmount[msg.sender] += ethToDeposit;
        } else {
            // New block - reset tracking
            lastDepositBlock[msg.sender] = block.number;
            lastDepositAmount[msg.sender] = ethToDeposit;
            maxWithdrawSameBlock[msg.sender] = (ethToDeposit * SAME_BLOCK_WITHDRAW_LIMIT) / 1 ether;
        }

        _mintFLETHAndRebalance(msg.sender, ethToDeposit);
    }

    /**
     * Enhanced withdraw with flash loan protection
     */
    function withdraw(uint amount) external override nonReentrant {
        // FLASH LOAN PROTECTION
        if (lastDepositBlock[msg.sender] == block.number) {
            // User deposited in same block - apply limits
            require(
                amount <= maxWithdrawSameBlock[msg.sender],
                "Flash loan detected: cannot withdraw full amount same block"
            );

            // Update remaining allowance
            maxWithdrawSameBlock[msg.sender] -= amount;
        }

        _burn(msg.sender, amount);

        uint currentEthBalance = address(this).balance;

        if (amount > currentEthBalance) {
            if (address(strategy) == address(0))
                revert AmountExceedsETHBalance();

            uint newTotalSupply = totalSupply();
            uint expectedNewEthBalance;
            unchecked {
                expectedNewEthBalance = (rebalanceThreshold * newTotalSupply) / 1 ether;
            }

            if (expectedNewEthBalance <= currentEthBalance) {
                uint rawEthToTransfer;
                unchecked {
                    rawEthToTransfer = currentEthBalance - expectedNewEthBalance;
                }

                uint strategyETHToWithdraw = amount - rawEthToTransfer;

                _transferETH(msg.sender, rawEthToTransfer);
                strategy.withdrawETH(strategyETHToWithdraw, msg.sender);

            } else {
                uint rawEthRequiredToReachThreshold = expectedNewEthBalance - currentEthBalance;

                strategy.withdrawETH(amount + rawEthRequiredToReachThreshold, address(this));
                _transferETH(msg.sender, amount);
            }
        } else {
            _transferETH(msg.sender, amount);
        }
    }

    // ... rest of contract unchanged ...
}
```

**Why this works**:

1. **Tracks deposits per block**: Records when and how much each user deposits
2. **Limits same-block withdrawals**: Users can only withdraw 10% of their deposit in the same block
3. **Prevents flash loan abuse**:
   - Flash loan: deposit 100 ETH → can only withdraw 10 ETH same block
   - Next block: can withdraw full amount (legitimate user behavior)

**Attack prevention**:
```solidity
// Flash loan attack (BLOCKED):
1. Flashloan 100 ETH
2. deposit(100 ETH)
   → lastDepositBlock[attacker] = block.number
   → lastDepositAmount[attacker] = 100 ETH
   → maxWithdrawSameBlock[attacker] = 10 ETH (10%)
3. withdraw(100 ETH)
   → Checks: lastDepositBlock == block.number? YES
   → Checks: 100 ETH <= 10 ETH? NO
   → ✗ REVERTS: "Flash loan detected"
4. Cannot repay flashloan → Attack fails

// Legitimate user (ALLOWED):
1. deposit(10 ETH) in block N
2. Wait until block N+1
3. withdraw(10 ETH) in block N+1
   → Checks: lastDepositBlock[user] == block.number? NO
   → ✓ Withdrawal proceeds normally
```

**Advanced variant - Proportional limit**:
```solidity
// Alternative: Allow proportional withdrawal based on total balance

mapping(address => uint256) private depositBlockNumber;
mapping(address => uint256) private depositedThisBlock;

function withdraw(uint amount) external override nonReentrant {
    if (depositBlockNumber[msg.sender] == block.number) {
        uint256 userBalance = balanceOf(msg.sender);
        uint256 depositRatio = (depositedThisBlock[msg.sender] * 1e18) / userBalance;

        // If user deposited >90% of their balance this block, limit withdrawal
        if (depositRatio > 0.9e18) {
            uint256 maxWithdraw = (userBalance * 10) / 100; // 10% limit
            require(amount <= maxWithdraw, "Flash loan protection");
        }
    }

    // ... rest of withdraw logic ...
}
```

---

### Fix 3: Rate Limiting on Rebalance Operations

**Severity**: Medium
**Impact**: Prevents rapid forced rebalancing
**Drawbacks**: May delay legitimate rebalances (low impact)

```solidity
contract flETH is IFLETH, ERC20, Ownable, ReentrancyGuard {

    uint256 private lastRebalanceBlock;
    uint256 public constant MIN_REBALANCE_INTERVAL = 50; // blocks (~10 minutes on Base)

    uint256 private totalRebalanceVolume;
    uint256 private rebalanceVolumeResetBlock;
    uint256 public constant MAX_REBALANCE_VOLUME_PER_PERIOD = 1000 ether; // Max 1000 ETH per period
    uint256 public constant VOLUME_RESET_PERIOD = 300; // blocks (~1 hour)

    /**
     * Enhanced rebalance with rate limiting
     */
    function rebalance() public override {
        if (address(strategy) == address(0) || strategy.isUnwinding()) return;

        // RATE LIMIT 1: Time-based
        require(
            block.number >= lastRebalanceBlock + MIN_REBALANCE_INTERVAL,
            "Rebalance too soon"
        );

        uint ethBalance = address(this).balance;
        uint ethThreshold = (rebalanceThreshold * totalSupply()) / 1 ether;

        if (ethBalance > ethThreshold) {
            uint256 amountToRebalance;
            unchecked {
                amountToRebalance = ethBalance - ethThreshold;
            }

            // RATE LIMIT 2: Volume-based
            if (block.number >= rebalanceVolumeResetBlock + VOLUME_RESET_PERIOD) {
                // Reset volume tracking
                totalRebalanceVolume = 0;
                rebalanceVolumeResetBlock = block.number;
            }

            require(
                totalRebalanceVolume + amountToRebalance <= MAX_REBALANCE_VOLUME_PER_PERIOD,
                "Rebalance volume limit exceeded"
            );

            // Update tracking
            lastRebalanceBlock = block.number;
            totalRebalanceVolume += amountToRebalance;

            strategy.convertETHToLST{value: amountToRebalance}();
        }
    }
}
```

**Why this works**:
- **Time-based limit**: Prevents rapid successive rebalances
- **Volume-based limit**: Prevents moving massive amounts in short time
- **Double protection**: Both limits must pass

**Attack prevention**:
```solidity
// Attack attempt (BLOCKED):
Block 1000: deposit(100 ETH) → triggers rebalance (sends 80 ETH to Strategy)
Block 1001: withdraw(100) → ✗ "Rebalance too soon" (needs 50 blocks)
Block 1050: withdraw(100) → ✓ Allowed (50 blocks passed)
             But if attacker tries again:
Block 1051: deposit(100) → ✗ "Rebalance too soon" (needs to wait until 1100)

Result: Attack severely rate-limited, becomes impractical
```

---

### Comparison Matrix

| Fix | Reentrancy | Flash Loan | Gas Grief | Legitimate User Impact | Implementation |
|-----|-----------|-----------|-----------|----------------------|----------------|
| **Fix 1: ReentrancyGuard** | ✅ Blocks | ⚠️ Partial | ⚠️ Partial | ✅ None | Easy |
| **Fix 2: Flash Loan Protection** | ✅ Helps | ✅ Blocks | ✅ Blocks | ⚠️ Minimal* | Medium |
| **Fix 3: Rate Limiting** | ❌ No | ⚠️ Partial | ✅ Blocks | ⚠️ May delay | Medium |
| **All 3 Combined** | ✅ Blocks | ✅ Blocks | ✅ Blocks | ⚠️ Minimal | Complex |

*Minimal impact: Legitimate users wait 1 block (~2 seconds on Base) between deposit and full withdraw

---

### Recommended Implementation Strategy

**Phase 1: Immediate (Emergency Fix)**
```solidity
// Add ReentrancyGuard NOW - zero downside
import {ReentrancyGuard} from '@openzeppelin/contracts/security/ReentrancyGuard.sol';

contract flETH is IFLETH, ERC20, Ownable, ReentrancyGuard {
    function deposit(...) external payable override nonReentrant { ... }
    function withdraw(...) external override nonReentrant { ... }
    function harvest() external override nonReentrant { ... }
}
```

**Phase 2: Short-term (Within 1 week)**
```solidity
// Add Flash Loan Protection
mapping(address => uint256) private lastDepositBlock;
mapping(address => uint256) private maxWithdrawSameBlock;

function deposit(...) external payable override nonReentrant {
    // Track deposits
    lastDepositBlock[msg.sender] = block.number;
    maxWithdrawSameBlock[msg.sender] = (ethToDeposit * 10) / 100;
    // ...
}

function withdraw(...) external override nonReentrant {
    // Check same-block limit
    if (lastDepositBlock[msg.sender] == block.number) {
        require(amount <= maxWithdrawSameBlock[msg.sender], "Flash loan protection");
    }
    // ...
}
```

**Phase 3: Long-term (Optional)**
```solidity
// Add Rate Limiting if needed based on monitoring
function rebalance() public override {
    require(block.number >= lastRebalanceBlock + MIN_INTERVAL, "Rate limit");
    // ...
}
```

---

### Testing the Fixes

**Test Case 1: Reentrancy Attack (Should Fail)**
```solidity
contract ReentrancyAttacker {
    flETH public target;
    uint256 public callCount;

    function attack() external payable {
        target.deposit{value: msg.value}(0);
        target.withdraw(target.balanceOf(address(this)));
    }

    receive() external payable {
        callCount++;
        if (callCount < 5) {
            // Try to reenter
            target.withdraw(target.balanceOf(address(this))); // ✗ Should revert
        }
    }
}
```

**Test Case 2: Flash Loan Attack (Should Fail)**
```solidity
function testFlashLoanBlocked() public {
    // Simulate flash loan
    uint256 flashAmount = 100 ether;

    // Same block operations
    flETH.deposit{value: flashAmount}(0);

    vm.expectRevert("Flash loan detected");
    flETH.withdraw(flashAmount); // ✗ Should revert
}
```

**Test Case 3: Legitimate User (Should Pass)**
```solidity
function testLegitimateUser() public {
    // Block N: Deposit
    flETH.deposit{value: 10 ether}(0);

    // Block N+1: Withdraw
    vm.roll(block.number + 1);
    flETH.withdraw(10 ether); // ✓ Should succeed
}
```

---

## Conclusion

The `withdraw()` function has **3 distinct execution paths**, each triggering `_transferETH()` under different conditions:

1. **PATH 1 (Line 140)**: Split transfer when flETH has excess balance
2. **PATH 2 (Line 157)**: Strategy → flETH → User (**CRITICAL**, reentrancy risk)
3. **PATH 3 (Line 162)**: Simple direct transfer

**PATH 2 is the attack surface** because:
- Strategy sends funds to flETH **before** user is paid
- Creates temporary imbalance exploitable via reentrancy
- Can be forced using flash loans at zero cost

The interaction chain (flETH → Strategy → Gateway → Aave → flETH → User) creates multiple points where state can be manipulated, making this a **HIGH severity** vulnerability despite the inability to extract direct profit.

---

**Document Version**: 1.0
**Last Updated**: January 2025
