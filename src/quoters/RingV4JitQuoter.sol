// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {RingLPPlanner} from "../libraries/RingLPPlanner.sol";
import {FewV4Quoter} from "../libraries/FewV4Quoter.sol";
import {LpPool} from "../types/LpPool.sol";
import {RingV4JitHook} from "../hooks/RingV4JitHook.sol";

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
        LpPool calldata lp
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
