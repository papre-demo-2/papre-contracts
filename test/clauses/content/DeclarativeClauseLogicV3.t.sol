// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {DeclarativeClauseLogicV3} from "../../../src/clauses/content/DeclarativeClauseLogicV3.sol";

/// @title DeclarativeClauseLogicV3 Unit Tests
/// @notice Tests for the v3 self-describing content anchoring clause with ERC-7201 storage
contract DeclarativeClauseLogicV3Test is Test {
    DeclarativeClauseLogicV3 public clause;

    // Test accounts
    address alice;
    address bob;
    address charlie;

    // Instance IDs for testing
    bytes32 constant INSTANCE_1 = bytes32(uint256(1));
    bytes32 constant INSTANCE_2 = bytes32(uint256(2));

    // State constants (matching the contract)
    uint16 constant REGISTERED = 1 << 1; // 0x0002
    uint16 constant SEALED = 1 << 2; // 0x0004
    uint16 constant REVOKED = 1 << 3; // 0x0008

    // Test content
    bytes32 constant CONTENT_HASH = keccak256("test-content");
    string constant CONTENT_URI = "ipfs://QmTest123";

    function setUp() public {
        clause = new DeclarativeClauseLogicV3();

        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");
    }

    // =============================================================
    // INITIAL STATE TESTS
    // =============================================================

    function test_InitialState_IsUninitialized() public view {
        // New instances start at 0 (uninitialized)
        assertEq(clause.queryStatus(INSTANCE_1), 0);
    }

    function test_QueryContentHash_InitiallyZero() public view {
        assertEq(clause.queryContentHash(INSTANCE_1), bytes32(0));
    }

    function test_QueryContentUri_InitiallyEmpty() public view {
        assertEq(clause.queryContentUri(INSTANCE_1), "");
    }

    function test_QueryRegistrant_InitiallyZero() public view {
        assertEq(clause.queryRegistrant(INSTANCE_1), address(0));
    }

    function test_QueryRegisteredAt_InitiallyZero() public view {
        assertEq(clause.queryRegisteredAt(INSTANCE_1), 0);
    }

    function test_QuerySealedAt_InitiallyZero() public view {
        assertEq(clause.querySealedAt(INSTANCE_1), 0);
    }

    function test_QueryIsSealed_InitiallyFalse() public view {
        assertFalse(clause.queryIsSealed(INSTANCE_1));
    }

    function test_QueryIsRevoked_InitiallyFalse() public view {
        assertFalse(clause.queryIsRevoked(INSTANCE_1));
    }

    // =============================================================
    // INTAKE TESTS
    // =============================================================

    function test_IntakeContent_Success() public {
        vm.prank(alice);
        clause.intakeContent(INSTANCE_1, CONTENT_HASH, CONTENT_URI);

        assertEq(clause.queryStatus(INSTANCE_1), REGISTERED);
        assertEq(clause.queryContentHash(INSTANCE_1), CONTENT_HASH);
        assertEq(clause.queryContentUri(INSTANCE_1), CONTENT_URI);
        assertEq(clause.queryRegistrant(INSTANCE_1), alice);
        assertEq(clause.queryRegisteredAt(INSTANCE_1), block.timestamp);
    }

    function test_IntakeContent_EmptyUri() public {
        vm.prank(alice);
        clause.intakeContent(INSTANCE_1, CONTENT_HASH, "");

        assertEq(clause.queryStatus(INSTANCE_1), REGISTERED);
        assertEq(clause.queryContentHash(INSTANCE_1), CONTENT_HASH);
        assertEq(clause.queryContentUri(INSTANCE_1), "");
    }

    function test_IntakeContent_RevertOnZeroHash() public {
        vm.prank(alice);
        vm.expectRevert("Invalid content hash");
        clause.intakeContent(INSTANCE_1, bytes32(0), CONTENT_URI);
    }

    function test_IntakeContent_OnlyInUninitialized() public {
        // First intake works
        vm.prank(alice);
        clause.intakeContent(INSTANCE_1, CONTENT_HASH, CONTENT_URI);

        // Second intake fails
        vm.prank(bob);
        vm.expectRevert("Wrong state");
        clause.intakeContent(INSTANCE_1, keccak256("other"), "https://other.com");
    }

    function test_IntakeContentHash_Success() public {
        vm.prank(alice);
        clause.intakeContentHash(INSTANCE_1, CONTENT_HASH);

        assertEq(clause.queryStatus(INSTANCE_1), REGISTERED);
        assertEq(clause.queryContentHash(INSTANCE_1), CONTENT_HASH);
        assertEq(clause.queryContentUri(INSTANCE_1), ""); // No URI
        assertEq(clause.queryRegistrant(INSTANCE_1), alice);
        assertEq(clause.queryRegisteredAt(INSTANCE_1), block.timestamp);
    }

    function test_IntakeContentHash_RevertOnZeroHash() public {
        vm.prank(alice);
        vm.expectRevert("Invalid content hash");
        clause.intakeContentHash(INSTANCE_1, bytes32(0));
    }

    function test_IntakeContentHash_OnlyInUninitialized() public {
        // First intake works
        vm.prank(alice);
        clause.intakeContentHash(INSTANCE_1, CONTENT_HASH);

        // Second intake fails
        vm.prank(bob);
        vm.expectRevert("Wrong state");
        clause.intakeContentHash(INSTANCE_1, keccak256("other"));
    }

    function test_IntakeContent_RecordsTimestamp() public {
        uint256 expectedTime = 1700000000;
        vm.warp(expectedTime);

        vm.prank(alice);
        clause.intakeContent(INSTANCE_1, CONTENT_HASH, CONTENT_URI);

        assertEq(clause.queryRegisteredAt(INSTANCE_1), expectedTime);
    }

    // =============================================================
    // ACTION TESTS - SEAL
    // =============================================================

    function test_ActionSeal_Success() public {
        // Setup
        vm.prank(alice);
        clause.intakeContent(INSTANCE_1, CONTENT_HASH, CONTENT_URI);

        assertEq(clause.queryStatus(INSTANCE_1), REGISTERED);

        // Seal
        vm.prank(alice);
        clause.actionSeal(INSTANCE_1);

        assertEq(clause.queryStatus(INSTANCE_1), SEALED);
        assertTrue(clause.queryIsSealed(INSTANCE_1));
        assertFalse(clause.queryIsRevoked(INSTANCE_1));
    }

    function test_ActionSeal_RecordsTimestamp() public {
        // Setup
        vm.warp(1000);
        vm.prank(alice);
        clause.intakeContent(INSTANCE_1, CONTENT_HASH, CONTENT_URI);

        // Seal later
        uint256 sealTime = 2000;
        vm.warp(sealTime);
        vm.prank(alice);
        clause.actionSeal(INSTANCE_1);

        assertEq(clause.querySealedAt(INSTANCE_1), sealTime);
    }

    function test_ActionSeal_OnlyRegistrant() public {
        // Setup as alice
        vm.prank(alice);
        clause.intakeContent(INSTANCE_1, CONTENT_HASH, CONTENT_URI);

        // Bob tries to seal
        vm.prank(bob);
        vm.expectRevert("Not registrant");
        clause.actionSeal(INSTANCE_1);
    }

    function test_ActionSeal_OnlyInRegistered() public {
        // Try to seal uninitialized
        vm.prank(alice);
        vm.expectRevert("Wrong state");
        clause.actionSeal(INSTANCE_1);
    }

    function test_ActionSeal_NotFromSealed() public {
        // Setup and seal
        vm.startPrank(alice);
        clause.intakeContent(INSTANCE_1, CONTENT_HASH, CONTENT_URI);
        clause.actionSeal(INSTANCE_1);

        // Try to seal again
        vm.expectRevert("Wrong state");
        clause.actionSeal(INSTANCE_1);
        vm.stopPrank();
    }

    function test_ActionSeal_NotFromRevoked() public {
        // Setup and revoke
        vm.startPrank(alice);
        clause.intakeContent(INSTANCE_1, CONTENT_HASH, CONTENT_URI);
        clause.actionRevoke(INSTANCE_1);

        // Try to seal
        vm.expectRevert("Wrong state");
        clause.actionSeal(INSTANCE_1);
        vm.stopPrank();
    }

    // =============================================================
    // ACTION TESTS - REVOKE
    // =============================================================

    function test_ActionRevoke_Success() public {
        // Setup
        vm.prank(alice);
        clause.intakeContent(INSTANCE_1, CONTENT_HASH, CONTENT_URI);

        assertEq(clause.queryStatus(INSTANCE_1), REGISTERED);

        // Revoke
        vm.prank(alice);
        clause.actionRevoke(INSTANCE_1);

        assertEq(clause.queryStatus(INSTANCE_1), REVOKED);
        assertTrue(clause.queryIsRevoked(INSTANCE_1));
        assertFalse(clause.queryIsSealed(INSTANCE_1));
    }

    function test_ActionRevoke_OnlyRegistrant() public {
        // Setup as alice
        vm.prank(alice);
        clause.intakeContent(INSTANCE_1, CONTENT_HASH, CONTENT_URI);

        // Bob tries to revoke
        vm.prank(bob);
        vm.expectRevert("Not registrant");
        clause.actionRevoke(INSTANCE_1);
    }

    function test_ActionRevoke_OnlyInRegistered() public {
        // Try to revoke uninitialized
        vm.prank(alice);
        vm.expectRevert("Wrong state");
        clause.actionRevoke(INSTANCE_1);
    }

    function test_ActionRevoke_NotFromSealed() public {
        // Setup and seal
        vm.startPrank(alice);
        clause.intakeContent(INSTANCE_1, CONTENT_HASH, CONTENT_URI);
        clause.actionSeal(INSTANCE_1);

        // Try to revoke
        vm.expectRevert("Wrong state");
        clause.actionRevoke(INSTANCE_1);
        vm.stopPrank();
    }

    function test_ActionRevoke_NotFromRevoked() public {
        // Setup and revoke
        vm.startPrank(alice);
        clause.intakeContent(INSTANCE_1, CONTENT_HASH, CONTENT_URI);
        clause.actionRevoke(INSTANCE_1);

        // Try to revoke again
        vm.expectRevert("Wrong state");
        clause.actionRevoke(INSTANCE_1);
        vm.stopPrank();
    }

    // =============================================================
    // HANDOFF TESTS
    // =============================================================

    function test_HandoffContentHash_InRegistered() public {
        vm.prank(alice);
        clause.intakeContent(INSTANCE_1, CONTENT_HASH, CONTENT_URI);

        bytes32 hash = clause.handoffContentHash(INSTANCE_1);
        assertEq(hash, CONTENT_HASH);
    }

    function test_HandoffContentHash_InSealed() public {
        vm.startPrank(alice);
        clause.intakeContent(INSTANCE_1, CONTENT_HASH, CONTENT_URI);
        clause.actionSeal(INSTANCE_1);
        vm.stopPrank();

        bytes32 hash = clause.handoffContentHash(INSTANCE_1);
        assertEq(hash, CONTENT_HASH);
    }

    function test_HandoffContentHash_NotInRevoked() public {
        vm.startPrank(alice);
        clause.intakeContent(INSTANCE_1, CONTENT_HASH, CONTENT_URI);
        clause.actionRevoke(INSTANCE_1);
        vm.stopPrank();

        vm.expectRevert("Wrong state");
        clause.handoffContentHash(INSTANCE_1);
    }

    function test_HandoffContentHash_NotInUninitialized() public {
        vm.expectRevert("Wrong state");
        clause.handoffContentHash(INSTANCE_1);
    }

    function test_HandoffContentUri_InRegistered() public {
        vm.prank(alice);
        clause.intakeContent(INSTANCE_1, CONTENT_HASH, CONTENT_URI);

        string memory uri = clause.handoffContentUri(INSTANCE_1);
        assertEq(uri, CONTENT_URI);
    }

    function test_HandoffContentUri_InSealed() public {
        vm.startPrank(alice);
        clause.intakeContent(INSTANCE_1, CONTENT_HASH, CONTENT_URI);
        clause.actionSeal(INSTANCE_1);
        vm.stopPrank();

        string memory uri = clause.handoffContentUri(INSTANCE_1);
        assertEq(uri, CONTENT_URI);
    }

    function test_HandoffContentUri_NotInRevoked() public {
        vm.startPrank(alice);
        clause.intakeContent(INSTANCE_1, CONTENT_HASH, CONTENT_URI);
        clause.actionRevoke(INSTANCE_1);
        vm.stopPrank();

        vm.expectRevert("Wrong state");
        clause.handoffContentUri(INSTANCE_1);
    }

    function test_HandoffRegistrant_InRegistered() public {
        vm.prank(alice);
        clause.intakeContent(INSTANCE_1, CONTENT_HASH, CONTENT_URI);

        address registrant = clause.handoffRegistrant(INSTANCE_1);
        assertEq(registrant, alice);
    }

    function test_HandoffRegistrant_InSealed() public {
        vm.startPrank(alice);
        clause.intakeContent(INSTANCE_1, CONTENT_HASH, CONTENT_URI);
        clause.actionSeal(INSTANCE_1);
        vm.stopPrank();

        address registrant = clause.handoffRegistrant(INSTANCE_1);
        assertEq(registrant, alice);
    }

    function test_HandoffRegistrant_NotInRevoked() public {
        vm.startPrank(alice);
        clause.intakeContent(INSTANCE_1, CONTENT_HASH, CONTENT_URI);
        clause.actionRevoke(INSTANCE_1);
        vm.stopPrank();

        vm.expectRevert("Wrong state");
        clause.handoffRegistrant(INSTANCE_1);
    }

    // =============================================================
    // QUERY TESTS
    // =============================================================

    function test_QueryStatus_AlwaysAvailable() public {
        // Works in UNINITIALIZED
        assertEq(clause.queryStatus(INSTANCE_1), 0);

        // Setup
        vm.prank(alice);
        clause.intakeContent(INSTANCE_1, CONTENT_HASH, CONTENT_URI);

        // Works in REGISTERED
        assertEq(clause.queryStatus(INSTANCE_1), REGISTERED);

        // Seal
        vm.prank(alice);
        clause.actionSeal(INSTANCE_1);

        // Works in SEALED
        assertEq(clause.queryStatus(INSTANCE_1), SEALED);
    }

    function test_QueryVerifyContent_Success() public {
        vm.prank(alice);
        clause.intakeContent(INSTANCE_1, CONTENT_HASH, CONTENT_URI);

        assertTrue(clause.queryVerifyContent(INSTANCE_1, CONTENT_HASH));
        assertFalse(clause.queryVerifyContent(INSTANCE_1, keccak256("wrong")));
    }

    function test_QueryVerifyContent_WorksInSealed() public {
        vm.startPrank(alice);
        clause.intakeContent(INSTANCE_1, CONTENT_HASH, CONTENT_URI);
        clause.actionSeal(INSTANCE_1);
        vm.stopPrank();

        assertTrue(clause.queryVerifyContent(INSTANCE_1, CONTENT_HASH));
    }

    function test_QueryVerifyContent_FailsInRevoked() public {
        vm.startPrank(alice);
        clause.intakeContent(INSTANCE_1, CONTENT_HASH, CONTENT_URI);
        clause.actionRevoke(INSTANCE_1);
        vm.stopPrank();

        // Returns false (not reverts) for revoked content
        assertFalse(clause.queryVerifyContent(INSTANCE_1, CONTENT_HASH));
    }

    function test_QueryVerifyContent_FailsInUninitialized() public view {
        // Returns false for uninitialized
        assertFalse(clause.queryVerifyContent(INSTANCE_1, CONTENT_HASH));
    }

    function test_QueryContentHash_AlwaysAvailable() public {
        // Returns bytes32(0) before init
        assertEq(clause.queryContentHash(INSTANCE_1), bytes32(0));

        vm.prank(alice);
        clause.intakeContent(INSTANCE_1, CONTENT_HASH, CONTENT_URI);

        // Returns actual hash after init
        assertEq(clause.queryContentHash(INSTANCE_1), CONTENT_HASH);
    }

    function test_QueryContentUri_AlwaysAvailable() public {
        // Returns empty before init
        assertEq(clause.queryContentUri(INSTANCE_1), "");

        vm.prank(alice);
        clause.intakeContent(INSTANCE_1, CONTENT_HASH, CONTENT_URI);

        // Returns actual URI after init
        assertEq(clause.queryContentUri(INSTANCE_1), CONTENT_URI);
    }

    // =============================================================
    // INSTANCE ISOLATION TESTS
    // =============================================================

    function test_MultipleInstances_Independent() public {
        // Setup two independent content instances
        vm.prank(alice);
        clause.intakeContent(INSTANCE_1, CONTENT_HASH, CONTENT_URI);

        bytes32 otherHash = keccak256("other-content");
        string memory otherUri = "ar://other";
        vm.prank(bob);
        clause.intakeContent(INSTANCE_2, otherHash, otherUri);

        // Verify independence
        assertEq(clause.queryContentHash(INSTANCE_1), CONTENT_HASH);
        assertEq(clause.queryContentHash(INSTANCE_2), otherHash);
        assertEq(clause.queryContentUri(INSTANCE_1), CONTENT_URI);
        assertEq(clause.queryContentUri(INSTANCE_2), otherUri);
        assertEq(clause.queryRegistrant(INSTANCE_1), alice);
        assertEq(clause.queryRegistrant(INSTANCE_2), bob);
    }

    function test_MultipleInstances_IndependentStates() public {
        // Setup both instances
        vm.prank(alice);
        clause.intakeContent(INSTANCE_1, CONTENT_HASH, CONTENT_URI);

        vm.prank(bob);
        clause.intakeContent(INSTANCE_2, keccak256("other"), "");

        // Seal instance 1
        vm.prank(alice);
        clause.actionSeal(INSTANCE_1);

        // Revoke instance 2
        vm.prank(bob);
        clause.actionRevoke(INSTANCE_2);

        // Verify different states
        assertEq(clause.queryStatus(INSTANCE_1), SEALED);
        assertEq(clause.queryStatus(INSTANCE_2), REVOKED);
        assertTrue(clause.queryIsSealed(INSTANCE_1));
        assertTrue(clause.queryIsRevoked(INSTANCE_2));
    }

    function test_MultipleInstances_ActionOnOneCantAffectOther() public {
        // Setup instance 1
        vm.prank(alice);
        clause.intakeContent(INSTANCE_1, CONTENT_HASH, CONTENT_URI);

        // Instance 2 is uninitialized
        assertEq(clause.queryStatus(INSTANCE_2), 0);

        // Seal instance 1
        vm.prank(alice);
        clause.actionSeal(INSTANCE_1);

        // Instance 2 still uninitialized
        assertEq(clause.queryStatus(INSTANCE_2), 0);
    }

    // =============================================================
    // STATE MACHINE TESTS
    // =============================================================

    function test_StateMachine_RegisterToSealed() public {
        // Start: UNINITIALIZED (0)
        assertEq(clause.queryStatus(INSTANCE_1), 0);

        // Register -> REGISTERED
        vm.prank(alice);
        clause.intakeContent(INSTANCE_1, CONTENT_HASH, CONTENT_URI);
        assertEq(clause.queryStatus(INSTANCE_1), REGISTERED);

        // Seal -> SEALED (terminal)
        vm.prank(alice);
        clause.actionSeal(INSTANCE_1);
        assertEq(clause.queryStatus(INSTANCE_1), SEALED);

        // Can't do anything else
        vm.prank(alice);
        vm.expectRevert("Wrong state");
        clause.actionSeal(INSTANCE_1);

        vm.prank(alice);
        vm.expectRevert("Wrong state");
        clause.actionRevoke(INSTANCE_1);
    }

    function test_StateMachine_RegisterToRevoked() public {
        // Start: UNINITIALIZED (0)
        assertEq(clause.queryStatus(INSTANCE_1), 0);

        // Register -> REGISTERED
        vm.prank(alice);
        clause.intakeContent(INSTANCE_1, CONTENT_HASH, CONTENT_URI);
        assertEq(clause.queryStatus(INSTANCE_1), REGISTERED);

        // Revoke -> REVOKED (terminal, dead end)
        vm.prank(alice);
        clause.actionRevoke(INSTANCE_1);
        assertEq(clause.queryStatus(INSTANCE_1), REVOKED);

        // Can't do anything else
        vm.prank(alice);
        vm.expectRevert("Wrong state");
        clause.actionSeal(INSTANCE_1);

        vm.prank(alice);
        vm.expectRevert("Wrong state");
        clause.actionRevoke(INSTANCE_1);

        // Handoffs blocked
        vm.expectRevert("Wrong state");
        clause.handoffContentHash(INSTANCE_1);
    }

    function test_StateMachine_SealedAllowsHandoff() public {
        vm.startPrank(alice);
        clause.intakeContent(INSTANCE_1, CONTENT_HASH, CONTENT_URI);
        clause.actionSeal(INSTANCE_1);
        vm.stopPrank();

        // All handoffs work in SEALED
        assertEq(clause.handoffContentHash(INSTANCE_1), CONTENT_HASH);
        assertEq(clause.handoffContentUri(INSTANCE_1), CONTENT_URI);
        assertEq(clause.handoffRegistrant(INSTANCE_1), alice);
    }

    // =============================================================
    // EDGE CASES
    // =============================================================

    function test_DifferentUriFormats() public {
        // IPFS
        vm.prank(alice);
        clause.intakeContent(bytes32(uint256(1)), CONTENT_HASH, "ipfs://QmTest123");
        assertEq(clause.queryContentUri(bytes32(uint256(1))), "ipfs://QmTest123");

        // Arweave
        vm.prank(alice);
        clause.intakeContent(bytes32(uint256(2)), CONTENT_HASH, "ar://abc123");
        assertEq(clause.queryContentUri(bytes32(uint256(2))), "ar://abc123");

        // HTTPS
        vm.prank(alice);
        clause.intakeContent(bytes32(uint256(3)), CONTENT_HASH, "https://example.com/doc.pdf");
        assertEq(clause.queryContentUri(bytes32(uint256(3))), "https://example.com/doc.pdf");
    }

    function test_LongUri() public {
        // Very long URI (within gas limits)
        string memory longUri =
            "ipfs://QmLongHash1234567890abcdefghijklmnopqrstuvwxyzLongHash1234567890abcdefghijklmnopqrstuvwxyzLongHash1234567890abcdefghijklmnopqrstuvwxyz";

        vm.prank(alice);
        clause.intakeContent(INSTANCE_1, CONTENT_HASH, longUri);
        assertEq(clause.queryContentUri(INSTANCE_1), longUri);
    }

    function test_SameHashDifferentInstances() public {
        // Same content hash can be registered in different instances
        vm.prank(alice);
        clause.intakeContent(INSTANCE_1, CONTENT_HASH, "uri1");

        vm.prank(bob);
        clause.intakeContent(INSTANCE_2, CONTENT_HASH, "uri2");

        // Both have same hash but different URIs
        assertEq(clause.queryContentHash(INSTANCE_1), CONTENT_HASH);
        assertEq(clause.queryContentHash(INSTANCE_2), CONTENT_HASH);
        assertEq(clause.queryContentUri(INSTANCE_1), "uri1");
        assertEq(clause.queryContentUri(INSTANCE_2), "uri2");
    }

    function test_RegistrantRemainsAfterSeal() public {
        vm.prank(alice);
        clause.intakeContent(INSTANCE_1, CONTENT_HASH, CONTENT_URI);

        vm.prank(alice);
        clause.actionSeal(INSTANCE_1);

        // Registrant still accessible
        assertEq(clause.queryRegistrant(INSTANCE_1), alice);
        assertEq(clause.handoffRegistrant(INSTANCE_1), alice);
    }

    // =============================================================
    // FUZZ TESTS
    // =============================================================

    function testFuzz_IntakeContent_AnyHash(bytes32 hash) public {
        vm.assume(hash != bytes32(0));

        vm.prank(alice);
        clause.intakeContent(INSTANCE_1, hash, CONTENT_URI);

        assertEq(clause.queryContentHash(INSTANCE_1), hash);
        assertEq(clause.queryStatus(INSTANCE_1), REGISTERED);
    }

    function testFuzz_IntakeContent_AnyUri(string calldata uri) public {
        vm.prank(alice);
        clause.intakeContent(INSTANCE_1, CONTENT_HASH, uri);

        assertEq(clause.queryContentUri(INSTANCE_1), uri);
    }

    function testFuzz_InstanceIsolation(bytes32 id1, bytes32 id2) public {
        vm.assume(id1 != id2);

        bytes32 hash1 = keccak256(abi.encode("content1", id1));
        bytes32 hash2 = keccak256(abi.encode("content2", id2));

        // Setup first instance
        vm.prank(alice);
        clause.intakeContent(id1, hash1, "uri1");

        // Second instance should be unaffected
        assertEq(clause.queryStatus(id2), 0);
        assertEq(clause.queryContentHash(id2), bytes32(0));

        // Setup second instance
        vm.prank(bob);
        clause.intakeContent(id2, hash2, "uri2");

        // Both independent
        assertEq(clause.queryContentHash(id1), hash1);
        assertEq(clause.queryContentHash(id2), hash2);
        assertEq(clause.queryRegistrant(id1), alice);
        assertEq(clause.queryRegistrant(id2), bob);
    }

    function testFuzz_VerifyContent_CorrectHash(bytes32 hash, bytes32 wrongHash) public {
        vm.assume(hash != bytes32(0));
        vm.assume(hash != wrongHash);

        vm.prank(alice);
        clause.intakeContent(INSTANCE_1, hash, "");

        assertTrue(clause.queryVerifyContent(INSTANCE_1, hash));
        assertFalse(clause.queryVerifyContent(INSTANCE_1, wrongHash));
    }

    function testFuzz_Timestamps(uint256 registerTime, uint256 sealTime) public {
        vm.assume(registerTime < sealTime);
        vm.assume(sealTime < type(uint64).max); // Reasonable timestamp

        vm.warp(registerTime);
        vm.prank(alice);
        clause.intakeContent(INSTANCE_1, CONTENT_HASH, CONTENT_URI);

        assertEq(clause.queryRegisteredAt(INSTANCE_1), registerTime);

        vm.warp(sealTime);
        vm.prank(alice);
        clause.actionSeal(INSTANCE_1);

        assertEq(clause.querySealedAt(INSTANCE_1), sealTime);
    }

    // =============================================================
    // INTEGRATION SCENARIO TESTS
    // =============================================================

    function test_Scenario_DocumentRegistrationAndSealing() public {
        // Alice registers a document
        bytes32 docHash = keccak256("legal-document-v1.0");
        string memory docUri = "ipfs://QmDocumentHash123";

        vm.prank(alice);
        clause.intakeContent(INSTANCE_1, docHash, docUri);

        // Document can be verified
        assertTrue(clause.queryVerifyContent(INSTANCE_1, docHash));

        // After review, alice seals the document
        vm.prank(alice);
        clause.actionSeal(INSTANCE_1);

        // Document is now immutable
        assertTrue(clause.queryIsSealed(INSTANCE_1));

        // Handoff data for downstream clause (e.g., signature)
        bytes32 handoffHash = clause.handoffContentHash(INSTANCE_1);
        assertEq(handoffHash, docHash);
    }

    function test_Scenario_ContentRevocation() public {
        // Bob registers content that turns out to be wrong
        vm.prank(bob);
        clause.intakeContent(INSTANCE_1, CONTENT_HASH, CONTENT_URI);

        // Bob realizes error and revokes
        vm.prank(bob);
        clause.actionRevoke(INSTANCE_1);

        // Content verification fails for revoked content
        assertFalse(clause.queryVerifyContent(INSTANCE_1, CONTENT_HASH));

        // Handoffs are blocked
        vm.expectRevert("Wrong state");
        clause.handoffContentHash(INSTANCE_1);
    }
}
