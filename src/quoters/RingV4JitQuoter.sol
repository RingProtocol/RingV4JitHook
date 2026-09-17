// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {FewV4Quoter} from "../libraries/FewV4Quoter.sol";

/// @notice External-view wrapper around {FewV4Quoter} so the hook can try/catch quote failures.
contract RingV4JitQuoter {
    IPoolManager private immutable _manager;

    constructor(IPoolManager manager) {
        _manager = manager;
    }

    function quote(PoolKey memory key, bool zeroForOne, int256 amountSpecified)
        external
        view
        returns (uint256 amountIn, uint256 amountOut, uint160 sqrtPriceX96)
    {
        return FewV4Quoter.quote(_manager, key, zeroForOne, amountSpecified);
    }
}
