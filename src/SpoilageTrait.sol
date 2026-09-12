// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ITrait} from "../interfaces/ITrait.sol";
import {TraitBase} from "./TraitBase.sol";

/// @title SpoilageTrait
/// @notice Goods left on the shelf go off, and the shelf remembers how long it has been.
///
/// WHAT THIS SAYS ABOUT THE UNDERLYING, IN PLAIN LANGUAGE
/// Two true things about physical inventory, and they are the same thing seen twice.
///
/// A merchant with perishable stock treats a full shelf and an empty one completely
/// differently. Stock that has been sitting is worth less than stock that just arrived,
/// so the merchant will take almost anything to clear it, and will pay very little to
/// take more of it in. And a dealer in any market, physical or not, widens the spread
/// when the tape has gone quiet, because time since the last print is exactly the
/// interval over which the world moved and the dealer did not find out.
///
/// So: this pool's unsold inventory spoils. Every hour with no trade, the goods sitting
/// in the warehouse get a little older, and the trade that eventually happens is priced
/// against older goods. Coming to BUY is free, always, at any staleness, because you are
/// clearing the shelf and the merchant is glad to see you. Coming to SELL, and handing
/// back stock onto a shelf that is already stale, costs more the longer the quiet lasted.
/// Any trade, either way, resets the clock: the shelf has turned over, the goods are
/// fresh again.
///
/// The consequence is a market with a memory of its own quietness. After a dead week the
/// first buyer gets an ordinary price and the first seller pays for the week. It is not a
/// penalty for selling; it is a penalty for selling into a book that has not traded, and
/// it is exactly the asymmetry a dealer with perishable stock actually runs.
///
/// @dev FAMILY: physical.
///
/// @dev SPOILAGE SCALES WITH HOW FULL THE SHELF IS. The accrued rate is weighted by
/// `tRes / supply`, the fraction of the token supply still sitting in the pool. A launch
/// that has sold three quarters of its inventory carries a quarter of the spoilage,
/// because there is a quarter as much left to go off. That weight starts at 1.0 at
/// launch and is 0.25 at the graduation point, so the mechanic fades exactly as the
/// warehouse empties.
///
/// @dev A DUST TRADE DOES NOT CLEAR A SHELF, AND THIS IS ENFORCED. The naive version of
/// this mechanic keys on time since the last trade of any size, and is then defeated for
/// one wei: anybody about to sell into a stale book buys a dust amount first, resets the
/// clock, and pays nothing. So a trade refreshes the shelf only if it is at least
/// `minTradePpm` of the pool's own underlying reserve. Anything smaller is priced as
/// usual and leaves the clock exactly where it was, which means a run of dust sells each
/// pays the full accrued spoilage rather than the first one clearing it for the rest.
/// Setting `minTradePpm` to zero restores the naive behaviour deliberately, for a
/// launcher who wants it and knows what it costs.
///
/// @dev THE ONLY STATEFUL TRAIT THAT WRITES ON MOST SWAPS. `newState` is the timestamp
/// of this trade whenever the trade was big enough to refresh, so the hook's persist is a
/// dirty SSTORE (about 2,900 gas warm) on those. That is the price of the mechanic and it
/// is worth stating out loud rather than discovering in a gas report. Every other trait
/// here is either stateless or writes only on an epoch boundary.
///
/// @dev NEVER REFUSES. Fee only, and only on the sell side, so an exit is available in
/// every block. The worst this trait can do to a seller is `capPpm`.
///
/// PARAMS, packed little end first into the frozen `bytes32`:
///   bits   0..23   spoilPpmPerDay  uint24   1 .. 100000
///   bits  24..47   capPpm          uint24   1 .. 100000
///   bits  48..63   graceHours      uint16   0 .. 8760      quiet time that does not count
///   bits  64..87   minTradePpm     uint24   0 .. 1000000   size that counts as a turnover
///   bits  88..255  MUST BE ZERO
///
/// WORKED SETTINGS
///   A fast-turning name:   spoilPpmPerDay 2000, capPpm 20000, graceHours 12,
///                          minTradePpm 1000
///     Half a day of quiet is free. After that, 0.2% a day, saturating at 2% after ten
///     days of silence, and it takes a trade worth a tenth of a percent of the reserve
///     to call the shelf turned over.
///   A slow name:           spoilPpmPerDay 500,  capPpm 10000, graceHours 72,
///                          minTradePpm 5000
///     Three days free, then 0.05% a day, saturating at 1% after twenty days.
///
/// COST. Constant. One `_satSub` on timestamps, three multiplies, three divides, one
/// clamp. No loops, no branches on trader input beyond the buy/sell test.
contract SpoilageTrait is TraitBase {
    uint256 private constant SH_RATE = 0;
    uint256 private constant SH_CAP = 24;
    uint256 private constant SH_GRACE = 48;
    uint256 private constant SH_MINTRADE = 64;
    uint256 private constant SH_END = 88;

    uint256 private constant HOUR = 3600;
    uint256 private constant MAX_GRACE_HOURS = 8760; // one year

    function quote(Ctx calldata c) external pure returns (uint24 addFeePpm, bytes32 newState) {
        newState = c.state;

        uint256 ratePpmDay = _bits(c.params, SH_RATE, 24);
        uint256 cap = _bits(c.params, SH_CAP, 24);
        uint256 graceSec = _bits(c.params, SH_GRACE, 16) * HOUR;

        // An unconfigured slot charges nothing AND touches nothing, so it does not cost
        // the hook a dirty SSTORE for a mechanic that is not running.
        if (ratePpmDay == 0 || cap == 0) return (0, newState);

        // The clock resets on a trade of either side, but only if the trade was big
        // enough to count as the shelf turning over. See the note above: without this a
        // seller resets their own spoilage for one wei.
        uint256 minPpm = _bits(c.params, SH_MINTRADE, 24);
        if (minPpm == 0 || _sizeU(c) >= _mulDiv128(c.uWad, minPpm, PPM)) {
            newState = bytes32(uint256(c.ts));
        }

        // Buying clears the shelf. Free at every staleness, by construction.
        if (c.buying) return (0, newState);

        // A zero state word is a launch that has never traded. Age the shelf from the
        // launch itself rather than from block zero: a mapping answers an unknown key
        // with an all-zero struct and that is exactly the phantom-value trap (RULE 6).
        uint256 last = uint256(c.state);
        if (last == 0) last = c.launchedAt;

        uint256 idle = _satSub(c.ts, last);
        uint256 billable = _satSub(idle, graceSec);
        if (billable == 0) return (0, newState);

        // ratePpmDay <= 1e5 and billable is a timestamp difference under 2^40, so the
        // product is under 1.1e17 and cannot overflow.
        uint256 accrued = (ratePpmDay * billable) / DAY;

        // Weight by how much stock is actually sitting there. Both are uint128, so the
        // product is safe, and a zero supply degrades to zero fee rather than reverting.
        if (c.supply == 0) return (0, newState);
        accrued = _mulDiv128(accrued, c.tRes, c.supply);

        addFeePpm = _fee(accrued, cap);
    }

    function describe() external pure returns (string memory family, string memory name) {
        return ("physical", "Spoilage");
    }

    /// @dev A grace of zero is legitimate here (goods start spoiling the moment they
    /// land) so it is allowed, but a zero rate or a zero cap is an unconfigured slot and
    /// is rejected. The grace ceiling of one year exists so a launcher cannot freeze a
    /// window that outlives the launch and quietly turn the trait into a no-op that the
    /// launch record still advertises.
    function validate(bytes32 params) external pure returns (bool) {
        if (_above(params, SH_END) != 0) return false;
        uint256 rate = _bits(params, SH_RATE, 24);
        uint256 cap = _bits(params, SH_CAP, 24);
        uint256 grace = _bits(params, SH_GRACE, 16);
        uint256 minTrade = _bits(params, SH_MINTRADE, 24);
        if (!_inRange(rate, 1, MAX_ADD_PPM)) return false;
        if (!_inRange(cap, 1, MAX_ADD_PPM)) return false;
        if (grace > MAX_GRACE_HOURS) return false;
        // A turnover threshold at or above the whole reserve is a clock that can never
        // be reset, which is a permanent maximum fee wearing a parameter's clothes.
        if (minTrade > PPM / 2) return false;
        return true;
    }
}
