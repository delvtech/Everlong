// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import { console2 as console } from "forge-std/console2.sol";
import { IERC20, IHyperdrive } from "hyperdrive/contracts/src/interfaces/IHyperdrive.sol";
import { ILido } from "hyperdrive/contracts/src/interfaces/ILido.sol";
import { FixedPointMath } from "hyperdrive/contracts/src/libraries/FixedPointMath.sol";
import { IEverlongStrategy } from "../../../contracts/interfaces/IEverlongStrategy.sol";
import { EVERLONG_STRATEGY_KIND, EVERLONG_VERSION } from "../../../contracts/libraries/Constants.sol";
import { EverlongForkSDAITest } from "../EverlongForkSDAITest.sol";

/// @dev Tests Everlong functionality when using the existing SDAIHyperdrive
///      instance on a fork.
contract TestEverlongForkSDAI is EverlongForkSDAITest {
    using FixedPointMath for uint256;

    /// @dev Ensure the deposit functions work as expected.
    function test_deposit() external {
        // Alice and Bob deposit into the vault.
        uint256 depositAmount = 100e18;
        uint256 aliceShares = depositSDAI(depositAmount, alice);
        uint256 bobShares = depositSDAI(depositAmount, bob);

        // Alice and Bob should have non-zero share amounts.
        assertGt(aliceShares, 0);
        assertGt(bobShares, 0);
    }

    /// @dev Ensure the rebalance and redeem functions work as expected.
    function test_redeem() external {
        // Alice and Bob deposit into the vault.
        uint256 depositAmount = 100e18;
        uint256 aliceShares = depositSDAI(depositAmount, alice);
        uint256 bobShares = depositSDAI(depositAmount, bob);

        // The vault allocates funds to the strategy.
        rebalance();

        // Alice and Bob redeem their shares from the vault.
        uint256 aliceRedeemAssets = redeemSDAI(aliceShares, alice);
        uint256 bobRedeemAssets = redeemSDAI(bobShares, bob);

        // Neither Alice nor Bob should have more assets than they began with.
        assertLe(aliceRedeemAssets, depositAmount);
        assertLe(bobRedeemAssets, depositAmount);
    }

    /// @dev Ensure that the `minimumTransactionAmount` calculated by the
    ///      strategy is greater than or equal to hyperdrive's representation.
    function test_minimumTransactionAmount_asBase_false_not_wrapped() external {
        // Obtain the minimum transaction amount from the strategy.
        uint256 minTxAmount = IEverlongStrategy(address(strategy))
            .minimumTransactionAmount();

        // Manually mint alice plenty of hyperdrive vault shares tokens.
        mintSDAI(minTxAmount * 100, alice);
        vm.prank(alice);
        IERC20(SDAI_ADDRESS).approve(address(hyperdrive), type(uint256).max);

        vm.startPrank(alice);
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
        vm.stopPrank();

        // Ensure the maturityTime and bondAmount are valid.
        assertGt(maturityTime, 0);
        assertGt(bondAmount, 0);
    }

    /// @dev Tests that when a partial closure would result in a remaining
    ///      position value less than the minimum transaction amount, the entire
    ///      position is closed.
    function test_partial_closures_min_transaction_amount() external {
        // Alice deposits into Everlong.
        uint256 aliceDepositAmount = 10e18;
        uint256 aliceShares = depositSDAIStrategy(aliceDepositAmount, alice);
        rebalance();

        // Ensure there is now one position.
        assertEq(IEverlongStrategy(address(strategy)).positionCount(), 1);

        // Calculate how many shares are neeed to reach the minimum transaction
        // amount.
        uint256 minTxShareAmount = (aliceShares).mulDivDown(
            hyperdrive.getPoolConfig().minimumTransactionAmount,
            IEverlongStrategy(address(strategy)).positionAt(0).bondAmount
        );

        // Redeem shares such that the remaining share value should be less
        // than the minimum transaction amount.
        redeemSDAIStrategy(aliceShares - minTxShareAmount, alice);
        rebalance();

        // There should be no positions left.
        assertEq(IEverlongStrategy(address(strategy)).positionCount(), 0);
    }
}
