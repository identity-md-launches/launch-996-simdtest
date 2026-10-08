// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SIMDTEST} from "../../src/SIMDTEST.sol";
import {SIMDTESTHook} from "../../src/SIMDTESTHook.sol";
import {SIMDTESTRouter} from "../../src/SIMDTESTRouter.sol";
import {HookFlags} from "../../src/HookFlags.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

abstract contract HookFixture is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant MAINNET_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    uint160 internal constant Q96 = 79228162514264337593543950336;
    IPoolManager internal manager;
    IERC20 internal pair;
    SIMDTEST internal token;
    SIMDTESTHook internal hook;
    SIMDTESTRouter internal router;
    PoolModifyLiquidityTest internal liquidityRouter;
    PoolSwapTest internal otherRouter;
    PoolKey internal key;
    address internal alice;
    address internal bob;

    function _localSetup() internal {
        manager = new PoolManager(address(this));
        vm.etch(IMD, address(new MockERC20("IMD", "IMD", 0)).code);
        _setupPool();
    }

    function _setupPool() internal {
        pair = IERC20(IMD);
        token = _createToken();
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        hook = _deployHook(manager, address(token));
        router = hook.rewardRouter();
        key = router.poolKey();
        manager.initialize(key, Q96);
        liquidityRouter = new PoolModifyLiquidityTest(manager);
        otherRouter = new PoolSwapTest(manager);
        deal(IMD, address(this), 100_000_000 ether);
        pair.approve(address(liquidityRouter), type(uint256).max);
        token.approve(address(liquidityRouter), type(uint256).max);
        liquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(-600, 600, 10_000_000 ether, 0), "");
        _fund(alice);
        _fund(bob);
    }

    function _createToken() internal virtual returns (SIMDTEST created) {
        for (uint256 i; i < 200; ++i) {
            created = new SIMDTEST();
            if (address(created) < IMD) return created;
        }
        revert("token ordering search failed");
    }

    function _fund(address who) internal {
        deal(IMD, who, 10_000_000 ether);
        token.transfer(who, 10_000_000 ether);
        vm.startPrank(who);
        pair.approve(address(router), type(uint256).max);
        token.approve(address(router), type(uint256).max);
        pair.approve(address(otherRouter), type(uint256).max);
        token.approve(address(otherRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _deployHook(IPoolManager pm, address launchToken) internal returns (SIMDTESTHook result) {
        bytes memory code = abi.encodePacked(type(SIMDTESTHook).creationCode, abi.encode(pm, launchToken));
        bytes32 hash = keccak256(code);
        for (uint256 i; i < 200_000; ++i) {
            bytes32 salt = bytes32(i);
            address at = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, hash))))
            );
            if (!HookFlags.matches(at, HookFlags.FLAGS)) continue;
            address deployed;
            assembly ("memory-safe") { deployed := create2(0, add(code, 32), mload(code), salt) }
            require(deployed == at, "mined deployment failed");
            return SIMDTESTHook(deployed);
        }
        revert("salt not found");
    }

    function _limit(bool buy) internal view returns (uint160) {
        bool zeroForOne = buy == (IMD < address(token));
        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    function _swap(address who, bool buy, int256 amount) internal returns (BalanceDelta) {
        uint256 maxInput = amount < 0 ? uint256(-amount) : uint256(amount) * 3 + 1 ether;
        vm.prank(who);
        return router.swap(buy, amount, maxInput, 0, _limit(buy), block.timestamp);
    }

    function _pairDelta(BalanceDelta delta) internal view returns (int128) {
        return IMD < address(token) ? delta.amount0() : delta.amount1();
    }

    function _assets() internal view returns (uint256) {
        return pair.balanceOf(address(hook)) + manager.balanceOf(address(hook), uint160(IMD));
    }

    function _assertSettled() internal view {
        assertFalse(manager.isUnlocked());
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertEq(manager.currencyDelta(address(hook), Currency.wrap(IMD)), 0);
        assertEq(manager.currencyDelta(address(router), Currency.wrap(IMD)), 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(router)), 0);
        assertEq(pair.balanceOf(address(router)), 0);
        assertGe(_assets(), hook.owedTotal());
    }
}
