// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.22;

import { console2 as console } from "forge-std/console2.sol";
import { IHyperdrive } from "hyperdrive/contracts/src/interfaces/IHyperdrive.sol";
import { FixedPointMath } from "hyperdrive/contracts/src/libraries/FixedPointMath.sol";
import { SafeCast } from "hyperdrive/contracts/src/libraries/SafeCast.sol";
import { HyperdriveUtils } from "hyperdrive/test/utils/HyperdriveUtils.sol";
import { SafeERC20 } from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import { BaseStrategy, ERC20 } from "tokenized-strategy/BaseStrategy.sol";
import { BaseHealthCheck } from "tokenized-strategy-periphery/Bases/HealthCheck/BaseHealthCheck.sol";
import { IEverlongStrategy } from "./interfaces/IEverlongStrategy.sol";
import { EVERLONG_KIND, EVERLONG_VERSION, ONE } from "./libraries/Constants.sol";
import { HyperdriveExecutionLibrary } from "./libraries/HyperdriveExecution.sol";
import { Portfolio } from "./libraries/Portfolio.sol";

//           ,---..-.   .-.,---.  ,---.   ,-.    .---.  .-. .-.  ,--,
//           | .-' \ \ / / | .-'  | .-.\  | |   / .-. ) |  \| |.' .'
//           | `-.  \ V /  | `-.  | `-'/  | |   | | |(_)|   | ||  |  __
//           | .-'   ) /   | .-'  |   (   | |   | | | | | |\  |\  \ ( _)
//           |  `--.(_)    |  `--.| |\ \  | `--.\ `-' / | | |)| \  `-) )
//           /( __.'       /( __.'|_| \)\ |( __.')---'  /(  (_) )\____/
//          (__)          (__)        (__)(_)   (_)    (__)    (__)
//
//          ##########      #++###################################      ### ######
//              ##########  #####################################   ###########
//                  #########################################################
//                  ##+###################################################
//                   ###############################################
//                   ##+#########++++++++++++++++++################
//                    ##+#####+++++++++++++++++++++++++++#########+
//                   +#######++++++++++++++++++++++++++++++######
//      ####################++++++++++++++++++++++++++++++++++#####
//   #####+# #+############++++++++++++++++++++++++++++++++++++##############
// ##+    ++##############+++++++++++++++++++++++++++++++++-++++###################
// ######################++++++++++++++++++++++++++++++++++-++++##########  ####+ #
// +#++++###############++++++++++#######++++++++++++++++++++++++#######      #####
//     +########+######++++++++++++++++++++++++++++++++++++++++++####           ###
//    ####  ###########++++++--+++++##++++++++++++++##+++++++++++####             #
//  +#################+++++--+++++++###+#++++++++++++####++++++++#######
// +##################++++++++++++++++++##+++++++++++###+++++++++#########
// ##################++++++++++++++++++++++++++++++++++###+++++++###############
// ##################++-+++++++++++++++++++++++++++++++##+++++++###################
//   ###    #####++++++-++++++++++++++++++++++++++++++++++++++++##########  #######
//  ###      ###+++++++++---+++++++++++++++-+++-++++++++++++++++######### #########
//          ###++++++++------++++++++++++###++-++++++++--+++++++#############
//        #####+++++++----------+++++++++++++++##++++-------+++##########
//    #########++++++----------+++++++++++++++++++++++------+++#########
// #############+++++----------+++++++++++++++++++++++++---+++###########
// #############++-++----------+++++++++++++++++++++++-+---++###    ## ###
// ### ###       ++++----------+++++++-++-++++++-+++++-----++###        ###
//                 ++----------+++#+++---------+++--++-+---++#####       ####
//                #+----------+++++++++++++--+--+++-------+-++#####       ####
//              ####+---------++++++++++++++++++#+++-----++-++#######      ####
//            ######+----------------++++++++++++++-----++--+    #####       ###
//          ##### #+++------+++-------+++++++--+++-----++-###       ###      #####
//         ###    ++--+-----+++++++++++++---------+---++-##++###    +##
//        ##+   ###+--------+++++++++++++++++--+++---++++      ++#######
//     ####+    ###+-----------+++++++++++++++++++++++++            #  #
//           ++##++++---------------+++++++++++++++++
//          ++## +++++------------+++++++++++++++++++
//              +++++++-----------+++++++++++++++++++
//          ++###++++++---------------++++++++++++++
//       +++#####+++++++++--------------++++++++++++
// #+ +++#######+++++++++++---------------+++++++++#+
// ###########++++++++++++++-------------++++++++++###
//
/// @author DELV
/// @title EverlongStrategy
/// @notice A money market powered by Hyperdrive.
/// @custom:disclaimer The language used in this code is for coding convenience
///                    only, and is not intended to, and does not, have any
///                    particular legal or regulatory significance.
contract EverlongStrategy is BaseHealthCheck {
    using FixedPointMath for uint256;
    using HyperdriveExecutionLibrary for IHyperdrive;
    using Portfolio for Portfolio.State;
    using SafeCast for *;
    using SafeERC20 for ERC20;
    using HyperdriveUtils for *;

    // ╭───────────────────────────────────────────────────────────────────────╮
    // │                               CONSTANTS                               │
    // ╰───────────────────────────────────────────────────────────────────────╯

    /// @notice Amount of additional bonds to close during a partial position
    ///         closure to avoid rounding errors. Represented as a percentage
    ///         of the positions total  amount of bonds where 1e18 represents
    ///         a 10% buffer.
    uint256 public constant partialPositionClosureBuffer = 0.001e18;

    /// @notice The Everlong instance's kind.
    string public constant kind = EVERLONG_KIND;

    /// @notice The Everlong instance's version.
    string public constant version = EVERLONG_VERSION;

    // ╭───────────────────────────────────────────────────────────────────────╮
    // │                              IMMUTABLES                               │
    // ╰───────────────────────────────────────────────────────────────────────╯

    /// @notice Address of the Hyperdrive instance wrapped by Everlong.
    address public immutable hyperdrive;

    /// @notice Whether to use Hyperdrive's base token to purchase bonds.
    ///      If false, use the Hyperdrive's `vaultSharesToken`.
    bool public immutable asBase;

    /// @dev Structure to store and account for everlong-controlled positions.
    Portfolio.State internal _portfolio;

    // ╭───────────────────────────────────────────────────────────────────────╮
    // │                              CONSTRUCTOR                              │
    // ╰───────────────────────────────────────────────────────────────────────╯

    constructor(
        address _asset,
        string memory __name,
        address _hyperdrive,
        bool _asBase
    ) BaseStrategy(_asset, __name) {
        hyperdrive = _hyperdrive;
        asBase = _asBase;
    }

    // ╭───────────────────────────────────────────────────────────────────────╮
    // │                          STRATEGY OVERRIDES                           │
    // ╰───────────────────────────────────────────────────────────────────────╯

    /// @inheritdoc BaseStrategy
    function _deployFunds(uint256) internal override {
        // Do nothing.
        // Opening longs on Hyperdrive is sandwichable so funds should only be
        // deployed when the `keeper` calls `tend()`.
        return;
    }

    /// @inheritdoc BaseStrategy
    function _freeFunds(uint256 _amount) internal override {
        // Close all matured positions (if any).
        uint256 output = _closeMaturedPositions(0);

        // Close immature positions if additional funds need to be freed.
        if (_amount > output) {
            _closePositions(_amount - output);
        }
    }

    /// @inheritdoc BaseStrategy
    function _harvestAndReport()
        internal
        override
        returns (uint256 _totalAssets)
    {
        // Close matured positions and redeploy any idle liquidity.
        // _tend(asset.balanceOf(address(this)));

        // Recalculate the value of assets the strategy controls.
        _totalAssets = calculateTotalAssets();
    }

    /// @inheritdoc BaseStrategy
    function availableDepositLimit(
        address
    ) public view override returns (uint256) {
        // Limit deposits to the maximum long that can be opened in hyperdrive.
        return IHyperdrive(hyperdrive).calculateMaxLong();
    }

    /// @inheritdoc BaseStrategy
    function _tendTrigger() internal view override returns (bool) {
        return canRebalance();
    }

    /// @inheritdoc BaseStrategy
    function _tend(uint256 _totalIdle) internal override {
        // Early return if no rebalancing is needed.
        if (!canRebalance()) {
            return;
        }

        // Close matured positions.
        _totalIdle += _closeMaturedPositions(0);

        // If Everlong has sufficient idle, open a new position.
        if (
            _totalIdle >=
            IHyperdrive(hyperdrive).getPoolConfig().minimumTransactionAmount
        ) {
            // Approve leaving an extra wei so the slot stays warm.
            ERC20(asset).forceApprove(address(hyperdrive), _totalIdle + 1);
            (uint256 maturityTime, uint256 bondAmount) = IHyperdrive(hyperdrive)
                .openLong(asBase, _totalIdle, 0, 0, "");

            // Account for the new position in the portfolio.
            _portfolio.handleOpenPosition(maturityTime, bondAmount);
        }
    }

    // ╭───────────────────────────────────────────────────────────────────────╮
    // │                           POSITION CLOSURE                            │
    // ╰───────────────────────────────────────────────────────────────────────╯

    /// @dev Close only matured positions in the portfolio.
    /// @param _limit The maximum number of positions to close.
    ///               A value of zero indicates no limit.
    /// @return output Proceeds of closing the matured positions.
    function _closeMaturedPositions(
        uint256 _limit
    ) internal returns (uint256 output) {
        // A value of zero for `_limit` indicates no limit.
        if (_limit == 0) {
            _limit = type(uint256).max;
        }

        // Iterate through positions from most to least mature.
        // Exit if:
        // - There are no more positions.
        // - The current position is not mature.
        // - The limit on closed positions has been reached.
        IEverlongStrategy.Position memory position;
        for (uint256 count; !_portfolio.isEmpty() && count < _limit; ++count) {
            // Retrieve the most mature position.
            position = _portfolio.head();

            // If the position is not mature, return the output received thus
            // far.
            if (!IHyperdrive(hyperdrive).isMature(position)) {
                return output;
            }

            // Close the position add the amount of assets received to the
            // cumulative output.
            output += IHyperdrive(hyperdrive).closeLong(
                asBase,
                position,
                0,
                ""
            );

            // Update portfolio accounting to reflect the closed position.
            _portfolio.handleClosePosition();
        }
    }

    /// @dev Close positions until the targeted amount of output is received.
    /// @param _targetOutput Target amount of proceeds to receive.
    /// @return output Total output received from closed positions.
    function _closePositions(
        uint256 _targetOutput
    ) internal returns (uint256 output) {
        // Round `_targetOutput` up to Hyperdrive's minimum transaction amount.
        _targetOutput = _targetOutput.max(
            IHyperdrive(hyperdrive).getPoolConfig().minimumTransactionAmount
        );

        // Since multiple position's worth of bonds may need to be closed,
        // iterate through each position starting with the most mature.
        //
        // For each position, use the expected output of closing the entire
        // position to estimate the amount of bonds to sell for a partial closure.
        IEverlongStrategy.Position memory position;
        uint256 totalPositionValue;
        while (!_portfolio.isEmpty() && output < _targetOutput) {
            // Retrieve the most mature position.
            position = _portfolio.head();

            // Calculate the value of the entire position, and use it to derive
            // the expected output for partial closures.
            totalPositionValue = IHyperdrive(hyperdrive).previewCloseLong(
                asBase,
                position,
                ""
            );

            // Close only part of the position if there are sufficient bonds
            // to reach the target output without leaving a small amount left.
            // For this case, the remaining bonds must be worth at least
            // Hyperdrive's minimum transaction amount.
            if (
                totalPositionValue >
                (_targetOutput -
                    output +
                    IHyperdrive(hyperdrive)
                        .getPoolConfig()
                        .minimumTransactionAmount).mulUp(
                        ONE + partialPositionClosureBuffer
                    )
            ) {
                // Calculate the amount of bonds to close from the position.
                uint256 bondsNeeded = uint256(position.bondAmount).mulDivUp(
                    (_targetOutput - output).mulUp(
                        ONE + partialPositionClosureBuffer
                    ),
                    totalPositionValue
                );

                // Close part of the position and enforce the slippage guard.
                // Add the amount of assets received to the total output.
                output += IHyperdrive(hyperdrive).closeLong(
                    asBase,
                    IEverlongStrategy.Position({
                        maturityTime: position.maturityTime,
                        bondAmount: bondsNeeded.toUint128()
                    }),
                    0,
                    ""
                );

                // Update portfolio accounting to include the partial closure.
                _portfolio.handleClosePosition(bondsNeeded);

                // No more closures are needed.
                return output;
            }
            // Close the entire position.
            else {
                // Close the entire position and increase the cumulative output.
                output += IHyperdrive(hyperdrive).closeLong(
                    asBase,
                    position,
                    0,
                    ""
                );

                // Update portfolio accounting to include the partial closure.
                _portfolio.handleClosePosition();
            }
        }

        // The target has been reached or no more positions remain.
        return output;
    }

    // ╭───────────────────────────────────────────────────────────────────────╮
    // │                            VIEW FUNCTIONS                             │
    // ╰───────────────────────────────────────────────────────────────────────╯

    /// @notice Calculates the present portfolio value using the total amount of
    ///      bonds and the weighted average maturity of all positions.
    /// @return value The present portfolio value.
    function calculateTotalAssets() public view returns (uint256 value) {
        value = ERC20(asset).balanceOf(address(this));
        if (_portfolio.totalBonds != 0) {
            // NOTE: The maturity time is rounded to the next checkpoint to
            //       underestimate the portfolio value.
            value += IHyperdrive(hyperdrive).previewCloseLong(
                asBase,
                IEverlongStrategy.Position({
                    maturityTime: IHyperdrive(hyperdrive)
                        .getCheckpointIdUp(_portfolio.avgMaturityTime)
                        .toUint128(),
                    bondAmount: _portfolio.totalBonds
                }),
                ""
            );
        }
    }

    // TODO: Use cached poolconfig.
    //
    /// @notice Returns true if the portfolio can be rebalanced.
    /// @notice The portfolio can be rebalanced if:
    ///         - Any positions are matured.
    ///         - The current idle liquidity is above the target.
    /// @return True if the portfolio can be rebalanced, false otherwise.
    function canRebalance() public view returns (bool) {
        return hasMaturedPositions() || canOpenPosition();
    }

    /// @notice Returns whether Everlong has sufficient idle liquidity to open
    ///         a new position.
    /// @return True if a new position can be opened, false otherwise.
    function canOpenPosition() public view returns (bool) {
        return
            asset.balanceOf(address(this)) >
            IHyperdrive(hyperdrive).getPoolConfig().minimumTransactionAmount;
    }

    /// @notice Returns whether the portfolio has matured positions.
    /// @return True if the portfolio has matured positions, false otherwise.
    function hasMaturedPositions() public view returns (bool) {
        return
            !_portfolio.isEmpty() &&
            IHyperdrive(hyperdrive).isMature(_portfolio.head());
    }

    /// @notice Retrieve the position at the specified location in the queue.
    /// @param _index Index in the queue to retrieve the position.
    /// @return The position at the specified location.
    function positionAt(
        uint256 _index
    ) external view returns (IEverlongStrategy.Position memory) {
        return _portfolio.at(_index);
    }

    /// @notice Returns how many positions are currently in the queue.
    /// @return The queue's position count.
    function positionCount() external view returns (uint256) {
        return _portfolio.positionCount();
    }

    /// @notice Total quantity of bonds held in the portfolio.
    /// @return Total quantity of bonds held in the portfolio.
    function totalBonds() external view returns (uint256) {
        return _portfolio.totalBonds;
    }
}