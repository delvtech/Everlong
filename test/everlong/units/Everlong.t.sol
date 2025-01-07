// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import { IERC20, IHyperdrive } from "hyperdrive/contracts/src/interfaces/IHyperdrive.sol";
import { ILido } from "hyperdrive/contracts/src/interfaces/ILido.sol";
import { IEverlongStrategy } from "../../../contracts/interfaces/IEverlongStrategy.sol";
import { EVERLONG_STRATEGY_KIND, EVERLONG_VERSION } from "../../../contracts/libraries/Constants.sol";
import { EverlongTest } from "../EverlongTest.sol";

/// @dev Tests Everlong functionality.
contract TestEverlong is EverlongTest {
    /// @dev Ensure that the `hyperdrive()` view function is implemented.
    function test_hyperdrive() external view {
        assertEq(
            IEverlongStrategy(address(strategy)).hyperdrive(),
            address(hyperdrive),
            "hyperdrive() should return hyperdrive address"
        );
    }

    /// @dev Ensure that the `kind()` view function is implemented.
    function test_kind() external view {
        assertEq(
            IEverlongStrategy(address(strategy)).kind(),
            EVERLONG_STRATEGY_KIND,
            "kind does not match"
        );
    }

    function test_minimumTransactionAmount_asBase_true() external {
        // Obtain the minimum transaction amount from the strategy.
        uint256 minTxAmount = IEverlongStrategy(address(strategy))
            .minimumTransactionAmount();

        // Open a long with that amount and `asBase` set to true (the default
        // for testing).
        (uint256 maturityTime, uint256 bondAmount) = openLong(
            alice,
            minTxAmount,
            AS_BASE
        );

        // Ensure the maturityTime and bondAmount are valid.
        assertGt(maturityTime, 0);
        assertGt(bondAmount, 0);
    }

    /// @dev Ensure that the `minimumTransactionAmountBuffer` view function is
    ///      implemented.
    function test_minimumTransactionAmountBuffer() external view {
        assertGt(
            IEverlongStrategy(address(strategy))
                .minimumTransactionAmountBuffer(),
            0
        );
    }

    /// @dev Ensure that the `version()` view function is implemented.
    function test_version() external view {
        assertEq(
            IEverlongStrategy(address(strategy)).version(),
            EVERLONG_VERSION,
            "version does not match"
        );
    }
}
