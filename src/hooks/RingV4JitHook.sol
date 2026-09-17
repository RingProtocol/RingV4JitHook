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
import {RingV4JitQuoter} from "../quoters/RingV4JitQuoter.sol";
import {LpPool} from "../types/LpPool.sol";
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
///   5. `_beforeSwap` is invoked: it quotes the backend once for the full order, solves the
///      JIT liquidity in closed form so the shell fill matches the backend quote, executes
///      the backend leg for the JIT position's share (wrap ETH, swap, unwrap USDC), and adds
///      the JIT position.
///   6. The shell v4 swap executes through the JIT + permanent liquidity; the permanent LP
///      and the JIT position split the trade proportionally at the same average price, so
///      the user is filled at the backend quote and each position covers its own share.
///   7. `_afterSwap` removes the JIT position, validates the deltas, takes the convexity
///      surplus into `roundingReserve`, and covers any small rounding loss from the reserve
///      (capped at MAX_ROUNDING_LOSS per currency).
contract RingV4JitHook is BaseHook, DeltaResolver, Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    uint256 public constant MAX_ROUNDING_LOSS = 8;
    uint256 public constant MIN_RESERVE = 16;
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
    bool private _syncing;

    error InvalidPool();
    error InvalidRoute();
    error FullRangeLiquidityOnly();
    error ProtocolFeeNotSupported();
    error InsufficientRoundingReserve();
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
        p.beforeAddLiquidity = true;
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
    ///  Validates that the pool key meets the hook's requirements (hooks == this, fee == 0,
    ///  valid tick spacing, sorted ERC20 currencies with code). On success, records the
    ///  poolId in `poolIds`, stores the key in `poolKeys`. Reverts `InvalidPool` on validation
    ///  failure. Duplicate initialization is prevented by the PoolManager itself.
    function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4) {
        if (
            address(key.hooks) != address(this) || key.fee != 0 || key.tickSpacing <= 0 || key.tickSpacing > 200
                || key.currency0 >= key.currency1 || Currency.unwrap(key.currency0).code.length == 0
                || Currency.unwrap(key.currency1).code.length == 0
        ) revert InvalidPool();
        PoolId poolId = key.toId();
        poolKeys[poolId] = key;
        poolIds.push(poolId);
        emit PoolCreated(poolId);
        return IHooks.beforeInitialize.selector;
    }

    /// @notice Hook entry point before adding liquidity. Enforces full-range only.
    /// @dev
    ///  Shell-pool LP positions must span the full tick range so that the hook's JIT
    ///  mechanics can rely on permanent liquidity always being active. Reverts
    ///  `FullRangeLiquidityOnly` if the provided tick range is not full-range.
    function _beforeAddLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata params, bytes calldata)
        internal
        view
        override
        returns (bytes4)
    {
        _requireFullRange(key, params);
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @notice Hook entry point before the shell swap.
    /// @dev
    ///  Example: user swaps exact 1,000 USDC out, `zeroForOne = true`.
    ///   - Enters the JIT lock and rejects non-zero shell-pool fees.
    ///   - If `hookData == SYNC_SWAP`, this is a price-sync trade against permanent liquidity.
    ///   - Otherwise `_quote` is called: one backend quote plus a closed-form solve for the
    ///     JIT liquidity that makes the shell fill match the backend quote.
    ///   - The user's `sqrtPriceLimitX96` is checked against the planned end price.
    ///   - If a JIT plan exists, `_execute` runs the backend leg for the JIT share and
    ///     `modifyLiquidity` adds the JIT position so the shell swap clears at the quote.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _requirePool(key);
        PoolId poolId = key.toId();
        jitLockFor(poolId).enter();
        _requireZeroFees(poolId);
        if (hookData.length == 32 && abi.decode(hookData, (bytes32)) == SYNC_SWAP) {
            _route(poolId);
            _syncing = true;
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        (,, RingLPPlanner.Plan memory p) = _quote(key, params.zeroForOne, params.amountSpecified);
        if (params.zeroForOne ? params.sqrtPriceLimitX96 >= p.end : params.sqrtPriceLimitX96 <= p.end) {
            revert PriceLimitExceeded();
        }
        _requireDelta(key.currency0, 0); //hook关于currency0，pm和hook之间是没有相互欠债的
        _requireDelta(key.currency1, 0); //hook关于currency1，pm和hook之间是没有相互欠债的
        _balance0Before = key.currency0.balanceOfSelf(); //hook拥有的currency0的余额
        _balance1Before = key.currency1.balanceOfSelf(); //hook拥有的currency1的余额
        _active = p;
        if (p.liquidity != 0) {
            _execute(key, params.zeroForOne, p.jitIn, p.jitOut, p.jitCost, p.backendEnd);
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
    ///   - It resolves the hook's residual deltas: a positive residual is the JIT share's
    ///     convexity surplus (taken into `roundingReserve`); a negative residual is a
    ///     rounding loss, capped at `MAX_ROUNDING_LOSS` per currency and paid from reserve.
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
        // Residuals are the hook's share of the trade: a small negative is covered by the
        // rounding reserve (<= MAX_ROUNDING_LOSS), a positive is the convexity surplus
        // between the JIT share's price and the full quote's price, taken into reserve.
        _resolve(key.currency0);
        _resolve(key.currency1);
        uint256 loss0 = _chargeRounding(key.currency0, _balance0Before);
        uint256 loss1 = _chargeRounding(key.currency1, _balance1Before);
        if (poolManager.getLiquidity(poolId) == 0) revert UnexpectedLiquidity();
        delete _active;
        delete _balance0Before;
        delete _balance1Before;
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
    ///   - The function checks the shell pool is live and has funded rounding reserves.
    ///   - It fetches the current slot0 and permanent liquidity.
    ///   - It quotes the FewToken backend once for the full requested amount, then solves
    ///     the JIT liquidity in closed form so the shell fill matches the backend quote.
    ///   - If no JIT plan is expressible, it falls back to permanent liquidity and validates
    ///     the shell/backend spot deviation is within the allowed 500 bps band (plus fees).
    ///   - A JIT plan must also land the post-swap shell price inside that band; this is the
    ///     same check `_afterSwap` enforces, evaluated early so bad quotes revert cheaply.
    function _quote(PoolKey calldata key, bool forward, int256 specified)
        private
        view
        returns (uint256 ringIn, uint256 ringOut, RingLPPlanner.Plan memory p)
    {
        _requirePool(key);
        PoolId poolId = key.toId();
        _requireReserveFunding(key);
        _requireZeroFees(poolId);
        if (specified == 0 || specified == type(int256).min) revert UnexpectedFill();
        uint256 requested = SafeCast.toUint256(specified < 0 ? -specified : specified);
        if (requested > type(uint96).max) revert UnexpectedFill();
        LpPool memory lp = _route(poolId);
        uint128 baseLiquidity = poolManager.getLiquidity(poolId);
        if (baseLiquidity == 0) revert UnexpectedLiquidity();
        (uint160 start,,,) = poolManager.getSlot0(poolId);
        try _quoter.quote(lp.lpPoolKey, forward == lp.orderAligned, specified) returns (
            uint256 quotedIn, uint256 quotedOut, uint160
        ) {
            ringIn = quotedIn;
            ringOut = quotedOut;
            p = RingLPPlanner.planQuoted(
                start, baseLiquidity, ringIn, ringOut, specified, forward, key.tickSpacing, MAX_ROUNDING_LOSS
            );
            if (p.liquidity != 0) {
                // Quote the backend leg's exact-input cost for the JIT share; `_execute`
                // enforces an exact match so a stale backend cannot be financed silently.
                try _quoter.quote(lp.lpPoolKey, forward == lp.orderAligned, SafeCast.toInt256(p.jitOut)) returns (
                    uint256 jitCost, uint256 jitOut, uint160 backendEnd
                ) {
                    if (jitOut != p.jitOut || jitCost > p.jitIn + MAX_ROUNDING_LOSS) revert UnexpectedFill();
                    p.jitCost = jitCost;
                    p.backendEnd = backendEnd;
                } catch {
                    delete p;
                }
            }
        } catch {}
        if (p.liquidity == 0) {
            (p.end, p.amountIn, p.amountOut) =
                RingLPPlanner.simulate(start, baseLiquidity, specified, forward, key.tickSpacing);
            p.start = start;
            ringIn = 0;
            ringOut = 0;
        }
        (uint256 deviationBps, uint256 allowedBps) = _spotDeviationBps(p.end, forward, lp);
        if (deviationBps > allowedBps) revert QuoteDeviationExceeded();
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

    /// @notice Settles a small negative delta or takes a positive delta into the reserve.
    /// @dev A negative delta is a rounding loss: it must stay within MAX_ROUNDING_LOSS and is
    ///      paid from the hook's balance (accounted by `_chargeRounding`). A positive delta is
    ///      the JIT share's convexity surplus — the backend always charges the position less
    ///      than its proportional share of the full quote — and is taken to the hook so
    ///      `_chargeRounding` accrues it to `roundingReserve`.
    function _resolve(Currency currency) private {
        int256 delta = poolManager.currencyDelta(address(this), currency);
        if (delta < 0) {
            uint256 amount = SafeCast.toUint256(-delta);
            if (amount > MAX_ROUNDING_LOSS) revert RoundingLossExceeded();
            _settle(currency, address(this), amount);
        } else if (delta > 0) {
            _take(currency, address(this), SafeCast.toUint256(delta));
        }
        _requireDelta(currency, 0);
    }

    /// @notice Reconciles the balance change of `currency` against `roundingReserve`.
    /// @dev Example: before=1_000, after=997 -> loss=3, subtracted from the reserve; a gain
    ///      (rounding surplus taken by `_resolve`) is added to the reserve instead.
    function _chargeRounding(Currency currency, uint256 beforeBalance) private returns (uint256 loss) {
        uint256 afterBalance = currency.balanceOfSelf();
        if (afterBalance > beforeBalance) {
            roundingReserve[currency] += afterBalance - beforeBalance;
            return 0;
        }
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

    function _requireFullRange(PoolKey calldata key, ModifyLiquidityParams calldata params) private view {
        requireJITNotInProgress();
        _requirePool(key);
        if (
            params.tickLower != TickMath.minUsableTick(key.tickSpacing)
                || params.tickUpper != TickMath.maxUsableTick(key.tickSpacing)
        ) revert FullRangeLiquidityOnly();
    }

    function _requireZeroFees(PoolId poolId) private view {
        (,, uint24 protocolFee, uint24 lpFee) = poolManager.getSlot0(poolId);
        if (protocolFee != 0 || lpFee != 0) revert ProtocolFeeNotSupported();
    }

    function _requireReserveFunding(PoolKey calldata key) private view {
        if (roundingReserve[key.currency0] < MIN_RESERVE || roundingReserve[key.currency1] < MIN_RESERVE) {
            revert InsufficientRoundingReserve();
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

    /// @notice Performs the FewToken v4 backend swap covering the JIT position's share of
    /// the order, and unwraps the result.
    /// @dev
    ///  Example: user sells 1 ETH, the JIT position must contribute `jitOut` USDC.
    ///   1. Swap on the backend for exactly `jitOut` (exact output, extreme price limit).
    ///      Flash accounting lets the delta go negative before the input is wrapped.
    ///   2. Enforce the convexity bound: the backend's cost `actualIn` must not exceed the
    ///      JIT position's collected input `jitIn` (plus the rounding allowance), and must
    ///      equal the quote `jitCost` exactly so a stale backend cannot be financed silently.
    ///      The position cannot lose money because its share of the fill always costs less
    ///      than its proportional share of the full quote.
    ///   3. Take raw input from PoolManager, wrap into FewToken, settle the backend debt,
    ///      take the wrapped output, unwrap, and settle raw output to PoolManager.
    ///   4. Verify the backend pool state (price, fees, liquidity) is unchanged since the
    ///      backend swap, so a wrapper callback cannot mutate the pool mid-flight.
    ///   After this, the hook's PoolManager deltas are `-jitCost` input and `+jitOut`
    ///   output; the shell swap's JIT position settles them to zero in `_afterSwap`.
    function _execute(
        PoolKey calldata key,
        bool forward,
        uint256 jitIn,
        uint256 jitOut,
        uint256 jitCost,
        uint160 expectedEnd
    ) private {
        PoolId poolId = key.toId();
        LpPool memory lp = _route(poolId);
        bool lpForward = forward == lp.orderAligned;
        Currency input = forward ? key.currency0 : key.currency1;
        Currency output = forward ? key.currency1 : key.currency0;
        Currency fwInput = lpForward ? lp.lpPoolKey.currency0 : lp.lpPoolKey.currency1;
        Currency fwOutput = lpForward ? lp.lpPoolKey.currency1 : lp.lpPoolKey.currency0;
        _requireDelta(fwInput, 0);
        _requireDelta(fwOutput, 0);
        BalanceDelta delta = poolManager.swap(
            lp.lpPoolKey,
            SwapParams(
                lpForward,
                SafeCast.toInt256(jitOut),
                lpForward ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            ""
        );
        int128 actualIn = lpForward ? delta.amount0() : delta.amount1();
        int128 actualOut = lpForward ? delta.amount1() : delta.amount0();
        if (
            actualIn >= 0 || actualOut <= 0 || int256(actualOut) != SafeCast.toInt256(jitOut)
                || int256(actualIn) != -SafeCast.toInt256(jitCost) || jitCost > jitIn + MAX_ROUNDING_LOSS
        ) revert UnexpectedFill();
        uint256 needed = jitCost;
        PoolId lpId = lp.lpPoolKey.toId();
        (uint160 actualEnd, int24 actualTick, uint24 protocolFee, uint24 lpFee) = poolManager.getSlot0(lpId);
        if (actualEnd != expectedEnd) revert UnexpectedFill();
        uint128 backendLiquidity = poolManager.getLiquidity(lpId);
        uint256 rawInBefore = input.balanceOfSelf();
        uint256 rawOutBefore = output.balanceOfSelf();
        uint256 fwInBefore = fwInput.balanceOfSelf();
        uint256 fwOutBefore = fwOutput.balanceOfSelf();
        _take(input, address(this), needed);
        if (input.balanceOfSelf() != rawInBefore + needed) revert UnexpectedTokenDelta();
        IERC20(Currency.unwrap(input)).forceApprove(Currency.unwrap(fwInput), needed);
        uint256 minted = IFewWrappedToken(Currency.unwrap(fwInput)).wrap(needed);
        IERC20(Currency.unwrap(input)).forceApprove(Currency.unwrap(fwInput), 0);
        if (minted != needed || fwInput.balanceOfSelf() != fwInBefore + needed || input.balanceOfSelf() != rawInBefore)
        {
            revert UnexpectedTokenDelta();
        }
        _settle(fwInput, address(this), needed);
        _take(fwOutput, address(this), jitOut);
        if (fwInput.balanceOfSelf() != fwInBefore || fwOutput.balanceOfSelf() != fwOutBefore + jitOut) {
            revert UnexpectedTokenDelta();
        }
        uint256 redeemed = IFewWrappedToken(Currency.unwrap(fwOutput)).unwrap(jitOut);
        if (redeemed != jitOut || output.balanceOfSelf() != rawOutBefore + jitOut) revert UnexpectedTokenDelta();
        _settle(output, address(this), jitOut);
        if (
            input.balanceOfSelf() != rawInBefore || output.balanceOfSelf() != rawOutBefore
                || fwInput.balanceOfSelf() != fwInBefore || fwOutput.balanceOfSelf() != fwOutBefore
        ) revert UnexpectedTokenDelta();
        _requireDelta(fwInput, 0);
        _requireDelta(fwOutput, 0);
        _requireDelta(input, -SafeCast.toInt256(needed));
        _requireDelta(output, SafeCast.toInt256(jitOut));
        (uint160 postEnd, int24 postTick, uint24 postProtocolFee, uint24 postLpFee) = poolManager.getSlot0(lpId);
        if (
            postEnd != actualEnd || postTick != actualTick || postProtocolFee != protocolFee || postLpFee != lpFee
                || poolManager.getLiquidity(lpId) != backendLiquidity
        ) revert UnexpectedFill();
        _route(poolId);
    }
}
