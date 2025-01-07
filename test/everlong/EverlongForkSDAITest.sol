// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import { console2 as console } from "forge-std/console2.sol";
import { IERC20, IHyperdrive } from "hyperdrive/contracts/src/interfaces/IHyperdrive.sol";
import { ILido } from "hyperdrive/contracts/src/interfaces/ILido.sol";
import { IEverlongStrategy } from "../../contracts/interfaces/IEverlongStrategy.sol";
import { EVERLONG_STRATEGY_KIND, EVERLONG_VERSION } from "../../contracts/libraries/Constants.sol";
import { EverlongTest } from "./EverlongTest.sol";

/// @dev Configures the testing Everlong instance to point to the existing
///      SDAIHyperdrive instance on mainnet.
contract EverlongForkSDAITest is EverlongTest {
    address internal SDAI_HYPERDRIVE_ADDRESS =
        0x324395D5d835F84a02A75Aa26814f6fD22F25698;

    address internal SDAI_ADDRESS = 0x83F20F44975D03b1b09e64809B757c47f942BEeA;

    address internal SDAI_WHALE = 0x27d3745135693647155d87706FBFf3EB5B7345c2;

    function setUp() public virtual override {
        vm.createSelectFork(vm.rpcUrl("mainnet"), FORK_BLOCK_NUMBER);

        createTestUsers();

        // Set up the strategy to use the current StETH hyperdrive instance.
        hyperdrive = IHyperdrive(SDAI_HYPERDRIVE_ADDRESS);
        AS_BASE = false;
        IS_WRAPPED = false;

        setUpRoleManager();
        setUpEverlongStrategy();
        setUpEverlongVault();
    }

    /// @dev "Mint" tokens to an account by transferring from the whale.
    /// @param _amount Amount of tokens to "mint".
    /// @param _to Destination for the tokens.
    function mintSDAI(uint256 _amount, address _to) internal {
        vm.startPrank(SDAI_WHALE);
        asset.transfer(_to, _amount);
        vm.stopPrank();
    }

    /// @dev Deposit into the SDAI everlong vault.
    /// @param _assets Amount of assets to deposit.
    /// @param _from Source of the tokens.
    /// @return shares Amount of shares received from the deposit.
    function depositSDAI(
        uint256 _assets,
        address _from
    ) internal returns (uint256 shares) {
        mintSDAI(_assets, _from);
        vm.startPrank(_from);
        asset.approve(address(vault), _assets);
        shares = vault.deposit(_assets, _from);
        vm.stopPrank();
    }

    /// @dev Redeem shares from the SDAI everlong vault.
    /// @param _shares Amount of shares to redeem.
    /// @param _from Source of the shares.
    /// @return assets Amount of assets received from the redemption.
    function redeemSDAI(
        uint256 _shares,
        address _from
    ) internal returns (uint256 assets) {
        vm.startPrank(_from);
        assets = vault.redeem(_shares, _from, _from);
        vm.stopPrank();
    }
}
