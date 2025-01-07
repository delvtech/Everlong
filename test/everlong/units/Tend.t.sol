// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import { console2 as console } from "forge-std/console2.sol";
import { IERC20 } from "hyperdrive/contracts/src/interfaces/IHyperdrive.sol";
import { FixedPointMath } from "hyperdrive/contracts/src/libraries/FixedPointMath.sol";
import { Lib } from "hyperdrive/test/utils/Lib.sol";
import { HyperdriveUtils } from "hyperdrive/test/utils/HyperdriveUtils.sol";
import { EverlongTest } from "../EverlongTest.sol";
import { IEverlongStrategy } from "../../../contracts/interfaces/IEverlongStrategy.sol";
import { HyperdriveExecutionLibrary } from "../../../contracts/libraries/HyperdriveExecution.sol";

contract TestTend is EverlongTest {
    using FixedPointMath for uint256;
    using Lib for *;
    using HyperdriveUtils for *;
    using HyperdriveExecutionLibrary for *;

    // NOTE: Playground to see vault APR. Modify various vault parameters to see
    //       how they affect the calculated APR.
    //
    /// @dev Tests that the gas cost for closing the maximum amount of matured
    ///      positions does not exceed the block gas limit.
    function test_apr() external {
        // Comment the line below to run the playground.
        vm.skip(true);

        uint256 depositAmount = 1_000e18;

        // Deposit and redeem from the strategy.
        uint256 bobShares = depositStrategy(depositAmount, bob, true);
        advanceTimeWithCheckpointsAndReporting(POSITION_DURATION);
        redeemStrategy(bobShares, bob);

        // Deposit and redeem from the vault.
        uint256 aliceShares = depositVault(depositAmount, alice, true);
        advanceTimeWithCheckpointsAndReporting(POSITION_DURATION);
        redeemVault(aliceShares, alice);
    }

    /// @dev Tests that the gas cost for closing the maximum amount of matured
    ///      positions does not exceed the block gas limit.
    function test_tend_max_matured_positions() external {
        // NOTE: Skipping this since it will fail, but keeping in case we want
        //       for informative purposes.
        vm.skip(true);

        // Calculate the maximum amount of positions possible with the current
        // position and checkpoint durations.
        uint256 maxPositionCount = POSITION_DURATION / CHECKPOINT_DURATION;

        // Loop through and make deposits each checkpoint interval.
        // Keep track of shares for the redeem call later which will force
        // the closure of the matured positions.
        uint256 shares;
        uint256 spent;
        for (uint256 i; i < maxPositionCount; i++) {
            spent +=
                IEverlongStrategy(address(strategy))
                    .minimumTransactionAmount() *
                2;
            shares += depositVault(
                IEverlongStrategy(address(strategy))
                    .minimumTransactionAmount() * 2,
                alice,
                true
            );
            advanceTimeWithCheckpointsAndReporting(CHECKPOINT_DURATION);
        }

        // Ensure Everlong has the maximum amount of positions possible.
        assertEq(
            IEverlongStrategy(address(strategy)).positionCount(),
            maxPositionCount
        );

        // Advance time so that all positions are mature.
        advanceTimeWithCheckpoints(POSITION_DURATION);

        // Track the gas cost for the redemption.
        uint256 gasUsed = gasleft();
        redeemVault(shares, alice);
        gasUsed -= gasleft();

        // Ensure the gas cost of the redemption is less than the block gas
        // limit.
        uint256 blockGasLimit = 30_000_000;
        assertLt(gasUsed, blockGasLimit);
    }

    // ╭───────────────────────────────────────────────────────────────────────╮
    // │                              TendTrigger                              │
    // ╰───────────────────────────────────────────────────────────────────────╯

    /// @dev Ensure that `tendTrigger()` returns false when everlong has
    ///      no positions nor balance.
    function test_tendTrigger_false_no_positions_no_balance() external view {
        // Check that Everlong:
        // - has no positions
        // - has no balance
        // - `tendTrigger()` returns false
        assertEq(
            IEverlongStrategy(address(strategy)).positionCount(),
            0,
            "everlong should not intialize with positions"
        );
        assertEq(
            IERC20(vault.asset()).balanceOf(address(vault)),
            0,
            "everlong should not initialize with a balance"
        );
        (bool canTend, ) = strategy.tendTrigger();
        assertFalse(
            canTend,
            "cannot rebalance without matured positions or balance"
        );
    }

    /// @dev Ensures that `tendTrigger()` returns true with a balance
    ///          greater than Hyperdrive's minTransactionAmount.
    function test_tendTrigger_with_balance_over_min_tx_amount() external {
        // Mint some tokens to Everlong for opening longs.
        // Ensure Everlong's balance is gte Hyperdrive's minTransactionAmount.
        // Ensure `tendTrigger()` returns true.
        depositStrategy(
            IEverlongStrategy(address(strategy)).minimumTransactionAmount() + 1,
            alice
        );
        assertGt(
            IERC20(strategy.asset()).balanceOf(address(strategy)),
            IEverlongStrategy(address(strategy)).minimumTransactionAmount()
        );
        (bool canTend, ) = strategy.tendTrigger();
        assertTrue(
            canTend,
            "everlong should be able to rebalance when it has a balance > hyperdrive's minTransactionAmount"
        );
    }

    /// @dev Ensures that `tendTrigger()` returns true with a matured
    ///      position.
    function test_tendTrigger_with_matured_position() external {
        // Mint some tokens to Everlong for opening longs and rebalance.
        mintApproveAsset(
            address(strategy),
            IEverlongStrategy(address(strategy)).minimumTransactionAmount() + 1
        );
        rebalance();

        // Increase block.timestamp until position is mature.
        // Ensure Everlong has a matured position.
        // Ensure `tendTrigger()` returns true.
        advanceTimeWithCheckpoints(
            IEverlongStrategy(address(strategy)).positionAt(0).maturityTime
        );
        assertTrue(
            IEverlongStrategy(address(strategy)).hasMaturedPositions(),
            "everlong should have matured position after advancing time"
        );
        (bool canTend, ) = strategy.tendTrigger();
        assertTrue(
            canTend,
            "everlong should allow rebalance with matured position"
        );
    }

    // ╭───────────────────────────────────────────────────────────────────────╮
    // │                              TendConfig                               │
    // ╰───────────────────────────────────────────────────────────────────────╯

    /// @dev Tests that `setTendConfig` cannot be called by a non-keeper.
    function test_setTendConfig_failure_not_keeper() external {
        // Start a prank as a non-keeper address (alice).
        vm.startPrank(alice);

        // setTendConfig should revert.
        vm.expectRevert();
        IEverlongStrategy(address(strategy)).setTendConfig(
            IEverlongStrategy.TendConfig({
                minOutput: 0,
                minVaultSharePrice: 0,
                positionClosureLimit: 0,
                extraData: ""
            })
        );

        // Stop the prank.
        vm.stopPrank();
    }

    /// @dev Tests that `setTendConfig` succeeds when called by the keeper.
    function test_setTendConfig_success() external {
        // Start a prank as the keeper address.
        vm.startPrank(address(keeperContract));

        // setTendConfig should succeed.
        IEverlongStrategy(address(strategy)).setTendConfig(
            IEverlongStrategy.TendConfig({
                minOutput: 1,
                minVaultSharePrice: 0,
                positionClosureLimit: 0,
                extraData: ""
            })
        );

        // Check that minOutput was updated.
        (, IEverlongStrategy.TendConfig memory tendConfig) = IEverlongStrategy(
            address(strategy)
        ).getTendConfig();
        assertEq(tendConfig.minOutput, 1);

        // Stop the prank.
        vm.stopPrank();
    }

    /// @dev Tests that `TendConfig.minOutput` is obeyed when opening longs.
    function test_minOutput_open_long() external {
        // Deposit into the strategy as alice.
        depositStrategy(
            IEverlongStrategy(address(strategy)).minimumTransactionAmount() + 1,
            alice
        );

        // Start a prank as a keeper.
        vm.startPrank(keeper);

        // Set minOutput to a very high value.
        uint256 minOutput = type(uint256).max;

        // Ensure `tend()` reverts.
        vm.expectRevert();
        keeperContract.tend(
            address(strategy),
            IEverlongStrategy.TendConfig({
                minOutput: minOutput,
                minVaultSharePrice: 0,
                positionClosureLimit: 0,
                extraData: ""
            })
        );

        // Stop the prank.
        vm.stopPrank();
    }

    /// @dev Tests that `TendConfig.minVaultSharePrice` is obeyed when opening longs.
    function test_minVaultSharePrice_open_long() external {
        // Deposit into the strategy as alice.
        depositStrategy(
            IEverlongStrategy(address(strategy)).minimumTransactionAmount() + 1,
            alice
        );

        // Start a prank as a keeper.
        vm.startPrank(keeper);

        // Set minVaultSharePrice to a very high value.
        uint256 minVaultSharePrice = type(uint256).max;

        // Ensure `tend()` reverts.
        vm.expectRevert();
        keeperContract.tend(
            address(strategy),
            IEverlongStrategy.TendConfig({
                minOutput: 0,
                minVaultSharePrice: minVaultSharePrice,
                positionClosureLimit: 0,
                extraData: ""
            })
        );

        // Stop the prank.
        vm.stopPrank();
    }

    /// @dev Tests that `TendConfig.positionClosureLimit` is obeyed when calling
    ///      tend().
    function test_positionClosureLimit_tend() external {
        // Deposit into the strategy as alice.
        depositStrategy(
            IEverlongStrategy(address(strategy)).minimumTransactionAmount() + 1,
            alice
        );

        // Rebalance to have the strategy hold a single position.
        rebalance();

        // Fast forward a checkpoint duration, deposit, and rebalance.
        // This will result in two total positions held by the strategy.
        advanceTimeWithCheckpoints(CHECKPOINT_DURATION);
        depositStrategy(
            IEverlongStrategy(address(strategy)).minimumTransactionAmount() + 1,
            alice
        );
        rebalance();
        assertEq(IEverlongStrategy(address(strategy)).positionCount(), 2);

        // Fast forward such that both positions are mature.
        advanceTimeWithCheckpoints(POSITION_DURATION * 2);

        // Start a prank as a keeper.
        vm.startPrank(keeper);

        // Set positionClosureLimit to the value 1.
        uint256 positionClosureLimit = 1;

        // Call tend().
        keeperContract.tend(
            address(strategy),
            IEverlongStrategy.TendConfig({
                minOutput: 0,
                minVaultSharePrice: 0,
                positionClosureLimit: positionClosureLimit,
                extraData: ""
            })
        );

        // Ensure that the strategy still has a matured position.
        assertTrue(IEverlongStrategy(address(strategy)).hasMaturedPositions());

        // Stop the prank.
        vm.stopPrank();
    }
}
