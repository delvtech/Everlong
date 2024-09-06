// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import { console2 as console } from "forge-std/console2.sol";
import { IHyperdrive } from "hyperdrive/contracts/src/interfaces/IHyperdrive.sol";
import { FixedPointMath } from "hyperdrive/contracts/src/libraries/FixedPointMath.sol";
import { HyperdriveMath } from "hyperdrive/contracts/src/libraries/HyperdriveMath.sol";
import { YieldSpaceMath } from "hyperdrive/contracts/src/libraries/YieldSpaceMath.sol";
import { SafeCast } from "hyperdrive/contracts/src/libraries/SafeCast.sol";
import { Packing } from "openzeppelin/utils/Packing.sol";
import { IEverlong } from "../interfaces/IEverlong.sol";

// TODO: Extract into its own library.
uint256 constant HYPERDRIVE_SHARE_RESERVES_BOND_RESERVES_SLOT = 2;
uint256 constant HYPERDRIVE_LONG_EXPOSURE_LONGS_OUTSTANDING_SLOT = 3;
uint256 constant HYPERDRIVE_SHARE_ADJUSTMENT_SHORTS_OUTSTANDING_SLOT = 4;

library HyperdriveExecutionLibrary {
    using FixedPointMath for uint256;
    using SafeCast for *;
    using Packing for bytes32;

    // ╭─────────────────────────────────────────────────────────╮
    // │ Open Long                                               │
    // ╰─────────────────────────────────────────────────────────╯

    struct OpenLongParams {
        uint256 maxSlippage;
        bool asBase;
    }

    function openLong(
        IHyperdrive self,
        OpenLongParams memory _params,
        uint256 _amount
    ) internal returns (uint256 maturity, uint256 quantity, uint256 price) {
        price = vaultSharePrice(self);
        // TODO: minVaultSharePrice
        (maturity, quantity) = self.openLong(
            _amount,
            previewOpenLong(self, _params, _amount),
            0,
            IHyperdrive.Options(address(this), _params.asBase, "")
        );
        return (maturity, quantity, price);
    }

    function previewOpenLong(
        IHyperdrive self,
        OpenLongParams memory _params,
        uint256 _amount
    ) internal view returns (uint256) {
        return _calculateOpenLong(self, self.convertToShares(_amount));
    }

    /// @dev Calculates the number of bonds a user will receive when opening a
    ///      long position.
    /// @param _shareAmount Amount of shares being exchanged for bonds.
    /// @return Amount of bonds received.
    function _calculateOpenLong(
        IHyperdrive self,
        uint256 _shareAmount
    ) internal view returns (uint256) {
        // We must load the entire PoolConfig since it contains values from
        // immutables without public accessors.
        IHyperdrive.PoolConfig memory poolConfig = self.getPoolConfig();

        // Save gas by reading storage directly instead of retrieving entire
        // PoolInfo and PoolConfig structs.
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
        uint256 bondReservesDelta = YieldSpaceMath
            .calculateBondsOutGivenSharesInDown(
                effectiveShareReserves,
                bondReserves,
                _shareAmount,
                // NOTE: Since the bonds traded on the curve are newly minted,
                // we use a time remaining of 1. This means that we can use
                // `_timeStretch = t * _timeStretch`.
                1e18 - poolConfig.timeStretch,
                _vaultSharePrice,
                poolConfig.initialVaultSharePrice
            );

        uint256 spotPrice = HyperdriveMath.calculateSpotPrice(
            effectiveShareReserves,
            bondReserves,
            poolConfig.initialVaultSharePrice,
            poolConfig.timeStretch
        );

        (, bondReservesDelta, ) = _calculateOpenLongFees(
            _shareAmount,
            bondReservesDelta,
            _vaultSharePrice,
            spotPrice,
            poolConfig.fees.curve,
            poolConfig.fees.governanceLP
        );
        return bondReservesDelta;
    }

    /// @dev Calculate the fees involved with opening the long and apply them.
    /// @param _shareReservesDelta The change in the share reserves without fees.
    /// @param _bondReservesDelta The change in the bond reserves without fees.
    /// @param _vaultSharePrice The current vault share price.
    /// @param _spotPrice The current spot price.
    /// @return The change in the share reserves with fees.
    /// @return The change in the bond reserves with fees.
    /// @return The governance fee in shares.
    function _calculateOpenLongFees(
        uint256 _shareReservesDelta,
        uint256 _bondReservesDelta,
        uint256 _vaultSharePrice,
        uint256 _spotPrice,
        uint256 _curveFee,
        uint256 _governanceLPFee
    ) internal pure returns (uint256, uint256, uint256) {
        // Calculate the fees charged to the user (curveFee) and the portion
        // of those fees that are paid to governance (governanceCurveFee).
        (
            uint256 curveFee, // bonds
            uint256 governanceCurveFee // bonds
        ) = _calculateFeesGivenShares(
                _shareReservesDelta,
                _spotPrice,
                _vaultSharePrice,
                _curveFee,
                _governanceLPFee
            );

        // Calculate the impact of the curve fee on the bond reserves. The curve
        // fee benefits the LPs by causing less bonds to be deducted from the
        // bond reserves.
        _bondReservesDelta -= curveFee;

        // NOTE: Round down to underestimate the governance fee.
        //
        // Calculate the fees owed to governance in shares. Open longs are
        // calculated entirely on the curve so the curve fee is the total
        // governance fee. In order to convert it to shares we need to multiply
        // it by the spot price and divide it by the vault share price:
        //
        // shares = (bonds * base/bonds) / (base/shares)
        // shares = bonds * shares/bonds
        // shares = shares
        uint256 totalGovernanceFee = governanceCurveFee.mulDivDown(
            _spotPrice,
            _vaultSharePrice
        );

        // Calculate the number of shares to add to the shareReserves.
        // shareReservesDelta, _shareAmount and totalGovernanceFee
        // are all denominated in shares:
        //
        // shares = shares - shares
        _shareReservesDelta -= totalGovernanceFee;

        return (_shareReservesDelta, _bondReservesDelta, totalGovernanceFee);
    }

    // ╭─────────────────────────────────────────────────────────╮
    // │ Close Long                                              │
    // ╰─────────────────────────────────────────────────────────╯

    struct CloseLongParams {
        uint256 maxSlippage;
        bool asBase;
    }

    function closeLong(
        IHyperdrive self,
        IEverlong.Position memory _position,
        CloseLongParams memory _params
    ) internal returns (uint256) {
        return
            self.closeLong(
                _position.maturityTime,
                _position.bondAmount,
                // previewCloseLong(self, _position, _params),
                0,
                IHyperdrive.Options(address(this), _params.asBase, "")
            );
    }

    function previewCloseLong(
        IHyperdrive self,
        IEverlong.Position memory _position,
        CloseLongParams memory _params
    ) internal view returns (uint256) {
        uint256 shareProceeds = _calculateCloseLong(
            self,
            _position.maturityTime,
            _position.bondAmount,
            _position.vaultSharePrice
        );
        if (_params.asBase) {
            return self.convertToBase(shareProceeds);
        }
        return shareProceeds;
    }

    function _calculateCloseLong(
        IHyperdrive self,
        uint256 _maturityTime,
        uint256 _bondAmount,
        uint256 _vaultSharePrice
    ) internal view returns (uint256) {
        IHyperdrive.PoolConfig memory poolConfig = self.getPoolConfig();
        uint256[] memory slots = new uint256[](2);
        slots[0] = HYPERDRIVE_SHARE_RESERVES_BOND_RESERVES_SLOT;
        slots[1] = HYPERDRIVE_SHARE_ADJUSTMENT_SHORTS_OUTSTANDING_SLOT;
        bytes32[] memory values = self.load(slots);
        uint256 effectiveShareReserves = HyperdriveMath
            .calculateEffectiveShareReserves(
                uint128(values[0].extract_32_16(16)), // shareReserves
                uint256(uint128(values[1].extract_32_16(16))).toInt256() // shareAdjustment
            );
        uint256 _normalizedTimeRemaining = normalizedTimeRemaining(
            self,
            _maturityTime
        );
        uint256 closeVaultSharePrice = vaultSharePrice(self);
        uint256 openVaultSharePrice = getNearestCheckpointUp(
            self,
            _maturityTime - poolConfig.positionDuration
        ).vaultSharePrice;
        (, , uint256 shareProceeds) = HyperdriveMath.calculateCloseLong(
            effectiveShareReserves,
            uint128(values[0].extract_32_16(0)), // bondReserves
            _bondAmount,
            _normalizedTimeRemaining,
            poolConfig.timeStretch,
            closeVaultSharePrice,
            poolConfig.initialVaultSharePrice
        );

        // Calculate the fees that should be paid by the trader. The trader
        // pays a fee on the curve and flat parts of the trade. Most of the
        // fees go the LPs, but a portion goes to governance.
        uint256 spotPrice = HyperdriveMath.calculateSpotPrice(
            effectiveShareReserves,
            uint128(values[0].extract_32_16(0)), // bondReserves
            poolConfig.initialVaultSharePrice,
            poolConfig.timeStretch
        );

        IHyperdrive.Fees memory fees = poolConfig.fees;
        (
            uint256 curveFee, // shares
            uint256 flatFee, // shares
            // shares
            ,

        ) = // shares
            _calculateFeesGivenBonds(
                _bondAmount,
                _normalizedTimeRemaining,
                spotPrice,
                closeVaultSharePrice,
                fees.curve,
                fees.flat,
                fees.governanceLP
            );
        shareProceeds -= curveFee + flatFee;

        if (closeVaultSharePrice < openVaultSharePrice) {
            shareProceeds = shareProceeds.mulDivDown(
                closeVaultSharePrice,
                openVaultSharePrice
            );
        }

        return shareProceeds;
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
    /// @return governanceCurveFee The curve fee that goes to governance. The
    ///         fee is in terms of shares.
    /// @return totalGovernanceFee The total fee that goes to governance. The
    ///         fee is in terms of shares.
    function _calculateFeesGivenBonds(
        uint256 _bondAmount,
        uint256 _normalizedTimeRemaining,
        uint256 _spotPrice,
        uint256 _vaultSharePrice,
        uint256 _curveFee,
        uint256 _flatFee,
        uint256 _governanceLPFee
    )
        internal
        pure
        returns (
            uint256 curveFee,
            uint256 flatFee,
            uint256 governanceCurveFee,
            uint256 totalGovernanceFee
        )
    {
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
            .mulUp(1e18 - _spotPrice)
            .mulUp(_bondAmount)
            .mulDivUp(_normalizedTimeRemaining, _vaultSharePrice);

        // NOTE: Round down to underestimate the governance curve fee.
        //
        // Calculate the curve portion of the governance fee:
        //
        // governanceCurveFee = curve_fee * phi_gov
        //                    = shares * phi_gov
        governanceCurveFee = curveFee.mulDown(_governanceLPFee);

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
            1e18 - _normalizedTimeRemaining,
            _vaultSharePrice
        );
        flatFee = flat.mulUp(_flatFee);

        // NOTE: Round down to underestimate the total governance fee.
        //
        // We calculate the flat portion of the governance fee as:
        //
        // governance_flat_fee = flat_fee * phi_gov
        //                     = shares * phi_gov
        //
        // The totalGovernanceFee is the sum of the curve and flat governance fees.
        totalGovernanceFee =
            governanceCurveFee +
            flatFee.mulDown(_governanceLPFee);
    }

    /// @dev Calculates the fees that go to the LPs and governance.
    /// @param _shareAmount The amount of shares exchanged for bonds.
    /// @param _spotPrice The price without slippage of bonds in terms of base
    ///         (base/bonds).
    /// @param _vaultSharePrice The current vault share price (base/shares).
    /// @return curveFee The curve fee. The fee is in terms of bonds.
    /// @return governanceCurveFee The curve fee that goes to governance. The
    ///         fee is in terms of bonds.
    function _calculateFeesGivenShares(
        uint256 _shareAmount,
        uint256 _spotPrice,
        uint256 _vaultSharePrice,
        uint256 _curveFee,
        uint256 _governanceLPFee
    ) internal pure returns (uint256 curveFee, uint256 governanceCurveFee) {
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
        curveFee = (uint256(1e18).divUp(_spotPrice) - 1e18)
            .mulUp(_curveFee)
            .mulUp(_vaultSharePrice)
            .mulUp(_shareAmount);

        // NOTE: Round down to underestimate the governance curve fee.
        //
        // We leave the governance fee in terms of bonds:
        // governanceCurveFee = curve_fee * phi_gov
        //                    = bonds * phi_gov
        governanceCurveFee = curveFee.mulDown(_governanceLPFee);
    }

    function vaultSharePrice(IHyperdrive self) internal view returns (uint256) {
        return self.convertToBase(1e18);
    }

    function isMature(
        IHyperdrive self,
        IEverlong.Position memory _position
    ) internal view returns (bool) {
        return isMature(self, _position.maturityTime);
    }

    function isMature(
        IHyperdrive self,
        uint256 _maturity
    ) internal view returns (bool) {
        return normalizedTimeRemaining(self, _maturity) == 0;
    }

    function normalizedTimeRemaining(
        IHyperdrive self,
        uint256 _maturity
    ) internal view returns (uint256 _duration) {
        _maturity = getNearestCheckpointIdUp(self, _maturity);
        _duration = _maturity > latestCheckpoint(self)
            ? _maturity - latestCheckpoint(self)
            : 0;
        _duration = _duration.divUp(self.getPoolConfig().positionDuration);
    }

    function latestCheckpoint(
        IHyperdrive self
    ) internal view returns (uint256) {
        return
            HyperdriveMath.calculateCheckpointTime(
                uint256(block.timestamp),
                self.getPoolConfig().checkpointDuration
            );
    }

    function getNearestCheckpointIdDown(
        IHyperdrive self,
        uint256 _timestamp
    ) internal view returns (uint256) {
        return
            _timestamp - (_timestamp % self.getPoolConfig().checkpointDuration);
    }

    function getNearestCheckpointDown(
        IHyperdrive self,
        uint256 _timestamp
    ) internal view returns (IHyperdrive.Checkpoint memory) {
        return self.getCheckpoint(getNearestCheckpointIdDown(self, _timestamp));
    }

    function getNearestCheckpointIdUp(
        IHyperdrive self,
        uint256 _timestamp
    ) internal view returns (uint256) {
        uint256 _checkpointDuration = self.getPoolConfig().checkpointDuration;
        return
            _timestamp +
            (_checkpointDuration - (_timestamp % _checkpointDuration));
    }

    function getNearestCheckpointUp(
        IHyperdrive self,
        uint256 _timestamp
    ) internal view returns (IHyperdrive.Checkpoint memory) {
        return self.getCheckpoint(getNearestCheckpointIdUp(self, _timestamp));
    }
}