// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {SIMDTESTHook} from "../src/SIMDTESTHook.sol";
import {SIMDTESTRouter} from "../src/SIMDTESTRouter.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

contract HookTest is HookFixture {
    using StateLibrary for IPoolManager;

    function setUp() public {
        _localSetup();
    }

    function test_thresholdAndDeferredClaims() public {
        _swap(alice, true, -int256(10 ether - 1));
        assertEq(hook.pending(alice), 0);
        _swap(alice, true, -10 ether);
        assertEq(hook.pending(alice), 0.1 ether);
        uint256 before = pair.balanceOf(alice);
        _swap(alice, true, -20 ether);
        assertEq(pair.balanceOf(alice), before - 20 ether, "swap paid a reward");
        assertEq(hook.pending(alice), 0.3 ether);
        assertEq(hook.owedTotal(), 0.3 ether);
        before = pair.balanceOf(alice);
        vm.prank(alice);
        assertEq(hook.claimRewards(), 0.3 ether);
        assertEq(pair.balanceOf(alice), before + 0.3 ether);
        assertEq(hook.owedTotal(), 0);
        vm.prank(alice);
        assertEq(hook.claimRewards(), 0);
        _assertSettled();
    }

    function test_payRecordedCannotRedirect() public {
        _swap(alice, true, -100 ether);
        uint256 a = pair.balanceOf(alice);
        uint256 b = pair.balanceOf(bob);
        vm.prank(bob);
        assertEq(hook.payRecorded(alice), 1 ether);
        assertEq(pair.balanceOf(alice), a + 1 ether);
        assertEq(pair.balanceOf(bob), b);
        assertEq(hook.pending(alice), 0);
        assertEq(hook.payRecorded(alice), 0);
        assertEq(hook.payRecorded(address(0)), 0);
    }

    function test_allFourSwapModes() public {
        uint256 assets = _assets();
        _swap(alice, true, -100 ether);
        assertEq(_assets() - assets, 2 ether);
        assertEq(hook.pending(alice), 1 ether);
        assets = _assets();
        uint256 priorReward = hook.pending(alice);
        BalanceDelta d = _swap(alice, true, 100 ether);
        uint256 spent = uint256(-int256(_pairDelta(d)));
        uint256 fee = _assets() - assets;
        assertEq(fee, (spent - fee) / 50);
        assertEq(hook.pending(alice) - priorReward, spent / 100);
        priorReward = hook.pending(alice);
        assets = _assets();
        d = _swap(alice, false, -100 ether);
        uint256 received = uint128(_pairDelta(d));
        fee = _assets() - assets;
        assertEq(fee, (received + fee) / 50);
        assertEq(hook.pending(alice), priorReward);
        assets = _assets();
        d = _swap(alice, false, 100 ether);
        assertEq(_pairDelta(d), 100 ether);
        fee = _assets() - assets;
        assertEq(fee, uint256(100 ether) / 49);
        assertEq(fee, (100 ether + fee) / 50);
        assertEq(hook.pending(alice), priorReward);
        (,,, uint24 lpFee) = manager.getSlot0(key.toId());
        assertEq(lpFee, 12500);
        _assertSettled();
    }

    function test_untrustedRouterCannotSpoofBuyerAndStillSwaps() public {
        vm.prank(bob);
        otherRouter.swap(
            key,
            SwapParams(IMD < address(token), -100 ether, _limit(true)),
            PoolSwapTest.TestSettings(false, false),
            abi.encode(alice)
        );
        assertEq(hook.pending(alice), 0);
        assertEq(hook.pending(bob), 0);
        assertEq(hook.owedTotal(), 0);
        assertEq(_assets(), 2 ether);
        _assertSettled();
    }

    function test_malformedHookDataNeverBlocksOtherRouter() public {
        vm.prank(alice);
        otherRouter.swap(
            key,
            SwapParams(IMD < address(token), -20 ether, _limit(true)),
            PoolSwapTest.TestSettings(false, false),
            hex"ff"
        );
        assertEq(hook.owedTotal(), 0);
        assertEq(_assets(), 0.4 ether);
    }

    function test_permissionsAndSize() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        Hooks.validateHookPermissions(IHooks(address(hook)), p);
        assertEq(HookFlags.flagsOf(address(hook)), 0x20cc);
        assertLe(type(SIMDTESTHook).creationCode.length + 64, 49152);
        assertLe(address(hook).code.length, 24576);
        _scan(address(hook).code);
        _scan(address(token).code);
        _scan(address(router).code);
    }

    function _scan(bytes memory runtime) internal pure {
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            require(op != 0xff && op != 0xf4 && op != 0xf2, "forbidden opcode");
        }
    }

    function test_allCallbacksRestricted() public {
        SwapParams memory p = SwapParams(true, -1 ether, _limit(true));
        vm.expectRevert(SIMDTESTHook.OnlyPoolManager.selector);
        hook.beforeInitialize(alice, key, Q96);
        vm.expectRevert(SIMDTESTHook.OnlyPoolManager.selector);
        hook.beforeSwap(alice, key, p, "");
        vm.expectRevert(SIMDTESTHook.OnlyPoolManager.selector);
        hook.afterSwap(alice, key, p, BalanceDeltaLibrary.ZERO_DELTA, "");
        vm.expectRevert(SIMDTESTHook.OnlyPoolManager.selector);
        hook.unlockCallback("");
        vm.expectRevert(SIMDTESTRouter.UnauthorizedCallback.selector);
        router.unlockCallback("");
        vm.prank(address(manager));
        vm.expectRevert(SIMDTESTRouter.UnauthorizedCallback.selector);
        router.unlockCallback("");
    }

    function test_wrongPoolCannotInitialize() public {
        PoolKey memory wrong = key;
        wrong.fee = 3000;
        vm.expectRevert();
        manager.initialize(wrong, Q96);
        wrong.fee = 0x800000;
        vm.expectRevert();
        manager.initialize(wrong, Q96);
    }

    function test_routerSlippageAndDeadlineRollback() public {
        uint256 before = pair.balanceOf(alice);
        vm.startPrank(alice);
        vm.expectRevert(SIMDTESTRouter.Slippage.selector);
        router.swap(true, -100 ether, 100 ether, 101 ether, _limit(true), block.timestamp);
        vm.expectRevert(SIMDTESTRouter.Slippage.selector);
        router.swap(true, 100 ether, 1 ether, 0, _limit(true), block.timestamp);
        vm.expectRevert(SIMDTESTRouter.Expired.selector);
        router.swap(true, -100 ether, 100 ether, 0, _limit(true), block.timestamp - 1);
        vm.stopPrank();
        assertEq(pair.balanceOf(alice), before);
        assertEq(hook.owedTotal(), 0);
        assertEq(_assets(), 0);
    }

    function test_routerCannotSpendAnApprovedVictim() public {
        uint256 before = pair.balanceOf(alice);
        // There is no payer/recipient parameter; Bob cannot use Alice's approval or output.
        _swap(bob, true, -100 ether);
        assertEq(pair.balanceOf(alice), before);
        assertEq(hook.pending(alice), 0);
        assertEq(hook.pending(bob), 1 ether);
    }

    function test_tinyTradeRounding() public {
        _swap(alice, true, -1);
        assertEq(hook.owedTotal(), 0);
        assertEq(_assets(), 0);
        _assertSettled();
    }

    function test_partialInputFeeUsesActualFill() public {
        uint160 limit = TickMath.getSqrtPriceAtTick(IMD < address(token) ? int24(-1) : int24(1));
        uint256 before = pair.balanceOf(alice);
        vm.prank(alice);
        BalanceDelta d = router.swap(true, -100_000 ether, 100_000 ether, 1, limit, block.timestamp);
        uint256 spent = uint256(-int256(_pairDelta(d)));
        assertLt(spent, 100_000 ether);
        assertEq(before - pair.balanceOf(alice), spent);
        assertEq(_assets(), spent / 50);
        assertEq(hook.pending(alice), spent / 100);
        _assertSettled();
    }

    function test_partialOutputSellDoesNotOverchargeOrRevert() public {
        // An arbitrary router may allow partial exact output; its fee must follow the actual fill.
        uint160 limit = TickMath.getSqrtPriceAtTick(IMD < address(token) ? int24(1) : int24(-1));
        uint256 before = pair.balanceOf(alice);
        vm.prank(alice);
        BalanceDelta d = otherRouter.swap(
            key,
            SwapParams(IMD > address(token), 100_000 ether, limit),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        uint256 received = uint128(_pairDelta(d));
        assertGt(received, 0);
        assertLt(received, 100_000 ether);
        assertEq(pair.balanceOf(alice) - before, received);
        assertEq(_assets(), (received + _assets()) / 50);
        assertEq(hook.owedTotal(), 0);
        _assertSettled();
    }

    function test_partialFillBelowThresholdDoesNotEarnReward() public {
        liquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(-600, 600, -9_999_000 ether, 0), "");
        uint160 limit = TickMath.getSqrtPriceAtTick(IMD < address(token) ? int24(-1) : int24(1));
        vm.prank(alice);
        BalanceDelta d = router.swap(true, -100_000 ether, 100_000 ether, 1, limit, block.timestamp);
        uint256 spent = uint256(-int256(_pairDelta(d)));
        assertGt(spent, 0);
        assertLt(spent, 10 ether);
        assertEq(hook.pending(alice), 0);
        assertEq(hook.owedTotal(), 0);
        assertEq(_assets(), spent / 50);
        _assertSettled();
    }

    function test_externalQuoteCannotBeUsedAsARouter() public {
        vm.expectRevert(SIMDTESTHook.OnlySelf.selector);
        hook.quoteSwap(key, SwapParams(IMD < address(token), -10 ether, _limit(true)));
    }

    /// forge-config: default.fuzz.runs = 1000
    /// forge-config: extended.fuzz.runs = 2000
    function testFuzz_feesRewardsAndClaims(uint96 raw, bool buy, bool exactInput) public virtual {
        uint256 amount = bound(raw, 1e12, 1000 ether);
        uint256 before = pair.balanceOf(alice);
        BalanceDelta d = _swap(alice, buy, exactInput ? -int256(amount) : int256(amount));
        uint256 assets = _assets();
        if (buy) {
            uint256 spent = uint256(-int256(_pairDelta(d)));
            assertEq(before - pair.balanceOf(alice), spent);
            uint256 expected = spent >= 10 ether ? spent / 100 : 0;
            assertEq(hook.pending(alice), expected);
            assertEq(assets, exactInput ? amount / 50 : (spent - assets) / 50);
            hook.payRecorded(alice);
            assertEq(pair.balanceOf(alice), before - spent + expected);
            assertEq(_assets(), assets - expected);
        } else {
            uint256 received = uint128(_pairDelta(d));
            assertEq(pair.balanceOf(alice) - before, received);
            assertEq(assets, exactInput ? (received + assets) / 50 : amount / 49);
            assertEq(hook.pending(alice), 0);
        }
        assertEq(hook.owedTotal(), 0);
        _assertSettled();
    }
}
