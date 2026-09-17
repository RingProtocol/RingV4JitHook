# AGENTS.md

## Language

Use English for all source code, comments, documentation, tests, commit messages, pull request descriptions, and agent responses related to this repository.

## Project Overview

RingV4JitHook is a Foundry-based Solidity project implementing a singleton Uniswap v4 hook that backs multiple v4 pools with real per-order JIT LP sourced from configurable FewToken v4 backend pools. A single deployed hook instance registers every shell pool during `beforeInitialize` and serves all of them.

## Architecture

- Singleton hook instance serving any number of shell v4 pools. Each pool is registered in `_beforeInitialize`, recorded in `poolIds`, and mapped to its `PoolKey` via `poolKeys[poolId]`. Shell pools must use `fee == 0` with tick spacing in `(0, 200]`. Ordinary LP positions must be full-range (`_beforeAddLiquidity` enforces `tickLower == minUsableTick` and `tickUpper == maxUsableTick`).
- Backend is a hookless, static-fee ERC20 FewToken v4 pool registered per shell pool via `setLpPool` (owner-gated). The referenced shell pool must already be registered by `_beforeInitialize`.
- `syncPrice` is a caller-funded trade against permanent liquidity, not an oracle update.
- V4 backend registration is explicit, uses the same PoolManager, and accepts only hookless, static-fee ERC20 FewToken pools.
- Wrapper ordering can differ from underlying-token ordering. Native currency and multihop backend routes are not supported.
- `FewV4Quoter` is a full-fill backend quote, not a general partial-fill preview. It uses the backend execution's extreme price limit, includes directional protocol fees, and rejects dust, incomplete fills, and swaps requiring more than 512 bitmap/tick steps.
- JIT planning is closed-form: `_quote` makes one backend quote for the full order, then `RingLPPlanner.planQuoted` solves the total liquidity so the shell fill's average price equals the quote's (`out/in == sqrtP0*sqrtP1/Q96^2`). The backend leg is an exact-output swap for the JIT position's share (`jitOut`), verified against a second quote (`jitCost`).
- The permanent LP and the JIT position split each fill proportionally at the same average price (the backend quote's average). By convexity, the backend cost of the JIT share never exceeds the position's collected input by more than the rounding cap; the difference (convexity surplus) accrues to `roundingReserve`.
- Per-pool state (`lpPools`, JIT active-swap state) is isolated by `PoolId`. Rounding reserves are currency-keyed. `JITLock` provides per-pool transient locks plus a global in-flight counter.
- Shell pools reject non-zero protocol and LP fees at swap time (`_requireZeroFees` in `_beforeSwap` and `_quote`).
- Hook permissions: `beforeInitialize`, `beforeAddLiquidity` (full-range enforcement), `beforeSwap`, `afterSwap`. `beforeRemoveLiquidity` is not enabled.

## Invariants

- Preserve exact 1:1 wrapper balance checks, zero backend currency deltas after settlement, and the eight-raw-unit per-currency hook rounding-loss cap. Positive residual deltas (convexity surplus) are taken into the reserve, not donated. This cap does not establish permanent-LP economic safety.
- A JIT plan is only valid on the hook-safe side of the backend quote: exact-input fills must produce `amountOut <= ringOut`, exact-output fills must cost `amountIn >= ringIn`, each within the eight-raw-unit cap. `_afterSwap` reverts unless the realized delta and end price match the plan exactly.

## Development Guidelines

- Follow the existing Solidity style and run `forge fmt` after Solidity changes.
- Do not edit vendored code under `lib/` unless explicitly requested.
- Keep the V2 implementation (`RingBackedLiqHook`) and the sibling `RingFallbackHook` repository unchanged unless explicitly requested.

## Verification

```bash
forge fmt --check
forge test -vv
```
