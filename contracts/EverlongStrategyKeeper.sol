// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import { IHyperdrive } from "hyperdrive/contracts/src/interfaces/IHyperdrive.sol";
import { FixedPointMath } from "hyperdrive/contracts/src/libraries/FixedPointMath.sol";
import { SafeCast } from "hyperdrive/contracts/src/libraries/SafeCast.sol";
import { CommonReportTrigger } from "lib/vault-periphery/lib/tokenized-strategy-periphery/src/ReportTrigger/CommonReportTrigger.sol";
import { Ownable } from "openzeppelin/access/Ownable.sol";
import { IERC20 } from "openzeppelin/token/ERC20/IERC20.sol";
import { SafeERC20 } from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import { BaseStrategy, ERC20 } from "tokenized-strategy/BaseStrategy.sol";
import { IStrategy } from "tokenized-strategy/interfaces/IStrategy.sol";
import { DebtAllocator } from "vault-periphery/debtAllocators/DebtAllocator.sol";
import { IVault } from "yearn-vaults-v3/interfaces/IVault.sol";
import { Roles } from "yearn-vaults-v3/interfaces/Roles.sol";
import { IEverlongStrategy } from "./interfaces/IEverlongStrategy.sol";
import { IRoleManager } from "./interfaces/IRoleManager.sol";
import { EVERLONG_STRATEGY_KEEPER_KIND, EVERLONG_VERSION, ONE, MAX_BPS } from "./libraries/Constants.sol";
import { EverlongPortfolioLibrary } from "./libraries/EverlongPortfolio.sol";
import { HyperdriveExecutionLibrary } from "./libraries/HyperdriveExecution.sol";

/// @author DELV
/// @title EverlongStrategyKeeper
/// @notice Periphery contract to simplify operations for keepers.
/// @custom:disclaimer The language used in this code is for coding convenience
///                    only, and is not intended to, and does not, have any
///                    particular legal or regulatory significance.
contract EverlongStrategyKeeper is Ownable {
    using FixedPointMath for uint256;
    using HyperdriveExecutionLibrary for IHyperdrive;
    using EverlongPortfolioLibrary for EverlongPortfolioLibrary.State;
    using SafeCast for *;
    using SafeERC20 for ERC20;

    /// @notice Kind of the EverlongStrategyKeeper.
    string public constant kind = EVERLONG_STRATEGY_KEEPER_KIND;

    /// @notice Version of the EverlongStrategyKeeper.
    string public constant version = EVERLONG_VERSION;

    /// @notice Name of the EverlongStrategyKeeper.
    string public name;

    /// @notice Address of the target RoleManager contract.
    /// @dev Helpful for getting periphery contract addresses and enumerating
    ///      vaults.
    address public roleManager;

    /// @notice Address of the external `CommonReportTrigger` contract.
    /// @dev This contract contains default checks for whether to report+tend.
    address public trigger;

    /// @notice Initialize the EverlongStrategyKeeper contract.
    /// @param _name Name for the keeper contract.
    /// @param _roleManager Address for the `RoleManager` contract.
    /// @param _trigger Address for the `CommonReportTrigger` contract.
    constructor(
        string memory _name,
        address _roleManager,
        address _trigger
    ) Ownable(msg.sender) {
        name = _name;
        roleManager = _roleManager;
        trigger = _trigger;
    }

    // ╭───────────────────────────────────────────────────────────────────────╮
    // │                                Setters                                │
    // ╰───────────────────────────────────────────────────────────────────────╯

    /// @notice Updates the address of the CommonReportTrigger contract.
    /// @param _trigger Address of the CommonReportTrigger contract to set.
    function setTrigger(address _trigger) external onlyOwner {
        trigger = _trigger;
    }

    /// @notice Updates the address of the RoleManager contract.
    /// @param _roleManager Address of the RoleManager contract to set.
    function setRoleManager(address _roleManager) external onlyOwner {
        roleManager = _roleManager;
    }

    // ╭───────────────────────────────────────────────────────────────────────╮
    // │                              Maintenance                              │
    // ╰───────────────────────────────────────────────────────────────────────╯

    /// @notice Calls `process_report()` on the vault/strategy combination if
    ///      needed.
    /// @param _vault Address of the vault contract to process the report on.
    /// @param _strategy Address of the strategy contract to process the report
    ///        on.
    function processReport(
        address _vault,
        address _strategy
    ) external onlyOwner {
        // Bail if this contract doesn't have the REPORTING_MANAGER role.
        uint256 roleMap = IVault(_vault).roles(address(this));
        if (roleMap & Roles.REPORTING_MANAGER != roleMap) {
            return;
        }

        // Check if report should be called on the vault/strategy combination.
        (
            bool shouldReportVault,
            bytes memory vaultCalldataOrReason
        ) = CommonReportTrigger(trigger).vaultReportTrigger(_vault, _strategy);

        // If process_report should be called, call it with the recommended
        // parameters.
        if (shouldReportVault) {
            (bool success, bytes memory err) = _vault.call(
                vaultCalldataOrReason
            );
            if (!success) {
                revert(
                    string.concat("vault process_report failed: ", string(err))
                );
            }
        }
    }

    /// @dev Calls `report()` on the strategy if needed.
    /// @param _strategy Address of the strategy contract to report on.
    /// @param _config Configuration for the `tend()` function called within
    ///        `_harvestAndReport()` in the strategy.
    function strategyReport(
        address _strategy,
        IEverlongStrategy.TendConfig memory _config
    ) external onlyOwner {
        // Bail if this contract isn't the keeper.
        if (IStrategy(_strategy).keeper() != address(this)) {
            return;
        }

        // Check if report should be called on the strategy.
        (
            bool shouldReportStrategy,
            bytes memory strategyCalldataOrReason
        ) = CommonReportTrigger(trigger).strategyReportTrigger(_strategy);

        // If report should be called, call it with the recommended parameters.
        if (shouldReportStrategy) {
            IEverlongStrategy(_strategy).setTendConfig(_config);
            (bool success, bytes memory err) = _strategy.call(
                strategyCalldataOrReason
            );
            if (!success) {
                revert(string.concat("strategy report failed: ", string(err)));
            }
        }
    }

    /// @dev Calls `tend()` on the strategy if needed and sets the
    ///      tend configuration.
    /// @param _strategy Address of the strategy to tend.
    /// @param _config Configuration for the tend call.
    function tend(
        address _strategy,
        IEverlongStrategy.TendConfig memory _config
    ) external onlyOwner {
        // Bail if this contract isn't the keeper.
        if (IStrategy(_strategy).keeper() != address(this)) {
            return;
        }

        // Check if tend should be called.
        (bool shouldTend_, bytes memory calldataOrReason) = CommonReportTrigger(
            trigger
        ).strategyTendTrigger(_strategy);

        // If tend should be called, call it with the recommended parameters.
        if (shouldTend_) {
            IEverlongStrategy(_strategy).setTendConfig(_config);
            (bool success, bytes memory err) = _strategy.call(calldataOrReason);
            if (!success) {
                revert(string.concat("strategy tend failed: ", string(err)));
            }
        }
    }

    /// @dev Calls `update_debt()` on the vault if needed.
    /// @param _vault Address of the vault to update debt for.
    /// @param _strategy Address of the strategy to update debt for.
    function update_debt(address _vault, address _strategy) external onlyOwner {
        // Get the DebtAllocator contract address.
        DebtAllocator debtAllocator = DebtAllocator(
            IRoleManager(roleManager).getDebtAllocator(_vault)
        );

        // Bail if there's no DebtAllocator for the vault or this contract isn't
        // the keeper.
        if (
            address(debtAllocator) == address(0) ||
            !debtAllocator.keepers(address(this))
        ) {
            revert("vault update debt failed: improper vault configuration");
        }

        // If update_debt should be called, call it with the recommended parameters.
        (bool shouldUpdateDebt_, bytes memory calldataOrReason) = debtAllocator
            .shouldUpdateDebt(_vault, _strategy);
        if (shouldUpdateDebt_) {
            (bool success, bytes memory err) = address(debtAllocator).call(
                calldataOrReason
            );
            if (!success) {
                revert(
                    string.concat("vault update debt failed: ", string(err))
                );
            }
        }
    }

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
    ) external view returns (bool shouldProcessReport_) {
        // Check if report should be called on the vault/strategy combination.
        (shouldProcessReport_, ) = CommonReportTrigger(trigger)
            .vaultReportTrigger(_vault, _strategy);
    }

    /// @notice Returns whether `report(..)` should be called on the strategy.
    /// @param _strategy Address of the strategy.
    /// @return shouldStrategyReport_ True if `report(..)` should be called,
    ///                               false otherwise.
    function shouldStrategyReport(
        address _strategy
    ) external view returns (bool shouldStrategyReport_) {
        // Check if report should be called on the strategy.
        (shouldStrategyReport_, ) = CommonReportTrigger(trigger)
            .strategyReportTrigger(_strategy);
    }

    /// @notice Returns whether `tend(..)` should be called on the strategy.
    /// @param _strategy Address of the strategy.
    /// @return shouldTend_ True if `tend(..)` should be called on the strategy,
    ///                     false otherwise.
    function shouldTend(
        address _strategy
    ) external view returns (bool shouldTend_) {
        // Check if tend should be called.
        (shouldTend_, ) = CommonReportTrigger(trigger).strategyTendTrigger(
            _strategy
        );
    }

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
    ) external view returns (bool shouldUpdateDebt_) {
        // Get the DebtAllocator contract address.
        DebtAllocator debtAllocator = DebtAllocator(
            IRoleManager(roleManager).getDebtAllocator(_vault)
        );
        // If update_debt should be called, call it with the recommended parameters.
        (shouldUpdateDebt_, ) = debtAllocator.shouldUpdateDebt(
            _vault,
            _strategy
        );
    }

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
    ) external view returns (uint256) {
        // Obtain the amount of idle currently present in the strategy.
        uint256 canSpend = IERC20(IEverlongStrategy(_strategy).asset())
            .balanceOf(_strategy);

        // Retrieve the strategy's Hyperdrive instance, its PoolConfig, and
        // determine whether the strategy will be transacting with its
        // base token.
        IHyperdrive hyperdrive = IHyperdrive(
            IEverlongStrategy(_strategy).hyperdrive()
        );
        IHyperdrive.PoolConfig memory poolConfig = hyperdrive.getPoolConfig();
        bool asBase = IEverlongStrategy(_strategy).asBase();

        // If the strategy has matured positions, increase the amount to spend
        // by the proceeds of closing these positions.
        if (IEverlongStrategy(_strategy).hasMaturedPositions()) {
            // Increment the amount that can be spent by the value of each
            // matured position in the strategy's portfolio. Since the
            // positions are stored from most to least mature, we can exit
            // when an immature position is encountered.
            uint256 positionCount = IEverlongStrategy(_strategy)
                .positionCount();
            IEverlongStrategy.EverlongPosition memory position;
            for (uint256 i = 0; i < positionCount; i++) {
                position = IEverlongStrategy(_strategy).positionAt(i);
                if (hyperdrive.isMature(position)) {
                    canSpend += hyperdrive.previewCloseLong(
                        asBase,
                        poolConfig,
                        position,
                        ""
                    );
                } else {
                    break;
                }
            }
        }

        // Skip calculations and return early if no assets are to be spent.
        if (canSpend == 0) {
            return 0;
        }

        // Calculate the amount of bonds that would be received if a long was
        // opened with `canSpend` assets.
        uint256 expectedOutput = hyperdrive.previewOpenLong(
            asBase,
            poolConfig,
            canSpend.min(
                IEverlongStrategy(_strategy).availableDepositLimit(_strategy)
            ),
            ""
        );

        // Decrease the output by the maximum acceptable slippage and return
        // the result.
        return expectedOutput.mulDivDown(MAX_BPS - _slippage, MAX_BPS);
    }

    /// @notice Calculates an appropriate `TendConfig.minVaultSharePrice` for
    ///         the input `_strategy` given the provided `_slippage` tolerance.
    /// @param _strategy Strategy to be tended.
    /// @param _slippage Maximum acceptable slippage in basis points where a
    ///        value of 10_000 indicates 100% slippage.
    function calculateMinVaultSharePrice(
        address _strategy,
        uint256 _slippage
    ) external view returns (uint256) {
        return
            IHyperdrive(IEverlongStrategy(_strategy).hyperdrive())
                .vaultSharePrice()
                .mulDivDown(MAX_BPS - _slippage, MAX_BPS);
    }
}
