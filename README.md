<p align="center">
<img src="./images/t-swap-youtube-dimensions.png" width="400" alt="t-swap">
<br/>

# 🔐 TSwap Security Audit

A comprehensive security audit of the **TSwap** Decentralized Exchange (DEX) protocol.

**Lead Security Researcher:** [GushALKDev](https://github.com/GushALKDev)

---

## 📋 Table of Contents

- [Audit Overview](#audit-overview)
- [📄 Full Audit Report (PDF)](#-full-audit-report-pdf)
- [Severity Classification](#severity-classification)
- [Executive Summary](#executive-summary)
- [Findings](#findings)
  - [High Severity](#-high-severity)
  - [Medium Severity](#-medium-severity)
  - [Low Severity](#-low-severity)
  - [Informational](#-informational)
- [Use of Tools](#-tools-used)
- [Lessons Learned](#-lessons-learned)

---

## Audit Overview

| Item | Detail |
|------|--------|
| **Audit Commit Hash** | `e643a8d4c2c802490976b538dd009b351b1c8dda` |
| **Solidity Version** | `0.8.20` |
| **Target Chain** | Ethereum |
| **Scope** | `src/PoolFactory.sol`, `src/TSwapPool.sol` |
| **Methods** | Manual Review, Static Analysis (Slither, Aderyn) |

---

## 📄 Full Audit Report (PDF)

> **[📥 Download the Complete Audit Report (PDF)](./audit-data/report.pdf)**

The full report contains detailed findings with complete Proof of Concept code, diff patches, and comprehensive recommendations.

---

## Severity Classification

| Severity | Impact |
|----------|--------|
| 🔴 **High** | Critical vulnerabilities leading to direct loss of funds or complete compromise |
| 🟠 **Medium** | Issues causing unexpected behavior or moderate financial impact |
| 🟡 **Low** | Minor issues that don't directly risk funds |
| 🔵 **Info** | Best practices and code quality improvements |

---

## Executive Summary

The **TSwap** protocol contains **critical security vulnerabilities** that make it **unsafe for production deployment**. Major issues were found in the fee calculation mechanics and slippage protection.

### Key Metrics

| Severity | Count |
|----------|-------|
| 🔴 High | 4 |
| 🟠 Medium | 1 |
| 🟡 Low | 3 |
| 🔵 Info | 14 |
| **Total** | **22** |

### Critical Risks

- ⚠️ **Broken Fee Calculation** — Protocol takes ~90% fee instead of 0.3% in `swapExactOutput`.
- ⚠️ **Missing Slippage Protection** — `swapExactOutput` has no `maxInput` check.
- ⚠️ **Incorrect Swap Logic** — `sellPoolTokens` calls `swapExactOutput` incorrectly.
- ⚠️ **No Deadline Checks** — Deposits can be executed at unfavorable times.

---

## Findings

### 🔴 High Severity

| ID | Finding | Location |
|----|---------|----------|
| H-1 | Incorrect fee calculation in `getInputAmountBasedOnOutput` causes protocol to take 90% fee instead of 0.3% | `TSwapPool::getInputAmountBasedOnOutput` |
| H-2 | `sellPoolTokens` calls `swapExactOutput` with incorrect parameters | `TSwapPool::sellPoolTokens` |
| H-3 | `swapExactOutput` lacks slippage protection (`maxInputAmount` missing) | `TSwapPool::swapExactOutput` |
| H-4 | `deposit` missing deadline check despite accepting `deadline` parameter | `TSwapPool::deposit` |

---

### 🟠 Medium Severity

| ID | Finding | Location |
|----|---------|----------|
| M-1 | Fee-on-transfer logic breaks protocol invariant (`x * y = k`) | `TSwapPool::_swap` |

---

### 🟡 Low Severity

| ID | Finding | Location |
|----|---------|----------|
| L-1 | `LiquidityAdded` event emits parameters in wrong order (swaps WETH and PoolTokens) | `TSwapPool::_addLiquidityMintAndTransfer` |
| L-2 | `swapExactInput` result value is not returned clearly | `TSwapPool::swapExactInput` |
| L-3 | `createPool` uses `.name()` instead of `.symbol()` for LP token symbol | `PoolFactory::createPool` |

---

### 🔵 Informational

| ID | Finding |
|----|---------|
| I-1 | Missing `address(0)` checks in constructors and setters |
| I-2 | Missing `revertIfZero` checks for amount parameters |
| I-3 | Events missing `indexed` parameters |
| I-4 | Magic numbers (1000, 997, 1e18) should be constants |
| I-5 | `pragma 0.8.20` may unlock PUSH0 (check chain compatibility) |
| I-6 | Unused custom error `PoolFactory__PoolDoesNotExist` |
| I-7 | `createPool` misses check for empty token name |
| I-8 | `deposit` error emits constant `MINIMUM_WETH_LIQUIDITY` |
| I-9 | Unused local variable `poolTokenReserves` in `deposit` |
| I-10 | `swapExactInput` should be `external` |
| I-11 | Missing NatSpec for `swapExactInput` |
| I-12 | Missing NatSpec for `deadline` in `swapExactOutput` |
| I-13 | `swapExactOutput` missing `maxInputAmount` indication |
| I-14 | `_swap` invariant check missing |

---

## 🎯 Section 5: The NFT Invariant Challenge

![NFT Exploit Challenge](./images/S5_NFT.png)

### 🕵️‍♂️ The Challenge & Approach

While a static code analysis hinted that disrupting the pool's invariant required swapping Token C for Token A or B, I opted for a more rigorous approach to confirm this hypothesis. By implementing a **Stateful Invariant Test Suite**, I was able to programmatically prove the vulnerability and identify the exact conditions required to break the system.

### 💥 The Breakthrough

The invariant test successfully falsified the system's safety properties, triggering a revert with specific swap parameters. This confirmed that the pool's balance integrity could be compromised via a specific token swap path:

```text
[Revert] panic: assertion failed (0x01)
S5Pool::swapFrom(TokenC: [...9b51A820a], TokenB: [...E1C58470b], 8.476e18)
```

This automated verification validated the visual inspection findings: **swapping Token C allows us to manipulate the pool state to satisfy the win condition.**

### 🔓 Exploit Execution

With the vulnerability confirmed, the NFT can be claimed via two distinct methods:

#### Method 1: Programmatic Execution (Hot Wallet)
Develop and execute a foundry script that interacts with the `S5Pool` to perform the specific swap sequence.

#### Method 2: Manual Execution (Cold Wallet / Remix)
For a manual approach using Remix, the following transaction sequence successfully solves the challenge:

1. **Reset State**: `S5::hardReset()`
2. **Acquire Tokens**: `S5Token::mint()`
3. **Approve Pool**: `S5Token::approve(address(S5Pool), 1e18)`
4. **Trigger Exploit**: `S5Pool::swapFrom(address(TokenC), address(TokenA), 1e18)`
5. **Claim Victory**: `S5:solveChallenge()`

---

## 🛠 Tools Used

| Tool | Purpose |
|------|---------|
| [Foundry](https://github.com/foundry-rs/foundry) | Testing & local development |
| [Slither](https://github.com/crytic/slither) | Static analysis |
| [Aderyn](https://github.com/Cyfrin/aderyn) | Smart contract analyzer |

---

## 📚 Lessons Learned

1.  **Invariants**: Rigorous invariant testing (e.g., `x * y = k`) is crucial for DeFi protocols to detect broken logic like incorrect fee math.
2.  **Slippage Protection**: Always include `minOutput` for swaps and `maxInput` for exact-output swaps to protect users from price changes.
3.  **Deadline Checks**: Essential for all time-sensitive actions (swaps, deposits) to preventing old transactions from being executed.
4.  **Math Precision**: Double-check all fee calculations and multipliers (e.g., 1000 vs 10000). Small typos causing massive losses.
5.  **CEI Pattern**: Checks-Effects-Interactions is just as important in AMMs as in other protocols.
6.  **Event Correctness**: Ensure event parameters match their definitions so off-chain indexers work correctly.

---

Made with ❤️ by **GushALKDev** | Advancing in Smart Contract Security
