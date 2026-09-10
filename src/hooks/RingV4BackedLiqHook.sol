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

contract RingV4BackedLiqHook is BaseHook, DeltaResolver, Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    uint256 public constant MAX_ROUNDING_LOSS = 8;
    uint256 public constant MIN_BUFFER = 16;
    uint256 public constant MAX_SPOT_DEVIATION_BPS = 500;
    bytes32 public constant SYNC_SWAP = keccak256("RingBackedLiqHook.sync");
    bytes32 private constant LP_SALT = keccak256("RingV4BackedLiqHook.position");
    IFewFactory public immutable fewFactory;
    RingV4BackedLiqQuoter private immutable _quoter;
    address public immutable factory;
    bool public initialized;
    bool public live;
    PoolId public configuredPoolId;
    PoolKey private _key;
    mapping(PoolId => FbPool) public fbPools;
    mapping(Currency => uint256) public roundingReserve;
    RingLPPlanner.Plan private _active;
    uint256 private _balance0Before;
    uint256 private _balance1Before;
    uint256 private _activeDonationLimit;
    bool private _syncing;

    struct FbPool {
        PoolKey fbPoolKey;
        bool orderAligned;
        bool set;
    }

    error InvalidPool();
    error InvalidRoute();
    error PoolNotLive();
    error FullRangeLiquidityOnly();
    error ProtocolFeeNotSupported();
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
    event LiveSet(bool live);
    event RoundingFunded(Currency indexed currency, uint256 amount);
    event FbPoolSet(PoolId indexed curPoolId, PoolKey fbPoolKey);
    event FbPoolRemoved(PoolId indexed curPoolId);
    event RingBackedSwap(
        PoolId indexed poolId, bool zeroForOne, uint256 amountIn, uint256 amountOut, uint256 loss0, uint256 loss1
    );
    event PriceSyncSwap(PoolId indexed poolId, bool zeroForOne, uint256 amountIn, uint256 amountOut);

    constructor(IPoolManager manager, IFewFactory few, address owner_) BaseHook(manager) Ownable(owner_) {
        if (address(manager) == address(0) || address(few) == address(0)) revert InvalidPool();
        fewFactory = few;
        _quoter = new RingV4BackedLiqQuoter(manager);
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
        p.beforeRemoveLiquidity = true;
        p.beforeSwap = true;
        p.afterSwap = true;
    }

    function initializePool(PoolKey calldata key, uint160 initialSqrtPriceX96) external onlyOwner idle nonReentrant {
        if (
            initialized || address(key.hooks) != address(this) || key.fee != 0 || key.tickSpacing <= 0
                || key.tickSpacing > 200 || key.currency0.isAddressZero() || key.currency0 >= key.currency1
                || Currency.unwrap(key.currency0).code.length == 0 || Currency.unwrap(key.currency1).code.length == 0
        ) revert InvalidPool();
        initialized = true;
        configuredPoolId = key.toId();
        _key = key;
        poolManager.initialize(key, initialSqrtPriceX96);
        emit PoolCreated(configuredPoolId);
    }

    function setFbPool(PoolKey calldata curPoolKey, PoolKey calldata fbPoolKey) external onlyOwner idle nonReentrant {
        _setFbPool(curPoolKey, fbPoolKey);
    }

    function setFbPools(PoolKey[] calldata curPoolKeys, PoolKey[] calldata fbPoolKeys)
        external
        onlyOwner
        idle
        nonReentrant
    {
        if (curPoolKeys.length == 0 || curPoolKeys.length != fbPoolKeys.length) revert InvalidRoute();
        for (uint256 i; i < curPoolKeys.length; ++i) {
            _setFbPool(curPoolKeys[i], fbPoolKeys[i]);
        }
    }

    function getFbPool(PoolKey calldata key) external view returns (FbPool memory) {
        return fbPools[key.toId()];
    }

    function _setFbPool(PoolKey calldata curPoolKey, PoolKey calldata fbPoolKey) private {
        _requirePool(curPoolKey);
        if (fbPoolKey.currency0.isAddressZero()) {
            delete fbPools[configuredPoolId];
            emit FbPoolRemoved(configuredPoolId);
            return;
        }
        bool aligned = _validateFbPool(fbPoolKey);
        fbPools[configuredPoolId] = FbPool(fbPoolKey, aligned, true);
        emit FbPoolSet(configuredPoolId, fbPoolKey);
    }

    function fundRounding(Currency currency, uint256 amount) external onlyOwner idle nonReentrant {
        _requireCurrency(currency);
        uint256 beforeBalance = currency.balanceOfSelf();
        IERC20(Currency.unwrap(currency)).safeTransferFrom(msg.sender, address(this), amount);
        if (currency.balanceOfSelf() != beforeBalance + amount) revert UnexpectedTokenDelta();
        roundingReserve[currency] += amount;
        emit RoundingFunded(currency, amount);
    }

    function withdrawRounding(Currency currency, uint256 amount, address to) external onlyOwner idle nonReentrant {
        _requireCurrency(currency);
        if (to == address(0)) revert InvalidRecipient();
        roundingReserve[currency] -= amount;
        currency.transfer(to, amount);
    }

    function setPoolLive(bool enabled) external onlyOwner idle {
        if (!initialized) revert InvalidPool();
        if (enabled) {
            _route();
            _requireBuffers();
            _requireZeroFees();
            if (poolManager.getLiquidity(configuredPoolId) == 0) revert UnexpectedLiquidity();
        }
        live = enabled;
        emit LiveSet(enabled);
    }

    function getSpotDeviationBps(bool forward) external view idle returns (uint256 deviationBps, uint256 allowedBps) {
        if (!initialized) revert InvalidPool();
        FbPool memory fb = _route();
        if (poolManager.getLiquidity(configuredPoolId) == 0) revert UnexpectedLiquidity();
        (uint160 start,,,) = poolManager.getSlot0(configuredPoolId);
        return _spotDeviationBps(start, forward, fb);
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

    function _quote(PoolKey calldata key, bool forward, int256 specified)
        private
        view
        returns (uint256 ringIn, uint256 ringOut, RingLPPlanner.Plan memory p)
    {
        _requirePool(key);
        if (!live) revert PoolNotLive();
        _requireBuffers();
        if (specified == 0 || specified == type(int256).min) revert UnexpectedFill();
        uint256 requested = SafeCast.toUint256(specified < 0 ? -specified : specified);
        if (requested > type(uint96).max) revert UnexpectedFill();
        _requireZeroFees();
        FbPool memory fb = _route();
        uint128 baseLiquidity = poolManager.getLiquidity(configuredPoolId);
        if (baseLiquidity == 0) revert UnexpectedLiquidity();
        (uint160 start,,,) = poolManager.getSlot0(configuredPoolId);
        (ringIn, ringOut, p) = _findHybridPlan(start, baseLiquidity, specified, forward, key.tickSpacing, fb);
        if (p.liquidity == 0) {
            (uint256 deviationBps, uint256 allowedBps) = _spotDeviationBps(start, forward, fb);
            if (deviationBps > allowedBps) revert QuoteDeviationExceeded();
        }
    }

    function _beforeInitialize(address, PoolKey calldata, uint160) internal pure override returns (bytes4) {
        revert InvalidPool();
    }

    function _beforeAddLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata params, bytes calldata)
        internal
        view
        override
        returns (bytes4)
    {
        _requireFullRange(key, params);
        return IHooks.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal view override returns (bytes4) {
        _requireFullRange(key, params);
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _requirePool(key);
        jitLockFor(configuredPoolId).enter();
        _requireZeroFees();
        if (hookData.length == 32 && abi.decode(hookData, (bytes32)) == SYNC_SWAP) {
            if (!live) revert PoolNotLive();
            _route();
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
            p.liquidity == 0 ? MAX_ROUNDING_LOSS : _inputQuantum(_route(), params.zeroForOne, ringOut);
        if (p.liquidity != 0) {
            _execute(params.zeroForOne, ringIn, ringOut);
            poolManager.modifyLiquidity(
                key, ModifyLiquidityParams(p.lower, p.upper, int256(uint256(p.liquidity)), LP_SALT), ""
            );
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        _requirePool(key);
        if (_syncing) {
            int128 syncInput = params.zeroForOne ? delta.amount0() : delta.amount1();
            int128 syncOutput = params.zeroForOne ? delta.amount1() : delta.amount0();
            if (syncInput >= 0 || syncOutput <= 0) revert UnexpectedFill();
            delete _syncing;
            jitLockFor(configuredPoolId).clear();
            emit PriceSyncSwap(
                configuredPoolId,
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
        (uint160 end,,,) = poolManager.getSlot0(configuredPoolId);
        if (end != p.end) revert UnexpectedFill();
        if (p.liquidity != 0) {
            poolManager.modifyLiquidity(
                key, ModifyLiquidityParams(p.lower, p.upper, -int256(uint256(p.liquidity)), LP_SALT), ""
            );
        }
        _donateCreditsThenResolve(key, params.zeroForOne);
        uint256 loss0 = _chargeRounding(key.currency0, _balance0Before);
        uint256 loss1 = _chargeRounding(key.currency1, _balance1Before);
        if (poolManager.getLiquidity(configuredPoolId) == 0) revert UnexpectedLiquidity();
        delete _active;
        delete _balance0Before;
        delete _balance1Before;
        delete _activeDonationLimit;
        jitLockFor(configuredPoolId).clear();
        emit RingBackedSwap(configuredPoolId, params.zeroForOne, p.amountIn, p.amountOut, loss0, loss1);
        return (IHooks.afterSwap.selector, 0);
    }

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

    function _findHybridPlan(
        uint160 start,
        uint128 baseLiquidity,
        int256 specified,
        bool forward,
        int24 spacing,
        FbPool memory fb
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
                start, baseLiquidity, SafeCast.toUint128(candidate), specified, forward, spacing, fb
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
                start, baseLiquidity, SafeCast.toUint128(middle), specified, forward, spacing, fb
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
        if (surplus.liquidity != 0 && surplusDifference <= _inputQuantum(fb, forward, surplusRingOut)) {
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

    function inputQuantum(FbPool calldata fb, bool forward, uint256 output) external view returns (uint256) {
        if (msg.sender != address(this)) revert InvalidPool();
        (uint256 current,,) = _quoter.quote(fb.fbPoolKey, forward == fb.orderAligned, SafeCast.toInt256(output));
        (uint256 next,,) = _quoter.quote(fb.fbPoolKey, forward == fb.orderAligned, SafeCast.toInt256(output + 1));
        return next - current + MAX_ROUNDING_LOSS;
    }

    function _inputQuantum(FbPool memory fb, bool forward, uint256 output) private view returns (uint256) {
        try this.inputQuantum(fb, forward, output) returns (uint256 quantum) {
            return quantum;
        } catch {
            return MAX_ROUNDING_LOSS;
        }
    }

    function _spotDeviationBps(uint160 start, bool forward, FbPool memory fb)
        private
        view
        returns (uint256 deviationBps, uint256 allowedBps)
    {
        (uint160 backend,, uint24 protocolFee, uint24 lpFee) = poolManager.getSlot0(fb.fbPoolKey.toId());
        bool fbForward = forward == fb.orderAligned;
        uint16 directionalFee = fbForward
            ? ProtocolFeeLibrary.getZeroForOneFee(protocolFee)
            : ProtocolFeeLibrary.getOneForZeroFee(protocolFee);
        uint24 fee = ProtocolFeeLibrary.calculateSwapFee(directionalFee, lpFee);
        if (fee >= 1_000_000) revert InvalidRoute();
        allowedBps = MAX_SPOT_DEVIATION_BPS + (uint256(fee) + 99) / 100;
        uint256 q96 = 1 << 96;
        uint256 sqrtRatio;
        if (fb.orderAligned) {
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

    function _requireFullRange(PoolKey calldata key, ModifyLiquidityParams calldata params) private view {
        requireJITNotInProgress();
        _requirePool(key);
        if (
            params.tickLower != TickMath.minUsableTick(key.tickSpacing)
                || params.tickUpper != TickMath.maxUsableTick(key.tickSpacing)
        ) revert FullRangeLiquidityOnly();
    }

    function _resolve(Currency currency) private {
        int256 delta = poolManager.currencyDelta(address(this), currency);
        uint256 amount = SafeCast.toUint256(delta < 0 ? -delta : delta);
        if (amount > MAX_ROUNDING_LOSS) revert RoundingLossExceeded();
        if (delta < 0) _settle(currency, address(this), amount);
        else if (delta > 0) _take(currency, address(this), amount);
        _requireDelta(currency, 0);
    }

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
        if (!initialized || PoolId.unwrap(key.toId()) != PoolId.unwrap(configuredPoolId)) revert InvalidPool();
    }

    function _requireCurrency(Currency currency) private view {
        if (!initialized || (!(currency == _key.currency0) && !(currency == _key.currency1))) revert InvalidPool();
    }

    function _requireBuffers() private view {
        if (roundingReserve[_key.currency0] < MIN_BUFFER || roundingReserve[_key.currency1] < MIN_BUFFER) {
            revert InsufficientRoundingBuffer();
        }
    }

    function _requireZeroFees() private view {
        (,, uint24 protocolFee, uint24 lpFee) = poolManager.getSlot0(configuredPoolId);
        if (protocolFee != 0 || lpFee != 0) revert ProtocolFeeNotSupported();
    }

    function _route() private view returns (FbPool memory fb) {
        fb = fbPools[configuredPoolId];
        if (!fb.set || _validateFbPool(fb.fbPoolKey) != fb.orderAligned) revert InvalidRoute();
    }

    function _validateFbPool(PoolKey memory key) private view returns (bool aligned) {
        if (
            address(key.hooks) != address(0) || key.fee >= 1_000_000 || key.tickSpacing < TickMath.MIN_TICK_SPACING
                || key.tickSpacing > TickMath.MAX_TICK_SPACING || key.currency0.isAddressZero()
                || key.currency0 >= key.currency1 || key.currency0 == _key.currency0 || key.currency0 == _key.currency1
                || key.currency1 == _key.currency0 || key.currency1 == _key.currency1
        ) revert InvalidRoute();
        address fw0 = Currency.unwrap(key.currency0);
        address fw1 = Currency.unwrap(key.currency1);
        if (fw0.code.length == 0 || fw1.code.length == 0) revert InvalidRoute();
        address raw0 = IFewWrappedToken(fw0).token();
        address raw1 = IFewWrappedToken(fw1).token();
        if (raw0 == Currency.unwrap(_key.currency0) && raw1 == Currency.unwrap(_key.currency1)) {
            aligned = true;
        } else if (raw0 != Currency.unwrap(_key.currency1) || raw1 != Currency.unwrap(_key.currency0)) {
            revert InvalidRoute();
        }
        if (fewFactory.getWrappedToken(raw0) != fw0 || fewFactory.getWrappedToken(raw1) != fw1) revert InvalidRoute();
        (uint160 price,,, uint24 lpFee) = poolManager.getSlot0(key.toId());
        if (price == 0 || lpFee != key.fee) revert InvalidRoute();
    }

    function _requireDelta(Currency currency, int256 expected) private view {
        if (poolManager.currencyDelta(address(this), currency) != expected) revert UnexpectedTokenDelta();
    }

    function _execute(bool forward, uint256 ringIn, uint256 ringOut) private {
        FbPool memory fb = _route();
        bool fbForward = forward == fb.orderAligned;
        (uint256 quotedIn, uint256 quotedOut, uint160 expectedEnd) =
            _quoter.quote(fb.fbPoolKey, fbForward, SafeCast.toInt256(ringOut));
        if (quotedIn != ringIn || quotedOut != ringOut) revert UnexpectedFill();
        Currency input = forward ? _key.currency0 : _key.currency1;
        Currency output = forward ? _key.currency1 : _key.currency0;
        Currency fwInput = fbForward ? fb.fbPoolKey.currency0 : fb.fbPoolKey.currency1;
        Currency fwOutput = fbForward ? fb.fbPoolKey.currency1 : fb.fbPoolKey.currency0;
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
            fb.fbPoolKey,
            SwapParams(
                fbForward,
                SafeCast.toInt256(ringOut),
                fbForward ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            ""
        );
        int128 actualIn = fbForward ? delta.amount0() : delta.amount1();
        int128 actualOut = fbForward ? delta.amount1() : delta.amount0();
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
        (uint160 actualEnd,,,) = poolManager.getSlot0(fb.fbPoolKey.toId());
        if (actualEnd != expectedEnd) revert UnexpectedFill();
        _route();
    }
}

contract RingV4BackedLiqQuoter {
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
        RingV4BackedLiqHook.FbPool calldata fb
    ) external view returns (uint256 ringIn, uint256 ringOut, RingLPPlanner.Plan memory p, int256 difference) {
        uint256 jitIn;
        uint256 jitOut;
        (p, jitIn, jitOut) =
            RingLPPlanner.planAtCurrent(start, baseLiquidity, jitLiquidity, specified, forward, spacing);
        if (jitOut == 0 || jitOut > type(uint96).max) revert RingV4BackedLiqHook.UnexpectedFill();
        (ringIn, ringOut,) =
            FewV4Quoter.quote(_manager, fb.fbPoolKey, forward == fb.orderAligned, SafeCast.toInt256(jitOut));
        if (ringOut != jitOut || ringIn == 0 || ringIn > uint256(uint128(type(int128).max))) {
            revert RingV4BackedLiqHook.UnexpectedFill();
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
