// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title ClauseBase
/// @notice Base contract for v3 clause primitives
/// @dev Provides common state constants for bitmask state machines.
///      Clauses use ERC-7201 namespaced storage for collision-free storage when
///      executed via delegatecall from Agreement proxies.
abstract contract ClauseBase {
    // Common state constants available to all clauses
    // Each clause may define additional states as needed
    uint16 internal constant UNINITIALIZED = 1 << 0;  // 0x0001
    uint16 internal constant PENDING       = 1 << 1;  // 0x0002
    uint16 internal constant COMPLETE      = 1 << 2;  // 0x0004
    uint16 internal constant CANCELLED     = 1 << 3;  // 0x0008
}
