// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

struct LpPool {
    PoolKey lpPoolKey;
    bool orderAligned;
    bool set;
}
