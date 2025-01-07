// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import { IERC20 } from "openzeppelin/interfaces/IERC20.sol";
import { IEverlongEvents } from "./IEverlongEvents.sol";
import { IPermissionedStrategy } from "./IPermissionedStrategy.sol";

interface IEverlongStrategy is IPermissionedStrategy, IEverlongEvents {
    // ╭───────────────────────────────────────────────────────────────────────╮
    // │                                STRUCTS                                │
    // ╰───────────────────────────────────────────────────────────────────────╯

    /// @notice Contains the information needed to identify an open Hyperdrive
    ///         position.
    struct EverlongPosition {
        /// @notice Time when the position matures.
        uint128 maturityTime;
        /// @notice Amount of bonds in the position.
        uint128 bondAmount;
    }

    /// @notice Configuration for how `tend()` will be performed.
    struct TendConfig {
        /// @notice Minimum amount of bonds to receive when opening a position.
        uint256 minOutput;
        /// @notice Minimum vault share price when opening a position.
        uint256 minVaultSharePrice;
        /// @notice Maximum amount of mature positions that can be closed.
        /// @dev A value of zero indicates no limit.
        uint256 positionClosureLimit;
        /// @notice Passed to hyperdrive `openLong()` and `closeLong()`.
        bytes extraData;
    }

    // ╭───────────────────────────────────────────────────────────────────────╮
    // │                                Errors                                 │
    // ╰───────────────────────────────────────────────────────────────────────╯

    /// @notice Thrown when calling wrap conversion functions on a strategy with
    ///         a non-wrapped asset.
    error AssetNotWrapped();

    // ╭───────────────────────────────────────────────────────────────────────╮
    // │                                SETTERS                                │
    // ╰───────────────────────────────────────────────────────────────────────╯

    /// @notice Sets the temporary tend configuration. Necessary for `tend()`
    ///         call to succeed. Must be called in the same tx as `tend()`.
    function setTendConfig(
        IEverlongStrategy.TendConfig memory _config
    ) external;

    // ╭───────────────────────────────────────────────────────────────────────╮
    // │                                 VIEWS                                 │
    // ╰───────────────────────────────────────────────────────────────────────╯

    /// @notice Gets whether Everlong uses hyperdrive's base token.
    /// @return True if using hyperdrive's base token, false otherwise.
    function asBase() external view returns (bool);

    /// @notice Weighted average maturity timestamp of the portfolio.
    /// @return Weighted average maturity timestamp of the portfolio.
    function avgMaturityTime() external view returns (uint128);

    /// @notice Calculates the current value of Everlong's bond portfolio.
    /// @dev The result of this calculation is used to set the new totalAssets
    ///      in `_harvestAndReport`.
    function calculatePortfolioValue() external view returns (uint256);

    /// @notice Returns whether Everlong has sufficient idle liquidity to open
    ///         a new position.
    /// @return True if a new position can be opened, false otherwise.
    function canOpenPosition() external view returns (bool);

    /// @notice Convert the amount of unwrapped tokens to the amount received
    ///         after wrapping.
    /// @param _unwrappedAmount Amount of unwrapped tokens.
    /// @return _wrappedAmount Amount of wrapped tokens.
    function convertToWrapped(
        uint256 _unwrappedAmount
    ) external view returns (uint256 _wrappedAmount);

    /// @notice Convert the amount of wrapped tokens to the amount received
    ///         after unwrapping.
    /// @param _wrappedAmount Amount of wrapped tokens.
    /// @return _unwrappedAmount Amount of unwrapped tokens.
    function convertToUnwrapped(
        uint256 _wrappedAmount
    ) external view returns (uint256 _unwrappedAmount);

    /// @notice Token used to execute trades with hyperdrive.
    /// @dev Determined by `asBase`.
    ///      If `asBase=true`, then hyperdrive's base token is used.
    ///      If `asBase=false`, then hyperdrive's vault shares token is used.
    ///      Same as the strategy asset `asset` unless `isWrapped=true`
    /// @return The token used to execute trades with hyperdrive.
    function executionToken() external view returns (address);

    /// @notice Reads and returns the current tend configuration from transient
    ///         storage.
    /// @return tendEnabled Whether TendConfig has been set.
    /// @return The current tend configuration.
    function getTendConfig()
        external
        returns (bool tendEnabled, IEverlongStrategy.TendConfig memory);

    /// @notice Determines whether any positions are matured.
    /// @return True if any positions are matured, false otherwise.
    function hasMaturedPositions() external view returns (bool);

    /// @notice Gets the address of the underlying Hyperdrive Instance
    function hyperdrive() external view returns (address);

    /// @notice Returns whether the strategy's asset is a wrapped hyperdrive token.
    function isWrapped() external view returns (bool);

    /// @notice Gets the Everlong instance's kind.
    /// @return The Everlong instance's kind.
    function kind() external pure returns (string memory);

    /// @notice Gets the minimum amount of strategy assets needed to open a long
    ///         with hyperdrive.
    /// @return Minimum amount of strategy assets needed to open a long with
    ///         hyperdrive.
    function minimumTransactionAmount() external view returns (uint256);

    /// @notice Amount to add to hyperdrive's minimum transaction amount to
    ///         account for hyperdrive's internal rounding. Represented as a
    ///         percentage of the value after conversions from base to shares
    ///         (if applicable) where 1e18 represents a 100% buffer.
    function minimumTransactionAmountBuffer() external view returns (uint256);

    /// @notice Amount of additional bonds to close during a partial position
    ///         closure to avoid rounding errors. Represented as a percentage
    ///         of the positions total  amount of bonds where 1e18 represents
    ///         a 100% buffer.
    /// @return The buffer for partial position closures.
    function partialPositionClosureBuffer() external view returns (uint256);

    /// @notice Gets the position at an index.
    ///         Position `maturityTime` increases with each index.
    /// @param _index The index of the position.
    /// @return The position.
    function positionAt(
        uint256 _index
    ) external view returns (EverlongPosition memory);

    /// @notice Gets the number of positions managed by the Everlong instance.
    /// @return The number of positions.
    function positionCount() external view returns (uint256);

    /// @notice Total quantity of bonds held in the portfolio.
    /// @return Total quantity of bonds held in the portfolio.
    function totalBonds() external view returns (uint128);

    /// @notice Gets the Everlong instance's version.
    /// @return The Everlong instance's version.
    function version() external pure returns (string memory);
}
