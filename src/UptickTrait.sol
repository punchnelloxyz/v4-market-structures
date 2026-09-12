// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TraitBase} from "./TraitBase.sol";

/// @title UptickTrait
/// @notice Once a market has fallen far enough, pressing it down further costs money.
///
/// WHAT THIS SAYS ABOUT THE UNDERLYING, IN PLAIN LANGUAGE
/// This is the oldest live rule in American equities. From 1938 to 2007 you could not sell
/// a share short unless the last price change had been upward, which is where the name
/// comes from. The SEC repealed it, watched 2008 happen, and put back a narrower version in
/// 2010: Rule 201, the alternative uptick rule. A stock that falls 10% from the previous
/// day's close goes into a restricted state, and for the rest of that day and the whole of
/// the next one a short sale may only be posted above the national best bid. You can still
/// sell. You just cannot be the one who hits the bid on the way down.
///
/// Every single one of the 193 assets on this chain lives under that rule in its home
/// market. It is not an exotic mechanism, it is the ordinary condition of a listed share on
/// a bad day.
///
/// This structure says the same thing with a price instead of a prohibition. A reference is
/// taken at the first trade of each session. While the market is within `triggerPpm` of it,
/// the structure charges nothing at all, in either direction. Once the price has fallen past
/// the trigger, every sale is charged in proportion to how far past it the sale leaves the
/// market, so leaning on a falling book gets progressively dearer and bidding it back up
/// stays free forever. When the price recovers through the trigger, the charge is gone.
///
/// @dev FAMILY: delivery. A short sale restriction is a squeeze read backwards: the same
/// machinery that makes a cornered market expensive to be short of makes a collapsing one
/// expensive to be selling into.
///
/// @dev ASYMMETRIC, AND THAT IS THE ENTIRE MECHANIC. Buys are free at every depth of
/// decline. The rule exists to make it costly to press a market down and free to support
/// it, so a symmetric version would be a volatility toll with an uptick rule's name on it,
/// and this directory already has structures that do volatility honestly.
///
/// @dev IT PRICES THE POST-TRADE MARKET, NOT THE ONE THE TRADER FOUND. Rule 201 does not
/// ask where the bid was, it forbids a sale that would take the price down; the analogue
/// here is to measure the decline the sale LEAVES BEHIND. On constant product that is a
/// closed form and no venue read is needed:
///
///     sell of `dy` tokens:  P'/P = (tRes / (tRes + dy))^2
///
/// This is THE PRICE MOVE and it is not execution slippage. Slippage is `1 - 1/(1 + x/R)`,
/// the move is `((R + x)/R)^2 - 1`, they differ by about 2x at small size and they diverge
/// without limit. `research/traits/CATALOGUE.md` section 1 carries the derivation and
/// `WARNINGS.md` records the session that got it wrong.
///
/// @dev THE REFERENCE IS THE SESSION'S FIRST PRINT, AND ON THIS VENUE THAT IS THE PRIOR
/// CLOSE. Rule 201 measures against the previous day's closing price. A structure cannot
/// store two prices and a session index in one word without truncating a price, and
/// truncating a price to make a fee schedule tidier is exactly the class of decision that
/// goes wrong later. It does not have to: THE PRICE ON THIS CURVE ONLY MOVES WHEN SOMEBODY
/// TRADES. There is no overnight tape, no auction, no gap. So the first price of a session
/// and the last price of the one before it are the same number, and the one reference this
/// structure stores is both.
///
/// @dev STATEFUL, AND IT WRITES ONLY ON A SESSION BOUNDARY. Every trade inside a session
/// returns `c.state` unchanged, so the hook's persist is a same-value SSTORE. The dirty
/// write happens on the first trade of a new session, which for a daily session is at most
/// once a day.
///
/// @dev AUTOSTART, CATALOGUE ENTRY 14, WHICH IS THE DIFFERENCE BETWEEN A MECHANIC AND A
/// TAX. A stateful structure that wakes after a long silence must evaluate its schedule
/// from `lastTouch + threshold` and not from the moment of waking. Here the failure would
/// be real and ugly: a launch that fell 30% and then went quiet for a month would charge
/// the maximum on the first trade back, forever, because the anchor still remembers a price
/// nobody has been able to trade against since. So `staleSessions` is that threshold. A gap
/// of one session (or up to the configured number) still measures against the old anchor,
/// which is the rule's own "and the following day". A longer gap discards the anchor,
/// charges NOTHING, and reseeds. Bunni found this in production and fixed it there; the fix
/// is taken rather than rediscovered.
///
/// @dev THE ONE PLACE THE REAL RULE IS NOT FOLLOWED, STATED RATHER THAN BURIED. Rule 201
/// LATCHES: once triggered it stays on for the remainder of the day and all of the next one
/// even if the price fully recovers. This structure lifts as soon as the price does. A latch
/// would mean charging a market that is no longer falling, which under a fee-only design is
/// a toll on a recovery, and the recovery is the thing everybody wants. Priced, not
/// prohibited, and lifted when the reason for it is gone.
///
/// @dev NEVER REFUSES. It cannot: `ITrait.quote` has no refusal channel. An exit is
/// available in every block at a price, which is more than Rule 201 itself offers.
///
/// PARAMS, packed little end first into the frozen `bytes32`:
///   bits    0..23   triggerPpm     uint24   1 .. 999999    decline that arms the rule
///   bits   24..47   slopePpm       uint24   1 .. 1000000   fee per unit of excess decline
///   bits   48..71   stepPpm        uint24   0 .. capPpm    flat charge on arming
///   bits   72..95   capPpm         uint24   1 .. 600000
///   bits   96..127  sessionSec     uint32   3600 .. 604800
///   bits  128..135  staleSessions  uint8    1 .. 7         the autostart threshold
///   bits  136..255  MUST BE ZERO
///
/// STATE, packed:
///   bits    0..127  reference price, underlying per token, 18 decimals
///   bits  128..159  session index, `ts / sessionSec`
///   bit       255   seeded. An all-zero word is a launch that has never traded.
///
/// WORKED SETTINGS
///   The rule as the SEC writes it, in our units:
///     triggerPpm 100000 (the real 10%), slopePpm 1000000, stepPpm 0, capPpm 60000,
///     sessionSec 86400, staleSessions 2.
///   Nothing at all down to a 10% decline. At 12% the sale pays 2%. At 16% it pays 6% and
///   the cap holds it there. A buy pays nothing at any depth. `staleSessions 2` is the
///   rule's own "that day and the following day" read as a staleness horizon.
///
/// COST. Constant. One packed state read, one price, one square, three multiplies, four
/// divides, one clamp. No loops, no branches on trader input beyond the side of the trade.
contract UptickTrait is TraitBase {
    uint256 private constant SH_TRIGGER = 0;
    uint256 private constant SH_SLOPE = 24;
    uint256 private constant SH_STEP = 48;
    uint256 private constant SH_CAP = 72;
    uint256 private constant SH_SESSION = 96;
    uint256 private constant SH_STALE = 128;
    uint256 private constant SH_END = 136;

    uint256 private constant ST_REF = 0;
    uint256 private constant ST_IDX = 128;
    uint256 private constant ST_SEEDED = 255;

    /// @dev A session shorter than an hour would make almost every trade the first of its
    /// session on a quiet launch, which rolls the anchor forward before it can ever measure
    /// anything. That is a structure that reads as installed and does nothing, which is the
    /// silent-noop shape RULE 5 exists for.
    uint256 private constant MIN_SESSION = 3600;
    uint256 private constant MAX_SESSION = 604_800; // one week
    uint256 private constant MAX_STALE = 7;

    function quote(Ctx calldata c) external pure returns (uint24 addFeePpm, bytes32 newState) {
        newState = c.state;

        uint256 trigger = _bits(c.params, SH_TRIGGER, 24);
        uint256 slope = _bits(c.params, SH_SLOPE, 24);
        uint256 step = _bits(c.params, SH_STEP, 24);
        uint256 cap = _bits(c.params, SH_CAP, 24);
        uint256 session = _bits(c.params, SH_SESSION, 32);
        uint256 stale = _bits(c.params, SH_STALE, 8);

        // An unconfigured or unusable slot charges nothing AND touches nothing, so it does
        // not cost the hook a dirty SSTORE for a mechanic that is not running. `validate`
        // is the thing that stops a launch being frozen this way in the first place.
        if (trigger == 0 || cap == 0 || stale == 0) return (0, newState);
        if (session < MIN_SESSION) return (0, newState);

        uint256 spot = _priceU18(c);
        if (spot == 0) return (0, newState); // an unpriceable book: never reseed on junk
        if (spot > U128_MAX) spot = U128_MAX;

        // `ts` is a uint40 and `session` is at least 3600, so the index is under 2^28 and
        // the 32 bits it is packed into can never be overrun.
        uint256 cur = uint256(c.ts) / session;
        uint256 ref = _bits(c.state, ST_REF, 128);

        // A zero word is a launch that has never traded. Seed the anchor and charge
        // nothing: a price test needs two observations and this is the first. A mapping
        // answers an unknown key with an all-zero struct and that is the phantom-value trap
        // (RULE 6), so the seeded bit is carried explicitly rather than inferred.
        if (_bits(c.state, ST_SEEDED, 1) == 0 || ref == 0) return (0, _pack(spot, cur));

        uint256 gap = _satSub(cur, _bits(c.state, ST_IDX, 32));

        // AUTOSTART. Past the staleness horizon the anchor remembers a price nobody has
        // been able to trade against, so it is discarded rather than charged against.
        if (gap > stale) return (0, _pack(spot, cur));

        // A new session rolls the anchor to the price this trade found, but the trade
        // itself is still measured against the anchor it arrived under. That is the rule's
        // own shape: the restriction on the first sale of the day is decided by yesterday.
        if (gap != 0) newState = _pack(spot, cur);

        // Bidding a falling market up is free at every depth, permanently.
        if (c.buying) return (0, newState);

        // `spot` and `ref` are both bounded by uint128, so `spot * PPM` is under 3.5e44.
        uint256 nowPpm = (spot * PPM) / ref;

        // THE PRICE MOVE, not execution slippage. See the header.
        uint256 dy = _sizeT(c);
        // `_mulDiv128` bounds its INPUTS and not its OUTPUT, so a `_sizeT` result can sit
        // far above uint128 and take any later multiply with it. WARNINGS.md carries the
        // counterexample: uWad 8, tRes 2.10e35, specified 2^128 - 1 gives about 8.9e72.
        if (dy > U128_MAX) dy = U128_MAX;
        uint256 r = (uint256(c.tRes) * PPM) / (uint256(c.tRes) + dy); // at most PPM
        uint256 postPpm = (nowPpm * ((r * r) / PPM)) / PPM;

        if (postPpm >= PPM) return (0, newState);
        uint256 declinePpm = PPM - postPpm;

        // RULE 5, and the tie is called deliberately. The SEC's trigger is a decline "of
        // 10% or more", so a decline of EXACTLY `triggerPpm` is inside the restriction and
        // not outside it. An inclusive comparison landing the wrong way is how float
        // disarmed a circuit breaker on three markets by an exact tie.
        if (declinePpm < trigger) return (0, newState);

        uint256 excess = declinePpm - trigger;
        // `slope` is at most 1e6 and `excess` at most 1e6, so the product is under 1e12.
        addFeePpm = _fee(step + (slope * excess) / PPM, cap);
    }

    function _pack(uint256 ref, uint256 idx) private pure returns (bytes32) {
        if (ref > U128_MAX) ref = U128_MAX;
        return bytes32((uint256(1) << ST_SEEDED) | (idx << ST_IDX) | ref);
    }

    function describe() external pure returns (string memory family, string memory name) {
        return ("delivery", "Uptick");
    }

    /// @dev Rejects the sentinel shapes that would silently disarm the mechanic (a zero
    /// trigger, a zero slope, a zero cap, a zero staleness horizon), rejects a slope that
    /// would charge more than the decline that caused it, rejects a step above the cap
    /// (which makes the cap a lie on the very first restricted trade), rejects a session
    /// too short to hold a reference or long enough to outlive a launch, and rejects any
    /// bit set above the last defined field.
    /// @dev The slope ceiling of one whole PPM is the property worth keeping: the charge
    /// can never exceed the excess decline it is measuring, so the structure is bounded by
    /// the move rather than by the imagination of whoever froze the parameters.
    function validate(bytes32 params) external pure returns (bool) {
        if (_above(params, SH_END) != 0) return false;
        uint256 trigger = _bits(params, SH_TRIGGER, 24);
        uint256 slope = _bits(params, SH_SLOPE, 24);
        uint256 step = _bits(params, SH_STEP, 24);
        uint256 cap = _bits(params, SH_CAP, 24);
        uint256 session = _bits(params, SH_SESSION, 32);
        uint256 stale = _bits(params, SH_STALE, 8);
        if (!_inRange(trigger, 1, PPM - 1)) return false;
        if (!_inRange(slope, 1, PPM)) return false;
        if (!_inRange(cap, 1, MAX_ADD_PPM)) return false;
        if (step > cap) return false;
        if (!_inRange(session, MIN_SESSION, MAX_SESSION)) return false;
        if (!_inRange(stale, 1, MAX_STALE)) return false;
        return true;
    }
}
