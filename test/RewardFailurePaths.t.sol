// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {PayoutIMD} from "./mocks/PayoutIMD.sol";
import {SIMDTESTHook} from "src/SIMDTESTHook.sol";
import {SIMDTESTRouter} from "src/SIMDTESTRouter.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {HookFlags} from "src/HookFlags.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/IERC6093.sol";

contract RewardFailurePathsTest is HookFixture, IUnlockCallback {
    using StateLibrary for IPoolManager;

    function setUp() public {
        _localSetup();
    }

    function test_subthresholdPurchasesDoNotAggregateIntoEligibility() public {
        for (uint256 i; i < 4; ++i) {
            _swap(alice, true, -9 ether);
        }
        assertEq(hook.pending(alice), 0);
        assertEq(hook.owedTotal(), 0);
        assertEq(_assets(), 0.72 ether);
        assertEq(hook.payRecorded(alice), 0);
        _assertSettled();
    }

    function test_claimThenEarnAgainKeepsBuyersIndependent() public {
        _swap(alice, true, -20 ether);
        _swap(bob, true, -30 ether);
        vm.prank(alice);
        assertEq(hook.claimRewards(), 0.2 ether);
        assertEq(hook.pending(bob), 0.3 ether);
        assertEq(hook.owedTotal(), 0.3 ether);
        _swap(alice, false, -20 ether);
        _swap(alice, false, 20 ether);
        assertEq(hook.pending(alice), 0, "sells must not reopen paid rewards");
        _swap(alice, true, -50 ether);
        assertEq(hook.pending(alice), 0.5 ether);
        assertEq(hook.payRecorded(bob), 0.3 ether);
        assertEq(hook.owedTotal(), 0.5 ether);
        assertEq(hook.payRecorded(alice), 0.5 ether);
        assertEq(hook.payRecorded(alice), 0);
        _assertSettled();
    }

    function test_failedBeneficiaryTransferRollsBackSuccessfulClaimRedemption() public {
        vm.etch(IMD, address(new PayoutIMD()).code);
        // Reject only transfers TO the hook while trading, forcing ERC-6909 fees.
        PayoutIMD(IMD).configure(address(hook), false);
        _swap(alice, true, -100 ether);
        _swap(bob, true, -200 ether);
        uint256 claims = manager.balanceOf(address(hook), uint160(IMD));
        assertEq(claims, 6 ether);
        uint256 managerBefore = pair.balanceOf(address(manager));
        uint256 aliceBefore = pair.balanceOf(alice);
        // Redemption can now transfer to the hook; only the final payout fails.
        PayoutIMD(IMD).configure(alice, false);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, IMD));
        hook.payRecorded(alice);
        assertEq(manager.balanceOf(address(hook), uint160(IMD)), claims, "burn escaped rollback");
        assertEq(pair.balanceOf(address(manager)), managerBefore);
        assertEq(pair.balanceOf(address(hook)), 0);
        assertEq(pair.balanceOf(alice), aliceBefore);
        assertEq(hook.pending(alice), 1 ether);
        assertEq(hook.pending(bob), 2 ether);
        assertEq(hook.owedTotal(), 3 ether);
        // A blocked beneficiary must not prevent a different creditor exiting.
        uint256 bobBefore = pair.balanceOf(bob);
        assertEq(hook.payRecorded(bob), 2 ether);
        assertEq(pair.balanceOf(bob), bobBefore + 2 ether);
        assertEq(hook.pending(alice), 1 ether);
        assertEq(hook.owedTotal(), 1 ether);
        assertEq(manager.balanceOf(address(hook), uint160(IMD)), 0);
        PayoutIMD(IMD).configure(address(0), false);
        vm.prank(alice);
        assertEq(hook.claimRewards(), 1 ether);
        _assertSettled();
    }

    function test_missingTransferReturnSupportsSwapRedemptionAndPayout() public {
        vm.etch(IMD, address(new PayoutIMD()).code);
        PayoutIMD(IMD).configure(address(hook), false);
        _swap(alice, true, -100 ether);
        assertEq(manager.balanceOf(address(hook), uint160(IMD)), 2 ether);
        PayoutIMD(IMD).configure(address(0), true);
        uint256 before = pair.balanceOf(alice);
        vm.prank(alice);
        assertEq(hook.claimRewards(), 1 ether);
        assertEq(pair.balanceOf(alice), before + 1 ether);
        _swap(bob, true, -100 ether);
        assertEq(hook.pending(bob), 1 ether);
        assertEq(hook.payRecorded(bob), 1 ether);
        assertEq(_assets(), 2 ether);
        _assertSettled();
    }

    function test_everyPaymentEntryRejectsAnUnrelatedManagerUnlock() public {
        _swap(alice, true, -100 ether);
        uint256 before = pair.balanceOf(alice);
        manager.unlock("");
        assertEq(hook.pending(alice), 1 ether);
        assertEq(pair.balanceOf(alice), before);
        assertEq(hook.payRecorded(alice), 1 ether);
        _assertSettled();
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(manager));
        vm.prank(alice);
        vm.expectRevert(SIMDTESTHook.ManagerUnlocked.selector);
        hook.claimRewards();
        vm.expectRevert(SIMDTESTHook.ManagerUnlocked.selector);
        hook.payRecorded(alice);
        vm.expectRevert(SIMDTESTHook.ManagerUnlocked.selector);
        hook.payRecorded(bob); // Also reject empty claims during an unlock.
        vm.expectRevert(SIMDTESTHook.ManagerUnlocked.selector);
        hook.collectFees();
        return "";
    }

    function test_unsolicitedManagerCallbackCannotRedeemFees() public {
        vm.prank(address(manager));
        vm.expectRevert(SIMDTESTHook.UnexpectedUnlock.selector);
        hook.unlockCallback("");
    }

    function test_invalidConstructorDependenciesRevertBeforeDeployment() public {
        vm.expectRevert(SIMDTESTHook.InvalidDeployment.selector);
        new SIMDTESTHook(IPoolManager(alice), address(token));
        vm.expectRevert(SIMDTESTHook.InvalidDeployment.selector);
        new SIMDTESTHook(manager, alice);
        vm.expectRevert(SIMDTESTHook.InvalidDeployment.selector);
        new SIMDTESTHook(manager, IMD);
    }

    function test_wrongCreate2PermissionBitsAreRejected() public {
        bytes32 hash =
            keccak256(abi.encodePacked(type(SIMDTESTHook).creationCode, abi.encode(manager, token)));
        uint256 salt;
        address predicted;
        do {
            predicted = address(
                uint160(
                    uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(salt++), hash)))
                )
            );
        } while (HookFlags.matches(predicted, HookFlags.FLAGS));
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new SIMDTESTHook{salt: bytes32(salt - 1)}(manager, address(token));
    }

    function test_routerInvalidAmountsLeaveAllAccountingUnchanged() public {
        bytes32 before = _state();
        vm.startPrank(alice);
        vm.expectRevert(SIMDTESTRouter.InvalidSwap.selector);
        router.swap(true, 0, 1 ether, 0, _limit(true), block.timestamp);
        vm.expectRevert(SIMDTESTRouter.InvalidSwap.selector);
        router.swap(true, type(int256).min, 1 ether, 0, _limit(true), block.timestamp);
        vm.expectRevert(SIMDTESTRouter.InvalidSwap.selector);
        router.swap(true, -100 ether, 99 ether, 0, _limit(true), block.timestamp);
        vm.expectRevert(SIMDTESTRouter.InvalidSwap.selector);
        router.swap(false, 100 ether, 0, 0, _limit(false), block.timestamp);
        vm.stopPrank();
        assertEq(_state(), before);
        _assertSettled();
    }

    function test_failedTokenPullDoesNotRecordFeesOrRewards() public {
        bytes32 before = _state();
        vm.startPrank(alice);
        pair.approve(address(router), 100 ether - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(router), 100 ether - 1, 100 ether
            )
        );
        router.swap(true, -100 ether, 100 ether, 0, _limit(true), block.timestamp);
        vm.stopPrank();
        assertEq(_state(), before);
        _assertSettled();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_exactOutputPartialFillRollsBackEverything(bool buy, uint96 raw) public {
        uint256 amount = bound(raw, 10_000 ether, 100_000 ether);
        bool zeroForOne = buy == (IMD < address(token));
        uint160 limit = TickMath.getSqrtPriceAtTick(zeroForOne ? int24(-1) : int24(1));
        bytes32 before = _state();
        vm.prank(alice);
        vm.expectRevert(SIMDTESTRouter.Slippage.selector);
        router.swap(buy, int256(amount), amount * 3, 0, limit, block.timestamp);
        assertEq(_state(), before, "reverted fill changed pool, balances, fees or debts");
        // Reuse the hook after rollback to detect stale specified-side fee state.
        _swap(alice, true, -10 ether);
        assertEq(hook.pending(alice), 0.1 ether);
        assertEq(_assets(), 0.2 ether);
        _assertSettled();
    }

    function _state() internal view returns (bytes32) {
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(key.toId());
        (uint256 growth0, uint256 growth1) = manager.getFeeGrowthGlobals(key.toId());
        bytes32 poolState = keccak256(abi.encode(price, tick, protocolFee, lpFee, growth0, growth1));
        return keccak256(
            abi.encode(
                poolState,
                pair.balanceOf(alice),
                token.balanceOf(alice),
                pair.balanceOf(address(manager)),
                token.balanceOf(address(manager)),
                pair.balanceOf(address(router)),
                token.balanceOf(address(router)),
                _assets(),
                hook.pending(alice),
                hook.owedTotal()
            )
        );
    }
}
