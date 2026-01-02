/**
 * /-\|/-\|/-\|/-\|/-\|/-\|/-\|/-\|/-\|/-\
 * |                                     |
 * \ _____    ____                       /
 * -|_   _|  / ___|_      ____ _ _ __    -
 * /  | |____\___ \ \ /\ / / _` | '_ \   \
 * |  | |_____|__) \ V  V / (_| | |_) |  |
 * \  |_|    |____/ \_/\_/ \__,_| .__/   /
 * -                            |_|      -
 * /                                     \
 * |                                     |
 * \-/|\-/|\-/|\-/|\-/|\-/|\-/|\-/|\-/|\-/
 */
// SPDX-License-Identifier: GNU General Public License v3.0
pragma solidity 0.8.20;
// @audit-info PUSH0 is not supported by all chains

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract TSwapPool is ERC20 {
    error TSwapPool__DeadlineHasPassed(uint64 deadline);
    error TSwapPool__MaxPoolTokenDepositTooHigh(
        uint256 maximumPoolTokensToDeposit,
        uint256 poolTokensToDeposit
    );
    error TSwapPool__MinLiquidityTokensToMintTooLow(
        uint256 minimumLiquidityTokensToMint,
        uint256 liquidityTokensToMint
    );
    error TSwapPool__WethDepositAmountTooLow(
        uint256 minimumWethDeposit,
        uint256 wethToDeposit
    );
    error TSwapPool__InvalidToken();
    error TSwapPool__OutputTooLow(uint256 actual, uint256 min);
    error TSwapPool__MustBeMoreThanZero();

    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    IERC20 private immutable i_wethToken;
    IERC20 private immutable i_poolToken;
    // @audit-info Large literal values can be replaced with scientific notation (1_000_000_000 -> 1e9)
    uint256 private constant MINIMUM_WETH_LIQUIDITY = 1_000_000_000;
    uint256 private swap_count = 0;
    uint256 private constant SWAP_COUNT_MAX = 10;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    // @audit-info Missing indexed values
    event LiquidityAdded(
        address indexed liquidityProvider,
        uint256 wethDeposited,
        uint256 poolTokensDeposited
    );
    // @audit-info Missing indexed values
    event LiquidityRemoved(
        address indexed liquidityProvider,
        uint256 wethWithdrawn,
        uint256 poolTokensWithdrawn
    );
    // @audit-info Missing indexed values for tokenIn and tokenOut
    event Swap(
        address indexed swapper,
        IERC20 tokenIn,
        uint256 amountTokenIn,
        IERC20 tokenOut,
        uint256 amountTokenOut
    );

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/
    modifier revertIfDeadlinePassed(uint64 deadline) {
        if (deadline < uint64(block.timestamp)) {
            revert TSwapPool__DeadlineHasPassed(deadline);
        }
        _;
    }

    modifier revertIfZero(uint256 amount) {
        if (amount == 0) {
            revert TSwapPool__MustBeMoreThanZero();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    constructor(
        address poolToken,
        address wethToken,
        string memory liquidityTokenName,
        string memory liquidityTokenSymbol
    ) ERC20(liquidityTokenName, liquidityTokenSymbol) {
        // @audit-info missing zero address check
        i_wethToken = IERC20(wethToken);
        // @audit-info missing zero address check
        i_poolToken = IERC20(poolToken);
    }

    /*//////////////////////////////////////////////////////////////
                        ADD AND REMOVE LIQUIDITY
    //////////////////////////////////////////////////////////////*/

    /// @notice Adds liquidity to the pool
    /// @dev The invariant of this function is that the ratio of WETH, PoolTokens, and LiquidityTokens is the same
    /// before and after the transaction
    /// @param wethToDeposit Amount of WETH the user is going to deposit
    /// @param minimumLiquidityTokensToMint We derive the amount of liquidity tokens to mint from the amount of WETH the
    /// user is going to deposit, but set a minimum so they know approx what they will accept
    /// @param maximumPoolTokensToDeposit The maximum amount of pool tokens the user is willing to deposit, again it's
    /// derived from the amount of WETH the user is going to deposit
    /// @param deadline The deadline for the transaction to be completed by

    // @audit-info maximumPoolTokensToDeposit should revert if it is zero
    // audit-info revertIfZero(maximumPoolTokensToDeposit)
    function deposit(
        uint256 wethToDeposit,
        uint256 minimumLiquidityTokensToMint,
        uint256 maximumPoolTokensToDeposit,
        // @audit-issue - HIGH - deadline is not used
        // audit-issue IMPACT: HIGH
        // audit-issue LIKELIHOOD: HIGH (Always)
        // audit-issue RECOMMENDATION: Use revertIfDeadlinePassed(deadline)
        uint64 deadline
    )
        external
        revertIfZero(wethToDeposit)
        returns (uint256 liquidityTokensToMint)
    {
        if (wethToDeposit < MINIMUM_WETH_LIQUIDITY) {
            // @audit-info MINIMUM_WETH_LIQUIDITY is a constant and is not necessary to be emitted in the error
            revert TSwapPool__WethDepositAmountTooLow(
                MINIMUM_WETH_LIQUIDITY,
                wethToDeposit
            );
        }
        if (totalLiquidityTokenSupply() > 0) {
            uint256 wethReserves = i_wethToken.balanceOf(address(this));
            // @audit-info poolTokenReserves is not used
            uint256 poolTokenReserves = i_poolToken.balanceOf(address(this));
            // Our invariant says weth, poolTokens, and liquidity tokens must always have the same ratio after the
            // initial deposit
            // poolTokens / constant(k) = weth
            // weth / constant(k) = liquidityTokens
            // aka...
            // weth / poolTokens = constant(k)
            // To make sure this holds, we can make sure the new balance will match the old balance
            // (wethReserves + wethToDeposit) / (poolTokenReserves + poolTokensToDeposit) = constant(k)
            // (wethReserves + wethToDeposit) / (poolTokenReserves + poolTokensToDeposit) =
            // (wethReserves / poolTokenReserves)
            //
            // So we can do some elementary math now to figure out poolTokensToDeposit...
            // (wethReserves + wethToDeposit) = (poolTokenReserves + poolTokensToDeposit) * (wethReserves / poolTokenReserves)
            // wethReserves + wethToDeposit  = poolTokenReserves * (wethReserves / poolTokenReserves) + poolTokensToDeposit * (wethReserves / poolTokenReserves)
            // wethReserves + wethToDeposit = wethReserves + poolTokensToDeposit * (wethReserves / poolTokenReserves)
            // wethToDeposit / (wethReserves / poolTokenReserves) = poolTokensToDeposit
            // (wethToDeposit * poolTokenReserves) / wethReserves = poolTokensToDeposit
            uint256 poolTokensToDeposit = getPoolTokensToDepositBasedOnWeth(
                wethToDeposit
            );
            // @audit-ok maximumPoolTokensToDeposit should be higher than poolTokensToDeposit
            if (maximumPoolTokensToDeposit < poolTokensToDeposit) {
                revert TSwapPool__MaxPoolTokenDepositTooHigh(
                    maximumPoolTokensToDeposit,
                    poolTokensToDeposit
                );
            }

            // We do the same thing for liquidity tokens. Similar math.
            // @audit-ok - example - Deposit 10 WETH, total liquidity tokens is 100, total weth is 100
            // audit - example - liquidityTokensToMint = (10 * 100) / 100 = 10
            liquidityTokensToMint = (wethToDeposit * totalLiquidityTokenSupply()) / wethReserves;
            // @audit-ok minimumLiquidityTokensToMint should be lower than liquidityTokensToMint
            if (liquidityTokensToMint < minimumLiquidityTokensToMint) {
                revert TSwapPool__MinLiquidityTokensToMintTooLow(
                    minimumLiquidityTokensToMint,
                    liquidityTokensToMint
                );
            }
            _addLiquidityMintAndTransfer(
                wethToDeposit,
                poolTokensToDeposit,
                liquidityTokensToMint
            );
        } else {
            // This will be the "initial" funding of the protocol. We are starting from blank here!
            // We just have them send the tokens in, and we mint liquidity tokens based on the weth
            _addLiquidityMintAndTransfer(
                wethToDeposit,
                maximumPoolTokensToDeposit,
                wethToDeposit
            );
            liquidityTokensToMint = wethToDeposit;
        }
    }

    /// @dev This is a sensitive function, and should only be called by addLiquidity
    /// @param wethToDeposit The amount of WETH the user is going to deposit
    /// @param poolTokensToDeposit The amount of pool tokens the user is going to deposit
    /// @param liquidityTokensToMint The amount of liquidity tokens the user is going to mint
    function _addLiquidityMintAndTransfer(
        uint256 wethToDeposit,
        uint256 poolTokensToDeposit,
        uint256 liquidityTokensToMint
    ) private {
        // @audit-ok Uses CEI patterns
        _mint(msg.sender, liquidityTokensToMint);
        // @audit-issue (low) -> the parameters are backwards
        // audit-issue LiquidityAdded(msg.sender, wethToDeposit, poolTokensToDeposit);
        emit LiquidityAdded(msg.sender, poolTokensToDeposit, wethToDeposit);

        // Interactions
        i_wethToken.safeTransferFrom(msg.sender, address(this), wethToDeposit);
        i_poolToken.safeTransferFrom(msg.sender, address(this), poolTokensToDeposit);
    }

    /// @notice Removes liquidity from the pool
    /// @param liquidityTokensToBurn The number of liquidity tokens the user wants to burn
    /// @param minWethToWithdraw The minimum amount of WETH the user wants to withdraw
    /// @param minPoolTokensToWithdraw The minimum amount of pool tokens the user wants to withdraw
    /// @param deadline The deadline for the transaction to be completed by
    function withdraw(
        uint256 liquidityTokensToBurn,
        uint256 minWethToWithdraw,
        uint256 minPoolTokensToWithdraw,
        uint64 deadline
    )
        external
        revertIfDeadlinePassed(deadline)
        revertIfZero(liquidityTokensToBurn)
        revertIfZero(minWethToWithdraw)
        revertIfZero(minPoolTokensToWithdraw)
    {
        // We do the same math as above
        uint256 wethToWithdraw = (liquidityTokensToBurn * i_wethToken.balanceOf(address(this))) / totalLiquidityTokenSupply();
        uint256 poolTokensToWithdraw = (liquidityTokensToBurn * i_poolToken.balanceOf(address(this))) / totalLiquidityTokenSupply();

        if (wethToWithdraw < minWethToWithdraw) {
            revert TSwapPool__OutputTooLow(wethToWithdraw, minWethToWithdraw);
        }
        if (poolTokensToWithdraw < minPoolTokensToWithdraw) {
            revert TSwapPool__OutputTooLow(
                poolTokensToWithdraw,
                minPoolTokensToWithdraw
            );
        }

        _burn(msg.sender, liquidityTokensToBurn);
        emit LiquidityRemoved(msg.sender, wethToWithdraw, poolTokensToWithdraw);

        i_wethToken.safeTransfer(msg.sender, wethToWithdraw);
        i_poolToken.safeTransfer(msg.sender, poolTokensToWithdraw);
    }

    /*//////////////////////////////////////////////////////////////
                              GET PRICING
    //////////////////////////////////////////////////////////////*/

    function getOutputAmountBasedOnInput(
        uint256 inputAmount,
        uint256 inputReserves,
        uint256 outputReserves
    )
        public
        pure
        revertIfZero(inputAmount)
        revertIfZero(outputReserves)
        returns (uint256 outputAmount)
    {
        // x * y = k
        // numberOfWeth * numberOfPoolTokens = constant k
        // k must not change during a transaction (invariant)
        // with this math, we want to figure out how many PoolTokens to deposit
        // since weth * poolTokens = k, we can rearrange to get:
        // (currentWeth + wethToDeposit) * (currentPoolTokens + poolTokensToDeposit) = k
        // **************************
        // ****** MATH TIME!!! ******
        // **************************
        // FOIL it (or ChatGPT): https://en.wikipedia.org/wiki/FOIL_method
        // (totalWethOfPool * totalPoolTokensOfPool) + (totalWethOfPool * poolTokensToDeposit) + (wethToDeposit *
        // totalPoolTokensOfPool) + (wethToDeposit * poolTokensToDeposit) = k
        // (totalWethOfPool * totalPoolTokensOfPool) + (wethToDeposit * totalPoolTokensOfPool) = k - (totalWethOfPool *
        // poolTokensToDeposit) - (wethToDeposit * poolTokensToDeposit)
        // @audit-ok 997 / 1000 = 0.997 -> 1 - 0.997 = 0.003 -> 0.003 * 100 = 0.3% fee
        // @audit-info Replace 997 with a constant
        uint256 inputAmountMinusFee = inputAmount * 997;
        uint256 numerator = inputAmountMinusFee * outputReserves;
        // @audit-info Replace 1000 with a constant
        uint256 denominator = (inputReserves * 1000) + inputAmountMinusFee;
        return numerator / denominator;
    }

    function getInputAmountBasedOnOutput(
        uint256 outputAmount,
        uint256 inputReserves,
        uint256 outputReserves
    )
        public
        pure
        revertIfZero(outputAmount)
        revertIfZero(outputReserves)
        returns (uint256 inputAmount)
    {
        // @audit ∆x = (β/(1-β)) * x
        // audit x * y = (x + ∆x) * (y − ∆y)
        // audit x * y = (x + ∆x) * (y − outputAmount)
        // audit x * y = x*y - x*outputAmount + ∆x*y - ∆x*outputAmount
        // audit -x*y                     -x*y
        // audit 0 = x*outputAmount + ∆x*y + ∆x*outputAmount
        // audit +x*outputAmount          x*outputAmount
        // audit x*outputAmount = ∆x*y - ∆x*outputAmount
        // audit inputReserves * outputAmount = inputAmount * (outputReserves - outputAmount)
        // audit inputAmount = (inputReserves * outputAmount) / (outputReserves - outputAmount)
        // audit without fees.... ingoring them for now
        // audit formula without fees is OK
        // @audit-info Replace magic numbers with constants
        // @audit-info Large literal values multiples of 10000 can be replaced with scientific notation
        // @audit-issue - 997 / 10000 = 0.0997 -> 1 - 0.0997 = 0.9003 -> 0.9003 * 100 = 90.03% fee
        // audit issue IMPACT: HIGH
        // audit issue LIKELIHOOD: HIGH
        // audit issue HIGH
        // audit-issue it should be 1000 instead of 10000 (Fix it replacing the magic number with a constant)
        return
            ((inputReserves * outputAmount) * 10000) /
            ((outputReserves - outputAmount) * 997);
    }

    // @audit-info This function could be marked as external
    // @audit-info Where is the NatSpec here?
    // @audit-info Missing address zero checks for inputToken and outputToken
    // @audit-info Missing minOutputAmount revertIfZero
    // @audit-issue - LOW - Unused return parameter (output)
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

    /*
     * @notice figures out how much you need to input based on how much
     * output you want to receive.
     *
     * Example: You say "I want 10 output WETH, and my input is DAI"
     * The function will figure out how much DAI you need to input to get 10 WETH
     * And then execute the swap
     * @param inputToken ERC20 token to pull from caller
     * @param outputToken ERC20 token to send to caller
     * @param outputAmount The exact amount of tokens to send to caller
     */
    // @audit-info Missing deadline parameter in natspec
    // @audit-info Missing maximum input amount?
    function swapExactOutput(
        IERC20 inputToken,
        IERC20 outputToken,
        uint256 outputAmount,
        // @audit-info No slippage protection - maxInputAmount is missing
        // audit-info uint256 maxInputAmount,
        // audit-info If the pool gets a massive transaction that changes the price
        // audit-info the user will get less output than expected
        uint64 deadline
    )
        public
        revertIfZero(outputAmount)
        revertIfDeadlinePassed(deadline)
        returns (uint256 inputAmount)
    {
        uint256 inputReserves = inputToken.balanceOf(address(this));
        uint256 outputReserves = outputToken.balanceOf(address(this));

        inputAmount = getInputAmountBasedOnOutput(
            outputAmount,
            inputReserves,
            outputReserves
        );

        _swap(inputToken, inputAmount, outputToken, outputAmount);
    }

    /**
     * @notice wrapper function to facilitate users selling pool tokens in exchange of WETH
     * @param poolTokenAmount amount of pool tokens to sell
     * @return wethAmount amount of WETH received by caller
     */
    function sellPoolTokens(
        uint256 poolTokenAmount
    ) external returns (uint256 wethAmount) {
        return
            // @audit-issue We should use here swapExactInput instead of swapExactOutput
            // audit-issue Input token is pool token
            // audit-issue Output token is WETH
            // audit-issue We know exactly the input amount
            swapExactOutput(
                i_poolToken,
                i_wethToken,
                poolTokenAmount,
                uint64(block.timestamp)
            );
    }

    /**
     * @notice Swaps a given amount of input for a given amount of output tokens.
     * @dev Every 10 swaps, we give the caller an extra token as an extra incentive to keep trading on T-Swap.
     * @param inputToken ERC20 token to pull from caller
     * @param inputAmount Amount of tokens to pull from caller
     * @param outputToken ERC20 token to send to caller
     * @param outputAmount Amount of tokens to send to caller
     */
    function _swap(
        IERC20 inputToken,
        uint256 inputAmount,
        IERC20 outputToken,
        uint256 outputAmount
    ) private {
        if (
            _isUnknown(inputToken) ||
            _isUnknown(outputToken) ||
            inputToken == outputToken
        ) {
            revert TSwapPool__InvalidToken();
        }

        swap_count++;
        // @audit-issue This fee-on-transfer breaks the invariant
        // if (swap_count >= SWAP_COUNT_MAX) {
        //     swap_count = 0;
        //     outputToken.safeTransfer(msg.sender, 1_000_000_000_000_000_000);
        // }
        emit Swap(
            msg.sender,
            inputToken,
            inputAmount,
            outputToken,
            outputAmount
        );

        inputToken.safeTransferFrom(msg.sender, address(this), inputAmount);
        outputToken.safeTransfer(msg.sender, outputAmount);

        // @audit-info We can add here a check for the constant product invariant
        // audit-info x * y = k Before swap == After swap
    }

    function _isUnknown(IERC20 token) private view returns (bool) {
        if (token != i_wethToken && token != i_poolToken) {
            return true;
        }
        return false;
    }

    /*//////////////////////////////////////////////////////////////
                   EXTERNAL AND PUBLIC VIEW AND PURE
    //////////////////////////////////////////////////////////////*/
    function getPoolTokensToDepositBasedOnWeth(
        uint256 wethToDeposit
    ) public view returns (uint256) {
        uint256 poolTokenReserves = i_poolToken.balanceOf(address(this));
        uint256 wethReserves = i_wethToken.balanceOf(address(this));
        // @audit-ok ∆x = (β/(1-β)) * x
        // audit-ok ∆x = (∆y * x) / y;
        // audit-ok ∆x = (wethToDeposit * poolTokenReserves) / wethReserves;
        return (wethToDeposit * poolTokenReserves) / wethReserves;
    }

    /// @notice a more verbose way of getting the total supply of liquidity tokens
    function totalLiquidityTokenSupply() public view returns (uint256) {
        return totalSupply();
    }

    function getPoolToken() external view returns (address) {
        return address(i_poolToken);
    }

    function getWeth() external view returns (address) {
        return address(i_wethToken);
    }

    function getMinimumWethDepositAmount() external pure returns (uint256) {
        return MINIMUM_WETH_LIQUIDITY;
    }

    function getPriceOfOneWethInPoolTokens() external view returns (uint256) {
        return
            getOutputAmountBasedOnInput(
                // @audit-info Replace magic numbers with constants
                1e18,
                i_wethToken.balanceOf(address(this)),
                i_poolToken.balanceOf(address(this))
            );
    }

    function getPriceOfOnePoolTokenInWeth() external view returns (uint256) {
        return
            getOutputAmountBasedOnInput(
                // @audit-info Replace magic numbers with constants
                1e18,
                i_poolToken.balanceOf(address(this)),
                i_wethToken.balanceOf(address(this))
            );
    }
}
