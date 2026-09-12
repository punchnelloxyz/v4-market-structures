// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TraitBase} from "./TraitBase.sol";

/// @title ImpactTrait
/// @notice A big order moves the price against you, and the merchant prices the move
/// rather than the order.
///
/// WHAT THIS SAYS ABOUT THE UNDERLYING, IN PLAIN LANGUAGE
/// A warehouse that sells you a thousand tonnes does not charge you a thousand times the
/// one-tonne price. It charges you for what taking a thousand tonnes does to the price of
/// the next tonne. Every dealer in every physical market has priced this forever, and it
/// is the one thing a bonding curve does not do on its own: the curve makes a large trade
/// expensive through slippage, but it hands the whole of that move to whoever arrives
/// next, for free.
///
/// This trait takes half of it back. An arbitrageur closing a divergence from `P` to `M`
/// fills at roughly the geometric mean `sqrt(P*M)`, so their profit is about half the
/// divergence, so a fee of half the impact captures the profit and leaves the trade.
///
/// @dev FAMILY: physical.
///
/// @dev SOURCE. Ported from `dennnis0204/slippage-fee-hook`, `src/SlippageFeeHook.sol`,
/// `_calculateFee`. MIT per-file SPDX. Live on Arbitrum One at
/// `0xc4bf39a096a1b610dd6186935f3ad99c66239080`. Catalogued at
/// `research/traits/CATALOGUE.md` section 1.
///
/// @dev WHAT THE PORT THROWS AWAY, AND WHY THAT IS THE POINT. The original opens
/// `poolManager.unlock`, executes the real swap, reads `slot0` for the resulting tick,
/// then deliberately reverts with that tick as calldata and catches its own revert to
/// recover it. That entire apparatus exists for one reason: a v4 concentrated-liquidity
/// pool has no closed form for its post-trade price, so the only way to learn it is to do
/// the trade. FOURTHSTREET'S CURVE HAS A CLOSED FORM. It is constant product on
/// `(uWad, tRes)`, so:
///
///     buy of `dx` underlying:   P'/P = ((uWad + dx) / uWad)^2
///     sell of `dy` tokens:      P'/P = (tRes / (tRes + dy))^2
///
/// Derivation for the buy, from `tokensOut = dx * tRes / (uWad + dx)`:
/// `t' = tRes - tokensOut = tRes * uWad / (uWad + dx)`, `u' = uWad + dx`, so
/// `P' = u'/t' = (uWad + dx)^2 / (tRes * uWad)` and `P'/P = ((uWad + dx)/uWad)^2`. The
/// sell is the mirror. Both are exact, both are two multiplies and a divide, and NEITHER
/// READS THE VENUE. A nested swap, a deliberate revert and a calldata decode collapse
/// into arithmetic on `Ctx`, which is the whole reason this trait is `pure`.
///
/// @dev SYMMETRIC IN SHAPE, NOT IN NUMBER. Buys and sells are charged by the same rule,
/// half the price impact each causes, but the two branches are not the same expression:
/// a buy's ratio is above one and a sell's is below it, so the impact is `r^2 - 1` on one
/// side and `1 - r^2` on the other. A single branch would be wrong on the sell side by
/// the whole of the difference.
///
/// @dev THE ONLY SHARP EDGE, AND IT IS HANDLED. `r` is clamped to `MAX_R` BEFORE it is
/// squared. Without the clamp, a `dx` at `uint128` max against a small `uWad` produces an
/// `r` whose square overflows `uint256`, and every fuzz test with sane parameters passes
/// while the configuration maximum reverts. This is the Bunni quadratic class recorded in
/// `research/traits/WARNINGS.md`: their `delta * delta` survives only on a 0.3% margin and
/// only because solady carries the intermediate in 512 bits. `TraitBase._mulDiv128` IS NOT
/// USABLE HERE, because it clamps both operands to `uint128` first, which would silently
/// truncate `r` rather than bounding the product. The clamp is on `r` and the square is
/// plain, which is safe because `MAX_R` is chosen to make it safe.
///
/// @dev THE SECOND SHARP EDGE, FOUND BY FUZZING THIS TRAIT AND NOT BY READING IT.
/// `_sizeU` and `_sizeT` clamp their OPERANDS to `uint128` and then divide, so their
/// RESULT is not bounded by `uint128` at all: `_mulDiv128(s, tRes, uWad)` with `s` and
/// `tRes` both near the ceiling and `uWad` small returns a number far above it. Multiplying
/// that by `PPM` to get a size ratio then overflows `uint256`, and the trait reverts.
/// Counterexample from the suite: `uWad = 8`, `tRes = 2.10e35`, `specified = 2^128 - 1`,
/// selling, exact output, which produces a `dy` of about `8.9e72` and a `dy * PPM` of
/// `8.9e78` against a ceiling of `1.16e77`. Both sizes are therefore clamped to `U128_MAX`
/// before any multiplication. This is the same class `research/traits/WARNINGS.md` records
/// against Bunni's quadratic term, and the same sentence applies: `_mulDiv128` bounds what
/// goes in, never what comes out.
///
/// @dev STATELESS. Everything comes out of the trade being priced. Returns `c.state`
/// untouched, so the hook pays a same-value SSTORE rather than a dirty one.
///
/// PARAMS, packed little end first into the frozen `bytes32`:
///   bits    0..23   sharePpm     uint24   1 .. 1000000   fraction of the impact charged
///   bits   24..47   capPpm       uint24   1 .. 600000
///   bits   48..71   floorPpm     uint24   0 .. 600000    charged on any billable trade
///   bits   72..95   minSizePpm   uint24   0 .. 1000000   size below which it is free
///   bits   96..255  MUST BE ZERO
///
/// WORKED SETTINGS
///   The original's own configuration, in our units:
///     sharePpm 500000 (half the impact), capPpm 50000 (5%), floorPpm 100 (1 bp),
///     minSizePpm 0.
///   A trade taking 1% of the underlying reserve moves the price about 2.01%, so it pays
///   about 1.005%. A trade taking 10% moves it 21% and pays 10.5%, which the 5% cap then
///   holds at 5%.
///
/// @dev A SENTENCE FROM THE ORIGINAL THAT IS WRONG AND IS NOT REPEATED HERE. Its NatSpec
/// and README both say it "protects swappers from slippage exceeding 5%". The guard is
/// `tickDelta > 1000`, and `1.0001^1000` is a 10.5% price move, not 5%. What equals 5% is
/// the FEE at that boundary. The doc conflates the move with the charge.
///
/// COST. Constant. One divide, one multiply, one square, two clamps, no loops, no branches
/// on anything but the trade's direction, no state transition.
contract ImpactTrait is TraitBase {
    uint256 private constant SH_SHARE = 0;
    uint256 private constant SH_CAP = 24;
    uint256 private constant SH_FLOOR = 48;
    uint256 private constant SH_MINSIZE = 72;
    uint256 private constant SH_END = 96;

    /// @dev The clamp that makes the square safe. `r` is a price ratio in ppm, so `PPM`
    /// is "no move" and `1e9` is a thousand-fold move, far past anything a real trade
    /// against a funded curve can reach. `r <= 1e9` gives `r*r <= 1e18`, which is
    /// fifty-nine orders of magnitude inside `uint256`.
    uint256 private constant MAX_R = 1e9;

    function quote(Ctx calldata c) external pure returns (uint24 addFeePpm, bytes32 newState) {
        newState = c.state;

        uint256 sharePpm = _bits(c.params, SH_SHARE, 24);
        uint256 cap = _bits(c.params, SH_CAP, 24);
        uint256 floorPpm = _bits(c.params, SH_FLOOR, 24);
        uint256 minSizePpm = _bits(c.params, SH_MINSIZE, 24);

        // An unconfigured slot charges nothing rather than guessing. `validate` is the
        // thing that stops a launch being frozen this way in the first place.
        if (sharePpm == 0 || cap == 0) return (0, newState);
        if (c.uWad == 0 || c.tRes == 0) return (0, newState);

        uint256 impactPpm;
        uint256 sizePpm;

        if (c.buying) {
            // dx is the underlying going in. `_sizeU` overstates a buy's underlying cost,
            // which overstates the impact, which is the conservative direction for a fee.
            uint256 dx = _sizeU(c);
            if (dx > U128_MAX) dx = U128_MAX; // see THE SECOND SHARP EDGE
            sizePpm = (dx * PPM) / uint256(c.uWad);

            uint256 r = PPM + sizePpm;
            if (r > MAX_R) r = MAX_R;
            // Safe by the clamp above, and deliberately NOT `_mulDiv128`.
            impactPpm = ((r * r) / PPM) - PPM;
        } else {
            // dy is the launched token coming in. The price falls, so the ratio is below
            // one and the impact is the deficit rather than the excess.
            uint256 dy = _sizeT(c);
            if (dy > U128_MAX) dy = U128_MAX; // see THE SECOND SHARP EDGE
            sizePpm = (dy * PPM) / uint256(c.tRes);

            uint256 denom = uint256(c.tRes) + dy;
            uint256 r = (uint256(c.tRes) * PPM) / denom; // <= PPM, so the square is bounded
            impactPpm = PPM - ((r * r) / PPM);
        }

        // Below the launcher's dust threshold the trait is free, which keeps a floor from
        // becoming a per-trade toll on trades too small to move anything.
        if (sizePpm < minSizePpm) return (0, newState);

        uint256 raw = (impactPpm * sharePpm) / PPM;
        if (raw < floorPpm) raw = floorPpm;

        addFeePpm = _fee(raw, cap);
    }

    function describe() external pure returns (string memory family, string memory name) {
        return ("physical", "Impact");
    }

    /// @dev Rejects the sentinel shapes that would silently disarm the mechanic (a zero
    /// share, a zero cap), rejects a share above one whole impact (which would charge
    /// more than the trade moves and turn a dealer's fee into a penalty), rejects a floor
    /// above the cap (which would make the cap a lie on every small trade), and rejects
    /// any bit set above the last defined field. RULE 5: a parameter set to a reserved
    /// value is how float disarmed a quorum breaker on three markets by an exact tie on
    /// an inclusive comparison.
    function validate(bytes32 params) external pure returns (bool) {
        if (_above(params, SH_END) != 0) return false;
        uint256 sharePpm = _bits(params, SH_SHARE, 24);
        uint256 cap = _bits(params, SH_CAP, 24);
        uint256 floorPpm = _bits(params, SH_FLOOR, 24);
        uint256 minSizePpm = _bits(params, SH_MINSIZE, 24);
        if (!_inRange(sharePpm, 1, PPM)) return false;
        if (!_inRange(cap, 1, MAX_ADD_PPM)) return false;
        if (floorPpm > cap) return false;
        if (minSizePpm > PPM) return false;
        return true;
    }
}
