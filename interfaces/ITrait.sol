// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ITrait
/// @notice The one and only interface a FourthStreet trait module implements.
///
/// @dev A trait can do exactly ONE thing: make a trade more expensive. It cannot refuse.
/// Nothing else.
///
/// @dev THE REFUSAL CAPABILITY WAS REMOVED 2026-09-08, deliberately and by the user's
/// standing rule that nothing may ever cap or block a trade in either direction. It is
/// gone from the TYPE, not merely unused, so no trait written after the hook is immutable
/// on chain can reintroduce it. That closes three abuses an audit found and left standing
/// precisely because this change was coming: a trait refusing a SELL in perpetuity so a
/// position could never be exited, a gas-starved refusal bypass, and refusal behaviour not
/// being frozen at launch the way a fee schedule is.
///
/// The mechanics that wanted it keep working by pricing instead of forbidding, which is
/// what QuotaTrait already says: nothing is ever forbidden, you can always have more, you
/// just have to outbid the quota. It cannot move a token, cannot change a reserve, cannot scale the
/// curve, cannot write storage, cannot reenter. That is deliberate and it is the whole
/// security argument: because a fee can only raise reserve-per-token and a refusal moves
/// nothing, the hook's solvency proof is one line and it covers every trait anyone ever
/// writes, including ones written after the hook is immutable on chain.
///
/// Wider interfaces were designed and rejected:
///   - returning a reserve delta lets a trait price a trade against one book while the
///     hook settles against another, which underflows the book or silently breaks the
///     floor invariant;
///   - a CALL rather than a STATICCALL lets a trait write storage, reenter and hold
///     funds, which is the Cork (about $11M) and Bunni ($8.4M) class;
///   - a curve scale factor changes the price without changing the reserve, which
///     breaks the floor invariant unless it can only tighten.
///
/// @dev A TRAIT IS ONLY EVER STATICCALLED, with a fixed gas stipend, inside try/catch.
/// A revert, an out-of-gas, or a returndata bomb is not an error condition: the hook
/// charges the trait's frozen fault fee and carries on. A trait must never be able to
/// brick a pool, because a revert inside beforeSwap kills every swap in that pool
/// permanently and there is no upgrade path.
///
/// @dev A TRAIT MUST NEVER READ VENUE STATE. Not slot0, not getLiquidity, not the
/// hook's own balances, not an external pool. Everything it is allowed to know is in
/// `Ctx`. This is what lets the same trait run unchanged on both sides of the CURVE to
/// AMM flip, where there is no pool liquidity before and real liquidity after. In
/// ~/vector the floor-vector read pool reserves directly and therefore could not attach
/// to a curve at all, so it missed the exact phase whose volume it existed to fund.
///
/// @dev EVERY SCHEDULE USES `Ctx.ts` (block.timestamp). Never block.number: on this
/// ArbOS chain block.number returns the L1 block, currently lagging the L2 height by
/// about 31.4 million, and L2 blocks are roughly 101ms. A fork test does NOT reproduce
/// this (Foundry seeds block.number from the RPC block's L2 number), so the grep gate
/// in script/check.sh is the only thing that catches it.
interface ITrait {
    /// @notice Everything a trait is permitted to see about the trade it is pricing.
    struct Ctx {
        /// @dev The launch's canonical id. `launchId` IS the v4 PoolId; there is no
        /// second identifier that can drift out of step with it.
        bytes32 poolId;
        /// @dev Which of the four install slots this trait occupies, 0 to 3.
        uint8 slot;
        /// @dev 1 CURVE, 2 AMM, 3 WINDDOWN. Mirrors the hook's Mode enum.
        uint8 mode;
        /// @dev True when the underlying is coming in and the token going out.
        /// The launched token is ALWAYS currency1, so `buying == zeroForOne`, always.
        bool buying;
        /// @dev True when the trader specified the input amount.
        bool exactInput;
        /// @dev The amount the trader specified, unsigned.
        uint256 specified;
        /// @dev Curve reserve of the underlying, FEE EXCLUSIVE. Accrued fees are in
        /// `feeWad` and are not part of the curve.
        uint128 uWad;
        /// @dev Curve reserve of the launched token.
        uint128 tRes;
        /// @dev Total supply of the launched token. Fixed at launch, never changes.
        uint128 supply;
        /// @dev Fees accrued in the underlying and not yet paid out.
        uint128 feeWad;
        /// @dev This pool's OWN claim ledger for the underlying, so a trait can see the
        /// solvency surplus. Never the hook's shared ERC-6909 balance: claim ids are
        /// per-currency, so two launches on the same underlying share one balance and
        /// that number says nothing about this launch.
        uint128 claimedU;
        /// @dev block.timestamp. NEVER block.number.
        uint40 ts;
        /// @dev block.timestamp at launch. Frozen.
        uint40 launchedAt;
        /// @dev beforeSwap's `sender`. THIS IS THE ROUTER, NEVER THE TRADER. Nothing
        /// may price off it. It is passed only so a trait can be honest about what it
        /// can and cannot see.
        address router;
        /// @dev The trait's own configuration, frozen at launch and never changed.
        bytes32 params;
        /// @dev Hook-owned state: the last word THIS trait returned for THIS pool. It
        /// lets a trait be a state machine (settlement windows, roll epochs, quota
        /// periods) without owning storage. The hook persists it only on a real swap,
        /// never on a view call.
        bytes32 state;
    }

    /// @notice Price this trade. STATICCALL ONLY.
    /// @dev The hook calls this from BOTH the swap path and the public quote view, with
    /// the same `Ctx`, so a poll that says yes IS a call that can execute. That makes
    /// RULE 7 structural rather than something a fuzz test has to defend: float shipped
    /// a preview that omitted a bound the transaction applied and advertised restocks
    /// that reverted every poll, silently, for hours.
    /// @param c Everything the trait may see.
    /// @return addFeePpm Extra fee in parts per million, ADDED to the launch's base fee.
    /// The hook clamps this to the trait's own frozen cap after return, then clamps the
    /// total. A trait cannot exceed its cap by returning a larger number.
    /// @return newState The word the hook persists for this trait on this pool.
    /// Ignored on a view call.
    function quote(Ctx calldata c) external view returns (uint24 addFeePpm, bytes32 newState);

    /// @notice Human-readable identity, for the UI and for the launch record.
    /// @return family One of: physical, delivery, term, supply.
    /// @return name The trait's own name.
    function describe() external pure returns (string memory family, string memory name);

    /// @notice Reject a configuration the trait cannot honour, BEFORE it is frozen.
    /// @dev Must reject any reserved or sentinel value. float set an oracle's
    /// maxStaleness to exactly the degraded-mode sentinel, so an inclusive comparison
    /// was true by an exact tie and a circuit breaker was disarmed on three markets
    /// (RULE 5). Every window, epoch and deadline a trait takes lands here.
    function validate(bytes32 params) external pure returns (bool);
}
