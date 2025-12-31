// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {PartyRegistryClauseLogicV3} from "../../../src/clauses/access/PartyRegistryClauseLogicV3.sol";

/// @title PartyRegistryClauseLogicV3 Unit Tests
/// @notice Tests for the v3 self-describing party registry clause with ERC-7201 storage
contract PartyRegistryClauseLogicV3Test is Test {

    PartyRegistryClauseLogicV3 public clause;

    // Test accounts
    address alice;
    address bob;
    address charlie;
    address david;

    // Instance IDs for testing
    bytes32 constant INSTANCE_1 = bytes32(uint256(1));
    bytes32 constant INSTANCE_2 = bytes32(uint256(2));

    // Role constants (matching typical usage)
    bytes32 constant SIGNER = keccak256("SIGNER");
    bytes32 constant ARBITER = keccak256("ARBITER");
    bytes32 constant BENEFICIARY = keccak256("BENEFICIARY");
    bytes32 constant ADMIN = keccak256("ADMIN");

    // State constants (matching the contract)
    uint16 constant UNINITIALIZED = 1 << 0;  // 0x0001
    uint16 constant ACTIVE        = 1 << 1;  // 0x0002

    function setUp() public {
        clause = new PartyRegistryClauseLogicV3();

        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");
        david = makeAddr("david");
    }

    // =============================================================
    // INITIAL STATE TESTS
    // =============================================================

    function test_InitialState_IsUninitialized() public view {
        // New instances start at 0
        assertEq(clause.queryStatus(INSTANCE_1), 0);
    }

    function test_QueryAllParties_InitiallyEmpty() public view {
        address[] memory parties = clause.queryAllParties(INSTANCE_1);
        assertEq(parties.length, 0);
    }

    function test_QueryPartyCount_InitiallyZero() public view {
        assertEq(clause.queryPartyCount(INSTANCE_1), 0);
    }

    // =============================================================
    // INTAKE TESTS - SINGLE PARTY
    // =============================================================

    function test_IntakeParty_Success() public {
        clause.intakeParty(INSTANCE_1, alice, SIGNER);

        assertTrue(clause.queryIsParty(INSTANCE_1, alice));
        assertTrue(clause.queryHasRole(INSTANCE_1, alice, SIGNER));
        assertEq(clause.queryPartyCount(INSTANCE_1), 1);
    }

    function test_IntakeParty_MultipleRoles() public {
        clause.intakeParty(INSTANCE_1, alice, SIGNER);
        clause.intakeParty(INSTANCE_1, alice, ADMIN);

        assertTrue(clause.queryIsParty(INSTANCE_1, alice));
        assertTrue(clause.queryHasRole(INSTANCE_1, alice, SIGNER));
        assertTrue(clause.queryHasRole(INSTANCE_1, alice, ADMIN));
        assertEq(clause.queryPartyCount(INSTANCE_1), 1); // Still just one party

        bytes32[] memory roles = clause.queryRolesForParty(INSTANCE_1, alice);
        assertEq(roles.length, 2);
    }

    function test_IntakeParty_DuplicateRoleIgnored() public {
        clause.intakeParty(INSTANCE_1, alice, SIGNER);
        clause.intakeParty(INSTANCE_1, alice, SIGNER); // Duplicate

        assertTrue(clause.queryHasRole(INSTANCE_1, alice, SIGNER));
        assertEq(clause.queryPartyCount(INSTANCE_1), 1);

        bytes32[] memory roles = clause.queryRolesForParty(INSTANCE_1, alice);
        assertEq(roles.length, 1); // Only one role, not duplicated
    }

    function test_IntakeParty_ZeroAddressReverts() public {
        vm.expectRevert("Invalid party address");
        clause.intakeParty(INSTANCE_1, address(0), SIGNER);
    }

    function test_IntakeParty_ZeroRoleReverts() public {
        vm.expectRevert("Invalid role");
        clause.intakeParty(INSTANCE_1, alice, bytes32(0));
    }

    function test_IntakeParty_OnlyInUninitialized() public {
        clause.intakeParty(INSTANCE_1, alice, SIGNER);
        clause.intakeReady(INSTANCE_1);

        // Now in ACTIVE state
        vm.expectRevert("Wrong state");
        clause.intakeParty(INSTANCE_1, bob, SIGNER);
    }

    // =============================================================
    // INTAKE TESTS - MULTIPLE PARTIES
    // =============================================================

    function test_IntakeParties_Success() public {
        address[] memory signers = new address[](3);
        signers[0] = alice;
        signers[1] = bob;
        signers[2] = charlie;

        clause.intakeParties(INSTANCE_1, signers, SIGNER);

        assertEq(clause.queryPartyCount(INSTANCE_1), 3);
        assertTrue(clause.queryHasRole(INSTANCE_1, alice, SIGNER));
        assertTrue(clause.queryHasRole(INSTANCE_1, bob, SIGNER));
        assertTrue(clause.queryHasRole(INSTANCE_1, charlie, SIGNER));

        address[] memory partiesInRole = clause.queryPartiesInRole(INSTANCE_1, SIGNER);
        assertEq(partiesInRole.length, 3);
    }

    function test_IntakeParties_EmptyArrayOk() public {
        address[] memory empty = new address[](0);
        clause.intakeParties(INSTANCE_1, empty, SIGNER);

        assertEq(clause.queryPartyCount(INSTANCE_1), 0);
    }

    function test_IntakeParties_OnlyInUninitialized() public {
        clause.intakeReady(INSTANCE_1);

        address[] memory parties = new address[](1);
        parties[0] = alice;

        vm.expectRevert("Wrong state");
        clause.intakeParties(INSTANCE_1, parties, SIGNER);
    }

    // =============================================================
    // INTAKE READY TESTS
    // =============================================================

    function test_IntakeReady_TransitionsToActive() public {
        clause.intakeParty(INSTANCE_1, alice, SIGNER);
        assertEq(clause.queryStatus(INSTANCE_1), 0); // Still uninitialized

        clause.intakeReady(INSTANCE_1);
        assertEq(clause.queryStatus(INSTANCE_1), ACTIVE);
    }

    function test_IntakeReady_EmptyRegistryAllowed() public {
        // Can activate with no parties (edge case, but allowed)
        clause.intakeReady(INSTANCE_1);
        assertEq(clause.queryStatus(INSTANCE_1), ACTIVE);
        assertEq(clause.queryPartyCount(INSTANCE_1), 0);
    }

    function test_IntakeReady_OnlyInUninitialized() public {
        clause.intakeReady(INSTANCE_1);

        // Already active
        vm.expectRevert("Wrong state");
        clause.intakeReady(INSTANCE_1);
    }

    // =============================================================
    // HANDOFF TESTS
    // =============================================================

    function test_HandoffPartiesInRole_Success() public {
        address[] memory signers = new address[](2);
        signers[0] = alice;
        signers[1] = bob;
        clause.intakeParties(INSTANCE_1, signers, SIGNER);
        clause.intakeParty(INSTANCE_1, charlie, ARBITER);
        clause.intakeReady(INSTANCE_1);

        address[] memory handedOff = clause.handoffPartiesInRole(INSTANCE_1, SIGNER);
        assertEq(handedOff.length, 2);
        assertEq(handedOff[0], alice);
        assertEq(handedOff[1], bob);
    }

    function test_HandoffPartiesInRole_EmptyRole() public {
        clause.intakeParty(INSTANCE_1, alice, SIGNER);
        clause.intakeReady(INSTANCE_1);

        address[] memory arbiters = clause.handoffPartiesInRole(INSTANCE_1, ARBITER);
        assertEq(arbiters.length, 0);
    }

    function test_HandoffPartiesInRole_OnlyInActive() public {
        clause.intakeParty(INSTANCE_1, alice, SIGNER);
        // Not activated yet

        vm.expectRevert("Wrong state");
        clause.handoffPartiesInRole(INSTANCE_1, SIGNER);
    }

    function test_HandoffAllParties_Success() public {
        clause.intakeParty(INSTANCE_1, alice, SIGNER);
        clause.intakeParty(INSTANCE_1, bob, ARBITER);
        clause.intakeParty(INSTANCE_1, charlie, BENEFICIARY);
        clause.intakeReady(INSTANCE_1);

        address[] memory all = clause.handoffAllParties(INSTANCE_1);
        assertEq(all.length, 3);
    }

    function test_HandoffAllParties_OnlyInActive() public {
        clause.intakeParty(INSTANCE_1, alice, SIGNER);

        vm.expectRevert("Wrong state");
        clause.handoffAllParties(INSTANCE_1);
    }

    // =============================================================
    // QUERY TESTS
    // =============================================================

    function test_QueryStatus_AlwaysAvailable() public {
        // In UNINITIALIZED (0)
        assertEq(clause.queryStatus(INSTANCE_1), 0);

        clause.intakeParty(INSTANCE_1, alice, SIGNER);
        clause.intakeReady(INSTANCE_1);

        // In ACTIVE
        assertEq(clause.queryStatus(INSTANCE_1), ACTIVE);
    }

    function test_QueryHasRole_AlwaysAvailable() public {
        // Before any intake
        assertFalse(clause.queryHasRole(INSTANCE_1, alice, SIGNER));

        clause.intakeParty(INSTANCE_1, alice, SIGNER);

        // After intake but before ready
        assertTrue(clause.queryHasRole(INSTANCE_1, alice, SIGNER));
        assertFalse(clause.queryHasRole(INSTANCE_1, alice, ARBITER));
        assertFalse(clause.queryHasRole(INSTANCE_1, bob, SIGNER));

        clause.intakeReady(INSTANCE_1);

        // After ready
        assertTrue(clause.queryHasRole(INSTANCE_1, alice, SIGNER));
    }

    function test_QueryPartiesInRole_AlwaysAvailable() public {
        // Before intake
        address[] memory empty = clause.queryPartiesInRole(INSTANCE_1, SIGNER);
        assertEq(empty.length, 0);

        clause.intakeParty(INSTANCE_1, alice, SIGNER);
        clause.intakeParty(INSTANCE_1, bob, SIGNER);

        // After intake
        address[] memory signers = clause.queryPartiesInRole(INSTANCE_1, SIGNER);
        assertEq(signers.length, 2);
    }

    function test_QueryRolesForParty_AlwaysAvailable() public {
        // Before intake
        bytes32[] memory empty = clause.queryRolesForParty(INSTANCE_1, alice);
        assertEq(empty.length, 0);

        clause.intakeParty(INSTANCE_1, alice, SIGNER);
        clause.intakeParty(INSTANCE_1, alice, ADMIN);

        // After intake
        bytes32[] memory roles = clause.queryRolesForParty(INSTANCE_1, alice);
        assertEq(roles.length, 2);
    }

    function test_QueryAllParties_AlwaysAvailable() public {
        // Before intake
        address[] memory empty = clause.queryAllParties(INSTANCE_1);
        assertEq(empty.length, 0);

        clause.intakeParty(INSTANCE_1, alice, SIGNER);
        clause.intakeParty(INSTANCE_1, bob, ARBITER);

        // After intake
        address[] memory parties = clause.queryAllParties(INSTANCE_1);
        assertEq(parties.length, 2);
    }

    function test_QueryIsParty_AlwaysAvailable() public {
        assertFalse(clause.queryIsParty(INSTANCE_1, alice));

        clause.intakeParty(INSTANCE_1, alice, SIGNER);

        assertTrue(clause.queryIsParty(INSTANCE_1, alice));
        assertFalse(clause.queryIsParty(INSTANCE_1, bob));
    }

    // =============================================================
    // INSTANCE ISOLATION TESTS
    // =============================================================

    function test_MultipleInstances_Independent() public {
        // Setup two independent registry instances
        clause.intakeParty(INSTANCE_1, alice, SIGNER);
        clause.intakeParty(INSTANCE_1, bob, SIGNER);
        clause.intakeReady(INSTANCE_1);

        clause.intakeParty(INSTANCE_2, charlie, ARBITER);
        clause.intakeParty(INSTANCE_2, david, BENEFICIARY);
        clause.intakeReady(INSTANCE_2);

        // Verify instance 1
        assertEq(clause.queryPartyCount(INSTANCE_1), 2);
        assertTrue(clause.queryHasRole(INSTANCE_1, alice, SIGNER));
        assertTrue(clause.queryHasRole(INSTANCE_1, bob, SIGNER));
        assertFalse(clause.queryIsParty(INSTANCE_1, charlie));

        // Verify instance 2
        assertEq(clause.queryPartyCount(INSTANCE_2), 2);
        assertTrue(clause.queryHasRole(INSTANCE_2, charlie, ARBITER));
        assertTrue(clause.queryHasRole(INSTANCE_2, david, BENEFICIARY));
        assertFalse(clause.queryIsParty(INSTANCE_2, alice));
    }

    function test_MultipleInstances_SamePartiesDifferentRoles() public {
        // Same people can have different roles in different instances
        clause.intakeParty(INSTANCE_1, alice, SIGNER);
        clause.intakeReady(INSTANCE_1);

        clause.intakeParty(INSTANCE_2, alice, ARBITER);
        clause.intakeReady(INSTANCE_2);

        assertTrue(clause.queryHasRole(INSTANCE_1, alice, SIGNER));
        assertFalse(clause.queryHasRole(INSTANCE_1, alice, ARBITER));

        assertFalse(clause.queryHasRole(INSTANCE_2, alice, SIGNER));
        assertTrue(clause.queryHasRole(INSTANCE_2, alice, ARBITER));
    }

    // =============================================================
    // INTEGRATION WITH SIGNATURE CLAUSE PATTERN
    // =============================================================

    function test_Integration_HandoffToSignatureClause() public {
        // Simulate the common pattern:
        // PartyRegistry.handoffPartiesInRole(SIGNER) -> SignatureClause.intakeSigners()

        // Setup registry with signers and other roles
        clause.intakeParty(INSTANCE_1, alice, SIGNER);
        clause.intakeParty(INSTANCE_1, bob, SIGNER);
        clause.intakeParty(INSTANCE_1, charlie, ARBITER);  // Not a signer
        clause.intakeReady(INSTANCE_1);

        // Get signers for handoff
        address[] memory signers = clause.handoffPartiesInRole(INSTANCE_1, SIGNER);

        // Verify only signers are included
        assertEq(signers.length, 2);
        assertEq(signers[0], alice);
        assertEq(signers[1], bob);

        // This array would be passed to SignatureClauseLogicV3.intakeSigners()
    }

    // =============================================================
    // STATE MACHINE TESTS
    // =============================================================

    function test_StateMachine_FullFlow() public {
        // Start: UNINITIALIZED (0)
        assertEq(clause.queryStatus(INSTANCE_1), 0);

        // Add parties with various roles
        clause.intakeParty(INSTANCE_1, alice, SIGNER);
        clause.intakeParty(INSTANCE_1, alice, ADMIN);
        clause.intakeParty(INSTANCE_1, bob, SIGNER);
        clause.intakeParty(INSTANCE_1, charlie, ARBITER);

        // Still UNINITIALIZED
        assertEq(clause.queryStatus(INSTANCE_1), 0);

        // Activate
        clause.intakeReady(INSTANCE_1);
        assertEq(clause.queryStatus(INSTANCE_1), ACTIVE);

        // Can query and handoff
        assertEq(clause.queryPartyCount(INSTANCE_1), 3);
        assertEq(clause.handoffPartiesInRole(INSTANCE_1, SIGNER).length, 2);
        assertEq(clause.handoffPartiesInRole(INSTANCE_1, ARBITER).length, 1);
        assertEq(clause.handoffPartiesInRole(INSTANCE_1, ADMIN).length, 1);
    }

    // =============================================================
    // EDGE CASES
    // =============================================================

    function test_SamePartyMultipleRoles_CountedOnce() public {
        clause.intakeParty(INSTANCE_1, alice, SIGNER);
        clause.intakeParty(INSTANCE_1, alice, ARBITER);
        clause.intakeParty(INSTANCE_1, alice, ADMIN);
        clause.intakeParty(INSTANCE_1, alice, BENEFICIARY);

        // Only one party
        assertEq(clause.queryPartyCount(INSTANCE_1), 1);

        // But four roles
        bytes32[] memory roles = clause.queryRolesForParty(INSTANCE_1, alice);
        assertEq(roles.length, 4);
    }

    function test_SameRoleMultipleParties() public {
        clause.intakeParty(INSTANCE_1, alice, SIGNER);
        clause.intakeParty(INSTANCE_1, bob, SIGNER);
        clause.intakeParty(INSTANCE_1, charlie, SIGNER);
        clause.intakeParty(INSTANCE_1, david, SIGNER);

        address[] memory signers = clause.queryPartiesInRole(INSTANCE_1, SIGNER);
        assertEq(signers.length, 4);
    }

    function test_NoActions_IntakeOnly() public {
        // This clause has no action functions
        // Just verify it can be set up and queried
        clause.intakeParty(INSTANCE_1, alice, SIGNER);
        clause.intakeReady(INSTANCE_1);

        // State is stable
        assertEq(clause.queryStatus(INSTANCE_1), ACTIVE);

        // Can query indefinitely
        assertTrue(clause.queryHasRole(INSTANCE_1, alice, SIGNER));
    }

    // =============================================================
    // FUZZ TESTS
    // =============================================================

    function testFuzz_IntakeParties_VariableCounts(uint8 count) public {
        vm.assume(count > 0 && count <= 50);

        address[] memory parties = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            parties[i] = address(uint160(i + 1));
        }

        clause.intakeParties(INSTANCE_1, parties, SIGNER);

        assertEq(clause.queryPartiesInRole(INSTANCE_1, SIGNER).length, count);
        assertEq(clause.queryPartyCount(INSTANCE_1), count);
    }

    function testFuzz_IntakeParty_ArbitraryRoles(bytes32 role) public {
        vm.assume(role != bytes32(0));

        clause.intakeParty(INSTANCE_1, alice, role);

        assertTrue(clause.queryHasRole(INSTANCE_1, alice, role));

        bytes32[] memory roles = clause.queryRolesForParty(INSTANCE_1, alice);
        assertEq(roles.length, 1);
        assertEq(roles[0], role);
    }

    function testFuzz_MultipleRolesPerParty(uint8 roleCount) public {
        vm.assume(roleCount > 0 && roleCount <= 20);

        for (uint256 i = 0; i < roleCount; i++) {
            bytes32 role = keccak256(abi.encode("ROLE", i));
            clause.intakeParty(INSTANCE_1, alice, role);
        }

        bytes32[] memory roles = clause.queryRolesForParty(INSTANCE_1, alice);
        assertEq(roles.length, roleCount);
        assertEq(clause.queryPartyCount(INSTANCE_1), 1);
    }

    function testFuzz_InstanceIsolation(bytes32 id1, bytes32 id2) public {
        vm.assume(id1 != id2);

        // Setup first instance
        clause.intakeParty(id1, alice, SIGNER);
        clause.intakeReady(id1);

        // Second instance should be unaffected
        assertEq(clause.queryStatus(id2), 0);
        assertEq(clause.queryPartyCount(id2), 0);
        assertFalse(clause.queryIsParty(id2, alice));
    }
}
