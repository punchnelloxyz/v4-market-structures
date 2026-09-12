// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TraitBase} from "./TraitBase.sol";

/// @title WitchingTrait
/// @notice Four days a year, everything expires at once, and the whole market knows it.
///
/// WHAT THIS SAYS ABOUT THE UNDERLYING, IN PLAIN LANGUAGE
/// On the third Friday of March, June, September and December, stock index futures, stock
/// index options and single stock options all expire on the same morning. The street has
/// called it triple witching since the 1980s, when there were three of them expiring
/// together, and the name stuck through every change to the list. On those four days the
/// closing volume is a multiple of an ordinary day's, the rebalancing prints go through at
/// the bell, and the spread on everything widens because every dealer on the desk is
/// unwinding a hedge against a settlement print rather than making a market.
///
/// It is not a crisis and nobody is surprised by it. It is a scheduled congestion event,
/// four times a year, on a date that has been known since the exchange listed the contract.
/// The third Friday of every OTHER month is the smaller version of the same thing, monthly
/// expiry, and a launcher who wants that instead can have it.
///
/// A launch carrying this structure is dearer to trade on the expiry and, if the launcher
/// wants it, on the run-up to the expiry. Every other day of the year it charges nothing.
///
/// @dev FAMILY: term. An expiry is the term structure arriving.
///
/// @dev THE COUPLING IS THE POINT, NOT A SIDE EFFECT. Every structure in this directory
/// keys off something private to its own launch: `launchedAt`, `poolId`, its own reserves,
/// its own last trade. This one keys off nothing but the calendar, so EVERY launch carrying
/// it fires on the same four days at the same instant, together, venue-wide. That is a
/// deliberate shared epoch and it is the one honest way to express the thing being modelled,
/// because triple witching is not a property of a stock, it is a property of the date. The
/// consequence is a correlated fee spike across every pool carrying the structure, which is
/// precisely what happens in the real market and precisely why the day has a name.
///
/// @dev SYMMETRIC. Buys and sells pay the same. An expiry widens the spread, and a spread
/// is not directional.
///
/// @dev STATELESS AND PURELY CALENDRICAL. There is no state, no reserve read, no price and
/// no memory: the answer is a function of `Ctx.ts` and the frozen params alone, so `c.state`
/// is returned untouched and the hook pays a same-value SSTORE. Two launches on the same day
/// with the same params give the same answer, which is what a calendar means.
///
/// @dev THE DATE ARITHMETIC IS EXACT AND EMBEDDED, WITH NO TABLE. The third Friday needs
/// only the civil month and day, which come from Howard Hinnant's days-from-civil algorithm
/// inverted, and the weekday, which is `(days + 4) % 7` because 1 January 1970 was a
/// Thursday. There is no holiday table and no data contract, so nothing here can go stale
/// the way `CALENDAR.md` section 4 warns an embedded holiday table will: the third Friday of
/// March is the third Friday of March in every year of the Gregorian calendar, forever, and
/// no legislature can move it.
///
/// @dev NEVER `block.number`. It returns the L1 block on this ArbOS chain, currently about
/// 31.4 million behind the L2 height, and a Foundry fork test does NOT reproduce that
/// because it seeds the number from the L2 block. Every schedule here is `Ctx.ts`.
///
/// @dev THE ONE INACCURACY, STATED RATHER THAN DISCOVERED. `tzOffsetMin` is a FIXED offset
/// and there is no daylight saving table, so for the part of the year the launcher's venue
/// is on summer time the day boundary is one hour out. The error lands at midnight local,
/// which is the least interesting hour of an expiry day, and it moves a boundary rather than
/// a level. Embedding a DST table would fix it and would then itself go stale if a
/// legislature abolished the clock change, which `CALENDAR.md` section 4 sets out at length.
/// One hour at midnight, four times a year, is the cheaper error.
///
/// PARAMS, packed little end first into the frozen `bytes32`:
///   bits    0..23   witchPpm    uint24   1 .. capPpm   charged on the expiry itself
///   bits   24..47   evePpm      uint24   0 .. witchPpm charged on the run-up
///   bits   48..71   capPpm      uint24   1 .. 600000
///   bits   72..79   eveDays     uint8    0 .. 7        length of the run-up, 0 for none
///   bits   80..87   monthly     uint8    0 or 1        0 quarterly only, 1 every month
///   bits   88..103  tzOffsetMin uint16   0 .. 2880     local offset in minutes, plus 1440
///   bits  104..255  MUST BE ZERO
///
/// WORKED SETTINGS
///   Triple witching on New York time, which is what almost every underlying here trades on:
///     witchPpm 20000 (2%), evePpm 5000 (0.5%), capPpm 20000, eveDays 2, monthly 0,
///     tzOffsetMin 1140 (which is -300 minutes, five hours behind UTC).
///   Four days a year at 2%, eight more at 0.5%, and 353 days at nothing.
///   Monthly expiry for a launch that wants the smaller event twelve times instead:
///     witchPpm 8000, evePpm 0, capPpm 8000, eveDays 0, monthly 1, tzOffsetMin 1140.
///
/// COST. Constant. One division to the day index, six divisions in the civil conversion,
/// three modulos and a handful of comparisons. No loops, no state, no external read.
contract WitchingTrait is TraitBase {
    uint256 private constant SH_WITCH = 0;
    uint256 private constant SH_EVE = 24;
    uint256 private constant SH_CAP = 48;
    uint256 private constant SH_EVEDAYS = 72;
    uint256 private constant SH_MONTHLY = 80;
    uint256 private constant SH_TZ = 88;
    uint256 private constant SH_END = 104;

    /// @dev `tzOffsetMin` is stored offset-encoded so it can be negative without a signed
    /// field: the stored value is the real offset in minutes plus this. 1440 minutes is a
    /// whole day, which covers every real venue with eleven hours to spare on both sides.
    uint256 private constant TZ_BIAS = 1440;
    uint256 private constant MAX_TZ = 2880;

    /// @dev A run-up longer than this could reach into the previous month, since the third
    /// Friday is never earlier than the 15th. Seven days keeps every eve day inside the
    /// expiry's own month, which is what makes the day arithmetic a single lookup.
    uint256 private constant MAX_EVE_DAYS = 7;

    /// @dev 1 January 1970 was a Thursday, so `(days + 4) % 7` is 0 for Sunday.
    uint256 private constant FRIDAY = 5;

    function quote(Ctx calldata c) external pure returns (uint24 addFeePpm, bytes32 newState) {
        newState = c.state; // stateless: a same-value SSTORE, not a clear

        uint256 witchPpm = _bits(c.params, SH_WITCH, 24);
        uint256 cap = _bits(c.params, SH_CAP, 24);

        // An unconfigured slot charges nothing rather than guessing a default.
        if (witchPpm == 0 || cap == 0) return (0, newState);

        uint256 tz = _bits(c.params, SH_TZ, 16);
        uint256 localTs = tz >= TZ_BIAS
            ? uint256(c.ts) + (tz - TZ_BIAS) * 60
            : _satSub(uint256(c.ts), (TZ_BIAS - tz) * 60);

        uint256 dayIdx = localTs / DAY;
        (uint256 month, uint256 dayOfMonth) = _monthDay(dayIdx);

        // March, June, September, December, unless the launcher asked for every month.
        if (_bits(c.params, SH_MONTHLY, 8) == 0 && month % 3 != 0) return (0, newState);

        // The weekday of the 1st, from the weekday of today, then the first Friday, then
        // the third. The third Friday is always between the 15th and the 21st inclusive,
        // which is the property that keeps the run-up inside the same month.
        uint256 dow = (dayIdx + 4) % 7;
        uint256 firstDow = (dow + 7 - ((dayOfMonth - 1) % 7)) % 7;
        uint256 third = 15 + ((FRIDAY + 7 - firstDow) % 7);

        if (dayOfMonth == third) return (_fee(witchPpm, cap), newState);

        uint256 eveDays = _bits(c.params, SH_EVEDAYS, 8);
        if (eveDays != 0 && dayOfMonth < third && third - dayOfMonth <= eveDays) {
            return (_fee(_bits(c.params, SH_EVE, 24), cap), newState);
        }

        return (0, newState);
    }

    /// @notice Civil month and day of month for a day index counted from 1 January 1970.
    /// @dev Howard Hinnant's `civil_from_days`, public domain, with the year dropped
    /// because nothing here needs it. Every intermediate is non-negative for any date at or
    /// after 1 March of year zero, which every timestamp this chain can produce is, so the
    /// unsigned form cannot underflow. Six divisions and no table.
    function _monthDay(uint256 dayIdx) private pure returns (uint256 month, uint256 dayOfMonth) {
        uint256 z = dayIdx + 719_468;
        uint256 era = z / 146_097;
        uint256 doe = z - era * 146_097; // day of era, 0 .. 146096
        uint256 yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365; // 0 .. 399
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // 0 .. 365, March based
        uint256 mp = (5 * doy + 2) / 153; // 0 .. 11, March is 0
        dayOfMonth = doy - (153 * mp + 2) / 5 + 1; // 1 .. 31
        month = mp < 10 ? mp + 3 : mp - 9; // 1 .. 12
    }

    function describe() external pure returns (string memory family, string memory name) {
        return ("term", "Witching");
    }

    /// @dev Rejects the sentinel shapes that would silently disarm the mechanic (a zero
    /// expiry charge, a zero cap), rejects an expiry charge above the cap so the headline
    /// number in the launch record is the number that gets charged rather than one silently
    /// clamped, rejects a run-up dearer than the day it is running up to (which would make
    /// the expiry the cheap part of expiry week), rejects a half-configured run-up in either
    /// direction, rejects a run-up long enough to reach into the previous month, rejects a
    /// timezone outside a whole day either side, and rejects any bit set above the last
    /// defined field.
    function validate(bytes32 params) external pure returns (bool) {
        if (_above(params, SH_END) != 0) return false;
        uint256 witchPpm = _bits(params, SH_WITCH, 24);
        uint256 evePpm = _bits(params, SH_EVE, 24);
        uint256 cap = _bits(params, SH_CAP, 24);
        uint256 eveDays = _bits(params, SH_EVEDAYS, 8);
        uint256 monthly = _bits(params, SH_MONTHLY, 8);
        uint256 tz = _bits(params, SH_TZ, 16);

        if (!_inRange(cap, 1, MAX_ADD_PPM)) return false;
        if (!_inRange(witchPpm, 1, cap)) return false;
        if (eveDays == 0) {
            if (evePpm != 0) return false;
        } else {
            if (eveDays > MAX_EVE_DAYS) return false;
            if (!_inRange(evePpm, 1, witchPpm)) return false;
        }
        if (monthly > 1) return false;
        if (tz > MAX_TZ) return false;
        return true;
    }
}
