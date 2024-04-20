// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {PointsHook} from "../src/PointsHook.sol";
import {HookMiner} from "./utils/HookMiner.sol";

contract TestPointsHook is Test, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    MockERC20 token;

    Currency ethCurrency = Currency.wrap(address(0));
    Currency tokenCurrency;

    PointsHook hook;

    function setUp() public {
        deployFreshManagerAndRouters();

        token = new MockERC20("Test Token", "TEST", 18);
        tokenCurrency = Currency.wrap(address(token));

        token.mint(address(this), 1000 ether);
        token.mint(address(1), 1000 ether);

        uint160 flags = uint160(
            Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        (, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            0,
            type(PointsHook).creationCode,
            abi.encode(manager, "Points Token", "TEST_POINTS")
        );

        hook = new PointsHook{salt: salt}(
            manager,
            "Points Token",
            "TEST_POINTS"
        );

        token.approve(address(hook), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);

        (key, ) = initPool(
            ethCurrency,
            tokenCurrency,
            hook,
            3000,
            SQRT_RATIO_1_1,
            ZERO_BYTES
        );
    }

    function test_addLiquidityAndSwap() public {
        bytes memory hookData = hook.getHookData(address(0), address(this));

        /*
        currentTick = 0
        We are adding liquidity at tickLower = -60, tickUpper = 60

        SqrtPrice(i = 0) = 1.0001 ^ (0/2) = 1
        SqrtPrice(i = 60) = 1.0001 ^ (60 / 2) = 1.0001 ^ 30 = 1.000761
        SqrtPrice(i = -60) = 1.0001 ^ (-60 / 2) = 1.0001 ^ -30 = 0.999239

        1 as a Q64.96 number = 1 * 2^96 = 792281625142643375935439503
        1.000761 as a Q64.96 number = 1.000761 * 2^96 = 79288455145937692754452637282
        0.999239 as a Q64.96 number = 0.999239 * 2^96 = 79167869882590982432635263389

        New liquidity must not change the token price
        Δx = Δ (L/SqrtPrice) = ( L * (SqrtPrice_tick - SqrtPrice_currentTick) ) / (SqrtPrice_tick * SqrtPrice_currentTick)
        Δy = Δ (L * SqrtPrice) = L * (SqrtPrice_currentTick - SqrtPrice_tick)

        We have set liquidityDelta = +1 ether
        We want ΔL = 1 ether

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
        uint256 pointsBalanceOriginal = hook.balanceOf(address(this));
        modifyLiquidityRouter.modifyLiquidity{value: 0.003 ether}(
            key,
            IPoolManager.ModifyLiquidityParams(-60, 60, 1 ether),
            hookData
        );
        uint256 pointsBalanceAfterAddLiquidity = hook.balanceOf(address(this));
        assertApproxEqAbs(
            pointsBalanceAfterAddLiquidity - pointsBalanceOriginal,
            2995354955910434,
            0.00001 ether
        );

        // Now we swap
        // We will swap 0.001 ether for tokens
        // We should get 20% of 0.001 * 10**18 points
        // = 2 * 10**14
        swapRouter.swap{value: 0.001 ether}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -0.001 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1
            }),
            PoolSwapTest.TestSettings({
                withdrawTokens: true,
                settleUsingTransfer: true,
                currencyAlreadySent: false
            }),
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
            IPoolManager.ModifyLiquidityParams(-60, 60, 1 ether),
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
                sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1
            }),
            PoolSwapTest.TestSettings({
                withdrawTokens: true,
                settleUsingTransfer: true,
                currencyAlreadySent: false
            }),
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
