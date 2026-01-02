// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {PoolFactory} from "../../src/PoolFactory.sol";
import {TSwapPool} from "../../src/TSwapPool.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {Handler} from "./Handler.t.sol";

contract InvariantTest is StdInvariant, Test {

    uint256 internal constant STARTING_X = 100 * 1e18;
    uint256 internal constant STARTING_Y = 50 * 1e18;
    PoolFactory public factory;
    Handler public handler;
    TSwapPool public pool; // poolToken <-> WETH
    ERC20Mock public weth;
    ERC20Mock public poolToken;

    function setUp() public {
        weth = new ERC20Mock("Wrapped Ethereum Mock", "WETH");
        poolToken = new ERC20Mock("Pool Token Mock", "PT");
        factory = new PoolFactory(address(weth));
        pool = TSwapPool(factory.createPool(address(poolToken)));

        // Create initial x and y balances
        weth.mint(address(this), STARTING_Y);
        poolToken.mint(address(this), STARTING_X);

        poolToken.approve(address(pool), type(uint256).max);
        weth.approve(address(pool), type(uint256).max);
        
        pool.deposit(
            STARTING_Y, // wethToDeposit
            STARTING_Y, // minimumLiquidityTokensToMint -> LPTokens
            STARTING_X, // maximumPoolTokensToDeposit
            uint64(block.timestamp) // deadline
        );

        handler = new Handler(pool);
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = handler.swapPoolTokenForWethBasedOnOutputWeth.selector;
        selectors[1] = handler.deposit.selector;
        
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function statefulFuzzconstantProductFormulaStaysTheSameX() public view {
        // The change in the pool size of WETH shoild follow this function:
        // ∆x = (β/(1-β)) * x
        // actual delta X == ∆x = (β/(1-β)) * x
        assertEq(handler.actualDeltaX(), handler.expectedDeltaX());
    }

    function statefulFuzzconstantProductFormulaStaysTheSameY() public view {
        // The change in the pool size of WETH shoild follow this function:
        // ∆y = (β/(1-β)) * y
        // actual delta Y == ∆y = (β/(1-β)) * y
        assertEq(handler.actualDeltaY(), handler.expectedDeltaY());
    }
}