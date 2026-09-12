// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TraitBase} from "./TraitBase.sol";

/// @title OddLotTrait
/// @notice Breaking a lot to fill a small order costs the warehouse something, and
/// exchanges used to charge for it by name.
///
/// WHAT THIS SAYS ABOUT THE UNDERLYING, IN PLAIN LANGUAGE
/// A warehouse deals in lots. A tonne, a bar, a contract, a round hundred shares. Filling
/// an order for less than a lot means breaking one open, and the broken remainder is worth
/// less than the whole was, so somebody pays for the break. The NYSE charged this by name
/// for most of the twentieth century and called it the odd-lot differential: a surcharge
/// on any order below the round lot, quoted separately from the commission.
///
/// It is the only mechanic in this directory whose fee FALLS as the trade grows, and that
/// inversion is the entire point. Every other fee here makes size expensive. This one
/// makes dust expensive, because dust is what actually costs a warehouse money.
///
/// @dev FAMILY: supply.
///
/// @dev PROVENANCE, STATED PLAINLY. This trait has NO production source. The catalogue's
/// rule is that nothing in it is invented except where the header says so, and this header
/// says so. The market practice is real, documented and named; the shape and every
/// parameter here are ours. It is the sign-flip of `ImpactTrait`, which is catalogued as
/// section 1, and nothing else in the catalogue has a fee decreasing in size.
///
/// @dev IT CANNOT BE GAMED BY SPLITTING, AND THIS IS THE FIRST THING ANYONE WILL ASK.
/// A fee that falls with size sounds like it rewards breaking an order up. It does the
/// opposite, and the direction is worth working through, because getting it backwards is
/// the obvious mistake:
///
///   - A trader at or above the round lot pays ZERO. Splitting that order into ten pieces
///     below the lot makes every piece pay the differential. Splitting is punished.
///   - A trader already below the lot cannot improve their position by splitting further,
///     because a smaller piece pays MORE per the same schedule, and the pieces still sum
///     to the same shortfall. Splitting is punished there too.
///   - The only way to pay less is to trade a ROUNDER number, which is exactly the
///     behaviour a warehouse wants and exactly what the historical differential bought.
///
/// The schedule is monotone non-increasing in size, so there is no local minimum anywhere
/// for a bot to sit in. That is the property to preserve if anyone ever changes the curve.
///
/// @dev SYMMETRIC. Buys and sells pay the same. Breaking a lot costs the same whichever
/// direction the remainder is going, and a one-sided differential would be a directional
/// bet dressed as a handling charge.
///
/// @dev MEASURED AGAINST THE POOL, NOT AGAINST A FIXED NUMBER. The round lot is a
/// fraction of `tRes` rather than an absolute token count, because a launch's supply is
/// chosen freely and an absolute lot would mean something different in every launch. The
/// consequence is that the lot SHRINKS as the curve is bought out, so the same absolute
/// order counts as rounder later in the launch. That is the correct direction: a thinner
/// warehouse breaks smaller lots.
///
/// @dev LINEAR, NOT CONVEX, AND DELIBERATELY. A convex ramp would put most of the charge
/// on the very smallest trades, which reads as an anti-dust rule with a warehouse costume
/// on. The historical differential was flat, and a linear taper is the nearest honest
/// thing that avoids a cliff at the lot boundary.
///
/// @dev STATELESS. Returns `c.state` untouched, so the hook pays a same-value SSTORE
/// rather than a dirty one.
///
/// PARAMS, packed little end first into the frozen `bytes32`:
///   bits    0..23   oddPpm         uint24   1 .. 600000    the differential at zero size
///   bits   24..47   roundLotPpm    uint24   1 .. 1000000   the lot, as ppm of `tRes`
///   bits   48..71   capPpm         uint24   1 .. 600000
///   bits   72..255  MUST BE ZERO
///
/// WORKED SETTINGS
///   A launch that wants trades of at least a tenth of a percent of the remaining float:
///     oddPpm 20000 (2% at zero size), roundLotPpm 1000 (0.1% of `tRes`), capPpm 20000.
///   An order at exactly the lot pays nothing. An order at half the lot pays 1%. An order
///   at a tenth of the lot pays 1.8%. Dust pays the full 2% and stops being worth sending.
///
/// COST. Constant. One multiply, two divides, one subtract, one clamp. No loops, no
/// branches on trader input, no state transition.
contract OddLotTrait is TraitBase {
    uint256 private constant SH_ODD = 0;
    uint256 private constant SH_LOT = 24;
    uint256 private constant SH_CAP = 48;
    uint256 private constant SH_END = 72;

    function quote(Ctx calldata c) external pure returns (uint24 addFeePpm, bytes32 newState) {
        newState = c.state;

        uint256 oddPpm = _bits(c.params, SH_ODD, 24);
        uint256 roundLotPpm = _bits(c.params, SH_LOT, 24);
        uint256 cap = _bits(c.params, SH_CAP, 24);

        // An unconfigured slot charges nothing rather than guessing. `validate` is the
        // thing that stops a launch being frozen this way in the first place.
        if (oddPpm == 0 || roundLotPpm == 0 || cap == 0) return (0, newState);
        if (c.tRes == 0) return (0, newState);

        // The lot, in launched tokens. `roundLotPpm <= 1e6` and `tRes` is a `uint128`, so
        // the product is bounded by 1e6 * 2^128 and cannot overflow.
        uint256 lot = (uint256(c.tRes) * roundLotPpm) / PPM;
        if (lot == 0) return (0, newState);

        // `_sizeT` overstates a buy's token draw, because the realised fill walks up the
        // curve away from the marginal price. Overstating size UNDERSTATES this fee, which
        // is the conservative direction for a charge that falls with size: it never
        // charges a trader more than the true size would.
        uint256 size = _sizeT(c);
        if (size >= lot) return (0, newState);

        uint256 shortfall = lot - size;
        uint256 raw = (oddPpm * shortfall) / lot;

        addFeePpm = _fee(raw, cap);
    }

    function describe() external pure returns (string memory family, string memory name) {
        return ("supply", "OddLot");
    }

    /// @dev Rejects the sentinel shapes that would silently disarm the mechanic (a zero
    /// differential, a zero lot, a zero cap), rejects a lot larger than the whole pool
    /// (which would charge the differential on every trade that could ever happen and make
    /// the trait a flat tax wearing a lot-size label), and rejects any bit set above the
    /// last defined field. RULE 5: a parameter set to a reserved value is how float
    /// disarmed a quorum breaker on three markets by an exact tie on an inclusive
    /// comparison.
    function validate(bytes32 params) external pure returns (bool) {
        if (_above(params, SH_END) != 0) return false;
        uint256 oddPpm = _bits(params, SH_ODD, 24);
        uint256 roundLotPpm = _bits(params, SH_LOT, 24);
        uint256 cap = _bits(params, SH_CAP, 24);
        if (!_inRange(oddPpm, 1, MAX_ADD_PPM)) return false;
        if (!_inRange(roundLotPpm, 1, PPM)) return false;
        if (!_inRange(cap, 1, MAX_ADD_PPM)) return false;
        return true;
    }
}
