// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ITrait} from "../interfaces/ITrait.sol";
import {TraitBase} from "./TraitBase.sol";

/// @title QuotaTrait
/// @notice A producer decides how much leaves the ground this month, and the price of
/// wanting more than that is the whole history of commodity markets.
///
/// WHAT THIS SAYS ABOUT THE UNDERLYING, IN PLAIN LANGUAGE
/// Supply is not a number, it is a decision. A cartel meets, agrees a quota, and the
/// world discovers what the marginal barrel costs when the taps are only open so far.
/// OPEC has run that experiment since 1960 and it works in both directions: cut and the
/// price of immediacy goes vertical, open the taps in March 2020 and it goes negative.
/// De Beers held rough diamonds off the market for most of a century. Even without a
/// cartel the same shape appears wherever production has a rate rather than a level:
/// mines have a throughput, refineries have a maintenance schedule, farms have a harvest.
///
/// And seasons are real. Heating oil is not the same product in January and July.
/// Gold moves against Diwali and the Chinese New Year, natural gas against the weather,
/// grain against the harvest. A market that prices a seasonal good identically all year
/// is missing the only thing everybody in that market actually talks about.
///
/// This trait gives a launch a production rate instead of an inventory. In each epoch,
/// only so much of the supply may leave the warehouse at the ordinary price. Buying
/// inside the quota costs nothing extra. Buying past it costs more, rising with how far
/// past it you are, up to the frozen ceiling. The quota itself is multiplied by a
/// seasonal factor that runs on the calendar and not on the launch, so every FourthStreet
/// market carrying this trait tightens and loosens in the same quarter, together, the way
/// a real season arrives for everyone at once.
///
/// Nothing is ever forbidden. You can always have more; you just have to outbid the
/// quota. That is what a cartel actually sells.
///
/// @dev FAMILY: supply.
///
/// @dev BUYS CONSUME QUOTA, SELLS DO NOT REPLENISH IT. Production is a rate, and metal
/// coming back to the warehouse is not the mine running backwards. Sells are free, never
/// refused, and never counted. The quota resets on the epoch boundary and only there.
///
/// @dev THE SIZE MEASUREMENT IS DELIBERATELY CONSERVATIVE. A trait sees `specified`, not
/// the fill, so a buy priced in the underlying is converted to tokens at the marginal
/// price, which OVERSTATES the tokens that actually leave (the realised fill walks up the
/// curve away from the marginal price). Overstating consumption makes the quota bind
/// sooner, which is the safe direction for a supply cap and the wrong direction for
/// anyone trying to sneak under it. The error is at most the trade's own slippage.
///
/// @dev SEASONS RUN ON ABSOLUTE TIME, NOT ON LAUNCH TIME. The quarter index is
/// `(block.timestamp / 7889400) % 4`, so it is a property of the world rather than of any
/// one launch, and two launches carrying this trait are always in the same season.
/// 7,889,400 seconds is 91.3125 days, one quarter of a Julian year, so the cycle is
/// 365.25 days and does not drift across the leap cycle. It is offset from the calendar
/// by whatever the Unix epoch happens to be: quarter 0 begins on 1 January 1970 and the
/// boundaries land within a couple of days of the calendar quarters. If a launch needs
/// exact calendar quarters it should not use this trait, and the launch record shows
/// precisely which four multipliers were frozen so nobody has to guess.
///
/// @dev NEVER REFUSES.
///
/// @dev INERT AFTER GRADUATION. In AMM mode the hook no longer moves `uWad` and `tRes`,
/// so there is no warehouse throughput left to meter. Mode 2 returns zero. The mine
/// closed and the market it fed is now a two sided pool.
///
/// PARAMS, packed little end first into the frozen `bytes32`:
///   bits    0..23   quotaPpm      uint24  1 .. 1000000   supply releasable per epoch
///   bits   24..47   overPpm       uint24  1 .. 100000    charge at one full quota over
///   bits   48..79   epochSeconds  uint32  3600 .. 31536000
///   bits   80..87   seasonPct Q0   uint8  1 .. 255       percent multiplier on the quota
///   bits   88..95   seasonPct Q1   uint8  1 .. 255
///   bits   96..103  seasonPct Q2   uint8  1 .. 255
///   bits  104..111  seasonPct Q3   uint8  1 .. 255
///   bits  112..255  MUST BE ZERO
///
/// STATE, packed:
///   bits    0..127  tokens released so far in the current epoch
///   bits  128..159  the epoch index that count belongs to
/// A stale epoch index is how the counter resets; there is no cron and no keeper.
///
/// WORKED SETTINGS
///   quotaPpm 20000 (2% of supply a day), overPpm 40000 (4% at one full quota over),
///   epochSeconds 86400, seasons 100/100/100/160. An ordinary market three quarters of
///   the year and a 60% wider tap in the fourth, which is roughly what a heating season
///   does to distillate.
///
/// COST. Constant. One divide for the epoch, one for the season, three multiplies, one
/// clamp, one repack. No loops. The state word changes on any buy and on the first trade
/// of a new epoch, so the hook's persist is a dirty SSTORE on those and a same-value
/// write otherwise.
contract QuotaTrait is TraitBase {
    uint256 private constant SH_QUOTA = 0;
    uint256 private constant SH_OVER = 24;
    uint256 private constant SH_EPOCH = 48;
    uint256 private constant SH_SEASON0 = 80;
    uint256 private constant SH_END = 112;

    uint256 private constant ST_USED = 0;
    uint256 private constant ST_EPOCH = 128;

    /// @dev 91.3125 days. Four of these is exactly one Julian year.
    uint256 private constant SEASON = 7_889_400;

    uint256 private constant MIN_EPOCH = 3600;
    uint256 private constant MAX_EPOCH = 31_536_000;
    uint256 private constant U32_MAX = type(uint32).max;

    uint8 private constant MODE_AMM = 2;

    function quote(Ctx calldata c) external pure returns (uint24 addFeePpm, bytes32 newState) {

        uint256 epochSec = _bits(c.params, SH_EPOCH, 32);
        uint256 quotaPpm = _bits(c.params, SH_QUOTA, 24);
        uint256 overPpm = _bits(c.params, SH_OVER, 24);

        if (epochSec < MIN_EPOCH || quotaPpm == 0 || overPpm == 0 || c.mode == MODE_AMM) {
            return (0, c.state);
        }

        uint256 epochIdx = _min(uint256(c.ts) / epochSec, U32_MAX);
        uint256 used = _bits(c.state, ST_EPOCH, 32) == epochIdx ? _bits(c.state, ST_USED, 128) : 0;

        // A sell returns goods to the warehouse. It does not run the mine backwards, so
        // it consumes nothing and pays nothing. The epoch index is still rolled forward
        // so the counter cannot be resurrected by a later trade in the same epoch.
        if (!c.buying) return (0, _pack(used, epochIdx));

        uint256 released = _sizeT(c);
        uint256 newUsed = used + released; // both are bounded by U128_MAX
        if (newUsed > U128_MAX) newUsed = U128_MAX;
        newState = _pack(newUsed, epochIdx);

        uint256 allowance = _quotaTokens(c, quotaPpm);

        // A quota that rounds to nothing means the taps are shut, so every unit is over.
        if (allowance == 0) return (_fee(overPpm, overPpm), newState);

        uint256 overage = _satSub(newUsed, allowance);
        if (overage == 0) return (0, newState);

        // The charge reaches `overPpm` at one full quota over and stays there. Without
        // this clamp a single very large buy would price against an unbounded ratio.
        uint256 frac = _min(PPM, (overage * PPM) / allowance);
        addFeePpm = _fee((overPpm * frac) / PPM, overPpm);
    }

    /// @notice The tokens this launch may release in the current epoch, after the
    /// seasonal multiplier.
    /// @dev Public so the UI and an indexer read the same number the fee is computed
    /// from, through the same code path (RULE 7).
    function quotaTokens(Ctx calldata c) external pure returns (uint256) {
        return _quotaTokens(c, _bits(c.params, SH_QUOTA, 24));
    }

    function _quotaTokens(Ctx calldata c, uint256 quotaPpm) internal pure returns (uint256) {
        uint256 q = (uint256(c.ts) / SEASON) % 4;
        uint256 pct = _bits(c.params, SH_SEASON0 + q * 8, 8);
        if (pct == 0) pct = 100; // an unconfigured season is an ordinary season

        uint256 eff = _min((quotaPpm * pct) / 100, PPM);
        return (uint256(c.supply) * eff) / PPM;
    }

    function _pack(uint256 used, uint256 epochIdx) private pure returns (bytes32) {
        if (used > U128_MAX) used = U128_MAX;
        return bytes32((epochIdx << ST_EPOCH) | used);
    }

    function describe() external pure returns (string memory family, string memory name) {
        return ("supply", "Quota");
    }

    /// @dev A seasonal multiplier of zero is rejected rather than treated as "no season".
    /// Zero would shut the taps completely and permanently for one quarter in four, which
    /// is a halt written as a rounding, and a halt is the one thing this trait must not
    /// be able to express. The epoch floor of one hour exists for the same reason as
    /// `TermTrait`'s tau floor: an epoch short enough to reset every block is a quota that
    /// never binds, which reads as installed and does nothing (RULE 5).
    function validate(bytes32 params) external pure returns (bool) {
        if (_above(params, SH_END) != 0) return false;

        uint256 quotaPpm = _bits(params, SH_QUOTA, 24);
        uint256 overPpm = _bits(params, SH_OVER, 24);
        uint256 epochSec = _bits(params, SH_EPOCH, 32);

        if (!_inRange(quotaPpm, 1, PPM)) return false;
        if (!_inRange(overPpm, 1, MAX_ADD_PPM)) return false;
        if (!_inRange(epochSec, MIN_EPOCH, MAX_EPOCH)) return false;

        // Unrolled on purpose. There is no loop anywhere in this directory, bounded or
        // otherwise, so "no loops" is a property a reader can check by grep rather than
        // a claim they have to take on trust.
        if (_bits(params, SH_SEASON0, 8) == 0) return false;
        if (_bits(params, SH_SEASON0 + 8, 8) == 0) return false;
        if (_bits(params, SH_SEASON0 + 16, 8) == 0) return false;
        if (_bits(params, SH_SEASON0 + 24, 8) == 0) return false;
        return true;
    }
}
