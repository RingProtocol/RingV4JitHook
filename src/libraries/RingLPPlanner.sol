// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";

/// @notice Constructs one real v4 LP position for an externally priced order.
/// @dev Simulates empty bitmap word boundaries as v4 does, rather than assuming one swap step.
///      Unsupported integer-price granularity reverts; it is never financed from an unbounded reserve.
library RingLPPlanner {
    uint256 internal constant MIN_AMOUNT = 10_000;
    uint256 internal constant MAX_AMOUNT = type(uint96).max;
    error UnrepresentableOrder();

    struct Plan {
        uint160 start;
        uint160 end;
        uint128 liquidity;
        int24 lower;
        int24 upper;
        uint256 amountIn;
        uint256 amountOut;
        // Net token amounts the JIT position contributes: input collected and output given.
        uint256 jitIn;
        uint256 jitOut;
        // Backend leg expectations, set by the caller: the exact-input cost of `jitOut` on
        // the backend pool and the backend sqrt price after that leg executes.
        uint256 jitCost;
        uint160 backendEnd;
    }

    /// @notice Closed-form JIT plan matching an external quote of `ringIn` in / `ringOut` out
    ///         for the user's `specified` amount.
    /// @dev
    ///  For constant liquidity traversed from `start` to `end`, the fill ratio satisfies
    ///  `amountOut / amountIn == start * end / Q96^2` (zeroForOne; mirrored for oneForZero),
    ///  so the end price is solved directly:
    ///      zeroForOne: end = ringOut * Q96^2 / (ringIn * start)
    ///      oneForZero: end = ringIn  * Q96^2 / (ringOut * start)
    ///  and the total liquidity follows from the fill equation of the unspecified side:
    ///      token1 side: amount1 = L * |end - start| / Q96
    ///      token0 side: amount0 = L * Q96 * |end - start| / (start * end)
    ///  The solved liquidity is verified with an exact `simulate` and nudged so the fill
    ///  lands within `tolerance` of the quote on the hook-safe side: an exact-input fill
    ///  must produce `amountOut <= ringOut` and an exact-output fill must cost
    ///  `amountIn >= ringIn` (the hook can always afford the convexity discount on its
    ///  proportional share, but never a deficit).
    ///  Returns `liquidity == 0` when the quote cannot be expressed from `start` — spot on
    ///  the wrong side of the quote's average price, dust, or permanent liquidity already
    ///  sufficient — in which case the caller falls back to permanent liquidity.
    function planQuoted(
        uint160 start,
        uint128 baseLiquidity,
        uint256 ringIn,
        uint256 ringOut,
        int256 specified,
        bool zeroForOne,
        int24 spacing,
        uint256 tolerance
    ) internal pure returns (Plan memory p) {
        if (
            specified == 0 || ringIn < MIN_AMOUNT || ringOut < MIN_AMOUNT || ringIn > MAX_AMOUNT || ringOut > MAX_AMOUNT
                || spacing <= 0 || spacing > 200
        ) return p;
        bool exactInput = specified < 0;
        uint256 q = (uint256(1) << 192) / start; // Q96^2 / start, <1 wei of relative error
        uint256 end = zeroForOne ? FullMath.mulDiv(ringOut, q, ringIn) : FullMath.mulDiv(ringIn, q, ringOut);
        // The fill's average price cannot beat `start`: zeroForOne needs end < start.
        if (zeroForOne ? end >= start : end <= start) return p;
        if (end <= TickMath.MIN_SQRT_PRICE || end >= TickMath.MAX_SQRT_PRICE) return p;
        uint256 gap = zeroForOne ? start - uint160(end) : uint160(end) - start;
        // Solve total liquidity from the unspecified side's fill equation.
        //   exact input  -> solve on the output (quote amount ringOut)
        //   exact output -> solve on the input  (quote amount ringIn)
        uint256 target = exactInput ? ringOut : ringIn;
        uint256 total = zeroForOne == exactInput
            ? FullMath.mulDiv(target, 1 << 96, gap)
            : FullMath.mulDiv(FullMath.mulDiv(target, start, 1 << 96), end, gap);
        // Exact input rounds down so `amountOut <= ringOut`; exact output rounds up so
        // `amountIn >= ringIn`.
        if (!exactInput) total += 1;
        if (total <= baseLiquidity) return p;
        uint256 jit = total - baseLiquidity;
        if (jit == 0 || jit > type(uint128).max - baseLiquidity) return p;
        for (uint256 i; i < 8; ++i) {
            p = planAtCurrent(start, baseLiquidity, uint128(jit), specified, zeroForOne, spacing);
            uint256 diff;
            bool grow;
            if (exactInput) {
                if (p.amountOut <= ringOut && ringOut - p.amountOut <= tolerance) return p;
                grow = p.amountOut < ringOut;
                diff = p.amountOut > ringOut ? p.amountOut - ringOut : ringOut - p.amountOut;
            } else {
                if (p.amountIn >= ringIn && p.amountIn - ringIn <= tolerance) return p;
                grow = p.amountIn < ringIn;
                diff = p.amountIn > ringIn ? p.amountIn - ringIn : ringIn - p.amountIn;
            }
            uint256 step = zeroForOne == exactInput
                ? FullMath.mulDiv(diff, 1 << 96, gap)
                : FullMath.mulDiv(FullMath.mulDiv(diff, start, 1 << 96), end, gap);
            if (grow) {
                jit += step + 1;
                if (jit > type(uint128).max - baseLiquidity) break;
            } else {
                if (step + 1 >= jit) break;
                jit -= step + 1;
            }
        }
        Plan memory empty;
        return empty;
    }

    /// @notice Builds the JIT leg on top of active full-range base liquidity at the stored pool price.
    function planAtCurrent(
        uint160 start,
        uint128 baseLiquidity,
        uint128 jitLiquidity,
        int256 specified,
        bool zeroForOne,
        int24 spacing
    ) internal pure returns (Plan memory p) {
        if (jitLiquidity == 0 || baseLiquidity > type(uint128).max - jitLiquidity) {
            revert UnrepresentableOrder();
        }
        p.start = start;
        p.liquidity = jitLiquidity;
        (p.end, p.amountIn, p.amountOut) = simulate(start, baseLiquidity + jitLiquidity, specified, zeroForOne, spacing);
        int24 startTick = TickMath.getTickAtSqrtPrice(start);
        int24 endTick = TickMath.getTickAtSqrtPrice(p.end);
        p.lower = (_floor(startTick < endTick ? startTick : endTick, spacing) - 1) * spacing;
        p.upper = (_floor(startTick > endTick ? startTick : endTick, spacing) + 2) * spacing;
        if (p.lower < TickMath.minUsableTick(spacing) || p.upper > TickMath.maxUsableTick(spacing)) {
            revert UnrepresentableOrder();
        }
        uint160 lowerPrice = TickMath.getSqrtPriceAtTick(p.lower);
        uint160 upperPrice = TickMath.getSqrtPriceAtTick(p.upper);
        uint256 add0 = SqrtPriceMath.getAmount0Delta(start, upperPrice, jitLiquidity, true);
        uint256 add1 = SqrtPriceMath.getAmount1Delta(lowerPrice, start, jitLiquidity, true);
        uint256 remove0 = SqrtPriceMath.getAmount0Delta(p.end, upperPrice, jitLiquidity, false);
        uint256 remove1 = SqrtPriceMath.getAmount1Delta(lowerPrice, p.end, jitLiquidity, false);
        if (zeroForOne) {
            if (remove0 <= add0 || add1 <= remove1) revert UnrepresentableOrder();
            p.jitIn = remove0 - add0;
            p.jitOut = add1 - remove1;
        } else {
            if (remove1 <= add1 || add0 <= remove0) revert UnrepresentableOrder();
            p.jitIn = remove1 - add1;
            p.jitOut = add0 - remove0;
        }
    }

    /// @dev Simulates a v4 swap over constant liquidity with no initialized interior ticks.
    ///      The shell pool only holds full-range positions, so liquidity is uniform across
    ///      all ticks and there are no interior tick boundaries to cross. The only
    ///      boundaries the swap must step over are the 256-tick bitmap word boundaries
    ///      (where v4 checks whether the next word has initialized ticks — always empty here).
    ///      With L=1000*sqrt(in*out) the intended trade is short; four bitmap steps suffice.
    ///      Fee is hardcoded to zero because the shell pool enforces fee == 0.
    function simulate(uint160 start, uint128 liquidity, int256 specified, bool zeroForOne, int24 spacing)
        internal
        pure
        returns (uint160 price, uint256 input, uint256 output)
    {
        price = start;
        int24 tick = TickMath.getTickAtSqrtPrice(price);
        // `remaining` tracks the unfulfilled portion of `specified`:
        //   negative = exact input (consume stepIn to shrink it toward 0)
        //   positive = exact output (consume stepOut to shrink it toward 0)
        int256 remaining = specified;
        for (uint256 i; i < 4 && remaining != 0; ++i) {
            // Compress the current tick into spacing units, then find the nearest
            // 256-tick bitmap word boundary in the swap direction.
            //   zeroForOne (price decreasing): boundary = start of the current word
            //   oneForZero (price increasing): boundary = end of the next word
            int24 compressed = _floor(tick, spacing);
            int24 next =
                zeroForOne ? (compressed >> 8) * 256 * spacing : (((compressed + 1) >> 8) * 256 + 255) * spacing;
            if (next <= TickMath.MIN_TICK || next >= TickMath.MAX_TICK) revert UnrepresentableOrder();
            // The sqrtPrice at the word boundary — the furthest price this step can reach.
            uint160 boundary = TickMath.getSqrtPriceAtTick(next);
            uint256 stepIn;
            uint256 stepOut;
            // computeSwapStep solves the constant-product math for this leg:
            //   how much input/output is consumed to move `price` to `boundary`
            //   (or to fully satisfy `remaining`, whichever comes first).
            //   Fee is 0 — the shell pool enforces fee == 0.
            (price, stepIn, stepOut,) = SwapMath.computeSwapStep(price, boundary, liquidity, remaining, 0);
            input += stepIn;
            output += stepOut;
            // Shrink `remaining` by the consumed amount.
            //   exact input (specified < 0): remaining += stepIn (approaches 0 from below)
            //   exact output (specified > 0): remaining -= stepOut (approaches 0 from above)
            remaining = specified < 0 ? remaining + SafeCast.toInt256(stepIn) : remaining - SafeCast.toInt256(stepOut);
            // If the price reached the word boundary, step past it so the next
            // iteration starts inside the adjacent word. Otherwise the swap
            // terminated mid-word — recover the exact tick from the final price.
            if (price == boundary) tick = zeroForOne ? next - 1 : next;
            else tick = TickMath.getTickAtSqrtPrice(price);
        }
        // If we still have unfulfilled input/output after 4 word-boundary steps,
        // the trade is too large for this liquidity level — reject.
        if (remaining != 0) revert UnrepresentableOrder();
    }

    function _floor(int24 tick, int24 spacing) private pure returns (int24 compressed) {
        compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) --compressed;
    }
}
