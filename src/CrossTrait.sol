// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TraitBase} from "./TraitBase.sol";

/// @title CrossTrait
/// @notice A real exchange does not open by trading. It opens by crossing, and the first
/// minutes of a session are nothing like the middle of one.
///
/// WHAT THIS SAYS ABOUT THE UNDERLYING, IN PLAIN LANGUAGE
/// The New York Stock Exchange does not start the day by matching the first two orders that
/// arrive. It runs an opening auction: orders accumulate, an indicative price is published,
/// and at the bell everything crosses at one price. It ends the day the same way, and the
/// closing cross is now the single largest liquidity event on the tape, because every index
/// fund on earth has to print at the official close. Every venue on the list in
/// `research/traits/CALENDAR.md` section 6 does some version of this, and the ones that do
/// not run an auction still have the same shape in their spreads.
///
/// The shape is the oldest finding in market microstructure and it has a name: the intraday
/// U. Spreads and volatility are widest at the open, narrow through the middle of the
/// session, and widen again into the close. The reason is not mysterious. At the open,
/// nobody knows where the price is yet and the overnight news has not been traded. Into the
/// close, everybody with an on-close obligation is trying to discharge it against everybody
/// else's imbalance.
///
/// So a launch carrying this structure is dear to trade in the first seconds of its session,
/// cheapening steadily as continuous trading takes over, free through the middle of the day,
/// and dear again as the closing cross approaches. It is the honest price of trading against
/// a book that has not found its level yet, or one that is about to be run over by the bell.
///
/// @dev FAMILY: term. A session is the shortest term structure there is.
///
/// @dev SYMMETRIC. Buys and sells pay the same. An auction is a crossing, not a direction,
/// and a one-sided auction fee would be a directional bet wearing an exchange's clothes.
///
/// @dev STATELESS. The whole answer is `(ts + phase) mod session`, so `c.state` is returned
/// untouched and the hook pays a same-value SSTORE. Nothing here can drift, nothing needs an
/// autostart rule, and a launch that has not traded for a year gets exactly the same schedule
/// as one that trades every block. That is `CATALOGUE.md` entry 14 not applying, rather than
/// being ignored.
///
/// @dev TWO RAMPS FACING OPPOSITE WAYS, WHICH IS THE WHOLE DESIGN. The opening charge is
/// largest at the bell and TAPERS DOWN across `openSec`, because uncertainty resolves as the
/// session finds its price. The closing charge RAMPS UP across `closeSec`, because the
/// imbalance builds into the cross. Making both of them decay, or both of them ramp, would
/// get one of the two ends of the U backwards.
///
/// @dev THE WINDOWS CANNOT OVERLAP, AND WHERE THEY WOULD, THE HIGHER ONE WINS. `validate`
/// holds `openSec + closeSec` to half the session, so a session always has a continuous
/// middle that costs nothing. The maximum is taken anyway rather than the sum, because a
/// configuration that never reached `validate` must still degrade to a bounded answer.
///
/// @dev HOW TO ALIGN IT TO A REAL BELL. `phaseSec` shifts the session start. For a daily
/// session (`sessionSec` 86400) aligned to the NYSE open at 13:30 UTC, the number is
/// `86400 - 48600 = 37800`, since 13:30 UTC is 48,600 seconds into the UTC day. There is no
/// daylight saving table here, so the alignment drifts by an hour for the part of the year
/// the venue is on summer time. That is a boundary error and not a level error: the schedule
/// keeps its shape and its cap, it just runs an hour early. `CALENDAR.md` section 4 sets out
/// why an embedded table is not obviously the better trade.
///
/// @dev THIS IS NOT `Toll`. `CATALOGUE.md` section 9 catalogues a privileged window during
/// which trading is CHEAP and outside which it is dear, taken from Angstrom's unlock. This
/// is the opposite sign and a different claim: there is no privileged window, the middle of
/// the session is the free part, and the auctions are what cost. A launcher installs one or
/// the other.
///
/// @dev NEVER `block.number`. Every boundary here is `Ctx.ts`.
///
/// PARAMS, packed little end first into the frozen `bytes32`:
///   bits    0..31   sessionSec  uint32   3600 .. 604800
///   bits   32..63   phaseSec    uint32   0 .. sessionSec - 1
///   bits   64..79   openSec     uint16   0 .. 65535    length of the opening cross
///   bits   80..103  openPpm     uint24   0 .. capPpm   charge at the bell
///   bits  104..119  closeSec    uint16   0 .. 65535    length of the closing cross
///   bits  120..143  closePpm    uint24   0 .. capPpm   charge in the last second
///   bits  144..167  capPpm      uint24   1 .. 600000
///   bits  168..255  MUST BE ZERO
///
/// WORKED SETTINGS
///   A daily session on New York's clock, both auctions priced:
///     sessionSec 86400, phaseSec 37800, openSec 900 (fifteen minutes), openPpm 15000
///     (1.5%), closeSec 600 (ten minutes), closePpm 20000 (2%), capPpm 20000.
///   The first second after the bell costs 1.5% and it is gone fifteen minutes later. The
///   middle twenty-three hours cost nothing. The last second before the next bell costs 2%,
///   which is the real ordering: the closing cross is the bigger event.
///
/// COST. Constant. One addition, one modulo, at most two multiplies and two divides, one
/// comparison, one clamp. No loops, no state transition, no branch on trader input at all.
contract CrossTrait is TraitBase {
    uint256 private constant SH_SESSION = 0;
    uint256 private constant SH_PHASE = 32;
    uint256 private constant SH_OPENSEC = 64;
    uint256 private constant SH_OPENPPM = 80;
    uint256 private constant SH_CLOSESEC = 104;
    uint256 private constant SH_CLOSEPPM = 120;
    uint256 private constant SH_CAP = 144;
    uint256 private constant SH_END = 168;

    /// @dev A session shorter than an hour is not a session, it is a metronome, and a
    /// launcher who wants a recurring toll rather than a market clock should say so with a
    /// structure that admits to being one.
    uint256 private constant MIN_SESSION = 3600;
    uint256 private constant MAX_SESSION = 604_800; // one week

    function quote(Ctx calldata c) external pure returns (uint24 addFeePpm, bytes32 newState) {
        newState = c.state; // stateless: a same-value SSTORE, not a clear

        uint256 session = _bits(c.params, SH_SESSION, 32);
        uint256 cap = _bits(c.params, SH_CAP, 24);
        uint256 openSec = _bits(c.params, SH_OPENSEC, 16);
        uint256 closeSec = _bits(c.params, SH_CLOSESEC, 16);

        // An unconfigured or unusable slot charges nothing rather than guessing a default.
        if (cap == 0 || session < MIN_SESSION) return (0, newState);
        if (openSec == 0 && closeSec == 0) return (0, newState);
        // A pair of windows that fills the session is a flat fee wearing a costume.
        // `validate` rejects it; this is what happens if one ever gets past.
        if (openSec + closeSec >= session) return (0, newState);

        // `ts` is a uint40 and `phase` a uint32, so the sum is under 2^41 and the modulo is
        // exact. Never `block.number`: on this ArbOS chain it is the L1 block.
        uint256 into = (uint256(c.ts) + _bits(c.params, SH_PHASE, 32)) % session;

        uint256 raw = 0;

        // The opening cross, widest at the bell and tapering as the session settles.
        if (into < openSec) {
            uint256 openPpm = _bits(c.params, SH_OPENPPM, 24);
            // `openPpm` is a uint24 and `into` is under 2^16, so the product is under
            // 1.1e12. The multiply happens before the divide so a short window does not
            // collapse the taper to zero.
            raw = openPpm - (openPpm * into) / openSec;
        }

        // The closing cross, building into the bell. `toClose` runs from `session` down to
        // 1, so the last second of the session is `toClose == 1` and pays the whole charge.
        uint256 toClose = session - into;
        if (toClose <= closeSec) {
            uint256 closePpm = _bits(c.params, SH_CLOSEPPM, 24);
            uint256 built = (closePpm * (closeSec - toClose + 1)) / closeSec;
            if (built > raw) raw = built;
        }

        addFeePpm = _fee(raw, cap);
    }

    function describe() external pure returns (string memory family, string memory name) {
        return ("term", "Cross");
    }

    /// @dev Rejects a zero cap, rejects a session too short to be one or long enough to
    /// outlive a launch's attention span, rejects a phase outside the session it is phasing
    /// (a phase past the period is the same phase wearing a bigger number, and a launch
    /// record should not carry a number that does not mean what it says), rejects a
    /// half-configured auction in either direction (a window with no charge, or a charge
    /// with no window), rejects auctions that take up more than half the session so there is
    /// always a continuous middle that costs nothing, rejects either charge above the cap so
    /// the headline numbers are the ones that get charged, and rejects any bit set above the
    /// last defined field.
    function validate(bytes32 params) external pure returns (bool) {
        if (_above(params, SH_END) != 0) return false;
        uint256 session = _bits(params, SH_SESSION, 32);
        uint256 phase = _bits(params, SH_PHASE, 32);
        uint256 openSec = _bits(params, SH_OPENSEC, 16);
        uint256 openPpm = _bits(params, SH_OPENPPM, 24);
        uint256 closeSec = _bits(params, SH_CLOSESEC, 16);
        uint256 closePpm = _bits(params, SH_CLOSEPPM, 24);
        uint256 cap = _bits(params, SH_CAP, 24);

        if (!_inRange(cap, 1, MAX_ADD_PPM)) return false;
        if (!_inRange(session, MIN_SESSION, MAX_SESSION)) return false;
        if (phase >= session) return false;
        if ((openSec == 0) != (openPpm == 0)) return false;
        if ((closeSec == 0) != (closePpm == 0)) return false;
        if (openSec == 0 && closeSec == 0) return false;
        if (openPpm > cap || closePpm > cap) return false;
        if (openSec + closeSec > session / 2) return false;
        return true;
    }
}
