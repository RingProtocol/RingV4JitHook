# AGENTS.md

## Language

Use English for all source code, comments, documentation, tests, commit messages, pull request descriptions, and agent responses related to this repository.

## Project Overview

RingV4JitHook is a Foundry-based Solidity project implementing a singleton Uniswap v4 hook that backs multiple v4 pools with real per-order JIT LP sourced from configurable FewToken v4 backend pools. A single deployed hook instance registers every shell pool during `beforeInitialize` and serves all of them.

## Architecture

- Singleton hook instance serving any number of shell v4 pools. Each pool is registered in `_beforeInitialize`, recorded in `poolIds`, and mapped to its `PoolKey` via `poolKeys[poolId]`. Ordinary LP positions may use any range (full-range is not enforced).
- Backend is a hookless, static-fee ERC20 FewToken v4 pool registered per shell pool via `setLpPool` (owner-gated). The referenced shell pool must already be registered by `_beforeInitialize`.
- `syncPrice` is a caller-funded trade against permanent liquidity, not an oracle update.
- V4 backend registration is explicit, uses the same PoolManager, and accepts only hookless, static-fee ERC20 FewToken pools.
- Wrapper ordering can differ from underlying-token ordering. Native currency and multihop backend routes are not supported.
- `FewV4Quoter` is a full-fill backend quote, not a general partial-fill preview. It uses the backend execution's extreme price limit, includes directional protocol fees, and rejects dust, incomplete fills, and swaps requiring more than 512 bitmap/tick steps.
- Per-pool state (`poolLive`, `lpPools`, JIT active-swap state) is isolated by `PoolId`. Rounding reserves are currency-keyed. `JITLock` provides per-pool transient locks plus a global in-flight counter.
- Hook permissions: `beforeInitialize`, `beforeAddLiquidity` (no-op validation), `beforeSwap`, `afterSwap`. `beforeRemoveLiquidity` is not enabled.

## Invariants

- Preserve exact 1:1 wrapper balance checks, zero backend currency deltas after settlement, and the eight-raw-unit per-currency hook rounding-loss cap. This cap does not establish permanent-LP economic safety.

## Development Guidelines

- Follow the existing Solidity style and run `forge fmt` after Solidity changes.
- Do not edit vendored code under `lib/` unless explicitly requested.
- Keep the V2 implementation (`RingBackedLiqHook`) and the sibling `RingFallbackHook` repository unchanged unless explicitly requested.

## Verification

```bash
forge fmt --check
forge test -vv
```
