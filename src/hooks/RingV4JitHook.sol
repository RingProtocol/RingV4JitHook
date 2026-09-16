// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {BaseHook} from "../utils/BaseHook.sol";
import {DeltaResolver} from "../base/DeltaResolver.sol";
import {RingLPPlanner} from "../libraries/RingLPPlanner.sol";
import {FewV4Quoter} from "../libraries/FewV4Quoter.sol";
import {IFewFactory} from "../interfaces/external/IFewFactory.sol";
import {IFewWrappedToken} from "../interfaces/external/IFewWrappedToken.sol";
import {jitLockFor, requireJITNotInProgress} from "../alf/types/JITLock.sol";

/// @title RingV4JitHook
/// @notice JIT-backed Uniswap v4 hook that sources real FewToken v4 liquidity for each swap.
/// @dev
///  Example lifecycle for a user selling 0.5 ETH (currency0) to buy 1,000 USDC (currency1):
///   1. Anyone initializes an shell pool with ETH/USDC as currency0/currency1 via `poolManager.initialize`.
///      The hook's `_beforeInitialize` validates and records the pool.
///   2. Owner sets a backend FewToken v4 pool with fwETH/fwUSDC whose raw tokens are ETH/USDC.
///   3. Owner adds liquidity to the shell pool.
///   4. A user calls `poolManager.swap` on the shell pool with `amountSpecified = -1_000e6`
///      (exact output of 1,000 USDC) and `zeroForOne = true`.
///   5. `_beforeSwap` is invoked: it quotes the backend, finds the JIT liquidity that makes
///      the shell-pool cost match the backend quote, adds that JIT position, and prefunds the
///      1,000 USDC by wrapping ETH, swapping on the backend, and unwrapping the USDC.
///   6. The shell v4 swap executes through the JIT + permanent liquidity, consuming ~0.5 ETH
///      and producing ~1,000 USDC in PoolManager deltas.
///   7. `_afterSwap` removes the JIT position, validates the deltas, and resolves any small
///      rounding remainder using `roundingReserve` (capped at MAX_ROUNDING_LOSS per currency).
contract RingV4JitHook is BaseHook, DeltaResolver, Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    uint256 public constant MAX_ROUNDING_LOSS = 8;
    uint256 public constant MIN_BUFFER = 16;
    uint256 public constant MAX_SPOT_DEVIATION_BPS = 500;
    bytes32 public constant SYNC_SWAP = keccak256("RingV4JitHook.sync");
    bytes32 private constant LP_SALT = keccak256("RingV4JitHook.position");
    IFewFactory public immutable fewFactory;
    RingV4JitQuoter private immutable _quoter;
    address public immutable factory;

    /// @notice Array of all registered shell-pool IDs.
    PoolId[] public poolIds;
    /// @notice Maps a registered shell-pool ID to its PoolKey.
    mapping(PoolId => PoolKey) public poolKeys;
    /// @notice Per-pool backend FewToken v4 pool configuration.
    mapping(PoolId => LpPool) public lpPools;
    mapping(Currency => uint256) public roundingReserve;
    RingLPPlanner.Plan private _active;
    uint256 private _balance0Before;
    uint256 private _balance1Before;
    uint256 private _activeDonationLimit;
    bool private _syncing;

    struct LpPool {
        PoolKey lpPoolKey;
        bool orderAligned;
        bool set;
    }

    error InvalidPool();
    error InvalidRoute();
    error InsufficientRoundingBuffer();
    error UnexpectedTokenDelta();
    error UnexpectedFill();
    error PriceLimitExceeded();
    error UnexpectedLiquidity();
    error RoundingLossExceeded();
    error QuoteDeviationExceeded();
    error InvalidRecipient();
    error RenounceOwnershipDisabled();

    event PoolCreated(PoolId indexed poolId);
    event RoundingFunded(Currency indexed currency, uint256 amount);
    event LpPoolSet(PoolId indexed curPoolId, PoolKey lpPoolKey);
    event LpPoolRemoved(PoolId indexed curPoolId);
    event RingJitSwap(
        PoolId indexed poolId, bool zeroForOne, uint256 amountIn, uint256 amountOut, uint256 loss0, uint256 loss1
    );
    event PriceSyncSwap(PoolId indexed poolId, bool zeroForOne, uint256 amountIn, uint256 amountOut);

    constructor(IPoolManager manager, IFewFactory few, address owner_) BaseHook(manager) Ownable(owner_) {
        if (address(manager) == address(0) || address(few) == address(0)) revert InvalidPool();
        fewFactory = few;
        _quoter = new RingV4JitQuoter(manager);
        factory = msg.sender;
    }

    modifier idle() {
        requireJITNotInProgress();
        _;
    }

    function renounceOwnership() public pure override {
        revert RenounceOwnershipDisabled();
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
    }

    function poolCount() external view returns (uint256) {
        return poolIds.length;
    }

    function setLpPool(PoolKey calldata curPoolKey, PoolKey calldata lpPoolKey) external onlyOwner idle nonReentrant {
        _setLpPool(curPoolKey, lpPoolKey);
    }

    function getLpPool(PoolKey calldata key) external view returns (LpPool memory) {
        return lpPools[key.toId()];
    }

    function _setLpPool(PoolKey calldata curPoolKey, PoolKey calldata lpPoolKey) private {
        _requirePool(curPoolKey);
        PoolId curPoolId = curPoolKey.toId();
        if (lpPoolKey.currency0.isAddressZero()) {
            delete lpPools[curPoolId];
            emit LpPoolRemoved(curPoolId);
            return;
        }
        bool aligned = _validateLpPool(curPoolKey, lpPoolKey);
        lpPools[curPoolId] = LpPool(lpPoolKey, aligned, true);
        emit LpPoolSet(curPoolId, lpPoolKey);
    }

    function fundRounding(Currency currency, uint256 amount) external onlyOwner idle nonReentrant {
        uint256 beforeBalance = currency.balanceOfSelf();
        IERC20(Currency.unwrap(currency)).safeTransferFrom(msg.sender, address(this), amount);
        if (currency.balanceOfSelf() != beforeBalance + amount) revert UnexpectedTokenDelta();
        roundingReserve[currency] += amount;
        emit RoundingFunded(currency, amount);
    }

    function withdrawRounding(Currency currency, uint256 amount, address to) external onlyOwner idle nonReentrant {
        if (to == address(0)) revert InvalidRecipient();
        roundingReserve[currency] -= amount;
        currency.transfer(to, amount);
    }

    function getSpotDeviationBps(PoolKey calldata key, bool forward)
        external
        view
        idle
        returns (uint256 deviationBps, uint256 allowedBps)
    {
        _requirePool(key);
        PoolId poolId = key.toId();
        LpPool memory lp = _route(poolId);
        if (poolManager.getLiquidity(poolId) == 0) revert UnexpectedLiquidity();
        (uint160 start,,,) = poolManager.getSlot0(poolId);
        return _spotDeviationBps(start, forward, lp);
    }

    /// @notice Hook entry point before pool initialization. Validates and registers the pool.
    /// @dev
    ///  Validates that the pool key meets the hook's requirements (hooks == this,
    ///  sorted currencies with code). On success, records the poolId in `poolIds`,
    ///  stores the key in `poolKeys`. Reverts `InvalidPool` on validation failure.
    ///  Duplicate initialization is prevented by the PoolManager itself.
    function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4) {
        if (
            address(key.hooks) != address(this) || key.currency0 >= key.currency1
                || Currency.unwrap(key.currency0).code.length == 0 || Currency.unwrap(key.currency1).code.length == 0
        ) revert InvalidPool();
        PoolId poolId = key.toId();
        poolKeys[poolId] = key;
        poolIds.push(poolId);
        emit PoolCreated(poolId);
        return IHooks.beforeInitialize.selector;
    }

    /// @notice Hook entry point before the shell swap.
    /// @dev
    ///  Example: user swaps exact 1,000 USDC out, `zeroForOne = true`.
    ///   - Enters the JIT lock and rejects non-zero shell-pool fees.
    ///   - If `hookData == SYNC_SWAP`, this is a price-sync trade against permanent liquidity.
    ///   - Otherwise `_quote` is called to get the plan (ringIn/ringOut/JIT liquidity).
    ///   - The user's `sqrtPriceLimitX96` is checked against the planned end price.
    ///   - If a JIT plan exists, `_execute` prefunds the output and `modifyLiquidity` adds
    ///     the JIT position so the shell swap can clear at the quoted price.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _requirePool(key);
        PoolId poolId = key.toId();
        jitLockFor(poolId).enter();
        if (hookData.length == 32 && abi.decode(hookData, (bytes32)) == SYNC_SWAP) {
            _route(poolId);
            _syncing = true;
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        (uint256 ringIn, uint256 ringOut, RingLPPlanner.Plan memory p) =
            _quote(key, params.zeroForOne, params.amountSpecified);
        if (params.zeroForOne ? params.sqrtPriceLimitX96 >= p.end : params.sqrtPriceLimitX96 <= p.end) {
            revert PriceLimitExceeded();
        }
        _requireDelta(key.currency0, 0);
        _requireDelta(key.currency1, 0);
        _balance0Before = key.currency0.balanceOfSelf();
        _balance1Before = key.currency1.balanceOfSelf();
        _active = p;
        _activeDonationLimit =
            p.liquidity == 0 ? MAX_ROUNDING_LOSS : _inputQuantum(_route(poolId), params.zeroForOne, ringOut);
        if (p.liquidity != 0) {
            _execute(key, params.zeroForOne, ringIn, ringOut);
            poolManager.modifyLiquidity(
                key, ModifyLiquidityParams(p.lower, p.upper, int256(uint256(p.liquidity)), LP_SALT), ""
            );
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice Hook exit point after the shell swap has executed.
    /// @dev
    ///  Example: user received 1,000 USDC and paid 0.5 ETH.
    ///   - For a SYNC_SWAP it only verifies direction and emits `PriceSyncSwap`.
    ///   - For a normal swap it verifies `delta` matches `_active` (input = -p.amountIn,
    ///     output = p.amountOut, end price = p.end).
    ///   - It enforces a post-swap price limit: the shell pool's end price must stay within
    ///     `MAX_SPOT_DEVIATION_BPS` (plus the backend fee buffer) of the backend FewToken
    ///     pool price, reverting `PriceLimitExceeded` otherwise. This blocks flash-loan
    ///     manipulation that would push the shell price away from the backed reference.
    ///   - It removes the JIT position if one was added.
    ///   - It donates small positive deltas to the pool (rewards) and resolves the remaining
    ///     rounding with `roundingReserve`.
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        _requirePool(key);
        PoolId poolId = key.toId();
        if (_syncing) {
            int128 syncInput = params.zeroForOne ? delta.amount0() : delta.amount1();
            int128 syncOutput = params.zeroForOne ? delta.amount1() : delta.amount0();
            if (syncInput >= 0 || syncOutput <= 0) revert UnexpectedFill();
            delete _syncing;
            jitLockFor(poolId).clear();
            emit PriceSyncSwap(
                poolId,
                params.zeroForOne,
                SafeCast.toUint256(-int256(syncInput)),
                SafeCast.toUint256(int256(syncOutput))
            );
            return (IHooks.afterSwap.selector, 0);
        }
        RingLPPlanner.Plan memory p = _active;
        if (p.start == 0) revert UnexpectedFill();
        int128 input = params.zeroForOne ? delta.amount0() : delta.amount1();
        int128 output = params.zeroForOne ? delta.amount1() : delta.amount0();
        if (int256(input) != -SafeCast.toInt256(p.amountIn) || int256(output) != SafeCast.toInt256(p.amountOut)) {
            revert UnexpectedFill();
        }
        (uint160 end,,,) = poolManager.getSlot0(poolId);
        if (end != p.end) revert UnexpectedFill();
        // Post-swap price limit: keep the shell pool price aligned with the backend
        // FewToken pool so a flash-loan cannot push it away from the backed reference.
        LpPool memory lp = _route(poolId);
        (uint256 deviationBps, uint256 allowedBps) = _spotDeviationBps(end, params.zeroForOne, lp);
        if (deviationBps > allowedBps) revert PriceLimitExceeded();
        if (p.liquidity != 0) {
            poolManager.modifyLiquidity(
                key, ModifyLiquidityParams(p.lower, p.upper, -int256(uint256(p.liquidity)), LP_SALT), ""
            );
        }
        _donateCreditsThenResolve(key, params.zeroForOne);
        uint256 loss0 = _chargeRounding(key.currency0, _balance0Before);
        uint256 loss1 = _chargeRounding(key.currency1, _balance1Before);
        if (poolManager.getLiquidity(poolId) == 0) revert UnexpectedLiquidity();
        delete _active;
        delete _balance0Before;
        delete _balance1Before;
        delete _activeDonationLimit;
        jitLockFor(poolId).clear();
        emit RingJitSwap(poolId, params.zeroForOne, p.amountIn, p.amountOut, loss0, loss1);
        return (IHooks.afterSwap.selector, 0);
    }

    function quote(PoolKey calldata key, bool zeroForOne, int256 amountSpecified)
        external
        view
        idle
        returns (uint256 ringIn, uint256 ringOut, RingLPPlanner.Plan memory p)
    {
        return _quote(key, zeroForOne, amountSpecified);
    }

    function getIndicativeQuote(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, bytes calldata)
        external
        view
        returns (uint256)
    {
        try this.quote(key, zeroForOne, amountSpecified) returns (uint256, uint256, RingLPPlanner.Plan memory p) {
            return amountSpecified < 0 ? p.amountOut : p.amountIn;
        } catch {
            return 0;
        }
    }

    /// @notice Computes the quoted input/output and the JIT plan for a requested swap.
    /// @dev
    ///  Example: `zeroForOne = true`, `amountSpecified = -1_000e6` (exact 1,000 USDC out).
    ///   - The function checks the shell pool is live and has rounding buffers.
    ///   - It fetches the current slot0 and permanent liquidity.
    ///   - It searches `_findHybridPlan` for the smallest JIT liquidity that makes the shell
    ///     pool's required ETH input equal to the FewV4 backend's ETH input for 1,000 USDC.
    ///   - If no JIT is needed, it validates the shell/inner price deviation is within the
    ///     allowed 500 bps band (plus fees).
    function _quote(PoolKey calldata key, bool forward, int256 specified)
        private
        view
        returns (uint256 ringIn, uint256 ringOut, RingLPPlanner.Plan memory p)
    {
        _requirePool(key);
        PoolId poolId = key.toId();
        _requireBuffers(key);
        if (specified == 0 || specified == type(int256).min) revert UnexpectedFill();
        uint256 requested = SafeCast.toUint256(specified < 0 ? -specified : specified);
        if (requested > type(uint96).max) revert UnexpectedFill();
        LpPool memory lp = _route(poolId);
        uint128 baseLiquidity = poolManager.getLiquidity(poolId);
        if (baseLiquidity == 0) revert UnexpectedLiquidity();
        (uint160 start,,,) = poolManager.getSlot0(poolId);
        (ringIn, ringOut, p) = _findHybridPlan(start, baseLiquidity, specified, forward, key.tickSpacing, lp);
        if (p.liquidity == 0) {
            (uint256 deviationBps, uint256 allowedBps) = _spotDeviationBps(start, forward, lp);
            if (deviationBps > allowedBps) revert QuoteDeviationExceeded();
        }
    }

    /// @notice Donates any hook credits up to the active limit, then resolves the remaining
    /// per-currency deltas.
    /// @dev
    ///  Example: after the swap the hook is owed 1e6 USDC (reward). If this is within the
    ///   active limit (for the output currency), it is donated to the LPs. Any small leftover
    ///   is then settled or taken in `_resolve`.
    function _donateCreditsThenResolve(PoolKey calldata key, bool zeroForOne) private {
        int256 d0 = poolManager.currencyDelta(address(this), key.currency0);
        int256 d1 = poolManager.currencyDelta(address(this), key.currency1);
        uint256 reward0 = d0 > 0 ? SafeCast.toUint256(d0) : 0;
        uint256 reward1 = d1 > 0 ? SafeCast.toUint256(d1) : 0;
        uint256 limit0 = zeroForOne ? _activeDonationLimit : MAX_ROUNDING_LOSS;
        uint256 limit1 = zeroForOne ? MAX_ROUNDING_LOSS : _activeDonationLimit;
        if (reward0 > limit0 || reward1 > limit1) revert RoundingLossExceeded();
        if (reward0 != 0 || reward1 != 0) poolManager.donate(key, reward0, reward1, "");
        _resolve(key.currency0);
        _resolve(key.currency1);
    }

    /// @notice Searches for a JIT liquidity amount such that the shell-pool swap cost matches
    /// the FewV4 backend swap cost.
    /// @dev
    ///  Example: baseLiquidity = 10_000, requested USDC out = 1_000, `forward = true`.
    ///   - It tries candidate JIT liquidities (base, 2x, 4x, ... up to 32 doublings) and runs
    ///     the backend quote to compare `ringIn` (backend ETH in) vs `jitIn` (shell ETH in).
    ///   - The difference `diff = ringIn - jitIn` tells us whether the backend is cheaper.
    ///   - It keeps the candidate with |diff| closest to zero, then narrows with binary search.
    ///   - If a "surplus" candidate (`diff <= 0`) fits within one backend-input quantum, it is
    ///     preferred; otherwise the function falls back to pure permanent liquidity (no JIT).
    function _findHybridPlan(
        uint160 start,
        uint128 baseLiquidity,
        int256 specified,
        bool forward,
        int24 spacing,
        LpPool memory lp
    ) private view returns (uint256 ringIn, uint256 ringOut, RingLPPlanner.Plan memory best) {
        uint256 maxJit = uint256(type(uint128).max) - baseLiquidity;
        uint256 candidate = uint256(baseLiquidity);
        int256 previousDiff;
        uint256 previousCandidate;
        uint256 bestDifference = type(uint256).max;
        uint256 surplusDifference = type(uint256).max;
        uint256 surplusRingIn;
        uint256 surplusRingOut;
        RingLPPlanner.Plan memory surplus;
        uint256 lower;
        uint256 upper;
        for (uint256 i; i < 32 && candidate <= maxJit; ++i) {
            try _quoter.hybridCandidate(
                start, baseLiquidity, SafeCast.toUint128(candidate), specified, forward, spacing, lp
            ) returns (
                uint256 ri, uint256 ro, RingLPPlanner.Plan memory p, int256 diff
            ) {
                uint256 difference = diff < 0 ? SafeCast.toUint256(-diff) : SafeCast.toUint256(diff);
                if (difference < bestDifference) {
                    (bestDifference, ringIn, ringOut, best) = (difference, ri, ro, p);
                }
                if (diff <= 0 && difference < surplusDifference) {
                    (surplusDifference, surplusRingIn, surplusRingOut, surplus) = (difference, ri, ro, p);
                }
                if (previousCandidate != 0 && (diff == 0 || (diff < 0) != (previousDiff < 0))) {
                    lower = previousCandidate;
                    upper = candidate;
                    break;
                }
                previousCandidate = candidate;
                previousDiff = diff;
            } catch {
                if (previousCandidate != 0) {
                    lower = previousCandidate;
                    upper = candidate;
                    break;
                }
            }
            if (candidate > maxJit / 2) break;
            candidate *= 2;
        }
        for (uint256 i; i < 64 && lower + 1 < upper; ++i) {
            uint256 middle = lower + (upper - lower) / 2;
            try _quoter.hybridCandidate(
                start, baseLiquidity, SafeCast.toUint128(middle), specified, forward, spacing, lp
            ) returns (
                uint256 ri, uint256 ro, RingLPPlanner.Plan memory p, int256 diff
            ) {
                uint256 difference = diff < 0 ? SafeCast.toUint256(-diff) : SafeCast.toUint256(diff);
                if (difference < bestDifference) {
                    (bestDifference, ringIn, ringOut, best) = (difference, ri, ro, p);
                }
                if (diff <= 0 && difference < surplusDifference) {
                    (surplusDifference, surplusRingIn, surplusRingOut, surplus) = (difference, ri, ro, p);
                }
                if ((diff < 0) == (previousDiff < 0)) {
                    lower = middle;
                    previousDiff = diff;
                } else {
                    upper = middle;
                }
            } catch {
                upper = middle;
            }
        }
        if (surplus.liquidity != 0 && surplusDifference <= _inputQuantum(lp, forward, surplusRingOut)) {
            (ringIn, ringOut, best) = (surplusRingIn, surplusRingOut, surplus);
        } else if (best.liquidity == 0 || bestDifference > MAX_ROUNDING_LOSS) {
            (best.end, best.amountIn, best.amountOut) =
                _quoter.simulate(start, baseLiquidity, specified, forward, spacing);
            best.start = start;
            best.liquidity = 0;
            ringIn = 0;
            ringOut = 0;
        }
    }

    /// @notice Returns the incremental backend input cost of one extra output unit plus
    /// the constant rounding allowance.
    /// @dev Example: backend needs 0.5004 ETH for 1_000 USDC and 0.5004005 for 1_001 USDC,
    ///  so the quantum is ~0.0000005 ETH + 8. It is used to accept a small surplus in
    ///  `_findHybridPlan`.
    function inputQuantum(LpPool calldata lp, bool forward, uint256 output) external view returns (uint256) {
        if (msg.sender != address(this)) revert InvalidPool();
        (uint256 current,,) = _quoter.quote(lp.lpPoolKey, forward == lp.orderAligned, SafeCast.toInt256(output));
        (uint256 next,,) = _quoter.quote(lp.lpPoolKey, forward == lp.orderAligned, SafeCast.toInt256(output + 1));
        return next - current + MAX_ROUNDING_LOSS;
    }

    function _inputQuantum(LpPool memory lp, bool forward, uint256 output) private view returns (uint256) {
        try this.inputQuantum(lp, forward, output) returns (uint256 quantum) {
            return quantum;
        } catch {
            return MAX_ROUNDING_LOSS;
        }
    }

    /// @notice Compares the shell pool price to the backend FewToken pool price.
    /// @dev
    ///  Example: if the shell price is 5% higher than the backend, the returned deviation
    ///   is roughly 500 bps; it must not exceed `allowedBps` (500 bps + fee buffer).
    function _spotDeviationBps(uint160 start, bool forward, LpPool memory lp)
        private
        view
        returns (uint256 deviationBps, uint256 allowedBps)
    {
        (uint160 backend,, uint24 protocolFee, uint24 lpFee) = poolManager.getSlot0(lp.lpPoolKey.toId());
        bool lpForward = forward == lp.orderAligned;
        uint16 directionalFee = lpForward
            ? ProtocolFeeLibrary.getZeroForOneFee(protocolFee)
            : ProtocolFeeLibrary.getOneForZeroFee(protocolFee);
        uint24 fee = ProtocolFeeLibrary.calculateSwapFee(directionalFee, lpFee);
        if (fee >= 1_000_000) revert InvalidRoute();
        allowedBps = MAX_SPOT_DEVIATION_BPS + (uint256(fee) + 99) / 100;
        uint256 q96 = 1 << 96;
        uint256 sqrtRatio;
        if (lp.orderAligned) {
            sqrtRatio = forward ? FullMath.mulDiv(start, q96, backend) : FullMath.mulDiv(backend, q96, start);
        } else if (forward) {
            sqrtRatio = FullMath.mulDiv(start, backend, q96);
        } else {
            sqrtRatio = FullMath.mulDiv(FullMath.mulDiv(q96, q96, start), q96, backend);
        }
        if (sqrtRatio >= 4 * q96) return (type(uint256).max, allowedBps);
        uint256 ratio = FullMath.mulDiv(FullMath.mulDiv(sqrtRatio, sqrtRatio, q96), 1e18, q96);
        ratio = FullMath.mulDiv(ratio, 1_000_000, 1_000_000 - fee);
        uint256 difference = ratio > 1e18 ? ratio - 1e18 : 1e18 - ratio;
        deviationBps = FullMath.mulDivRoundingUp(difference, 10_000, 1e18);
    }

    /// @notice Settles a negative delta or takes a positive delta, capping the amount.
    /// @dev Example: if the hook owes 3 wei of currency0, it settles; if owed 2 wei, it takes.
    function _resolve(Currency currency) private {
        int256 delta = poolManager.currencyDelta(address(this), currency);
        uint256 amount = SafeCast.toUint256(delta < 0 ? -delta : delta);
        if (amount > MAX_ROUNDING_LOSS) revert RoundingLossExceeded();
        if (delta < 0) _settle(currency, address(this), amount);
        else if (delta > 0) _take(currency, address(this), amount);
        _requireDelta(currency, 0);
    }

    /// @notice Deducts the balance decrease of `currency` from `roundingReserve`.
    /// @dev Example: before=1_000, after=997 -> loss=3, which is subtracted from the reserve.
    function _chargeRounding(Currency currency, uint256 beforeBalance) private returns (uint256 loss) {
        uint256 afterBalance = currency.balanceOfSelf();
        if (afterBalance > beforeBalance) revert UnexpectedTokenDelta();
        loss = beforeBalance - afterBalance;
        if (loss > MAX_ROUNDING_LOSS) revert RoundingLossExceeded();
        roundingReserve[currency] -= loss;
    }

    function _pay(Currency currency, address, uint256 amount) internal override {
        currency.transfer(address(poolManager), amount);
    }

    function _requirePool(PoolKey calldata key) private view {
        if (poolKeys[key.toId()].currency0.isAddressZero()) revert InvalidPool();
    }

    function _requireBuffers(PoolKey calldata key) private view {
        if (roundingReserve[key.currency0] < MIN_BUFFER || roundingReserve[key.currency1] < MIN_BUFFER) {
            revert InsufficientRoundingBuffer();
        }
    }

    function _route(PoolId poolId) private view returns (LpPool memory lp) {
        lp = lpPools[poolId];
        if (!lp.set || _validateLpPool(poolKeys[poolId], lp.lpPoolKey) != lp.orderAligned) revert InvalidRoute();
    }

    function _validateLpPool(PoolKey memory curKey, PoolKey memory lpKey) private view returns (bool aligned) {
        if (
            address(lpKey.hooks) != address(0) || lpKey.fee >= 1_000_000
                || lpKey.tickSpacing < TickMath.MIN_TICK_SPACING || lpKey.tickSpacing > TickMath.MAX_TICK_SPACING
                || lpKey.currency0.isAddressZero() || lpKey.currency0 >= lpKey.currency1
                || lpKey.currency0 == curKey.currency0 || lpKey.currency0 == curKey.currency1
                || lpKey.currency1 == curKey.currency0 || lpKey.currency1 == curKey.currency1
        ) revert InvalidRoute();
        address fw0 = Currency.unwrap(lpKey.currency0);
        address fw1 = Currency.unwrap(lpKey.currency1);
        if (fw0.code.length == 0 || fw1.code.length == 0) revert InvalidRoute();
        address raw0 = IFewWrappedToken(fw0).token();
        address raw1 = IFewWrappedToken(fw1).token();
        if (raw0 == Currency.unwrap(curKey.currency0) && raw1 == Currency.unwrap(curKey.currency1)) {
            aligned = true;
        } else if (raw0 != Currency.unwrap(curKey.currency1) || raw1 != Currency.unwrap(curKey.currency0)) {
            revert InvalidRoute();
        }
        if (fewFactory.getWrappedToken(raw0) != fw0 || fewFactory.getWrappedToken(raw1) != fw1) revert InvalidRoute();
        (uint160 price,,, uint24 lpFee) = poolManager.getSlot0(lpKey.toId());
        if (price == 0 || lpFee != lpKey.fee) revert InvalidRoute();
    }

    function _requireDelta(Currency currency, int256 expected) private view {
        if (poolManager.currencyDelta(address(this), currency) != expected) revert UnexpectedTokenDelta();
    }

    /// @notice Performs the actual FewToken v4 backend swap and unwraps the result.
    /// @dev
    ///  Example: user sells ETH for USDC, `ringIn = 0.5e18`, `ringOut = 1_000e6`.
    ///   1. Re-quote the backend for exactly `ringOut` USDC to obtain `ringIn` ETH.
    ///   2. Take raw ETH from PoolManager, wrap into fwETH, and approve it.
    ///   3. Swap on the backend (exact output) to receive `ringOut` fwUSDC.
    ///   4. Unwrap fwUSDC into raw USDC and settle it to PoolManager.
    ///   5. After this, the hook's PoolManager deltas are `-ringIn` input and `+ringOut`
    ///      output, matching the user-facing shell swap.
    function _execute(PoolKey calldata key, bool forward, uint256 ringIn, uint256 ringOut) private {
        PoolId poolId = key.toId();
        LpPool memory lp = _route(poolId);
        bool lpForward = forward == lp.orderAligned;
        (uint256 quotedIn, uint256 quotedOut, uint160 expectedEnd) =
            _quoter.quote(lp.lpPoolKey, lpForward, SafeCast.toInt256(ringOut));
        if (quotedIn != ringIn || quotedOut != ringOut) revert UnexpectedFill();
        Currency input = forward ? key.currency0 : key.currency1;
        Currency output = forward ? key.currency1 : key.currency0;
        Currency fwInput = lpForward ? lp.lpPoolKey.currency0 : lp.lpPoolKey.currency1;
        Currency fwOutput = lpForward ? lp.lpPoolKey.currency1 : lp.lpPoolKey.currency0;
        _requireDelta(fwInput, 0);
        _requireDelta(fwOutput, 0);
        uint256 rawInBefore = input.balanceOfSelf();
        uint256 rawOutBefore = output.balanceOfSelf();
        uint256 fwInBefore = fwInput.balanceOfSelf();
        uint256 fwOutBefore = fwOutput.balanceOfSelf();
        _take(input, address(this), ringIn);
        if (input.balanceOfSelf() != rawInBefore + ringIn) revert UnexpectedTokenDelta();
        IERC20(Currency.unwrap(input)).forceApprove(Currency.unwrap(fwInput), ringIn);
        uint256 minted = IFewWrappedToken(Currency.unwrap(fwInput)).wrap(ringIn);
        IERC20(Currency.unwrap(input)).forceApprove(Currency.unwrap(fwInput), 0);
        if (minted != ringIn || fwInput.balanceOfSelf() != fwInBefore + ringIn || input.balanceOfSelf() != rawInBefore)
        {
            revert UnexpectedTokenDelta();
        }
        BalanceDelta delta = poolManager.swap(
            lp.lpPoolKey,
            SwapParams(
                lpForward,
                SafeCast.toInt256(ringOut),
                lpForward ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            ""
        );
        int128 actualIn = lpForward ? delta.amount0() : delta.amount1();
        int128 actualOut = lpForward ? delta.amount1() : delta.amount0();
        if (
            actualIn >= 0 || actualOut <= 0 || int256(actualIn) != -SafeCast.toInt256(ringIn)
                || int256(actualOut) != SafeCast.toInt256(ringOut)
        ) revert UnexpectedFill();
        _requireDelta(fwInput, -SafeCast.toInt256(ringIn));
        _requireDelta(fwOutput, SafeCast.toInt256(ringOut));
        _settle(fwInput, address(this), ringIn);
        _take(fwOutput, address(this), ringOut);
        if (fwInput.balanceOfSelf() != fwInBefore || fwOutput.balanceOfSelf() != fwOutBefore + ringOut) {
            revert UnexpectedTokenDelta();
        }
        uint256 redeemed = IFewWrappedToken(Currency.unwrap(fwOutput)).unwrap(ringOut);
        if (redeemed != ringOut || output.balanceOfSelf() != rawOutBefore + ringOut) revert UnexpectedTokenDelta();
        _settle(output, address(this), ringOut);
        if (
            input.balanceOfSelf() != rawInBefore || output.balanceOfSelf() != rawOutBefore
                || fwInput.balanceOfSelf() != fwInBefore || fwOutput.balanceOfSelf() != fwOutBefore
        ) revert UnexpectedTokenDelta();
        _requireDelta(fwInput, 0);
        _requireDelta(fwOutput, 0);
        _requireDelta(input, -SafeCast.toInt256(ringIn));
        _requireDelta(output, SafeCast.toInt256(ringOut));
        (uint160 actualEnd,,,) = poolManager.getSlot0(lp.lpPoolKey.toId());
        if (actualEnd != expectedEnd) revert UnexpectedFill();
        _route(poolId);
    }
}

contract RingV4JitQuoter {
    IPoolManager private immutable _manager;

    constructor(IPoolManager manager) {
        _manager = manager;
    }

    function hybridCandidate(
        uint160 start,
        uint128 baseLiquidity,
        uint128 jitLiquidity,
        int256 specified,
        bool forward,
        int24 spacing,
        RingV4JitHook.LpPool calldata lp
    ) external view returns (uint256 ringIn, uint256 ringOut, RingLPPlanner.Plan memory p, int256 difference) {
        uint256 jitIn;
        uint256 jitOut;
        (p, jitIn, jitOut) =
            RingLPPlanner.planAtCurrent(start, baseLiquidity, jitLiquidity, specified, forward, spacing);
        if (jitOut == 0 || jitOut > type(uint96).max) revert RingV4JitHook.UnexpectedFill();
        (ringIn, ringOut,) =
            FewV4Quoter.quote(_manager, lp.lpPoolKey, forward == lp.orderAligned, SafeCast.toInt256(jitOut));
        if (ringOut != jitOut || ringIn == 0 || ringIn > uint256(uint128(type(int128).max))) {
            revert RingV4JitHook.UnexpectedFill();
        }
        difference = SafeCast.toInt256(ringIn) - SafeCast.toInt256(jitIn);
    }

    function simulate(uint160 start, uint128 liquidity, int256 specified, bool forward, int24 spacing)
        external
        pure
        returns (uint160 end, uint256 amountIn, uint256 amountOut)
    {
        return RingLPPlanner.simulate(start, liquidity, specified, forward, spacing);
    }

    function quote(PoolKey memory key, bool zeroForOne, int256 amountSpecified)
        external
        view
        returns (uint256 amountIn, uint256 amountOut, uint160 sqrtPriceX96)
    {
        return FewV4Quoter.quote(_manager, key, zeroForOne, amountSpecified);
    }
}
