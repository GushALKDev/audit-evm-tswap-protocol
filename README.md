<p align="center">
<img src="./images/t-swap-youtube-dimensions.png" width="400" alt="t-swap">
<br/>

# 🔐 TSwap Security Audit

A comprehensive security audit of the **TSwap** Decentralized Exchange (DEX) protocol.

**Lead Security Researcher:** [GushALKDev](https://github.com/GushALKDev)

---

## 📋 Table of Contents

- [Audit Overview](#audit-overview)
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

#### [H-1] Incorrect fee calculation in `getInputAmountBasedOnOutput` causes protocol to take 90% fee instead of 0.3%

**Location:** `TSwapPool::getInputAmountBasedOnOutput`

The function uses `10000` instead of `1000` in the numerator when calculating input amount, resulting in a massive overcharge (90%+ fee) rather than the intended 0.3%.

```solidity
// ❌ Vulnerable - 10000 creates 90% fee
return ((inputReserves * outputAmount) * 10000) / ((outputReserves - outputAmount) * 997);
```

**Fix:** Replace `10000` with `1000`.

---

#### [H-2] `TSwapPool::sellPoolTokens` calls `swapExactOutput` with incorrect parameters

**Location:** `TSwapPool::sellPoolTokens`

The function calls `swapExactOutput` passing `poolTokenAmount` (an input amount) as the `outputAmount` parameter. This fundamentally breaks the logic of selling a specific amount of tokens.

**Fix:** Use `swapExactInput` instead.

---

#### [H-3] `TSwapPool::swapExactOutput` lacks slippage protection

**Location:** `TSwapPool::swapExactOutput`

The function does not accept a `maxInputAmount` parameter. If market conditions change or liquidity shifts, users may end up paying significantly more input tokens than expected to receive their desired output.

**Fix:** Add `maxInputAmount` parameter and check `inputAmount <= maxInputAmount`.

---

#### [H-4] `TSwapPool::deposit` Missing Deadline Check

**Location:** `TSwapPool::deposit`

The `deposit` function accepts a `deadline` parameter but never checks it (missing `revertIfDeadlinePassed` modifier). Transactions can hang in the mempool and be executed long after the user intended.

**Fix:** Add `revertIfDeadlinePassed(deadline)` modifier.

---

### 🟠 Medium Severity

#### [M-1] Fee-on-transfer logic breaks protocol invariant

**Location:** `TSwapPool::_swap`

Logic exists to send tokens out of the contract every `SWAP_COUNT_MAX` swaps without balancing the reserves. This removes tokens from the pool without a corresponding swap, breaking the `x * y = k` invariant.

**Fix:** Remove the fee-on-transfer mechanism or account for it mathematically.

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

<p align="center">
Made with ❤️ while learning Smart Contract Security
</p>
