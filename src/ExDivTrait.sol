// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TraitBase} from "./TraitBase.sol";

/// @title ExDivTrait
/// @notice On one specific morning a quarter, the price is lower and nothing has gone wrong.
///
/// WHAT THIS SAYS ABOUT THE UNDERLYING, IN PLAIN LANGUAGE
/// A dividend is the only scheduled discontinuity in an equity price. On the ex-dividend
/// date the stock opens lower by roughly the dividend, because the buyer that morning is
/// buying something that no longer carries the payment. Exchanges adjust every resting limit
/// order for it overnight. It is arithmetic, it is on the calendar months in advance, and
/// nobody calls it a crash.
///
/// Almost everything listed on this chain does it. SPY, VTI, SCHD and SPMO step quarterly.
/// SGOV and SHY step monthly, which is why a treasury fund's chart looks like a saw. GLD,
/// SLV and USO never do, because a bar of metal does not pay you anything, and a launcher
/// against those should not install this.
///
/// The awkward part is the one this structure prices. The underlying steps down on a known
/// date. The curve does not, because a curve moves when somebody trades it and for no other
/// reason. So for the hours around the step there is a book quoting a claim on an asset that
/// just got smaller, and whoever trades across that boundary is trading against a mark from
/// the other side of it. A dealer facing a known discontinuity in something they cannot
/// re-mark widens, holds the wider price until the tape catches up, and then narrows again.
/// That is exactly the shape here: a step at the ex-instant, then a straight line back to
/// nothing over the following hours.
///
/// @dev FAMILY: term. A dividend is a term structure input before it is anything else; it is
/// the whole reason a forward price is not the spot price.
///
/// @dev SYMMETRIC. Both sides pay in the window. The step is not directional: one side is
/// buying a claim about to shrink and the other is selling one that already has, and which
/// of them is wrong depends entirely on where in the window the trade lands. Charging one
/// side would be taking a view on that, and this structure does not have one.
///
/// @dev THE CLIFF IS DELIBERATE, WHICH IS UNUSUAL IN THIS DIRECTORY. `CATALOGUE.md` section
/// 12 makes the case against thresholds in general: a cliff is a place to stand, and float
/// disarmed a circuit breaker on three markets by landing exactly on one. It is right about
/// fee curves that are approximating something continuous. This is not one. THE DIVIDEND IS
/// A CLIFF. The price genuinely does step, at an instant, by a known amount, and smoothing
/// the charge into the run-up would be modelling something that does not happen. The far
/// edge of the window is continuous because that side IS a taper: it is the market catching
/// up, which takes time.
///
/// @dev STATELESS, AND THE WHOLE SCHEDULE IS FROZEN AT LAUNCH. Every ex-date is
/// `launchedAt + phaseDays + n * periodDays`, so a UI can draw the next twenty years of them
/// on launch day. `c.state` is returned untouched and the hook pays a same-value SSTORE.
///
/// @dev IT DOES NOT KNOW A DIVIDEND WAS PAID, AND DOES NOT PRETEND TO. There is no oracle in
/// this project and no attestation anywhere in the trust path, so nothing on chain can tell
/// this structure that a distribution actually happened, or was cut, or was special. What it
/// has is a schedule frozen at launch by whoever launched it, and if the real issuer changes
/// the calendar the schedule is wrong and stays wrong. That is a bounded, capped, fee-shaped
/// wrongness: the worst case is a charge on an ordinary day and no charge on a real one.
/// Under a design that could halt or refuse, the same drift would be a pool that stops
/// working on a date nobody can change. `CALENDAR.md` section 5 makes the identical argument
/// about unscheduled exchange closures.
///
/// @dev NEVER REFUSES.
///
/// PARAMS, packed little end first into the frozen `bytes32`:
///   bits    0..23   stepPpm      uint24   1 .. capPpm   charge at the ex-instant
///   bits   24..47   capPpm       uint24   1 .. 600000
///   bits   48..63   periodDays   uint16   1 .. 3650     the distribution cycle
///   bits   64..79   windowHours  uint16   1 .. 6 * periodDays
///   bits   80..95   phaseDays    uint16   0 .. 3650     launch to the first ex-date
///   bits   96..255  MUST BE ZERO
///
/// WORKED SETTINGS
///   The charge is meant to be the size of the step, so it is arithmetic on the underlying's
///   own published distribution rather than a number somebody liked. A broad index fund
///   yielding about 1.3% a year and paying quarterly steps about a quarter of that on each
///   ex-date, which is 3,250 ppm:
///     stepPpm 3250, capPpm 5000, periodDays 91, windowHours 12, phaseDays 30.
///   A dividend-oriented fund yielding about 3.6% and paying quarterly is 9,000 ppm a step:
///     stepPpm 9000, capPpm 10000, periodDays 91, windowHours 12, phaseDays 45.
///   A treasury fund distributing monthly at about 4.2% a year is 3,500 ppm a step:
///     stepPpm 3500, capPpm 5000, periodDays 30, windowHours 6, phaseDays 10.
///   The yields move; the arithmetic does not. Whoever freezes the parameters is asserting a
///   distribution they can defend, exactly as `CarryTrait` asserts a sponsor fee.
///
/// COST. Constant. Two saturating subtracts, one modulo, two multiplies, two divides, one
/// clamp. No loops, no branches on trader input, no state transition.
contract ExDivTrait is TraitBase {
    uint256 private constant SH_STEP = 0;
    uint256 private constant SH_CAP = 24;
    uint256 private constant SH_PERIOD = 48;
    uint256 private constant SH_WINDOW = 64;
    uint256 private constant SH_PHASE = 80;
    uint256 private constant SH_END = 96;

    uint256 private constant HOUR = 3600;

    /// @dev Ten years, in both the cycle and the phase. A distribution cycle longer than
    /// that is not a distribution cycle, and a first ex-date past it is a line in the launch
    /// record the launch will not live to reach.
    uint256 private constant MAX_DAYS = 3650;

    function quote(Ctx calldata c) external pure returns (uint24 addFeePpm, bytes32 newState) {
        newState = c.state; // stateless: a same-value SSTORE, not a clear

        uint256 step = _bits(c.params, SH_STEP, 24);
        uint256 cap = _bits(c.params, SH_CAP, 24);
        uint256 periodDays = _bits(c.params, SH_PERIOD, 16);
        uint256 windowHours = _bits(c.params, SH_WINDOW, 16);

        // An unconfigured slot charges nothing rather than guessing a default.
        if (step == 0 || cap == 0 || periodDays == 0 || windowHours == 0) return (0, newState);

        // `periodDays` is a uint16, so the period is under 5.7e9 seconds and the window is
        // under 2.4e8. Neither can overflow and neither is close to trying.
        uint256 period = periodDays * DAY;
        uint256 window = windowHours * HOUR;
        // A window that fills the cycle is a flat fee wearing a dividend's clothes.
        // `validate` rejects it; this is what happens if one ever gets past.
        if (window >= period) return (0, newState);

        uint256 age = _satSub(c.ts, c.launchedAt);
        uint256 phase = _bits(c.params, SH_PHASE, 16) * DAY;
        // Before the first ex-date there is nothing to price. `_satSub` is not used here
        // because the two branches mean different things: not yet due, versus due and past.
        if (age < phase) return (0, newState);

        uint256 into = (age - phase) % period;
        if (into >= window) return (0, newState);

        // A straight line from the whole step at the ex-instant to nothing at the far edge
        // of the window. The multiply happens before the divide so a short window does not
        // collapse the taper, and the division rounds DOWN, which is the direction that
        // never charges a trader more than the schedule says.
        addFeePpm = _fee(step - (step * into) / window, cap);
    }

    function describe() external pure returns (string memory family, string memory name) {
        return ("term", "ExDiv");
    }

    /// @dev Rejects the sentinel shapes that would silently disarm the mechanic (a zero
    /// step, a zero cap, a zero cycle, a zero window), rejects a step above the cap so the
    /// headline number in the launch record is the number that gets charged rather than one
    /// silently clamped, rejects a window longer than a quarter of the cycle so an ex-date
    /// stays an event rather than becoming the weather (which is `OutageTrait`'s rule, for
    /// the same reason), rejects a cycle or a phase beyond ten years, and rejects any bit set
    /// above the last defined field.
    /// @dev The window bound is written as `windowHours > periodDays * 6` because a quarter
    /// of `periodDays * 24` hours is exactly `periodDays * 6`, and doing the arithmetic in
    /// hours keeps both sides of the comparison in the units the parameters are quoted in.
    function validate(bytes32 params) external pure returns (bool) {
        if (_above(params, SH_END) != 0) return false;
        uint256 step = _bits(params, SH_STEP, 24);
        uint256 cap = _bits(params, SH_CAP, 24);
        uint256 periodDays = _bits(params, SH_PERIOD, 16);
        uint256 windowHours = _bits(params, SH_WINDOW, 16);
        uint256 phaseDays = _bits(params, SH_PHASE, 16);

        if (!_inRange(cap, 1, MAX_ADD_PPM)) return false;
        if (!_inRange(step, 1, cap)) return false;
        if (!_inRange(periodDays, 1, MAX_DAYS)) return false;
        if (windowHours == 0 || windowHours > periodDays * 6) return false;
        if (phaseDays > MAX_DAYS) return false;
        return true;
    }
}
