// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Yolo (YOLO)
/// @notice A fixed supply ERC-20 with 18 decimals and no administrative powers.
contract Yolo is ERC20 {
    /// @notice One billion whole tokens, expressed in the smallest token units.
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    /// @notice Mints the entire supply once to the immediate deployer (the launch factory).
    constructor() ERC20("Yolo", "YOLO") {
        _mint(msg.sender, INITIAL_SUPPLY);
    }
}
