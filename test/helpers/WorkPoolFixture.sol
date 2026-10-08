// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {Work} from "src/Work.sol";
import {WorkLaunchHook} from "src/WorkLaunchHook.sol";
import {HookMiner} from "script/HookMiner.sol";
import {PairToken} from "./PairToken.sol";

/// @dev Only the external IMD token is a stand-in. WORK, CREATE2 hook deployment,
/// PoolManager, swaps, liquidity accounting and settlement execute real code.
abstract contract WorkPoolFixture is Test {
    address internal constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address internal constant TREASURY = 0xc9EAFE33A510a3a3d95A94c4f85AdaF6a3EA12a0;
    uint256 internal constant OPEN_TIME = 1_700_000_000;
    uint160 internal constant INITIAL_PRICE = 79228162514264337593543950336;

    IPoolManager internal manager;
    Work internal work;
    PairToken internal pair;
    WorkLaunchHook internal hook;
    PoolSwapTest internal router;
    PoolModifyLiquidityTest internal liquidityRouter;
    PoolKey internal key;
    address[3] internal actors;

    function setUp() public virtual {
        vm.warp(OPEN_TIME);
        manager = IPoolManager(address(new PoolManager(address(this))));
        work = new Work();
        PairToken implementation = new PairToken();
        vm.etch(IMD, address(implementation).code);
        pair = PairToken(IMD);
        pair.mint(address(this), 1_000_000_000 ether);

        bytes32 hash = HookMiner.initCodeHash(manager, address(work));
        (address predicted, bytes32 salt) = HookMiner.find(address(this), hash, 0, 1_000_000);
        hook = new WorkLaunchHook{salt: salt}(manager, address(work));
        assertEq(address(hook), predicted);
        assertEq(uint160(address(hook)) & 0x3fff, 0x2044);

        (address c0, address c1) = address(work) < IMD ? (address(work), IMD) : (IMD, address(work));
        key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 12500, 60, IHooks(address(hook)));
        router = new PoolSwapTest(manager);
        liquidityRouter = new PoolModifyLiquidityTest(manager);
        work.approve(address(liquidityRouter), type(uint256).max);
        pair.approve(address(liquidityRouter), type(uint256).max);
        manager.initialize(key, INITIAL_PRICE);
        // Full range keeps repeated bounded trades liquid in either direction.
        liquidityRouter.modifyLiquidity(
            key, IPoolManager.ModifyLiquidityParams(-887220, 887220, 1_000_000 ether, bytes32(0)), ""
        );

        actors = [makeAddr("pool trader Alice"), makeAddr("pool trader Bob"), makeAddr("pool trader Carol")];
        for (uint256 i; i < actors.length; ++i) {
            work.transfer(actors[i], 10_000_000 ether);
            pair.transfer(actors[i], 10_000_000 ether);
            vm.startPrank(actors[i]);
            work.approve(address(router), type(uint256).max);
            pair.approve(address(router), type(uint256).max);
            work.approve(address(liquidityRouter), type(uint256).max);
            pair.approve(address(liquidityRouter), type(uint256).max);
            vm.stopPrank();
        }
    }
}
