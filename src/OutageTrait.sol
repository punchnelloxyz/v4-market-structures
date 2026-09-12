// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ITrait} from "../interfaces/ITrait.sol";
import {TraitBase} from "./TraitBase.sol";

/// @title OutageTrait
/// @notice Things break without warning, and the price finds out before anybody does.
///
/// WHAT THIS SAYS ABOUT THE UNDERLYING, IN PLAIN LANGUAGE
/// Every physical market has the same hole in it. A refinery trips. A mine floods. A
/// compressor station fails, a cable parts, a smelter loses power for four hours. Nobody
/// scheduled it, nobody hedged it, and the spot price moves before the press release
/// does. Planned maintenance is on a calendar and the curve has already priced it; an
/// unplanned outage is the thing the curve cannot price, and that is exactly why it is
/// the event that pays.
///
/// So this launch has outages. Six an hour, twenty seconds each, and the clock that picks
/// them is not a clock anybody is watching. Inside one, the toll opens at its peak and
/// falls away by halves, so the trade that arrives first pays most and the market is back
/// to normal before the minute is out. Outside one, this trait charges nothing at all,
/// which is 96.7% of every hour.
///
/// It is the only mechanic in this directory whose cause is not visible on the chart, and
/// that is the honest part rather than the trick: an outage is not caused by trading. It
/// is caused by the world, and it lands on whoever happened to be at the screen.
///
/// @dev FAMILY: physical.
///
/// @dev THE SCHEDULE IS DETERMINISTIC AND PUBLIC, AND THAT IS NOT A BUG. A trait's answer
/// must be computable BEFORE the trade or `quote()` stops matching execution, so no fee
/// in this system can ever be genuinely unpredictable. Anyone who reads this contract can
/// compute every window for every launch for the next thousand years. What they cannot do
/// is compute them without bothering. This taxes inattention, not ignorance, and it is
/// better to say so here than to let someone discover it and call it a rug.
///
/// @dev THE DRAW. `keccak256(poolId, hourIndex)` seeds one hour. Six 32-bit fields are
/// taken from that seed and each is reduced into `[0, 3600 - windowSec]`. 32 bits gives a
/// modulo bias under 0.0001%, where 12 bits (the natural width for a 0..3599 offset)
/// would give 12.1%. Every launch has a different schedule because `poolId` is in the
/// seed, and no two hours repeat because the hour index is.
///
/// @dev WINDOWS ARE CLAMPED INSIDE THE HOUR rather than allowed to wrap. A window that
/// started at 3595 and ran to 3615 would have to be found by also drawing the previous
/// hour, doubling the keccak cost to defend twenty seconds. The cost is that the last
/// `windowSec` of each hour can never begin a window. Documented, not hidden.
///
/// @dev OVERLAPS TAKE THE MAXIMUM. Six random starts in an hour collide rarely, and when
/// they do the trader pays the higher of the two rather than the sum, because two
/// outages at once is still one outage as far as a price is concerned.
///
/// @dev SYMMETRIC. An outage moves spot for everyone in the pit. Charging only buyers
/// would make it a launch tax wearing a costume, and this directory already has `Pace`
/// for that and does it better.
///
/// @dev NEVER REFUSES. There is no window in which a position cannot be exited, and the
/// fee inside one decays to nothing within `windowSec`. See `TraitBase`'s house rule.
///
/// @dev THE 60% HEADLINE IS NOT WHAT ANYBODY PAYS. Peak is only charged in the first
/// second. A trade landing uniformly inside a 20 second window at a 7 second half-life
/// pays 27.4% on average, and the expected cost across a whole day, at 3.33% window
/// occupancy, is about 91 bps of volume.
///
/// @dev CEILING. `TraitBase.MAX_ADD_PPM` is 100,000 ppm, which is 10%, and `_fee` clamps
/// every return through it. Until `FEE_CEIL_PPM` is raised in `FourthStreetHook`,
/// `FourthStreetLauncher` and `TraitBase`, a `peakPpm` of 600,000 configured here will be
/// served as 100,000. The maths below is written for the raised ceiling and is correct
/// either way; only the clamp moves.
///
/// COST. One `keccak256` over 64 bytes, six comparisons, and at most one decay
/// evaluation. No loops over trader input, no state, no storage. Well inside `TRAIT_GAS`.
contract OutageTrait is TraitBase {
    /// @dev Seconds in the scheduling epoch. One hour.
    uint256 private constant EPOCH = 3600;

    /// @dev Beyond 24 halvings the fee is zero in ppm regardless of the peak, so the
    /// decay short-circuits rather than shifting by a width it cannot represent.
    uint256 private constant MAX_HALVINGS = 24;

    // params layout, frozen at launch by the factory
    uint256 private constant SH_PEAK = 0; //  24 bits, ppm at t = 0 inside a window
    uint256 private constant SH_WINDOW = 24; // 16 bits, window length in seconds
    uint256 private constant SH_HALFLIFE = 40; // 16 bits, decay half-life in seconds
    uint256 private constant SH_PERHOUR = 56; //  8 bits, windows per hour
    uint256 private constant SH_CAP = 64; // 24 bits, this slot's frozen ceiling

    function quote(Ctx calldata c) external pure returns (uint24 addFeePpm, bytes32 newState) {
        newState = c.state; // stateless: a same-value SSTORE, not a clear

        uint256 peak = _bits(c.params, SH_PEAK, 24);
        uint256 window = _bits(c.params, SH_WINDOW, 16);
        uint256 halfLife = _bits(c.params, SH_HALFLIFE, 16);
        uint256 perHour = _bits(c.params, SH_PERHOUR, 8);
        uint256 cap = _bits(c.params, SH_CAP, 24);

        // An unconfigured slot charges nothing rather than guessing a default.
        if (peak == 0 || window == 0 || halfLife == 0 || perHour == 0 || cap == 0) {
            return (0, newState);
        }
        if (window >= EPOCH) return (0, newState);

        uint256 ts = uint256(c.ts);
        uint256 offset = ts % EPOCH;
        // `span` is the number of start positions available once the window is clamped
        // to end inside the hour. window < EPOCH is guaranteed above, so span >= 1.
        uint256 span = EPOCH - window + 1;

        bytes32 seed = keccak256(abi.encodePacked(c.poolId, ts / EPOCH));

        uint256 best = 0;
        for (uint256 i = 0; i < perHour; ++i) {
            // Six 32-bit draws fit in one 256-bit seed. Past eight, stop rather than
            // reading zero bits and stacking every remaining window on offset 0.
            if (i >= 8) break;
            uint256 start = (uint256(seed) >> (i * 32)) & 0xFFFFFFFF;
            start %= span;

            if (offset < start) continue;
            uint256 dt = offset - start;
            if (dt >= window) continue;

            uint256 f = _decay(peak, dt, halfLife);
            if (f > best) best = f;
        }

        addFeePpm = _fee(best, cap);
    }

    /// @notice `peak * 2^(-dt / halfLife)`, without `expWad` and without a library.
    /// @dev Integer halvings with linear interpolation inside the current halving. The
    /// maximum relative error against the true exponential is 6.07%, at the midpoint of
    /// a halving, and it always errs HIGH, so an outage lingers a little rather than
    /// expiring early. That is the conservative direction for the pool and the
    /// aggressive one for the trader, which is why it is stated here and bounded by
    /// `_fee` on the way out.
    function _decay(uint256 peak, uint256 dt, uint256 halfLife) private pure returns (uint256) {
        uint256 n = dt / halfLife;
        if (n >= MAX_HALVINGS) return 0;
        uint256 hi = peak >> n;
        uint256 lo = hi >> 1;
        uint256 into = dt % halfLife;
        return hi - ((hi - lo) * into) / halfLife;
    }

    /// @notice Reject a configuration that could never behave, at launch, once.
    /// @dev `perHour` is capped at 8 because the seed carries eight 32-bit draws and a
    /// ninth would silently reuse bits. `window * perHour` is capped at a quarter of the
    /// hour so an "outage" stays an event rather than becoming the weather.
    function validate(bytes32 params) external pure returns (bool) {
        uint256 peak = _bits(params, SH_PEAK, 24);
        uint256 window = _bits(params, SH_WINDOW, 16);
        uint256 halfLife = _bits(params, SH_HALFLIFE, 16);
        uint256 perHour = _bits(params, SH_PERHOUR, 8);
        uint256 cap = _bits(params, SH_CAP, 24);

        if (!_inRange(peak, 1, 999_999)) return false;
        if (!_inRange(window, 1, 600)) return false;
        if (!_inRange(halfLife, 1, window)) return false;
        if (!_inRange(perHour, 1, 8)) return false;
        if (!_inRange(cap, 1, MAX_ADD_PPM)) return false;
        if (window * perHour > EPOCH / 4) return false;
        return true;
    }

    function describe() external pure returns (string memory family, string memory name) {
        return ("physical", "Outage");
    }
}
