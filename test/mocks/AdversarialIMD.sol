// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockERC20} from "./MockERC20.sol";

contract AdversarialIMD is MockERC20 {
    address public target;
    address public beneficiary;
    bool public rejectTransfers;
    bool public attack;
    bool public attempted;
    bool public succeeded;
    bytes4 public failure;

    constructor() MockERC20("IMD", "IMD", 0) {}

    function configure(address hook, address buyer, bool reject, bool reenter) external {
        target = hook;
        beneficiary = buyer;
        rejectTransfers = reject;
        attack = reenter;
        attempted = false;
        succeeded = false;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!rejectTransfers || (from != target && to != target), "blocked transfer");
        super._update(from, to, value);
        if (attack && (from == target || to == target) && !attempted) {
            attempted = true;
            (bool ok, bytes memory data) =
                target.call(abi.encodeWithSignature("payRecorded(address)", beneficiary));
            succeeded = ok;
            if (!ok && data.length >= 4) failure = bytes4(data);
        }
    }
}
