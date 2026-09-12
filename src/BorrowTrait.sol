// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TraitBase} from "./TraitBase.sol";

/// @title BorrowTrait
/// @notice What the last available share costs is not what the first one cost.
///
/// WHAT THIS SAYS ABOUT THE UNDERLYING, IN PLAIN LANGUAGE
/// A securities lending desk quotes two completely different worlds under one name. Most of
/// the market is general collateral: the shares are everywhere, the rate is a few basis
/// points, and nobody thinks about it. Then a name goes special. The lendable float shrinks,
/// the rate stops being a rounding error, and it does not rise in a straight line. It goes
/// hyperbolic, because the price of the last available share is set by the fact that there
/// is no other one. GameStop's borrow rate reached triple digits annualised in January 2021,
/// and it did that on the same desk, under the same contract, that had been quoting a
/// fraction of a percent for the same stock a month earlier.
///
/// A launch on this chain has a lendable float and it is not a metaphor: `tRes` is the stock
/// still sitting in the warehouse and `supply` is how much there ever was. The ratio starts
/// at one and falls as the curve sells, and it is the only quantity in `Ctx` that says how
/// much of the thing is left. This structure quotes the general collateral rate while there
/// is plenty on the shelf, and the scarcity rate once there is not.
///
/// @dev FAMILY: supply.
///
/// @dev THE RATE IS SET ON THE FLOAT YOU LEAVE BEHIND, NOT THE ONE YOU FOUND. A buy that
/// takes half of what is left is not entitled to the rate that applied before it took it.
/// This is the whole difference between this structure and a level reading of `tRes`: the
/// trade is priced against the market it creates, so the order that empties the shelf pays
/// the empty-shelf rate. It also means the structure prices a squeeze while it is happening
/// rather than one block later.
///
/// @dev SYMMETRIC IN RULE, NOT IN NUMBER, WHEN `sideMode` IS 1. A sell RETURNS stock to the
/// shelf, so the float it leaves behind is LARGER and the rate it pays is lower. That is
/// what a lending desk does when a borrow comes back, and it falls out of the arithmetic
/// rather than being bolted on. In `sideMode` 0 the seller pays nothing at all, which is
/// the stricter reading: the borrower pays the borrow.
///
/// @dev WHICH SIDE IS THE BORROWER, SINCE SOMEBODY WILL ASK. In a real hard-to-borrow name
/// the SHORT pays the rate. There is no short here; there is no lending, no rehypothecation
/// and no locate. What there is, is a warehouse whose lendable float is shrinking, and the
/// party removing the last of it is the BUYER. So the buyer pays. Charging the seller as the
/// primary side would be charging the person putting stock back on the shelf, which is the
/// opposite of what a lending desk does. `CATALOGUE.md` section 5 reaches the same
/// conclusion from the other direction and recommends `buysOnly` for the same reason.
///
/// @dev STATELESS. Everything comes out of `tRes`, `supply` and the trade being priced, all
/// of which are already in `Ctx`. `c.state` is returned untouched, so the hook pays a
/// same-value SSTORE rather than a dirty one. This is the cheapest structure in the
/// directory after `Null`, which `CLAUDE.md`'s design note predicted: the ratio is already
/// in `Ctx` and the mechanic is nearly free.
///
/// @dev HYPERBOLIC, NOT KINKED, AND THE DIFFERENCE MATTERS. Compound's borrow curve, which
/// `CATALOGUE.md` section 5 catalogues as `Utilisation`, is piecewise linear with a kink.
/// This one is `easy * pivot / float`, which has no kink, no cliff and no boundary to stand
/// exactly on, and it is the shape a real borrow rate actually has: a scarcity price behaves
/// like one over the remaining supply, not like a line with a bend in it. A launcher installs
/// one or the other, never both.
///
/// @dev AN EMPTY SHELF CHARGES THE CAP RATHER THAN DIVIDING BY ZERO. A float of exactly
/// nothing is not an error condition and it is not infinity either; it is the cap, which is
/// the most the structure was ever allowed to say. Stated here because a hyperbola with a
/// zero denominator is the first thing anybody will look for.
///
/// @dev NEVER REFUSES. However special the name gets, an exit is available in every block,
/// and under `sideMode` 0 an exit is free.
///
/// PARAMS, packed little end first into the frozen `bytes32`:
///   bits    0..23   easyPpm   uint24   1 .. capPpm     the general collateral rate
///   bits   24..47   pivotPpm  uint24   1 .. 1000000    float at which it stops being easy
///   bits   48..71   capPpm    uint24   1 .. 600000
///   bits   72..79   sideMode  uint8    0 or 1          0 buys only, 1 both sides
///   bits   80..255  MUST BE ZERO
///
/// WORKED SETTINGS
///   A name that is meant to go special near the end of its curve:
///     easyPpm 500 (5 bps), pivotPpm 250000 (a quarter of the supply), capPpm 60000,
///     sideMode 0.
///   Five basis points for the whole first three quarters of the warehouse, because the
///   supply split leaves 25% of the tokens in the curve at graduation and that is where the
///   pivot is put. At 10% float the rate is 12.5 bps, at 2% it is 62.5 bps, at 0.2% it is
///   6.25% and it keeps going until the cap catches it.
///
/// COST. Constant. One saturating subtract, three multiplies, two divides, one comparison,
/// one clamp. No loops, no state transition.
contract BorrowTrait is TraitBase {
    uint256 private constant SH_EASY = 0;
    uint256 private constant SH_PIVOT = 24;
    uint256 private constant SH_CAP = 48;
    uint256 private constant SH_SIDE = 72;
    uint256 private constant SH_END = 80;

    uint256 private constant SIDE_BUYS = 0;
    uint256 private constant SIDE_BOTH = 1;

    function quote(Ctx calldata c) external pure returns (uint24 addFeePpm, bytes32 newState) {
        newState = c.state;

        uint256 easy = _bits(c.params, SH_EASY, 24);
        uint256 pivot = _bits(c.params, SH_PIVOT, 24);
        uint256 cap = _bits(c.params, SH_CAP, 24);

        // An unconfigured slot charges nothing rather than guessing. `validate` is the
        // thing that stops a launch being frozen this way in the first place.
        if (easy == 0 || pivot == 0 || cap == 0) return (0, newState);
        if (c.supply == 0) return (0, newState);
        if (!c.buying && _bits(c.params, SH_SIDE, 8) == SIDE_BUYS) return (0, newState);

        // The tokens this trade moves. `_sizeT` OVERSTATES a buy's token draw, because the
        // realised fill walks up the curve away from the marginal price, so it overstates
        // how much float the buy removes and therefore overstates the rate. That is the
        // conservative direction for the pool, which is the direction every rounding and
        // every approximation in this directory is pointed.
        uint256 dy = _sizeT(c);
        // `_mulDiv128` bounds its INPUTS and not its OUTPUT, so a `_sizeT` result can sit
        // far above uint128 and take any later multiply with it: `uWad` 8, `tRes` 2.10e35
        // and `specified` 2^128 - 1 gives about 8.9e72, and that times PPM is 8.9e78
        // against a uint256 ceiling of 1.16e77. WARNINGS.md records it. Clamp the RESULT.
        if (dy > U128_MAX) dy = U128_MAX;

        uint256 shelf = c.buying ? _satSub(uint256(c.tRes), dy) : uint256(c.tRes) + dy;
        // Returning more than the warehouse ever held does not make the float bigger than
        // the supply; it makes it the supply.
        if (shelf > uint256(c.supply)) shelf = uint256(c.supply);

        // `shelf` is at most `supply`, a uint128, so `shelf * PPM` is under 3.5e44.
        uint256 floatPpm = (shelf * PPM) / uint256(c.supply);

        // An empty shelf is the cap, not a division by zero and not infinity.
        if (floatPpm == 0) return (_fee(MAX_ADD_PPM, cap), newState);

        // General collateral while there is plenty, the scarcity hyperbola once there is
        // not. `easy` is a uint24 and `pivot` is at most 1e6, so the product is under
        // 1.7e13 and cannot overflow.
        uint256 raw = floatPpm >= pivot ? easy : (easy * pivot) / floatPpm;

        addFeePpm = _fee(raw, cap);
    }

    function describe() external pure returns (string memory family, string memory name) {
        return ("supply", "Borrow");
    }

    /// @dev Rejects the sentinel shapes that would silently disarm the mechanic (a zero
    /// rate, a zero pivot, a zero cap), rejects a general collateral rate above the cap
    /// (which would make the cap the only number the structure ever returns, a flat tax
    /// wearing a borrow curve's clothes), rejects a pivot above the whole float, rejects a
    /// side mode outside the two it defines rather than defaulting it, and rejects any bit
    /// set above the last defined field. RULE 5: a parameter set to a reserved value is how
    /// float disarmed a quorum breaker on three markets by an exact tie on an inclusive
    /// comparison.
    function validate(bytes32 params) external pure returns (bool) {
        if (_above(params, SH_END) != 0) return false;
        uint256 easy = _bits(params, SH_EASY, 24);
        uint256 pivot = _bits(params, SH_PIVOT, 24);
        uint256 cap = _bits(params, SH_CAP, 24);
        uint256 side = _bits(params, SH_SIDE, 8);
        if (!_inRange(cap, 1, MAX_ADD_PPM)) return false;
        if (!_inRange(easy, 1, cap)) return false;
        if (!_inRange(pivot, 1, PPM)) return false;
        if (side > SIDE_BOTH) return false;
        return true;
    }
}
