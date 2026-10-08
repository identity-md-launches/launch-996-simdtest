// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Fixed-pool, self-recipient router. The hook creates and trusts exactly this implementation.
contract SIMDTESTRouter is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IPoolManager public immutable poolManager;
    address public immutable hook;
    address public immutable token;
    address public immutable pairedCurrency;

    error InvalidSwap();
    error UnauthorizedCallback();
    error Slippage();
    error Expired();

    struct Request {
        address buyer;
        bool buy;
        SwapParams params;
        uint256 maxInput;
        uint256 minOutput;
    }

    constructor(IPoolManager manager, address launchToken, address pair) {
        poolManager = manager;
        hook = msg.sender;
        token = launchToken;
        pairedCurrency = pair;
    }

    function poolKey() public view returns (PoolKey memory) {
        (address a, address b) = token < pairedCurrency ? (token, pairedCurrency) : (pairedCurrency, token);
        return PoolKey(Currency.wrap(a), Currency.wrap(b), 12500, 60, IHooks(hook));
    }

    /// @param amountSpecified Negative for exact input; positive for exact output, including hook fees.
    /// @dev All input is pulled from msg.sender before unlocking. No payer or recipient can be supplied.
    function swap(
        bool buy,
        int256 amountSpecified,
        uint256 maxInput,
        uint256 minOutput,
        uint160 sqrtPriceLimitX96,
        uint256 deadline
    ) external nonReentrant returns (BalanceDelta delta) {
        if (block.timestamp > deadline) revert Expired();
        if (amountSpecified == 0 || amountSpecified == type(int256).min || maxInput == 0) {
            revert InvalidSwap();
        }
        if (amountSpecified < 0 && uint256(-amountSpecified) != maxInput) revert InvalidSwap();
        IERC20 input = IERC20(buy ? pairedCurrency : token);
        // Only this call spends an allowance, and its source is always the authenticated caller.
        input.safeTransferFrom(msg.sender, address(this), maxInput);
        Request memory r = Request(
            msg.sender,
            buy,
            SwapParams(buy == (pairedCurrency < token), amountSpecified, sqrtPriceLimitX96),
            maxInput,
            minOutput
        );
        uint256 spent;
        (delta, spent) = abi.decode(poolManager.unlock(abi.encode(r)), (BalanceDelta, uint256));
        if (maxInput > spent) input.safeTransfer(msg.sender, maxInput - spent);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || !_reentrancyGuardEntered()) revert UnauthorizedCallback();
        Request memory r = abi.decode(data, (Request));
        PoolKey memory key = poolKey();
        BalanceDelta delta = poolManager.swap(key, r.params, abi.encode(r.buyer));
        int128 inputDelta = r.params.zeroForOne ? delta.amount0() : delta.amount1();
        int128 outputDelta = r.params.zeroForOne ? delta.amount1() : delta.amount0();
        if (inputDelta > 0 || outputDelta < 0) revert InvalidSwap();
        uint256 spent = uint256(-int256(inputDelta));
        uint256 received = uint128(outputDelta);
        if (spent > r.maxInput || received < r.minOutput) revert Slippage();
        if (r.params.amountSpecified > 0 && received < uint256(r.params.amountSpecified)) revert Slippage();
        Currency input = r.params.zeroForOne ? key.currency0 : key.currency1;
        Currency output = r.params.zeroForOne ? key.currency1 : key.currency0;
        if (spent != 0) {
            poolManager.sync(input);
            IERC20(Currency.unwrap(input)).safeTransfer(address(poolManager), spent);
            poolManager.settle();
        }
        if (received != 0) poolManager.take(output, r.buyer, received);
        return abi.encode(delta, spent);
    }
}
