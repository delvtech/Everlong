// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import { console2 as console } from "forge-std/console2.sol";
import { IERC20 } from "hyperdrive/contracts/src/interfaces/IHyperdrive.sol";
import { FixedPointMath } from "hyperdrive/contracts/src/libraries/FixedPointMath.sol";
import { ERC20Mintable } from "hyperdrive/contracts/test/ERC20Mintable.sol";
import { HyperdriveTest } from "hyperdrive/test/utils/HyperdriveTest.sol";
import { HyperdriveUtils } from "hyperdrive/test/utils/HyperdriveUtils.sol";
import { CommonReportTrigger } from "lib/vault-periphery/lib/tokenized-strategy-periphery/src/ReportTrigger/CommonReportTrigger.sol";
import { DebtAllocator } from "vault-periphery/debtAllocators/DebtAllocator.sol";
import { IVault } from "yearn-vaults-v3/interfaces/IVault.sol";
import { IAccountant } from "../contracts/interfaces/IAccountant.sol";
import { IAprOracle } from "../contracts/interfaces/IAprOracle.sol";
import { IPermissionedStrategy } from "../contracts/interfaces/IPermissionedStrategy.sol";
import { IRoleManager } from "../contracts/interfaces/IRoleManager.sol";
import { IRoleManagerFactory } from "../contracts/interfaces/IRoleManagerFactory.sol";
import { MAX_BPS } from "../contracts/libraries/Constants.sol";

/// @dev Vault testing harness contract.
/// @dev Extending contracts must implement `rebalance()` and `report()`.
abstract contract VaultTest is HyperdriveTest {
    using HyperdriveUtils for *;
    using FixedPointMath for *;

    // ╭───────────────────────────────────────────────────────────────────────╮
    // │                          Fork Configuration                           │
    // ╰───────────────────────────────────────────────────────────────────────╯
    uint256 FORK_BLOCK_NUMBER = 21_381_521;

    // ╭───────────────────────────────────────────────────────────────────────╮
    // │                        HyperdriveTest Storage                         │
    // ╰───────────────────────────────────────────────────────────────────────╯

    // address alice
    // address bob
    // address celine
    // address dan
    // address eve
    //
    // address minter
    // address deployer
    // address feeCollector
    // address sweepCollector
    // address governance
    // address pauser
    // address registrar
    // address rewardSource
    //
    // ERC20ForwarderFactory         forwarderFactory
    // ERC20Mintable                 baseToken
    // IHyperdriveGovernedRegistry   registry
    // IHyperdriveCheckpointRewarder checkpointRewarder
    // IHyperdrive                   hyperdrive

    // ╭───────────────────────────────────────────────────────────────────────╮
    // │                       Hyperdrive Configuration                        │
    // ╰───────────────────────────────────────────────────────────────────────╯

    /// @dev Address calling `initialize(..)` on the hyperdrive instance.
    address internal HYPERDRIVE_INITIALIZER = address(0);

    /// @dev Fixed rate for the hyperdrive instance.
    uint256 internal FIXED_RATE = 0.05e18;

    /// @dev Variable rate for the hyperdrive instance.
    int256 internal VARIABLE_RATE = 0.05e18;

    /// @dev Initial vault share price for the hyperdrive instance.
    uint256 internal INITIAL_VAULT_SHARE_PRICE = 1e18;

    /// @dev Initial contribution for the hyperdrive instance.
    uint256 internal INITIAL_CONTRIBUTION = 1_000_000e18;

    /// @dev Curve fee for the hyperdrive instance.
    uint256 internal CURVE_FEE = 0.01e18;

    /// @dev Flat fee for the hyperdrive instance.
    uint256 internal FLAT_FEE = 0.0005e18;

    /// @dev Governance LP fee for the hyperdrive instance.
    uint256 internal GOVERNANCE_LP_FEE = 0.15e18;

    /// @dev Governance Zombie fee for the hyperdrive instance.
    uint256 internal GOVERNANCE_ZOMBIE_FEE = 0.03e18;

    // ╭───────────────────────────────────────────────────────────────────────╮
    // │                    Vault + Strategy Configuration                     │
    // ╰───────────────────────────────────────────────────────────────────────╯

    /// @dev Time period for the strategy to release profits over.
    uint256 internal STRATEGY_PROFIT_MAX_UNLOCK_TIME = 0 days;

    /// @dev Time period for the strategy to release profits over.
    uint256 internal VAULT_PROFIT_MAX_UNLOCK_TIME = 1 days;

    /// @dev Vault/Strategy asset.
    IERC20 internal asset;

    /// @dev Minimum idle liquidity (in basis points) for the Everlong vault.
    uint256 internal MIN_IDLE_LIQUIDITY_BASIS_POINTS = 500;

    /// @dev Target idle liquidity (in basis points) for the Everlong vault.
    uint256 internal TARGET_IDLE_LIQUIDITY_BASIS_POINTS = 1000;

    /// @dev Vault management address.
    /// @dev Used when interacting with the `DebtAllocator`.
    address internal management;

    /// @dev Keeper address.
    address internal keeper;

    /// @dev Emergency admin address.
    address internal emergencyAdmin;

    /// @dev Mainnet `RoleManager` factory.
    IRoleManagerFactory internal roleManagerFactory =
        IRoleManagerFactory(0xca12459a931643BF28388c67639b3F352fe9e5Ce);

    /// @dev Yearn apr oracle.
    /// @dev Capable of getting the current and expected apr for any vault or
    ///      strategy.
    IAprOracle internal aprOracle =
        IAprOracle(0x1981AD9F44F2EA9aDd2dC4AD7D075c102C70aF92);

    /// @dev Shared contract providing default triggers for vault reporting,
    ///      strategy reporting, and strategy tending.
    CommonReportTrigger internal reportTrigger =
        CommonReportTrigger(0xA045D4dAeA28BA7Bfe234c96eAa03daFae85A147);

    /// @dev Strategy address.
    IPermissionedStrategy internal strategy;

    /// @dev Vault address.
    IVault internal vault;

    /// @dev Vault role manager.
    /// @dev Handles setup and permissioning for
    ///      vault periphery contracts such as DebtAllocator and Accountant.
    IRoleManager internal roleManager;

    /// @dev Vault debt allocator.
    /// @dev Handles vault debt allocation to strategies.
    DebtAllocator internal debtAllocator;

    /// @dev Vault accountant.
    /// @dev Handles fee and reporting configuration.
    IAccountant internal accountant;

    // ╭───────────────────────────────────────────────────────────────────────╮
    // │                         Maintenance Overrides                         │
    // ╰───────────────────────────────────────────────────────────────────────╯

    /// @dev Call `everlong.rebalance(...)` as the admin with default options.
    /// @dev Must be implemented by extending contract.
    function rebalance() internal virtual;

    /// @dev Call `report` on the strategy then call `process_report` on the
    ///      vault if needed.
    /// @dev Must be implemented by extending contract.
    function report() internal virtual;

    // ╭───────────────────────────────────────────────────────────────────────╮
    // │                             SetUp Helpers                             │
    // ╰───────────────────────────────────────────────────────────────────────╯

    /// @dev Set up the testing environment on a fork of mainnet.
    function setUp() public virtual override {
        vm.createSelectFork(vm.rpcUrl("mainnet"), FORK_BLOCK_NUMBER);
        super.setUp();
        setUpHyperdrive();
        setUpRoleManager();
    }

    /// @dev Deploy and initialize the hyperdrive instance with seed liquidity.
    function setUpHyperdrive() internal {
        vm.startPrank(deployer);

        // Deploy the hyperdrive instance.
        deploy(
            deployer,
            FIXED_RATE,
            INITIAL_VAULT_SHARE_PRICE,
            CURVE_FEE,
            FLAT_FEE,
            GOVERNANCE_LP_FEE,
            GOVERNANCE_ZOMBIE_FEE
        );

        // Seed liquidity for the hyperdrive instance.
        if (HYPERDRIVE_INITIALIZER == address(0)) {
            HYPERDRIVE_INITIALIZER = deployer;
        }
        initialize(HYPERDRIVE_INITIALIZER, FIXED_RATE, INITIAL_CONTRIBUTION);

        vm.stopPrank();
    }

    /// @dev Deploy the RoleManager and store the periphery contract addresses.
    function setUpRoleManager() internal {
        // Set up the `management` address.
        (management, ) = createUser("management");

        // Deploy the RoleManager from the factory and store the relevant
        // RoleManager component addresses.
        vm.startPrank(deployer);
        roleManager = IRoleManager(
            roleManagerFactory.newProject("DELV", governance, management)
        );
        debtAllocator = DebtAllocator(roleManager.getDebtAllocator());
        accountant = IAccountant(roleManager.getAccountant());
        vm.stopPrank();

        // As the `governance` address:
        //   1. Accept the "Fee Manager" role for the Accountant.
        //   2. Set the default `config.maxLoss` for the accountant to be 10%.
        //      This will enable losses of up to 10% across reports before
        //      reverting.
        vm.startPrank(governance);
        accountant.acceptFeeManager();
        IAccountant.Fee memory defaultConfig = accountant.defaultConfig();
        // Must increase the accountant maxLoss for reporting since `totalAssets`
        // decreases whenever opening longs.
        accountant.updateDefaultConfig(
            0,
            0,
            0,
            0,
            defaultConfig.maxGain,
            defaultConfig.maxLoss
        );
        vm.stopPrank();
    }

    /// @dev Create all the role-based and arbitrary users used in testing.
    ///      The `setUp` function from `HyperdriveTest` creates these for us,
    ///      but if its overridden then this must be called.
    function createTestUsers() internal {
        // Create role-based users.
        (deployer, ) = createUser("deployer");
        (governance, ) = createUser("governance");
        (keeper, ) = createUser("keeper");
        (management, ) = createUser("management");
        (emergencyAdmin, ) = createUser("emergencyAdmin");

        // Create arbitrary test users.
        (alice, alicePK) = createUser("alice");
        (bob, bobPK) = createUser("bob");
        (celine, celinePK) = createUser("celine");
        (dan, danPK) = createUser("dan");
        (eve, evePK) = createUser("eve");
    }

    // ╭───────────────────────────────────────────────────────────────────────╮
    // │                            Deposit Helpers                            │
    // ╰───────────────────────────────────────────────────────────────────────╯

    /// @dev Deposit into the strategy.
    /// @param _amount Amount of assets to deposit.
    /// @param _depositor Address to deposit as.
    /// @return shares Amount of shares received from the deposit.
    function depositStrategy(
        uint256 _amount,
        address _depositor
    ) internal returns (uint256 shares) {
        return depositStrategy(_amount, _depositor, false);
    }

    // NOTE: Core functionality for all `depositStrategy(..)` overloads.
    //       This is the most verbose, probably don't want to call it directly.
    function depositStrategy(
        uint256 _amount,
        address _depositor,
        bool _shouldRebalance
    ) internal returns (uint256 shares) {
        // Resolve the appropriate token.
        ERC20Mintable token = ERC20Mintable(vault.asset());

        // Enable deposits from _depositor.
        vm.startPrank(management);
        strategy.setDepositor(_depositor, true);
        vm.stopPrank();

        // Mint sufficient tokens to _depositor.
        vm.startPrank(_depositor);
        token.mint(_amount);
        vm.stopPrank();

        // Approve everlong as _depositor.
        vm.startPrank(_depositor);
        token.approve(address(strategy), _amount);
        vm.stopPrank();

        // Make the deposit.
        vm.startPrank(_depositor);
        shares = strategy.deposit(_amount, _depositor);
        vm.stopPrank();

        // Rebalance if specified.
        if (_shouldRebalance) {
            rebalance();
        }

        // Return the amount of shares issued to _depositor for the deposit.
        return shares;
    }

    /// @dev Deposit into the vault.
    /// @param _amount Amount of assets to deposit.
    /// @param _depositor Address to deposit as.
    /// @return shares Amount of shares received from the deposit.
    function depositVault(
        uint256 _amount,
        address _depositor
    ) internal returns (uint256 shares) {
        return depositVault(_amount, _depositor, false);
    }

    // NOTE: Core functionality for all `depositVault(..)` overloads.
    //       This is the most verbose, probably don't want to call it directly.
    function depositVault(
        uint256 _amount,
        address _depositor,
        bool _shouldRebalance
    ) internal returns (uint256 shares) {
        // Resolve the appropriate token.
        ERC20Mintable token = ERC20Mintable(vault.asset());

        // Mint sufficient tokens to _depositor.
        vm.startPrank(_depositor);
        token.mint(_amount);
        vm.stopPrank();

        // Approve everlong as _depositor.
        vm.startPrank(_depositor);
        token.approve(address(vault), _amount);
        vm.stopPrank();

        // Make the deposit.
        vm.startPrank(_depositor);
        shares = vault.deposit(_amount, _depositor);
        vm.stopPrank();

        // Rebalance if specified.
        if (_shouldRebalance) {
            rebalance();
        }

        // Return the amount of shares issued to _depositor for the deposit.
        return shares;
    }

    // ╭───────────────────────────────────────────────────────────────────────╮
    // │                            Redeem Helpers                             │
    // ╰───────────────────────────────────────────────────────────────────────╯

    /// @dev Redeem shares from the strategy.
    /// @param _shares Amount of shares to redeem.
    /// @param _redeemer Address to redeem as.
    /// @return assets Amount of assets received from the redemption.
    function redeemStrategy(
        uint256 _shares,
        address _redeemer
    ) internal returns (uint256 assets) {
        assets = redeemStrategy(_shares, _redeemer, false);
        return assets;
    }

    // NOTE: Core functionality for all `redeemStrategy(..)` overloads.
    //       This is the most verbose, probably don't want to call it directly.
    function redeemStrategy(
        uint256 _amount,
        address _redeemer,
        bool _shouldRebalance
    ) internal returns (uint256 proceeds) {
        // Make the redemption.
        vm.startPrank(_redeemer);
        proceeds = strategy.redeem(_amount, _redeemer, _redeemer);
        vm.stopPrank();

        // Rebalance if specified.
        if (_shouldRebalance) {
            rebalance();
        }
    }

    /// @dev Redeem shares from the vault.
    /// @param _shares Amount of shares to redeem.
    /// @param _redeemer Address to redeem as.
    /// @return assets Amount of assets received from the redemption.
    function redeemVault(
        uint256 _shares,
        address _redeemer
    ) internal returns (uint256 assets) {
        assets = redeemVault(_shares, _redeemer, false);
        return assets;
    }

    // NOTE: Core functionality for all `redeemVault(..)` overloads.
    //       This is the most verbose, probably don't want to call it directly.
    function redeemVault(
        uint256 _amount,
        address _redeemer,
        bool _shouldRebalance
    ) internal returns (uint256 proceeds) {
        // Make the redemption.
        vm.startPrank(_redeemer);
        proceeds = vault.redeem(_amount, _redeemer, _redeemer);
        vm.stopPrank();

        // Rebalance if specified.
        if (_shouldRebalance) {
            rebalance();
        }
    }

    /// @dev Mint token to the provided address and approve the vault and
    ///      strategy.
    /// @param _recipient Receiver of the minted assets.
    /// @param _amount Amount of assets to mint.
    function mintApproveAsset(address _recipient, uint256 _amount) internal {
        ERC20Mintable(address(asset)).mint(_recipient, _amount);
        vm.startPrank(_recipient);
        ERC20Mintable(address(asset)).approve(address(vault), _amount);
        ERC20Mintable(address(asset)).approve(address(strategy), _amount);
        vm.stopPrank();
    }

    // ╭───────────────────────────────────────────────────────────────────────╮
    // │                             Time Helpers                              │
    // ╰───────────────────────────────────────────────────────────────────────╯

    /// @dev Advance time by the specified amount at the global variable rate.
    /// @param _time Amount of time to advance.
    function advanceTimeWithCheckpoints(uint256 _time) internal virtual {
        advanceTimeWithCheckpoints(_time, VARIABLE_RATE);
    }

    /// @dev Advance time and rebalance on the specified interval.
    /// @dev If time % _rebalanceInterval != 0 then it ends up advancing time
    ///      to the next _rebalanceInterval.
    /// @param _time Amount of time to advance.
    /// @param _rebalanceInterval Amount of time between rebalances.
    function advanceTimeWithRebalancing(
        uint256 _time,
        uint256 _rebalanceInterval
    ) internal virtual {
        uint256 startTimeElapsed = block.timestamp;
        // Note: if time % _rebalanceInterval != 0 then it ends up
        // advancing time to the next _rebalanceInterval.
        while (block.timestamp - startTimeElapsed < _time) {
            advanceTime(_rebalanceInterval, VARIABLE_RATE);
            rebalance();
        }
    }

    /// @dev Advance time, create checkpoints, and report at checkpoints.
    /// @dev If time % _rebalanceInterval != 0 then it ends up advancing time
    ///      to the next _rebalanceInterval.
    /// @param _time Amount of time to advance.
    function advanceTimeWithCheckpointsAndReporting(
        uint256 _time
    ) internal virtual {
        uint256 startTimeElapsed = block.timestamp;
        // Note: if time % CHECKPOINT_DURATION != 0 then it ends up
        // advancing time to the next checkpoint.
        while (block.timestamp - startTimeElapsed < _time) {
            advanceTime(CHECKPOINT_DURATION, VARIABLE_RATE);
            // Create the checkpoint.
            hyperdrive.checkpoint(
                HyperdriveUtils.latestCheckpoint(hyperdrive),
                0
            );
            // Update debt for the vault and rebalance the strategy.
            rebalance();
            // Generate reports for the strategy and vault.
            report();
        }
    }

    /// @dev Advance time, create checkpoints, and rebalance at checkpoints.
    /// @dev If time % _rebalanceInterval != 0 then it ends up advancing time
    ///      to the next _rebalanceInterval.
    /// @param _time Amount of time to advance.
    function advanceTimeWithCheckpointsAndRebalancing(
        uint256 _time
    ) internal virtual {
        uint256 startTimeElapsed = block.timestamp;
        // Note: if time % CHECKPOINT_DURATION != 0 then it ends up
        // advancing time to the next checkpoint.
        while (block.timestamp - startTimeElapsed < _time) {
            advanceTime(CHECKPOINT_DURATION, VARIABLE_RATE);
            // Create the checkpoint.
            hyperdrive.checkpoint(
                HyperdriveUtils.latestCheckpoint(hyperdrive),
                0
            );
            // Update debt for the vault and rebalance the strategy.
            rebalance();
        }
    }

    // ╭───────────────────────────────────────────────────────────────────────╮
    // │                        Idle Liquidity Helpers                         │
    // ╰───────────────────────────────────────────────────────────────────────╯

    /// @dev Calculates the target amount of idle assets for the vault.
    /// @return Target idle assets for the vault.
    function targetIdleLiquidity() internal virtual returns (uint256) {
        return
            (MAX_BPS -
                uint256(
                    debtAllocator
                        .getStrategyConfig(address(vault), address(strategy))
                        .targetRatio
                )).mulDivDown(vault.totalAssets(), MAX_BPS);
    }

    /// @dev Calculates the minimum amount of idle assets for the vault.
    /// @return Minimum idle assets for the vault.
    function minIdleLiquidity() internal virtual returns (uint256) {
        return
            (MAX_BPS -
                uint256(
                    debtAllocator
                        .getStrategyConfig(address(vault), address(strategy))
                        .maxRatio
                )).mulDivDown(vault.totalAssets(), MAX_BPS);
    }
}
