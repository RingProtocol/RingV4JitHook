# AGENTS.md

## Language

Use English for all source code, comments, documentation, tests, commit messages, pull request descriptions, and agent responses related to this repository.

## Project Overview

RingV4BackedLiqHook is a Foundry-based Solidity project implementing a Uniswap v4 hook that backs a single v4 pool with full-range permanent liquidity and real per-order JIT LP sourced from a configurable FewToken v4 backend pool.

## Architecture

- Single outer v4 pool with full-range permanent liquidity, ordinary v4 swap deltas, and a prefunded `RingLPRouter`.
- Backend is a hookless, static-fee ERC20 FewToken v4 pool registered via `setFbPool` / `setFbPools` (owner-gated).
- `syncPrice` is a caller-funded trade against permanent liquidity, not an oracle update.
- V4 backend registration is explicit, uses the same PoolManager, and accepts only hookless, static-fee ERC20 FewToken pools.
- Wrapper ordering can differ from underlying-token ordering. Native currency and multihop backend routes are not supported.
- `FewV4Quoter` is a full-fill backend quote, not a general partial-fill preview. It uses the backend execution's extreme price limit, includes directional protocol fees, and rejects dust, incomplete fills, and swaps requiring more than 512 bitmap/tick steps.

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
