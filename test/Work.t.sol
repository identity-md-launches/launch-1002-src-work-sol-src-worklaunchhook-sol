// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Work} from "../src/Work.sol";

/// forge-config: default.fuzz.runs = 1000
contract WorkTest is Test {
    Work internal work;

    function setUp() public {
        work = new Work();
    }

    function testMetadataAndSupply() public view {
        assertEq(work.name(), "Work");
        assertEq(work.symbol(), "WORK");
        assertEq(work.decimals(), 18);
        assertEq(work.totalSupply(), 1_000_000_000 ether);
        assertEq(work.balanceOf(address(this)), work.totalSupply());
    }

    function testFuzzTransferPreservesSupply(uint256 amount) public {
        amount = bound(amount, 0, work.totalSupply());
        address recipient = makeAddr("recipient");
        assertTrue(work.transfer(recipient, amount));
        assertEq(work.balanceOf(recipient), amount);
        assertEq(work.balanceOf(address(this)), work.totalSupply() - amount);
        assertEq(work.totalSupply(), 1_000_000_000 ether);
    }

    function testAllowanceTransferAndExhaustion() public {
        address spender = makeAddr("spender");
        address recipient = makeAddr("recipient");
        work.approve(spender, 7 ether);
        vm.prank(spender);
        work.transferFrom(address(this), recipient, 7 ether);
        assertEq(work.balanceOf(recipient), 7 ether);
        assertEq(work.allowance(address(this), spender), 0);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        work.transferFrom(address(this), recipient, 1);
    }

    function testRejectsInsufficientBalance() public {
        address empty = makeAddr("empty");
        vm.prank(empty);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, empty, 0, 1));
        work.transfer(address(this), 1);
    }

    function testRejectsZeroRecipient() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        work.transfer(address(0), 1);
    }

    function testNoExternalMintOrAdminSurface() public {
        (bool mintOK,) = address(work).call(abi.encodeWithSignature("mint(address,uint256)", address(this), 1));
        (bool ownerOK,) = address(work).call(abi.encodeWithSignature("owner()"));
        (bool pauseOK,) = address(work).call(abi.encodeWithSignature("pause()"));
        assertFalse(mintOK);
        assertFalse(ownerOK);
        assertFalse(pauseOK);
        assertEq(work.totalSupply(), 1_000_000_000 ether);
    }
}
