// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ITrait} from "../interfaces/ITrait.sol";
import {TraitBase} from "./TraitBase.sol";

/// @title NullTrait
/// @notice A trait that expresses nothing about the underlying, on purpose.
///
/// WHAT THIS SAYS ABOUT THE UNDERLYING, IN PLAIN LANGUAGE
/// Nothing. This is a plain token backed by a plain share, priced by a plain curve. It
/// is the control in the experiment: a launch that installs only this one behaves
/// exactly as though no trait were installed at all, and the difference between its
/// chart and its neighbour's is entirely the neighbour's mechanic. Without a control
/// there is no way to tell a trait's effect from the market's mood.
///
/// @dev THIS IS THE REFERENCE IMPLEMENTATION. It is the shortest complete answer to
/// "what does a trait have to do", it is the baseline every gas number in this
/// directory is quoted against, and it is the fixture a hook test should install when it
/// wants a trait slot occupied and no behaviour changed.
///
/// @dev `describe` returns the family "reference", which is deliberately NOT one of the
/// four families `ITrait` lists (physical, delivery, term, supply). Labelling a no-op as
/// physical would be a lie in the UI, and this is the only trait in the directory that
/// is outside the taxonomy. Every other trait returns one of the four.
///
/// @dev It returns `c.state` unchanged rather than `bytes32(0)`, so the hook's persist
/// is a same-value SSTORE (about 100 gas) rather than a clear. It also means installing
/// this trait into a slot that previously held state does not erase the record.
///
/// COST. Constant. No branches on trader input, no loops, no state transition, two
/// calldata reads. See the measured figures in the directory report.
contract NullTrait is TraitBase {
    function quote(Ctx calldata c) external pure returns (uint24 addFeePpm, bytes32 newState) {
        return (0, c.state);
    }

    function describe() external pure returns (string memory family, string memory name) {
        return ("reference", "Null");
    }

    /// @dev Accepts ONLY the zero word. A no-op trait has no configuration, so any
    /// non-zero parameter is a launcher believing something that is not true, and the
    /// place to catch that is before it is frozen forever (RULE 6: no meaningful default
    /// exists anywhere, and every reader tests a field that cannot legitimately be
    /// wrong).
    function validate(bytes32 params) external pure returns (bool) {
        return params == bytes32(0);
    }
}
