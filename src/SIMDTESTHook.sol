// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SIMDTESTRouter} from "./SIMDTESTRouter.sol";

/// @notice Immutable IMD swap fees and deferred buyer rewards for the SIMDTEST launch pool.
contract SIMDTESTHook is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using TransientStateLibrary for IPoolManager;

    uint256 public constant buyerRewardFeeBps = 200;
    uint256 public constant minBuyUnits = 10 ether;
    // v4's fee tier uses millionths despite the name required by the launch interface.
    uint24 public constant poolFeeBps = 12500;
    address public constant pairedCurrency = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;

    IPoolManager public immutable poolManager;
    address public immutable token;
    SIMDTESTRouter public immutable rewardRouter;
    mapping(address buyer => uint256 amount) public pending;
    uint256 public owedTotal;
    uint256 private _feeForSwap;

    error OnlyPoolManager();
    error InvalidDeployment();
    error InvalidPool();
    error ManagerUnlocked();
    error UnexpectedUnlock();
    error OnlySelf();
    error SwapQuote(int256 delta);
    error InvalidQuote();

    event FeeAccrued(uint256 amount, bool asClaim);
    event RewardRecorded(address indexed buyer, uint256 spent, uint256 reward);
    event RewardPaid(address indexed buyer, uint256 amount);
    event FeesCollected(uint256 amount);

    constructor(IPoolManager manager, address launchToken) {
        if (
            address(manager).code.length == 0 || launchToken.code.length == 0 || launchToken == pairedCurrency
        ) {
            revert InvalidDeployment();
        }
        poolManager = manager;
        token = launchToken;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
        rewardRouter = new SIMDTESTRouter(manager, launchToken, pairedCurrency);
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    function beforeInitialize(address, PoolKey calldata key, uint160)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        if (!_isLaunchPool(key)) revert InvalidPool();
        return IHooks.beforeInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint256 fee = 0;
        if (_isLaunchPool(key) && _pairIsSpecified(key, params)) {
            fee = _specifiedFee(params.amountSpecified);
            // Preview against the same PoolManager state, then revert the preview completely.
            // This caps specified-side fees to the actual fill when a price limit or empty range stops a swap.
            SwapParams memory preview = params;
            preview.amountSpecified += int256(fee);
            uint256 filled = _previewPairAmount(key, preview);
            uint256 actualFee = params.amountSpecified < 0 ? filled / 49 : filled / 50;
            if (actualFee < fee) fee = actualFee;
            _feeForSwap = fee;
        }
        // The static LP fee is untouched. Positive specified delta withholds input / grosses up output.
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4, int128) {
        if (!_isLaunchPool(key)) return (IHooks.afterSwap.selector, 0);
        bool pair0 = Currency.unwrap(key.currency0) == pairedCurrency;
        int128 pairedDelta = pair0 ? delta.amount0() : delta.amount1();
        int128 tokenDelta = pair0 ? delta.amount1() : delta.amount0();
        bool specified = _pairIsSpecified(key, params);
        uint256 amount = pairedDelta < 0 ? uint256(-int256(pairedDelta)) : uint128(pairedDelta);
        uint256 fee = specified ? _feeForSwap : amount / 50;
        _feeForSwap = 0;

        // Only our immutable self-recipient router authenticates the buyer. Arbitrary hookData is ignored.
        if (sender == address(rewardRouter) && pairedDelta < 0 && tokenDelta > 0 && hookData.length == 32) {
            address buyer = abi.decode(hookData, (address));
            uint256 spent = amount + fee;
            if (buyer != address(0) && spent >= minBuyUnits) {
                uint256 reward = spent / 100;
                pending[buyer] += reward;
                owedTotal += reward;
                emit RewardRecorded(buyer, spent, reward);
            }
        }
        if (fee != 0) _accrueFee(fee);
        return (IHooks.afterSwap.selector, specified ? int128(0) : fee.toInt128());
    }

    /// @dev Reverting simulation only. Called by this hook so v4 skips recursive hook callbacks.
    /// No simulated pool state, accounting, or event survives this call.
    function quoteSwap(PoolKey calldata key, SwapParams calldata params) external {
        if (msg.sender != address(this)) revert OnlySelf();
        BalanceDelta delta = poolManager.swap(key, params, "");
        revert SwapQuote(BalanceDelta.unwrap(delta));
    }

    function _previewPairAmount(PoolKey calldata key, SwapParams memory params) private returns (uint256) {
        (bool ok, bytes memory data) = address(this).call(abi.encodeCall(this.quoteSwap, (key, params)));
        if (ok) revert InvalidQuote();
        if (data.length != 36 || bytes4(data) != SwapQuote.selector) {
            // Preserve the underlying PoolManager's own failure on an invalid swap.
            assembly ("memory-safe") { revert(add(data, 32), mload(data)) }
        }
        int256 raw;
        assembly ("memory-safe") { raw := mload(add(data, 36)) }
        BalanceDelta delta = BalanceDelta.wrap(raw);
        int128 paired = Currency.unwrap(key.currency0) == pairedCurrency ? delta.amount0() : delta.amount1();
        return paired < 0 ? uint256(-int256(paired)) : uint128(paired);
    }

    function claimRewards() external nonReentrant returns (uint256) {
        return _pay(msg.sender);
    }

    /// @notice Permissionless payment to the recorded beneficiary. The caller can never redirect it.
    function payRecorded(address buyer) external nonReentrant returns (uint256) {
        return _pay(buyer);
    }

    /// @notice Converts any ERC-6909 fallback fees into IMD held by this hook, never by the caller.
    function collectFees() external nonReentrant returns (uint256) {
        if (poolManager.isUnlocked()) revert ManagerUnlocked();
        return _collectFees();
    }

    function unlockCallback(bytes calldata) external onlyPoolManager returns (bytes memory) {
        if (!_reentrancyGuardEntered()) revert UnexpectedUnlock();
        uint256 amount = poolManager.balanceOf(address(this), uint160(pairedCurrency));
        if (amount != 0) {
            poolManager.burn(address(this), uint160(pairedCurrency), amount);
            poolManager.take(Currency.wrap(pairedCurrency), address(this), amount);
        }
        return abi.encode(amount);
    }

    function _pay(address buyer) private returns (uint256 amount) {
        // Also excludes payments between callbacks while any router still has an active unlock.
        if (poolManager.isUnlocked()) revert ManagerUnlocked();
        amount = pending[buyer];
        if (amount == 0) return 0;
        pending[buyer] = 0;
        owedTotal -= amount;
        if (IERC20(pairedCurrency).balanceOf(address(this)) < amount) _collectFees();
        IERC20(pairedCurrency).safeTransfer(buyer, amount);
        emit RewardPaid(buyer, amount);
    }

    function _collectFees() private returns (uint256 amount) {
        if (poolManager.balanceOf(address(this), uint160(pairedCurrency)) == 0) return 0;
        amount = abi.decode(poolManager.unlock(""), (uint256));
        emit FeesCollected(amount);
    }

    function _accrueFee(uint256 fee) private {
        // A fresh one-sided pool may not have any IMD until the router settles after this callback.
        // Failed transfers roll back the manager's take delta; mint then settles the same hook credit.
        try poolManager.take(Currency.wrap(pairedCurrency), address(this), fee) {
            emit FeeAccrued(fee, false);
        } catch {
            poolManager.mint(address(this), uint160(pairedCurrency), fee);
            emit FeeAccrued(fee, true);
        }
    }

    function _specifiedFee(int256 amountSpecified) private pure returns (uint256) {
        if (amountSpecified < 0) {
            return (uint256(-(amountSpecified + 1)) + 1) / 50;
        }
        // Exact-output sells specify NET IMD. N/49 == floor(2% of gross N + N/49).
        return uint256(amountSpecified) / 49;
    }

    function _pairIsSpecified(PoolKey calldata key, SwapParams calldata params) private pure returns (bool) {
        bool specified0 = (params.amountSpecified < 0) == params.zeroForOne;
        return specified0 == (Currency.unwrap(key.currency0) == pairedCurrency);
    }

    function _isLaunchPool(PoolKey calldata key) private view returns (bool) {
        (address a, address b) = token < pairedCurrency ? (token, pairedCurrency) : (pairedCurrency, token);
        return Currency.unwrap(key.currency0) == a && Currency.unwrap(key.currency1) == b
            && key.fee == poolFeeBps && key.tickSpacing == 60 && address(key.hooks) == address(this);
    }
}
