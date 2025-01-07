// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import { console2 as console } from "forge-std/console2.sol";
import { FixedPointMath } from "hyperdrive/contracts/src/libraries/FixedPointMath.sol";
import { Lib } from "hyperdrive/test/utils/Lib.sol";
import { EverlongTest } from "../EverlongTest.sol";
import { IEverlongStrategy } from "../../../contracts/interfaces/IEverlongStrategy.sol";
import { HyperdriveExecutionLibrary } from "../../../contracts/libraries/HyperdriveExecution.sol";

contract TestPartialClosures is EverlongTest {
    using FixedPointMath for uint256;
    using Lib for *;
    using HyperdriveExecutionLibrary for *;

    /// @dev Tests that immature positions can be partially closed when
    ///      additional liquidity is needed to service a withdrawal.
    ///      Ensures that the amount of longs closed in the position is not
    ///      excessive.
    function testFuzz_partial_closures(
        uint256 _deposit,
        uint256 _redemptionAmount
    ) external {
        // Alice deposits into Everlong.
        uint256 aliceDepositAmount = bound(
            _deposit,
            IEverlongStrategy(address(strategy)).minimumTransactionAmount() *
                100, // Increase minimum bound otherwise partial redemption won't occur
            hyperdrive.calculateMaxLong(AS_BASE)
        );
        uint256 aliceShares = depositStrategy(aliceDepositAmount, alice, true);
        uint256 positionBondsAfterDeposit = IEverlongStrategy(address(strategy))
            .totalBonds();

        // Alice redeems a significant enough portion of her shares to require
        // partially closing the immature position.
        _redemptionAmount = bound(
            _redemptionAmount,
            aliceShares.mulDown(0.05e18),
            aliceShares.mulDown(0.95e18)
        );
        redeemStrategy(_redemptionAmount, alice, true);
        uint256 positionBondsAfterRedeem = IEverlongStrategy(address(strategy))
            .totalBonds();

        // Ensure Everlong still has a position open.
        assertGt(IEverlongStrategy(address(strategy)).positionCount(), 0);

        // Ensure the remaining Everlong position has proportionally less bonds
        // than it did prior to redemption.
        assertApproxEqRel(
            positionBondsAfterDeposit.mulDivDown(
                aliceShares - _redemptionAmount,
                aliceShares
            ),
            positionBondsAfterRedeem,
            0.05e18
        );
    }

    /// @dev Tests the case where a redemption requires closing longs from
    ///      two separate positions that have dramatically different bond prices.
    ///
    ///      If the expected bond prices are calculated using portfolio averages (bad)
    ///      - The output for the least mature bonds will be overestimated
    ///      - The slippage guard will be triggered.
    ///      - The redemption will fail.
    ///
    ///      If the expected bond prices are calculated on a per-position basis (good)
    ///      - The output for all bonds should be correctly estimated.
    ///      - The slippage guard should not be triggered.
    ///      - The redemption will succeed.
    function test_partial_closures_large_position_bond_price_difference()
        external
    {
        // Alice deposits into Everlong.
        uint256 aliceDepositAmount = 10_000e18;
        uint256 aliceShares = depositStrategy(aliceDepositAmount, alice, true);

        // Time advances towards the end of the term.
        advanceTimeWithCheckpointsAndRebalancing(
            POSITION_DURATION.mulDown(0.8e18)
        );

        // Alice deposits again into Everlong.
        aliceShares += depositStrategy(aliceDepositAmount, alice, true);

        // Ensure Everlong has two positions and that the bond prices differ
        // by greater than Everlong's max closeLong slippage.
        assertEq(IEverlongStrategy(address(strategy)).positionCount(), 2);
        IEverlongStrategy.EverlongPosition
            memory oldPosition = IEverlongStrategy(address(strategy))
                .positionAt(0);
        IEverlongStrategy.EverlongPosition
            memory newPosition = IEverlongStrategy(address(strategy))
                .positionAt(1);
        uint256 oldBondPrice = hyperdrive
            .previewCloseLong(true, hyperdrive.getPoolConfig(), oldPosition, "")
            .divDown(oldPosition.bondAmount);
        uint256 newBondPrice = hyperdrive
            .previewCloseLong(true, hyperdrive.getPoolConfig(), newPosition, "")
            .divDown(newPosition.bondAmount);
        assertGt(
            (oldBondPrice - newBondPrice).divDown(oldBondPrice),
            IEverlongStrategy(address(strategy)).partialPositionClosureBuffer()
        );

        // Alice redeems enough shares to require closing the first and part
        // of the second position.
        // This should succeed.
        uint256 redeemPercentage = 0.75e18;
        uint256 aliceRedeemAmount = aliceShares.mulDown(redeemPercentage);
        redeemStrategy(aliceRedeemAmount, alice, true);

        // Ensure Everlong has one position left.
        assertEq(IEverlongStrategy(address(strategy)).positionCount(), 1);
    }

    /// @dev Tests that when a partial closure would result in a remaining
    ///      position value less than the minimum transaction amount, the entire
    ///      position is closed.
    function test_partial_closures_position_min_transaction_amount() external {
        // Alice deposits into Everlong.
        uint256 aliceDepositAmount = 1000e18;
        uint256 aliceShares = depositStrategy(aliceDepositAmount, alice, true);

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
        redeemStrategy(aliceShares - minTxShareAmount, alice, true);

        // There should be no positions left.
        assertEq(IEverlongStrategy(address(strategy)).positionCount(), 0);
    }
}
