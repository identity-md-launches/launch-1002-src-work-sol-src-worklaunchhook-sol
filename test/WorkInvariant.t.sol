// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Work} from "src/Work.sol";

contract WorkTokenHandler is Test {
    Work public immutable work;
    address[3] public actors;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;

    constructor(Work work_, address[3] memory actors_, uint256[3] memory balances_) {
        work = work_;
        actors = actors_;
        for (uint256 i; i < 3; ++i) {
            expectedBalance[actors_[i]] = balances_[i];
        }
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) public {
        address from = actors[fromSeed % 3];
        address to = actors[toSeed % 3];
        uint256 amount = bound(amountSeed, 0, expectedBalance[from]);
        vm.prank(from);
        assertTrue(work.transfer(to, amount));
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool infinite) public {
        address owner = actors[ownerSeed % 3];
        address spender = actors[spenderSeed % 3];
        if (infinite) amount = type(uint256).max;
        vm.prank(owner);
        assertTrue(work.approve(spender, amount));
        expectedAllowance[owner][spender] = amount;
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed) public {
        address owner = actors[ownerSeed % 3];
        address spender = actors[spenderSeed % 3];
        address to = actors[toSeed % 3];
        uint256 allowance = expectedAllowance[owner][spender];
        uint256 max = allowance < expectedBalance[owner] ? allowance : expectedBalance[owner];
        uint256 amount = bound(amountSeed, 0, max);
        vm.prank(spender);
        assertTrue(work.transferFrom(owner, to, amount));
        expectedBalance[owner] -= amount;
        expectedBalance[to] += amount;
        if (allowance != type(uint256).max) expectedAllowance[owner][spender] -= amount;
    }

    function rejectOverspend(uint256 ownerSeed, uint256 amountSeed) public {
        address owner = actors[ownerSeed % 3];
        uint256 balance = expectedBalance[owner];
        uint256 amount = bound(amountSeed, balance + 1, type(uint256).max);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, amount));
        work.transfer(actors[(ownerSeed % 3 + 1) % 3], amount);
    }

    function revokeAndRejectSpender(uint256 ownerSeed) public {
        uint256 i = ownerSeed % 3;
        address owner = actors[i];
        address spender = actors[(i + 1) % 3];
        vm.prank(owner);
        work.approve(spender, 0);
        expectedAllowance[owner][spender] = 0;
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        work.transferFrom(owner, spender, 1);
    }

    function rejectZeroRecipient(uint256 ownerSeed, uint256 amountSeed) public {
        address owner = actors[ownerSeed % 3];
        uint256 amount = bound(amountSeed, 0, expectedBalance[owner]);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        work.transfer(address(0), amount);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract WorkInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    Work internal work;
    WorkTokenHandler internal handler;
    address[3] internal actors;

    function setUp() public {
        work = new Work();
        actors = [makeAddr("WORK Alice"), makeAddr("WORK Bob"), makeAddr("WORK Carol")];
        uint256[3] memory amounts = [SUPPLY / 3, SUPPLY / 3, SUPPLY - 2 * (SUPPLY / 3)];
        for (uint256 i; i < 3; ++i) {
            work.transfer(actors[i], amounts[i]);
        }
        handler = new WorkTokenHandler(work, actors, amounts);
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.transferFrom.selector;
        selectors[3] = handler.rejectOverspend.selector;
        selectors[4] = handler.revokeAndRejectSpender.selector;
        selectors[5] = handler.rejectZeroRecipient.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
        // Finite and infinite allowance states are reachable immediately.
        handler.approve(0, 1, 100 ether, false);
        handler.approve(1, 2, 0, true);
    }

    function invariant_fixedSupplyAndIndividualBalancesMatchLedger() public view {
        uint256 sum;
        for (uint256 i; i < 3; ++i) {
            uint256 balance = work.balanceOf(actors[i]);
            assertEq(balance, handler.expectedBalance(actors[i]), "tokens moved without authorization");
            sum += balance;
        }
        assertEq(sum, SUPPLY);
        assertEq(work.totalSupply(), SUPPLY);
        assertEq(work.balanceOf(address(0)), 0);
        assertEq(work.balanceOf(address(this)), 0);
        assertEq(work.balanceOf(address(handler)), 0);
    }

    function invariant_allowancesMatchApprovalsAndSpending() public view {
        for (uint256 i; i < 3; ++i) {
            for (uint256 j; j < 3; ++j) {
                assertEq(work.allowance(actors[i], actors[j]), handler.expectedAllowance(actors[i], actors[j]));
            }
        }
    }

    function testFullSupplyZeroSelfAndInfiniteAllowanceSequence() public {
        handler.transfer(1, 0, work.balanceOf(actors[1]));
        handler.transfer(2, 0, work.balanceOf(actors[2]));
        assertEq(work.balanceOf(actors[0]), SUPPLY);
        handler.transfer(0, 0, SUPPLY);
        handler.transfer(0, 1, 0);
        handler.transfer(0, 1, 1);
        handler.approve(0, 2, 0, true);
        handler.transferFrom(0, 2, 1, work.balanceOf(actors[0]));
        assertEq(work.allowance(actors[0], actors[2]), type(uint256).max);
        assertEq(work.balanceOf(actors[1]), SUPPLY);
        handler.rejectOverspend(1, type(uint256).max);
        handler.rejectZeroRecipient(1, SUPPLY);
        handler.revokeAndRejectSpender(1);
        invariant_fixedSupplyAndIndividualBalancesMatchLedger();
        invariant_allowancesMatchApprovalsAndSpending();
    }
}
