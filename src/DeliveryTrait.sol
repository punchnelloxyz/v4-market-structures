// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ITrait} from "../interfaces/ITrait.sol";
import {TraitBase} from "./TraitBase.sol";

/// @title DeliveryTrait
/// @notice What happens when more people hold a claim on the warehouse than the
/// warehouse can actually deliver.
///
/// WHAT THIS SAYS ABOUT THE UNDERLYING, IN PLAIN LANGUAGE
/// Every commodity market eventually arrives at the same question, and it is not a
/// question about price. It is: if everybody who holds a contract asked for the metal
/// today, is the metal there. Usually nobody asks, and the answer never gets tested. On
/// the days it does get tested the market stops behaving like a market. In March 2022 the
/// LME found more nickel contracts outstanding than deliverable nickel, the price tripled
/// in a morning, and the exchange cancelled a day of trades. In April 2020 the opposite
/// squeeze ran the other way: nobody could take delivery of oil at Cushing, and the
/// contract printed negative forty dollars.
///
/// A FourthStreet launch has exactly this shape, honestly and by construction. Tokens held
/// outside the pool are open interest: claims on the warehouse. The underlying the pool
/// actually holds is the deliverable. And on a constant-product curve those two numbers
/// diverge by arithmetic, not by anyone's fault: the pool's coverage of its own
/// mark-to-market open interest is exactly the fraction of supply still unsold, so a
/// launch that has sold three quarters of its tokens can deliver on one quarter of what
/// those tokens are marked at. The last seller out receives the first buyer's price. That
/// is a redemption schedule, not a floor, and it is true of every bonding curve ever
/// deployed. Most of them do not say so.
///
/// This trait says so, continuously, in the price. As coverage falls, buying gets more
/// expensive and selling never does. And on a schedule, at the end of every delivery
/// period, the window opens: for a few hours the squeeze charge goes to its maximum, and
/// if the launch was configured that way, new longs cannot be opened at all until the
/// window closes. You can always get out. You cannot always get in.
///
/// It is not a warning label. It is the warning label priced into the ticket, which is
/// the only kind anybody reads.
///
/// @dev FAMILY: delivery.
///
/// @dev COVERAGE, EXACTLY. `oi = supply - tRes` is the token float outside the pool.
/// `notional = oi * uWad / tRes` is that float marked at the curve's marginal price.
/// `deliverable = claimedU - feeWad` is the underlying this launch's own claim ledger
/// says it can actually pay out, net of fees it owes elsewhere. `coverage = deliverable /
/// notional`, in ppm, capped at 1.0. On an unmodified constant-product curve this equals
/// `tRes / supply` identically, which is a useful sanity check for a test to assert.
/// It uses `claimedU`, the launch's OWN ledger, and never a token balance or the hook's
/// shared ERC-6909 balance: claim ids are per currency, so two launches on the same
/// underlying share one balance and that number says nothing about either of them.
///
/// @dev THE WINDOW ALWAYS ENDS, AND `validate` PROVES IT. The window is at most half of
/// its period, so trading is open for at least half of every cycle, and the phase is
/// `(ts - launchedAt) % periodSeconds` which is pure arithmetic on the frozen launch
/// time. There is no way to configure a permanent halt and no way to extend one, because
/// there is no setter anywhere in this contract.
///
/// @dev IT REFUSES BUYS ONLY, NEVER SELLS. This is the one trait in the directory that
/// prices the squeeze rather than forbidding it. A trait cannot refuse at all since
/// 2026-09-08, so an exit is
/// available in every block of every launch, in every window, at every coverage level.
/// A trait that could trap a holder would be a worse product than no trait at all.
///
/// @dev INERT AFTER GRADUATION. In AMM mode the hook stops updating `uWad` and `tRes`,
/// so coverage would freeze at whatever it was at the flip and the trait would charge a
/// constant toll forever on a number that no longer means anything. It returns zero in
/// mode 2 instead, and this is a deliberate switch rather than an accident of frozen
/// state: the warehouse became a two-sided market, and delivery risk is what a warehouse
/// has.
///
/// PARAMS, packed little end first into the frozen `bytes32`:
///   bits   0..23   squeezePpm    uint24   1 .. 100000    charge at zero coverage
///   bits  24..47   coverThreshPpm uint24  1 .. 1000000   coverage at which it engages
///   bits  48..63   periodDays    uint16   0 .. 3650      0 disables the window entirely
///   bits  64..79   windowHours   uint16   0 .. 8760      must be 0 iff periodDays is 0
///   bits  80..87   haltBuys      uint8    0 or 1
///   bits  88..255  MUST BE ZERO
///
/// WORKED SETTINGS
///   squeezePpm 30000 (3% at zero coverage), coverThreshPpm 500000 (engages once the
///   warehouse covers less than half its own float), periodDays 30, windowHours 8,
///   haltBuys 1. A monthly contract with an eight hour delivery window at the end of it.
///
/// COST. Constant. Two divides for coverage, one modulo for the window, one clamp. No
/// loops, no state.
contract DeliveryTrait is TraitBase {
    uint256 private constant SH_SQUEEZE = 0;
    uint256 private constant SH_THRESH = 24;
    uint256 private constant SH_PERIOD = 48;
    uint256 private constant SH_WINDOW = 64;
    uint256 private constant SH_HALT = 80;
    uint256 private constant SH_END = 88;

    uint256 private constant HOUR = 3600;
    uint256 private constant MAX_PERIOD_DAYS = 3650;
    uint256 private constant MAX_WINDOW_HOURS = 8760;

    uint8 private constant MODE_AMM = 2;

    function quote(Ctx calldata c) external pure returns (uint24 addFeePpm, bytes32 newState) {
        newState = c.state;

        // Selling always relieves the squeeze. It is never charged and never refused.
        if (!c.buying) return (0, newState);

        // After the flip there is no warehouse to run out of. See the note above.
        if (c.mode == MODE_AMM) return (0, newState);

        uint256 squeeze = _bits(c.params, SH_SQUEEZE, 24);
        uint256 thresh = _bits(c.params, SH_THRESH, 24);
        if (squeeze == 0 || thresh == 0) return (0, newState);

        uint256 periodSec = _bits(c.params, SH_PERIOD, 16) * DAY;
        uint256 windowSec = _bits(c.params, SH_WINDOW, 16) * HOUR;

        if (periodSec != 0 && windowSec != 0 && windowSec < periodSec) {
            uint256 phase = _satSub(c.ts, c.launchedAt) % periodSec;
            if (phase >= periodSec - windowSec) {
                // Delivery. The charge is at its maximum for the whole window, and if
                // the launch was configured to halt, entry is priced at this slot's
                // ceiling for the duration.
                //
                // IT NO LONGER BLOCKS. Until 2026-09-08 this returned `refuse` for a buy
                // inside the window, which made a launch unenterable for a bounded period.
                // `refuse` is gone from `ITrait` entirely and a halt now charges the
                // maximum instead. The economics of a squeeze are preserved (getting in
                // during delivery is punitive) without any window in which the market is
                // shut, which is the standing rule: nothing is ever forbidden, you just
                // have to outbid it.
                uint256 charge = _bits(c.params, SH_HALT, 8) == 1 ? MAX_ADD_PPM : squeeze;
                return (_fee(charge, charge), newState);
            }
        }

        uint256 cov = _coveragePpm(c);
        if (cov >= thresh) return (0, newState);

        // Linear ramp: zero at the threshold, the full squeeze charge at zero coverage.
        // squeeze <= 1e5 and the shortfall <= 1e6, so the product is under 1e11.
        uint256 raw = (squeeze * (thresh - cov)) / thresh;
        addFeePpm = _fee(raw, squeeze);
    }

    /// @notice What fraction of its own marked-to-market float this launch could actually
    /// deliver, in ppm, capped at 1.0.
    /// @dev Public so a UI, an indexer or a test can read the same number the fee is
    /// computed from, with the same code, rather than reimplementing it and drifting
    /// (RULE 7: float shipped a preview that omitted a bound the transaction applied).
    function coveragePpm(Ctx calldata c) external pure returns (uint256) {
        return _coveragePpm(c);
    }

    function _coveragePpm(Ctx calldata c) internal pure returns (uint256) {
        uint256 oi = _satSub(c.supply, c.tRes);
        if (oi == 0) return PPM; // nothing has left the warehouse yet
        if (c.tRes == 0) return 0; // the warehouse is empty and claims are outstanding

        uint256 notional = _mulDiv128(oi, c.uWad, c.tRes);
        if (notional == 0) return PPM;

        uint256 deliverable = _satSub(c.claimedU, c.feeWad);
        uint256 cov = (deliverable * PPM) / notional;
        return _min(cov, PPM);
    }

    function describe() external pure returns (string memory family, string memory name) {
        return ("delivery", "Delivery");
    }

    /// @dev The window rules are the safety property of this contract, so they are
    /// checked here and not merely documented. A period of zero disables the window and
    /// then a non-zero window or halt flag is a contradiction rather than a default, and
    /// is rejected. A non-zero period requires a non-zero window, so a launch cannot
    /// advertise a delivery schedule that never arrives. And `windowSec * 2 <= periodSec`
    /// bounds the halt at half of every cycle, which is what makes "you can always get
    /// out, and you can get in at least half the time" a checked claim.
    function validate(bytes32 params) external pure returns (bool) {
        if (_above(params, SH_END) != 0) return false;

        uint256 squeeze = _bits(params, SH_SQUEEZE, 24);
        uint256 thresh = _bits(params, SH_THRESH, 24);
        uint256 periodDays = _bits(params, SH_PERIOD, 16);
        uint256 windowHours = _bits(params, SH_WINDOW, 16);
        uint256 halt = _bits(params, SH_HALT, 8);

        if (!_inRange(squeeze, 1, MAX_ADD_PPM)) return false;
        if (!_inRange(thresh, 1, PPM)) return false;
        if (halt > 1) return false;
        if (periodDays > MAX_PERIOD_DAYS) return false;
        if (windowHours > MAX_WINDOW_HOURS) return false;

        if (periodDays == 0) {
            // No delivery schedule. Then there is no window and nothing to halt.
            return windowHours == 0 && halt == 0;
        }
        if (windowHours == 0) return false;
        return windowHours * HOUR * 2 <= periodDays * DAY;
    }
}
