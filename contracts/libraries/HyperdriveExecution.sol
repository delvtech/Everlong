// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import { IERC4626 } from "hyperdrive/contracts/src/interfaces/IERC4626.sol";
import { IHyperdrive } from "hyperdrive/contracts/src/interfaces/IHyperdrive.sol";
import { ILido } from "hyperdrive/contracts/src/interfaces/ILido.sol";
import { FixedPointMath } from "hyperdrive/contracts/src/libraries/FixedPointMath.sol";
import { HyperdriveMath } from "hyperdrive/contracts/src/libraries/HyperdriveMath.sol";
import { SafeCast } from "hyperdrive/contracts/src/libraries/SafeCast.sol";
import { YieldSpaceMath } from "hyperdrive/contracts/src/libraries/YieldSpaceMath.sol";
import { ERC20 } from "openzeppelin/token/ERC20/ERC20.sol";
import { SafeERC20 } from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import { Packing } from "openzeppelin/utils/Packing.sol";
import { IEverlongEvents } from "../interfaces/IEverlongEvents.sol";
import { IEverlongStrategy } from "../interfaces/IEverlongStrategy.sol";
import { ONE, LEGACY_SDAI_HYPERDRIVE, LEGACY_STETH_HYPERDRIVE } from "./Constants.sol";

// TODO: Extract into its own library.
uint256 constant HYPERDRIVE_SHARE_RESERVES_BOND_RESERVES_SLOT = 2;
uint256 constant HYPERDRIVE_LONG_EXPOSURE_LONGS_OUTSTANDING_SLOT = 3;
uint256 constant HYPERDRIVE_SHARE_ADJUSTMENT_SHORTS_OUTSTANDING_SLOT = 4;

/// @author DELV
/// @title HyperdriveExecutionLibrary
/// @notice Library to handle the execution of trades with hyperdrive.
/// @custom:disclaimer The language used in this code is for coding convenience
///                    only, and is not intended to, and does not, have any
///                    particular legal or regulatory significance.
library HyperdriveExecutionLibrary {
    using FixedPointMath for uint256;
    using FixedPointMath for int256;
    using SafeCast for *;
    using SafeERC20 for ERC20;
    using Packing for bytes32;

    // ╭───────────────────────────────────────────────────────────────────────╮
    // │                               Open Long                               │
    // ╰───────────────────────────────────────────────────────────────────────╯

    /// @dev Opens a long with hyperdrive using amount.
    /// @param _asBase Whether to use hyperdrive's base asset.
    /// @param _amount Amount of assets to spend.
    /// @param _extraData Extra data to pass to hyperdrive.
    /// @return maturityTime Maturity timestamp of the opened position.
    /// @return bondAmount Amount of bonds received.
    function openLong(
        IHyperdrive self,
        bool _asBase,
        uint256 _amount,
        bytes memory _extraData
    ) internal returns (uint256 maturityTime, uint256 bondAmount) {
        (maturityTime, bondAmount) = self.openLong(
            _amount,
            0,
            0,
            IHyperdrive.Options({
                destination: address(this),
                asBase: _asBase,
                extraData: _extraData
            })
        );
        emit IEverlongEvents.PositionOpened(
            maturityTime.toUint128(),
            bondAmount.toUint128()
        );
    }

    /// @dev Opens a long with hyperdrive using amount.
    /// @param _asBase Whether to use hyperdrive's base asset.
    /// @param _amount Amount of assets to spend.
    /// @param _minOutput Minimum amount of bonds to receive.
    /// @param _minVaultSharePrice Minimum hyperdrive vault share price.
    /// @param _extraData Extra data to pass to hyperdrive.
    /// @return maturityTime Maturity timestamp of the opened position.
    /// @return bondAmount Amount of bonds received.
    function openLong(
        IHyperdrive self,
        bool _asBase,
        uint256 _amount,
        uint256 _minOutput,
        uint256 _minVaultSharePrice,
        bytes memory _extraData
    ) internal returns (uint256 maturityTime, uint256 bondAmount) {
        (maturityTime, bondAmount) = self.openLong(
            _amount,
            _minOutput,
            _minVaultSharePrice,
            IHyperdrive.Options({
                destination: address(this),
                asBase: _asBase,
                extraData: _extraData
            })
        );
        emit IEverlongEvents.PositionOpened(
            maturityTime.toUint128(),
            bondAmount.toUint128()
        );
    }

    /// @dev Calculates the result of opening a long with hyperdrive.
    /// @param _asBase Whether to use hyperdrive's base asset.
    /// @param _poolConfig The hyperdrive's PoolConfig.
    /// @param _amount Amount of assets to spend.
    /// @return Amount of bonds received.
    function previewOpenLong(
        IHyperdrive self,
        bool _asBase,
        IHyperdrive.PoolConfig memory _poolConfig,
        uint256 _amount,
        bytes memory // unused extra data
    ) internal view returns (uint256) {
        return
            _calculateOpenLong(
                self,
                _poolConfig,
                _asBase ? _convertToShares(self, _amount) : _amount
            );
    }

    /// @dev Calculates the amount of output bonds received from opening a
    ///      long. The process is as follows:
    ///        1. Calculates the raw amount using yield space.
    ///        2. Subtracts fees.
    /// @param _poolConfig The hyperdrive's PoolConfig.
    /// @param _shareAmount Amount of shares being exchanged for bonds.
    /// @return Amount of bonds received.
    function _calculateOpenLong(
        IHyperdrive self,
        IHyperdrive.PoolConfig memory _poolConfig,
        uint256 _shareAmount
    ) internal view returns (uint256) {
        // Prepare the necessary information to perform the yield space
        // calculation. We save gas by reading storage directly instead of
        // retrieving entire PoolInfo struct.
        uint256[] memory slots = new uint256[](2);
        slots[0] = HYPERDRIVE_SHARE_RESERVES_BOND_RESERVES_SLOT;
        slots[1] = HYPERDRIVE_SHARE_ADJUSTMENT_SHORTS_OUTSTANDING_SLOT;
        bytes32[] memory values = self.load(slots);
        uint256 effectiveShareReserves = HyperdriveMath
            .calculateEffectiveShareReserves(
                uint128(values[0].extract_32_16(16)), // shareReserves
                uint256(uint128(values[1].extract_32_16(16))).toInt256() // shareAdjustment
            );
        uint256 bondReserves = uint128(values[0].extract_32_16(0));
        uint256 _vaultSharePrice = vaultSharePrice(self);

        // Calculate the change in hyperdrive's bond reserves given a purchase
        // of _shareAmount. This amount is equivalent to the amount of bonds
        // the purchaser will receive (not accounting for fees).
        uint256 bondReservesDelta = YieldSpaceMath
            .calculateBondsOutGivenSharesInDown(
                effectiveShareReserves,
                bondReserves,
                _shareAmount,
                // NOTE: Since the bonds traded on the curve are newly minted,
                // we use a time remaining of 1. This means that we can use
                // `_timeStretch = t * _timeStretch`.
                ONE - _poolConfig.timeStretch,
                _vaultSharePrice,
                _poolConfig.initialVaultSharePrice
            );

        // Apply fees to the output bond amount and return it.
        uint256 spotPrice = HyperdriveMath.calculateSpotPrice(
            effectiveShareReserves,
            bondReserves,
            _poolConfig.initialVaultSharePrice,
            _poolConfig.timeStretch
        );
        bondReservesDelta = _calculateOpenLongFees(
            _shareAmount,
            bondReservesDelta,
            _vaultSharePrice,
            spotPrice,
            _poolConfig.fees.curve
        );
        return bondReservesDelta;
    }

    /// @dev Calculate the fees involved with opening the long and apply them.
    /// @param _shareReservesDelta The change in the share reserves without fees.
    /// @param _bondReservesDelta The change in the bond reserves without fees.
    /// @param _vaultSharePrice The current vault share price.
    /// @param _spotPrice The current spot price.
    /// @return The change in the bond reserves with fees.
    function _calculateOpenLongFees(
        uint256 _shareReservesDelta,
        uint256 _bondReservesDelta,
        uint256 _vaultSharePrice,
        uint256 _spotPrice,
        uint256 _curveFee
    ) internal pure returns (uint256) {
        // Calculate the fees charged to the user (curveFee).
        uint256 curveFee = _calculateFeesGivenShares(
            _shareReservesDelta,
            _spotPrice,
            _vaultSharePrice,
            _curveFee
        );

        // Calculate the impact of the curve fee on the bond reserves. The curve
        // fee benefits the LPs by causing less bonds to be deducted from the
        // bond reserves.
        _bondReservesDelta -= curveFee;

        return (_bondReservesDelta);
    }

    /// @dev Calculates the fees that go to the LPs and governance.
    /// @dev See `lib/hyperdrive/contracts/src/internal/HyperdriveBase.sol`
    ///      for more information.
    /// @param _shareAmount The amount of shares exchanged for bonds.
    /// @param _spotPrice The price without slippage of bonds in terms of base
    ///         (base/bonds).
    /// @param _vaultSharePrice The current vault share price (base/shares).
    /// @return curveFee The curve fee. The fee is in terms of bonds.
    function _calculateFeesGivenShares(
        uint256 _shareAmount,
        uint256 _spotPrice,
        uint256 _vaultSharePrice,
        uint256 _curveFee
    ) internal pure returns (uint256 curveFee) {
        // NOTE: Round up to overestimate the curve fee.
        //
        // Fixed Rate (r) = (value at maturity - purchase price)/(purchase price)
        //                = (1-p)/p
        //                = ((1 / p) - 1)
        //                = the ROI at maturity of a bond purchased at price p
        //
        // Another way to think about it:
        //
        // p (spot price) tells us how many base a bond is worth -> p = base/bonds
        // 1/p tells us how many bonds a base is worth -> 1/p = bonds/base
        // 1/p - 1 tells us how many additional bonds we get for each
        // base -> (1/p - 1) = additional bonds/base
        //
        // The curve fee is taken from the additional bonds the user gets for
        // each base:
        //
        // curve fee = ((1 / p) - 1) * phi_curve * c * dz
        //           = r * phi_curve * base/shares * shares
        //           = bonds/base * phi_curve * base
        //           = bonds * phi_curve
        curveFee = (uint256(ONE).divUp(_spotPrice) - ONE)
            .mulUp(_curveFee)
            .mulUp(_vaultSharePrice)
            .mulUp(_shareAmount);
    }

    // ╭───────────────────────────────────────────────────────────────────────╮
    // │                              Close Long                               │
    // ╰───────────────────────────────────────────────────────────────────────╯

    /// @dev Close a long with the input position's bond amount and maturity.
    /// @param _asBase Whether to receive hyperdrive's base token as output.
    /// @param _position Position information used to specify the long to close.
    /// @param _minOutput Minimum amount of assets to receive as output.
    /// @param _data Extra data to pass to hyperdrive.
    /// @return proceeds The amount of output assets received from closing the long.
    function closeLong(
        IHyperdrive self,
        bool _asBase,
        IEverlongStrategy.EverlongPosition memory _position,
        uint256 _minOutput,
        bytes memory _data
    ) internal returns (uint256 proceeds) {
        proceeds = self.closeLong(
            _position.maturityTime,
            _position.bondAmount,
            _minOutput,
            IHyperdrive.Options(address(this), _asBase, _data)
        );
        emit IEverlongEvents.PositionClosed(
            _position.maturityTime,
            _position.bondAmount
        );
    }

    /// @dev Calculate the amount of output assets received from closing a
    ///         long.
    /// @dev Always less than or equal to the actual amount of assets received.
    /// @param _asBase Whether to receive hyperdrive's base token as output.
    /// @param _poolConfig Hyperdrive PoolConfig.
    /// @param _position Position information used to specify the long to close.
    /// @return The amount of output assets received from closing the long.
    function previewCloseLong(
        IHyperdrive self,
        bool _asBase,
        IHyperdrive.PoolConfig memory _poolConfig,
        IEverlongStrategy.EverlongPosition memory _position,
        bytes memory // unused extradata
    ) internal view returns (uint256) {
        // Read select `PoolInfo` fields directly from Hyperdrive's storage to
        // save on gas costs.
        uint256[] memory slots = new uint256[](2);
        slots[0] = HYPERDRIVE_SHARE_RESERVES_BOND_RESERVES_SLOT;
        slots[1] = HYPERDRIVE_SHARE_ADJUSTMENT_SHORTS_OUTSTANDING_SLOT;
        bytes32[] memory values = self.load(slots);
        uint256 shareProceeds = _calculateCloseLong(
            self,
            CalculateCloseLongParams({
                timeStretch: _poolConfig.timeStretch,
                initialVaultSharePrice: _poolConfig.initialVaultSharePrice,
                positionDuration: _poolConfig.positionDuration,
                curveFee: _poolConfig.fees.curve,
                flatFee: _poolConfig.fees.flat,
                shareReserves: uint128(values[0].extract_32_16(16)),
                bondReserves: uint128(values[0].extract_32_16(0)),
                shareAdjustment: uint256(uint128(values[1].extract_32_16(16)))
                    .toInt256()
            }),
            _position
        );
        if (_asBase) {
            return _convertToBase(self, shareProceeds);
        }
        return shareProceeds;
    }

    struct CalculateCloseLongParams {
        uint256 timeStretch;
        uint256 initialVaultSharePrice;
        uint256 positionDuration;
        uint256 curveFee;
        uint256 flatFee;
        uint128 shareReserves;
        uint128 bondReserves;
        int256 shareAdjustment;
    }

    struct CalculateCloseLongData {
        uint256 effectiveShareReserves;
        uint256 normalizedTimeRemaining;
        uint256 openVaultSharePrice;
        uint256 closeVaultSharePrice;
        uint256 shareProceeds;
        uint256 spotPrice;
        uint256 curveFee;
        uint256 flatFee;
    }

    /// @dev Calculates the amount of output assets received from closing a
    ///      long. The process is as follows:
    ///        1. Calculates the raw amount using yield space.
    ///        2. Subtracts fees.
    ///        3. Accounts for negative interest.
    ///        4. Converts to shares and back to account for any rounding issues.
    /// @param _params Hyperdrive data needed for the calculation.
    /// @param _position Position containing information on the long to close.
    /// @return The amount of output assets received from closing the long.
    function _calculateCloseLong(
        IHyperdrive self,
        CalculateCloseLongParams memory _params,
        IEverlongStrategy.EverlongPosition memory _position
    ) internal view returns (uint256) {
        // Use a struct to hold intermediate calculation results and avoid
        // stack-too-deep errors.
        CalculateCloseLongData memory data;

        // Prepare the necessary information to perform the yield space
        // calculation.
        data.effectiveShareReserves = HyperdriveMath
            .calculateEffectiveShareReserves(
                _params.shareReserves, // shareReserves
                _params.shareAdjustment // shareAdjustment
            );
        data.normalizedTimeRemaining = normalizedTimeRemaining(
            self,
            _position.maturityTime
        );

        // Hyperdrive uses the vaultSharePrice at the beginning of the
        // checkpoint as the open price, and the current vaultSharePrice as
        // the close price.
        data.closeVaultSharePrice = vaultSharePrice(self);
        data.openVaultSharePrice = getCheckpointDown(
            self,
            _position.maturityTime - _params.positionDuration
        ).vaultSharePrice;

        // Calculate the raw proceeds of the close without fees.
        (, , data.shareProceeds) = HyperdriveMath.calculateCloseLong(
            data.effectiveShareReserves,
            _params.bondReserves, // bondReserves
            _position.bondAmount,
            data.normalizedTimeRemaining,
            _params.timeStretch,
            data.closeVaultSharePrice,
            _params.initialVaultSharePrice
        );

        // Calculate the fees that should be paid by the trader. The trader
        // pays a fee on the curve and flat parts of the trade. Most of the
        // fees go the LPs, but a portion goes to governance.
        data.spotPrice = HyperdriveMath.calculateSpotPrice(
            data.effectiveShareReserves,
            _params.bondReserves,
            _params.initialVaultSharePrice,
            _params.timeStretch
        );
        (
            data.curveFee, // shares
            data.flatFee // shares
        ) = _calculateFeesGivenBonds(
            _position.bondAmount,
            data.normalizedTimeRemaining,
            data.spotPrice,
            data.closeVaultSharePrice,
            _params.curveFee,
            _params.flatFee
        );

        // Subtract fees from the proceeds.
        data.shareProceeds -= data.curveFee + data.flatFee;

        // Adjust the proceeds to account for negative interest.
        if (data.closeVaultSharePrice < data.openVaultSharePrice) {
            data.shareProceeds = data.shareProceeds.mulDivDown(
                data.closeVaultSharePrice,
                data.openVaultSharePrice
            );
        }

        // Correct for any error that crept into the calculation of the share
        // amount by converting the shares to base and then back to shares
        // using the vault's share conversion logic.
        data.shareProceeds = _convertToShares(
            self,
            data.shareProceeds.mulDown(data.closeVaultSharePrice)
        );

        return data.shareProceeds;
    }

    /// @dev Calculates the fees that go to the LPs and governance.
    /// @param _bondAmount The amount of bonds being exchanged for shares.
    /// @param _normalizedTimeRemaining The normalized amount of time until
    ///        maturity.
    /// @param _spotPrice The price without slippage of bonds in terms of base
    ///        (base/bonds).
    /// @param _vaultSharePrice The current vault share price (base/shares).
    /// @return curveFee The curve fee. The fee is in terms of shares.
    /// @return flatFee The flat fee. The fee is in terms of shares.
    function _calculateFeesGivenBonds(
        uint256 _bondAmount,
        uint256 _normalizedTimeRemaining,
        uint256 _spotPrice,
        uint256 _vaultSharePrice,
        uint256 _curveFee,
        uint256 _flatFee
    ) internal pure returns (uint256 curveFee, uint256 flatFee) {
        // NOTE: Round up to overestimate the curve fee.
        //
        // p (spot price) tells us how many base a bond is worth -> p = base/bonds
        // 1 - p tells us how many additional base a bond is worth at
        // maturity -> (1 - p) = additional base/bonds
        //
        // The curve fee is taken from the additional base the user gets for
        // each bond at maturity:
        //
        // curve fee = ((1 - p) * phi_curve * d_y * t)/c
        //           = (base/bonds * phi_curve * bonds * t) / (base/shares)
        //           = (base/bonds * phi_curve * bonds * t) * (shares/base)
        //           = (base * phi_curve * t) * (shares/base)
        //           = phi_curve * t * shares
        curveFee = _curveFee
            .mulUp(ONE - _spotPrice)
            .mulUp(_bondAmount)
            .mulDivUp(_normalizedTimeRemaining, _vaultSharePrice);

        // NOTE: Round up to overestimate the flat fee.
        //
        // The flat portion of the fee is taken from the matured bonds.
        // Since a matured bond is worth 1 base, it is appropriate to consider
        // d_y in units of base:
        //
        // flat fee = (d_y * (1 - t) * phi_flat) / c
        //          = (base * (1 - t) * phi_flat) / (base/shares)
        //          = (base * (1 - t) * phi_flat) * (shares/base)
        //          = shares * (1 - t) * phi_flat
        uint256 flat = _bondAmount.mulDivUp(
            ONE - _normalizedTimeRemaining,
            _vaultSharePrice
        );
        flatFee = flat.mulUp(_flatFee);
    }

    // ╭───────────────────────────────────────────────────────────────────────╮
    // │                               Max Long                                │
    // ╰───────────────────────────────────────────────────────────────────────╯

    // HACK: Copied from `delvtech/hyperdrive` repo.
    //
    /// @dev Calculates the maximum amount of longs that can be opened.
    /// @param _asBase Whether to transact using hyperdrive's base or vault
    ///                shares token.
    /// @param _maxIterations The maximum number of iterations to use.
    /// @return amount The cost of buying the maximum amount of longs.
    function calculateMaxLong(
        IHyperdrive self,
        bool _asBase,
        uint256 _maxIterations
    ) internal view returns (uint256 amount) {
        IHyperdrive.PoolConfig memory poolConfig = self.getPoolConfig();
        IHyperdrive.PoolInfo memory poolInfo = self.getPoolInfo();
        (amount, ) = calculateMaxLong(
            MaxTradeParams({
                shareReserves: poolInfo.shareReserves,
                shareAdjustment: poolInfo.shareAdjustment,
                bondReserves: poolInfo.bondReserves,
                longsOutstanding: poolInfo.longsOutstanding,
                longExposure: poolInfo.longExposure,
                timeStretch: poolConfig.timeStretch,
                vaultSharePrice: poolInfo.vaultSharePrice,
                initialVaultSharePrice: poolConfig.initialVaultSharePrice,
                minimumShareReserves: poolConfig.minimumShareReserves,
                curveFee: poolConfig.fees.curve,
                flatFee: poolConfig.fees.flat,
                governanceLPFee: poolConfig.fees.governanceLP
            }),
            self.getCheckpointExposure(latestCheckpoint(self)),
            _maxIterations
        );

        // The above `amount` is denominated in hyperdrive's base token.
        // If `_asBase == false` then hyperdrive's vault shares token is being
        // used and we must convert the value.
        if (!_asBase) {
            amount = _convertToShares(self, amount);
        }

        return amount;
    }

    // HACK: Copied from `delvtech/hyperdrive` repo.
    //
    /// @dev Calculates the maximum amount of longs that can be opened.
    /// @param _asBase Whether to transact using hyperdrive's base or vault
    ///                shares token.
    /// @return baseAmount The cost of buying the maximum amount of longs.
    function calculateMaxLong(
        IHyperdrive self,
        bool _asBase
    ) internal view returns (uint256 baseAmount) {
        return calculateMaxLong(self, _asBase, 7);
    }

    // HACK: Copied from `delvtech/hyperdrive` repo.
    //
    /// @dev Parameters needed for `calculateMaxLong`.
    ///      Used internally, should typically not be used by external callers
    ///      of the library.
    struct MaxTradeParams {
        uint256 shareReserves;
        int256 shareAdjustment;
        uint256 bondReserves;
        uint256 longsOutstanding;
        uint256 longExposure;
        uint256 timeStretch;
        uint256 vaultSharePrice;
        uint256 initialVaultSharePrice;
        uint256 minimumShareReserves;
        uint256 curveFee;
        uint256 flatFee;
        uint256 governanceLPFee;
    }

    // HACK: Copied from `delvtech/hyperdrive` repo.
    //
    /// @dev Gets the max long that can be opened given a budget.
    ///
    ///      We start by calculating the long that brings the pool's spot price
    ///      to 1. If we are solvent at this point, then we're done. Otherwise,
    ///      we approach the max long iteratively using Newton's method.
    /// @param _params The parameters for the max long calculation.
    /// @param _checkpointExposure The exposure in the checkpoint.
    /// @param _maxIterations The maximum number of iterations to use in the
    ///                       Newton's method loop.
    /// @return maxBaseAmount The maximum base amount.
    /// @return maxBondAmount The maximum bond amount.
    function calculateMaxLong(
        MaxTradeParams memory _params,
        int256 _checkpointExposure,
        uint256 _maxIterations
    ) internal pure returns (uint256 maxBaseAmount, uint256 maxBondAmount) {
        // Get the maximum long that brings the spot price to 1. If the pool is
        // solvent after opening this long, then we're done.
        uint256 effectiveShareReserves = HyperdriveMath
            .calculateEffectiveShareReserves(
                _params.shareReserves,
                _params.shareAdjustment
            );
        uint256 spotPrice = HyperdriveMath.calculateSpotPrice(
            effectiveShareReserves,
            _params.bondReserves,
            _params.initialVaultSharePrice,
            _params.timeStretch
        );
        uint256 absoluteMaxBaseAmount;
        uint256 absoluteMaxBondAmount;
        {
            (
                absoluteMaxBaseAmount,
                absoluteMaxBondAmount
            ) = calculateAbsoluteMaxLong(
                _params,
                effectiveShareReserves,
                spotPrice
            );
            (, bool isSolvent_) = calculateSolvencyAfterLong(
                _params,
                _checkpointExposure,
                absoluteMaxBaseAmount,
                absoluteMaxBondAmount,
                spotPrice
            );
            if (isSolvent_) {
                return (absoluteMaxBaseAmount, absoluteMaxBondAmount);
            }
        }

        // Use Newton's method to iteratively approach a solution. We use pool's
        // solvency $S(x)$ as our objective function, which will converge to the
        // amount of base that needs to be paid to open the maximum long. The
        // derivative of $S(x)$ is negative (since solvency decreases as more
        // longs are opened). The fixed point library doesn't support negative
        // numbers, so we use the negation of the derivative to side-step the
        // issue.
        //
        // Given the current guess of $x_n$, Newton's method gives us an updated
        // guess of $x_{n+1}$:
        //
        // $$
        // x_{n+1} = x_n - \tfrac{S(x_n)}{S'(x_n)} = x_n + \tfrac{S(x_n)}{-S'(x_n)}
        // $$
        //
        // The guess that we make is very important in determining how quickly
        // we converge to the solution.
        maxBaseAmount = calculateMaxLongGuess(
            _params,
            absoluteMaxBaseAmount,
            _checkpointExposure,
            spotPrice
        );
        maxBondAmount = calculateLongAmount(
            _params,
            maxBaseAmount,
            effectiveShareReserves,
            spotPrice
        );
        (uint256 solvency_, bool success) = calculateSolvencyAfterLong(
            _params,
            _checkpointExposure,
            maxBaseAmount,
            maxBondAmount,
            spotPrice
        );
        require(success, "Initial guess in `calculateMaxLong` is insolvent.");
        for (uint256 i = 0; i < _maxIterations; ++i) {
            // If the max base amount is equal to or exceeds the absolute max,
            // we've gone too far and the calculation deviated from reality at
            // some point.
            require(
                maxBaseAmount < absoluteMaxBaseAmount,
                "Reached absolute max bond amount in `get_max_long`."
            );

            // TODO: It may be better to gracefully handle crossing over the
            // root by extending the fixed point math library to handle negative
            // numbers or even just using an if-statement to handle the negative
            // numbers.
            //
            // Proceed to the next step of Newton's method. Once we have a
            // candidate solution, we check to see if the pool is solvent if
            // a long is opened with the candidate amount. If the pool isn't
            // solvent, then we're done.
            uint256 derivative;
            (derivative, success) = calculateSolvencyAfterLongDerivative(
                _params,
                maxBaseAmount,
                effectiveShareReserves,
                spotPrice
            );
            if (!success) {
                break;
            }
            uint256 possibleMaxBaseAmount = maxBaseAmount +
                solvency_.divDown(derivative);
            uint256 possibleMaxBondAmount = calculateLongAmount(
                _params,
                possibleMaxBaseAmount,
                effectiveShareReserves,
                spotPrice
            );
            (solvency_, success) = calculateSolvencyAfterLong(
                _params,
                _checkpointExposure,
                possibleMaxBaseAmount,
                possibleMaxBondAmount,
                spotPrice
            );
            if (success) {
                maxBaseAmount = possibleMaxBaseAmount;
                maxBondAmount = possibleMaxBondAmount;
            } else {
                break;
            }
        }

        return (maxBaseAmount, maxBondAmount);
    }

    // HACK: Copied from `delvtech/hyperdrive` repo.
    //
    /// @dev Calculates the largest long that can be opened without buying bonds
    ///      at a negative interest rate. This calculation does not take
    ///      Hyperdrive's solvency constraints into account and shouldn't be
    ///      used directly.
    /// @param _params The parameters for the max long calculation.
    /// @param _effectiveShareReserves The pool's effective share reserves.
    /// @param _spotPrice The pool's spot price.
    /// @return absoluteMaxBaseAmount The absolute maximum base amount.
    /// @return absoluteMaxBondAmount The absolute maximum bond amount.
    function calculateAbsoluteMaxLong(
        MaxTradeParams memory _params,
        uint256 _effectiveShareReserves,
        uint256 _spotPrice
    )
        internal
        pure
        returns (uint256 absoluteMaxBaseAmount, uint256 absoluteMaxBondAmount)
    {
        // We are targeting the pool's max spot price of:
        //
        // p_max = (1 - flatFee) / (1 + curveFee * (1 / p_0 - 1) * (1 - flatFee))
        //
        // We can derive a formula for the target bond reserves y_t in
        // terms of the target share reserves z_t as follows:
        //
        // p_max = ((mu * z_t) / y_t) ** t_s
        //
        //                       =>
        //
        // y_t = (mu * z_t) * ((1 + curveFee * (1 / p_0 - 1) * (1 - flatFee)) / (1 - flatFee)) ** (1 / t_s)
        //
        // We can use this formula to solve our YieldSpace invariant for z_t:
        //
        // k = (c / mu) * (mu * z_t) ** (1 - t_s) +
        //     (
        //         (mu * z_t) * ((1 + curveFee * (1 / p_0 - 1) * (1 - flatFee)) / (1 - flatFee)) ** (1 / t_s)
        //     ) ** (1 - t_s)
        //
        //                       =>
        //
        // z_t = (1 / mu) * (
        //           k / (
        //               (c / mu) +
        //               ((1 + curveFee * (1 / p_0 - 1) * (1 - flatFee)) / (1 - flatFee)) ** ((1 - t_s) / t_s))
        //           )
        //       ) ** (1 / (1 - t_s))
        uint256 inner;
        {
            uint256 k_ = YieldSpaceMath.kDown(
                _effectiveShareReserves,
                _params.bondReserves,
                ONE - _params.timeStretch,
                _params.vaultSharePrice,
                _params.initialVaultSharePrice
            );
            inner = _params.curveFee.mulUp(ONE.divUp(_spotPrice) - ONE).mulUp(
                ONE - _params.flatFee
            );
            inner = (ONE + inner).divUp(ONE - _params.flatFee);
            inner = inner.pow(
                (ONE - _params.timeStretch).divDown(_params.timeStretch)
            );
            inner += _params.vaultSharePrice.divUp(
                _params.initialVaultSharePrice
            );
            inner = k_.divDown(inner);
            inner = inner.pow(ONE.divDown(ONE - _params.timeStretch));
        }
        uint256 targetShareReserves = inner.divDown(
            _params.initialVaultSharePrice
        );

        // Now that we have the target share reserves, we can calculate the
        // target bond reserves using the formula:
        //
        // y_t = (mu * z_t) * ((1 + curveFee * (1 / p_0 - 1) * (1 - flatFee)) / (1 - flatFee)) ** (1 / t_s)
        //
        // Here we round down to underestimate the number of bonds that can be longed.
        uint256 targetBondReserves;
        {
            uint256 feeAdjustment = _params
                .curveFee
                .mulDown(ONE.divDown(_spotPrice) - ONE)
                .mulDown(ONE - _params.flatFee);
            targetBondReserves = (
                (ONE + feeAdjustment).divDown(ONE - _params.flatFee)
            ).pow(ONE.divUp(_params.timeStretch)).mulDown(inner);
        }

        // The absolute max base amount is given by:
        //
        // absoluteMaxBaseAmount = c * (z_t - z)
        absoluteMaxBaseAmount = (targetShareReserves - _effectiveShareReserves)
            .mulDown(_params.vaultSharePrice);

        // The absolute max bond amount is given by:
        //
        // absoluteMaxBondAmount = (y - y_t) - c(x)
        absoluteMaxBondAmount =
            (_params.bondReserves - targetBondReserves) -
            calculateLongCurveFee(
                absoluteMaxBaseAmount,
                _spotPrice,
                _params.curveFee
            );
    }

    // HACK: Copied from `delvtech/hyperdrive` repo.
    //
    /// @dev Calculates an initial guess of the max long that can be opened.
    ///      This is a reasonable estimate that is guaranteed to be less than
    ///      the true max long. We use this to get a reasonable starting point
    ///      for Newton's method.
    /// @param _params The max long calculation parameters.
    /// @param _absoluteMaxBaseAmount The absolute max base amount that can be
    ///        used to open a long.
    /// @param _checkpointExposure The exposure in the checkpoint.
    /// @param _spotPrice The spot price of the pool.
    /// @return A conservative estimate of the max long that the pool can open.
    function calculateMaxLongGuess(
        MaxTradeParams memory _params,
        uint256 _absoluteMaxBaseAmount,
        int256 _checkpointExposure,
        uint256 _spotPrice
    ) internal pure returns (uint256) {
        // Get an initial estimate of the max long by using the spot price as
        // our conservative price.
        uint256 guess = calculateMaxLongEstimate(
            _params,
            _checkpointExposure,
            _spotPrice,
            _spotPrice
        );

        // We know that the spot price is 1 when the absolute max base amount is
        // used to open a long. We also know that our spot price isn't a great
        // estimate (conservative or otherwise) of the realized price that the
        // max long will pay, so we calculate a better estimate of the realized
        // price by interpolating between the spot price and 1 depending on how
        // large the estimate is.
        uint256 t = guess
            .divDown(_absoluteMaxBaseAmount)
            .pow(ONE.divUp(ONE - _params.timeStretch))
            .mulDown(0.8e18);
        uint256 estimateSpotPrice = _spotPrice.mulDown(ONE - t) +
            ONE.mulDown(t);

        // Recalculate our initial guess using the bootstrapped conservative.
        // estimate of the realized price.
        guess = calculateMaxLongEstimate(
            _params,
            _checkpointExposure,
            _spotPrice,
            estimateSpotPrice
        );

        return guess;
    }

    // HACK: Copied from `delvtech/hyperdrive` repo.
    //
    /// @dev Estimates the max long based on the pool's current solvency and a
    ///      conservative price estimate, $p_r$.
    ///
    ///      We can use our estimate price $p_r$ to approximate $y(x)$ as
    ///      $y(x) \approx p_r^{-1} \cdot x - c(x)$. Plugging this into our
    ///      solvency function $s(x)$, we can calculate the share reserves and
    ///      exposure after opening a long with $x$ base as:
    ///
    ///      \begin{aligned}
    ///      z(x) &= z_0 + \tfrac{x - g(x)}{c} - z_{min} \\
    ///      e(x) &= e_0 + min(exposure_{c}, 0) + 2 \cdot y(x) - x + g(x) \\
    ///           &= e_0 + min(exposure_{c}, 0) + 2 \cdot p_r^{-1} \cdot x -
    ///                  2 \cdot c(x) - x + g(x)
    ///      \end{aligned}
    ///
    ///      We debit and negative checkpoint exposure from $e_0$ since the
    ///      global exposure doesn't take into account the negative exposure
    ///      from non-netted shorts in the checkpoint. These formulas allow us
    ///      to calculate the approximate ending solvency of:
    ///
    ///      $$
    ///      s(x) \approx z(x) - \tfrac{e(x)}{c} - z_{min}
    ///      $$
    ///
    ///      If we let the initial solvency be given by $s_0$, we can solve for
    ///      $x$ as:
    ///
    ///      $$
    ///      x = \frac{c}{2} \cdot \frac{s_0 + min(exposure_{c}, 0)}{
    ///              p_r^{-1} +
    ///              \phi_{g} \cdot \phi_{c} \cdot \left( 1 - p \right) -
    ///              1 -
    ///              \phi_{c} \cdot \left( p^{-1} - 1 \right)
    ///          }
    ///      $$
    /// @param _params The max long calculation parameters.
    /// @param _checkpointExposure The exposure in the checkpoint.
    /// @param _spotPrice The spot price of the pool.
    /// @param _estimatePrice The estimated realized price the max long will pay.
    /// @return A conservative estimate of the max long that the pool can open.
    function calculateMaxLongEstimate(
        MaxTradeParams memory _params,
        int256 _checkpointExposure,
        uint256 _spotPrice,
        uint256 _estimatePrice
    ) internal pure returns (uint256) {
        uint256 checkpointExposure = uint256(-_checkpointExposure.min(0));
        uint256 estimate = (_params.shareReserves +
            checkpointExposure.divDown(_params.vaultSharePrice) -
            _params.longExposure.divDown(_params.vaultSharePrice) -
            _params.minimumShareReserves).mulDivDown(
                _params.vaultSharePrice,
                2e18
            );
        estimate = estimate.divDown(
            ONE.divDown(_estimatePrice) +
                _params.governanceLPFee.mulDown(_params.curveFee).mulDown(
                    ONE - _spotPrice
                ) -
                ONE -
                _params.curveFee.mulDown(ONE.divDown(_spotPrice) - ONE)
        );
        return estimate;
    }

    // HACK: Copied from `delvtech/hyperdrive` repo.
    //
    /// @dev Gets the solvency of the pool $S(x)$ after a long is opened with a
    ///      base amount $x$.
    ///
    ///      Since longs can net out with shorts in this checkpoint, we decrease
    ///      the global exposure variable by any negative exposure we have
    ///      in the checkpoint. The pool's solvency is calculated as:
    ///
    ///      $$
    ///      s = z - \tfrac{exposure + min(exposure_{checkpoint}, 0)}{c} - z_{min}
    ///      $$
    ///
    ///      When a long is opened, the share reserves $z$ increase by:
    ///
    ///      $$
    ///      \Delta z = \tfrac{x - g(x)}{c}
    ///      $$
    ///
    ///      Opening the long increases the non-netted longs by the bond amount.
    ///      From this, the change in the exposure is given by:
    ///
    ///      $$
    ///      \Delta exposure = y(x)
    ///      $$
    ///
    ///      From this, we can calculate $S(x)$ as:
    ///
    ///      $$
    ///      S(x) = \left( z + \Delta z \right) - \left(
    ///                 \tfrac{
    ///                     exposure +
    ///                     min(exposure_{checkpoint}, 0) +
    ///                     \Delta exposure
    ///                 }{c}
    ///             \right) - z_{min}
    ///      $$
    ///
    ///      It's possible that the pool is insolvent after opening a long. In
    ///      this case, we return `None` since the fixed point library can't
    ///      represent negative numbers.
    /// @param _params The max long calculation parameters.
    /// @param _checkpointExposure The exposure in the checkpoint.
    /// @param _baseAmount The base amount.
    /// @param _bondAmount The bond amount.
    /// @param _spotPrice The spot price.
    /// @return The solvency of the pool.
    /// @return A flag indicating that the pool is solvent if true and insolvent
    ///         if false.
    function calculateSolvencyAfterLong(
        MaxTradeParams memory _params,
        int256 _checkpointExposure,
        uint256 _baseAmount,
        uint256 _bondAmount,
        uint256 _spotPrice
    ) internal pure returns (uint256, bool) {
        uint256 governanceFee = calculateLongGovernanceFee(
            _baseAmount,
            _spotPrice,
            _params.curveFee,
            _params.governanceLPFee
        );
        uint256 shareReserves = _params.shareReserves +
            _baseAmount.divDown(_params.vaultSharePrice) -
            governanceFee.divDown(_params.vaultSharePrice);
        uint256 exposure = _params.longExposure + _bondAmount;
        uint256 checkpointExposure = uint256(-_checkpointExposure.min(0));
        if (
            shareReserves +
                checkpointExposure.divDown(_params.vaultSharePrice) >=
            exposure.divDown(_params.vaultSharePrice) +
                _params.minimumShareReserves
        ) {
            return (
                shareReserves +
                    checkpointExposure.divDown(_params.vaultSharePrice) -
                    exposure.divDown(_params.vaultSharePrice) -
                    _params.minimumShareReserves,
                true
            );
        } else {
            return (0, false);
        }
    }

    // HACK: Copied from `delvtech/hyperdrive` repo.
    //
    /// @dev Gets the negation of the derivative of the pool's solvency with
    ///      respect to the base amount that the long pays.
    ///
    ///      The derivative of the pool's solvency $S(x)$ with respect to the
    ///      base amount that the long pays is given by:
    ///
    ///      $$
    ///      S'(x) = \tfrac{1}{c} \cdot \left(
    ///                  1 - y'(x) - \phi_{g} \cdot p \cdot c'(x)
    ///              \right) \\
    ///            = \tfrac{1}{c} \cdot \left(
    ///                  1 - y'(x) - \phi_{g} \cdot \phi_{c} \cdot \left(
    ///                      1 - p
    ///                  \right)
    ///              \right)
    ///      $$
    ///
    ///      This derivative is negative since solvency decreases as more longs
    ///      are opened. We use the negation of the derivative to stay in the
    ///      positive domain, which allows us to use the fixed point library.
    /// @param _params The max long calculation parameters.
    /// @param _baseAmount The base amount.
    /// @param _effectiveShareReserves The effective share reserves.
    /// @param _spotPrice The spot price.
    /// @return derivative The negation of the derivative of the pool's solvency
    ///         w.r.t the base amount.
    /// @return success A flag indicating whether or not the derivative was
    ///         successfully calculated.
    function calculateSolvencyAfterLongDerivative(
        MaxTradeParams memory _params,
        uint256 _baseAmount,
        uint256 _effectiveShareReserves,
        uint256 _spotPrice
    ) internal pure returns (uint256 derivative, bool success) {
        // Calculate the derivative of the long amount. This calculation can
        // fail when we are close to the root. In these cases, we exit early.
        (derivative, success) = calculateLongAmountDerivative(
            _params,
            _baseAmount,
            _effectiveShareReserves,
            _spotPrice
        );
        if (!success) {
            return (0, success);
        }

        // Finish computing the derivative.
        derivative += _params.governanceLPFee.mulDown(_params.curveFee).mulDown(
            ONE - _spotPrice
        );
        derivative -= ONE;

        return (derivative.mulDivDown(1e18, _params.vaultSharePrice), success);
    }

    // HACK: Copied from `delvtech/hyperdrive` repo.
    //
    /// @dev Gets the long amount that will be opened for a given base amount.
    ///
    ///      The long amount $y(x)$ that a trader will receive is given by:
    ///
    ///      $$
    ///      y(x) = y_{*}(x) - c(x)
    ///      $$
    ///
    ///      Where $y_{*}(x)$ is the amount of long that would be opened if there
    ///      was no curve fee and [$c(x)$](long_curve_fee) is the curve fee.
    ///      $y_{*}(x)$ is given by:
    ///
    ///      $$
    ///      y_{*}(x) = y - \left(
    ///                     k - \tfrac{c}{\mu} \cdot \left(
    ///                         \mu \cdot \left( z - \zeta + \tfrac{x}{c}
    ///                     \right) \right)^{1 - t_s}
    ///                 \right)^{\tfrac{1}{1 - t_s}}
    ///      $$
    /// @param _params The max long calculation parameters.
    /// @param _baseAmount The base amount.
    /// @param _effectiveShareReserves The effective share reserves.
    /// @param _spotPrice The spot price.
    /// @return The long amount.
    function calculateLongAmount(
        MaxTradeParams memory _params,
        uint256 _baseAmount,
        uint256 _effectiveShareReserves,
        uint256 _spotPrice
    ) internal pure returns (uint256) {
        uint256 longAmount = HyperdriveMath.calculateOpenLong(
            _effectiveShareReserves,
            _params.bondReserves,
            _baseAmount.divDown(_params.vaultSharePrice),
            _params.timeStretch,
            _params.vaultSharePrice,
            _params.initialVaultSharePrice
        );
        return
            longAmount -
            calculateLongCurveFee(_baseAmount, _spotPrice, _params.curveFee);
    }

    // HACK: Copied from `delvtech/hyperdrive` repo.
    //
    /// @dev Gets the derivative of [long_amount](long_amount) with respect to
    ///      the base amount.
    ///
    ///      We calculate the derivative of the long amount $y(x)$ as:
    ///
    ///      $$
    ///      y'(x) = y_{*}'(x) - c'(x)
    ///      $$
    ///
    ///      Where $y_{*}'(x)$ is the derivative of $y_{*}(x)$ and $c'(x)$ is the
    ///      derivative of [$c(x)$](long_curve_fee). $y_{*}'(x)$ is given by:
    ///
    ///      $$
    ///      y_{*}'(x) = \left( \mu \cdot (z - \zeta + \tfrac{x}{c}) \right)^{-t_s}
    ///                  \left(
    ///                      k - \tfrac{c}{\mu} \cdot
    ///                      \left(
    ///                          \mu \cdot (z - \zeta + \tfrac{x}{c}
    ///                      \right)^{1 - t_s}
    ///                  \right)^{\tfrac{t_s}{1 - t_s}}
    ///      $$
    ///
    ///      and $c'(x)$ is given by:
    ///
    ///      $$
    ///      c'(x) = \phi_{c} \cdot \left( \tfrac{1}{p} - 1 \right)
    ///      $$
    /// @param _params The max long calculation parameters.
    /// @param _baseAmount The base amount.
    /// @param _spotPrice The spot price.
    /// @param _effectiveShareReserves The effective share reserves.
    /// @return derivative The derivative of the long amount w.r.t. the base
    ///         amount.
    /// @return A flag indicating whether or not the derivative was
    ///         successfully calculated.
    function calculateLongAmountDerivative(
        MaxTradeParams memory _params,
        uint256 _baseAmount,
        uint256 _effectiveShareReserves,
        uint256 _spotPrice
    ) internal pure returns (uint256 derivative, bool) {
        // Compute the first part of the derivative.
        uint256 shareAmount = _baseAmount.divDown(_params.vaultSharePrice);
        uint256 inner = _params.initialVaultSharePrice.mulDown(
            _effectiveShareReserves + shareAmount
        );
        uint256 k_ = YieldSpaceMath.kDown(
            _effectiveShareReserves,
            _params.bondReserves,
            ONE - _params.timeStretch,
            _params.vaultSharePrice,
            _params.initialVaultSharePrice
        );
        derivative = ONE.divDown(inner.pow(_params.timeStretch));

        // It's possible that k is slightly larger than the rhs in the inner
        // calculation. If this happens, we are close to the root, and we short
        // circuit.
        uint256 rhs = _params.vaultSharePrice.mulDivDown(
            inner.pow(_params.timeStretch),
            _params.initialVaultSharePrice
        );
        if (k_ < rhs) {
            return (0, false);
        }
        derivative = derivative.mulDown(
            (k_ - rhs).pow(_params.timeStretch.divUp(ONE - _params.timeStretch))
        );

        // Finish computing the derivative.
        derivative -= _params.curveFee.mulDown(ONE.divDown(_spotPrice) - ONE);

        return (derivative, true);
    }

    // HACK: Copied from `delvtech/hyperdrive` repo.
    //
    /// @dev Gets the curve fee paid by longs for a given base amount.
    ///
    ///      The curve fee $c(x)$ paid by longs is given by:
    ///
    ///      $$
    ///      c(x) = \phi_{c} \cdot \left( \tfrac{1}{p} - 1 \right) \cdot x
    ///      $$
    /// @param _baseAmount The base amount, $x$.
    /// @param _spotPrice The spot price, $p$.
    /// @param _curveFee The curve fee, $\phi_{c}$.
    function calculateLongCurveFee(
        uint256 _baseAmount,
        uint256 _spotPrice,
        uint256 _curveFee
    ) internal pure returns (uint256) {
        // fee = curveFee * (1/p - 1) * x
        return _curveFee.mulUp(ONE.divUp(_spotPrice) - ONE).mulUp(_baseAmount);
    }

    // HACK: Copied from `delvtech/hyperdrive` repo.
    //
    /// @dev Gets the governance fee paid by longs for a given base amount.
    ///
    ///      Unlike the [curve fee](long_curve_fee) which is paid in bonds, the
    ///      governance fee is paid in base. The governance fee $g(x)$ paid by
    ///      longs is given by:
    ///
    ///      $$
    ///      g(x) = \phi_{g} \cdot p \cdot c(x)
    ///      $$
    /// @param _baseAmount The base amount, $x$.
    /// @param _spotPrice The spot price, $p$.
    /// @param _curveFee The curve fee, $\phi_{c}$.
    /// @param _governanceLPFee The governance fee, $\phi_{g}$.
    function calculateLongGovernanceFee(
        uint256 _baseAmount,
        uint256 _spotPrice,
        uint256 _curveFee,
        uint256 _governanceLPFee
    ) internal pure returns (uint256) {
        return
            calculateLongCurveFee(_baseAmount, _spotPrice, _curveFee)
                .mulDown(_governanceLPFee)
                .mulDown(_spotPrice);
    }

    // ╭───────────────────────────────────────────────────────────────────────╮
    // │                                Helpers                                │
    // ╰───────────────────────────────────────────────────────────────────────╯

    /// @dev Obtains the vaultSharePrice from the hyperdrive instance.
    /// @return The current vaultSharePrice.
    function vaultSharePrice(IHyperdrive self) internal view returns (uint256) {
        return _convertToBase(self, ONE);
    }

    /// @dev Returns whether a position is mature.
    /// @param _position Position to evaluate.
    /// @return True if the position is mature false otherwise.
    function isMature(
        IHyperdrive self,
        IEverlongStrategy.EverlongPosition memory _position
    ) internal view returns (bool) {
        return isMature(self, _position.maturityTime);
    }

    /// @dev Returns whether a position is mature.
    /// @param _maturity Maturity to evaluate.
    /// @return True if the position is mature false otherwise.
    function isMature(
        IHyperdrive self,
        uint256 _maturity
    ) internal view returns (bool) {
        return normalizedTimeRemaining(self, _maturity) == 0;
    }

    /// @dev Converts the duration of the bond to a value between 0 and 1.
    /// @param _maturity Maturity time to evaluate.
    /// @return timeRemaining The normalized duration of the bond.
    function normalizedTimeRemaining(
        IHyperdrive self,
        uint256 _maturity
    ) internal view returns (uint256 timeRemaining) {
        // Use the latest checkpoint to calculate the time remaining if the
        // bond is not mature.
        timeRemaining = _maturity > latestCheckpoint(self)
            ? _maturity - latestCheckpoint(self)
            : 0;

        // Represent the time remaining as a fraction of the term.
        timeRemaining = timeRemaining.divDown(
            self.getPoolConfig().positionDuration
        );

        // Since we overestimate the time remaining to underestimate the
        // proceeds, there is an edge case where _normalizedTimeRemaining > 1
        // if the position was opened in the same checkpoint. For this case,
        // we can just set it to ONE.
        if (timeRemaining > ONE) {
            timeRemaining = ONE;
        }
    }

    /// @dev Retrieve the latest checkpoint time from the hyperdrive instance.
    /// @return The latest checkpoint time.
    function latestCheckpoint(
        IHyperdrive self
    ) internal view returns (uint256) {
        return
            HyperdriveMath.calculateCheckpointTime(
                uint256(block.timestamp),
                self.getPoolConfig().checkpointDuration
            );
    }

    /// @dev Returns the closest checkpoint timestamp before _timestamp.
    /// @param _timestamp The timestamp to search for checkpoints.
    /// @return The closest checkpoint timestamp.
    function getCheckpointIdDown(
        IHyperdrive self,
        uint256 _timestamp
    ) internal view returns (uint256) {
        return
            _timestamp - (_timestamp % self.getPoolConfig().checkpointDuration);
    }

    /// @dev Returns the closest checkpoint before _timestamp.
    /// @param _timestamp The timestamp to search for checkpoints.
    /// @return The closest checkpoint.
    function getCheckpointDown(
        IHyperdrive self,
        uint256 _timestamp
    ) internal view returns (IHyperdrive.Checkpoint memory) {
        return self.getCheckpoint(getCheckpointIdDown(self, _timestamp));
    }

    /// @dev Returns the closest checkpoint timestamp after _timestamp.
    /// @param _timestamp The timestamp to search for checkpoints.
    /// @return The closest checkpoint timestamp.
    function getCheckpointIdUp(
        IHyperdrive self,
        uint256 _timestamp
    ) internal view returns (uint256) {
        uint256 _checkpointDuration = self.getPoolConfig().checkpointDuration;
        return
            _timestamp +
            (_checkpointDuration - (_timestamp % _checkpointDuration));
    }

    /// @dev Returns the closest checkpoint after _timestamp.
    /// @param _timestamp The timestamp to search for checkpoints.
    /// @return The closest checkpoint.
    function getCheckpointUp(
        IHyperdrive self,
        uint256 _timestamp
    ) internal view returns (IHyperdrive.Checkpoint memory) {
        return self.getCheckpoint(getCheckpointIdUp(self, _timestamp));
    }

    /// @dev Convert the input `_shareAmount` to base assets and return the
    ///      amount.
    /// @dev Modern hyperdrive instances expose a `convertToBase` function but
    ///      some legacy instances do not. For those legacy cases, we perform
    ///      the calculation here.
    /// @param _shareAmount Amount of shares to convert to base assets.
    /// @return The converted base amount.
    function _convertToBase(
        IHyperdrive self,
        uint256 _shareAmount
    ) internal view returns (uint256) {
        // Check whether the chain is mainnet. If so, special accomodations may
        // be needed for legacy hyperdrive instances.
        if (block.chainid == 1) {
            // If the address is the legacy stETH pool, we have to convert the
            // proceeds to base manually using Lido's `getPooledEthByShares`
            // function.
            if (address(self) == LEGACY_STETH_HYPERDRIVE) {
                return
                    ILido(address(self.vaultSharesToken()))
                        .getPooledEthByShares(_shareAmount);
            }
            // If the address is the legacy sDAI pool, we have to convert the
            // proceeds to base manually using ERC4626's `convertToAssets`
            // function.
            else if (address(self) == LEGACY_SDAI_HYPERDRIVE) {
                return
                    IERC4626(self.vaultSharesToken()).convertToAssets(
                        _shareAmount
                    );
            }
        }
        return self.convertToBase(_shareAmount);
    }

    /// @dev Convert the input `_baseAmount` to vault shares and return the
    ///      amount.
    /// @dev Modern hyperdrive instances expose a `convertToShares` function but
    ///      some legacy instances do not. For those legacy cases, we perform
    ///      the calculation here.
    /// @param _baseAmount Amount of base to convert to shares.
    /// @return The converted share amount.
    function _convertToShares(
        IHyperdrive self,
        uint256 _baseAmount
    ) internal view returns (uint256) {
        // Check whether the chain is mainnet. If so, special accomodations may
        // be needed for legacy hyperdrive instances.
        if (block.chainid == 1) {
            // If the address is the legacy stETH pool, we have to convert the
            // proceeds to shares manually using Lido's `getSharesByPooledEth`
            // function.
            if (address(self) == LEGACY_STETH_HYPERDRIVE) {
                return
                    ILido(address(self.vaultSharesToken()))
                        .getSharesByPooledEth(_baseAmount);
            }
            // If the address is the legacy sDAI pool, we have to convert the
            // proceeds to base manually using ERC4626's `convertToShares`
            // function.
            else if (address(self) == LEGACY_SDAI_HYPERDRIVE) {
                return
                    IERC4626(self.vaultSharesToken()).convertToShares(
                        _baseAmount
                    );
            }
        }
        return self.convertToShares(_baseAmount);
    }

    /// @dev Gets the minimum amount of strategy assets needed to open a long
    ///         with hyperdrive.
    /// @param _poolConfig The hyperdrive PoolConfig.
    /// @param _asBase Whether to transact in hyperdrive's base token or vault
    ///                shares token.
    /// @return amount Minimum amount of strategy assets needed to open a long
    ///                with hyperdrive.
    function _minimumTransactionAmount(
        IHyperdrive self,
        IHyperdrive.PoolConfig storage _poolConfig,
        bool _asBase
    ) public view returns (uint256 amount) {
        amount = _poolConfig.minimumTransactionAmount;

        // Since `amount` is denominated in hyperdrive's base token. We must
        // convert it to the shares token if `_asBase` is set to false.
        if (!_asBase) {
            amount = _convertToShares(self, amount);
        }
    }
}
