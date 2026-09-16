// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";

/// @notice ERC20 router with input prepayment, full-fill enforcement, amount limits, and refunds.
/// @dev No custom deltas: the received delta is the actual v4 LP swap result.
contract RingLPRouter is IUnlockCallback, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;
    using TransientStateLibrary for IPoolManager;
    IPoolManager public immutable poolManager;
    bytes32 private constant SYNC_SWAP = keccak256("RingV4JitHook.sync");
    error InvalidSwap();
    error Expired();
    error UnauthorizedCallback();
    error SlippageExceeded();
    error IncompleteFill();

    constructor(IPoolManager manager) {
        if (address(manager) == address(0)) revert InvalidSwap();
        poolManager = manager;
    }

    function swap(PoolKey calldata key, SwapParams calldata params, uint256 limit, uint256 deadline)
        external
        nonReentrant
        returns (BalanceDelta)
    {
        return _swap(key, params, limit, deadline, bytes(""));
    }

    /// @notice Trades only against permanent v4 liquidity so arbitrageurs can realign its price with Ring.
    /// @dev The caller chooses direction, amount, price limit and slippage limit and supplies all input capital.
    function syncPrice(PoolKey calldata key, SwapParams calldata params, uint256 limit, uint256 deadline)
        external
        nonReentrant
        returns (BalanceDelta)
    {
        return _swap(key, params, limit, deadline, abi.encode(SYNC_SWAP));
    }

    function _swap(
        PoolKey calldata key,
        SwapParams calldata params,
        uint256 limit,
        uint256 deadline,
        bytes memory hookData
    ) private returns (BalanceDelta) {
        // A timestamp deadline is intentional: it limits how long the user-authorized swap can execute.
        // Small validator timestamp variance cannot bypass the user's amount limit.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > deadline) revert Expired();
        if (
            key.currency0.isAddressZero() || key.currency1.isAddressZero() || params.amountSpecified == 0
                || params.amountSpecified == type(int256).min || limit == 0
        ) revert InvalidSwap();
        uint256 budget = params.amountSpecified < 0 ? SafeCast.toUint256(-params.amountSpecified) : limit;
        if (budget > uint256(uint128(type(int128).max))) revert InvalidSwap();
        return
            abi.decode(poolManager.unlock(abi.encode(msg.sender, key, params, limit, budget, hookData)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || !_reentrancyGuardEntered()) revert UnauthorizedCallback();
        (
            address payer,
            PoolKey memory key,
            SwapParams memory params,
            uint256 limit,
            uint256 budget,
            bytes memory hookData
        ) = abi.decode(data, (address, PoolKey, SwapParams, uint256, uint256, bytes));
        Currency input = params.zeroForOne ? key.currency0 : key.currency1;
        Currency output = params.zeroForOne ? key.currency1 : key.currency0;
        poolManager.sync(input);
        IERC20(Currency.unwrap(input)).safeTransferFrom(payer, address(poolManager), budget);
        if (poolManager.settle() != budget) revert InvalidSwap();
        BalanceDelta delta = poolManager.swap(key, params, hookData);
        int128 di = params.zeroForOne ? delta.amount0() : delta.amount1();
        int128 dout = params.zeroForOne ? delta.amount1() : delta.amount0();
        if (di >= 0 || dout <= 0) revert InvalidSwap();
        uint256 spent = SafeCast.toUint256(-int256(di));
        uint256 received = SafeCast.toUint256(int256(dout));
        if (params.amountSpecified < 0) {
            if (spent != budget) revert IncompleteFill();
            if (received < limit) revert SlippageExceeded();
        } else {
            if (received != SafeCast.toUint256(params.amountSpecified)) revert IncompleteFill();
            if (spent > limit) revert SlippageExceeded();
        }
        if (
            poolManager.currencyDelta(address(this), input) != SafeCast.toInt256(budget - spent)
                || poolManager.currencyDelta(address(this), output) != SafeCast.toInt256(received)
        ) revert InvalidSwap();
        if (budget > spent) poolManager.take(input, payer, budget - spent);
        poolManager.take(output, payer, received);
        return abi.encode(delta);
    }
}
