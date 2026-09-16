// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {RingV4JitHook} from "../src/hooks/RingV4JitHook.sol";
import {RingLPRouter} from "../src/routers/RingLPRouter.sol";
import {RingLPPlanner} from "../src/libraries/RingLPPlanner.sol";
import {IFewFactory} from "../src/interfaces/external/IFewFactory.sol";
import {IFewWrappedToken} from "../src/interfaces/external/IFewWrappedToken.sol";
import {HookMiner} from "./TestHelpers.sol";

/// @notice Fork integration test against Ethereum mainnet via anvil (port 8545).
///         Run with: forge test --fork-url http://127.0.0.1:8545 --match-contract RingV4JitHookFork -vvv
contract RingV4JitHookForkTest is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // Mainnet constants
    IPoolManager constant pm = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IFewFactory constant few = IFewFactory(0x7D86394139bf1122E82FDF45Bb4e3b038A4464DD);
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant FEW_WBTC = 0x2078f336Fdd260f708BEc4a20c82b063274E1b23;
    address constant FEW_WETH = 0xa250CC729Bb3323e7933022a67B52200fE354767;

    RingV4JitHook hook;
    RingLPRouter router;
    PoolModifyLiquidityTest lp;

    PoolKey key; // outer pool: WBTC/WETH with hook, fee=0, ts=60
    PoolKey fbKey; // backend pool: FEW_WBTC/FEW_WETH hookless, fee=3000, ts=60

    uint160 backendSqrtPrice;

    function setUp() public {
        // ------------------------------------------------------------------
        // 1. Token acquisition
        // ------------------------------------------------------------------
        // Deal ETH and wrap to WETH (proper deposit flow)
        vm.deal(address(this), 200_000 ether);
        IWETH(WETH).deposit{value: 100_000 ether}();

        // Deal WBTC via storage manipulation
        deal(WBTC, address(this), 1_000e8); // 1000 WBTC

        // ------------------------------------------------------------------
        // 2. Deploy test helpers
        // ------------------------------------------------------------------
        lp = new PoolModifyLiquidityTest(pm);
        router = new RingLPRouter(pm);

        // ------------------------------------------------------------------
        // 3. Seed backend pool (FEW_WBTC / FEW_WETH, fee=3000, ts=60)
        // ------------------------------------------------------------------
        fbKey = PoolKey(Currency.wrap(FEW_WBTC), Currency.wrap(FEW_WETH), 3000, 60, IHooks(address(0)));
        (backendSqrtPrice,,,) = pm.getSlot0(fbKey.toId());
        assertGt(backendSqrtPrice, 0, "backend pool not initialized");

        // Wrap raw tokens to FewWrapped tokens
        IERC20(WBTC).approve(FEW_WBTC, type(uint256).max);
        IERC20(WETH).approve(FEW_WETH, type(uint256).max);
        IFewWrappedToken(FEW_WBTC).wrap(100e8); // 100 FEW_WBTC
        IFewWrappedToken(FEW_WETH).wrap(3_000e18); // 3000 FEW_WETH

        // Approve FEW tokens to PoolModifyLiquidityTest and add full-range liquidity
        IERC20(FEW_WBTC).approve(address(lp), type(uint256).max);
        IERC20(FEW_WETH).approve(address(lp), type(uint256).max);
        lp.modifyLiquidity(
            fbKey,
            ModifyLiquidityParams(
                TickMath.minUsableTick(60), TickMath.maxUsableTick(60), int256(uint256(1e14)), bytes32(0)
            ),
            ""
        );

        // ------------------------------------------------------------------
        // 4. Deploy hook (CREATE2 mine for flags 0x2ac0)
        // ------------------------------------------------------------------
        bytes memory args = abi.encode(pm, few, address(this));
        (bytes32 salt,) = HookMiner.mine(address(this), type(RingV4JitHook).creationCode, args, 0x2ac0, 300_000);
        hook = new RingV4JitHook{salt: salt}(pm, few, address(this));

        // ------------------------------------------------------------------
        // 5. Initialize outer pool (WBTC/WETH, fee=0, ts=60, hook)
        // ------------------------------------------------------------------
        key = PoolKey(Currency.wrap(WBTC), Currency.wrap(WETH), 0, 60, IHooks(address(hook)));
        hook.initializePool(key, backendSqrtPrice);

        // ------------------------------------------------------------------
        // 6. Configure backend route
        // ------------------------------------------------------------------
        hook.setFbPool(key, fbKey);
        assertTrue(hook.getFbPool(key).set);
        assertTrue(hook.getFbPool(key).orderAligned, "wrapper ordering should be aligned");

        // ------------------------------------------------------------------
        // 7. Fund rounding buffers (MIN_BUFFER = 16)
        // ------------------------------------------------------------------
        IERC20(WBTC).approve(address(hook), type(uint256).max);
        IERC20(WETH).approve(address(hook), type(uint256).max);
        hook.fundRounding(key.currency0, 1_000_000); // 0.01 WBTC
        hook.fundRounding(key.currency1, 1_000_000); // 0.000001 WETH

        // ------------------------------------------------------------------
        // 8. Add full-range base liquidity to outer pool
        // ------------------------------------------------------------------
        IERC20(WBTC).approve(address(lp), type(uint256).max);
        IERC20(WETH).approve(address(lp), type(uint256).max);
        lp.modifyLiquidity(
            key,
            ModifyLiquidityParams(
                TickMath.minUsableTick(60), TickMath.maxUsableTick(60), int256(uint256(1e12)), bytes32(0)
            ),
            ""
        );
        assertGt(pm.getLiquidity(key.toId()), 0, "outer pool has no base liquidity");

        // ------------------------------------------------------------------
        // 9. Set pool live
        // ------------------------------------------------------------------
        hook.setPoolLive(true);
        assertTrue(hook.live());

        // ------------------------------------------------------------------
        // 10. Approve router
        // ------------------------------------------------------------------
        IERC20(WBTC).approve(address(router), type(uint256).max);
        IERC20(WETH).approve(address(router), type(uint256).max);
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    function _params(bool forward, int256 specified) internal pure returns (SwapParams memory) {
        return SwapParams(forward, specified, forward ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
    }

    function _assertSettled() internal view {
        assertFalse(pm.isUnlocked(), "pool manager should be locked during assertion");
        assertEq(pm.getNonzeroDeltaCount(), 0, "nonzero delta count");
        assertEq(pm.currencyDelta(address(hook), key.currency0), 0, "hook delta c0");
        assertEq(pm.currencyDelta(address(hook), key.currency1), 0, "hook delta c1");
        assertEq(pm.currencyDelta(address(router), key.currency0), 0, "router delta c0");
        assertEq(pm.currencyDelta(address(router), key.currency1), 0, "router delta c1");
        assertEq(IERC20(WBTC).balanceOf(address(router)), 0, "router wbtc balance");
        assertEq(IERC20(WETH).balanceOf(address(router)), 0, "router weth balance");
        assertGt(pm.getLiquidity(key.toId()), 0, "base liquidity preserved");
    }

    // -----------------------------------------------------------------------
    // Tests
    // -----------------------------------------------------------------------

    /// @notice Test that the hook is deployed with correct permissions and constants.
    function test_ForkPermissionsAndConstants() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize);
        assertTrue(p.beforeAddLiquidity);
        assertTrue(p.beforeRemoveLiquidity);
        assertTrue(p.beforeSwap);
        assertTrue(p.afterSwap);
        assertFalse(p.beforeSwapReturnDelta);
        assertFalse(p.afterSwapReturnDelta);
        assertEq(uint160(address(hook)) & 0x3FFF, 0x2AC0);
        assertEq(hook.MAX_ROUNDING_LOSS(), 8);
        assertEq(hook.MAX_SPOT_DEVIATION_BPS(), 500);
        assertEq(hook.MIN_BUFFER(), 16);
    }

    /// @notice Test quote is view-only and returns sensible values.
    function test_ForkQuoteDoesNotMutateState() public {
        // Quote: swap 0.01 WBTC for WETH
        uint256 before = vm.snapshotState();
        (uint256 ringIn, uint256 ringOut, RingLPPlanner.Plan memory p) = hook.quote(key, true, -int256(0.01e8));
        assertGt(p.amountOut, 0, "quote should return positive output");
        assertGt(ringIn, 0, "backend ringIn should be positive");
        assertGt(ringOut, 0, "backend ringOut should be positive");
        assertEq(p.amountIn, 0.01e8, "exact input should match");
        assertTrue(vm.revertToState(before));
    }

    /// @notice Test forward swap: WBTC -> WETH via the backed hook.
    function test_ForkSwapWBTCForWETH() public {
        (, uint256 ringOut, RingLPPlanner.Plan memory p) = hook.quote(key, true, -int256(0.01e8));
        assertGt(p.amountOut, 0);

        uint256 wbtcBefore = IERC20(WBTC).balanceOf(address(this));
        uint256 wethBefore = IERC20(WETH).balanceOf(address(this));

        BalanceDelta delta = router.swap(key, _params(true, -int256(0.01e8)), p.amountOut, block.timestamp);

        assertEq(int256(delta.amount0()), -int256(p.amountIn), "delta amount0");
        assertEq(int256(delta.amount1()), int256(p.amountOut), "delta amount1");
        assertEq(wbtcBefore - IERC20(WBTC).balanceOf(address(this)), p.amountIn, "wbtc spent");
        assertEq(IERC20(WETH).balanceOf(address(this)) - wethBefore, p.amountOut, "weth received");

        _assertSettled();
    }

    /// @notice Test reverse swap: WETH -> WBTC via the backed hook.
    function test_ForkSwapWETHForWBTC() public {
        (,, RingLPPlanner.Plan memory p) = hook.quote(key, false, -int256(0.2e18));
        assertGt(p.amountOut, 0);

        uint256 wethBefore = IERC20(WETH).balanceOf(address(this));
        uint256 wbtcBefore = IERC20(WBTC).balanceOf(address(this));

        BalanceDelta delta = router.swap(key, _params(false, -int256(0.2e18)), p.amountOut, block.timestamp);

        assertEq(int256(delta.amount1()), -int256(p.amountIn), "delta amount1 (input)");
        assertEq(int256(delta.amount0()), int256(p.amountOut), "delta amount0 (output)");
        assertEq(wethBefore - IERC20(WETH).balanceOf(address(this)), p.amountIn, "weth spent");
        assertEq(IERC20(WBTC).balanceOf(address(this)) - wbtcBefore, p.amountOut, "wbtc received");

        _assertSettled();
    }

    /// @notice Test exact-output swap: specify desired WETH output, pay WBTC input.
    function test_ForkExactOutputSwap() public {
        (,, RingLPPlanner.Plan memory p) = hook.quote(key, true, int256(0.1e18));
        assertGt(p.amountIn, 0);
        assertEq(p.amountOut, 0.1e18);

        uint256 wbtcBefore = IERC20(WBTC).balanceOf(address(this));
        uint256 wethBefore = IERC20(WETH).balanceOf(address(this));

        // For exact output, limit is max input to spend. Use a generous but sane limit.
        router.swap(key, _params(true, int256(0.1e18)), p.amountIn * 2, block.timestamp);

        assertEq(wbtcBefore - IERC20(WBTC).balanceOf(address(this)), p.amountIn, "exact wbtc spent");
        assertEq(IERC20(WETH).balanceOf(address(this)) - wethBefore, p.amountOut, "exact weth received");

        _assertSettled();
    }

    /// @notice Test that slippage protection reverts on excessive slippage.
    function test_ForkSlippageReverts() public {
        (,, RingLPPlanner.Plan memory p) = hook.quote(key, true, -int256(0.01e8));
        assertGt(p.amountOut, 0);

        vm.expectRevert(RingLPRouter.SlippageExceeded.selector);
        router.swap(key, _params(true, -int256(0.01e8)), p.amountOut + 1, block.timestamp);
    }

    /// @notice Test repeated swaps clear JIT and preserve base liquidity.
    function test_ForkRepeatedSwaps() public {
        for (uint256 i; i < 5; ++i) {
            bool forward = i % 2 == 0;
            int256 size = forward ? -int256(0.005e8) : -int256(0.1e18);
            (,, RingLPPlanner.Plan memory p) = hook.quote(key, forward, size);
            if (p.amountOut == 0) continue;
            router.swap(key, _params(forward, size), p.amountOut, block.timestamp);
            _assertSettled();
        }
    }

    /// @notice Test syncPrice moves the outer pool price without touching the backend.
    function test_ForkSyncPrice() public {
        (uint160 start,,,) = pm.getSlot0(key.toId());
        // Sync to a slightly different price (move tick by a few ticks)
        int24 targetTick = 263100;
        uint160 target = TickMath.getSqrtPriceAtTick(targetTick);
        // Only sync if target is reachable (price moves in the right direction)
        if (target > start) {
            // Need to swap WETH -> WBTC (oneForZero, price goes up)
            uint256 amount = SqrtPriceMath.getAmount1Delta(start, target, pm.getLiquidity(key.toId()), true);
            bytes32 backendBefore = _backendStateHash();
            router.syncPrice(key, SwapParams(false, -int256(amount), target), 1, block.timestamp);
            assertEq(_backendStateHash(), backendBefore, "backend should not change");
            (uint160 end,,,) = pm.getSlot0(key.toId());
            assertEq(end, target, "outer price should reach target");
            _assertSettled();
        }
    }

    /// @notice Test that deviation guard blocks quotes when outer price diverges from backend.
    function test_ForkDeviationGuard() public {
        // At setup, outer price == backend price, so quote should work
        (,, RingLPPlanner.Plan memory p) = hook.quote(key, true, -int256(0.01e8));
        assertGt(p.amountOut, 0, "quote should work when prices are aligned");

        // Move the outer price very far from the backend (4x) to force JIT failure
        // and trigger the deviation guard on the base-only fallback path
        (uint160 start,,,) = pm.getSlot0(key.toId());
        uint160 target = uint160(uint256(start) * 4);
        uint256 amount = SqrtPriceMath.getAmount1Delta(start, target, pm.getLiquidity(key.toId()), true);
        router.syncPrice(key, SwapParams(false, -int256(amount), target), 1, block.timestamp);
        _assertSettled();

        // With 4x deviation, JIT cannot match and deviation guard should reject
        vm.expectRevert();
        hook.quote(key, true, -int256(0.01e8));
    }

    /// @notice Test that admin functions are owner-gated.
    function test_ForkAdminGated() public {
        address outsider = address(0xBEEF);
        vm.startPrank(outsider);
        vm.expectRevert();
        hook.setFbPool(key, fbKey);
        vm.expectRevert();
        hook.setPoolLive(false);
        vm.expectRevert();
        hook.fundRounding(key.currency0, 1);
        vm.expectRevert();
        hook.withdrawRounding(key.currency0, 1, outsider);
        vm.stopPrank();
    }

    /// @notice Test rounding reserves are preserved across swaps.
    function test_ForkRoundingReservePreserved() public {
        uint256 reserve0 = hook.roundingReserve(key.currency0);
        uint256 reserve1 = hook.roundingReserve(key.currency1);

        (,, RingLPPlanner.Plan memory p) = hook.quote(key, true, -int256(0.01e8));
        router.swap(key, _params(true, -int256(0.01e8)), p.amountOut, block.timestamp);
        _assertSettled();

        (,, p) = hook.quote(key, false, -int256(0.1e18));
        router.swap(key, _params(false, -int256(0.1e18)), p.amountOut, block.timestamp);
        _assertSettled();

        // Rounding loss per currency is capped at 8 raw units per swap
        assertLe(reserve0 - hook.roundingReserve(key.currency0), 16, "rounding loss c0");
        assertLe(reserve1 - hook.roundingReserve(key.currency1), 16, "rounding loss c1");
    }

    function _backendStateHash() internal view returns (bytes32) {
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = pm.getSlot0(fbKey.toId());
        return keccak256(abi.encode(price, tick, protocolFee, lpFee, pm.getLiquidity(fbKey.toId())));
    }

    /// @dev Required to receive ETH refunds from PoolModifyLiquidityTest.
    receive() external payable {}
}

interface IWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint256) external;
}
