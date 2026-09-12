// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ITrait} from "../interfaces/ITrait.sol";
import {TraitBase} from "./TraitBase.sol";

/// @title CarryTrait
/// @notice Storage costs money, and somebody has been paying it since block one.
///
/// WHAT THIS SAYS ABOUT THE UNDERLYING, IN PLAIN LANGUAGE
/// A share of GLD is a claim on gold in a vault in London, and the vault is not free.
/// The sponsor deducts 0.40% a year from the metal itself, so the number of ounces
/// behind each share falls every single day whether or not anybody trades. SLV does the
/// same at 0.50%, USO at about 0.60%, SPY at 0.0945%. Nobody sends you an invoice; the
/// bar just gets smaller.
///
/// A FourthStreet pool holds the real thing. From the moment it opens it is a warehouse, and
/// it is paying rent on inventory it has not sold yet. This trait puts that rent on the
/// ticket. The fee starts at zero and rises at exactly the underlying's published
/// sponsor fee, so a launch that sits untouched for a year has accrued precisely the
/// carry the real asset lost in that year, and the trade that finally happens pays it.
///
/// It is the quietest mechanic in the directory and the most literal. There is no game
/// in it, no edge to find, nothing to time. That is the point: carry is not an event, it
/// is a fact, and a market that prices it as an event has the shape wrong.
///
/// @dev FAMILY: physical.
///
/// @dev SYMMETRIC. Buys and sells pay the same. Rent does not care which way you are
/// facing; the warehouse paid it either way. A one-sided carry would be a directional
/// bet dressed as a cost.
///
/// @dev MONOTONE AND CAPPED. The fee is a non-decreasing function of `ts - launchedAt`
/// and of nothing else, so it is completely predictable years in advance from the launch
/// record alone, and it saturates at `capPpm`. A UI can draw the whole curve at launch.
///
/// @dev STATELESS. Age is measured from `launchedAt`, which is frozen, so this trait
/// never needs to remember anything and returns `c.state` untouched. That makes its cost
/// to the hook a same-value SSTORE rather than a dirty one.
///
/// PARAMS, packed little end first into the frozen `bytes32`:
///   bits   0..23   carryPpmPerYear  uint24   1 .. 100000    (4000 = 0.40% a year = GLD)
///   bits  24..47   capPpm           uint24   1 .. 100000
///   bits  48..63   graceDays        uint16   0 .. 3650      free storage before rent starts
///   bits  64..255  MUST BE ZERO
///
/// WORKED SETTINGS, from the real published sponsor fees:
///   GLD   carryPpmPerYear 4000   (0.40%)
///   SLV   carryPpmPerYear 5000   (0.50%)
///   USO   carryPpmPerYear 6000   (0.60%)
///   SPY   carryPpmPerYear  945   (0.0945%)
///   SGOV  carryPpmPerYear  900   (0.09%)
/// A treasury fund's fee is real too, which is why SGOV is on the list. The trait does
/// not know or care what the number means; it means whatever the launcher can defend.
///
/// COST. Constant. One `_satSub`, one multiply, one divide, one clamp. No loops, no
/// branches on trader input, no state transition.
contract CarryTrait is TraitBase {
    uint256 private constant SH_CARRY = 0;
    uint256 private constant SH_CAP = 24;
    uint256 private constant SH_GRACE = 48;
    uint256 private constant SH_END = 64;

    uint256 private constant MAX_CARRY_PPM_YEAR = 100_000; // 10% a year, far above any real fund
    uint256 private constant MAX_GRACE_DAYS = 3650; // ten years

    function quote(Ctx calldata c) external pure returns (uint24 addFeePpm, bytes32 newState) {
        newState = c.state;

        uint256 ratePpmYear = _bits(c.params, SH_CARRY, 24);
        uint256 cap = _bits(c.params, SH_CAP, 24);
        uint256 graceSec = _bits(c.params, SH_GRACE, 16) * DAY;

        // A zero rate or a zero cap is an unconfigured slot. Charge nothing rather than
        // guessing, and let `validate` be the thing that stops it being frozen that way.
        if (ratePpmYear == 0 || cap == 0) return (0, newState);

        uint256 age = _satSub(c.ts, c.launchedAt);
        uint256 billable = _satSub(age, graceSec);
        if (billable == 0) return (0, newState);

        // ratePpmYear <= 100000 and billable is a timestamp difference, so the product is
        // bounded by 1e5 * 2^40 which is about 1.1e17. It cannot overflow.
        uint256 accrued = (ratePpmYear * billable) / YEAR;

        addFeePpm = _fee(accrued, cap);
    }

    function describe() external pure returns (string memory family, string memory name) {
        return ("physical", "Carry");
    }

    /// @dev Rejects the two sentinel shapes that would silently disarm the mechanic (a
    /// zero rate, a zero cap), rejects a grace period long enough that the trait would
    /// be inert for a launch's whole life, and rejects any bit set above the last
    /// defined field. RULE 5: a parameter set to a reserved value is how float disarmed
    /// a quorum breaker on three markets by an exact tie on an inclusive comparison.
    function validate(bytes32 params) external pure returns (bool) {
        if (_above(params, SH_END) != 0) return false;
        uint256 rate = _bits(params, SH_CARRY, 24);
        uint256 cap = _bits(params, SH_CAP, 24);
        uint256 grace = _bits(params, SH_GRACE, 16);
        if (!_inRange(rate, 1, MAX_CARRY_PPM_YEAR)) return false;
        if (!_inRange(cap, 1, MAX_ADD_PPM)) return false;
        if (grace > MAX_GRACE_DAYS) return false;
        return true;
    }
}
