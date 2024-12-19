// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import { FixedPointMath } from "hyperdrive/contracts/src/libraries/FixedPointMath.sol";
import { SafeCast } from "hyperdrive/contracts/src/libraries/SafeCast.sol";
import { IEverlongStrategy } from "../interfaces/IEverlongStrategy.sol";
import { EverlongPositionLibrary } from "./EverlongPosition.sol";

/// @author DELV
/// @title EverlongPortfolioLibraryLibrary
/// @notice Library to handle storage and accounting for a bond portfolio.
/// @custom:disclaimer The language used in this code is for coding convenience
///                    only, and is not intended to, and does not, have any
///                    particular legal or regulatory significance.
library EverlongPortfolioLibrary {
    using FixedPointMath for uint256;
    using SafeCast for *;
    using EverlongPositionLibrary for IEverlongStrategy.EverlongPosition;

    /// @notice Thrown on attempting to access either end of an empty queue.
    error IndexOutOfBounds();

    /// @notice Thrown on attempting to remove a position from an empty queue.
    error QueueEmpty();

    /// @notice Thrown on attempting to add a position to a full queue.
    error QueueFull();

    /// @notice Thrown when attempting to decrease a position by more than it
    ///         has.
    error InsufficientBonds();

    /// @dev The state of the portfolio which contains a double-ended queue
    ///      of {IEverlongStrategy.EverlongPosition} along with the portfolio's average
    ///      maturity, vault share price, and total bond count.
    struct State {
        /// @dev Starting index for the double-ended queue structure.
        uint128 _begin;
        /// @dev Ending index for the double-ended queue structure.
        uint128 _end;
        /// @dev Weighted average maturity time for the portfolio.
        uint128 avgMaturityTime;
        /// @dev Total bond count of the portfolio.
        uint128 totalBonds;
        /// @dev Mapping of indices to {IEverlongStrategy.EverlongPosition} for the
        ///      double-ended queue structure.
        mapping(uint256 index => IEverlongStrategy.EverlongPosition) _q;
    }

    /// @notice Update portfolio accounting a newly-opened position.
    /// @param _maturityTime Maturity of the opened position.
    /// @param _bondAmount Amount of bonds in the opened position.
    function handleOpenPosition(
        State storage self,
        uint256 _maturityTime,
        uint256 _bondAmount
    ) internal {
        // Check whether the incoming maturity is already in the portfolio.
        // Since the portfolio's positions are stored as a queue (old -> new),
        // we need only check the 'tail' position.
        if (!isEmpty(self) && tail(self).maturityTime == _maturityTime) {
            // The maturity is already present in the portfolio, so update it
            // with the additional bonds and the price of those bonds.
            tail(self).increase(_bondAmount);
        } else {
            // The maturity is not in the portfolio, so add a new position.
            _addPosition(
                self,
                IEverlongStrategy.EverlongPosition(
                    uint128(_maturityTime),
                    uint128(_bondAmount)
                )
            );
        }

        // Update the portfolio's weighted averages.
        self.avgMaturityTime = uint256(self.avgMaturityTime)
            .updateWeightedAverage(
                self.totalBonds,
                _maturityTime,
                _bondAmount,
                true
            )
            .toUint128();

        // Update the portfolio's total bond count.
        self.totalBonds += uint128(_bondAmount);
    }

    /// @notice Update portfolio accounting for a newly-closed position.
    ///         Since the portfolio handles positions via a queue, the
    ///         position being closed always the oldest at the head.
    function handleClosePosition(State storage self) internal {
        IEverlongStrategy.EverlongPosition memory position = _removePosition(
            self
        );
        self.avgMaturityTime = uint256(self.avgMaturityTime)
            .updateWeightedAverage(
                self.totalBonds,
                position.maturityTime,
                position.bondAmount,
                false
            )
            .toUint128();
        self.totalBonds -= position.bondAmount;
    }

    /// @notice Update portfolio accounting for a newly-closed position.
    ///         Since the portfolio handles positions via a queue, the
    ///         position being closed always the oldest at the head.
    /// @param _amount Amount to reduce the position's bondAmount by.
    function handleClosePosition(State storage self, uint256 _amount) internal {
        IEverlongStrategy.EverlongPosition memory position = _decreasePosition(
            self,
            _amount.toUint128()
        );
        self.avgMaturityTime = uint256(self.avgMaturityTime)
            .updateWeightedAverage(
                self.totalBonds,
                position.maturityTime,
                _amount,
                false
            )
            .toUint128();
        self.totalBonds -= _amount.toUint128();
    }

    /// @notice Obtain the position at the head of the queue.
    ///         This is the oldest position in the portfolio.
    /// @return Position at the head of the queue.
    function head(
        State storage self
    ) internal view returns (IEverlongStrategy.EverlongPosition memory) {
        // Revert if the queue is empty.
        if (isEmpty(self)) revert IndexOutOfBounds();

        // Return the item at the start index.
        return self._q[self._begin];
    }

    /// @notice Obtain the position at the tail of the queue.
    ///         This is the most recent position in the portfolio.
    /// @return Position at the tail of the queue.
    function tail(
        State storage self
    ) internal view returns (IEverlongStrategy.EverlongPosition storage) {
        // Revert if the queue is empty.
        if (isEmpty(self)) revert IndexOutOfBounds();

        // Return the item at the end index.
        unchecked {
            return self._q[self._end - 1];
        }
    }

    /// @notice Retrieve the position at the specified location in the queue..
    /// @param _index Index in the queue to retrieve the position.
    /// @return The position at the specified location.
    function at(
        State storage self,
        uint256 _index
    ) internal view returns (IEverlongStrategy.EverlongPosition memory) {
        // Ensure the requested index is within range.
        if (_index >= positionCount(self)) revert IndexOutOfBounds();

        // Return the position at the specified index.
        unchecked {
            return self._q[self._begin + uint256(_index)];
        }
    }

    /// @notice Returns whether the position queue is empty.
    /// @return True if the position queue is empty, false otherwise.
    function isEmpty(State storage self) internal view returns (bool) {
        return self._end == self._begin;
    }

    /// @notice Returns how many positions are currently in the queue.
    /// @return The queue's position count.
    function positionCount(State storage self) internal view returns (uint256) {
        unchecked {
            return uint256(self._end - self._begin);
        }
    }

    /// @dev Push a new {IEverlongStrategy.EverlongPosition} to the position queue.
    /// @param value Position to be pushed.
    function _addPosition(
        State storage self,
        IEverlongStrategy.EverlongPosition memory value
    ) internal {
        unchecked {
            uint128 backIndex = self._end;

            // Ensure we haven't run out of indices.
            if (backIndex + 1 == self._begin) revert QueueFull();

            // Update indices to extend the queue.
            self._q[backIndex] = value;
            self._end = backIndex + 1;
        }
    }

    /// @dev Decrease the most mature position's bondAmount by the amount
    ///      specified. If the amount is equal to the position's remaining
    ///      bondAmount, remove the position.
    /// @param _amount Amount of bonds to remove from the position.
    /// @return value A copy of the position that was just popped.
    function _decreasePosition(
        State storage self,
        uint128 _amount
    ) internal returns (IEverlongStrategy.EverlongPosition memory value) {
        uint128 frontIndex = self._begin;

        // Ensure there are items in the queue.
        if (frontIndex == self._end) revert QueueEmpty();

        // Revert if trying to decrease by an amount greater than what is
        // present.
        if (_amount > self._q[frontIndex].bondAmount) {
            revert InsufficientBonds();
        }
        // Remove the position if _amount equals the position's bondAmount.
        else if (_amount == self._q[frontIndex].bondAmount) {
            value = _removePosition(self);
        }
        // Reduce the position's bondAmount by `_amount`.
        else {
            self._q[frontIndex].decrease(_amount);
            // Return updated position.
            value = self._q[frontIndex];
        }
    }

    /// @dev Pop the oldest {IEverlongStrategy.EverlongPosition} from the position queue.
    /// @return value A copy of the position that was just popped.
    function _removePosition(
        State storage self
    ) internal returns (IEverlongStrategy.EverlongPosition memory value) {
        unchecked {
            uint128 frontIndex = self._begin;

            // Ensure there are items in the queue.
            if (frontIndex == self._end) revert QueueEmpty();

            // Update indices to shrink the queue.
            value = self._q[frontIndex];
            delete self._q[frontIndex];
            self._begin = frontIndex + 1;
        }
    }

    /// @dev Reset the queue, removing all positions.
    function _clear(State storage self) internal {
        self._begin = 0;
        self._end = 0;
    }
}
