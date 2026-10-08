// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Test-only IMD stand-in; its runtime is installed at the brief's IMD address.
contract PairToken is ERC20 {
    address public blockedRecipient;

    constructor() ERC20("Test IMD", "IMD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function blockRecipient(address recipient) external {
        blockedRecipient = recipient;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(to != blockedRecipient, "Recipient blocked");
        super._update(from, to, value);
    }
}

contract RejectNative {
    receive() external payable {
        revert("Native rejected");
    }
}
