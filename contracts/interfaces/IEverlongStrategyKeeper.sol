// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import { IEverlongStrategy } from "./IEverlongStrategy.sol";

/// @author DELV
/// @title IEverlongStrategyKeeper
/// @notice Interface for EverlongStrategyKeeper.
/// @custom:disclaimer The language used in this code is for coding convenience
///                    only, and is not intended to, and does not, have any
///                    particular legal or regulatory significance.
interface IEverlongStrategyKeeper {
    // ╭───────────────────────────────────────────────────────────────────────╮
    // │                                Setters                                │
    // ╰───────────────────────────────────────────────────────────────────────╯

    /// @notice Updates the address of the CommonReportTrigger contract.
    /// @param _trigger Address of the CommonReportTrigger contract to set.
    function setTrigger(address _trigger) external;

    /// @notice Updates the address of the RoleManager contract.
    /// @param _roleManager Address of the RoleManager contract to set.
    function setRoleManager(address _roleManager) external;

    // ╭───────────────────────────────────────────────────────────────────────╮
    // │                               Ownership                               │
    // ╰───────────────────────────────────────────────────────────────────────╯

    // NOTE: Renouncing ownership will leave the contract without an owner,
    // thereby disabling any functionality that is only available to the owner.
    //
    /// @dev Leaves the contract without owner. It will not be possible to call
    /// `onlyOwner` functions. Can only be called by the current owner.
    function renounceOwnership() external;

    /// @dev Transfers ownership of the contract to a new account (`newOwner`).
    ///      Can only be called by the current owner.
    ///
    /// @param newOwner Address to receive ownership.
    function transferOwnership(address newOwner) external;

    // ╭───────────────────────────────────────────────────────────────────────╮
    // │                     Vault + Strategy Maintenance                      │
    // ╰───────────────────────────────────────────────────────────────────────╯

    /// @notice Calls `process_report()` on the vault/strategy combination if
    ///      needed.
    /// @param _vault Address of the vault contract to process the report on.
    /// @param _strategy Address of the strategy contract to process the report
    ///        on.
    function processReport(address _vault, address _strategy) external;

    /// @dev Calls `report()` on the strategy if needed.
    ///
    /// @param _strategy Address of the strategy contract to report on.
    /// @param _config Configuration for the `tend()` function called within
    ///        `_harvestAndReport()` in the strategy.
    function strategyReport(
        address _strategy,
        IEverlongStrategy.TendConfig memory _config
    ) external;

    /// @dev Calls `tend()` on the strategy if needed and sets the
    ///      tend configuration.
    /// @param _strategy Address of the strategy to tend.
    /// @param _config Configuration for the tend call.
    function tend(
        address _strategy,
        IEverlongStrategy.TendConfig memory _config
    ) external;

    /// @dev Calls `update_debt()` on the vault if needed.
    /// @param _vault Address of the vault to update debt for.
    /// @param _strategy Address of the strategy to update debt for.
    function update_debt(address _vault, address _strategy) external;

    // ╭───────────────────────────────────────────────────────────────────────╮
    // │                               Triggers                                │
    // ╰───────────────────────────────────────────────────────────────────────╯

    /// @notice Returns true if `processReport(..)` should be called on the
    ///         vault/strategy combination.
    /// @param _vault Address of the vault to process the report on.
    /// @param _strategy Address of the strategy to process the report on.
    /// @return shouldProcessReport_ True if `processReport(..)` should be
    ///         called, false otherwise.
    function shouldProcessReport(
        address _vault,
        address _strategy
    ) external view returns (bool shouldProcessReport_);

    /// @notice Returns whether `report(..)` should be called on the strategy.
    /// @param _strategy Address of the strategy.
    /// @return shouldStrategyReport_ True if `report(..)` should be called,
    ///                               false otherwise.
    function shouldStrategyReport(
        address _strategy
    ) external view returns (bool shouldStrategyReport_);

    /// @notice Returns whether `tend(..)` should be called on the strategy.
    /// @param _strategy Address of the strategy.
    /// @return shouldTend_ True if `tend(..)` should be called on the strategy,
    ///                     false otherwise.
    function shouldTend(
        address _strategy
    ) external view returns (bool shouldTend_);

    /// @notice Returns whether `update_debt(..)` should be called for the
    ///         vault/strategy combination.
    /// @param _vault Address of the vault.
    /// @param _strategy Address of the strategy.
    /// @return shouldUpdateDebt_ True if `update_debt(..)` should be called
    ///                           on the vault/strategy combination, false
    ///                           otherwise.
    function shouldUpdateDebt(
        address _vault,
        address _strategy
    ) external view returns (bool shouldUpdateDebt_);

    // ╭───────────────────────────────────────────────────────────────────────╮
    // │                 IEverlongStrategy.TendConfig Helpers                  │
    // ╰───────────────────────────────────────────────────────────────────────╯

    /// @notice Calculates an appropriate `TendConfig.minOutput` for the input
    ///         `_strategy` given the provided `_slippage` tolerance.
    /// @param _strategy Strategy to be tended.
    /// @param _slippage Maximum acceptable slippage in basis points where a
    ///        value of 10_000 indicates 100% slippage.
    function calculateMinOutput(
        address _strategy,
        uint256 _slippage
    ) external view returns (uint256);

    /// @notice Calculates an appropriate `TendConfig.minVaultSharePrice` for
    ///         the input `_strategy` given the provided `_slippage` tolerance.
    /// @param _strategy Strategy to be tended.
    /// @param _slippage Maximum acceptable slippage in basis points where a
    ///        value of 10_000 indicates 100% slippage.
    function calculateMinVaultSharePrice(
        address _strategy,
        uint256 _slippage
    ) external view returns (uint256);

    // ╭───────────────────────────────────────────────────────────────────────╮
    // │                                 Views                                 │
    // ╰───────────────────────────────────────────────────────────────────────╯

    /// @notice Gets the EverlongStrategyKeeper's kind.
    /// @return The EverlongStrategyKeeper's kind.
    function kind() external pure returns (string memory);

    /// @notice Name of the EverlongStrategyKeeper.
    /// @return The EverlongStrategyKeeper's name.
    function name() external pure returns (string memory);

    /// @notice Returns the address of the current owner.
    /// @return The current owner's address.
    function owner() external view returns (address);

    /// @notice Returns the address of the current RoleManager contract.
    /// @return The current RoleManager contract address.
    function roleManager() external view returns (address);

    /// @notice Returns the address of the current CommonReportTrigger contract.
    /// @return The current CommonReportTrigger address.
    function trigger() external view returns (address);

    /// @notice Gets the EverlongStrategyKeeper's version.
    /// @return The EverlongStrategyKeeper's version.
    function version() external pure returns (string memory);

    // ╭───────────────────────────────────────────────────────────────────────╮
    // │                                Errors                                 │
    // ╰───────────────────────────────────────────────────────────────────────╯

    /// @notice The caller account is not authorized to perform an operation.
    error OwnableUnauthorizedAccount(address account);

    /// @notice The owner is not a valid owner account. (eg. `address(0)`)
    error OwnableInvalidOwner(address owner);

    /// @notice Thrown when a strategy report reverts.
    error StrategyReportFailed(bytes data);

    /// @notice Thrown when `tend` reverts.
    error TendFailed(bytes data);

    /// @notice Thrown when `update_debt` reverts.
    error UpdateDebtFailed(bytes data);

    /// @notice Thrown when a vault report reverts.
    error VaultReportFailed(bytes data);

    // ╭───────────────────────────────────────────────────────────────────────╮
    // │                                Events                                 │
    // ╰───────────────────────────────────────────────────────────────────────╯

    /// @notice Ownership has been transferred from `previousOwner` to
    ///         `newOwner`.
    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );
}
