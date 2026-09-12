// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ITrait} from "../interfaces/ITrait.sol";
import {TraitBase} from "./TraitBase.sol";

/// @title TermTrait
/// @notice The shape of the curve, not the level of it, is what a carry market charges
/// you for.
///
/// WHAT THIS SAYS ABOUT THE UNDERLYING, IN PLAIN LANGUAGE
/// A futures market almost never quotes one price. It quotes a front month and a back
/// month, and the gap between them is the whole business. When the front is dearer than
/// the back the market is in contango: everyone wants the thing now, storage and money
/// are being paid for, and a fund that has to keep rolling its position sells the cheap
/// prompt contract and buys the dear one every month and bleeds. That bleed is why USO
/// tracked oil so badly through 2020 that the fund had to redesign itself. When the
/// front is cheaper than the back the market is in backwardation: the prompt unit is
/// scarce, and holding the physical thing pays you.
///
/// A launch on this chain has no second month to quote. What it does have is its own
/// history. This trait keeps a slow-moving anchor price, a time-weighted memory of where
/// the curve has been trading, and treats the gap between spot and that anchor as the
/// term structure. Spot above the anchor is contango: the front is rich, and the buyer
/// is the one paying up for immediacy, so the buyer pays the spread. Spot below the
/// anchor is backwardation: the prompt unit is scarce, and the seller is the one giving
/// up something worth more now than later, so the seller pays.
///
/// The fee is a fraction of the measured spread, so a market trading flat against its
/// own memory costs nothing at all, and a market that has run pays in proportion to how
/// far it ran. It is roll yield, expressed as a toll, on a venue with no second month.
///
/// @dev FAMILY: term.
///
/// @dev THE SPREAD IS MEASURED ON THE BOOK AS THE TRADER FOUND IT. `Ctx` carries the
/// pre-trade reserves, so the fee prices the dislocation that already existed and never
/// the trader's own impact. The curve already charges for size; charging twice would be
/// a size penalty wearing a term-structure costume. The consequence, stated plainly: the
/// trade that CREATES a dislocation escapes it and the next one pays. That is also how a
/// roll works, so it is the honest shape.
///
/// @dev THE ANCHOR IS A LINEAR TIME BLEND, NOT AN EXPONENTIAL. `anchor += (spot -
/// anchor) * min(dt, tau) / tau`, so after `tau` seconds with no trade the anchor is
/// fully refreshed to the last observed spot, and a trade one second after the previous
/// one barely moves it. No exponentials, no logarithms, no loops, no fixed-point library:
/// two multiplies and a divide, and the whole thing is exact in integers.
///
/// @dev MANIPULATION, AND WHY IT DOES NOT MATTER. Anyone can drag the anchor toward spot
/// by trading repeatedly, and doing so lowers the fee toward zero. That is the only
/// direction the manipulation runs: the anchor moving toward spot always narrows the
/// spread, and a narrower spread is always a smaller fee. The worst outcome an attacker
/// can buy is that the trait does nothing, which is the outcome of not installing it.
/// It can never raise the fee beyond `capPpm`, never move a reserve, and never refuse.
///
/// @dev NEVER REFUSES.
///
/// PARAMS, packed little end first into the frozen `bytes32`:
///   bits   0..23   sensePpm    uint24   1 .. 1000000   fraction of the spread charged
///   bits  24..47   capPpm      uint24   1 .. 100000
///   bits  48..79   tauSeconds  uint32   60 .. 31536000 anchor refresh time
///   bits  80..87   mode        uint8    0 or 1
///   bits  88..255  MUST BE ZERO
///
/// MODE
///   0  roll. Contango charges buys, backwardation charges sells. The directional read.
///   1  spread. Both sides pay. A pure volatility toll with no view in it.
///
/// STATE, packed:
///   bits   0..127  anchor price, underlying per token, 18 decimals
///   bits 128..167  timestamp of the last anchor update
///   bit      255   seeded. A zero word means the anchor has never been set.
///
/// WORKED SETTINGS
///   sensePpm 250000 (charge a quarter of the spread), capPpm 15000, tau 21600 (six
///   hours), mode 0. A 4% dislocation against a six hour memory costs the side that is
///   paying up 1%.
///
/// COST. Constant. One packed state read, four multiplies, three divides, one repack.
/// No loops. State changes on every swap that is not the first, so the hook's persist is
/// a dirty SSTORE.
contract TermTrait is TraitBase {
    uint256 private constant SH_SENSE = 0;
    uint256 private constant SH_CAP = 24;
    uint256 private constant SH_TAU = 48;
    uint256 private constant SH_MODE = 80;
    uint256 private constant SH_END = 88;

    uint256 private constant MODE_ROLL = 0;
    uint256 private constant MODE_SPREAD = 1;

    uint256 private constant MIN_TAU = 60;
    uint256 private constant MAX_TAU = 31_536_000; // one year
    uint256 private constant MAX_SENSE_PPM = 1_000_000;

    // State field positions.
    uint256 private constant ST_ANCHOR = 0;
    uint256 private constant ST_TS = 128;
    uint256 private constant ST_SEEDED = 255;

    function quote(Ctx calldata c) external pure returns (uint24 addFeePpm, bytes32 newState) {

        uint256 sense = _bits(c.params, SH_SENSE, 24);
        uint256 cap = _bits(c.params, SH_CAP, 24);
        uint256 tau = _bits(c.params, SH_TAU, 32);
        uint256 mode = _bits(c.params, SH_MODE, 8);

        uint256 spot = _priceU18(c);
        if (spot > U128_MAX) spot = U128_MAX;

        // An unpriceable book (no token reserve, or no underlying) leaves the anchor
        // exactly where it was and charges nothing. Never revert, never reseed on junk.
        if (spot == 0 || sense == 0 || cap == 0 || tau < MIN_TAU) {
            return (0, c.state);
        }

        uint256 anchor = _bits(c.state, ST_ANCHOR, 128);
        bool seeded = _bits(c.state, ST_SEEDED, 1) == 1;

        // First trade of the launch: there is no memory to measure against, so seed it
        // and charge nothing. A term structure needs two points and this is the first.
        if (!seeded || anchor == 0) {
            return (0, _pack(spot, c.ts));
        }

        uint256 lastTs = _bits(c.state, ST_TS, 40);
        uint256 dt = _satSub(c.ts, lastTs);
        uint256 w = dt >= tau ? PPM : (dt * PPM) / tau;

        bool contango = spot > anchor;
        uint256 diff = contango ? spot - anchor : anchor - spot;

        // diff <= 2^128 and PPM is 1e6, so diff * PPM is under 3.5e44. No overflow.
        uint256 spreadPpm = (diff * PPM) / anchor;

        uint256 moved = (diff * w) / PPM;
        uint256 anchorNew = contango ? anchor + moved : anchor - moved;
        newState = _pack(anchorNew, c.ts);

        // Who is paying up for immediacy.
        bool charged = mode == MODE_SPREAD || (contango ? c.buying : !c.buying);
        if (!charged) return (0, newState);

        // spreadPpm can be very large after a big move; sense is at most 1e6, so the
        // product is bounded by roughly 3.5e50 and the clamp catches the rest.
        addFeePpm = _fee((spreadPpm * sense) / PPM, cap);
    }

    function _pack(uint256 anchor, uint40 ts) private pure returns (bytes32) {
        if (anchor > U128_MAX) anchor = U128_MAX;
        return bytes32((uint256(1) << ST_SEEDED) | (uint256(ts) << ST_TS) | anchor);
    }

    function describe() external pure returns (string memory family, string memory name) {
        return ("term", "TermStructure");
    }

    /// @dev `tau` has a floor of 60 seconds. A tau small enough to refresh inside one
    /// block would make the anchor equal to spot forever and the spread identically
    /// zero, which is a trait that reads as installed and does nothing. That silent-noop
    /// shape is exactly what RULE 5 is about. Mode is an enum with two members and
    /// anything else is rejected rather than defaulted.
    function validate(bytes32 params) external pure returns (bool) {
        if (_above(params, SH_END) != 0) return false;
        uint256 sense = _bits(params, SH_SENSE, 24);
        uint256 cap = _bits(params, SH_CAP, 24);
        uint256 tau = _bits(params, SH_TAU, 32);
        uint256 mode = _bits(params, SH_MODE, 8);
        if (!_inRange(sense, 1, MAX_SENSE_PPM)) return false;
        if (!_inRange(cap, 1, MAX_ADD_PPM)) return false;
        if (!_inRange(tau, MIN_TAU, MAX_TAU)) return false;
        if (mode > MODE_SPREAD) return false;
        return true;
    }
}
