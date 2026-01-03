### [H-1] Incorrect fee calculation in `getInputAmountBasedOnOutput` causes protocol to take 90% fee instead of 0.3%

**IMPACT:** High
**LIKELIHOOD:** High

**Description:** The `TSwapPool::getInputAmountBasedOnOutput` function is intended to calculate the amount of tokens a user needs to input to receive a specific amount of output tokens. However, there is a typo in the fee calculation. 

The function uses `10000` and `997` to calculate the fee, implying a 0.3% fee.
```solidity
return ((inputReserves * outputAmount) * 10000) / ((outputReserves - outputAmount) * 997);
```

However, `997 / 10000` results in `0.0997`, which means the multiplier is `99.7%` ?? 
Actually, the math is: 
Target: `inputAmount * 997 / 1000 = outputAmount` (roughly)
Current: `inputAmount = (outputAmount * 10000) / 997`

If we look at `getOutputAmountBasedOnInput`:
`inputAmount * 997 / 1000`
Here `getInputAmountBasedOnOutput` should be the inverse.
`outputAmount * 1000 / 997`

The current implementation uses `10000` in the numerator:
`outputAmount * 10000 / 997`

This results in the user being required to send ~10x more tokens than they should.
Calculated fee: `1 - (997/10000) = 1 - 0.0997 = 0.9003` => 90.03% fee.

**Impact:** Users are charged a massively high fee (90%+) for swaps where they specify the exact output amount. This effectively steals user funds or makes the protocol completely unusable for this transaction type.

**Proof of Concept:**

<details>
<summary>PoC</summary>

```solidity
    function testFlawedSwapExactOutput() public {
        uint256 initialLiquidity = 100e18;
        vm.startPrank(liquidityProvider);
        weth.approve(address(pool), initialLiquidity);
        poolToken.approve(address(pool), initialLiquidity);
        pool.deposit(initialLiquidity, 0, initialLiquidity, uint64(block.timestamp));
        vm.stopPrank();

        // User wants to swap 1 WETH
        address attacker = makeAddr("attacker");
        vm.startPrank(attacker);
        poolToken.mint(attacker, 100e18);
        poolToken.approve(address(pool), 100e18);
        
        uint256 valueToBuy = 1e18;
        uint256 expectedCost = 1103362165907421361; // ~1.103 token ~= 10% more than 1 (normal for these reserves)
        // However, the flawed math will ask for much more
        
        pool.swapExactOutput(poolToken, weth, valueToBuy, uint64(block.timestamp));
        
        uint256 actualCost = 100e18 - poolToken.balanceOf(attacker);
        // It should be around 1e18, but it is ~11e18
        console.log("Actual cost: ", actualCost); 
        assert(actualCost > 10e18); // It charges ~10x more
        vm.stopPrank();
    }
```
</details>

**Recommended Mitigation:** Replace `10000` with `1000`.

```diff
- return ((inputReserves * outputAmount) * 10000) / ((outputReserves - outputAmount) * 997);
+ return ((inputReserves * outputAmount) * 1000) / ((outputReserves - outputAmount) * 997);
```

### [H-2] `TSwapPool::sellPoolTokens` calls `swapExactOutput` with incorrect parameters

**IMPACT:** High
**LIKELIHOOD:** High

**Description:** The `sellPoolTokens` function allows users to sell their liquidity tokens (pool tokens) for WETH. It calls `swapExactOutput`:

```solidity
    function sellPoolTokens(
        uint256 poolTokenAmount
    ) external returns (uint256 wethAmount) {
        return
            swapExactOutput(
                i_poolToken,
                i_wethToken,
                poolTokenAmount,
                uint64(block.timestamp)
            );
    }
```

The `swapExactOutput` function expects the third argument to be `outputAmount`. However, `poolTokenAmount` is passed, which is the *input* amount (the amount of pool tokens being sold). This suggests the function intends to swap an exact *input* of pool tokens, not get an exact *output* of WETH matching the pool token amount.

Additionally, `swapExactOutput` calculates `inputAmount` based on `outputAmount`. By passing `poolTokenAmount` as `outputAmount`, the function tries to calculate how many pool tokens are needed to get `poolTokenAmount` of WETH, which is not the intended behavior of "selling X pool tokens".

**Impact:** The function logic is fundamentally flawed. It will attempt to swap for a specific amount of WETH rather than selling a specific amount of pool tokens. If the price isn't 1:1, this will result in unexpected behavior or revert. Users cannot sell the exact amount of pool tokens they want.

**Proof of Concept:**

<details>
<summary>PoC</summary>

```solidity
    function testSellPoolTokens() public {
        uint256 initialLiquidity = 100e18;
        vm.startPrank(liquidityProvider);
        weth.approve(address(pool), initialLiquidity);
        poolToken.approve(address(pool), initialLiquidity);
        pool.deposit(initialLiquidity, 0, initialLiquidity, uint64(block.timestamp));
        vm.stopPrank();

        address user = makeAddr("user");
        vm.startPrank(user);
        poolToken.mint(user, 10e18);
        poolToken.approve(address(pool), 10e18);

        // User wants to sell 10 pool tokens
        // Expected behavior: User calls sellPoolTokens(10e18) and pays 10e18 pool tokens
        // Actual behavior: check logs
        pool.sellPoolTokens(10e18);
        
        // The user effectively requested to BUY 10 WETH output, identifying how many pool tokens input needed
        // If the price is 1:1, it might work by coincidence, but if reserves skew, it breaks.
        // Also, notice the function sellPoolTokens signature implies inputting a specific amount of pool tokens.
        vm.stopPrank();
    }
```
</details>

**Recommended Mitigation:** Use `swapExactInput` instead of `swapExactOutput` and pass `poolTokenAmount` as the `inputAmount`.

```diff
    function sellPoolTokens(
        uint256 poolTokenAmount
    ) external returns (uint256 wethAmount) {
-       return swapExactOutput(i_poolToken, i_wethToken, poolTokenAmount, uint64(block.timestamp));
+       return swapExactInput(i_poolToken, poolTokenAmount, i_wethToken, minOutputAmount, uint64(block.timestamp));
    }
```
*Note: `sellPoolTokens` would need an additional `minOutputAmount` parameter to be safe.*

### [H-3] `TSwapPool::swapExactOutput` lacks slippage protection

**IMPACT:** High
**LIKELIHOOD:** Medium

**Description:** The `swapExactOutput` function allows users to specify an exact amount of tokens they want to receive. However, it does not allow users to specify a maximum amount of input tokens they are willing to spend (`maxInputAmount`).

```solidity
    function swapExactOutput(
        IERC20 inputToken,
        IERC20 outputToken,
        uint256 outputAmount,
        uint64 deadline
    )
```

**Impact:** If market conditions change (slippage) or if the pool state is manipulated before the transaction is executed, the user might end up modifying their input token balance significantly more than expected. They have no guarantee on the "price" they are paying for the output.

**Proof of Concept:**

<details>
<summary>PoC</summary>

```solidity
    function testSwapExactOutputNoSlippage() public {
        uint256 initialLiquidity = 100e18;
        vm.startPrank(liquidityProvider);
        weth.approve(address(pool), initialLiquidity);
        poolToken.approve(address(pool), initialLiquidity);
        pool.deposit(initialLiquidity, 0, initialLiquidity, uint64(block.timestamp));
        vm.stopPrank();

        address user = makeAddr("user");
        vm.startPrank(user);
        poolToken.mint(user, 1000e18); // Rich user
        poolToken.approve(address(pool), 1000e18);

        // Normal swap expected cost
        uint256 outputToBuy = 1e18;
        
        // Imagine a front-runner comes in and changes the ratio drastically
        // (Just simulating a changed state here)
        vm.stopPrank();
        vm.startPrank(liquidityProvider);
        pool.withdraw(90e18, 90e18, 90e18, uint64(block.timestamp)); // Remove liquidity, price moves or depth drops
        vm.stopPrank();
        
        vm.startPrank(user);
        // User executes swap expecting previous price, but there is no maxInput param to revert
        pool.swapExactOutput(poolToken, weth, outputToBuy, uint64(block.timestamp));
        // Transaction succeeds but user paid way more than they might have authorized
        vm.stopPrank();
    }
```
</details>

**Recommended Mitigation:** Add a `maxInputAmount` parameter and require the calculated `inputAmount` to be less than or equal to `maxInputAmount`.

```diff
    function swapExactOutput(
        IERC20 inputToken,
        IERC20 outputToken,
        uint256 outputAmount,
+       uint256 maxInputAmount,
        uint64 deadline
    )
    ...
+   if (inputAmount > maxInputAmount) {
+       revert TSwapPool__InputTooHigh(inputAmount, maxInputAmount);
+   }
```

### [H-4] `TSwapPool::deposit` Missing Deadline Check

**IMPACT:** High
**LIKELIHOOD:** Medium

**Description:** The `deposit` function accepts a `deadline` parameter but never uses it. The `revertIfDeadlinePassed` modifier is missing from the function signature.

```solidity
    function deposit(
        uint256 wethToDeposit,
        uint256 minimumLiquidityTokensToMint,
        uint256 maximumPoolTokensToDeposit,
        uint64 deadline
    )
        external
        revertIfZero(wethToDeposit)
        returns (uint256 liquidityTokensToMint)
```

**Impact:** Users who submit a deposit transaction with a deadline expect the transaction to fail if it stays pending for too long (e.g., to avoid depositing during unfavorable market/gas conditions). Without the check, the transaction could be executed at an arbitrary later time, potentially harming the user.

**Proof of Concept:**

<details>
<summary>PoC</summary>

```solidity
    function testDepositDeadlinePassed() public {
        uint256 initialLiquidity = 100e18;
        vm.startPrank(liquidityProvider);
        weth.approve(address(pool), initialLiquidity);
        poolToken.approve(address(pool), initialLiquidity);
        
        // Deadline is in the past
        uint64 pastDeadline = uint64(block.timestamp - 1);
        
        // Should revert, but it succeeds
        pool.deposit(initialLiquidity, 0, initialLiquidity, pastDeadline);
        
        vm.stopPrank();
        assertEq(pool.totalSupply(), initialLiquidity);
    }
```
</details>

**Recommended Mitigation:** Add the `revertIfDeadlinePassed` modifier.

```diff
    function deposit(
        ...
        uint64 deadline
    )
        external
+       revertIfDeadlinePassed(deadline)
        revertIfZero(wethToDeposit)
        returns (uint256 liquidityTokensToMint)
```

### [M-1] Fee-on-transfer logic breaks protocol invariant (if implemented)

**IMPACT:** High
**LIKELIHOOD:** Low

**Description:** In `TSwapPool::_swap`, there is some logic regarding an extra token incentive:

```diff
-        if (swap_count >= SWAP_COUNT_MAX) {
-            swap_count = 0;
-            outputToken.safeTransfer(msg.sender, 1_000_000_000_000_000_000);
-        }
```

Sending tokens out of the contract without a corresponding swap input disrupts the `x * y = k` invariant. The contract's balance of `outputToken` decreases without `inputToken` increasing to compensate.

**Impact:** If this logic were active, the constant product invariant would be broken, leading to incorrect pricing for subsequent swaps and potential depletion of the pool over time.

**Recommended Mitigation:** Do not implement fee-on-transfer mechanics that simply remove tokens from the pool's reserves involved in the pricing curve. If incentives are needed, they should be funded separately or accounted for mathematically.

### [L-1] `LiquidityAdded` event parameters are mismatched

**IMPACT:** Low
**LIKELIHOOD:** High

**Description:** In `TSwapPool::_addLiquidityMintAndTransfer`, the `LiquidityAdded` event is emitted with the parameters in the wrong order.

```solidity
emit LiquidityAdded(msg.sender, poolTokensToDeposit, wethToDeposit);
```

The event definition is:
```solidity
event LiquidityAdded(address indexed liquidityProvider, uint256 wethDeposited, uint256 poolTokensDeposited);
```

The call swaps `wethDeposited` and `poolTokensDeposited`.

**Impact:** Off-chain indexers and UIs will display incorrect deposit amounts for WETH and PoolTokens, confusing users.

**Recommended Mitigation:** Swap the arguments in the emit statement.

### [L-2] `TSwapPool::swapExactInput` returns unused value

**IMPACT:** Low
**LIKELIHOOD:** High

**Description:** The `swapExactInput` function returns `uint256 output`, but the return value is not well-documented and the function ends with `_swap` which doesn't return the value explicitly in a `return` statement (though solidity handles named returns).

```solidity
    function swapExactInput(
        IERC20 inputToken,
        uint256 inputAmount,
        IERC20 outputToken,
        uint256 minOutputAmount,
        uint64 deadline
    )
        public
        revertIfZero(inputAmount)
        revertIfDeadlinePassed(deadline)
        returns (uint256 output)
    {
        uint256 inputReserves = inputToken.balanceOf(address(this));
        uint256 outputReserves = outputToken.balanceOf(address(this));

        uint256 outputAmount = getOutputAmountBasedOnInput(
            inputAmount,
            inputReserves,
            outputReserves
        );

        if (outputAmount < minOutputAmount) {
            revert TSwapPool__OutputTooLow(outputAmount, minOutputAmount);
        }

        _swap(inputToken, inputAmount, outputToken, outputAmount);
    }
```

**Impact:** Confusing API for integrators.

**Recommended Mitigation:** Ensure the return value is explicit and documented.

### [L-3] `PoolFactory::createPool` uses wrong token symbol

**IMPACT:** Low
**LIKELIHOOD:** High

**Description:** When creating a new pool, the `liquidityTokenSymbol` is created using the name of the token instead of the symbol.

```solidity
string memory liquidityTokenSymbol = string.concat("ts", IERC20(tokenAddress).name());
```

**Impact:** The symbol of the LP token will be incorrect (e.g., "tsWrapped Ether" instead of "tsWETH"), which is confusing.

**Recommended Mitigation:** Use `.symbol()` instead of `.name()`.

### [I-1] Missing `zero address` checks

**Description:** Several functions and constructors lack checks for `address(0)`.

- `PoolFactory::constructor`: `wethToken`

```solidity
    constructor(address wethToken) {
        i_wethToken = wethToken;
    }
```

- `PoolFactory::createPool`: `tokenAddress`

```solidity
    function createPool(address tokenAddress) external returns (address) {
        if (s_pools[tokenAddress] != address(0)) {
            revert PoolFactory__PoolAlreadyExists(tokenAddress);
        }
        // ...
```

- `TSwapPool::constructor`: `wethToken`, `poolToken`

```solidity
    constructor(
        address poolToken,
        address wethToken,
        string memory liquidityTokenName,
        string memory liquidityTokenSymbol
    ) ERC20(liquidityTokenName, liquidityTokenSymbol) {
        i_wethToken = IERC20(wethToken);
        i_poolToken = IERC20(poolToken);
    }
```

**Recommended Mitigation:** Add `require(address != address(0))` checks.

### [I-2] Missing `revertIfZero` checks

**Description:** Several functions accept amount parameters that should be checked against 0 to avoid wasted gas or logic errors.

- `TSwapPool::deposit`: `maximumPoolTokensToDeposit`

```solidity
    function deposit(
        uint256 wethToDeposit,
        uint256 minimumLiquidityTokensToMint,
        uint256 maximumPoolTokensToDeposit,
        uint64 deadline
    )
        external
        revertIfZero(wethToDeposit)
        returns (uint256 liquidityTokensToMint)
    {
        // ...
```

- `TSwapPool::swapExactInput`: `minOutputAmount`

```solidity
    function swapExactInput(
        IERC20 inputToken,
        uint256 inputAmount,
        IERC20 outputToken,
        uint256 minOutputAmount,
        uint64 deadline
    )
        public
        revertIfZero(inputAmount)
        revertIfDeadlinePassed(deadline)
        returns (uint256 output)
    {
        // ...
```

**Recommended Mitigation:** Add `revertIfZero` modifier or require checks.

### [I-3] Missing `indexed` event fields

**Description:** Events `PoolCreated`, `LiquidityAdded`, `LiquidityRemoved`, and `Swap` do not use `indexed` keywords on addresses (except `LiquidityAdded` which has one). `Swap` is missing indexed keys for `tokenIn` and `tokenOut`, making it hard to filter swaps by token.

Found in `src/TSwapPool.sol`:

```solidity
    event LiquidityAdded(
        address indexed liquidityProvider,
        uint256 wethDeposited,
        uint256 poolTokensDeposited
    );

    event LiquidityRemoved(
        address indexed liquidityProvider,
        uint256 wethWithdrawn,
        uint256 poolTokensWithdrawn
    );

    event Swap(
        address indexed swapper,
        IERC20 tokenIn,
        uint256 amountTokenIn,
        IERC20 tokenOut,
        uint256 amountTokenOut
    );
```

Found in `src/PoolFactory.sol`:

```solidity
    event PoolCreated(address tokenAddress, address poolAddress);
```

**Recommended Mitigation:** Add `indexed` to address parameters in events.

### [I-4] Magic Numbers

**Description:** The codebase uses literal numbers like `1000`, `997`, `10000`, `1e18`.

**Found in:**

In `src/TSwapPool.sol`:

```solidity
        uint256 inputAmountMinusFee = inputAmount * 997;
        uint256 numerator = inputAmountMinusFee * outputReserves;
        uint256 denominator = (inputReserves * 1000) + inputAmountMinusFee;
```

```solidity
        return
            ((inputReserves * outputAmount) * 10000) /
            ((outputReserves - outputAmount) * 997);
```

```solidity
        return
            getOutputAmountBasedOnInput(
                1e18,
                i_wethToken.balanceOf(address(this)),
                i_poolToken.balanceOf(address(this))
            );
```

```solidity
        return
            getOutputAmountBasedOnInput(
                1e18,
                i_poolToken.balanceOf(address(this)),
                i_wethToken.balanceOf(address(this))
            );
```

**Recommended Mitigation:** Define these as `constant` variables (e.g., `FEE_MULTIPLIER = 997`).

### [I-5] PUSH0 Opscode capability

**Description:** The contract uses `pragma solidity 0.8.20`, which may use the `PUSH0` opcode. This opcode is not supported on all EVM chains (e.g., possibly L2s or older mainnet forks depending on timing).

Found in `src/TSwapPool.sol` and `src/PoolFactory.sol`:
```solidity
pragma solidity 0.8.20;
```

**Recommended Mitigation:** Verify target chain compatibility or use 0.8.19.

### [I-6] Unused Custom Errors

**Description:** `PoolFactory__PoolDoesNotExist` is defined but never used.

Found in `src/PoolFactory.sol`:

```solidity
    error PoolFactory__PoolAlreadyExists(address tokenAddress);
    error PoolFactory__PoolDoesNotExist(address tokenAddress);
```

**Recommended Mitigation:** Remove unused errors.

### [I-7] `PoolFactory`: Liquidity token name missing zero length check

**Description:** The `PoolFactory::createPool` function creates a new liquidity token with a name derived from the token's name. However, there is no check to ensure that the liquidity token name is not empty or zero length.

Found in `src/PoolFactory.sol`:

```solidity
string memory liquidityTokenName = string.concat("T-Swap ", IERC20(tokenAddress).name());
```

**Recommended Mitigation:** Add a check to ensure `liquidityTokenName` is not empty.

### [I-8] `TSwapPool::deposit`: Error emits constant value

**Description:** The error `TSwapPool__WethDepositAmountTooLow` emits `MINIMUM_WETH_LIQUIDITY`, which is a constant. Emitting constants in errors is unnecessary and increases gas costs.

Found in `src/TSwapPool.sol`:

```solidity
revert TSwapPool__WethDepositAmountTooLow(
    MINIMUM_WETH_LIQUIDITY,
    wethToDeposit
);
```

**Recommended Mitigation:** Remove the constant from the error definition and emission.

### [I-9] `TSwapPool::deposit`: Unused local variable `poolTokenReserves`

**Description:** The `poolTokenReserves` variable is defined but never used in the `deposit` function.

Found in `src/TSwapPool.sol`:

```solidity
uint256 poolTokenReserves = i_poolToken.balanceOf(address(this));
```

**Recommended Mitigation:** Remove the unused variable.

### [I-10] `TSwapPool::swapExactInput`: Function should be `external`

**Description:** The `swapExactInput` function is marked as `public` but is not called internally. It should be marked as `external` to save gas.

Found in `src/TSwapPool.sol`:

```solidity
function swapExactInput(
    ...
)
    public
```

**Recommended Mitigation:** Change visibility to `external`.

### [I-11] `TSwapPool::swapExactInput`: Missing NatSpec

**Description:** The `swapExactInput` function lacks NatSpec documentation, making it difficult for developers and auditors to understand its purpose and parameters.

Found in `src/TSwapPool.sol`:

```solidity
function swapExactInput(
```

**Recommended Mitigation:** Add complete NatSpec documentation.

### [I-12] `TSwapPool::swapExactOutput`: Missing `deadline` in NatSpec

**Description:** The NatSpec for `swapExactOutput` is missing the `@param deadline` documentation.

Found in `src/TSwapPool.sol`:

```solidity
function swapExactOutput(
```

**Recommended Mitigation:** Add the missing parameter documentation.

### [I-13] `TSwapPool::swapExactOutput`: Missing `maxInputAmount` indication

**Description:** The function does not clearly indicate or enforce a maximum input amount, which is crucial for slippage protection (related to H-3).

**Recommended Mitigation:** Implement `maxInputAmount` parameter (as recommended in H-3).

### [I-14] `TSwapPool::_swap`: Invariant check missing

**Description:** The `_swap` function does not verify that the constant product invariant (`x * y = k`) holds after the swap.

**Recommended Mitigation:** Consider adding an invariant check in debug/testing mode or ensure math guarantees it.

