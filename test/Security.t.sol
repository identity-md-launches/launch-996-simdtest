// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {AdversarialIMD} from "./mocks/AdversarialIMD.sol";
import {SIMDTESTHook} from "../src/SIMDTESTHook.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract SecurityTest is HookFixture {
    function setUp() public {
        _localSetup();
    }

    function test_freshTokenOnlyPoolAccruesClaimsThenPays() public {
        manager = new PoolManager(address(this));
        hook = _deployHook(manager, address(token));
        router = hook.rewardRouter();
        key = router.poolKey();
        manager.initialize(key, Q96);
        liquidityRouter = new PoolModifyLiquidityTest(manager);
        otherRouter = new PoolSwapTest(manager);
        token.approve(address(liquidityRouter), type(uint256).max);
        int24 lower = IMD < address(token) ? int24(-600) : int24(0);
        int24 upper = IMD < address(token) ? int24(0) : int24(600);
        liquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, 10_000_000 ether, 0), "");
        assertEq(pair.balanceOf(address(manager)), 0, "one-sided pool must have no IMD");
        _fund(alice);
        _swap(alice, true, -100 ether);
        assertEq(pair.balanceOf(address(hook)), 0);
        assertEq(manager.balanceOf(address(hook), uint160(IMD)), 2 ether);
        assertEq(hook.pending(alice), 1 ether);
        uint256 before = pair.balanceOf(alice);
        vm.prank(alice);
        hook.claimRewards();
        assertEq(pair.balanceOf(alice), before + 1 ether);
        assertEq(manager.balanceOf(address(hook), uint160(IMD)), 0);
        assertEq(pair.balanceOf(address(hook)), 1 ether);
        _assertSettled();
    }

    function test_failedFeeTransferDoesNotBlockSwap() public {
        vm.etch(IMD, address(new AdversarialIMD()).code);
        AdversarialIMD(IMD).configure(address(hook), alice, true, false);
        _swap(alice, true, -100 ether);
        assertEq(pair.balanceOf(address(hook)), 0);
        assertEq(manager.balanceOf(address(hook), uint160(IMD)), 2 ether);
        assertEq(hook.pending(alice), 1 ether);
        uint256 before = pair.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert();
        hook.claimRewards();
        assertEq(pair.balanceOf(alice), before);
        assertEq(hook.pending(alice), 1 ether, "failed payout erased debt");
        assertEq(hook.owedTotal(), 1 ether);
        AdversarialIMD(IMD).configure(address(hook), alice, false, false);
        vm.prank(bob);
        assertEq(hook.collectFees(), 2 ether);
        assertEq(pair.balanceOf(address(hook)), 2 ether);
        assertEq(hook.collectFees(), 0);
        hook.payRecorded(alice);
        assertEq(pair.balanceOf(alice), before + 1 ether);
        _assertSettled();
    }

    function test_feeTransferCannotTriggerRewardDuringSwap() public {
        vm.etch(IMD, address(new AdversarialIMD()).code);
        AdversarialIMD(IMD).configure(address(hook), alice, false, true);
        uint256 before = pair.balanceOf(alice);
        _swap(alice, true, -100 ether);
        assertTrue(AdversarialIMD(IMD).attempted());
        assertFalse(AdversarialIMD(IMD).succeeded());
        assertEq(AdversarialIMD(IMD).failure(), SIMDTESTHook.ManagerUnlocked.selector);
        assertEq(pair.balanceOf(alice), before - 100 ether);
        assertEq(hook.pending(alice), 1 ether);
        _assertSettled();
    }

    function test_claimCannotReenterOrPayTwice() public {
        _swap(alice, true, -100 ether);
        vm.etch(IMD, address(new AdversarialIMD()).code);
        AdversarialIMD(IMD).configure(address(hook), alice, false, true);
        uint256 before = pair.balanceOf(alice);
        hook.payRecorded(alice);
        assertTrue(AdversarialIMD(IMD).attempted());
        assertFalse(AdversarialIMD(IMD).succeeded());
        assertEq(AdversarialIMD(IMD).failure(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(pair.balanceOf(alice), before + 1 ether);
        assertEq(hook.pending(alice), 0);
        assertEq(hook.owedTotal(), 0);
        _assertSettled();
    }

    function test_noLiquidityNoFeeNoReward() public {
        liquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(-600, 600, -10_000_000 ether, 0), "");
        uint256 before = pair.balanceOf(alice);
        _swap(alice, true, -100 ether);
        assertEq(pair.balanceOf(alice), before);
        assertEq(_assets(), 0);
        assertEq(hook.pending(alice), 0);
        _assertSettled();
    }
}
