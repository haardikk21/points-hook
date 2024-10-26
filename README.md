# First Hook

A really simple onchain "points program"

Assume we launch some memecoin - TOKEN

we set up a pool for ETH/TOKEN

1. We're gonna issue points for every time somebody buys TOKEN with ETH
2. We're gonna issue points everytime somebody adds liquidity to the pool

This is not production ready by ANY means. At the end of the workshop, we'll discuss some obvious flaws and how we can make it better.

### How many points to give out?

- For every swap, we will give out (20% of the value in ETH) as points

e.g. if somebody sells 1 ETH to buy "TOKEN", they will get 0.2 `POINTS`

- For add liquidity, we'll keep it 1:1 for ETH added

### How are these points represented?

- Separate ERC-20 token, call it `POINTS`, minting `POINTS` to people who do those above things

## Mechanism Design

(1) - issue points everytime somebody swaps to buy `TOKEN` for `ETH`

we will issue points proportional to amount of ETH being spent in the swap

HOW Much ETH is being spent in the swap
=> we only know this for sure AFTER the swap has happened

- afterSwap

(2) - issue points everytime somebody adds liquidity

- afterAddLiquidity

## BalanceDelta

Alice is doing a swap on some pool

```

function swap() {

    beforeSwap()

    // how much tokens does Alice get back?
        // BalanceDelta
    // are we possibly hitting her slippage limit?
    // how much fees is being charged for this swap?
    coreSwapLogic();

    afterSwap();
}

```

How many different "configurations" of swaps are possible in Uniswap?

"Direction of the swap" `zeroForOne`
In the case of ETH/TOKEN pool:

- sell ETH and buy TOKEN (zeroForOne)
- sell TOKEn and buy ETH (oneForZero)

"exact input vs. exact output" swaps

Sell ETH for TOKEN

exact input swap

- "Sell 1 ETH for TOKEN"
  - amount of token 0 to be swapped is specified upfront
  - amount of token 1 to get back is unknown until after the swap

exact output swap

- "Sell ??? ETH for 1000 TOKEN"
  - amount of token 0 to be swapped is unknown
  - amount of token 1 to get back is specified upfront

---

4 total possibilities:

- exact input zero for one
- exact input one for zero

- exact output zero for one
- exact output one for zero

---

BalanceDelta have a negative value??

"Technical Introduction"

whenever there is a balance change involved, all numbers in uniswap by convention are represented
from the perspective of the "User"

`amount0Delta` = -1 ether
=> User needs to send 1 ETH to Uniswap (user owes 1 ETH)

`amount1Delta` = 500 token
=> User is owed 500 tokens by Uniswap (Uniswap needs to send 500 tokens to the user)

---

BalanceDelta = (amount0Delta, amount1Delta)

Alice sells 1 ETH for TOKEN in our pool
after the swap is done

`BalanceDelta` = (-1 ETH, +500 TOKEN)

these two values individually represent changes in balances of token0 and token1 respectively

---

zeroForOne

- exact input (...)
  - we're exactly specifying how much input tokens to spend
  - `amountSpecified`
  - `amountSpecified < 0`
    => negative number = money leaving user's wallet
    => exact input swap
  - `amountSpecified > 0`
    => the amount we're specifying is in terms of money entering the user's wallet
    => exact OUTPUT swap
- exact output (we dont know this until afterSwap)
