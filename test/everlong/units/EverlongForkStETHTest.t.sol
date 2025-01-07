// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import { IERC20, IHyperdrive } from "hyperdrive/contracts/src/interfaces/IHyperdrive.sol";
import { ILido } from "hyperdrive/contracts/src/interfaces/ILido.sol";
import { IEverlongStrategy } from "../../../contracts/interfaces/IEverlongStrategy.sol";
import { EVERLONG_STRATEGY_KIND, EVERLONG_VERSION } from "../../../contracts/libraries/Constants.sol";
import { EverlongForkStETHTest } from "../EverlongForkStETHTest.sol";

/// @dev Tests Everlong functionality when using the existing StETHHyperdrive
///      instance on a fork.
contract TestEverlongForkStETH is EverlongForkStETHTest {
    /// @dev Ensure the deposit functions work as expected.
    function test_deposit() external {
        // Alice and Bob deposit into the vault.
        uint256 depositAmount = 100e18;
        uint256 aliceShares = depositWSTETH(depositAmount, alice);
        uint256 bobShares = depositWSTETH(depositAmount, bob);

        // Alice and Bob should have non-zero share amounts.
        assertGt(aliceShares, 0);
        assertGt(bobShares, 0);
    }

    /// @dev Ensure the rebalance and redeem functions work as expected.
    function test_redeem() external {
        // Alice and Bob deposit into the vault.
        uint256 depositAmount = 100e18;
        uint256 aliceShares = depositWSTETH(depositAmount, alice);
        uint256 bobShares = depositWSTETH(depositAmount, bob);

        // The vault allocates funds to the strategy.
        rebalance();

        // Alice and Bob redeem their shares from the vault.
        uint256 aliceRedeemAssets = redeemWSTETH(aliceShares, alice);
        uint256 bobRedeemAssets = redeemWSTETH(bobShares, bob);

        // Neither Alice nor Bob should have more assets than they began with.
        assertLe(aliceRedeemAssets, depositAmount);
        assertLe(bobRedeemAssets, depositAmount);
    }

    /// @dev Ensure that the `minimumTransactionAmount` calculated by the
    ///      strategy is greater than or equal to hyperdrive's representation.
    function test_minimumTransactionAmount_asBase_false_wrapped() external {
        // Obtain the minimum transaction amount from the strategy.
        uint256 minTxAmount = IEverlongStrategy(address(strategy))
            .minimumTransactionAmount();

        // Manually mint alice plenty of hyperdrive vault shares tokens.
        vm.startPrank(STETH_WHALE);
        ILido(STETH_ADDRESS).transferShares(alice, minTxAmount * 100);
        ILido(STETH_ADDRESS).approve(address(hyperdrive), type(uint256).max);

        // Open a long in hyperdrive with the vault shares tokens.
        (uint256 maturityTime, uint256 bondAmount) = hyperdrive.openLong(
            minTxAmount,
            0, // min bond proceeds
            0, // min vault share price
            IHyperdrive.Options({
                destination: alice,
                asBase: false,
                extraData: ""
            })
        );

        // Ensure the maturityTime and bondAmount are valid.
        assertGt(maturityTime, 0);
        assertGt(bondAmount, 0);
    }
}
