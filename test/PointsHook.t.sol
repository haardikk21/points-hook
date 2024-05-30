// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {PointsHook} from "../src/PointsHook.sol";
import {HookMiner} from "./utils/HookMiner.sol";

contract TestPointsHook is Test, Deployers {
    using CurrencyLibrary for Currency;

    MockERC20 token;

    Currency ethCurrency = Currency.wrap(address(0));
    Currency tokenCurrency;

    PointsHook hook;

    function setUp() public {
        // Step 1 + 2
        // Deploy PoolManager and Router contracts
        deployFreshManagerAndRouters();

        // Deploy our TOKEN contract
        token = new MockERC20("Test Token", "TEST", 18);
        tokenCurrency = Currency.wrap(address(token));

        // Mint a bunch of TOKEN to ourselves and to address(1)
        token.mint(address(this), 1000 ether);
        token.mint(address(1), 1000 ether);

        address hookAddress = address(uint160(Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG));

        deployCodeTo("PointsHook.sol", abi.encode(manager, "Points Token", "TEST_POINTS"), hookAddress);
        hook = PointsHook(hookAddress);

        // Approve our TOKEN for spending on the swap router and modify liquidity router
        // These variables are coming from the `Deployers` contract
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);

        // Initialize a pool
        (key, ) = initPool(
            ethCurrency, // Currency 0 = ETH
            tokenCurrency, // Currency 1 = TOKEN
            hook, // Hook Contract
            3000, // Swap Fees
            SQRT_PRICE_1_1, // Initial Sqrt(P) value = 1
            ZERO_BYTES // No additional `initData`
        );
    }

    /*
        currentTick = 0
        We are adding liquidity at tickLower = -60, tickUpper = 60

        New liquidity must not change the token price

        We saw an equation in "Ticks and Q64.96 Numbers" of how to calculate amounts of
        x and y when adding liquidity. Given the three variables - x, y, and L - we need to set value of one.

        We'll set liquidityDelta = 1 ether, i.e. ΔL = 1 ether
        since the `modifyLiquidity` function takes `liquidityDelta` as an argument instead of 
        specific values for `x` and `y`.

        Then, we can calculate Δx and Δy:
        Δx = Δ (L/SqrtPrice) = ( L * (SqrtPrice_tick - SqrtPrice_currentTick) ) / (SqrtPrice_tick * SqrtPrice_currentTick)
        Δy = Δ (L * SqrtPrice) = L * (SqrtPrice_currentTick - SqrtPrice_tick)

        So, we can calculate how much x and y we need to provide
        The python script below implements code to compute that for us
        Python code taken from https://uniswapv3book.com

        ```py
        import math

        q96 = 2**96

        def tick_to_price(t):
            return 1.0001**t

        def price_to_sqrtp(p):
            return int(math.sqrt(p) * q96)

        sqrtp_low = price_to_sqrtp(tick_to_price(-60))
        sqrtp_cur = price_to_sqrtp(tick_to_price(0))
        sqrtp_upp = price_to_sqrtp(tick_to_price(60))

        def calc_amount0(liq_delta, pa, pb):
            if pa > pb:
                pa, pb = pb, pa
            return int(liq_delta * q96 * (pb - pa) / pa / pb)

        def calc_amount1(liq_delta, pa, pb):
            if pa > pb:
                pa, pb = pb, pa
            return int(liq_delta * (pb - pa) / q96)

        one_ether = 10 ** 18
        liq = 1 * one_ether
        eth_amount = calc_amount0(liq, sqrtp_upp, sqrtp_cur)
        token_amount = calc_amount1(liq, sqrtp_low, sqrtp_cur)

        print(dict({
        'eth_amount': eth_amount,
        'eth_amount_readable': eth_amount / 10**18,
        'token_amount': token_amount,
        'token_amount_readable': token_amount / 10**18,
        }))
        ```

        {'eth_amount': 2995354955910434, 'eth_amount_readable': 0.002995354955910434, 'token_amount': 2995354955910412, 'token_amount_readable': 0.002995354955910412}

        Therefore, Δx = 0.002995354955910434 ETH and Δy = 0.002995354955910434 Tokens

        NOTE: Python and Solidity handle precision a bit differently, so these are rough amounts. Slight loss of precision is to be expected.

        */

    function test_addLiquidityAndSwap() public {
        // Set no referrer in the hook data
        bytes memory hookData = hook.getHookData(address(0), address(this));

        uint256 pointsBalanceOriginal = hook.balanceOf(address(this));

        // How we landed on 0.003 ether here is based on computing value of x and y given
        // total value of delta L (liquidity delta) = 1 ether
        // This is done by computing x and y from the equation shown in Ticks and Q64.96 Numbers lesson
        // View the full code for this lesson on GitHub which has additional comments
        // showing the exact computation and a Python script to do that calculation for you
        modifyLiquidityRouter.modifyLiquidity{value: 0.003 ether}(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 1 ether, 
                salt: 0
            }),
            hookData
        );
        uint256 pointsBalanceAfterAddLiquidity = hook.balanceOf(address(this));

        // The exact amount of ETH we're adding (x)
        // is roughly 0.299535... ETH
        // Our original POINTS balance was 0
        // so after adding liquidity we should have roughly 0.299535... POINTS tokens
        assertApproxEqAbs(
            pointsBalanceAfterAddLiquidity - pointsBalanceOriginal,
            2995354955910434,
            0.0001 ether // error margin for precision loss
        );

        // Now we swap
        // We will swap 0.001 ether for tokens
        // We should get 20% of 0.001 * 10**18 points
        // = 2 * 10**14
        swapRouter.swap{value: 0.001 ether}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -0.001 ether, // Exact input for output swap
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}),
            hookData
        );
        uint256 pointsBalanceAfterSwap = hook.balanceOf(address(this));
        assertEq(
            pointsBalanceAfterSwap - pointsBalanceAfterAddLiquidity,
            2 * 10 ** 14
        );
    }

    function test_addLiquidityAndSwapWithReferral() public {
        bytes memory hookData = hook.getHookData(address(1), address(this));

        uint256 pointsBalanceOriginal = hook.balanceOf(address(this));
        uint256 referrerPointsBalanceOriginal = hook.balanceOf(address(1));

        modifyLiquidityRouter.modifyLiquidity{value: 0.003 ether}(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 1 ether,
                salt: 0
            }),
            hookData
        );

        uint256 pointsBalanceAfterAddLiquidity = hook.balanceOf(address(this));
        uint256 referrerPointsBalanceAfterAddLiquidity = hook.balanceOf(
            address(1)
        );

        assertApproxEqAbs(
            pointsBalanceAfterAddLiquidity - pointsBalanceOriginal,
            2995354955910434,
            0.00001 ether
        );
        assertApproxEqAbs(
            referrerPointsBalanceAfterAddLiquidity -
                referrerPointsBalanceOriginal -
                hook.POINTS_FOR_REFERRAL(),
            299535495591043,
            0.000001 ether
        );

        // Now we swap
        // We will swap 0.001 ether for tokens
        // We should get 20% of 0.001 * 10**18 points
        // = 2 * 10**14
        // Referrer should get 10% of that - so 2 * 10**13
        swapRouter.swap{value: 0.001 ether}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -0.001 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}),
            hookData
        );
        uint256 pointsBalanceAfterSwap = hook.balanceOf(address(this));
        uint256 referrerPointsBalanceAfterSwap = hook.balanceOf(address(1));

        assertEq(
            pointsBalanceAfterSwap - pointsBalanceAfterAddLiquidity,
            2 * 10 ** 14
        );
        assertEq(
            referrerPointsBalanceAfterSwap -
                referrerPointsBalanceAfterAddLiquidity,
            2 * 10 ** 13
        );
    }
}
