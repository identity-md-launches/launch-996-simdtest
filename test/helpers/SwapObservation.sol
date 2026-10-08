// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

/// @dev Read the manager's actual AMM fill, before hook deltas. Foundry records
/// even reverted preview logs: filter on the real router's indexed sender.
library SwapObservation {
    bytes32 internal constant SWAP =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    function amounts(Vm.Log[] memory logs, address manager, PoolId pool, address router)
        internal
        pure
        returns (int128 amount0, int128 amount1)
    {
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != manager || logs[i].topics.length != 3) continue;
            if (logs[i].topics[0] != SWAP || logs[i].topics[1] != PoolId.unwrap(pool)) continue;
            if (logs[i].topics[2] != bytes32(uint256(uint160(router)))) continue;
            (amount0, amount1,,,,) =
                abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            ++count;
        }
        require(count == 1, "expected one surviving AMM swap");
    }
}
