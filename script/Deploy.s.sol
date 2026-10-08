// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SIMDTEST} from "../src/SIMDTEST.sol";
import {SIMDTESTHook} from "../src/SIMDTESTHook.sol";
import {HookFlags} from "../src/HookFlags.sol";

/// @dev Local smoke-test factory only. The network's launch factory does this CREATE2 in production.
contract LocalHookFactory {
    function deploy(IPoolManager manager, address token, bytes32 salt) external returns (SIMDTESTHook) {
        return new SIMDTESTHook{salt: salt}(manager, token);
    }
}

/// @notice No keys, RPC configuration, or transactions are needed for the default offline dry run.
/// Production deployment is performed by the network's reviewed launch factory, from launch.json.
contract Deploy is Script {
    function run() external returns (SIMDTESTHook hook) {
        require(block.chainid == 31337, "local smoke test only");
        LocalHookFactory factory = new LocalHookFactory();
        IPoolManager manager = new PoolManager(address(factory));
        SIMDTEST token = new SIMDTEST();
        (bytes32 salt,) = mine(address(factory), manager, address(token));
        vm.startBroadcast();
        hook = factory.deploy(manager, address(token), salt);
        vm.stopBroadcast();
    }

    /// @notice Deployment planning only. Supply the actual factory, manager and resolved launch token.
    function mine(address factory, IPoolManager manager, address token)
        public
        pure
        returns (bytes32 salt, address predicted)
    {
        bytes32 hash =
            keccak256(abi.encodePacked(type(SIMDTESTHook).creationCode, abi.encode(manager, token)));
        for (uint256 i; i < 1_000_000; ++i) {
            salt = bytes32(i);
            predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), factory, salt, hash)))));
            if (HookFlags.matches(predicted, HookFlags.FLAGS)) return (salt, predicted);
        }
        revert("no salt in search window");
    }
}
