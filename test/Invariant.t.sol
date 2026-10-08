// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HookFixture} from "./helpers/HookFixture.sol";
import {SIMDTESTHook} from "../src/SIMDTESTHook.sol";
import {SIMDTESTRouter} from "../src/SIMDTESTRouter.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

contract RewardHandler is Test {
    SIMDTESTHook public immutable hook;
    SIMDTESTRouter public immutable router;
    IPoolManager public immutable manager;
    IERC20 public immutable pair;
    address[2] public buyers;
    uint256 public collectedFees;
    uint256 public paidRewards;

    constructor(SIMDTESTHook h, address a, address b) {
        hook = h;
        router = h.rewardRouter();
        manager = h.poolManager();
        pair = IERC20(h.pairedCurrency());
        buyers = [a, b];
    }

    function assets() public view returns (uint256) {
        return pair.balanceOf(address(hook)) + manager.balanceOf(address(hook), uint160(address(pair)));
    }

    function trade(uint96 raw, bool buy, bool exactInput, bool secondBuyer) public {
        uint256 amount = bound(raw, 1e12, 100 ether);
        address buyer = buyers[secondBuyer ? 1 : 0];
        uint256 before = assets();
        bool zeroForOne = buy == (address(pair) < hook.token());
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        vm.prank(buyer);
        router.swap(
            buy,
            exactInput ? -int256(amount) : int256(amount),
            exactInput ? amount : amount * 3 + 1 ether,
            0,
            limit,
            block.timestamp
        );
        collectedFees += assets() - before;
    }

    function pay(bool secondBuyer, bool selfClaim) public {
        address buyer = buyers[secondBuyer ? 1 : 0];
        uint256 before = pair.balanceOf(buyer);
        if (selfClaim) {
            vm.prank(buyer);
            hook.claimRewards();
        } else {
            hook.payRecorded(buyer);
        }
        paidRewards += pair.balanceOf(buyer) - before;
    }

    function collect() public {
        hook.collectFees();
    }
}

contract RewardInvariantTest is HookFixture {
    RewardHandler internal handler;

    function setUp() public {
        _localSetup();
        handler = new RewardHandler(hook, alice, bob);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = RewardHandler.trade.selector;
        selectors[1] = RewardHandler.pay.selector;
        selectors[2] = RewardHandler.collect.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 32
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_allRewardsBackedAndAllFeesConserved() public view {
        assertEq(hook.owedTotal(), hook.pending(alice) + hook.pending(bob));
        assertGe(_assets(), hook.owedTotal());
        assertEq(handler.collectedFees(), _assets() + handler.paidRewards());
        assertLe(handler.paidRewards() + hook.owedTotal(), handler.collectedFees());
        assertEq(token.totalSupply(), 1e27);
        _assertSettled();
    }
}
