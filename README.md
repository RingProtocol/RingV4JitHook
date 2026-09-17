# RingV4JitHook

A Uniswap v4 hook that backs multiple v4 pools with real per-order JIT LP sourced from configurable FewToken v4 backend pools. A single deployed hook instance registers every shell pool during `beforeInitialize` and serves all of them.

## How it works

1. **Shell pools**: Any number of v4 pools initialized with `RingV4JitHook` as their hook. Each pool is registered in `_beforeInitialize`, recorded in `poolIds`, and mapped to its `PoolKey` via `poolKeys[poolId]`. Shell pools must use `fee == 0`, and permanent LP positions must be full-range. They may hold negligible TVL — user swaps are filled at the backend price regardless of shell-pool depth.
2. **Backend pool**: An owner-registered hookless FewToken v4 pool per shell pool (`setLpPool`), providing real liquidity for JIT execution. The referenced shell pool must already be registered by `_beforeInitialize`.
3. **Swap flow**:
   - `beforeSwap`: The hook quotes the backend once for the full order, solves the JIT liquidity in closed form (`RingLPPlanner.planQuoted`) so the shell fill's average price equals the backend quote, then executes the backend leg — an exact-output swap covering only the JIT position's share (`jitOut`), paid by wrapping the collected input share and settling FewToken — and adds the JIT position.
   - The shell v4 swap executes against permanent + JIT liquidity; both split the fill proportionally at the same average price, so the user receives the backend quote and the JIT position only ever funds its own share.
   - `afterSwap`: Hook removes the JIT position, verifies the realized delta and end price match the plan exactly, enforces the post-swap price-alignment check against the backend FewToken pool, takes the convexity surplus into the rounding reserve, and covers rounding losses up to `MAX_ROUNDING_LOSS` per currency.
4. **`syncPrice`**: A caller-funded trade against permanent liquidity (via `SYNC_SWAP` hookData), not an oracle update.
5. **Per-pool state**: `lpPools`, rounding reserves (currency-keyed), and JIT active-swap state are all isolated per `PoolId`. `JITLock` provides per-pool transient locks plus a global in-flight counter.

## Build

```bash
forge build
```

## Test

```bash
forge test -vv
```
