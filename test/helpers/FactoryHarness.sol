// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Yolo} from "../../src/Yolo.sol";

/// @dev Test-only caller used to exercise the launch's CREATE2 and transfer paths.
contract FactoryHarness {
    function deploy(bytes32 salt) external returns (Yolo) {
        return new Yolo{salt: salt}();
    }

    function transfer(Yolo token, address recipient, uint256 amount) external returns (bool) {
        return token.transfer(recipient, amount);
    }
}
