// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ClauseBase} from "../../base/ClauseBase.sol";

/// @title PartyRegistryClauseLogicV3
/// @notice Self-describing party registry clause following v3 specification
/// @dev Logic contract executed via delegatecall from Agreement proxies.
///      Manages agreement parties and their roles. Roles are bytes32 identifiers
///      (use keccak256("ROLE_NAME")).
///
///      This clause is typically first in an agreement pipeline, providing party
///      lists to downstream clauses via handoff functions.
///
///      Example role definitions:
///        bytes32 constant SIGNER = keccak256("SIGNER");
///        bytes32 constant ARBITER = keccak256("ARBITER");
///        bytes32 constant BENEFICIARY = keccak256("BENEFICIARY");
contract PartyRegistryClauseLogicV3 is ClauseBase {
    // =============================================================
    // STATES (bitmask)
    // =============================================================

    // Uses UNINITIALIZED from ClauseBase (1 << 0 = 0x0001)
    uint16 internal constant ACTIVE = 1 << 1; // 0x0002

    // =============================================================
    // ERC-7201 NAMESPACED STORAGE
    // =============================================================

    /// @custom:storage-location erc7201:papre.clause.partyregistry.storage
    struct PartyRegistryStorage {
        /// @notice instanceId => clause state
        mapping(bytes32 => uint16) status;
        /// @notice instanceId => all unique parties registered
        mapping(bytes32 => address[]) parties;
        /// @notice instanceId => party => is registered
        mapping(bytes32 => mapping(address => bool)) isParty;
        /// @notice instanceId => party => array of roles they hold
        mapping(bytes32 => mapping(address => bytes32[])) partyRoles;
        /// @notice instanceId => role => array of parties with that role
        mapping(bytes32 => mapping(bytes32 => address[])) roleParties;
        /// @notice instanceId => party => role => has role (O(1) lookup)
        mapping(bytes32 => mapping(address => mapping(bytes32 => bool))) hasRole;
    }

    // keccak256(abi.encode(uint256(keccak256("papre.clause.partyregistry.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT = 0xe71edd7a17bf0aa0275f121442c57c2a84deb99e132bbadf61f10bb96e4a3900;

    function _getStorage() internal pure returns (PartyRegistryStorage storage $) {
        assembly {
            $.slot := STORAGE_SLOT
        }
    }

    // =============================================================
    // INTAKE (from previous clause / setup)
    // =============================================================

    /// @notice Add a single party with a role
    /// @param instanceId Unique identifier for this registry instance
    /// @param party The address to register
    /// @param role The role to assign (use keccak256("ROLE_NAME"))
    function intakeParty(bytes32 instanceId, address party, bytes32 role) external {
        PartyRegistryStorage storage $ = _getStorage();
        // Status 0 means uninitialized (fresh storage)
        require($.status[instanceId] == 0, "Wrong state");
        _addPartyWithRole($, instanceId, party, role);
    }

    /// @notice Add multiple parties with the same role
    /// @param instanceId Unique identifier for this registry instance
    /// @param parties Array of addresses to register
    /// @param role The role to assign to all parties
    function intakeParties(bytes32 instanceId, address[] calldata parties, bytes32 role) external {
        PartyRegistryStorage storage $ = _getStorage();
        // Status 0 means uninitialized (fresh storage)
        require($.status[instanceId] == 0, "Wrong state");
        for (uint256 i = 0; i < parties.length; i++) {
            _addPartyWithRole($, instanceId, parties[i], role);
        }
    }

    /// @notice Signal that party registration is complete, transition to ACTIVE
    /// @param instanceId Unique identifier for this registry instance
    function intakeReady(bytes32 instanceId) external {
        PartyRegistryStorage storage $ = _getStorage();
        // Status 0 means uninitialized (fresh storage)
        require($.status[instanceId] == 0, "Wrong state");
        $.status[instanceId] = ACTIVE;
    }

    // =============================================================
    // ACTIONS (state-changing)
    // =============================================================

    // None for now - this is an intake-only clause
    // Future: Could add actionAddParty, actionRemoveParty for dynamic membership

    // =============================================================
    // HANDOFF (to next clause)
    // =============================================================

    /// @notice Get all parties with a specific role - for wiring to downstream clauses
    /// @param instanceId Unique identifier for this registry instance
    /// @param role The role to query
    /// @return Array of addresses with that role
    function handoffPartiesInRole(bytes32 instanceId, bytes32 role) external view returns (address[] memory) {
        PartyRegistryStorage storage $ = _getStorage();
        require($.status[instanceId] == ACTIVE, "Wrong state");
        return $.roleParties[instanceId][role];
    }

    /// @notice Get all registered parties - for wiring to downstream clauses
    /// @param instanceId Unique identifier for this registry instance
    /// @return Array of all party addresses
    function handoffAllParties(bytes32 instanceId) external view returns (address[] memory) {
        PartyRegistryStorage storage $ = _getStorage();
        require($.status[instanceId] == ACTIVE, "Wrong state");
        return $.parties[instanceId];
    }

    // =============================================================
    // QUERIES (always available)
    // =============================================================

    /// @notice Get the current state of an instance
    /// @param instanceId Unique identifier for this registry instance
    /// @return Current state bitmask
    function queryStatus(bytes32 instanceId) external view returns (uint16) {
        return _getStorage().status[instanceId];
    }

    /// @notice Check if a party has a specific role (O(1) lookup)
    /// @param instanceId Unique identifier for this registry instance
    /// @param party The address to check
    /// @param role The role to check for
    /// @return True if the party has the role
    function queryHasRole(bytes32 instanceId, address party, bytes32 role) external view returns (bool) {
        return _getStorage().hasRole[instanceId][party][role];
    }

    /// @notice Get all parties with a specific role
    /// @param instanceId Unique identifier for this registry instance
    /// @param role The role to query
    /// @return Array of addresses with that role
    function queryPartiesInRole(bytes32 instanceId, bytes32 role) external view returns (address[] memory) {
        return _getStorage().roleParties[instanceId][role];
    }

    /// @notice Get all roles held by a specific party
    /// @param instanceId Unique identifier for this registry instance
    /// @param party The address to query
    /// @return Array of role identifiers
    function queryRolesForParty(bytes32 instanceId, address party) external view returns (bytes32[] memory) {
        return _getStorage().partyRoles[instanceId][party];
    }

    /// @notice Get all registered parties
    /// @param instanceId Unique identifier for this registry instance
    /// @return Array of all party addresses
    function queryAllParties(bytes32 instanceId) external view returns (address[] memory) {
        return _getStorage().parties[instanceId];
    }

    /// @notice Get the total number of unique parties
    /// @param instanceId Unique identifier for this registry instance
    /// @return Count of registered parties
    function queryPartyCount(bytes32 instanceId) external view returns (uint256) {
        return _getStorage().parties[instanceId].length;
    }

    /// @notice Check if an address is a registered party
    /// @param instanceId Unique identifier for this registry instance
    /// @param party The address to check
    /// @return True if the address is registered
    function queryIsParty(bytes32 instanceId, address party) external view returns (bool) {
        return _getStorage().isParty[instanceId][party];
    }

    // =============================================================
    // INTERNAL
    // =============================================================

    /// @notice Internal helper to add a party with a role
    /// @dev Handles deduplication for both parties and role assignments
    function _addPartyWithRole(PartyRegistryStorage storage $, bytes32 instanceId, address party, bytes32 role)
        private
    {
        require(party != address(0), "Invalid party address");
        require(role != bytes32(0), "Invalid role");

        // Add to parties list if new
        if (!$.isParty[instanceId][party]) {
            $.parties[instanceId].push(party);
            $.isParty[instanceId][party] = true;
        }

        // Add role if not already assigned
        if (!$.hasRole[instanceId][party][role]) {
            $.hasRole[instanceId][party][role] = true;
            $.partyRoles[instanceId][party].push(role);
            $.roleParties[instanceId][role].push(party);
        }
    }
}
