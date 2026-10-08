// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Work} from "../src/Work.sol";
import {WorkLaunchHook} from "../src/WorkLaunchHook.sol";
import {HookMiner} from "../script/HookMiner.sol";
import {PairToken, RejectNative, ForceNativeBalance} from "./helpers/PairToken.sol";

contract WorkLaunchHookTest is Test {
    using StateLibrary for IPoolManager;

    address internal constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address internal constant TREASURY = 0xc9EAFE33A510a3a3d95A94c4f85AdaF6a3EA12a0;
    uint160 internal constant INITIAL_PRICE = 79228162514264337593543950336;
    uint256 internal constant OPEN_TIME = 1_700_000_000;

    IPoolManager internal manager;
    Work internal work;
    PairToken internal pair;
    WorkLaunchHook internal hook;
    PoolSwapTest internal router;
    PoolModifyLiquidityTest internal liquidityRouter;
    PoolKey internal key;
    PoolKey internal controlKey;

    event StandingFee(uint256 fee);

    function setUp() public {
        vm.warp(OPEN_TIME);
        manager = IPoolManager(address(new PoolManager(address(this))));
        work = new Work();
        PairToken implementation = new PairToken();
        vm.etch(IMD, address(implementation).code);
        pair = PairToken(IMD);
        pair.mint(address(this), 1_000_000_000 ether);
        hook = _deployHook(address(work));
        key = _key(address(work), address(hook));
        controlKey = _key(address(work), address(0));
        router = new PoolSwapTest(manager);
        liquidityRouter = new PoolModifyLiquidityTest(manager);
        work.approve(address(router), 100_000_000 ether);
        pair.approve(address(router), 100_000_000 ether);
        work.approve(address(liquidityRouter), 100_000_000 ether);
        pair.approve(address(liquidityRouter), 100_000_000 ether);
    }

    function _deployHook(address token) internal returns (WorkLaunchHook deployed) {
        bytes32 hash = HookMiner.initCodeHash(manager, token);
        (address predicted, bytes32 salt) = HookMiner.find(address(this), hash, 0, 1_000_000);
        deployed = new WorkLaunchHook{salt: salt}(manager, token);
        assertEq(address(deployed), predicted);
    }

    function _key(address token, address hooks) internal pure returns (PoolKey memory) {
        (address c0, address c1) = token < IMD ? (token, IMD) : (IMD, token);
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), 12500, 60, IHooks(hooks));
    }

    function _initializeAndFund() internal {
        manager.initialize(key, INITIAL_PRICE);
        manager.initialize(controlKey, INITIAL_PRICE);
        IPoolManager.ModifyLiquidityParams memory p = IPoolManager.ModifyLiquidityParams({
            tickLower: -600, tickUpper: 600, liquidityDelta: 1_000_000 ether, salt: bytes32(0)
        });
        liquidityRouter.modifyLiquidity(key, p, "");
        liquidityRouter.modifyLiquidity(controlKey, p, "");
    }

    function _params(bool zeroForOne, int256 amount) internal pure returns (IPoolManager.SwapParams memory) {
        return IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amount,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
    }

    function _swap(PoolKey memory k, bool zeroForOne, int256 amount) internal returns (BalanceDelta) {
        return router.swap(k, _params(zeroForOne, amount), PoolSwapTest.TestSettings(false, false), "");
    }

    function _expectInitializationRejection(PoolKey memory invalid) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                bytes(""),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(invalid, INITIAL_PRICE);
        assertEq(hook.openedAt(), 0);
    }

    function testCreate2FlagsAndImmutables() public view {
        assertEq(uint160(address(hook)) & 0x3fff, 0x2044);
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.token(), address(work));
        assertEq(hook.IMD(), IMD);
        assertEq(hook.B(), TREASURY);
        assertEq(hook.standingFee(), 200);
    }

    function testWrongCreate2FlagsRevert() public {
        bytes32 hash = HookMiner.initCodeHash(manager, address(work));
        uint256 candidate;
        address predicted = HookMiner.predict(address(this), bytes32(candidate), hash);
        while (uint160(predicted) & 0x3fff == 0x2044) {
            predicted = HookMiner.predict(address(this), bytes32(++candidate), hash);
        }
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new WorkLaunchHook{salt: bytes32(candidate)}(manager, address(work));
    }

    function testRejectsZeroTokenAndIMDAsToken() public {
        vm.expectRevert();
        new WorkLaunchHook(manager, address(0));
        vm.expectRevert();
        new WorkLaunchHook(manager, IMD);
    }

    function testInitializeRecordsTimestampAndPrice() public {
        assertEq(hook.openedAt(), 0);
        assertEq(hook.feeNow(), 5000);
        manager.initialize(key, INITIAL_PRICE);
        assertEq(hook.openedAt(), OPEN_TIME);
        (uint160 price, int24 tick,, uint24 fee) = manager.getSlot0(key.toId());
        assertEq(price, INITIAL_PRICE);
        assertEq(tick, 0);
        assertEq(fee, 12500);
    }

    function testReviewThirdPartyCanInitializeBeforeFactory() public {
        uint160 attackerPrice = TickMath.MIN_SQRT_PRICE + 1;
        vm.prank(makeAddr("first initializer"));
        manager.initialize(key, attackerPrice);
        (uint160 price,,,) = manager.getSlot0(key.toId());
        assertEq(price, attackerPrice);
        assertEq(hook.openedAt(), OPEN_TIME);
        vm.expectRevert();
        manager.initialize(key, INITIAL_PRICE);
        vm.warp(OPEN_TIME + 1000);
        assertEq(manager.getLiquidity(key.toId()), 0);
        assertEq(hook.feeNow(), 200);
    }

    function testReviewRampCanExpireBeforeFirstLiquidity() public {
        manager.initialize(key, INITIAL_PRICE);
        manager.initialize(controlKey, INITIAL_PRICE);
        vm.warp(OPEN_TIME + 900);
        assertEq(manager.getLiquidity(key.toId()), 0);
        IPoolManager.ModifyLiquidityParams memory p =
            IPoolManager.ModifyLiquidityParams(-600, 600, 1_000_000 ether, bytes32(0));
        liquidityRouter.modifyLiquidity(key, p, "");
        liquidityRouter.modifyLiquidity(controlKey, p, "");
        assertEq(hook.feeNow(), 200);
        _assertSwapAgainstControl(Currency.unwrap(key.currency0) == IMD, true, 100 ether);
    }

    function testReviewHooklessPoolPaysNoHookFee() public {
        manager.initialize(key, INITIAL_PRICE);
        controlKey.fee = 3000;
        manager.initialize(controlKey, INITIAL_PRICE);
        liquidityRouter.modifyLiquidity(
            controlKey, IPoolManager.ModifyLiquidityParams(-600, 600, 1_000_000 ether, bytes32(0)), ""
        );
        bool buyIsZeroForOne = Currency.unwrap(controlKey.currency0) == IMD;
        BalanceDelta result = _swap(controlKey, buyIsZeroForOne, -100 ether);
        assertGt(buyIsZeroForOne ? result.amount1() : result.amount0(), 99 ether);
        assertEq(hook.feeNow(), 5000);
        _assertEmptyHook();
    }

    function testReviewExactInputDustRoundsToZero() public {
        _initializeAndFund();
        vm.warp(OPEN_TIME + 900);
        bool buyIsZeroForOne = Currency.unwrap(key.currency0) == IMD;
        BalanceDelta result = _swap(key, buyIsZeroForOne, -50);
        assertEq(buyIsZeroForOne ? result.amount1() : result.amount0(), 48);
        _assertEmptyHook();
    }

    function testReviewPermissionsAreAddressBitsWithoutGetter() public view {
        (bool success,) = address(hook).staticcall(abi.encodeWithSignature("getHookPermissions()"));
        assertFalse(success);
        assertEq(
            uint160(address(hook)) & Hooks.ALL_HOOK_MASK,
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
    }

    function testInitializeWorksWithBothTokenOrderings() public {
        // Only IMD is etched. WORK and hooks are deployed normally using CREATE/CREATE2.
        bool foundLower;
        bool foundHigher;
        for (uint256 i; i < 128 && !(foundLower && foundHigher); ++i) {
            Work other = new Work();
            bool lower = address(other) < IMD;
            if ((lower && foundLower) || (!lower && foundHigher)) continue;
            WorkLaunchHook otherHook = _deployHook(address(other));
            PoolKey memory otherKey = _key(address(other), address(otherHook));
            manager.initialize(otherKey, INITIAL_PRICE);
            assertEq(otherHook.openedAt(), OPEN_TIME);
            if (lower) foundLower = true;
            else foundHigher = true;
        }
        assertTrue(foundLower && foundHigher);
    }

    function testUnauthorizedCallbacksRevert() public {
        vm.expectRevert();
        hook.beforeInitialize(address(this), key, INITIAL_PRICE);
        vm.expectRevert();
        hook.afterSwap(address(this), key, _params(true, -1 ether), toBalanceDelta(-1 ether, 1 ether), "");
        vm.expectRevert();
        hook.unlockCallback("");
    }

    function testRejectsWrongPair() public {
        Work unrelated = new Work();
        PoolKey memory invalid = _key(address(unrelated), address(hook));
        _expectInitializationRejection(invalid);
    }

    function testRejectsWrongFee() public {
        PoolKey memory invalid = key;
        invalid.fee = 3000;
        _expectInitializationRejection(invalid);
    }

    function testRejectsZeroAndDynamicFee() public {
        PoolKey memory invalid = key;
        invalid.fee = 0;
        _expectInitializationRejection(invalid);
        invalid.fee = 0x800000;
        _expectInitializationRejection(invalid);
    }

    function testRejectsWrongTickSpacing() public {
        PoolKey memory invalid = key;
        invalid.tickSpacing = 10;
        _expectInitializationRejection(invalid);
    }

    function testRejectsNativePair() public {
        PoolKey memory invalid = key;
        invalid.currency0 = Currency.wrap(address(0));
        invalid.currency1 = Currency.wrap(address(work));
        _expectInitializationRejection(invalid);
    }

    function testRejectsWrongHookInAuthenticatedCallback() public {
        PoolKey memory invalid = key;
        invalid.hooks = IHooks(address(0));
        vm.prank(address(manager));
        vm.expectRevert();
        hook.beforeInitialize(address(this), invalid, INITIAL_PRICE);
    }

    function testCannotInitializeTwice() public {
        manager.initialize(key, INITIAL_PRICE);
        vm.warp(OPEN_TIME + 100);
        vm.expectRevert();
        manager.initialize(key, INITIAL_PRICE);
        vm.prank(address(manager));
        vm.expectRevert();
        hook.beforeInitialize(address(this), key, INITIAL_PRICE);
        assertEq(hook.openedAt(), OPEN_TIME);
    }

    function testInvalidInitialPriceRollsBackOpenedAt() public {
        vm.expectRevert();
        manager.initialize(key, 0);
        assertEq(hook.openedAt(), 0);
        manager.initialize(key, INITIAL_PRICE);
        assertEq(hook.openedAt(), OPEN_TIME);
    }

    function testFeeScheduleBoundaries() public {
        vm.warp(OPEN_TIME + 1 days);
        assertEq(hook.feeNow(), 5000);
        manager.initialize(key, INITIAL_PRICE);
        uint256 start = hook.openedAt();
        assertEq(hook.feeNow(), 5000);
        vm.warp(start + 1);
        assertEq(hook.feeNow(), 4994);
        vm.warp(start + 450);
        assertEq(hook.feeNow(), 2600);
        vm.warp(start + 899);
        assertEq(hook.feeNow(), 205);
        vm.warp(start + 900);
        assertEq(hook.feeNow(), 200);
        vm.warp(start + 365 days);
        assertEq(hook.feeNow(), 200);
    }

    function testAdminFeeBoundsAndEvent() public {
        vm.expectEmit(false, false, false, true, address(hook));
        emit StandingFee(1000);
        vm.prank(TREASURY);
        hook.setStandingFee(1000);
        assertEq(hook.standingFee(), 1000);
        vm.prank(TREASURY);
        hook.setStandingFee(0);
        assertEq(hook.standingFee(), 0);
        vm.prank(TREASURY);
        vm.expectRevert();
        hook.setStandingFee(1001);
        assertEq(hook.standingFee(), 0);
    }

    function testFuzzUnauthorizedAdmin(address caller, uint256 fee) public {
        vm.assume(caller != TREASURY);
        fee = bound(fee, 0, 1000);
        vm.prank(caller);
        vm.expectRevert();
        hook.setStandingFee(fee);
        assertEq(hook.standingFee(), 200);
    }

    function testFuzzRejectsOutOfRangeFee(uint256 fee) public {
        fee = bound(fee, 1001, type(uint256).max);
        vm.prank(TREASURY);
        vm.expectRevert();
        hook.setStandingFee(fee);
        assertEq(hook.standingFee(), 200);
    }

    function testStandingFeeChangeDuringAndAfterRamp() public {
        manager.initialize(key, INITIAL_PRICE);
        vm.warp(OPEN_TIME + 450);
        vm.prank(TREASURY);
        hook.setStandingFee(1000);
        assertEq(hook.feeNow(), 3000);
        assertEq(hook.openedAt(), OPEN_TIME);
        vm.warp(OPEN_TIME + 900);
        assertEq(hook.feeNow(), 1000);
        vm.prank(TREASURY);
        hook.setStandingFee(0);
        assertEq(hook.feeNow(), 0);
    }

    function testFuzzScheduleIsBoundedAndMonotone(uint256 elapsed, uint256 fee) public {
        elapsed = bound(elapsed, 0, 1800);
        fee = bound(fee, 0, 1000);
        vm.prank(TREASURY);
        hook.setStandingFee(fee);
        manager.initialize(key, INITIAL_PRICE);
        vm.warp(OPEN_TIME + elapsed);
        uint256 current = hook.feeNow();
        assertGe(current, fee);
        assertLe(current, 5000);
        vm.warp(OPEN_TIME + elapsed + 1);
        assertLe(hook.feeNow(), current);
        vm.warp(OPEN_TIME + 900);
        assertEq(hook.feeNow(), fee);
    }

    function _assertSwapAgainstControl(bool zeroForOne, bool exactInput, uint256 amount) internal {
        int256 specified = exactInput ? -int256(amount) : int256(amount);
        BalanceDelta base = _swap(controlKey, zeroForOne, specified);
        IERC20 token0 = IERC20(Currency.unwrap(key.currency0));
        IERC20 token1 = IERC20(Currency.unwrap(key.currency1));
        uint256 before0 = token0.balanceOf(address(this));
        uint256 before1 = token1.balanceOf(address(this));
        uint256 managerBefore0 = token0.balanceOf(address(manager));
        uint256 managerBefore1 = token1.balanceOf(address(manager));
        uint256 claimsBefore0 = manager.balanceOf(address(hook), key.currency0.toId());
        uint256 claimsBefore1 = manager.balanceOf(address(hook), key.currency1.toId());
        BalanceDelta actual = _swap(key, zeroForOne, specified);

        // Independent pool provides the pre-hook delta. Exact input charges output;
        // exact output charges input, determined from swap direction, not hook code.
        bool chargeToken0 = exactInput ? !zeroForOne : zeroForOne;
        int256 baseCharge = chargeToken0 ? int256(base.amount0()) : int256(base.amount1());
        uint256 magnitude = uint256(baseCharge < 0 ? -baseCharge : baseCharge);
        uint256 rate = hook.feeNow();
        uint256 expected = magnitude * rate / (exactInput ? 10_000 : 10_000 - rate);
        assertEq(int256(actual.amount0()), int256(base.amount0()) - (chargeToken0 ? int256(expected) : int256(0)));
        assertEq(int256(actual.amount1()), int256(base.amount1()) - (chargeToken0 ? int256(0) : int256(expected)));
        assertEq(manager.balanceOf(address(hook), key.currency0.toId()) - claimsBefore0, chargeToken0 ? expected : 0);
        assertEq(manager.balanceOf(address(hook), key.currency1.toId()) - claimsBefore1, chargeToken0 ? 0 : expected);
        assertEq(int256(token0.balanceOf(address(this))) - int256(before0), int256(actual.amount0()));
        assertEq(int256(token1.balanceOf(address(this))) - int256(before1), int256(actual.amount1()));
        assertEq(int256(token0.balanceOf(address(manager))) - int256(managerBefore0), -int256(actual.amount0()));
        assertEq(int256(token1.balanceOf(address(manager))) - int256(managerBefore1), -int256(actual.amount1()));
        assertEq(token0.balanceOf(address(hook)), 0);
        assertEq(token1.balanceOf(address(hook)), 0);
        assertEq(work.totalSupply(), 1_000_000_000 ether);

        // Independently measure the effective rate from the trader's actual deltas.
        // Input fees are a fraction of total paid; output fees are a fraction of pool output.
        int256 actualCharge = chargeToken0 ? int256(actual.amount0()) : int256(actual.amount1());
        uint256 charged = uint256(baseCharge - actualCharge);
        uint256 gross = exactInput ? magnitude : uint256(-actualCharge);
        assertLe(charged * 10_000, gross * rate);
        assertLt(gross * rate - charged * 10_000, 10_000, "effective fee shortfall exceeds rounding");
    }

    function _assertAllSwapModes() internal {
        _assertSwapAgainstControl(true, true, 100 ether);
        _assertSwapAgainstControl(false, true, 100 ether);
        _assertSwapAgainstControl(true, false, 100 ether);
        _assertSwapAgainstControl(false, false, 100 ether);
    }

    function testAllSwapModesAtLaunch() public {
        _initializeAndFund();
        assertEq(hook.feeNow(), 5000);
        _assertAllSwapModes();
    }

    function testAllSwapModesMidRamp() public {
        _initializeAndFund();
        vm.warp(OPEN_TIME + 450);
        assertEq(hook.feeNow(), 2600);
        _assertAllSwapModes();
    }

    function testAllSwapModesAtStandingFee() public {
        _initializeAndFund();
        vm.warp(OPEN_TIME + 900);
        assertEq(hook.feeNow(), 200);
        _assertAllSwapModes();
    }

    function testAllSwapModesAtMaxStandingFee() public {
        _initializeAndFund();
        vm.warp(OPEN_TIME + 900);
        vm.prank(TREASURY);
        hook.setStandingFee(1000);
        _assertAllSwapModes();
    }

    function testZeroStandingFeeStillChargesDuringLaunch() public {
        _initializeAndFund();
        vm.prank(TREASURY);
        hook.setStandingFee(0);
        assertEq(hook.feeNow(), 5000);
        _assertSwapAgainstControl(true, true, 100 ether);
        vm.warp(OPEN_TIME + 900);
        assertEq(hook.feeNow(), 0);
        _assertAllSwapModes();
    }

    function testDustFeeRoundsDownToZero() public {
        _initializeAndFund();
        vm.warp(OPEN_TIME + 900);
        _assertSwapAgainstControl(true, false, 1);
        assertEq(manager.balanceOf(address(hook), key.currency0.toId()), 0);
        assertEq(manager.balanceOf(address(hook), key.currency1.toId()), 0);
    }

    function testPartialFillsChargeOnlyExecutedUnspecifiedAmount() public {
        _initializeAndFund();
        _assertSwapAgainstControl(true, true, 100_000 ether);
        _assertSwapAgainstControl(false, true, 100_000 ether);
        _assertSwapAgainstControl(true, false, 100_000 ether);
        _assertSwapAgainstControl(false, false, 100_000 ether);
    }

    function testSettlementFailureRollsBackSwapAndFeeClaims() public {
        _initializeAndFund();
        IERC20(Currency.unwrap(key.currency0)).approve(address(router), 0);
        vm.expectRevert();
        _swap(key, true, -100 ether);
        _assertEmptyHook();
        (uint160 price,,,) = manager.getSlot0(key.toId());
        assertEq(price, INITIAL_PRICE);
    }

    function testFuzzSwapAccounting(bool zeroForOne, bool exactInput, uint256 amount, uint256 elapsed, uint256 fee)
        public
    {
        amount = bound(amount, 1, 1000 ether);
        elapsed = bound(elapsed, 0, 1800);
        fee = bound(fee, 0, 1000);
        _initializeAndFund();
        vm.prank(TREASURY);
        hook.setStandingFee(fee);
        vm.warp(OPEN_TIME + elapsed);
        _assertSwapAgainstControl(zeroForOne, exactInput, amount);
    }

    function _accrueBothCurrencies() internal {
        _initializeAndFund();
        _swap(key, true, -100 ether);
        _swap(key, false, -100 ether);
        assertGt(manager.balanceOf(address(hook), key.currency0.toId()), 0);
        assertGt(manager.balanceOf(address(hook), key.currency1.toId()), 0);
    }

    function testPermissionlessSweepConservesBothCurrenciesAndDonations() public {
        _accrueBothCurrencies();
        uint256 claimWork = manager.balanceOf(address(hook), uint160(address(work)));
        uint256 claimIMD = manager.balanceOf(address(hook), uint160(IMD));
        uint256 managerWork = work.balanceOf(address(manager));
        uint256 managerIMD = pair.balanceOf(address(manager));
        work.transfer(address(hook), 7 ether);
        pair.transfer(address(hook), 9 ether);
        address caller = makeAddr("sweeper");
        vm.prank(caller);
        hook.sweep();
        assertEq(work.balanceOf(TREASURY), claimWork + 7 ether);
        assertEq(pair.balanceOf(TREASURY), claimIMD + 9 ether);
        assertEq(work.balanceOf(address(manager)), managerWork - claimWork);
        assertEq(pair.balanceOf(address(manager)), managerIMD - claimIMD);
        assertEq(work.balanceOf(caller), 0);
        assertEq(pair.balanceOf(caller), 0);
        _assertEmptyHook();
        hook.sweep();
        assertEq(work.balanceOf(TREASURY), claimWork + 7 ether);
        assertEq(pair.balanceOf(TREASURY), claimIMD + 9 ether);
        // A later swap still accrues and can be swept again.
        _swap(key, true, -100 ether);
        hook.sweep();
        _assertEmptyHook();
    }

    function _assertEmptyHook() internal view {
        assertEq(manager.balanceOf(address(hook), uint160(address(work))), 0);
        assertEq(manager.balanceOf(address(hook), uint160(IMD)), 0);
        assertEq(work.balanceOf(address(hook)), 0);
        assertEq(pair.balanceOf(address(hook)), 0);
        assertEq(address(hook).balance, 0);
    }

    function testSweepBeforeInitializationAndWithNoFees() public {
        hook.sweep();
        _assertEmptyHook();
        manager.initialize(key, INITIAL_PRICE);
        hook.sweep();
        _assertEmptyHook();
    }

    function testRevertingTokenTransferPreservesClaims() public {
        _accrueBothCurrencies();
        uint256 claimIMD = manager.balanceOf(address(hook), uint160(IMD));
        uint256 claimWork = manager.balanceOf(address(hook), uint160(address(work)));
        pair.blockRecipient(TREASURY);
        vm.expectRevert();
        hook.sweep();
        assertEq(manager.balanceOf(address(hook), uint160(IMD)), claimIMD);
        assertEq(manager.balanceOf(address(hook), uint160(address(work))), claimWork);
        assertEq(pair.balanceOf(TREASURY), 0);
        assertEq(work.balanceOf(TREASURY), 0);
        pair.blockRecipient(address(0));
        hook.sweep();
        _assertEmptyHook();
    }

    function testForcedWeiCannotBlockTokenClaimsOrDonations() public {
        _accrueBothCurrencies();
        uint256 claimIMD = manager.balanceOf(address(hook), uint160(IMD));
        uint256 claimWork = manager.balanceOf(address(hook), uint160(address(work)));
        RejectNative rejector = new RejectNative();
        vm.etch(TREASURY, address(rejector).code);
        work.transfer(address(hook), 7 ether);
        pair.transfer(address(hook), 9 ether);
        address griefer = makeAddr("forced ETH sender");
        vm.deal(griefer, 1);
        vm.prank(griefer);
        new ForceNativeBalance{value: 1}(payable(address(hook)));
        assertEq(address(hook).balance, 1);
        uint256 treasuryNativeBefore = TREASURY.balance;
        vm.prank(makeAddr("permissionless sweeper"));
        hook.sweep();
        assertEq(manager.balanceOf(address(hook), uint160(IMD)), 0);
        assertEq(manager.balanceOf(address(hook), uint160(address(work))), 0);
        assertEq(pair.balanceOf(TREASURY), claimIMD + 9 ether);
        assertEq(work.balanceOf(TREASURY), claimWork + 7 ether);
        assertEq(pair.balanceOf(address(hook)), 0);
        assertEq(work.balanceOf(address(hook)), 0);
        assertEq(address(hook).balance, 1);
        assertEq(TREASURY.balance, treasuryNativeBefore);
        hook.sweep();
        assertEq(pair.balanceOf(TREASURY), claimIMD + 9 ether);
        assertEq(work.balanceOf(TREASURY), claimWork + 7 ether);
    }

    function testSweepCannotNestInsideManagerUnlock() public {
        manager.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(manager));
        vm.expectRevert(IPoolManager.AlreadyUnlocked.selector);
        hook.sweep();
        return "";
    }

    function testSwapBeforeInitializationReverts() public {
        vm.expectRevert(Pool.PoolNotInitialized.selector);
        _swap(key, true, -1 ether);
    }

    function testZeroSwapRevertsWithoutClaims() public {
        _initializeAndFund();
        vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
        _swap(key, true, 0);
        _assertEmptyHook();
    }
}
