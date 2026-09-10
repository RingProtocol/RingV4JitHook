// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
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
    uint256 internal constant MAX_PRICE_ROUNDING = 2;
    error UnrepresentableOrder();

    struct Plan {
        uint160 start;
        uint160 end;
        uint128 liquidity;
        int24 lower;
        int24 upper;
        uint256 amountIn;
        uint256 amountOut;
    }

    function plan(uint256 ringIn, uint256 ringOut, bool zeroForOne, bool exactInput, int24 spacing)
        internal
        pure
        returns (Plan memory p)
    {
        if (
            ringIn < MIN_AMOUNT || ringOut < MIN_AMOUNT || ringIn > MAX_AMOUNT || ringOut > MAX_AMOUNT || spacing <= 0
                || spacing > 200
        ) {
            revert UnrepresentableOrder();
        }
        p.liquidity = SafeCast.toUint128(Math.sqrt(ringIn * ringOut) * 1000);
        // Q128 ratio remains below 2^224 for the supported uint96 amounts.
        uint256 ratio = FullMath.mulDiv(zeroForOne ? ringOut : ringIn, 1 << 128, zeroForOne ? ringIn : ringOut);
        uint160 midPrice = SafeCast.toUint160(Math.sqrt(ratio) << 32);
        uint160 lo = midPrice / 2;
        uint160 hi = midPrice * 2;
        if (lo <= TickMath.MIN_SQRT_PRICE || hi >= TickMath.MAX_SQRT_PRICE) revert UnrepresentableOrder();
        int256 specified = exactInput ? -SafeCast.toInt256(ringIn) : SafeCast.toInt256(ringOut);
        uint256 target = exactInput ? ringOut : ringIn;
        bool increasing = zeroForOne == exactInput;
        // Locate the transition around the Ring amount, then select a user-favourable candidate.
        while (lo < hi) {
            uint160 middle = lo + (hi - lo) / 2;
            (, uint256 input, uint256 output) = simulate(middle, p.liquidity, specified, zeroForOne, spacing);
            uint256 metric = exactInput ? output : input;
            if (increasing ? metric < target : metric > target) lo = middle + 1;
            else hi = middle;
        }
        bool found;
        for (uint256 i; i < 2; ++i) {
            uint160 candidate = i == 0 ? lo : lo - 1;
            (uint160 end, uint256 input, uint256 output) =
                simulate(candidate, p.liquidity, specified, zeroForOne, spacing);
            bool acceptable = exactInput
                ? input == ringIn && output >= ringOut && output - ringOut <= MAX_PRICE_ROUNDING
                : output == ringOut && input <= ringIn && ringIn - input <= MAX_PRICE_ROUNDING;
            if (acceptable) {
                p.start = candidate;
                p.end = end;
                p.amountIn = input;
                p.amountOut = output;
                found = true;
                break;
            }
        }
        if (!found) revert UnrepresentableOrder();
        int24 startTick = TickMath.getTickAtSqrtPrice(p.start);
        int24 endTick = TickMath.getTickAtSqrtPrice(p.end);
        // Keep BOTH endpoints strictly inside the position. This also handles a starting
        // exact tick whose stored tick is tick-1 after the empty-pool reposition swap.
        p.lower = (_floor(startTick < endTick ? startTick : endTick, spacing) - 1) * spacing;
        p.upper = (_floor(startTick > endTick ? startTick : endTick, spacing) + 2) * spacing;
        if (p.lower < TickMath.minUsableTick(spacing) || p.upper > TickMath.maxUsableTick(spacing)) {
            revert UnrepresentableOrder();
        }
    }

    function _floor(int24 tick, int24 spacing) private pure returns (int24 compressed) {
        compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) --compressed;
    }

    /// @notice Builds the JIT leg on top of active full-range base liquidity at the stored pool price.
    function planAtCurrent(
        uint160 start,
        uint128 baseLiquidity,
        uint128 jitLiquidity,
        int256 specified,
        bool zeroForOne,
        int24 spacing
    ) internal pure returns (Plan memory p, uint256 jitIn, uint256 jitOut) {
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
            jitIn = remove0 - add0;
            jitOut = add1 - remove1;
        } else {
            if (remove1 <= add1 || add0 <= remove0) revert UnrepresentableOrder();
            jitIn = remove1 - add1;
            jitOut = add0 - remove0;
        }
    }

    /// @dev Constant liquidity, no initialized interior ticks, and a full-range price limit.
    ///      With L=1000*sqrt(in*out) the intended trade is short; four bitmap steps suffice.
    function simulate(uint160 start, uint128 liquidity, int256 specified, bool zeroForOne, int24 spacing)
        internal
        pure
        returns (uint160 price, uint256 input, uint256 output)
    {
        price = start;
        int24 tick = TickMath.getTickAtSqrtPrice(price);
        int256 remaining = specified;
        for (uint256 i; i < 4 && remaining != 0; ++i) {
            int24 compressed = _floor(tick, spacing);
            int24 next =
                zeroForOne ? (compressed >> 8) * 256 * spacing : (((compressed + 1) >> 8) * 256 + 255) * spacing;
            if (next <= TickMath.MIN_TICK || next >= TickMath.MAX_TICK) revert UnrepresentableOrder();
            uint160 boundary = TickMath.getSqrtPriceAtTick(next);
            uint256 stepIn;
            uint256 stepOut;
            (price, stepIn, stepOut,) = SwapMath.computeSwapStep(price, boundary, liquidity, remaining, 0);
            input += stepIn;
            output += stepOut;
            remaining = specified < 0 ? remaining + SafeCast.toInt256(stepIn) : remaining - SafeCast.toInt256(stepOut);
            if (price == boundary) tick = zeroForOne ? next - 1 : next;
            else tick = TickMath.getTickAtSqrtPrice(price);
        }
        if (remaining != 0) revert UnrepresentableOrder();
    }
}
