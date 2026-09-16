# RingV4JitHook

A Uniswap v4 hook that backs multiple v4 pools with real per-order JIT LP sourced from configurable FewToken v4 backend pools. A single deployed hook instance registers every outer pool during `beforeInitialize` and serves all of them.

## How it works

1. **Outer pools**: Any number of v4 pools initialized with `RingV4JitHook` as their hook. Each pool is registered in `_beforeInitialize`, recorded in `poolIds`, and mapped to its `PoolKey` via `poolKeys[poolId]`. Ordinary LP positions may use any range (full-range is not enforced).
2. **Backend pool**: An owner-registered hookless FewToken v4 pool per outer pool (`setLpPool` / `setLpPools`), providing real liquidity for JIT execution. The referenced outer pool must already be registered by `_beforeInitialize`.
3. **Swap flow**:
   - `beforeSwap`: Hook quotes the backend, wraps raw tokens to FewToken, executes a real v4 swap on the backend pool, unwraps back, then adds JIT liquidity to the outer v4 pool.
   - The outer v4 pool executes the user's swap against the JIT liquidity.
   - `afterSwap`: Hook removes the JIT position, donates bounded credits, settles rounding, and enforces a post-swap price-alignment check against the backend FewToken pool to block flash-loan manipulation.
4. **`syncPrice`**: A caller-funded trade against permanent liquidity (via `SYNC_SWAP` hookData), not an oracle update.
5. **Per-pool state**: `poolLive`, `lpPools`, rounding reserves (currency-keyed), and JIT active-swap state are all isolated per `PoolId`. `JITLock` provides per-pool transient locks plus a global in-flight counter.

## Build

```bash
forge build
```

## Test

```bash
forge test -vv
```

## Project structure

```
src/
  hooks/RingV4JitHook.sol   # Main hook + RingV4JitQuoter
  routers/RingLPRouter.sol         # Prefunded swap router
  libraries/
    RingLPPlanner.sol              # JIT LP planning math
    FewV4Quoter.sol                # Full-fill v4 backend quoter
    ActionConstants.sol
  base/
    DeltaResolver.sol
    ImmutableState.sol
  utils/BaseHook.sol
  interfaces/
    IImmutableState.sol
    external/IFewFactory.sol
    external/IFewWrappedToken.sol
  alf/
    types/JITLock.sol
    libraries/FeeLib.sol
test/
  RingV4JitHook.t.sol        # 34 tests
  TestHelpers.sol                  # Mocks: MockFewFactory, MockFewWrappedToken, HookMiner
```
