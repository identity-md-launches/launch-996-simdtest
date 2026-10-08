// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SwapObservation} from "./helpers/SwapObservation.sol";
import {HookFlags} from "src/HookFlags.sol";
import {SIMDTESTRouter} from "src/SIMDTESTRouter.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @notice Uses the fork selected by the operator's Foundry configuration, never env cheatcodes.
/// Default offline runs explicitly SKIP these tests. No mock code is placed at mainnet addresses here.
contract MainnetForkTest is HookFixture {
    using StateLibrary for IPoolManager;

    function setUp() public {
        if (block.chainid != 1 || MAINNET_MANAGER.code.length == 0 || IMD.code.length == 0) {
            vm.skip(true);
            return;
        }
        assertEq(IERC20Metadata(IMD).decimals(), 18);
        assertEq(IERC20Metadata(IMD).symbol(), "IMD");
        manager = IPoolManager(MAINNET_MANAGER);
        _setupPool();
    }

    function test_forkFourModesAndClaims() public {
        _swap(alice, true, -9 ether);
        assertEq(hook.pending(alice), 0);
        _swap(alice, true, -10 ether);
        assertEq(hook.pending(alice), 0.1 ether);
        uint256 prior = hook.pending(alice);
        BalanceDelta d = _swap(alice, true, 20 ether);
        uint256 spent = uint256(-int256(_pairDelta(d)));
        assertEq(hook.pending(alice), prior + spent / 100);
        prior = hook.pending(alice);
        _swap(alice, false, -20 ether);
        _swap(alice, false, 20 ether);
        assertEq(hook.pending(alice), prior);
        uint256 before = pair.balanceOf(alice);
        vm.prank(alice);
        assertEq(hook.claimRewards(), prior);
        assertEq(pair.balanceOf(alice), before + prior);
        assertEq(hook.owedTotal(), 0);
        _assertSettled();
    }

    function test_forkThirdPartyPaymentAndFeeAccrual() public {
        _swap(alice, true, -100 ether);
        assertEq(_assets(), 2 ether);
        uint256 before = pair.balanceOf(alice);
        uint256 thirdParty = pair.balanceOf(bob);
        vm.prank(bob);
        hook.payRecorded(alice);
        assertEq(pair.balanceOf(alice), before + 1 ether);
        assertEq(pair.balanceOf(bob), thirdParty);
        assertEq(_assets(), 1 ether);
        _assertSettled();
    }

    function test_forkFeesMatchRealManagerFillsInEverySwapMode() public {
        assertEq(block.chainid, 1);
        assertEq(address(hook.poolManager()), MAINNET_MANAGER);
        assertEq(HookFlags.flagsOf(address(hook)), HookFlags.FLAGS);
        for (uint256 mode; mode < 4; ++mode) {
            bool buy = mode < 2;
            bool exactInput = mode % 2 == 0;
            uint256 before = _assets();
            uint256 rewardBefore = hook.pending(alice);
            uint256 balanceBefore = pair.balanceOf(alice);
            vm.recordLogs();
            BalanceDelta d = _swap(alice, buy, exactInput ? -25 ether : int256(25 ether));
            (int128 a0, int128 a1) =
                SwapObservation.amounts(vm.getRecordedLogs(), MAINNET_MANAGER, key.toId(), address(router));
            int128 ammPair = IMD < address(token) ? a0 : a1;
            uint256 gross = ammPair < 0 ? uint256(-int256(ammPair)) : uint128(ammPair);
            uint256 fee = _assets() - before;
            if (buy) {
                uint256 spent = balanceBefore - pair.balanceOf(alice);
                assertEq(spent, uint256(-int256(_pairDelta(d))));
                assertEq(fee, exactInput ? spent * 200 / 10_000 : gross * 200 / 10_000);
                assertEq(spent, gross + fee);
                assertEq(hook.pending(alice) - rewardBefore, spent / 100);
            } else {
                uint256 received = pair.balanceOf(alice) - balanceBefore;
                assertEq(fee, gross * 200 / 10_000);
                assertEq(received + fee, gross);
                assertEq(hook.pending(alice), rewardBefore);
            }
            _assertSettled();
        }
        (,,, uint24 lpFee) = manager.getSlot0(key.toId());
        assertEq(lpFee, 12500);
        uint256 pending = hook.pending(alice);
        uint256 beforeClaim = pair.balanceOf(alice);
        vm.prank(alice);
        assertEq(hook.claimRewards(), pending);
        assertEq(pair.balanceOf(alice), beforeClaim + pending);
        _assertSettled();
    }

    function test_forkPartialOutputFailurePreservesRewardDebt() public {
        _swap(alice, true, -20 ether);
        uint256 balanceBefore = pair.balanceOf(alice);
        uint256 tokenBefore = token.balanceOf(alice);
        uint256 assetsBefore = _assets();
        (uint160 priceBefore, int24 tick,,) = manager.getSlot0(key.toId());
        int24 limitTick = IMD < address(token) ? tick - 1 : tick + 1;
        vm.prank(alice);
        vm.expectRevert(SIMDTESTRouter.Slippage.selector);
        router.swap(
            true, 100_000 ether, 300_000 ether, 0, TickMath.getSqrtPriceAtTick(limitTick), block.timestamp
        );
        (uint160 priceAfter,,,) = manager.getSlot0(key.toId());
        assertEq(priceAfter, priceBefore);
        assertEq(pair.balanceOf(alice), balanceBefore);
        assertEq(token.balanceOf(alice), tokenBefore);
        assertEq(_assets(), assetsBefore);
        assertEq(hook.pending(alice), 0.2 ether);
        assertEq(hook.owedTotal(), 0.2 ether);
        assertEq(hook.payRecorded(alice), 0.2 ether);
        _assertSettled();
    }
}
