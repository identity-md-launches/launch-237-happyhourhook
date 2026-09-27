// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Happy Hour: a fixed supply, ordinary ERC-20 with no administrative powers.
contract LaunchToken is ERC20 {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;

    constructor() ERC20("Happy Hour", "HAPY") {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
