// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {SwapObservation} from "./helpers/SwapObservation.sol";
import {SIMDTEST} from "src/SIMDTEST.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

contract FillAccountingTest is HookFixture {
    using StateLibrary for IPoolManager;

    function setUp() public {
        _localSetup();
    }

    struct Fill {
        uint256 pairBefore;
        uint256 tokenBefore;
        uint256 budget;
        int128 ammPair;
        int128 ammToken;
        BalanceDelta delta;
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_partialFillsChargeOnlyActualIMD(
        uint96 rawAmount,
        uint80 rawLiquidity,
        uint16 rawTick,
        bool buy,
        bool exactInput
    ) public virtual {
        uint256 liquidity = bound(rawLiquidity, 1e6, 100_000 ether);
        liquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams(-600, 600, int256(liquidity) - 10_000_000 ether, 0), ""
        );
        int24 tick = int24(int256(bound(rawTick, 1, 1200)));
        bool zeroForOne = buy == (IMD < address(token));
        uint160 limit = TickMath.getSqrtPriceAtTick(zeroForOne ? -tick : tick);
        Fill memory f;
        f.budget = bound(rawAmount, 1, 1000 ether);
        f.pairBefore = pair.balanceOf(alice);
        f.tokenBefore = token.balanceOf(alice);
        address executor = buy && exactInput ? address(router) : address(otherRouter);
        vm.recordLogs();
        vm.prank(alice);
        if (buy && exactInput) {
            f.delta = router.swap(true, -int256(f.budget), f.budget, 0, limit, block.timestamp);
        } else {
            // The generic core router permits partial exact-output fills; the
            // production reward router intentionally rejects those (tested separately).
            f.delta = otherRouter.swap(
                key,
                SwapParams(zeroForOne, exactInput ? -int256(f.budget) : int256(f.budget), limit),
                PoolSwapTest.TestSettings(false, false),
                ""
            );
        }
        (int128 a0, int128 a1) =
            SwapObservation.amounts(vm.getRecordedLogs(), address(manager), key.toId(), executor);
        f.ammPair = IMD < address(token) ? a0 : a1;
        f.ammToken = IMD < address(token) ? a1 : a0;
        if (buy) _checkBuy(f, exactInput);
        else _checkSell(f, exactInput);
        (,,, uint24 lpFee) = manager.getSlot0(key.toId());
        assertEq(lpFee, 12500);
        _assertSettled();
    }

    function _checkBuy(Fill memory f, bool exactInput) internal {
        uint256 spent = f.pairBefore - pair.balanceOf(alice);
        uint256 output = token.balanceOf(alice) - f.tokenBefore;
        uint256 fee = exactInput ? spent * 200 / 10_000 : uint256(-int256(f.ammPair)) * 200 / 10_000;
        assertEq(_assets(), fee, "fee based on requested amount instead of actual fill");
        assertEq(spent, uint256(-int256(f.ammPair)) + fee);
        assertEq(_pairDelta(f.delta), -int256(spent));
        assertEq(output, uint128(f.ammToken));
        assertLe(exactInput ? spent : output, f.budget);
        if (exactInput) {
            uint256 reward = spent >= 10 ether && output > 0 ? spent / 100 : 0;
            assertEq(hook.pending(alice), reward);
            uint256 before = pair.balanceOf(alice);
            assertEq(hook.payRecorded(alice), reward);
            assertEq(pair.balanceOf(alice), before + reward);
            assertEq(_assets(), fee - reward);
        }
    }

    function _checkSell(Fill memory f, bool exactInput) internal view {
        uint256 received = pair.balanceOf(alice) - f.pairBefore;
        uint256 spent = f.tokenBefore - token.balanceOf(alice);
        uint256 fee = uint128(f.ammPair) * 200 / 10_000;
        assertEq(_assets(), fee);
        assertEq(received + fee, uint128(f.ammPair));
        assertEq(_pairDelta(f.delta), int256(received));
        assertEq(spent, uint256(-int256(f.ammToken)));
        assertLe(exactInput ? spent : received, f.budget);
        assertEq(hook.pending(alice), 0);
        assertEq(hook.owedTotal(), 0);
    }

    /// @dev A reference pool has the same liquidity and static LP fee but no hook.
    /// Compare resulting price and fee growth to prove the reverting quote has
    /// no surviving effect on either price or LP compensation.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_previewDoesNotDoubleMovePriceOrLPFees(uint96 raw, bool buy) public virtual {
        uint256 amount = bound(raw, 1, 1000 ether);
        PoolKey memory referenceKey = key;
        referenceKey.hooks = IHooks(address(0));
        manager.initialize(referenceKey, Q96);
        liquidityRouter.modifyLiquidity(
            referenceKey, ModifyLiquidityParams(-600, 600, 10_000_000 ether, 0), ""
        );
        BalanceDelta actual = _swap(alice, buy, buy ? -int256(amount) : int256(amount));
        uint256 fee = buy ? amount * 200 / 10_000 : amount * 200 / 9800;
        int256 referenceAmount = buy ? -int256(amount - fee) : int256(amount + fee);
        vm.prank(bob);
        BalanceDelta referenceDelta = otherRouter.swap(
            referenceKey,
            SwapParams(buy == (IMD < address(token)), referenceAmount, _limit(buy)),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        assertEq(int256(_pairDelta(actual)) + int256(fee), int256(_pairDelta(referenceDelta)));
        assertEq(
            IMD < address(token) ? actual.amount1() : actual.amount0(),
            IMD < address(token) ? referenceDelta.amount1() : referenceDelta.amount0()
        );
        _assertPoolMatches(referenceKey);
        assertEq(_assets(), fee);
        _assertSettled();
    }

    function _assertPoolMatches(PoolKey memory referenceKey) internal view {
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(key.toId());
        (uint160 refPrice, int24 refTick, uint24 refProtocolFee, uint24 refLPFee) =
            manager.getSlot0(referenceKey.toId());
        assertEq(price, refPrice);
        assertEq(tick, refTick);
        assertEq(protocolFee, refProtocolFee);
        assertEq(lpFee, refLPFee);
        (uint256 growth0, uint256 growth1) = manager.getFeeGrowthGlobals(key.toId());
        (uint256 refGrowth0, uint256 refGrowth1) = manager.getFeeGrowthGlobals(referenceKey.toId());
        assertEq(growth0, refGrowth0, "preview retained currency0 fees");
        assertEq(growth1, refGrowth1, "preview retained currency1 fees");
    }
}

contract ReverseFillAccountingTest is FillAccountingTest {
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_partialFillsChargeOnlyActualIMD(
        uint96 rawAmount,
        uint80 rawLiquidity,
        uint16 rawTick,
        bool buy,
        bool exactInput
    ) public override {
        super.testFuzz_partialFillsChargeOnlyActualIMD(rawAmount, rawLiquidity, rawTick, buy, exactInput);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_previewDoesNotDoubleMovePriceOrLPFees(uint96 raw, bool buy) public override {
        super.testFuzz_previewDoesNotDoubleMovePriceOrLPFees(raw, buy);
    }

    function _createToken() internal override returns (SIMDTEST created) {
        for (uint256 i; i < 200; ++i) {
            created = new SIMDTEST();
            if (address(created) > IMD) return created;
        }
        revert("token ordering search failed");
    }
}
