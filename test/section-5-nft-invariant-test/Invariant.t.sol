//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {S5Pool} from "../../src/section-5-nft/S5Pool.sol";
import {S5Token} from "../../src/section-5-nft/S5Token.sol";
import {S5Handler} from "./Handler.t.sol";

contract S5InvariantTest is StdInvariant, Test {

    uint256 private initialTotalTokens;

    uint256 public constant STARTING_BALANCE = 1000 * 1e18;
    S5Token private tokenA;
    S5Token private tokenB;
    S5Token private tokenC;
    S5Pool public s_pool;
    S5Handler public handler;

    address public liquidityProvider;
    address public user;

    function setUp() public {
        tokenA = new S5Token("A");
        tokenB = new S5Token("B");
        tokenC = new S5Token("C");
        vm.label(address(tokenA), "TokenA");
        vm.label(address(tokenB), "TokenB");
        vm.label(address(tokenC), "TokenC");
        s_pool = new S5Pool(tokenA, tokenB, tokenC);
        user = makeAddr("user");

        // Approve
        tokenA.approve(address(s_pool), type(uint256).max);
        tokenB.approve(address(s_pool), type(uint256).max);
        tokenC.approve(address(s_pool), type(uint256).max);

        //Invariant
        initialTotalTokens = tokenA.INITIAL_SUPPLY() + tokenB.INITIAL_SUPPLY();

        // Deposit
        s_pool.deposit(tokenA.INITIAL_SUPPLY(), uint64(block.timestamp));

        // Handler
        handler = new S5Handler(s_pool, address(tokenA), address(tokenB), address(tokenC));
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.swapFrom.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_testStateFullInvariantS5() public {
        // Redeem
        s_pool.redeem(uint64(block.timestamp));
        // Invariant
        assert(tokenA.balanceOf(address(this)) + tokenB.balanceOf(address(this)) >= initialTotalTokens);
    }
}