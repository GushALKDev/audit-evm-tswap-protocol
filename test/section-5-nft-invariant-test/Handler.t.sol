// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {S5Pool} from "../../src/section-5-nft/S5Pool.sol";
import {S5Token} from "../../src/section-5-nft/S5Token.sol";

contract S5Handler is Test {
    S5Pool public s_pool;
    S5Token public tokenA;
    S5Token public tokenB;
    S5Token public tokenC;

    address public liquidityProvider;
    address public user;

   constructor(S5Pool _pool, address _tokenA, address _tokenB, address _tokenC) {
        s_pool = _pool;
        tokenA = S5Token(_tokenA);
        tokenB = S5Token(_tokenB);
        tokenC = S5Token(_tokenC);

        liquidityProvider = makeAddr("liquidityProvider");
        user = makeAddr("user");
    }

    function deposit(uint256 amount) public {
        amount = bound(amount, 1, type(uint64).max);

        deal(address(tokenA), liquidityProvider, amount);
        deal(address(tokenB), liquidityProvider, amount);
        deal(address(tokenC), liquidityProvider, amount);

        vm.startPrank(liquidityProvider);
        tokenA.approve(address(s_pool), type(uint256).max);
        tokenB.approve(address(s_pool), type(uint256).max);
        tokenC.approve(address(s_pool), type(uint256).max);
        
        s_pool.deposit(amount, uint64(block.timestamp));
        vm.stopPrank();
    }

    function swapFrom(uint256 fromSeed, uint256 toSeed, uint256 amount) public {
        S5Token from = _getToken(fromSeed);
        S5Token to = _getToken(toSeed);

        amount = bound(amount, 0, type(uint64).max);
        deal(address(from), user, amount);

        vm.startPrank(user);
        from.approve(address(s_pool), type(uint256).max);
        s_pool.swapFrom(from, to, amount);
        vm.stopPrank();
    }

    function _getToken(uint256 seed) internal view returns (S5Token) {
        uint256 choice = bound(seed, 0, 2);
        if (choice == 0) return tokenA;
        if (choice == 1) return tokenB;
        return tokenC;
    }
}