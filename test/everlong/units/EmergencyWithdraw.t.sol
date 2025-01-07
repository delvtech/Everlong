// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import { IMultiToken } from "hyperdrive/contracts/src/interfaces/IMultiToken.sol";
import { AssetId } from "hyperdrive/contracts/src/libraries/AssetId.sol";
import { IEverlongStrategy } from "../../../contracts/interfaces/IEverlongStrategy.sol";
import { EVERLONG_STRATEGY_KIND, EVERLONG_VERSION } from "../../../contracts/libraries/Constants.sol";
import { EverlongTest } from "../EverlongTest.sol";

/// @dev Tests emergency withdraw functionality.
contract TestEmergencyWithdraw is EverlongTest {
    function test_call_from_non_management_failure() external {
        // Shut down the strategy.
        vm.startPrank(strategy.emergencyAdmin());
        strategy.shutdownStrategy();
        vm.stopPrank();

        // Ensure calling emergencyWithdraw from a random address fails.
        vm.startPrank(alice);
        vm.expectRevert();
        strategy.emergencyWithdraw(type(uint256).max);
        vm.stopPrank();

        // Ensure calling emergencyWithdraw from the keeper address fails.
        vm.startPrank(keeper);
        vm.expectRevert();
        strategy.emergencyWithdraw(type(uint256).max);
        vm.stopPrank();

        // Ensure calling emergencyWithdraw from the keeper contract address
        // fails.
        vm.startPrank(address(keeperContract));
        vm.expectRevert();
        strategy.emergencyWithdraw(type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Ensure strategy can be shutdown when it has no positions.
    function test_no_positions_open() external {
        // Ensure the strategy has no open positions.
        assertEq(IEverlongStrategy(address(strategy)).positionCount(), 0);

        // Shut down the strategy and call `emergencyWithdraw`.
        vm.startPrank(strategy.emergencyAdmin());
        strategy.shutdownStrategy();
        strategy.emergencyWithdraw(type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Ensure strategy can be shutdown when it has  positions.
    function test_positions_open() external {
        // Deposit into the vault and "rebalance" to open a position in the
        // strategy.
        depositVault(100e18, alice, true);
        rebalance();

        // Ensure the strategy has one open position.
        assertEq(IEverlongStrategy(address(strategy)).positionCount(), 1);

        // Get the position.
        IEverlongStrategy.EverlongPosition memory position = IEverlongStrategy(
            address(strategy)
        ).positionAt(0);

        // Record the strategy's balance of longs for that position.
        uint256 strategyLongBalance = IMultiToken(hyperdrive).balanceOf(
            AssetId.encodeAssetId(
                AssetId.AssetIdPrefix.Long,
                uint256(position.maturityTime)
            ),
            address(strategy)
        );

        // Shut down the strategy and call `emergencyWithdraw`.
        vm.startPrank(strategy.emergencyAdmin());
        strategy.shutdownStrategy();
        strategy.emergencyWithdraw(type(uint256).max);
        vm.stopPrank();

        // Ensure the emergency admin address's long balance matches the strategy's
        // long balance prior to the emergency withdraw.
        assertEq(
            strategyLongBalance,
            IMultiToken(hyperdrive).balanceOf(
                AssetId.encodeAssetId(
                    AssetId.AssetIdPrefix.Long,
                    uint256(position.maturityTime)
                ),
                address(strategy.emergencyAdmin())
            )
        );

        // Ensure the strategy has no positions left.
        assertEq(IEverlongStrategy(address(strategy)).positionCount(), 0);
    }

    function test_maxBondAmount() external {
        // Deposit into the vault and "rebalance" to open a position in the
        // strategy.
        depositVault(100e18, alice, true);
        rebalance();

        // Ensure the strategy has one open position.
        assertEq(IEverlongStrategy(address(strategy)).positionCount(), 1);

        // Get the position.
        IEverlongStrategy.EverlongPosition memory position = IEverlongStrategy(
            address(strategy)
        ).positionAt(0);

        // Record the strategy's balance of longs for that position.
        uint256 strategyLongBalance = IMultiToken(hyperdrive).balanceOf(
            AssetId.encodeAssetId(
                AssetId.AssetIdPrefix.Long,
                uint256(position.maturityTime)
            ),
            address(strategy)
        );

        // Shut down the strategy and call `emergencyWithdraw` with
        // `_maxBondAmount` set to a value less than the position's bond amount.
        vm.startPrank(strategy.emergencyAdmin());
        strategy.shutdownStrategy();
        strategy.emergencyWithdraw(strategyLongBalance - 1);
        vm.stopPrank();

        // Ensure the emergency admin address's long balance is zero since no
        // positions were transferred.
        assertEq(
            0,
            IMultiToken(hyperdrive).balanceOf(
                AssetId.encodeAssetId(
                    AssetId.AssetIdPrefix.Long,
                    uint256(position.maturityTime)
                ),
                address(strategy.emergencyAdmin())
            )
        );

        // Ensure the strategy still has one open position.
        assertEq(IEverlongStrategy(address(strategy)).positionCount(), 1);

        // Call `emergencyWithdraw` with `_maxBondAmount` set to a value more
        // than the position's bond amount.
        vm.startPrank(strategy.emergencyAdmin());
        strategy.emergencyWithdraw(strategyLongBalance + 1);
        vm.stopPrank();

        // Ensure the emergency admin address's long balance matches the strategy's
        // long balance prior to the emergency withdraw.
        assertEq(
            strategyLongBalance,
            IMultiToken(hyperdrive).balanceOf(
                AssetId.encodeAssetId(
                    AssetId.AssetIdPrefix.Long,
                    uint256(position.maturityTime)
                ),
                address(strategy.emergencyAdmin())
            )
        );

        // Ensure the strategy has no positions left.
        assertEq(IEverlongStrategy(address(strategy)).positionCount(), 0);
    }
}
