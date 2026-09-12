// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TraitBase} from "./TraitBase.sol";

/// @title BreakerTrait
/// @notice The market-wide circuit breaker, with the halt replaced by a price.
///
/// WHAT THIS SAYS ABOUT THE UNDERLYING, IN PLAIN LANGUAGE
/// Every US exchange runs the same three numbers. If the S&P 500 falls 7% against the
/// previous session's close, trading stops everywhere for fifteen minutes. If it falls 13%,
/// it stops again. If it falls 20%, the day is over and nobody trades anything until
/// tomorrow. Three tiers, minus seven, minus thirteen, minus twenty, written into Rule 80B
/// after 1987 and rewritten to those levels after 2010. They have been used: 9 March 2020,
/// 12 March, 16 March, 18 March, four Level 1 halts in eight trading days.
///
/// The tiers are not a scale. They are steps. Nothing happens at 6.9% and the whole market
/// stops at 7.0%, which is the point: a breaker is a threshold, not a curve, and the
/// discontinuity is what makes everybody look up.
///
/// This structure keeps the three tiers and throws away the halt. Below 7% against the
/// session's reference it charges nothing at all. At 7% it steps to the first tier, at 13%
/// to the second, at 20% to the third, and it charges both sides, because a halt stops
/// buyers too. The trade that lifts the price back above a tier boundary is charged at the
/// tier it LEAVES, so the bid that repairs the breach escapes it. That is the one thing a
/// real halt cannot do: it freezes the buyer and the seller together and then reopens into
/// whatever has accumulated in fifteen minutes of nobody being able to do anything.
///
/// @dev FAMILY: physical.
///
/// @dev SYMMETRIC, AND DELIBERATELY SO. `UptickTrait` in this directory is the one-sided
/// price test, and the pair is only coherent read together: Rule 201 restricts short sales
/// and touches nobody else, Rule 80B halts the entire market and touches everybody. Two
/// real rules, two different symmetries, and copying one of them onto the other would lose
/// exactly the distinction that makes both of them worth having.
///
/// @dev THE TIERS ARE CONSTANTS, NOT PARAMETERS, AND THAT IS ON PURPOSE. `-7%`, `-13%` and
/// `-20%` are the published levels. A launcher chooses what each tier COSTS and nothing
/// else. Making the thresholds configurable would let a launch advertise a circuit breaker
/// and freeze it at a level no market ever used, and the whole value of this structure is
/// that the numbers in it are the numbers in the rulebook.
///
/// @dev IT PRICES THE POST-TRADE MARKET. A breaker asks where the price IS, and a trade
/// that takes it through a tier has taken it through. On constant product both moves are a
/// closed form and neither reads the venue:
///
///     buy of `dx` underlying:  P'/P = ((uWad + dx) / uWad)^2
///     sell of `dy` tokens:     P'/P = (tRes / (tRes + dy))^2
///
/// This is THE PRICE MOVE and it is not execution slippage, which is `1 - 1/(1 + x/R)`.
/// They differ by about 2x at small size and diverge without limit.
/// `research/traits/CATALOGUE.md` section 1 carries the derivation.
///
/// @dev THE REFERENCE IS THE SESSION'S FIRST PRINT, AND ON THIS VENUE THAT IS THE PRIOR
/// CLOSE, because the price on this curve only moves when somebody trades. There is no
/// overnight tape and no auction, so the first price of a session and the last price of the
/// one before it are the same number. The anchor logic here is deliberately DUPLICATED from
/// `UptickTrait` rather than shared: a structure is a self-contained singleton, and a shared
/// helper would tie two rules' behaviour to one edit made for the benefit of the other.
///
/// @dev STATEFUL, AND IT WRITES ONLY ON A SESSION BOUNDARY. Every trade inside a session
/// returns `c.state` unchanged, so the hook's persist is a same-value SSTORE.
///
/// @dev AUTOSTART, CATALOGUE ENTRY 14. Without it, a launch that fell 25% and then went
/// quiet for a month would charge the third tier on the first trade back, and on every
/// trade after that, because the anchor still remembers a price nobody has been able to
/// trade against. `staleSessions` is the threshold: a gap within it still measures against
/// the old anchor, a gap past it discards the anchor, charges nothing and reseeds. A halt
/// that never lifts is not a breaker, it is a delisting.
///
/// @dev NEVER REFUSES. The Level 3 halt closes the market for the day; this structure
/// prices it instead, which is `QuotaTrait`'s line applied to the deepest tier there is:
/// nothing is ever forbidden, you can always have more, you just have to outbid it.
///
/// PARAMS, packed little end first into the frozen `bytes32`:
///   bits    0..23   l1Ppm          uint24   1 .. capPpm    charged at -7% or worse
///   bits   24..47   l2Ppm          uint24   l1 .. capPpm   charged at -13% or worse
///   bits   48..71   l3Ppm          uint24   l2 .. capPpm   charged at -20% or worse
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
///   A launch that wants the tiers to bite the way the real ones do:
///     l1Ppm 5000 (0.5%), l2Ppm 25000 (2.5%), l3Ppm 100000 (10%), capPpm 100000,
///     sessionSec 86400, staleSessions 1.
///   An ordinary 5% day costs nothing. A 2020-shaped 8% day costs half a percent a side. A
///   day that takes the launch down 21% costs ten percent to trade at all, in either
///   direction, which is the honest price of a market nobody wants to be the other side of.
///
/// COST. Constant. One packed state read, one price, one square, three multiplies, four
/// divides, three comparisons. No loops.
contract BreakerTrait is TraitBase {
    uint256 private constant SH_L1 = 0;
    uint256 private constant SH_L2 = 24;
    uint256 private constant SH_L3 = 48;
    uint256 private constant SH_CAP = 72;
    uint256 private constant SH_SESSION = 96;
    uint256 private constant SH_STALE = 128;
    uint256 private constant SH_END = 136;

    uint256 private constant ST_REF = 0;
    uint256 private constant ST_IDX = 128;
    uint256 private constant ST_SEEDED = 255;

    /// @dev SEC Rule 80B, as amended after the 2010 flash crash. Level 1 and Level 2 halt
    /// the market for fifteen minutes; Level 3 ends the session. These are the published
    /// levels and they are constants here for that reason.
    uint256 private constant LEVEL1_PPM = 70_000; // -7%
    uint256 private constant LEVEL2_PPM = 130_000; // -13%
    uint256 private constant LEVEL3_PPM = 200_000; // -20%

    uint256 private constant MIN_SESSION = 3600;
    uint256 private constant MAX_SESSION = 604_800; // one week
    uint256 private constant MAX_STALE = 7;

    /// @dev The clamp that makes the buy branch's square safe. `r` is a price ratio in ppm,
    /// so `PPM` is no move and `1e9` is a thousand-fold move. `r <= 1e9` gives `r*r <= 1e18`,
    /// which is fifty-nine orders of magnitude inside uint256. Without it a `dx` at the
    /// uint128 ceiling against a small `uWad` overflows, and every fuzz run with sane
    /// parameters passes while the configuration maximum reverts.
    uint256 private constant MAX_R = 1e9;

    function quote(Ctx calldata c) external pure returns (uint24 addFeePpm, bytes32 newState) {
        newState = c.state;

        uint256 cap = _bits(c.params, SH_CAP, 24);
        uint256 session = _bits(c.params, SH_SESSION, 32);
        uint256 stale = _bits(c.params, SH_STALE, 8);

        // An unconfigured or unusable slot charges nothing AND touches nothing.
        if (cap == 0 || stale == 0) return (0, newState);
        if (session < MIN_SESSION) return (0, newState);

        uint256 spot = _priceU18(c);
        if (spot == 0) return (0, newState); // an unpriceable book: never reseed on junk
        if (spot > U128_MAX) spot = U128_MAX;

        // `ts` is a uint40 and `session` is at least 3600, so the index is under 2^28 and
        // the 32 bits it is packed into can never be overrun.
        uint256 cur = uint256(c.ts) / session;
        uint256 ref = _bits(c.state, ST_REF, 128);

        // A zero word is a launch that has never traded. The seeded bit is carried
        // explicitly rather than inferred, because a mapping answers an unknown key with an
        // all-zero struct and that is the phantom-value trap (RULE 6).
        if (_bits(c.state, ST_SEEDED, 1) == 0 || ref == 0) return (0, _pack(spot, cur));

        uint256 gap = _satSub(cur, _bits(c.state, ST_IDX, 32));

        // AUTOSTART. Past the staleness horizon the anchor remembers a price nobody has
        // been able to trade against, so it is discarded rather than charged against.
        if (gap > stale) return (0, _pack(spot, cur));
        if (gap != 0) newState = _pack(spot, cur);

        // `spot` and `ref` are both bounded by uint128, so `spot * PPM` is under 3.5e44.
        uint256 nowPpm = (spot * PPM) / ref;
        uint256 movePpm = _movePpm(c);
        // `nowPpm` is at most 3.5e44 and `movePpm` at most 1e12, so the product is under
        // 3.5e56 and cannot overflow.
        uint256 postPpm = (nowPpm * movePpm) / PPM;

        if (postPpm >= PPM) return (0, newState);
        uint256 declinePpm = PPM - postPpm;

        // RULE 5, and the tie is called deliberately. Rule 80B triggers at a decline "of 7%
        // or more", so a decline of exactly a tier's level is INSIDE that tier. An
        // inclusive comparison landing the wrong way is how float disarmed a circuit
        // breaker on three markets by an exact tie, which is a memorably relevant
        // precedent for a structure named after one.
        uint256 raw;
        if (declinePpm >= LEVEL3_PPM) {
            raw = _bits(c.params, SH_L3, 24);
        } else if (declinePpm >= LEVEL2_PPM) {
            raw = _bits(c.params, SH_L2, 24);
        } else if (declinePpm >= LEVEL1_PPM) {
            raw = _bits(c.params, SH_L1, 24);
        } else {
            return (0, newState);
        }

        addFeePpm = _fee(raw, cap);
    }

    /// @notice The post-trade price as a ppm ratio of the pre-trade price.
    /// @dev THE PRICE MOVE, not execution slippage. Both branches are exact on constant
    /// product and neither reads the venue.
    function _movePpm(Ctx calldata c) private pure returns (uint256) {
        if (c.buying) {
            uint256 dx = _sizeU(c);
            // `_mulDiv128` bounds its INPUTS and not its OUTPUT, so a `_size*` result can
            // sit far above uint128 and take any later multiply with it. WARNINGS.md
            // carries the counterexample.
            if (dx > U128_MAX) dx = U128_MAX;
            uint256 r = ((uint256(c.uWad) + dx) * PPM) / uint256(c.uWad);
            if (r > MAX_R) r = MAX_R;
            return (r * r) / PPM;
        }
        uint256 dy = _sizeT(c);
        if (dy > U128_MAX) dy = U128_MAX;
        uint256 s = (uint256(c.tRes) * PPM) / (uint256(c.tRes) + dy); // at most PPM
        return (s * s) / PPM;
    }

    function _pack(uint256 ref, uint256 idx) private pure returns (bytes32) {
        if (ref > U128_MAX) ref = U128_MAX;
        return bytes32((uint256(1) << ST_SEEDED) | (idx << ST_IDX) | ref);
    }

    function describe() external pure returns (string memory family, string memory name) {
        return ("physical", "Breaker");
    }

    /// @dev Rejects the sentinel shapes that would silently disarm the mechanic (a zero
    /// first tier, a zero cap, a zero staleness horizon), rejects tiers that do not
    /// increase (a breaker whose deeper level is cheaper is not a breaker, it is a
    /// discount for a crash), rejects a top tier above the cap so the headline number in
    /// the launch record is the number that gets charged rather than one silently clamped,
    /// and rejects any bit set above the last defined field.
    function validate(bytes32 params) external pure returns (bool) {
        if (_above(params, SH_END) != 0) return false;
        uint256 l1 = _bits(params, SH_L1, 24);
        uint256 l2 = _bits(params, SH_L2, 24);
        uint256 l3 = _bits(params, SH_L3, 24);
        uint256 cap = _bits(params, SH_CAP, 24);
        uint256 session = _bits(params, SH_SESSION, 32);
        uint256 stale = _bits(params, SH_STALE, 8);
        if (!_inRange(cap, 1, MAX_ADD_PPM)) return false;
        if (l1 == 0) return false;
        if (l2 < l1 || l3 < l2) return false;
        if (l3 > cap) return false;
        if (!_inRange(session, MIN_SESSION, MAX_SESSION)) return false;
        if (!_inRange(stale, 1, MAX_STALE)) return false;
        return true;
    }
}
