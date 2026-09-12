// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TraitBase} from "./TraitBase.sol";

/// @title LockupTrait
/// @notice The date the insiders are allowed to sell is on the calendar from day one.
///
/// WHAT THIS SAYS ABOUT THE UNDERLYING, IN PLAIN LANGUAGE
/// When a company goes public, the people who already owned it are not allowed to sell. The
/// underwriting agreement locks them up, almost always for 180 days, and quite often in two
/// pieces: a slice released at 90 days if the stock is above some level, the rest at 180.
/// Everybody knows the date. It is in the prospectus. It is on every calendar on every desk
/// on the street, and on the morning it expires the float can double.
///
/// What happens then is not a mystery either, and it is one of the most studied events in
/// finance: volume jumps, the spread widens, and the price drifts down by a low single-digit
/// percentage around the unlock even though the date was public for six months. The market
/// knows, and it still costs something, because knowing a lot of stock is coming and having
/// somewhere to put it are different problems.
///
/// The pre-IPO tier in `data/GENESIS-50.md` is twelve private companies, and this is
/// literally true of every one of them: Anthropic, ByteDance, Databricks, Stripe, Shein.
/// If any of them lists, there is a lockup, and it has a date.
///
/// So a launch carrying this structure has an unlock on its calendar, frozen at launch,
/// visible in the launch record from the first block. On that date selling gets expensive
/// and then gets cheaper again over the following days, exactly the shape of the real event:
/// a cliff, then a taper as the supply is absorbed.
///
/// @dev FAMILY: supply. It is the supply shock with a date on it, which is the only kind
/// anybody can plan around.
///
/// @dev ASYMMETRIC. SELLS PAY, BUYS ARE FREE. An unlock is a one-directional flow: the
/// released holders are sellers, and the buyer is the party providing the liquidity the
/// unlock needs. Charging the buyer would be charging the only person helping. This is the
/// same reading `SpoilageTrait` makes when it says buying clears the shelf.
///
/// @dev STATELESS, AND COMPLETELY PREDICTABLE. Everything is measured from `launchedAt`,
/// which is frozen, so the whole schedule is a function of age and nothing else. A UI can
/// draw every future day of it at launch, years out, and `c.state` is returned untouched so
/// the hook pays a same-value SSTORE rather than a dirty one.
///
/// @dev TWO CLIFFS, AND OVERLAPS TAKE THE MAXIMUM. Staged releases are the norm rather than
/// the exception, so a second date is supported and may carry its own peak. If the two
/// tapers overlap, the trader pays the higher of the two and not the sum: two tranches
/// landing in the same week is still one crowded exit as far as a price is concerned. That
/// is `OutageTrait`'s rule for the same reason.
///
/// @dev NO ANTICIPATION RAMP, DELIBERATELY. The literature finds some of the drift arrives
/// BEFORE the date, which argues for charging into the cliff as well as out of it. It is not
/// done here, for a reason worth stating: a charge that begins before the event is
/// indistinguishable in shape from the launch-window taper this project explicitly dropped
/// (`CATALOGUE.md` section 13, and the anti-snipe tax in `CLAUDE.md`), and once a structure
/// can charge before a date it is one parameter away from charging from block one. The
/// cliff is the event. Everything before it is free.
///
/// @dev NEVER REFUSES. The worst this structure can do to a seller on the worst day of the
/// schedule is `capPpm`, and every other day of the launch's life it does nothing at all.
///
/// PARAMS, packed little end first into the frozen `bytes32`:
///   bits    0..23   peak1Ppm    uint24   1 .. capPpm     charge at the first unlock
///   bits   24..39   day1        uint16   1 .. 3650       days from launch to it
///   bits   40..63   peak2Ppm    uint24   0 .. capPpm     charge at the second unlock
///   bits   64..79   day2        uint16   0 .. 3650       0 means there is no second one
///   bits   80..95   taperDays   uint16   1 .. 365        how long each cliff takes to fade
///   bits   96..119  capPpm      uint24   1 .. 600000
///   bits  120..255  MUST BE ZERO
///
/// WORKED SETTINGS
///   The ordinary underwriting agreement, in our units:
///     peak1Ppm 30000 (3%), day1 180, peak2Ppm 0, day2 0, taperDays 14, capPpm 30000.
///   Nothing for the first 180 days. On day 180 a sale costs 3%, on day 187 it costs 1.5%,
///   on day 194 it is gone and never comes back.
///   The staged version, which is the more common shape for a hot listing:
///     peak1Ppm 10000 (1%), day1 90, peak2Ppm 30000 (3%), day2 180, taperDays 14,
///     capPpm 30000. A small slice at 90 days and the real one at 180.
///
/// COST. Constant. Two subtractions, two multiplies, two divides, one comparison, one
/// clamp. No loops, no branches on trader input beyond the side of the trade, no state
/// transition.
contract LockupTrait is TraitBase {
    uint256 private constant SH_PEAK1 = 0;
    uint256 private constant SH_DAY1 = 24;
    uint256 private constant SH_PEAK2 = 40;
    uint256 private constant SH_DAY2 = 64;
    uint256 private constant SH_TAPER = 80;
    uint256 private constant SH_CAP = 96;
    uint256 private constant SH_END = 120;

    /// @dev Ten years. A lockup date beyond that is not a lockup, it is a date the launch
    /// will not live to see, and a schedule nobody will ever reach is a line in the launch
    /// record that means nothing.
    uint256 private constant MAX_DAYS = 3650;
    uint256 private constant MAX_TAPER_DAYS = 365;

    function quote(Ctx calldata c) external pure returns (uint24 addFeePpm, bytes32 newState) {
        newState = c.state;

        uint256 peak1 = _bits(c.params, SH_PEAK1, 24);
        uint256 day1 = _bits(c.params, SH_DAY1, 16);
        uint256 taperDays = _bits(c.params, SH_TAPER, 16);
        uint256 cap = _bits(c.params, SH_CAP, 24);

        // An unconfigured slot charges nothing rather than guessing. `validate` is the
        // thing that stops a launch being frozen this way in the first place.
        if (peak1 == 0 || day1 == 0 || taperDays == 0 || cap == 0) return (0, newState);

        // The buyer at an unlock is the liquidity, not the event.
        if (c.buying) return (0, newState);

        uint256 age = _satSub(c.ts, c.launchedAt);
        uint256 taper = taperDays * DAY;

        uint256 raw = _cliff(age, day1 * DAY, peak1, taper);

        uint256 day2 = _bits(c.params, SH_DAY2, 16);
        if (day2 != 0) {
            uint256 second = _cliff(age, day2 * DAY, _bits(c.params, SH_PEAK2, 24), taper);
            if (second > raw) raw = second;
        }

        addFeePpm = _fee(raw, cap);
    }

    /// @notice One cliff: nothing before `at`, `peak` on it, a straight line to zero over
    /// `taper` seconds after it, and nothing ever again.
    /// @dev `peak` is a uint24 and `taper` is at most 365 days, so the product is under
    /// 5.3e14 and cannot overflow. The multiplication is done before the division so the
    /// taper does not collapse to zero on a short window, and the result rounds DOWN, which
    /// is the direction that never charges a seller more than the schedule says.
    function _cliff(uint256 age, uint256 at, uint256 peak, uint256 taper) private pure returns (uint256) {
        if (peak == 0 || age < at) return 0;
        uint256 into = age - at;
        if (into >= taper) return 0;
        return peak - (peak * into) / taper;
    }

    function describe() external pure returns (string memory family, string memory name) {
        return ("supply", "Lockup");
    }

    /// @dev Rejects the sentinel shapes that would silently disarm the mechanic (a zero
    /// peak, a zero date, a zero taper, a zero cap), rejects a peak above the cap so the
    /// headline number in the launch record is the number that gets charged rather than one
    /// silently clamped, rejects a half-configured second tranche in either direction (a
    /// date with no charge, or a charge with no date), rejects a second unlock at or before
    /// the first, and rejects any bit set above the last defined field. RULE 5: a parameter
    /// set to a reserved value is how float disarmed a quorum breaker on three markets by an
    /// exact tie on an inclusive comparison.
    function validate(bytes32 params) external pure returns (bool) {
        if (_above(params, SH_END) != 0) return false;
        uint256 peak1 = _bits(params, SH_PEAK1, 24);
        uint256 day1 = _bits(params, SH_DAY1, 16);
        uint256 peak2 = _bits(params, SH_PEAK2, 24);
        uint256 day2 = _bits(params, SH_DAY2, 16);
        uint256 taperDays = _bits(params, SH_TAPER, 16);
        uint256 cap = _bits(params, SH_CAP, 24);

        if (!_inRange(cap, 1, MAX_ADD_PPM)) return false;
        if (!_inRange(peak1, 1, cap)) return false;
        if (!_inRange(day1, 1, MAX_DAYS)) return false;
        if (!_inRange(taperDays, 1, MAX_TAPER_DAYS)) return false;
        if (day2 == 0) {
            if (peak2 != 0) return false;
        } else {
            if (!_inRange(peak2, 1, cap)) return false;
            if (day2 <= day1 || day2 > MAX_DAYS) return false;
        }
        return true;
    }
}
