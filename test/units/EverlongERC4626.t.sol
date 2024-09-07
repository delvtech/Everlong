// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

// solhint-disable-next-line no-console, no-unused-import
import { console2 as console } from "forge-std/console2.sol";
import { EverlongTest } from "../harnesses/EverlongTest.sol";

/// @dev Tests EverlongERC4626 functionality.
/// @dev Functions not overridden by Everlong are assumed to be functional.
contract TestEverlongERC4626 is EverlongTest {
    /// @dev Performs a redemption while ensuring the preview amount at most
    ///      equals the actual output and is within tolerance.
    /// @param _shares Amount of shares to redeem.
    /// @param _redeemer Address of the share holder.
    /// @return assets Assets sent to _redeemer from the redemption.
    function assertRedemption(
        uint256 _shares,
        address _redeemer
    ) public returns (uint256 assets) {
        uint256 preview = everlong.previewRedeem(_shares);
        vm.startPrank(_redeemer);
        assets = everlong.redeem(_shares, _redeemer, _redeemer);
        vm.stopPrank();
        assertLe(preview, assets);
        assertApproxEqAbs(preview, assets, 1e9);
    }

    /// @dev Tests that previewRedeem does not overestimate proceeds for a
    ///      single shareholder immediately redeeming all their shares.
    function test_previewRedeem_single_instant_full() external {
        // Deploy the everlong instance.
        deployEverlong();

        // Deposit into everlong.
        uint256 amount = 250e18;
        uint256 shares = depositEverlong(amount, alice);

        // Ensure that previewRedeem output is at most equal to actual output
        // and within margins.
        assertRedemption(shares, alice);
    }

    /// @dev Tests that previewRedeem does not overestimate proceeds for a
    ///      single shareholder immediately redeeming part of their shares.
    function test_previewRedeem_single_partial() external {
        // Deploy the everlong instance.
        deployEverlong();

        // Deposit into everlong.
        uint256 amount = 250e18;
        uint256 shares = depositEverlong(amount, alice);

        // Ensure that previewRedeem output is at most equal to actual output
        // and within margins.
        assertRedemption(shares - 1, alice);
    }
}
