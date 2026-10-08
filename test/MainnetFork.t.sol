// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @notice Uses the fork selected by the operator's Foundry configuration, never env cheatcodes.
/// Default offline runs explicitly SKIP these tests. No mock code is placed at mainnet addresses here.
contract MainnetForkTest is HookFixture {
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
}
