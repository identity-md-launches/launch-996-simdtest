// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookTest} from "./Hook.t.sol";
import {SIMDTEST} from "../src/SIMDTEST.sol";

/// @notice Re-runs the entire integration/fuzz suite with IMD as currency0 instead of currency1.
contract ReverseOrderTest is HookTest {
    /// forge-config: default.fuzz.runs = 1000
    /// forge-config: extended.fuzz.runs = 2000
    function testFuzz_feesRewardsAndClaims(uint96 raw, bool buy, bool exactInput) public override {
        super.testFuzz_feesRewardsAndClaims(raw, buy, exactInput);
    }

    function _createToken() internal override returns (SIMDTEST created) {
        for (uint256 i; i < 200; ++i) {
            created = new SIMDTEST();
            if (address(created) > IMD) return created;
        }
        revert("token ordering search failed");
    }
}
