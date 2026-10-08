// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Work} from "../src/Work.sol";
import {WorkLaunchHook} from "../src/WorkLaunchHook.sol";
import {HookMiner} from "./HookMiner.sol";

/// @notice Operator utilities; the network launch factory consumes launch.json separately.
contract Deploy is Script {
    /// @notice Standalone token deployment / offline smoke simulation.
    function run() external returns (Work token) {
        _checkChain();
        vm.startBroadcast();
        token = new Work();
        vm.stopBroadcast();
    }

    /// @notice Separate hook deployment, with an operator-mined salt for the actual CREATE2 deployer.
    function deployHook(IPoolManager manager, address token, bytes32 salt) external returns (WorkLaunchHook hook) {
        _checkChain();
        require(address(manager).code.length > 0, "PoolManager has no code");
        require(token.code.length > 0, "Token has no code");
        vm.startBroadcast();
        hook = new WorkLaunchHook{salt: salt}(manager, token);
        vm.stopBroadcast();
    }

    /// @notice Read-only helper: no deployment, RPC, keys or filesystem reads.
    function mine(address create2Deployer, IPoolManager manager, address token, uint256 start, uint256 attempts)
        external
        view
        returns (address predicted, bytes32 salt)
    {
        require(create2Deployer != address(0), "Missing CREATE2 deployer");
        require(address(manager) != address(0) && token != address(0), "Missing constructor argument");
        return HookMiner.find(create2Deployer, HookMiner.initCodeHash(manager, token), start, attempts);
    }

    function _checkChain() internal view {
        uint256 expected = vm.envOr("EXPECTED_CHAIN_ID", uint256(0));
        require(block.chainid == 31337 || block.chainid == 11155111, "Unsupported chain");
        if (expected == 0) require(block.chainid == 31337, "Dry run requires local chain");
        else require(block.chainid == expected, "Chain mismatch");
    }
}
