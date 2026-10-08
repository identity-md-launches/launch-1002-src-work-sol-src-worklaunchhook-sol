// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {WorkLaunchHook} from "src/WorkLaunchHook.sol";
import {PairToken} from "./PairToken.sol";

contract WorkLaunchHandler is Test {
    using StateLibrary for IPoolManager;

    bytes32 internal constant SWAP_EVENT =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    IPoolManager public immutable manager;
    WorkLaunchHook public immutable hook;
    PoolSwapTest public immutable router;
    PoolModifyLiquidityTest public immutable liquidityRouter;
    address public immutable treasury;
    PoolKey internal key;
    address[3] public actors;
    IERC20[2] public currencies;

    // These ledgers come from observed pool deltas and actual transfers, never
    // by copying the hook's fee formula or resetting ghosts to its claim balance.
    uint256[2] public accrued;
    uint256[2] public donated;
    uint256[2] public paidClaims;
    uint256[2] public paidDonations;
    uint256[2] public poolAssets;
    uint256[4] public swapsByMode;
    uint256 public sweepCalls;
    uint256 public expectedStanding = 200;

    constructor(
        WorkLaunchHook hook_,
        PoolSwapTest router_,
        PoolModifyLiquidityTest liquidityRouter_,
        PoolKey memory key_,
        address[3] memory actors_
    ) {
        hook = hook_;
        manager = hook_.poolManager();
        treasury = hook_.B();
        router = router_;
        liquidityRouter = liquidityRouter_;
        key = key_;
        actors = actors_;
        currencies[0] = IERC20(Currency.unwrap(key_.currency0));
        currencies[1] = IERC20(Currency.unwrap(key_.currency1));
        for (uint256 i; i < 2; ++i) {
            poolAssets[i] = currencies[i].balanceOf(address(manager));
        }
    }

    function swap(uint256 actorSeed, bool zeroForOne, bool exactInput, uint256 amountSeed) public {
        address actor = actors[actorSeed % 3];
        uint256 amount = bound(amountSeed, 1, 1000 ether);
        uint256[2] memory beforeBalances = _balances(actor);
        uint256 rate = hook.feeNow();
        vm.recordLogs();
        vm.prank(actor);
        BalanceDelta actual = router.swap(
            key,
            IPoolManager.SwapParams(
                zeroForOne,
                exactInput ? -int256(amount) : int256(amount),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        int256[2] memory raw = _poolSwapDeltas(vm.getRecordedLogs());
        int256[2] memory settled = [int256(actual.amount0()), int256(actual.amount1())];
        uint256 chargeIndex = exactInput ? (zeroForOne ? 1 : 0) : (zeroForOne ? 0 : 1);
        for (uint256 i; i < 2; ++i) {
            assertEq(int256(currencies[i].balanceOf(actor)) - int256(beforeBalances[i]), settled[i]);
            assertGe(raw[i], settled[i], "hook may only debit fees");
            uint256 fee = uint256(raw[i] - settled[i]);
            if (i == chargeIndex) {
                // Fee as a fraction of gross received (exact input) or total paid
                // (exact output). Less than one base unit may be lost to rounding.
                uint256 gross = uint256(exactInput ? raw[i] : -settled[i]);
                assertLe(fee * 10_000, gross * rate, "fee above advertised rate");
                assertLt(gross * rate - fee * 10_000, 10_000, "fee below advertised rate");
            } else {
                assertEq(fee, 0, "fee charged on specified side");
            }
            accrued[i] += fee;
            poolAssets[i] = _addDelta(poolAssets[i], -raw[i]);
        }
        ++swapsByMode[(zeroForOne ? 0 : 2) + (exactInput ? 0 : 1)];
    }

    function donate(uint256 actorSeed, bool token1, uint256 amountSeed) public {
        uint256 i = token1 ? 1 : 0;
        uint256 amount = bound(amountSeed, 0, 100 ether);
        vm.prank(actors[actorSeed % 3]);
        assertTrue(currencies[i].transfer(address(hook), amount));
        donated[i] += amount;
    }

    function sweep(uint256 actorSeed) public {
        address actor = actors[actorSeed % 3];
        uint256[2] memory beforeBalances = _balances(actor);
        vm.prank(actor);
        hook.sweep();
        for (uint256 i; i < 2; ++i) {
            paidClaims[i] = accrued[i];
            paidDonations[i] = donated[i];
            assertEq(currencies[i].balanceOf(actor), beforeBalances[i], "sweeper received fees");
            assertEq(currencies[i].balanceOf(address(hook)), 0, "donation left after sweep");
            assertEq(manager.balanceOf(address(hook), uint160(address(currencies[i]))), 0, "claim left after sweep");
            assertEq(currencies[i].balanceOf(treasury), paidClaims[i] + paidDonations[i]);
        }
        ++sweepCalls;
    }

    function advanceTime(uint256 elapsedSeed) public {
        uint256 rate = hook.feeNow();
        vm.warp(vm.getBlockTimestamp() + bound(elapsedSeed, 0, 120));
        assertLe(hook.feeNow(), rate, "time increased fee without admin action");
    }

    function setStandingFee(uint256 feeSeed) public {
        uint256 fee = bound(feeSeed, 0, 1000);
        vm.prank(treasury);
        hook.setStandingFee(fee);
        expectedStanding = fee;
    }

    function rejectFeeChange(uint256 actorSeed, uint256 feeSeed, bool unauthorized) public {
        uint256 fee = unauthorized ? bound(feeSeed, 0, 1000) : bound(feeSeed, 1001, type(uint256).max);
        vm.prank(unauthorized ? actors[actorSeed % 3] : treasury);
        vm.expectRevert();
        hook.setStandingFee(fee);
        assertEq(hook.standingFee(), expectedStanding);
    }

    function rejectCallback(uint256 actorSeed, bool unlock) public {
        vm.prank(actors[actorSeed % 3]);
        vm.expectRevert();
        if (unlock) hook.unlockCallback("");
        else hook.beforeInitialize(actors[actorSeed % 3], key, 79228162514264337593543950336);
    }

    function rejectClaimTheft(uint256 actorSeed, bool token1) public {
        uint256 i = token1 ? 1 : 0;
        address actor = actors[actorSeed % 3];
        uint256 id = uint160(address(currencies[i]));
        uint256 beforeClaims = manager.balanceOf(address(hook), id);
        vm.prank(actor);
        vm.expectRevert();
        manager.transferFrom(address(hook), actor, id, 1);
        assertEq(manager.balanceOf(address(hook), id), beforeClaims);
        assertEq(manager.balanceOf(actor, id), 0);
    }

    function failedSweep(uint256 actorSeed) public {
        // Ensure the token failure is reachable, even immediately after a sweep
        // or when the admin has set a zero fee. No balances are cheatcode-minted.
        bool imdIsToken1 = address(currencies[1]) == hook.IMD();
        donate(actorSeed, imdIsToken1, 1);
        bytes32 beforeState = _fundsDigest();
        PairToken(hook.IMD()).blockRecipient(treasury);
        vm.prank(actors[actorSeed % 3]);
        vm.expectRevert();
        hook.sweep();
        assertEq(_fundsDigest(), beforeState, "failed sweep changed balances or claims");
        PairToken(hook.IMD()).blockRecipient(address(0));
    }

    function liquidityRoundTrip(uint256 actorSeed, uint256 amountSeed) public {
        address actor = actors[actorSeed % 3];
        uint256 amount = bound(amountSeed, 1, 1000 ether);
        uint256[2] memory beforeBalances = _balances(actor);
        uint256[2] memory beforeClaims;
        for (uint256 i; i < 2; ++i) {
            beforeClaims[i] = manager.balanceOf(address(hook), uint160(address(currencies[i])));
        }
        // Separate position from the initial LP; no fees have accrued to this
        // position when it is immediately removed in the same transaction.
        bytes32 salt = bytes32(uint256(uint160(actor)));
        vm.startPrank(actor);
        BalanceDelta added = liquidityRouter.modifyLiquidity(
            key, IPoolManager.ModifyLiquidityParams(-887220, 887220, int256(amount), salt), ""
        );
        BalanceDelta removed = liquidityRouter.modifyLiquidity(
            key, IPoolManager.ModifyLiquidityParams(-887220, 887220, -int256(amount), salt), ""
        );
        vm.stopPrank();
        int256[2] memory net =
            [int256(added.amount0()) + removed.amount0(), int256(added.amount1()) + removed.amount1()];
        for (uint256 i; i < 2; ++i) {
            assertLe(currencies[i].balanceOf(actor), beforeBalances[i], "LP round trip created tokens");
            assertEq(int256(currencies[i].balanceOf(actor)) - int256(beforeBalances[i]), net[i]);
            assertEq(
                manager.balanceOf(address(hook), uint160(address(currencies[i]))), beforeClaims[i], "fee on liquidity"
            );
            poolAssets[i] = _addDelta(poolAssets[i], -net[i]);
        }
        (uint128 remaining,,) = manager.getPositionInfo(key.toId(), address(liquidityRouter), -887220, 887220, salt);
        assertEq(remaining, 0);
    }

    function _poolSwapDeltas(Vm.Log[] memory logs) internal view returns (int256[2] memory raw) {
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(manager) || logs[i].topics.length != 3 || logs[i].topics[0] != SWAP_EVENT) {
                continue;
            }
            assertEq(logs[i].topics[1], PoolId.unwrap(key.toId()));
            (int128 a0, int128 a1,,,,) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            raw = [int256(a0), int256(a1)];
            ++count;
        }
        assertEq(count, 1, "missing or ambiguous raw pool delta");
    }

    function _balances(address actor) internal view returns (uint256[2] memory) {
        return [currencies[0].balanceOf(actor), currencies[1].balanceOf(actor)];
    }

    function _fundsDigest() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                _balances(address(manager)),
                _balances(address(hook)),
                _balances(treasury),
                manager.balanceOf(address(hook), key.currency0.toId()),
                manager.balanceOf(address(hook), key.currency1.toId())
            )
        );
    }

    function _addDelta(uint256 balance, int256 delta) internal pure returns (uint256) {
        return delta >= 0 ? balance + uint256(delta) : balance - uint256(-delta);
    }
}
