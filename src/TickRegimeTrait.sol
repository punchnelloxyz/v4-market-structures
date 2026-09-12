// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TraitBase} from "./TraitBase.sol";

/// @title TickRegimeTrait
/// @notice A price that cannot move by a tick has not moved, and quoting it anyway is the
/// thing exchanges charge for.
///
/// WHAT THIS SAYS ABOUT THE UNDERLYING, IN PLAIN LANGUAGE
/// Every regulated market quantises its prices. You cannot bid 50.0037 for a share; there is
/// a minimum increment and it is set by rule. MiFID II wrote the European table into RTS 11
/// in 2018, keyed on price and on how many trades a day the instrument does, and the SEC ran
/// a two-year experiment on the same question, the Tick Size Pilot, which widened the
/// increment to five cents for hundreds of small caps and then measured what happened.
///
/// Both were arguing about the same thing. A tick that is too fine lets anybody step in front
/// of a resting order for a fraction of a cent they never really paid, and the book fills up
/// with quotes that flicker without ever changing the price. A tick that is too coarse makes
/// the spread artificially wide. The regulators landed where they landed, and the finding
/// that survived both regimes is the interesting one: below the tick, activity is not price
/// discovery. It is noise.
///
/// A bonding curve has no tick. Its price is a ratio of two integers and it moves by an
/// arbitrarily small amount for an arbitrarily small trade, so it is a venue with an infinite
/// number of price levels and no minimum increment at all. This structure gives it one. A
/// trade that moves the price by at least one tick pays nothing: it did something, the mark
/// changed, that is what a market is for. A trade that moves the price by less than a tick
/// pays for the privilege, and the less it moves the price the more it pays, all the way down
/// to a trade that moves nothing whatsoever and pays the whole charge.
///
/// @dev FAMILY: physical. It is a handling rule, in the same sense that a lot size is.
///
/// @dev IT IS THE ONLY STRUCTURE HERE THAT PRICES THE MOVE RATHER THAN THE SIZE, WITH THE
/// SIGN INVERTED. `ImpactTrait` charges half the price move and rises with it. This charges
/// the SHORTFALL against one tick and falls with it. They are the two ends of the same
/// measurement and a launcher can coherently install both: one makes the trades that move the
/// market pay for the move, the other makes the trades that do not move it pay for the space.
///
/// @dev IT IS ALSO NOT `OddLot`, THOUGH BOTH FALL WITH SIZE. `OddLotTrait` measures a
/// QUANTITY against a lot; this measures a PRICE MOVE against a tick. The difference is
/// observable and it matters: the same order in a pool with twice the reserve moves the price
/// half as far, so it is odd-lot-identical and tick-different. A lot is a convention about
/// how much; a tick is a convention about how far.
///
/// @dev THE MOVE IS THE PRICE MOVE, NOT EXECUTION SLIPPAGE, AND THEY ARE NOT THE SAME
/// NUMBER. Slippage is `1 - 1/(1 + x/R)`, what the trader loses against spot. The price move
/// is `((R + x)/R)^2 - 1`, what the next trader finds. They differ by about 2x at small size
/// and diverge without limit. On constant product both branches are closed form and neither
/// reads the venue:
///
///     buy of `dx` underlying:  P'/P = ((uWad + dx) / uWad)^2
///     sell of `dy` tokens:     P'/P = (tRes / (tRes + dy))^2
///
/// `research/traits/CATALOGUE.md` section 1 carries the derivation and `WARNINGS.md` records
/// the session that asserted the wrong one.
///
/// @dev SYMMETRIC. A tick is a tick in both directions. The two branches are different
/// expressions because a buy's ratio is above one and a sell's is below it, which is the same
/// asymmetry in shape that `ImpactTrait` documents, but the schedule applied to the resulting
/// move is identical either way.
///
/// @dev THE SAWTOOTH VERSION WAS CONSIDERED AND REJECTED. The most literal reading of a tick
/// regime charges for the sub-tick REMAINDER: a trade moving 2.7 ticks pays for the 0.7,
/// because the 0.7 is the part a real book could not have expressed. It is a better metaphor
/// and a worse mechanic. It is not monotone, so it puts a local minimum at every whole tick
/// for a bot to sit in, and it is unreachable in practice anyway because a trader specifying
/// an exact output cannot compute the fill that determines their own remainder. The version
/// shipped here is monotone non-increasing in the move over the whole domain, which is the
/// property to preserve if anyone ever changes the curve.
///
/// @dev STATELESS. Returns `c.state` untouched, so the hook pays a same-value SSTORE rather
/// than a dirty one.
///
/// @dev NEVER REFUSES. The most a noise trade can be charged is `capPpm`, and the way to stop
/// paying it is to send a trade that actually does something.
///
/// PARAMS, packed little end first into the frozen `bytes32`:
///   bits    0..23   tickPpm   uint24   1 .. 100000   the minimum increment, ppm of price
///   bits   24..47   noisePpm  uint24   1 .. capPpm   charge on a trade that moves nothing
///   bits   48..71   capPpm    uint24   1 .. 600000
///   bits   72..255  MUST BE ZERO
///
/// WORKED SETTINGS
///   A penny tick on a fifty dollar share is 200 ppm of price, which is the increment most of
///   the equities on this chain quote in:
///     tickPpm 200, noisePpm 3000 (0.3%), capPpm 3000.
///   A trade that moves the price a full 200 ppm or more pays nothing. One that moves it 100
///   ppm pays 0.15%. One that moves it nothing at all pays 0.3% and stops being worth
///   sending, which is what the Tick Size Pilot was testing for.
///   A nickel tick, which is what the pilot widened small caps to, is 1000 ppm on the same
///   share:
///     tickPpm 1000, noisePpm 5000, capPpm 5000.
///
/// COST. Constant. One square, three multiplies, three divides, two comparisons, one clamp.
/// No loops, no state transition, no branch on anything but the side of the trade.
contract TickRegimeTrait is TraitBase {
    uint256 private constant SH_TICK = 0;
    uint256 private constant SH_NOISE = 24;
    uint256 private constant SH_CAP = 48;
    uint256 private constant SH_END = 72;

    /// @dev A tick of ten percent of the price is not a tick, it is a doubling with a tick's
    /// name on it, and every trade under it would pay the charge. Real increments are one to
    /// a few hundred ppm; this ceiling is three orders of magnitude of headroom above them.
    uint256 private constant MAX_TICK_PPM = 100_000;

    /// @dev The clamp that makes the buy branch's square safe. Without it a `dx` at the
    /// uint128 ceiling against a small `uWad` produces an `r` whose square overflows
    /// uint256, and every fuzz run with sane parameters passes while the configuration
    /// maximum reverts. `r <= 1e9` gives `r*r <= 1e18`, fifty-nine orders of magnitude
    /// inside uint256. This is the Bunni quadratic class in `research/traits/WARNINGS.md`.
    uint256 private constant MAX_R = 1e9;

    function quote(Ctx calldata c) external pure returns (uint24 addFeePpm, bytes32 newState) {
        newState = c.state; // stateless: a same-value SSTORE, not a clear

        uint256 tick = _bits(c.params, SH_TICK, 24);
        uint256 noise = _bits(c.params, SH_NOISE, 24);
        uint256 cap = _bits(c.params, SH_CAP, 24);

        // An unconfigured slot charges nothing rather than guessing. `validate` is the thing
        // that stops a launch being frozen this way in the first place.
        if (tick == 0 || noise == 0 || cap == 0) return (0, newState);
        if (c.uWad == 0 || c.tRes == 0) return (0, newState);

        uint256 movePpm;
        if (c.buying) {
            uint256 dx = _sizeU(c);
            // `_mulDiv128` bounds its INPUTS and not its OUTPUT, so a `_size*` result can
            // sit far above uint128 and take the multiply below with it: `uWad` 8,
            // `tRes` 2.10e35 and `specified` 2^128 - 1 gives about 8.9e72, and that times
            // PPM is 8.9e78 against a uint256 ceiling of 1.16e77. Clamp the RESULT.
            if (dx > U128_MAX) dx = U128_MAX;
            uint256 r = ((uint256(c.uWad) + dx) * PPM) / uint256(c.uWad);
            if (r > MAX_R) r = MAX_R;
            movePpm = ((r * r) / PPM) - PPM;
        } else {
            uint256 dy = _sizeT(c);
            if (dy > U128_MAX) dy = U128_MAX;
            uint256 s = (uint256(c.tRes) * PPM) / (uint256(c.tRes) + dy); // at most PPM
            movePpm = PPM - ((s * s) / PPM);
        }

        // RULE 5, and the tie is called deliberately. A move of EXACTLY one tick is a move
        // the book could have expressed, so it is free. The charge is for the shortfall, and
        // at one whole tick there is none.
        if (movePpm >= tick) return (0, newState);

        // `noise` is a uint24 and `movePpm` is under `tick`, which is at most 1e5, so the
        // product is under 1.7e12. The multiply happens before the divide so a fine tick
        // does not collapse the taper, and the division rounds DOWN, which never charges a
        // trader more than the schedule says.
        addFeePpm = _fee(noise - (noise * movePpm) / tick, cap);
    }

    function describe() external pure returns (string memory family, string memory name) {
        return ("physical", "TickRegime");
    }

    /// @dev Rejects the sentinel shapes that would silently disarm the mechanic (a zero
    /// tick, a zero charge, a zero cap), rejects a tick so coarse that no ordinary trade
    /// could ever clear it, rejects a charge above the cap so the headline number in the
    /// launch record is the number that gets charged rather than one silently clamped, and
    /// rejects any bit set above the last defined field. RULE 5: a parameter set to a
    /// reserved value is how float disarmed a quorum breaker on three markets by an exact tie
    /// on an inclusive comparison.
    function validate(bytes32 params) external pure returns (bool) {
        if (_above(params, SH_END) != 0) return false;
        uint256 tick = _bits(params, SH_TICK, 24);
        uint256 noise = _bits(params, SH_NOISE, 24);
        uint256 cap = _bits(params, SH_CAP, 24);
        if (!_inRange(cap, 1, MAX_ADD_PPM)) return false;
        if (!_inRange(tick, 1, MAX_TICK_PPM)) return false;
        if (!_inRange(noise, 1, cap)) return false;
        return true;
    }
}
