// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockERC20} from "./MockERC20.sol";

/// @dev Preserves the fixture token's storage layout. Allows redemption to
/// succeed before the eventual beneficiary transfer fails in the same claim.
contract PayoutIMD is MockERC20 {
    address public blockedRecipient;
    bool public omitReturn;

    constructor() MockERC20("IMD", "IMD", 0) {}

    function configure(address recipient, bool noReturn) external {
        blockedRecipient = recipient;
        omitReturn = noReturn;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (to == blockedRecipient) return false;
        super.transfer(to, amount);
        if (omitReturn) {
            assembly ("memory-safe") { return(0, 0) }
        }
        return true;
    }
}
