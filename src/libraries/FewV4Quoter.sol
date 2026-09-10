// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TickBitmap} from "@uniswap/v4-core/src/libraries/TickBitmap.sol";
import {BitMath} from "@uniswap/v4-core/src/libraries/BitMath.sol";
import {LiquidityMath} from "@uniswap/v4-core/src/libraries/LiquidityMath.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {FeeLib} from "../alf/libraries/FeeLib.sol";

library FewV4Quoter {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    uint256 internal constant MAX_STEPS = 512;

    error InvalidQuotePool();
    error InvalidQuoteAmount();
    error IncompleteQuote();

    struct State {
        uint160 price;
        int24 tick;
        uint128 liquidity;
        int256 remaining;
    }

    function quote(IPoolManager manager, PoolKey memory key, bool zeroForOne, int256 amountSpecified)
        internal
        view
        returns (uint256 amountIn, uint256 amountOut, uint160 sqrtPriceX96)
    {
        if (
            address(key.hooks) != address(0) || key.currency0.isAddressZero() || key.currency0 >= key.currency1
                || key.fee >= SwapMath.MAX_SWAP_FEE || key.tickSpacing < TickMath.MIN_TICK_SPACING
                || key.tickSpacing > TickMath.MAX_TICK_SPACING
        ) revert InvalidQuotePool();
        if (
            amountSpecified == 0 || amountSpecified < -int256(type(int128).max)
                || amountSpecified > int256(type(int128).max)
        ) revert InvalidQuoteAmount();

        PoolId id = key.toId();
        State memory state;
        uint24 protocolFee;
        uint24 lpFee;
        (state.price, state.tick, protocolFee, lpFee) = manager.getSlot0(id);
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        if (state.price == 0 || (zeroForOne ? limit >= state.price : limit <= state.price)) {
            revert InvalidQuotePool();
        }
        uint24 fee = FeeLib.effectiveSwapFee(lpFee, protocolFee, zeroForOne);
        if (fee >= SwapMath.MAX_SWAP_FEE) revert InvalidQuotePool();
        state.liquidity = manager.getLiquidity(id);
        state.remaining = amountSpecified;

        for (uint256 i; i < MAX_STEPS && state.remaining != 0 && state.price != limit; ++i) {
            (int24 next, bool initialized) = _nextTick(manager, id, state.tick, key.tickSpacing, zeroForOne);
            if (next < TickMath.MIN_TICK) next = TickMath.MIN_TICK;
            if (next > TickMath.MAX_TICK) next = TickMath.MAX_TICK;
            uint160 nextPrice = TickMath.getSqrtPriceAtTick(next);
            uint256 stepIn;
            uint256 stepOut;
            uint256 feeAmount;
            (state.price, stepIn, stepOut, feeAmount) = SwapMath.computeSwapStep(
                state.price,
                SwapMath.getSqrtPriceTarget(zeroForOne, nextPrice, limit),
                state.liquidity,
                state.remaining,
                fee
            );
            amountIn += stepIn + feeAmount;
            amountOut += stepOut;
            if (amountIn > uint256(uint128(type(int128).max))) revert InvalidQuoteAmount();
            if (amountOut > uint256(uint128(type(int128).max))) revert InvalidQuoteAmount();
            state.remaining = amountSpecified < 0
                ? state.remaining + SafeCast.toInt256(stepIn + feeAmount)
                : state.remaining - SafeCast.toInt256(stepOut);

            if (state.price == nextPrice) {
                if (initialized) {
                    (, int128 net) = manager.getTickLiquidity(id, next);
                    state.liquidity = LiquidityMath.addDelta(state.liquidity, zeroForOne ? -net : net);
                }
                state.tick = zeroForOne ? next - 1 : next;
            } else {
                state.tick = TickMath.getTickAtSqrtPrice(state.price);
            }
        }
        if (state.remaining != 0 || amountIn == 0 || amountOut == 0) revert IncompleteQuote();
        sqrtPriceX96 = state.price;
    }

    function _nextTick(IPoolManager manager, PoolId id, int24 tick, int24 spacing, bool zeroForOne)
        private
        view
        returns (int24 next, bool initialized)
    {
        unchecked {
            int24 compressed = TickBitmap.compress(tick, spacing);
            if (zeroForOne) {
                (int16 word, uint8 bit) = TickBitmap.position(compressed);
                uint256 masked = manager.getTickBitmap(id, word) & (type(uint256).max >> (255 - bit));
                initialized = masked != 0;
                next = initialized
                    ? (compressed - int24(uint24(bit - BitMath.mostSignificantBit(masked)))) * spacing
                    : (compressed - int24(uint24(bit))) * spacing;
            } else {
                (int16 word, uint8 bit) = TickBitmap.position(++compressed);
                uint256 masked = manager.getTickBitmap(id, word) & ~((uint256(1) << bit) - 1);
                initialized = masked != 0;
                next = initialized
                    ? (compressed + int24(uint24(BitMath.leastSignificantBit(masked) - bit))) * spacing
                    : (compressed + int24(uint24(255 - bit))) * spacing;
            }
        }
    }
}
