// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import { console2 as console } from "forge-std/console2.sol";
import { IERC20, IHyperdrive } from "hyperdrive/contracts/src/interfaces/IHyperdrive.sol";
import { ILido } from "hyperdrive/contracts/src/interfaces/ILido.sol";
import { IEverlongStrategy } from "../../contracts/interfaces/IEverlongStrategy.sol";
import { EVERLONG_STRATEGY_KIND, EVERLONG_VERSION } from "../../contracts/libraries/Constants.sol";
import { EverlongTest } from "./EverlongTest.sol";

/// @dev Configures the testing Everlong instance to point to the existing
///      StETHHyperdrive instance on mainnet.
contract EverlongForkStETHTest is EverlongTest {
    address internal STETH_HYPERDRIVE_ADDRESS =
        0xd7e470043241C10970953Bd8374ee6238e77D735;

    address internal STETH_ADDRESS = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    address internal WSTETH_ADDRESS =
        0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    address internal STETH_WHALE = 0x51C2cEF9efa48e08557A361B52DB34061c025a1B;

    address internal WSTETH_WHALE = 0x5313b39bf226ced2332C81eB97BB28c6fD50d1a3;

    function setUp() public virtual override {
        vm.createSelectFork(vm.rpcUrl("mainnet"), FORK_BLOCK_NUMBER);

        createTestUsers();

        // Set up the strategy to use the current StETH hyperdrive instance.
        hyperdrive = IHyperdrive(STETH_HYPERDRIVE_ADDRESS);
        AS_BASE = false;
        IS_WRAPPED = true;
        WRAPPED_ASSET = WSTETH_ADDRESS;

        setUpRoleManager();
        setUpEverlongStrategy();
        setUpEverlongVault();
    }

    /// @dev "Mint" tokens to an account by transferring from the whale.
    /// @param _amount Amount of tokens to "mint".
    /// @param _to Destination for the tokens.
    function mintWSTETH(uint256 _amount, address _to) internal {
        vm.startPrank(WSTETH_WHALE);
        asset.transfer(_to, _amount);
        vm.stopPrank();
    }

    /// @dev Deposit into the WSTETH everlong vault.
    /// @param _assets Amount of assets to deposit.
    /// @param _from Source of the tokens.
    /// @return shares Amount of shares received from the deposit.
    function depositWSTETH(
        uint256 _assets,
        address _from
    ) internal returns (uint256 shares) {
        mintWSTETH(_assets, _from);
        vm.startPrank(_from);
        asset.approve(address(vault), _assets);
        shares = vault.deposit(_assets, _from);
        vm.stopPrank();
    }

    /// @dev Redeem shares from the WSTETH everlong vault.
    /// @param _shares Amount of shares to redeem.
    /// @param _from Source of the shares.
    /// @return assets Amount of assets received from the redemption.
    function redeemWSTETH(
        uint256 _shares,
        address _from
    ) internal returns (uint256 assets) {
        vm.startPrank(_from);
        assets = vault.redeem(_shares, _from, _from);
        vm.stopPrank();
    }
}
