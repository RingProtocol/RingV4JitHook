# RingV4BackedLiqHook

A Uniswap v4 hook that backs a single v4 pool with full-range permanent liquidity and real per-order JIT LP sourced from a configurable FewToken v4 backend pool.

## How it works

1. **Outer pool**: A single v4 pool with full-range permanent base liquidity, hooked to `RingV4BackedLiqHook`.
2. **Backend pool**: An owner-registered hookless FewToken v4 pool (`setFbPool` / `setFbPools`), providing real liquidity for JIT execution.
3. **Swap flow**:
   - `beforeSwap`: Hook quotes the backend, wraps raw tokens to FewToken, executes a real v4 swap on the backend pool, unwraps back, then adds JIT liquidity to the outer v4 pool.
   - The outer v4 pool executes the user's swap against the JIT liquidity.
   - `afterSwap`: Hook removes the JIT position, donates bounded credits, and settles rounding.
4. **`syncPrice`**: A caller-funded trade against permanent liquidity (via `SYNC_SWAP` hookData), not an oracle update.

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
  hooks/RingV4BackedLiqHook.sol   # Main hook + RingV4BackedLiqQuoter
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
  RingV4BackedLiqHook.t.sol        # 34 tests
  TestHelpers.sol                  # Mocks: MockFewFactory, MockFewWrappedToken, HookMiner
```
