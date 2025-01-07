// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import { console2 as console } from "forge-std/console2.sol";
import { IERC20, IHyperdrive } from "hyperdrive/contracts/src/interfaces/IHyperdrive.sol";
import { FixedPointMath } from "hyperdrive/contracts/src/libraries/FixedPointMath.sol";
import { ERC20Mintable } from "hyperdrive/contracts/test/ERC20Mintable.sol";
import { HyperdriveTest } from "hyperdrive/test/utils/HyperdriveTest.sol";
import { HyperdriveUtils } from "hyperdrive/test/utils/HyperdriveUtils.sol";
import { CommonReportTrigger } from "lib/vault-periphery/lib/tokenized-strategy-periphery/src/ReportTrigger/CommonReportTrigger.sol";
import { DebtAllocator } from "vault-periphery/debtAllocators/DebtAllocator.sol";
import { IVault } from "yearn-vaults-v3/interfaces/IVault.sol";
import { IAccountant } from "../../contracts/interfaces/IAccountant.sol";
import { IAprOracle } from "../../contracts/interfaces/IAprOracle.sol";
import { IEverlongEvents } from "../../contracts/interfaces/IEverlongEvents.sol";
import { IEverlongStrategy } from "../../contracts/interfaces/IEverlongStrategy.sol";
import { IRoleManager } from "../../contracts/interfaces/IRoleManager.sol";
import { IRoleManagerFactory } from "../../contracts/interfaces/IRoleManagerFactory.sol";
import { MAX_BPS } from "../../contracts/libraries/Constants.sol";
import { EverlongStrategy } from "../../contracts/EverlongStrategy.sol";
import { EverlongStrategyKeeper } from "../../contracts/EverlongStrategyKeeper.sol";
import { IPermissionedStrategy } from "../../contracts/interfaces/IPermissionedStrategy.sol";
import { VaultTest } from "../VaultTest.sol";

/// @dev Everlong testing harness contract.
/// @dev Tests should extend this contract and call its `setUp` function.
contract EverlongTest is VaultTest, IEverlongEvents {
    using HyperdriveUtils for *;
    using FixedPointMath for *;

    /// @dev Whether to use the base token from the hyperdrive instance.
    bool internal AS_BASE = true;

    /// @dev Everlong token name.
    string internal EVERLONG_NAME = "Everlong Testing";

    /// @dev Everlong token symbol.
    string internal EVERLONG_SYMBOL = "EVRLNG";

    /// @dev Maximum slippage for bond purchases.
    uint256 internal MIN_OUTPUT_SLIPPAGE = 500;

    /// @dev Maximum slippage for vault share price.
    uint256 internal MIN_VAULT_SHARE_PRICE_SLIPPAGE = 500;

    /// @dev Whether to use a wrapped asset for the strategy.
    bool IS_WRAPPED;

    /// @dev Asset to use for the strategy when IS_WRAPPED=true.
    address WRAPPED_ASSET;

    /// @dev Periphery contract to simplify maintenance operations for vaults
    ///      and strategies.
    EverlongStrategyKeeper internal keeperContract;

    // ╭───────────────────────────────────────────────────────────────────────╮
    // │                             SetUp Helpers                             │
    // ╰───────────────────────────────────────────────────────────────────────╯

    /// @dev Set up the testing environment on a fork of mainnet.
    function setUp() public virtual override {
        super.setUp();
        setUpEverlongStrategy();
        setUpEverlongVault();
    }

    /// @dev Deploy the Everlong Yearn Tokenized Strategy.
    function setUpEverlongStrategy() internal {
        vm.startPrank(deployer);
        // Set Up the `keeper` address.
        (keeper, ) = createUser("keeper");

        // Deploy the EverlongStrategyKeeper helper contract.
        keeperContract = new EverlongStrategyKeeper(
            "EVERLONG_STRATEGY_KEEPER",
            address(roleManager),
            address(reportTrigger)
        );
        keeperContract.transferOwnership(keeper);

        // Deploy and configure the strategy.
        strategy = IPermissionedStrategy(
            address(
                new EverlongStrategy(
                    IS_WRAPPED
                        ? WRAPPED_ASSET
                        : (
                            AS_BASE
                                ? hyperdrive.baseToken()
                                : hyperdrive.vaultSharesToken()
                        ),
                    EVERLONG_NAME,
                    address(hyperdrive),
                    AS_BASE,
                    IS_WRAPPED
                )
            )
        );
        strategy.setPerformanceFeeRecipient(governance);
        strategy.setKeeper(address(keeperContract));
        strategy.setPendingManagement(management);
        (emergencyAdmin, ) = createUser("emergencyAdmin");
        strategy.setEmergencyAdmin(emergencyAdmin);
        vm.stopPrank();

        // Set the appropriate asset.
        asset = (
            IS_WRAPPED
                ? IERC20(WRAPPED_ASSET)
                : IERC20(
                    AS_BASE
                        ? hyperdrive.baseToken()
                        : hyperdrive.vaultSharesToken()
                )
        );

        // As the `management` address:
        //   1. Accept the `management` role for the strategy.
        //   2. Set the `profitMaxUnlockTime` to zero.
        vm.startPrank(management);
        strategy.acceptManagement();
        strategy.setProfitMaxUnlockTime(STRATEGY_PROFIT_MAX_UNLOCK_TIME);
        strategy.setPerformanceFee(0);
        vm.stopPrank();
    }

    /// @dev Deploy the Everlong Yearn v3 Vault.
    function setUpEverlongVault() internal {
        // As the `governance` address:
        //   1. Deploy the Vault using the RoleManager.
        //   2. Add the EverlongStrategy to the vault.
        //   3. Update the max debt for the strategy to be the maximum uint256.
        //   4. Configure the vault to `auto_allocate` which will automatically
        //      update the strategy's debt on deposit.
        vm.startPrank(governance);
        vault = IVault(
            roleManager.newVault(
                address(asset),
                0,
                EVERLONG_NAME,
                EVERLONG_SYMBOL
            )
        );
        vault.add_strategy(address(strategy));
        vault.update_max_debt_for_strategy(
            address(strategy),
            type(uint256).max
        );
        roleManager.setPositionHolder(
            roleManager.KEEPER(),
            address(keeperContract)
        );
        vm.stopPrank();

        // As the `management` address, configure the DebtAllocator to not
        // wait to update a strategy's debt and set the minimum change before
        // updating to just above hyperdrive's minimum transaction amount.
        vm.startPrank(management);
        // Set the vault's duration for unlocking profit.
        vault.setProfitMaxUnlockTime(VAULT_PROFIT_MAX_UNLOCK_TIME);
        // Enable deposits to the strategy from the vault.
        strategy.setDepositor(address(vault), true);
        // Give the `EverlongStrategyKeeper` role to the keeper address.
        debtAllocator.setKeeper(address(keeperContract), true);
        // Set minimum wait time for updating strategy debt.
        debtAllocator.setMinimumWait(0);
        // Set minimum change in debt for triggering an update.
        debtAllocator.setMinimumChange(
            address(vault),
            MINIMUM_TRANSACTION_AMOUNT + 1
        );
        debtAllocator.setStrategyDebtRatio(
            address(vault),
            address(strategy),
            MAX_BPS - TARGET_IDLE_LIQUIDITY_BASIS_POINTS,
            MAX_BPS - MIN_IDLE_LIQUIDITY_BASIS_POINTS
        );

        vm.stopPrank();
    }

    // ╭───────────────────────────────────────────────────────────────────────╮
    // │                          Rebalancing Helpers                          │
    // ╰───────────────────────────────────────────────────────────────────────╯

    /// @dev Call `everlong.rebalance(...)` as the admin with default options.
    function rebalance() internal override {
        vm.startPrank(keeper);
        keeperContract.update_debt(address(vault), address(strategy));
        keeperContract.tend(
            address(strategy),
            IEverlongStrategy.TendConfig({
                minOutput: keeperContract.calculateMinOutput(
                    address(strategy),
                    MIN_OUTPUT_SLIPPAGE
                ),
                minVaultSharePrice: keeperContract.calculateMinVaultSharePrice(
                    address(strategy),
                    MIN_VAULT_SHARE_PRICE_SLIPPAGE
                ),
                positionClosureLimit: 0,
                extraData: ""
            })
        );
        vm.stopPrank();
        // Skip forward one second so that `update_debt` doesn't get called on
        // the same timestamp.
        skip(1);
    }

    /// @dev Call `report` on the strategy then call `process_report` on the
    ///      vault if needed.
    function report() internal override {
        vm.startPrank(keeper);
        keeperContract.strategyReport(
            address(strategy),
            IEverlongStrategy.TendConfig({
                minOutput: keeperContract.calculateMinOutput(
                    address(strategy),
                    MIN_OUTPUT_SLIPPAGE
                ),
                minVaultSharePrice: keeperContract.calculateMinVaultSharePrice(
                    address(strategy),
                    MIN_VAULT_SHARE_PRICE_SLIPPAGE
                ),
                positionClosureLimit: 0,
                extraData: ""
            })
        );
        keeperContract.processReport(address(vault), address(strategy));
        vm.stopPrank();
    }
}
