// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
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
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {RingV4JitHook} from "../src/hooks/RingV4JitHook.sol";
import {RingLPRouter} from "../src/routers/RingLPRouter.sol";
import {RingLPPlanner} from "../src/libraries/RingLPPlanner.sol";
import {FewV4Quoter} from "../src/libraries/FewV4Quoter.sol";
import {MockFewFactory, MockFewWrappedToken, HookMiner} from "./TestHelpers.sol";

contract DefensiveFewWrappedToken is MockERC20 {
    address public immutable token;
    uint8 public wrapMode;
    uint8 public unwrapMode;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackOnUnwrap;
    bool public callbackMustSucceed;
    uint256 public callbackAttempts;
    uint256 public callbackSuccesses;

    constructor(address underlying) MockERC20("Defensive Few", "dfw", 18) {
        token = underlying;
    }

    function setModes(uint8 wrapping, uint8 unwrapping) external {
        wrapMode = wrapping;
        unwrapMode = unwrapping;
    }

    function setCallback(address target, bytes calldata data, bool onUnwrap, bool mustSucceed) external {
        callbackTarget = target;
        callbackData = data;
        callbackOnUnwrap = onUnwrap;
        callbackMustSucceed = mustSucceed;
        callbackAttempts = 0;
        callbackSuccesses = 0;
    }

    function execute(address target, bytes calldata data) external {
        (bool ok,) = target.call(data);
        require(ok, "execution failed");
    }

    function wrap(uint256 amount) external returns (uint256) {
        require(IERC20(token).transferFrom(msg.sender, address(this), wrapMode == 3 ? amount - 1 : amount));
        _mint(msg.sender, wrapMode == 2 ? amount - 1 : amount);
        if (!callbackOnUnwrap) _callback();
        return wrapMode == 1 ? amount - 1 : amount;
    }

    function unwrap(uint256 amount) external returns (uint256) {
        _burn(msg.sender, unwrapMode == 3 ? amount - 1 : amount);
        require(IERC20(token).transfer(msg.sender, unwrapMode == 2 ? amount - 1 : amount));
        if (callbackOnUnwrap) _callback();
        return unwrapMode == 1 ? amount - 1 : amount;
    }

    function _callback() private {
        if (callbackTarget == address(0)) return;
        ++callbackAttempts;
        (bool ok,) = callbackTarget.call(callbackData);
        if (ok) ++callbackSuccesses;
        require(!callbackMustSucceed || ok, "callback failed");
    }
}

contract FewV4QuoteHarness {
    function quote(IPoolManager manager, PoolKey memory key, bool zeroForOne, int256 specified)
        external
        view
        returns (uint256 amountIn, uint256 amountOut, uint160 price)
    {
        return FewV4Quoter.quote(manager, key, zeroForOne, specified);
    }
}

contract RingV4JitHookTest is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint160 constant Q96 = 79228162514264337593543950336;
    uint128 constant BASE_LIQUIDITY = 100 ether;
    uint128 constant BACKEND_LIQUIDITY = 10_000 ether;
    PoolManager manager;
    IPoolManager pm;
    MockFewFactory few;
    RingV4JitHook hook;
    RingLPRouter router;
    PoolSwapTest backendRouter;
    PoolModifyLiquidityTest lp;
    FewV4QuoteHarness quoter;
    PoolKey key;
    PoolKey lpKey;
    address a;
    address b;
    address fwA;
    address fwB;
    uint256[4] donated;

    function _defensiveWrappers() internal returns (DefensiveFewWrappedToken input, DefensiveFewWrappedToken output) {
        _fullRange(lpKey, -int256(uint256(BACKEND_LIQUIDITY)));
        input = new DefensiveFewWrappedToken(a);
        output = new DefensiveFewWrappedToken(b);
        fwA = address(input);
        fwB = address(output);
        few.setWrapped(a, fwA);
        few.setWrapped(b, fwB);
        IERC20(a).approve(fwA, type(uint256).max);
        IERC20(b).approve(fwB, type(uint256).max);
        input.wrap(100_000 ether);
        output.wrap(100_000 ether);
        _approve(fwA);
        _approve(fwB);
        lpKey = _backendKey(3000, 60);
        pm.initialize(lpKey, Q96);
        _fullRange(lpKey, int256(uint256(BACKEND_LIQUIDITY)));
        hook.setLpPool(key, lpKey);
    }

    function setUp() public {
        _fixture(true);
    }

    function _fixture(bool aligned) internal {
        manager = new PoolManager(address(this));
        pm = IPoolManager(address(manager));
        few = new MockFewFactory();
        a = address(new MockERC20("A", "A", 18));
        b = address(new MockERC20("B", "B", 18));
        if (a > b) (a, b) = (b, a);
        fwA = address(few.create(a));
        fwB = address(few.create(b));
        while ((fwA < fwB) != aligned) {
            fwB = address(new MockFewWrappedToken(b));
        }
        few.setWrapped(b, fwB);
        router = new RingLPRouter(pm);
        backendRouter = new PoolSwapTest(pm);
        lp = new PoolModifyLiquidityTest(pm);
        quoter = new FewV4QuoteHarness();
        MockERC20(a).mint(address(this), 1_000_000 ether);
        MockERC20(b).mint(address(this), 1_000_000 ether);
        IERC20(a).approve(fwA, type(uint256).max);
        IERC20(b).approve(fwB, type(uint256).max);
        MockFewWrappedToken(fwA).wrap(100_000 ether);
        MockFewWrappedToken(fwB).wrap(100_000 ether);
        _approve(a);
        _approve(b);
        _approve(fwA);
        _approve(fwB);
        lpKey = _backendKey(3000, 60);
        pm.initialize(lpKey, Q96);
        _fullRange(lpKey, int256(uint256(BACKEND_LIQUIDITY)));
        bytes memory args = abi.encode(pm, few, address(this));
        (bytes32 salt,) = HookMiner.mine(address(this), type(RingV4JitHook).creationCode, args, 0x20c0, 10_000_000);
        hook = new RingV4JitHook{salt: salt}(pm, few, address(this));
        key = PoolKey(Currency.wrap(a), Currency.wrap(b), 0, 60, IHooks(address(hook)));
        pm.initialize(key, Q96);
        hook.setLpPool(key, lpKey);
        IERC20(a).approve(address(hook), type(uint256).max);
        IERC20(b).approve(address(hook), type(uint256).max);
        hook.fundRounding(key.currency0, 1_000_000);
        hook.fundRounding(key.currency1, 1_000_000);
        _fullRange(key, int256(uint256(BASE_LIQUIDITY)));
    }

    function _approve(address token) internal {
        IERC20(token).approve(address(router), type(uint256).max);
        IERC20(token).approve(address(backendRouter), type(uint256).max);
        IERC20(token).approve(address(lp), type(uint256).max);
    }

    function _backendKey(uint24 fee, int24 spacing) internal view returns (PoolKey memory) {
        return PoolKey(
            Currency.wrap(fwA < fwB ? fwA : fwB), Currency.wrap(fwA < fwB ? fwB : fwA), fee, spacing, IHooks(address(0))
        );
    }

    function _fullRange(PoolKey memory pool, int256 liquidity) internal {
        _range(pool, TickMath.minUsableTick(pool.tickSpacing), TickMath.maxUsableTick(pool.tickSpacing), liquidity);
    }

    function _range(PoolKey memory pool, int24 lower, int24 upper, int256 liquidity) internal {
        lp.modifyLiquidity(pool, ModifyLiquidityParams(lower, upper, liquidity, 0), "");
    }

    function _params(bool forward, int256 specified) internal pure returns (SwapParams memory) {
        return SwapParams(forward, specified, forward ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
    }

    function _backendSwap(bool forward, int256 specified) internal returns (BalanceDelta) {
        return backendRouter.swap(lpKey, _params(forward, specified), PoolSwapTest.TestSettings(false, false), "");
    }

    function _poolState(PoolKey memory pool) internal view returns (bytes32) {
        bytes32 slot = keccak256(abi.encodePacked(PoolId.unwrap(pool.toId()), bytes32(uint256(6))));
        return keccak256(abi.encode(pm.extsload(slot, 4)));
    }

    function _state() internal view returns (bytes32 result) {
        result = keccak256(
            abi.encode(
                _poolState(key),
                _poolState(lpKey),
                hook.roundingReserve(key.currency0),
                hook.roundingReserve(key.currency1)
            )
        );
        address[4] memory tokens = [a, b, fwA, fwB];
        address[6] memory accounts = [address(this), address(pm), address(hook), address(router), fwA, fwB];
        for (uint256 i; i < tokens.length; ++i) {
            for (uint256 j; j < accounts.length; ++j) {
                result = keccak256(abi.encode(result, IERC20(tokens[i]).balanceOf(accounts[j])));
            }
        }
    }

    function _assertSettled() internal view {
        assertFalse(pm.isUnlocked());
        assertEq(pm.getNonzeroDeltaCount(), 0);
        address[4] memory tokens = [a, b, fwA, fwB];
        for (uint256 i; i < tokens.length; ++i) {
            assertEq(pm.currencyDelta(address(hook), Currency.wrap(tokens[i])), 0);
            assertEq(pm.currencyDelta(address(router), Currency.wrap(tokens[i])), 0);
            assertEq(IERC20(tokens[i]).balanceOf(address(router)), 0);
        }
        assertEq(IERC20(fwA).balanceOf(address(hook)), donated[2]);
        assertEq(IERC20(fwB).balanceOf(address(hook)), donated[3]);
        assertEq(IERC20(a).balanceOf(address(hook)), hook.roundingReserve(key.currency0) + donated[0]);
        assertEq(IERC20(b).balanceOf(address(hook)), hook.roundingReserve(key.currency1) + donated[1]);
        assertEq(IERC20(a).allowance(address(hook), fwA), 0);
        assertEq(IERC20(b).allowance(address(hook), fwB), 0);
        assertEq(pm.getLiquidity(key.toId()), BASE_LIQUIDITY);
        (uint128 base,,) = pm.getPositionInfo(
            key.toId(), address(lp), TickMath.minUsableTick(key.tickSpacing), TickMath.maxUsableTick(key.tickSpacing), 0
        );
        assertEq(base, BASE_LIQUIDITY);
    }

    function _assertSwapEvents(RingLPPlanner.Plan memory p) internal view {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 modifications;
        uint256 backendSwaps;
        int256 netLiquidity;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(pm) || logs[i].topics.length < 2) continue;
            if (
                logs[i].topics[0] == keccak256("ModifyLiquidity(bytes32,address,int24,int24,int256,bytes32)")
                    && logs[i].topics[1] == PoolId.unwrap(key.toId())
            ) {
                (int24 lower, int24 upper, int256 change, bytes32 salt) =
                    abi.decode(logs[i].data, (int24, int24, int256, bytes32));
                assertEq(lower, p.lower);
                assertEq(upper, p.upper);
                assertEq(uint256(change < 0 ? -change : change), p.liquidity);
                (uint128 remaining,,) = pm.getPositionInfo(key.toId(), address(hook), lower, upper, salt);
                assertEq(remaining, 0);
                netLiquidity += change;
                ++modifications;
            }
            if (
                logs[i].topics[0] == keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)")
                    && logs[i].topics[1] == PoolId.unwrap(lpKey.toId())
            ) ++backendSwaps;
        }
        assertEq(modifications, p.liquidity == 0 ? 0 : 2);
        assertEq(backendSwaps, p.liquidity == 0 ? 0 : 1);
        assertEq(netLiquidity, 0);
    }

    struct TradeSnapshot {
        uint256 userIn;
        uint256 userOut;
        uint256 reserve0;
        uint256 reserve1;
        uint256 backendIn;
        uint256 backendOut;
        bytes32 backendState;
    }

    function _tradeSnapshot(bool forward) internal view returns (TradeSnapshot memory s) {
        s.userIn = IERC20(forward ? a : b).balanceOf(address(this));
        s.userOut = IERC20(forward ? b : a).balanceOf(address(this));
        s.reserve0 = hook.roundingReserve(key.currency0);
        s.reserve1 = hook.roundingReserve(key.currency1);
        s.backendIn = IERC20(forward ? fwA : fwB).balanceOf(address(pm));
        s.backendOut = IERC20(forward ? fwB : fwA).balanceOf(address(pm));
        s.backendState = _poolState(lpKey);
    }

    function _trade(bool forward, bool exactInput, uint256 size) internal {
        int256 specified = exactInput ? -int256(size) : int256(size);
        bytes32 beforeQuote = _state();
        (uint256 ringIn, uint256 ringOut, RingLPPlanner.Plan memory p) = hook.quote(key, forward, specified);
        assertEq(_state(), beforeQuote, "quote mutated state");
        assertEq(ringIn == 0, ringOut == 0);
        assertEq(p.liquidity == 0, ringIn == 0);
        assertEq(exactInput ? p.amountIn : p.amountOut, size);
        TradeSnapshot memory s = _tradeSnapshot(forward);
        vm.recordLogs();
        BalanceDelta delta =
            router.swap(key, _params(forward, specified), exactInput ? p.amountOut : p.amountIn, block.timestamp);
        _assertSwapEvents(p);
        assertEq(int256(forward ? delta.amount0() : delta.amount1()), -int256(p.amountIn));
        assertEq(int256(forward ? delta.amount1() : delta.amount0()), int256(p.amountOut));
        assertEq(s.userIn - IERC20(forward ? a : b).balanceOf(address(this)), p.amountIn);
        assertEq(IERC20(forward ? b : a).balanceOf(address(this)) - s.userOut, p.amountOut);
        assertEq(IERC20(forward ? fwA : fwB).balanceOf(address(pm)) - s.backendIn, ringIn);
        assertEq(s.backendOut - IERC20(forward ? fwB : fwA).balanceOf(address(pm)), ringOut);
        assertLe(s.reserve0 - hook.roundingReserve(key.currency0), 8);
        assertLe(s.reserve1 - hook.roundingReserve(key.currency1), 8);
        (uint160 end,,,) = pm.getSlot0(key.toId());
        assertEq(end, p.end);
        if (p.liquidity == 0) assertEq(_poolState(lpKey), s.backendState);
        else assertNotEq(_poolState(lpKey), s.backendState);
        _assertSettled();
    }

    function _expectHookError(bytes4 reason) internal {
        vm.expectRevert(
            abi.encodeWithSignature(
                "WrappedError(address,bytes4,bytes,bytes)",
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodePacked(reason),
                abi.encodePacked(Hooks.HookCallFailed.selector)
            )
        );
    }

    function test_DefensiveWrapperReturnAndBalanceMismatchesRollback() public {
        (DefensiveFewWrappedToken input, DefensiveFewWrappedToken output) = _defensiveWrappers();
        (,, RingLPPlanner.Plan memory p) = hook.quote(key, true, -int256(1 ether));
        assertGt(p.liquidity, 0);
        for (uint8 mode = 1; mode <= 3; ++mode) {
            for (uint256 side; side < 2; ++side) {
                input.setModes(side == 0 ? mode : 0, 0);
                output.setModes(0, side == 1 ? mode : 0);
                bytes32 beforeState = _state();
                uint256 supplyA = input.totalSupply();
                uint256 supplyB = output.totalSupply();
                _expectHookError(RingV4JitHook.UnexpectedTokenDelta.selector);
                router.swap(key, _params(true, -int256(1 ether)), p.amountOut, block.timestamp);
                assertEq(_state(), beforeState);
                assertEq(input.totalSupply(), supplyA);
                assertEq(output.totalSupply(), supplyB);
                _assertSettled();
                input.setModes(0, 0);
                output.setModes(0, 0);
            }
        }
        _trade(true, true, 1 ether);
    }

    function test_DefensiveWrapperCallbacksCannotReenterPoolRouterOrOwnerActions() public {
        (DefensiveFewWrappedToken input, DefensiveFewWrappedToken output) = _defensiveWrappers();
        for (uint256 side; side < 2; ++side) {
            for (uint256 action; action < 4; ++action) {
                uint256 snapshot = vm.snapshotState();
                DefensiveFewWrappedToken caller = side == 0 ? input : output;
                address target;
                bytes memory data;
                if (action == 0) {
                    target = address(pm);
                    data = abi.encodeCall(pm.swap, (key, _params(true, -int256(1 ether)), bytes("")));
                } else if (action == 1) {
                    target = address(router);
                    data = abi.encodeCall(router.swap, (key, _params(true, -int256(1 ether)), 1, block.timestamp));
                } else {
                    hook.transferOwnership(address(caller));
                    caller.execute(address(hook), abi.encodeCall(hook.acceptOwnership, ()));
                    assertEq(hook.owner(), address(caller));
                    target = address(hook);
                    if (action == 2) {
                        PoolKey memory empty;
                        data = abi.encodeCall(hook.setLpPool, (key, empty));
                    } else {
                        data = abi.encodeCall(hook.withdrawRounding, (key.currency0, uint256(100), address(caller)));
                    }
                }
                caller.setCallback(target, data, side == 1, false);
                (,, RingLPPlanner.Plan memory p) = hook.quote(key, true, -int256(1 ether));
                assertGt(p.liquidity, 0);
                _trade(true, true, 1 ether);
                assertEq(caller.callbackAttempts(), 1);
                assertEq(caller.callbackSuccesses(), 0);
                assertTrue(hook.getLpPool(key).set);
                assertTrue(vm.revertToState(snapshot));
            }
        }
    }

    function test_DefensiveBackendMutationDuringWrapRejectsExactFillMismatch() public {
        (DefensiveFewWrappedToken input,) = _defensiveWrappers();
        for (uint256 action; action < 2; ++action) {
            uint256 snapshot = vm.snapshotState();
            bytes memory data;
            if (action == 0) {
                data = abi.encodeCall(pm.swap, (lpKey, _params(fwA < fwB, -int256(10 ether)), bytes("")));
            } else {
                data = abi.encodeCall(
                    pm.modifyLiquidity,
                    (
                        lpKey,
                        ModifyLiquidityParams(
                            TickMath.minUsableTick(lpKey.tickSpacing),
                            TickMath.maxUsableTick(lpKey.tickSpacing),
                            int256(1000 ether),
                            bytes32(uint256(71))
                        ),
                        bytes("")
                    )
                );
            }
            input.setCallback(address(pm), data, false, true);
            (,, RingLPPlanner.Plan memory p) = hook.quote(key, true, -int256(1 ether));
            assertGt(p.liquidity, 0);
            bytes32 beforeState = _state();
            _expectHookError(RingV4JitHook.UnexpectedFill.selector);
            router.swap(key, _params(true, -int256(1 ether)), p.amountOut, block.timestamp);
            assertEq(_state(), beforeState);
            assertEq(input.callbackAttempts(), 0);
            assertEq(pm.currencyDelta(address(input), lpKey.currency0), 0);
            assertEq(pm.currencyDelta(address(input), lpKey.currency1), 0);
            (uint128 mutatedPosition,,) = pm.getPositionInfo(
                lpKey.toId(),
                address(input),
                TickMath.minUsableTick(lpKey.tickSpacing),
                TickMath.maxUsableTick(lpKey.tickSpacing),
                bytes32(uint256(71))
            );
            assertEq(mutatedPosition, 0);
            _assertSettled();
            assertTrue(vm.revertToState(snapshot));
        }
        _trade(true, true, 1 ether);
    }

    function test_DefensiveDonationsPreservedAcrossAllModes() public {
        address donor = address(0xd010);
        address[4] memory tokens = [a, b, fwA, fwB];
        for (uint256 i; i < tokens.length; ++i) {
            donated[i] = (i + 1) * 1 ether;
            IERC20(tokens[i]).transfer(donor, donated[i] + 123);
            vm.prank(donor);
            IERC20(tokens[i]).transfer(address(hook), donated[i]);
        }
        uint256 reserve0 = hook.roundingReserve(key.currency0);
        uint256 reserve1 = hook.roundingReserve(key.currency1);
        (,, RingLPPlanner.Plan memory p) = hook.quote(key, true, -int256(1 ether));
        assertGt(p.liquidity, 0);
        _trade(true, true, 1 ether);
        _trade(false, true, 1 ether);
        _trade(true, false, 1 ether);
        _trade(false, false, 1 ether);
        assertLe(reserve0 - hook.roundingReserve(key.currency0), 32);
        assertLe(reserve1 - hook.roundingReserve(key.currency1), 32);
        for (uint256 i; i < tokens.length; ++i) {
            assertEq(IERC20(tokens[i]).balanceOf(donor), 123);
        }
    }

    function test_AlignedFourModesAndRealBackendSwap() public {
        assertTrue(hook.getLpPool(key).orderAligned);
        (uint256 ringIn, uint256 ringOut, RingLPPlanner.Plan memory p) = hook.quote(key, true, -int256(1 ether));
        assertGt(p.liquidity, 0);
        assertGt(ringIn, 0);
        assertGt(ringOut, 0);
        _trade(true, true, 1 ether);
        _trade(false, true, 1 ether);
        _trade(true, false, 1 ether);
        _trade(false, false, 1 ether);
    }

    function test_InvertedFourModesAndRealBackendSwap() public {
        _fixture(false);
        assertFalse(hook.getLpPool(key).orderAligned);
        (,, RingLPPlanner.Plan memory p) = hook.quote(key, true, -int256(1 ether));
        assertGt(p.liquidity, 0);
        _trade(true, true, 1 ether);
        _trade(false, true, 1 ether);
        _trade(true, false, 1 ether);
        _trade(false, false, 1 ether);
    }

    function testFuzz_TradeModesClear(bool forward, bool exactInput, uint64 raw) public {
        _trade(forward, exactInput, bound(uint256(raw), 1e6, 10 ether));
    }

    function test_ReverseExactInputAndOutputUseRealBackend() public {
        uint256 snapshot = vm.snapshotState();
        (,, RingLPPlanner.Plan memory p) = hook.quote(key, false, -int256(1 ether));
        assertGt(p.liquidity, 0);
        _trade(false, true, 1 ether);
        assertTrue(vm.revertToState(snapshot));
        (,, p) = hook.quote(key, false, int256(1 ether));
        assertGt(p.liquidity, 0);
        _trade(false, false, 1 ether);
    }

    function test_BackendDirectionalProtocolFeesIncludedInJIT() public {
        manager.setProtocolFeeController(address(this));
        manager.setProtocolFee(lpKey, uint24(500 | (1000 << 12)));
        (,, RingLPPlanner.Plan memory p) = hook.quote(key, true, -int256(1 ether));
        assertGt(p.liquidity, 0);
        _trade(true, true, 1 ether);
        _trade(false, false, 1 ether);
    }

    function test_RepeatedSwapsClearJITAndPreserveBase() public {
        for (uint256 i; i < 8; ++i) {
            _trade(i % 2 == 0, i % 3 == 0, 1 ether);
        }
    }

    function test_PermissionsAndConstants() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize && p.beforeSwap && p.afterSwap);
        assertFalse(p.beforeAddLiquidity || p.beforeRemoveLiquidity);
        assertFalse(p.beforeSwapReturnDelta || p.afterSwapReturnDelta);
        assertEq(uint160(address(hook)) & 0x3fff, 0x20c0);
        assertEq(hook.MAX_ROUNDING_LOSS(), 8);
        assertEq(hook.MAX_SPOT_DEVIATION_BPS(), 500);
    }

    function test_OwnerRouteReplacementRemovalAndBatch() public {
        PoolKey memory replacement = _backendKey(500, 10);
        pm.initialize(replacement, Q96);
        _fullRange(replacement, int256(uint256(BACKEND_LIQUIDITY)));
        hook.setLpPool(key, replacement);
        assertEq(PoolId.unwrap(hook.getLpPool(key).lpPoolKey.toId()), PoolId.unwrap(replacement.toId()));
        lpKey = replacement;
        _trade(true, true, 1 ether);
        PoolKey memory empty;
        hook.setLpPool(key, empty);
        assertFalse(hook.getLpPool(key).set);
        assertEq(hook.getIndicativeQuote(key, true, -int256(1 ether), ""), 0);
        vm.expectRevert();
        hook.quote(key, true, -int256(1 ether));
        bytes32 beforeState = _state();
        vm.expectRevert();
        router.swap(key, _params(true, -int256(1 ether)), 1, block.timestamp);
        assertEq(_state(), beforeState);
        hook.setLpPool(key, replacement);
        assertTrue(hook.getLpPool(key).set);
    }

    function test_NativeBackendCurrencyZeroRemovesWithoutRouteInference() public {
        PoolKey memory nativeRoute = lpKey;
        nativeRoute.currency0 = Currency.wrap(address(0));
        hook.setLpPool(key, nativeRoute);
        assertFalse(hook.getLpPool(key).set);
        bytes32 beforeState = _state();
        vm.expectRevert();
        hook.quote(key, true, -int256(1 ether));
        vm.expectRevert();
        router.swap(key, _params(true, -int256(1 ether)), 1, block.timestamp);
        assertEq(_state(), beforeState);
    }

    function test_CanonicalFactoryMutationInvalidatesConfiguredRoute() public {
        few.setWrapped(a, address(new MockFewWrappedToken(a)));
        bytes32 beforeState = _state();
        vm.expectRevert();
        hook.quote(key, true, -int256(1 ether));
        vm.expectRevert();
        router.swap(key, _params(true, -int256(1 ether)), 1, block.timestamp);
        assertEq(_state(), beforeState);
    }

    function test_AdministrationUnauthorized() public {
        address outsider = address(0xbeef);
        vm.startPrank(outsider);
        vm.expectRevert();
        hook.setLpPool(key, lpKey);
        vm.expectRevert();
        hook.fundRounding(key.currency0, 1);
        vm.expectRevert();
        hook.withdrawRounding(key.currency0, 1, outsider);
        vm.stopPrank();
        vm.expectRevert();
        hook.renounceOwnership();
        vm.expectRevert();
        router.unlockCallback("");
    }

    function test_InvalidPoolRollsBackWithoutAffectingExistingRoute() public {
        PoolKey memory bad = key;
        bad.tickSpacing = 1;
        vm.expectRevert();
        hook.setLpPool(bad, lpKey);
        assertTrue(hook.getLpPool(key).set);
        assertEq(PoolId.unwrap(hook.getLpPool(key).lpPoolKey.toId()), PoolId.unwrap(lpKey.toId()));
    }

    function test_InitializeRejectsNativeAndDuplicatePool() public {
        MockFewFactory otherFew = new MockFewFactory();
        bytes memory args = abi.encode(pm, otherFew, address(this));
        (bytes32 salt,) = HookMiner.mine(address(this), type(RingV4JitHook).creationCode, args, 0x20c0, 10_000_000);
        RingV4JitHook other = new RingV4JitHook{salt: salt}(pm, otherFew, address(this));
        PoolKey memory candidate = key;
        candidate.hooks = IHooks(address(other));
        candidate.currency0 = Currency.wrap(address(0));
        vm.expectRevert();
        pm.initialize(candidate, Q96);
        candidate.currency0 = key.currency0;
        pm.initialize(candidate, Q96);
        assertFalse(other.getLpPool(candidate).set);
        vm.expectRevert();
        pm.initialize(candidate, Q96);
        vm.expectRevert();
        pm.initialize(key, Q96);
    }

    function test_UninitializedHookedDynamicNativeAndUnsortedRoutesRejected() public {
        PoolKey memory bad = _backendKey(500, 10);
        vm.expectRevert();
        hook.setLpPool(key, bad);
        bad = lpKey;
        bad.hooks = IHooks(address(hook));
        vm.expectRevert();
        hook.setLpPool(key, bad);
        bad = lpKey;
        bad.fee = 0x800000;
        vm.expectRevert();
        hook.setLpPool(key, bad);
        bad.fee = 1_000_000;
        vm.expectRevert();
        hook.setLpPool(key, bad);
        bad = lpKey;
        (bad.currency0, bad.currency1) = (bad.currency1, bad.currency0);
        vm.expectRevert();
        hook.setLpPool(key, bad);
        bad = lpKey;
        bad.currency1 = Currency.wrap(address(0));
        vm.expectRevert();
        hook.setLpPool(key, bad);
        PoolKey memory other = key;
        other.currency0 = Currency.wrap(address(0));
        vm.expectRevert();
        hook.setLpPool(other, lpKey);
        other = key;
        other.tickSpacing = 10;
        vm.expectRevert();
        hook.setLpPool(other, lpKey);
        assertEq(PoolId.unwrap(hook.getLpPool(key).lpPoolKey.toId()), PoolId.unwrap(lpKey.toId()));
    }

    function test_WrongUnderlyingNoncanonicalAndRawOverlapRejected() public {
        address c = address(new MockERC20("C", "C", 18));
        address fwC = address(few.create(c));
        PoolKey memory bad = PoolKey(
            Currency.wrap(fwA < fwC ? fwA : fwC), Currency.wrap(fwA < fwC ? fwC : fwA), 3000, 60, IHooks(address(0))
        );
        pm.initialize(bad, Q96);
        vm.expectRevert();
        hook.setLpPool(key, bad);
        few.setWrapped(b, fwC);
        vm.expectRevert();
        hook.setLpPool(key, bad);
        few.setWrapped(b, address(new MockFewWrappedToken(b)));
        vm.expectRevert();
        hook.setLpPool(key, lpKey);
        few.setWrapped(b, fwB);
        bad = PoolKey(key.currency0, key.currency1, 3000, 60, IHooks(address(0)));
        pm.initialize(bad, Q96);
        few.setWrapped(a, a);
        few.setWrapped(b, b);
        vm.expectRevert();
        hook.setLpPool(key, bad);
    }

    function test_EmptyBackendFallsBackWithoutPartialBackendExecution() public {
        _fullRange(lpKey, -int256(uint256(BACKEND_LIQUIDITY)));
        (uint256 ringIn, uint256 ringOut, RingLPPlanner.Plan memory p) = hook.quote(key, true, -int256(1 ether));
        assertEq(p.liquidity, 0);
        assertEq(ringIn, 0);
        assertEq(ringOut, 0);
        _trade(true, true, 1 ether);
    }

    function test_SlippageRollsBackBothPoolsAndReserves() public {
        (,, RingLPPlanner.Plan memory p) = hook.quote(key, true, -int256(1 ether));
        assertGt(p.liquidity, 0);
        bytes32 beforeState = _state();
        vm.expectRevert(RingLPRouter.SlippageExceeded.selector);
        router.swap(key, _params(true, -int256(1 ether)), p.amountOut + 1, block.timestamp);
        assertEq(_state(), beforeState);
        _assertSettled();
    }

    function test_PartialOuterFillRollsBackBothPoolsAndReserves() public {
        bytes32 beforeState = _state();
        vm.expectRevert();
        router.swap(key, SwapParams(true, -int256(1 ether), Q96 - 1), 1, block.timestamp);
        assertEq(_state(), beforeState);
        _assertSettled();
    }

    function test_InsufficientBackendDepthCannotPartiallyFillPromisedQuote() public {
        (,, RingLPPlanner.Plan memory promised) = hook.quote(key, true, -int256(10 ether));
        assertGt(promised.liquidity, 0);
        _fullRange(lpKey, -int256(uint256(BACKEND_LIQUIDITY)));
        _range(lpKey, -60, 60, 100 ether);
        bytes32 beforeState = _state();
        vm.expectRevert();
        router.swap(key, _params(true, -int256(10 ether)), promised.amountOut, block.timestamp);
        assertEq(_state(), beforeState);
        _assertSettled();
    }

    function test_UnfundedBackendRollsBackBothPoolsAndReserves() public {
        (,, RingLPPlanner.Plan memory p) = hook.quote(key, true, -int256(1 ether));
        assertGt(p.liquidity, 0);
        uint256 backendBalance = IERC20(fwB).balanceOf(address(pm));
        vm.prank(address(pm));
        IERC20(fwB).transfer(address(this), backendBalance);
        bytes32 beforeState = _state();
        vm.expectRevert();
        router.swap(key, _params(true, -int256(1 ether)), 1, block.timestamp);
        assertEq(_state(), beforeState);
        _assertSettled();
    }

    function test_UnfundedWrapperRollsBackBackendSwapAndOuterJIT() public {
        (,, RingLPPlanner.Plan memory p) = hook.quote(key, true, -int256(1 ether));
        assertGt(p.liquidity, 0);
        uint256 backingBalance = IERC20(b).balanceOf(fwB);
        vm.prank(fwB);
        IERC20(b).transfer(address(this), backingBalance);
        bytes32 beforeState = _state();
        vm.expectRevert();
        router.swap(key, _params(true, -int256(1 ether)), 1, block.timestamp);
        assertEq(_state(), beforeState);
        _assertSettled();
    }

    function test_ExactOutputRefundsUnusedBudget() public {
        (,, RingLPPlanner.Plan memory p) = hook.quote(key, true, int256(1 ether));
        uint256 beforeBalance = IERC20(a).balanceOf(address(this));
        router.swap(key, _params(true, int256(1 ether)), p.amountIn + 1 ether, block.timestamp);
        assertEq(beforeBalance - IERC20(a).balanceOf(address(this)), p.amountIn);
        _assertSettled();
    }

    function test_ExternalBackendTradeInvalidatesStaleQuoteAtomically() public {
        (,, RingLPPlanner.Plan memory old) = hook.quote(key, true, -int256(1 ether));
        _backendSwap(fwA < fwB, -int256(100 ether));
        (,, RingLPPlanner.Plan memory fresh) = hook.quote(key, true, -int256(1 ether));
        assertLt(fresh.amountOut, old.amountOut);
        bytes32 beforeState = _state();
        vm.expectRevert();
        router.swap(key, _params(true, -int256(1 ether)), old.amountOut, block.timestamp);
        assertEq(_state(), beforeState);
        _trade(true, true, 1 ether);
    }

    function _syncTo(uint160 target) internal {
        (uint160 start,,,) = pm.getSlot0(key.toId());
        bool forward = target < start;
        uint256 amount = forward
            ? SqrtPriceMath.getAmount0Delta(target, start, BASE_LIQUIDITY, true)
            : SqrtPriceMath.getAmount1Delta(start, target, BASE_LIQUIDITY, true);
        bytes32 backendBefore = _poolState(lpKey);
        uint256 reserve0 = hook.roundingReserve(key.currency0);
        uint256 reserve1 = hook.roundingReserve(key.currency1);
        router.syncPrice(key, SwapParams(forward, -int256(amount), target), 1, block.timestamp);
        assertEq(_poolState(lpKey), backendBefore);
        assertLe(reserve0 - hook.roundingReserve(key.currency0), 8);
        assertLe(reserve1 - hook.roundingReserve(key.currency1), 8);
        _assertSettled();
    }

    function test_DeviationGuardAndBaseOnlySync() public {
        _backendSwap(fwA < fwB, -int256(1000 ether));
        (uint256 deviation, uint256 allowed) = hook.getSpotDeviationBps(key, true);
        assertGt(deviation, allowed);
        assertEq(hook.getIndicativeQuote(key, true, -int256(1 ether), ""), 0);
        vm.expectRevert();
        hook.quote(key, true, -int256(1 ether));
        (uint160 backendPrice,,,) = pm.getSlot0(lpKey.toId());
        _syncTo(fwA < fwB ? backendPrice : uint160((uint256(1) << 192) / backendPrice));
        (deviation, allowed) = hook.getSpotDeviationBps(key, true);
        assertLe(deviation, allowed);
        _trade(true, true, 1 ether);
    }

    function test_BufferGuards() public {
        hook.withdrawRounding(key.currency0, 999_990, address(this));
        assertEq(hook.getIndicativeQuote(key, true, -int256(1 ether), ""), 0);
        vm.expectRevert();
        router.swap(key, _params(true, -int256(1 ether)), 1, block.timestamp);
        hook.fundRounding(key.currency0, 999_990);
    }

    function test_BackendTickCrossingWithFeesUsesJIT() public {
        _fullRange(lpKey, -int256(uint256(BACKEND_LIQUIDITY)));
        _fullRange(lpKey, 1000 ether);
        _range(lpKey, -60, 60, 100 ether);
        (,, RingLPPlanner.Plan memory p) = hook.quote(key, true, -int256(10 ether));
        assertGt(p.liquidity, 0);
        _trade(true, true, 10 ether);
        (, int24 tick,,) = pm.getSlot0(lpKey.toId());
        assertLt(tick, -60);
        (uint256 fees0, uint256 fees1) = pm.getFeeGrowthGlobals(lpKey.toId());
        assertGt(fees0 + fees1, 0);
        assertEq(pm.getLiquidity(lpKey.toId()), 1000 ether);
    }

    function _compareQuote(bool forward, int256 specified) internal {
        bytes32 beforeState = _state();
        (uint256 amountIn, uint256 amountOut, uint160 end) = quoter.quote(pm, lpKey, forward, specified);
        assertEq(_state(), beforeState);
        BalanceDelta delta = _backendSwap(forward, specified);
        assertEq(-int256(forward ? delta.amount0() : delta.amount1()), int256(amountIn));
        assertEq(int256(forward ? delta.amount1() : delta.amount0()), int256(amountOut));
        assertEq(specified < 0 ? amountIn : amountOut, uint256(specified < 0 ? -specified : specified));
        (uint160 actual,,,) = pm.getSlot0(lpKey.toId());
        assertEq(actual, end);
        assertEq(pm.getNonzeroDeltaCount(), 0);
    }

    function _compareFourModes(uint256 amount) internal {
        for (uint256 i; i < 4; ++i) {
            uint256 snapshot = vm.snapshotState();
            _compareQuote(i < 2, i % 2 == 0 ? -int256(amount) : int256(amount));
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function test_QuoterFourModesWithDirectionalProtocolFees() public {
        manager.setProtocolFeeController(address(this));
        manager.setProtocolFee(lpKey, uint24(500 | (1000 << 12)));
        _compareFourModes(10 ether);
    }

    function test_QuoterInitializedBoundaryStoredTickDiffersFromPrice() public {
        _range(lpKey, -60, 60, 1000 ether);
        backendRouter.swap(
            lpKey,
            SwapParams(true, -int256(100 ether), TickMath.getSqrtPriceAtTick(-60)),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        (uint160 price, int24 tick,,) = pm.getSlot0(lpKey.toId());
        assertEq(price, TickMath.getSqrtPriceAtTick(-60));
        assertEq(tick, -61);
        _compareFourModes(1 ether);
    }

    function test_QuoterMultipleRangesAndGapAllModes() public {
        _fullRange(lpKey, -int256(uint256(BACKEND_LIQUIDITY)));
        _range(lpKey, -60, 60, 100 ether);
        _range(lpKey, -600, -120, 1000 ether);
        _range(lpKey, 120, 600, 1000 ether);
        _compareFourModes(5 ether);
    }

    function test_QuoterRejectsInsufficientDepthInAllModes() public {
        _fullRange(lpKey, -int256(uint256(BACKEND_LIQUIDITY)));
        _range(lpKey, -60, 60, 100 ether);
        for (uint256 i; i < 4; ++i) {
            bytes32 beforeState = _state();
            vm.expectRevert();
            quoter.quote(pm, lpKey, i < 2, i % 2 == 0 ? -int256(10 ether) : int256(10 ether));
            assertEq(_state(), beforeState);
        }
    }
}
