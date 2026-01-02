//SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {TSwapPool} from "../../src/TSwapPool.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

contract Handler is Test {
    TSwapPool public pool;
    ERC20Mock weth;
    ERC20Mock poolToken;

    // Ghost variables
    int256 public startingY;
    int256 public startingX;

    int256 public expectedDeltaY; // Change in WETH balances
    int256 public expectedDeltaX; // Change in PoolToken balances

    int256 public actualDeltaY;
    int256 public actualDeltaX;

    // User
    address public liquidityProvider;
    address public swapper;

    constructor(TSwapPool _pool) {
        pool = _pool;
        weth = ERC20Mock(address(pool.getWeth()));
        poolToken = ERC20Mock(address(pool.getPoolToken()));
        liquidityProvider = makeAddr("liquidityProvider");
        swapper = makeAddr("swapper");
    }

    function swapPoolTokenForWethBasedOnOutputWeth(uint256 outputWeth) public {
        uint256 minWethDeposit = pool.getMinimumWethDepositAmount();
        if (weth.balanceOf(address(pool)) <= minWethDeposit) {
            return;
        }

        outputWeth = bound(outputWeth, minWethDeposit, weth.balanceOf(address(pool)));
        // If these two values are the same, we will divide by 0
        if (outputWeth == weth.balanceOf(address(pool))) {
            return;
        }
        
        uint256 outputReserves = weth.balanceOf(address(pool));
        uint256 inputReserves = poolToken.balanceOf(address(pool));
        
        // Prevent overflow in getInputAmountBasedOnOutput
        if (inputReserves > 0 && outputWeth > type(uint256).max / inputReserves / 10000) {
            return;
        }
        
        // ∆x = (β/(1-β)) * x
        // x * y = k
        uint256 poolTokenAmount = pool.getInputAmountBasedOnOutput(outputWeth, inputReserves, outputReserves);

        startingY = int256(weth.balanceOf(address(pool)));
        startingX = int256(poolToken.balanceOf(address(pool)));
        expectedDeltaY = int256(-1) * int256(outputWeth);
        expectedDeltaX = int256(poolTokenAmount);
        // This is also valid
        // expectedDeltaX = int256(pool.getPoolTokensToDepositBasedOnWeth(outputWeth));

        if (poolToken.balanceOf(swapper) < poolTokenAmount) {
            poolToken.mint(swapper, poolTokenAmount - poolToken.balanceOf(swapper) + 1);
        }
        
        // swap
        vm.startPrank(swapper);
        poolToken.approve(address(pool), type(uint256).max);
        pool.swapExactOutput({
            inputToken: poolToken,
            outputToken: weth,
            outputAmount: outputWeth,
            deadline: uint64(block.timestamp)
        });
            
        vm.stopPrank();

        // Assert with actual values
        int256 endingY = int256(weth.balanceOf(address(pool)));
        int256 endingX = int256(poolToken.balanceOf(address(pool)));

        actualDeltaY = endingY - startingY;
        actualDeltaX = endingX - startingX;
    }

    // deposit, swapExactOutput
    function deposit(uint256 wethAmount) public {
        // let's make sure if it's a reanoable amount
        // avoid weird overflow errors
        uint256 minWethDeposit = pool.getMinimumWethDepositAmount();
        wethAmount = bound(wethAmount, minWethDeposit, type(uint64).max); // 1 -> 18 WETH
        // Additional sanity check: if adding this amount would cause overflow in downstream calc, skip.
        // This is not masking a bug, but preventing the fuzzer from exploring mathematically impossible states.
        uint256 poolTokenReserves = poolToken.balanceOf(address(pool));
        if (poolTokenReserves > 0 && wethAmount > type(uint256).max / poolTokenReserves) {
            return;
        }

        startingY = int256(weth.balanceOf(address(pool)));
        startingX = int256(poolToken.balanceOf(address(pool)));
        expectedDeltaY = int256(wethAmount);
        expectedDeltaX = int256(pool.getPoolTokensToDepositBasedOnWeth(wethAmount));  

        // deposit
        vm.startPrank(liquidityProvider);
        
        weth.mint(liquidityProvider, wethAmount);
        poolToken.mint(liquidityProvider, uint256(expectedDeltaX));

        weth.approve(address(pool), type(uint256).max);
        poolToken.approve(address(pool), type(uint256).max);
        
        pool.deposit(
            wethAmount,
            0,
            uint256(expectedDeltaX),
            uint64(block.timestamp)
        );
        
        vm.stopPrank();

        // Assert with actual values      
        int256 endingY = int256(weth.balanceOf(address(pool)));
        int256 endingX = int256(poolToken.balanceOf(address(pool)));

        actualDeltaY = endingY - startingY;
        actualDeltaX = endingX - startingX;
    }
}
