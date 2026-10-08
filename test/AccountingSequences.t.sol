// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HookFixture} from "./helpers/HookFixture.sol";
import {SwapObservation} from "./helpers/SwapObservation.sol";
import {AdversarialIMD} from "./mocks/AdversarialIMD.sol";
import {SIMDTESTHook} from "src/SIMDTESTHook.sol";
import {SIMDTESTRouter} from "src/SIMDTESTRouter.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @dev Ghost debts come from actual trader debits, and ghost fees from the
/// manager's Swap event. Neither is copied from hook.pending or hook assets.
contract AccountingSequenceHandler is Test {
    SIMDTESTHook public immutable hook;
    SIMDTESTRouter public immutable router;
    IPoolManager public immutable manager;
    AdversarialIMD public immutable pair;
    IERC20 public immutable token;
    address[3] public buyers;
    mapping(address => uint256) public expectedPending;
    uint256 public expectedFees;
    uint256 public earned;
    uint256 public paid;
    uint256 public donated;

    constructor(SIMDTESTHook h, address[3] memory actors) {
        hook = h;
        router = h.rewardRouter();
        manager = h.poolManager();
        pair = AdversarialIMD(h.pairedCurrency());
        token = IERC20(h.token());
        buyers = actors;
    }

    struct Trade {
        address buyer;
        uint256 amount;
        uint256 pairBefore;
        uint256 tokenBefore;
        int128 ammPair;
        int128 ammToken;
    }

    function trade(uint96 raw, uint8 who, bool buy, bool exactInput, bool deferFee) public {
        Trade memory t;
        t.buyer = buyers[who % 3];
        t.amount = bound(raw, 1, 100 ether);
        // Exercise threshold neighbors frequently, including a one-wei difference.
        if (raw % 4 == 0) t.amount = 10 ether - 1 + uint256(who % 3);
        bool zeroForOne = buy == (address(pair) < address(token));
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        pair.configure(address(hook), t.buyer, deferFee, false);
        t.pairBefore = pair.balanceOf(t.buyer);
        t.tokenBefore = token.balanceOf(t.buyer);
        vm.recordLogs();
        vm.prank(t.buyer);
        router.swap(
            buy,
            exactInput ? -int256(t.amount) : int256(t.amount),
            exactInput ? t.amount : t.amount * 3 + 1 ether,
            0,
            limit,
            block.timestamp
        );
        PoolKey memory key = router.poolKey();
        (int128 a0, int128 a1) =
            SwapObservation.amounts(vm.getRecordedLogs(), address(manager), key.toId(), address(router));
        t.ammPair = address(pair) < address(token) ? a0 : a1;
        t.ammToken = address(pair) < address(token) ? a1 : a0;
        pair.configure(address(hook), t.buyer, false, false);
        if (buy) _recordBuy(t, exactInput);
        else _recordSell(t, exactInput);
    }

    function _recordBuy(Trade memory t, bool exactInput) internal {
        uint256 spent = t.pairBefore - pair.balanceOf(t.buyer);
        uint256 output = token.balanceOf(t.buyer) - t.tokenBefore;
        uint256 fee = exactInput ? spent * 200 / 10_000 : uint256(-int256(t.ammPair)) * 200 / 10_000;
        assertEq(spent, uint256(-int256(t.ammPair)) + fee, "buy fee deviates from AMM fill");
        assertEq(output, uint128(t.ammToken), "hook charged launch tokens");
        if (exactInput) assertEq(spent, t.amount, "bounded trade must fully fill");
        else assertEq(output, t.amount);
        uint256 reward = spent >= 10 ether && output > 0 ? spent / 100 : 0;
        expectedPending[t.buyer] += reward;
        earned += reward;
        expectedFees += fee;
    }

    function _recordSell(Trade memory t, bool exactInput) internal {
        uint256 received = pair.balanceOf(t.buyer) - t.pairBefore;
        uint256 gross = uint128(t.ammPair);
        uint256 fee = gross * 200 / 10_000;
        assertEq(received + fee, gross, "sell fee deviates from AMM fill");
        assertEq(t.tokenBefore - token.balanceOf(t.buyer), uint256(-int256(t.ammToken)));
        if (exactInput) assertEq(t.tokenBefore - token.balanceOf(t.buyer), t.amount);
        else assertEq(received, t.amount);
        expectedFees += fee;
    }

    function pay(uint8 who, bool selfClaim) public {
        address buyer = buyers[who % 3];
        address caller = selfClaim ? buyer : buyers[(uint256(who) + 1) % 3];
        uint256 before = pair.balanceOf(buyer);
        uint256 callerBefore = pair.balanceOf(caller);
        vm.prank(caller);
        uint256 actual = selfClaim ? hook.claimRewards() : hook.payRecorded(buyer);
        uint256 expected = expectedPending[buyer];
        assertEq(actual, expected, "payout differs from independently earned rewards");
        assertEq(pair.balanceOf(buyer) - before, expected);
        if (!selfClaim) assertEq(pair.balanceOf(caller), callerBefore, "caller redirected payout");
        paid += expected;
        expectedPending[buyer] = 0;
    }

    function collect() public {
        uint256 claims = manager.balanceOf(address(hook), uint160(address(pair)));
        uint256 cash = pair.balanceOf(address(hook));
        uint256 callerBefore = pair.balanceOf(address(this));
        assertEq(hook.collectFees(), claims);
        assertEq(manager.balanceOf(address(hook), uint160(address(pair))), 0);
        assertEq(pair.balanceOf(address(hook)), cash + claims);
        assertEq(pair.balanceOf(address(this)), callerBefore);
    }

    function donate(uint64 raw, uint8 who) public {
        uint256 amount = bound(raw, 0, 1 ether);
        vm.prank(buyers[who % 3]);
        pair.transfer(address(hook), amount);
        donated += amount;
    }

    function failedPay(uint8 who) public {
        address buyer = buyers[who % 3];
        if (expectedPending[buyer] == 0) return;
        uint256 debt = hook.owedTotal();
        uint256 cash = pair.balanceOf(address(hook));
        uint256 balance = pair.balanceOf(buyer);
        uint256 claims = manager.balanceOf(address(hook), uint160(address(pair)));
        pair.configure(address(hook), buyer, true, false);
        vm.expectRevert();
        hook.payRecorded(buyer);
        pair.configure(address(hook), buyer, false, false);
        assertEq(hook.pending(buyer), expectedPending[buyer]);
        assertEq(hook.owedTotal(), debt);
        assertEq(pair.balanceOf(address(hook)), cash);
        assertEq(pair.balanceOf(buyer), balance);
        assertEq(manager.balanceOf(address(hook), uint160(address(pair))), claims);
    }
}

contract AccountingSequencesTest is HookFixture {
    AccountingSequenceHandler internal handler;
    address internal charlie;

    function setUp() public {
        _localSetup();
        charlie = makeAddr("charlie");
        _fund(charlie);
        vm.etch(IMD, address(new AdversarialIMD()).code);
        handler = new AccountingSequenceHandler(hook, [alice, bob, charlie]);
        // Every campaign starts with both cash and claim-backed fees, and three
        // creditors, so payout coverage does not depend on random action order.
        handler.trade(20 ether, 0, true, true, true);
        handler.trade(30 ether + 1, 1, true, true, false);
        handler.trade(40 ether + 1, 2, true, false, true);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.trade.selector;
        selectors[1] = handler.pay.selector;
        selectors[2] = handler.collect.selector;
        selectors[3] = handler.donate.selector;
        selectors[4] = handler.failedPay.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_independentDebtsFeesAndSupplyAreConserved() public view {
        uint256 expected;
        uint256 heldByBuyers;
        for (uint256 i; i < 3; ++i) {
            address buyer = handler.buyers(i);
            uint256 debt = handler.expectedPending(buyer);
            assertEq(hook.pending(buyer), debt, "buyer debt diverged");
            expected += debt;
            heldByBuyers += token.balanceOf(buyer);
        }
        assertEq(hook.owedTotal(), expected);
        assertEq(handler.earned(), handler.paid() + expected);
        assertEq(handler.expectedFees() + handler.donated(), _assets() + handler.paid());
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)) + token.balanceOf(address(manager)) + heldByBuyers, 1e27);
        _assertSettled();
    }

    function afterInvariant() public {
        handler.pay(0, true);
        handler.pay(1, false);
        handler.pay(2, true);
        handler.collect();
        assertEq(hook.owedTotal(), 0, "all creditors must be able to exit");
        assertEq(handler.paid(), handler.earned());
        assertEq(_assets(), handler.expectedFees() + handler.donated() - handler.paid());
        _assertSettled();
    }
}
