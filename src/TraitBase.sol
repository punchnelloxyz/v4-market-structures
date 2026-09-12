// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ITrait} from "../interfaces/ITrait.sol";

/// @title TraitBase
/// @notice Shared, revert-free arithmetic for every FourthStreet trait. No storage, no state,
/// no external calls, nothing to configure. Each trait inherits it and pays for the few
/// hundred bytes of inlined helpers it actually uses.
///
/// @dev EVERY FOURTHSTREET TRAIT IS `pure`, NOT `view`. `ITrait.quote` is declared `view` and
/// Solidity permits an implementation to tighten that to `pure`, so every trait in this
/// directory does. A `pure` function cannot read storage, cannot read a balance, cannot
/// read `slot0`, cannot read the hook, and cannot call anything. That is a stronger
/// guarantee than the interface asks for and it is the point: a trait's answer is a
/// function of the `Ctx` the hook handed it and of nothing else in the world. It makes
/// the same trait behave identically either side of the CURVE to AMM flip, which is the
/// failure that killed ~/vector's floor-vector (it deserialized the pool to read
/// reserves, so it could not attach to a curve at all and missed the exact phase whose
/// volume it existed to fund).
///
/// @dev EVERY TRAIT IN THIS DIRECTORY IS STATELESS AND SHARED. One deployed instance
/// serves every launch. All configuration arrives in `Ctx.params`, frozen at launch by
/// the factory, and all per-launch memory arrives in `Ctx.state`, owned by the hook.
/// There is no constructor argument, no owner, no setter and no upgrade path anywhere in
/// this directory.
///
/// @dev A TRAIT MUST NEVER REVERT. A revert inside `beforeSwap` would kill every swap in
/// that pool permanently if the hook did not catch it, and the hook charging a fault fee
/// instead is a degradation, not a success. So every helper here saturates rather than
/// overflowing, guards every division, and clamps every input. `_satSub` is used in
/// place of `-` everywhere a timestamp or a reserve is differenced, because `Ctx` is
/// supplied by the hook and a trait does not get to assume the hook is correct.
///
/// @dev A TRAIT CANNOT REFUSE ANYTHING. Fee is the only lever, in either direction, and
/// that is now enforced by the TYPE rather than by a house rule: `ITrait.quote` returns a
/// fee and a state word and has no refusal channel at all. An exit from a position is
/// therefore available in every block of every launch, structurally, and a trait written
/// after the hook is immutable on chain cannot change that.
abstract contract TraitBase is ITrait {
    // -----------------------------------------------------------------------
    // Constants
    // -----------------------------------------------------------------------

    /// @dev Parts per million, the unit `addFeePpm` is denominated in.
    uint256 internal constant PPM = 1_000_000;

    /// @notice The hard ceiling any single trait in this directory will ever return.
    /// @dev 100,000 ppm is 10%, and it is the hook's own `FEE_CEIL_PPM`. It is repeated
    /// here so a trait is bounded on its own, before the hook's clamp, which is the
    /// belt-and-braces the brief asks for: the trait clamps to its frozen per-launch
    /// cap, the trait clamps again to this, and the hook clamps a third time to the
    /// slot's frozen `capPpm` and then to `min(maxFeePpm, FEE_CEIL_PPM)`.
    /// @dev It matters that the total stays STRICTLY below 1,000,000. v4's
    /// `Pool.swap` checks `swapFee >= SwapMath.MAX_SWAP_FEE` ABOVE the zero-amount early
    /// return and reverts `InvalidFeeForExactOut`, so a fee of exactly 1e6 bricks every
    /// exact-output swap in the pool forever while exact-input keeps working. Half a
    /// pool, permanently, with no upgrade path.
    /// @dev RAISED 2026-09-08 from 100,000 (10%) to 600,000 (60%), to allow the Outage
    /// trait's transient spike. This is the ABSOLUTE bound, not a default: every launch
    /// still carries its own `maxFeePpm` and the effective ceiling is
    /// `min(maxFeePpm, FEE_CEIL_PPM)`, so 60% is opt-in per launch rather than available
    /// to every trait by accident. Launch defaults stay at 10%.
    /// @dev 600,000 is safe against v4's `SwapMath.MAX_SWAP_FEE = 1e6`. `p.feePpm` is
    /// handed to the PoolManager as a dynamic-fee OVERRIDE and is therefore the whole
    /// swap fee, not an addition to a base, so the total can never approach 1e6 from
    /// here. A fee of exactly 1e6 would revert `InvalidFeeForExactOut` above the
    /// zero-amount early return and brick every exact-output swap in the pool forever.
    uint24 internal constant MAX_ADD_PPM = 600_000;

    uint256 internal constant DAY = 86_400;

    /// @dev 365 days exactly. Carry rates are quoted per annum and the extra quarter day
    /// a Julian year would add is well inside the rounding of a published sponsor fee.
    uint256 internal constant YEAR = 365 * DAY;

    uint256 internal constant U128_MAX = type(uint128).max;

    // -----------------------------------------------------------------------
    // Saturating arithmetic
    // -----------------------------------------------------------------------

    /// @dev Subtraction that returns 0 instead of reverting. Used for every timestamp
    /// and reserve difference, because `Ctx` comes from the hook and a trait does not
    /// get to assume `ts >= launchedAt` or `supply >= tRes`.
    function _satSub(uint256 a, uint256 b) internal pure returns (uint256) {
        unchecked {
            return a > b ? a - b : 0;
        }
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /// @dev Division that answers 0 rather than reverting on a zero denominator.
    function _divSafe(uint256 a, uint256 b) internal pure returns (uint256) {
        return b == 0 ? 0 : a / b;
    }

    /// @dev `a * b / d`, where a and b are each known to fit in uint128 so the product
    /// cannot overflow uint256: (2^128 - 1)^2 < 2^256. Every caller here upholds that by
    /// clamping to `U128_MAX` first, because the reserves in `Ctx` are uint128 and
    /// `specified` is the only uint256 a trader controls.
    function _mulDiv128(uint256 a, uint256 b, uint256 d) internal pure returns (uint256) {
        if (d == 0) return 0;
        if (a > U128_MAX) a = U128_MAX;
        if (b > U128_MAX) b = U128_MAX;
        return (a * b) / d;
    }

    // -----------------------------------------------------------------------
    // Fee clamping
    // -----------------------------------------------------------------------

    /// @notice Clamp a raw fee to this launch's frozen cap and to the directory ceiling.
    /// @dev Every `quote` in this directory returns through here. There is no path in
    /// any trait that returns a number this function has not bounded.
    function _fee(uint256 raw, uint256 cap) internal pure returns (uint24) {
        uint256 hi = cap < MAX_ADD_PPM ? cap : MAX_ADD_PPM;
        return uint24(_min(raw, hi));
    }

    // -----------------------------------------------------------------------
    // Reading the trade out of Ctx
    // -----------------------------------------------------------------------

    /// @notice The curve's marginal price, underlying per token, 18 decimals.
    /// @dev Both legs of a FourthStreet pool are 18 decimals (every Robinhood token on 4663 was
    /// checked with `decimals()`, all 193 are 18, and `FourthStreetToken` fixes 18), so this
    /// carries no scale factor. USDG's 6 decimals never reach a trait; that 1e12
    /// asymmetry belongs entirely to the periphery router (RULE 16).
    /// @dev `Ctx.uWad` INCLUDES the launch's virtual reserve offset, so this is the
    /// curve's quoted price and not a measure of real backing. Real backing is
    /// `claimedU`.
    function _priceU18(Ctx calldata c) internal pure returns (uint256) {
        if (c.tRes == 0) return 0;
        return (uint256(c.uWad) * 1e18) / uint256(c.tRes);
    }

    /// @dev Which currency `Ctx.specified` is denominated in.
    ///   buying  + exactInput  -> underlying in
    ///   buying  + exactOutput -> token out
    ///   selling + exactInput  -> token in
    ///   selling + exactOutput -> underlying out
    /// which collapses to `buying == exactInput`.
    function _specifiedIsUnderlying(Ctx calldata c) internal pure returns (bool) {
        return c.buying == c.exactInput;
    }

    /// @notice The trade's size expressed in the underlying, at the marginal price.
    /// @dev APPROXIMATE ON PURPOSE, and the direction of the error is stated so nobody
    /// has to rediscover it. The marginal price is the best price in the trade, so
    /// converting a token amount at it OVERSTATES a buy's underlying cost and
    /// UNDERSTATES what a sell realises. A trait must never depend on this being exact;
    /// these traits use it only for a monotone ramp, never for settlement.
    function _sizeU(Ctx calldata c) internal pure returns (uint256) {
        uint256 s = c.specified;
        if (s > U128_MAX) s = U128_MAX;
        if (_specifiedIsUnderlying(c)) return s;
        if (c.tRes == 0) return 0;
        return _mulDiv128(s, c.uWad, c.tRes);
    }

    /// @notice The trade's size expressed in the launched token, at the marginal price.
    /// @dev Same approximation, mirrored. For a buy this OVERSTATES the tokens that
    /// actually leave the pool, because the realised fill walks up the curve away from
    /// the marginal price. `QuotaTrait` relies on that direction: overstating usage makes
    /// a quota bind sooner, which is the conservative side for a supply cap.
    function _sizeT(Ctx calldata c) internal pure returns (uint256) {
        uint256 s = c.specified;
        if (s > U128_MAX) s = U128_MAX;
        if (!_specifiedIsUnderlying(c)) return s;
        if (c.uWad == 0) return 0;
        return _mulDiv128(s, c.tRes, c.uWad);
    }

    // -----------------------------------------------------------------------
    // Params and state field access
    // -----------------------------------------------------------------------

    /// @dev Read `width` bits out of a packed word at `shift`. Widths used here are all
    /// well under 256, so the mask arithmetic cannot wrap.
    function _bits(bytes32 w, uint256 shift, uint256 width) internal pure returns (uint256) {
        return (uint256(w) >> shift) & ((uint256(1) << width) - 1);
    }

    /// @dev Everything at or above `shift`. Every `validate` in this directory requires
    /// this to be zero above the last defined field, so a launcher cannot freeze a word
    /// carrying meaning that a later reader would misinterpret. A frozen parameter is
    /// frozen forever; there is no setter anywhere.
    function _above(bytes32 w, uint256 shift) internal pure returns (uint256) {
        return uint256(w) >> shift;
    }

    function _inRange(uint256 v, uint256 lo, uint256 hi) internal pure returns (bool) {
        return v >= lo && v <= hi;
    }
}
