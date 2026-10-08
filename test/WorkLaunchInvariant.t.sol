// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {WorkPoolFixture} from "./helpers/WorkPoolFixture.sol";
import {WorkLaunchHandler} from "./helpers/WorkLaunchHandler.sol";

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract WorkLaunchInvariantTest is WorkPoolFixture {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    WorkLaunchHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new WorkLaunchHandler(hook, router, liquidityRouter, key, actors);
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = handler.swap.selector;
        selectors[1] = handler.donate.selector;
        selectors[2] = handler.sweep.selector;
        selectors[3] = handler.advanceTime.selector;
        selectors[4] = handler.setStandingFee.selector;
        selectors[5] = handler.rejectFeeChange.selector;
        selectors[6] = handler.rejectCallback.selector;
        selectors[7] = handler.rejectClaimTheft.selector;
        selectors[8] = handler.failedSweep.selector;
        selectors[9] = handler.liquidityRoundTrip.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));

        // Start with real, nonzero claims in both currencies and every swap mode.
        handler.swap(0, true, true, 100 ether);
        handler.swap(1, true, false, 100 ether);
        handler.swap(2, false, true, 100 ether);
        handler.swap(0, false, false, 100 ether);
        handler.donate(1, false, 7 ether);
        handler.donate(2, true, 9 ether);
    }

    function invariant_feesAndDonationsAreConservedAndBacked() public view {
        for (uint256 i; i < 2; ++i) {
            IERC20 currency = handler.currencies(i);
            uint256 claims = manager.balanceOf(address(hook), uint160(address(currency)));
            assertEq(claims + handler.paidClaims(i), handler.accrued(i), "claims lost or invented");
            assertEq(currency.balanceOf(address(hook)) + handler.paidDonations(i), handler.donated(i));
            assertEq(currency.balanceOf(TREASURY), handler.paidClaims(i) + handler.paidDonations(i));
            assertEq(currency.balanceOf(address(manager)), handler.poolAssets(i) + claims, "unbacked claims");
            assertEq(
                claims + currency.balanceOf(address(hook)) + currency.balanceOf(TREASURY),
                handler.accrued(i) + handler.donated(i),
                "fee value disappeared"
            );
        }
    }

    function invariant_supplyIsConservedAcrossAllHolders() public view {
        assertEq(work.totalSupply(), 1_000_000_000 ether);
        for (uint256 i; i < 2; ++i) {
            IERC20 currency = handler.currencies(i);
            uint256 total = currency.balanceOf(address(this)) + currency.balanceOf(address(manager))
                + currency.balanceOf(address(hook)) + currency.balanceOf(TREASURY);
            for (uint256 j; j < actors.length; ++j) {
                total += currency.balanceOf(actors[j]);
            }
            assertEq(total, currency.totalSupply());
            assertEq(currency.balanceOf(address(router)), 0);
            assertEq(currency.balanceOf(address(liquidityRouter)), 0);
            assertEq(currency.balanceOf(address(handler)), 0);
        }
    }

    function invariant_launchAndSettlementRemainValid() public view {
        assertEq(hook.openedAt(), OPEN_TIME, "launch timer reset");
        assertEq(hook.standingFee(), handler.expectedStanding(), "unauthorized fee change");
        assertLe(hook.standingFee(), 1000);
        assertGe(hook.feeNow(), hook.standingFee());
        assertLe(hook.feeNow(), 5000);
        if (vm.getBlockTimestamp() >= OPEN_TIME + 900) assertEq(hook.feeNow(), hook.standingFee());
        assertFalse(manager.isUnlocked());
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency0), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency1), 0);
        assertEq(manager.getLiquidity(key.toId()), 1_000_000 ether);
    }

    function afterInvariant() public {
        // Withdrawal liveness at the end of EVERY random sequence, including
        // sequences ending with a failed sweep, donation, or admin change.
        handler.sweep(0);
        handler.sweep(1);
        invariant_feesAndDonationsAreConservedAndBacked();
        invariant_supplyIsConservedAcrossAllHolders();
        invariant_launchAndSettlementRemainValid();
    }

    function testHandlerExercisesEveryActionAndCanResumeAfterFailure() public {
        for (uint256 i; i < 4; ++i) {
            assertGt(handler.swapsByMode(i), 0);
        }
        handler.failedSweep(2);
        handler.rejectClaimTheft(0, false);
        handler.rejectClaimTheft(1, true);
        handler.rejectCallback(0, false);
        handler.rejectCallback(1, true);
        handler.rejectFeeChange(0, 1000, true);
        handler.rejectFeeChange(0, type(uint256).max, false);
        handler.liquidityRoundTrip(0, 1);
        handler.liquidityRoundTrip(2, 1000 ether);
        handler.setStandingFee(0);
        for (uint256 i; i < 8; ++i) {
            handler.advanceTime(120);
        }
        handler.swap(0, true, true, 1);
        handler.setStandingFee(1000);
        handler.swap(1, false, false, 1000 ether);
        invariant_feesAndDonationsAreConservedAndBacked();
        afterInvariant();
        assertEq(handler.sweepCalls(), 2);
    }
}
