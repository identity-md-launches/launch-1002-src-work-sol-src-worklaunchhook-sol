// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {WorkLaunchHook} from "../src/WorkLaunchHook.sol";

/// @dev Local CREATE2 preparation; the deployer must be the address executing CREATE2.
library HookMiner {
    uint160 internal constant FLAGS = 0x2044;
    uint160 internal constant MASK = 0x3fff;

    function initCodeHash(IPoolManager manager, address token) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(type(WorkLaunchHook).creationCode, abi.encode(manager, token)));
    }

    function predict(address deployer, bytes32 salt, bytes32 hash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, hash)))));
    }

    function find(address deployer, bytes32 hash, uint256 start, uint256 attempts)
        internal
        view
        returns (address predicted, bytes32 salt)
    {
        for (uint256 i; i < attempts; ++i) {
            salt = bytes32(start + i);
            predicted = predict(deployer, salt, hash);
            if (uint160(predicted) & MASK == FLAGS && predicted.code.length == 0) return (predicted, salt);
        }
        revert("No salt in search range");
    }
}
