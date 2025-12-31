// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {SignatureClauseLogicV3} from "../../../src/clauses/attestation/SignatureClauseLogicV3.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title SignatureClauseLogicV3 Unit Tests
/// @notice Tests for the v3 self-describing signature clause with ERC-7201 storage
contract SignatureClauseLogicV3Test is Test {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    SignatureClauseLogicV3 public clause;

    // Test accounts
    address alice;
    address bob;
    address charlie;

    // Instance IDs for testing
    bytes32 constant INSTANCE_1 = bytes32(uint256(1));
    bytes32 constant INSTANCE_2 = bytes32(uint256(2));

    // State constants (matching the contract)
    uint16 constant UNINITIALIZED = 1 << 0;  // 0x0001
    uint16 constant PENDING       = 1 << 1;  // 0x0002
    uint16 constant COMPLETE      = 1 << 2;  // 0x0004
    uint16 constant CANCELLED     = 1 << 3;  // 0x0008

    function setUp() public {
        clause = new SignatureClauseLogicV3();

        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");
    }

    // =============================================================
    // INITIAL STATE TESTS
    // =============================================================

    function test_InitialState_IsUninitialized() public view {
        // New instances start at 0, which maps to UNINITIALIZED behavior
        // (actually 0, not the bitmask, but require checks == UNINITIALIZED)
        assertEq(clause.queryStatus(INSTANCE_1), 0);
    }

    function test_QuerySigners_InitiallyEmpty() public view {
        address[] memory signers = clause.querySigners(INSTANCE_1);
        assertEq(signers.length, 0);
    }

    // =============================================================
    // INTAKE TESTS
    // =============================================================

    function test_IntakeSigners_Success() public {
        address[] memory signers = new address[](2);
        signers[0] = alice;
        signers[1] = bob;

        clause.intakeSigners(INSTANCE_1, signers);

        address[] memory stored = clause.querySigners(INSTANCE_1);
        assertEq(stored.length, 2);
        assertEq(stored[0], alice);
        assertEq(stored[1], bob);
    }

    function test_IntakeSigners_OnlyInUninitialized() public {
        address[] memory signers = new address[](1);
        signers[0] = alice;

        // First intake works
        clause.intakeSigners(INSTANCE_1, signers);

        // Transition to PENDING via intakeDocumentHash
        clause.intakeDocumentHash(INSTANCE_1, keccak256("doc"));

        // Now should fail
        vm.expectRevert("Wrong state");
        clause.intakeSigners(INSTANCE_1, signers);
    }

    function test_IntakeDocumentHash_TransitionsToPending() public {
        address[] memory signers = new address[](1);
        signers[0] = alice;

        clause.intakeSigners(INSTANCE_1, signers);
        assertEq(clause.queryStatus(INSTANCE_1), 0); // Still uninitialized (0)

        clause.intakeDocumentHash(INSTANCE_1, keccak256("document-hash"));
        assertEq(clause.queryStatus(INSTANCE_1), PENDING);
    }

    function test_IntakeDocumentHash_OnlyInUninitialized() public {
        address[] memory signers = new address[](1);
        signers[0] = alice;

        clause.intakeSigners(INSTANCE_1, signers);
        clause.intakeDocumentHash(INSTANCE_1, keccak256("doc1"));

        // Now in PENDING, should fail
        vm.expectRevert("Wrong state");
        clause.intakeDocumentHash(INSTANCE_1, keccak256("doc2"));
    }

    // =============================================================
    // ACTION TESTS - SIGNING
    // =============================================================

    function test_ActionSign_SingleSigner_Success() public {
        // Setup
        address[] memory signers = new address[](1);
        signers[0] = alice;
        clause.intakeSigners(INSTANCE_1, signers);
        clause.intakeDocumentHash(INSTANCE_1, keccak256("doc"));

        // Sign as alice
        vm.prank(alice);
        clause.actionSign(INSTANCE_1, abi.encodePacked("alice-signature"));

        assertTrue(clause.queryHasSigned(INSTANCE_1, alice));
        assertEq(clause.queryStatus(INSTANCE_1), COMPLETE);
    }

    function test_ActionSign_MultipleSigners_PartialComplete() public {
        // Setup with 2 signers
        address[] memory signers = new address[](2);
        signers[0] = alice;
        signers[1] = bob;
        clause.intakeSigners(INSTANCE_1, signers);
        clause.intakeDocumentHash(INSTANCE_1, keccak256("doc"));

        // Alice signs
        vm.prank(alice);
        clause.actionSign(INSTANCE_1, abi.encodePacked("alice-signature"));

        assertTrue(clause.queryHasSigned(INSTANCE_1, alice));
        assertFalse(clause.queryHasSigned(INSTANCE_1, bob));
        assertEq(clause.queryStatus(INSTANCE_1), PENDING); // Not complete yet
    }

    function test_ActionSign_MultipleSigners_Complete() public {
        // Setup with 2 signers
        address[] memory signers = new address[](2);
        signers[0] = alice;
        signers[1] = bob;
        clause.intakeSigners(INSTANCE_1, signers);
        clause.intakeDocumentHash(INSTANCE_1, keccak256("doc"));

        // Both sign
        vm.prank(alice);
        clause.actionSign(INSTANCE_1, abi.encodePacked("alice-signature"));

        vm.prank(bob);
        clause.actionSign(INSTANCE_1, abi.encodePacked("bob-signature"));

        assertTrue(clause.queryHasSigned(INSTANCE_1, alice));
        assertTrue(clause.queryHasSigned(INSTANCE_1, bob));
        assertEq(clause.queryStatus(INSTANCE_1), COMPLETE);
    }

    function test_ActionSign_OnlyInPending() public {
        // Try signing before initialization complete
        vm.prank(alice);
        vm.expectRevert("Wrong state");
        clause.actionSign(INSTANCE_1, abi.encodePacked("sig"));
    }

    function test_ActionSign_OrderDoesNotMatter() public {
        // Setup with 3 signers
        address[] memory signers = new address[](3);
        signers[0] = alice;
        signers[1] = bob;
        signers[2] = charlie;
        clause.intakeSigners(INSTANCE_1, signers);
        clause.intakeDocumentHash(INSTANCE_1, keccak256("doc"));

        // Sign in reverse order
        vm.prank(charlie);
        clause.actionSign(INSTANCE_1, abi.encodePacked("charlie-sig"));

        vm.prank(alice);
        clause.actionSign(INSTANCE_1, abi.encodePacked("alice-sig"));

        vm.prank(bob);
        clause.actionSign(INSTANCE_1, abi.encodePacked("bob-sig"));

        assertEq(clause.queryStatus(INSTANCE_1), COMPLETE);
    }

    // =============================================================
    // ACTION TESTS - CANCEL
    // =============================================================

    function test_ActionCancel_Success() public {
        // Setup
        address[] memory signers = new address[](1);
        signers[0] = alice;
        clause.intakeSigners(INSTANCE_1, signers);
        clause.intakeDocumentHash(INSTANCE_1, keccak256("doc"));

        assertEq(clause.queryStatus(INSTANCE_1), PENDING);

        clause.actionCancel(INSTANCE_1);

        assertEq(clause.queryStatus(INSTANCE_1), CANCELLED);
    }

    function test_ActionCancel_OnlyInPending() public {
        // Not initialized yet
        vm.expectRevert("Wrong state");
        clause.actionCancel(INSTANCE_1);
    }

    function test_ActionCancel_NotInComplete() public {
        // Setup and complete
        address[] memory signers = new address[](1);
        signers[0] = alice;
        clause.intakeSigners(INSTANCE_1, signers);
        clause.intakeDocumentHash(INSTANCE_1, keccak256("doc"));

        vm.prank(alice);
        clause.actionSign(INSTANCE_1, abi.encodePacked("sig"));

        assertEq(clause.queryStatus(INSTANCE_1), COMPLETE);

        // Can't cancel after completion
        vm.expectRevert("Wrong state");
        clause.actionCancel(INSTANCE_1);
    }

    // =============================================================
    // HANDOFF TESTS
    // =============================================================

    function test_HandoffSigners_OnlyInComplete() public {
        // Setup but don't complete
        address[] memory signers = new address[](2);
        signers[0] = alice;
        signers[1] = bob;
        clause.intakeSigners(INSTANCE_1, signers);
        clause.intakeDocumentHash(INSTANCE_1, keccak256("doc"));

        // In PENDING state
        vm.expectRevert("Wrong state");
        clause.handoffSigners(INSTANCE_1);
    }

    function test_HandoffSigners_Success() public {
        // Setup and complete
        address[] memory signers = new address[](2);
        signers[0] = alice;
        signers[1] = bob;
        clause.intakeSigners(INSTANCE_1, signers);
        clause.intakeDocumentHash(INSTANCE_1, keccak256("doc"));

        vm.prank(alice);
        clause.actionSign(INSTANCE_1, abi.encodePacked("alice-sig"));
        vm.prank(bob);
        clause.actionSign(INSTANCE_1, abi.encodePacked("bob-sig"));

        assertEq(clause.queryStatus(INSTANCE_1), COMPLETE);

        address[] memory handedOff = clause.handoffSigners(INSTANCE_1);
        assertEq(handedOff.length, 2);
        assertEq(handedOff[0], alice);
        assertEq(handedOff[1], bob);
    }

    function test_HandoffDocumentHash_OnlyInComplete() public {
        // Setup but don't complete
        address[] memory signers = new address[](1);
        signers[0] = alice;
        clause.intakeSigners(INSTANCE_1, signers);
        clause.intakeDocumentHash(INSTANCE_1, keccak256("doc"));

        // In PENDING state
        vm.expectRevert("Wrong state");
        clause.handoffDocumentHash(INSTANCE_1);
    }

    function test_HandoffDocumentHash_Success() public {
        bytes32 docHash = keccak256("my-document");

        // Setup and complete
        address[] memory signers = new address[](1);
        signers[0] = alice;
        clause.intakeSigners(INSTANCE_1, signers);
        clause.intakeDocumentHash(INSTANCE_1, docHash);

        vm.prank(alice);
        clause.actionSign(INSTANCE_1, abi.encodePacked("sig"));

        assertEq(clause.queryStatus(INSTANCE_1), COMPLETE);

        bytes32 handedOff = clause.handoffDocumentHash(INSTANCE_1);
        assertEq(handedOff, docHash);
    }

    // =============================================================
    // QUERY TESTS
    // =============================================================

    function test_QueryStatus_AlwaysAvailable() public {
        // Works in UNINITIALIZED
        assertEq(clause.queryStatus(INSTANCE_1), 0);

        // Setup
        address[] memory signers = new address[](1);
        signers[0] = alice;
        clause.intakeSigners(INSTANCE_1, signers);
        clause.intakeDocumentHash(INSTANCE_1, keccak256("doc"));

        // Works in PENDING
        assertEq(clause.queryStatus(INSTANCE_1), PENDING);

        vm.prank(alice);
        clause.actionSign(INSTANCE_1, abi.encodePacked("sig"));

        // Works in COMPLETE
        assertEq(clause.queryStatus(INSTANCE_1), COMPLETE);
    }

    function test_QueryHasSigned_AlwaysAvailable() public view {
        // Works even before initialization
        assertFalse(clause.queryHasSigned(INSTANCE_1, alice));
        assertFalse(clause.queryHasSigned(INSTANCE_1, bob));
    }

    function test_QuerySigners_AlwaysAvailable() public {
        // Works in UNINITIALIZED (empty)
        address[] memory empty = clause.querySigners(INSTANCE_1);
        assertEq(empty.length, 0);

        // Setup
        address[] memory signers = new address[](2);
        signers[0] = alice;
        signers[1] = bob;
        clause.intakeSigners(INSTANCE_1, signers);

        // Works after intake
        address[] memory stored = clause.querySigners(INSTANCE_1);
        assertEq(stored.length, 2);
    }

    // =============================================================
    // INSTANCE ISOLATION TESTS
    // =============================================================

    function test_MultipleInstances_Independent() public {
        // Setup two independent signing instances
        address[] memory signers1 = new address[](1);
        signers1[0] = alice;
        clause.intakeSigners(INSTANCE_1, signers1);
        clause.intakeDocumentHash(INSTANCE_1, keccak256("doc1"));

        address[] memory signers2 = new address[](2);
        signers2[0] = bob;
        signers2[1] = charlie;
        clause.intakeSigners(INSTANCE_2, signers2);
        clause.intakeDocumentHash(INSTANCE_2, keccak256("doc2"));

        // Complete instance 1
        vm.prank(alice);
        clause.actionSign(INSTANCE_1, abi.encodePacked("alice-sig"));

        // Verify instance 1 is complete but instance 2 is not
        assertEq(clause.queryStatus(INSTANCE_1), COMPLETE);
        assertEq(clause.queryStatus(INSTANCE_2), PENDING);

        // Instance 2 signers are independent
        assertFalse(clause.queryHasSigned(INSTANCE_2, alice)); // Alice is not a signer in instance 2
        assertFalse(clause.queryHasSigned(INSTANCE_2, bob));
        assertFalse(clause.queryHasSigned(INSTANCE_2, charlie));
    }

    function test_MultipleInstances_DifferentDocuments() public {
        bytes32 doc1 = keccak256("document-1");
        bytes32 doc2 = keccak256("document-2");

        address[] memory signers = new address[](1);
        signers[0] = alice;

        // Setup both instances
        clause.intakeSigners(INSTANCE_1, signers);
        clause.intakeDocumentHash(INSTANCE_1, doc1);

        clause.intakeSigners(INSTANCE_2, signers);
        clause.intakeDocumentHash(INSTANCE_2, doc2);

        // Complete both
        vm.startPrank(alice);
        clause.actionSign(INSTANCE_1, abi.encodePacked("sig1"));
        clause.actionSign(INSTANCE_2, abi.encodePacked("sig2"));
        vm.stopPrank();

        // Verify different document hashes
        assertEq(clause.handoffDocumentHash(INSTANCE_1), doc1);
        assertEq(clause.handoffDocumentHash(INSTANCE_2), doc2);
    }

    // =============================================================
    // STATE MACHINE TESTS
    // =============================================================

    function test_StateMachine_FullFlow() public {
        // Start: UNINITIALIZED (0)
        assertEq(clause.queryStatus(INSTANCE_1), 0);

        // Intake signers (still UNINITIALIZED)
        address[] memory signers = new address[](2);
        signers[0] = alice;
        signers[1] = bob;
        clause.intakeSigners(INSTANCE_1, signers);
        assertEq(clause.queryStatus(INSTANCE_1), 0);

        // Intake document hash -> PENDING
        clause.intakeDocumentHash(INSTANCE_1, keccak256("doc"));
        assertEq(clause.queryStatus(INSTANCE_1), PENDING);

        // Partial signing (still PENDING)
        vm.prank(alice);
        clause.actionSign(INSTANCE_1, abi.encodePacked("sig"));
        assertEq(clause.queryStatus(INSTANCE_1), PENDING);

        // Complete signing -> COMPLETE
        vm.prank(bob);
        clause.actionSign(INSTANCE_1, abi.encodePacked("sig"));
        assertEq(clause.queryStatus(INSTANCE_1), COMPLETE);
    }

    function test_StateMachine_CancelFlow() public {
        // Setup to PENDING
        address[] memory signers = new address[](1);
        signers[0] = alice;
        clause.intakeSigners(INSTANCE_1, signers);
        clause.intakeDocumentHash(INSTANCE_1, keccak256("doc"));
        assertEq(clause.queryStatus(INSTANCE_1), PENDING);

        // Cancel -> CANCELLED
        clause.actionCancel(INSTANCE_1);
        assertEq(clause.queryStatus(INSTANCE_1), CANCELLED);

        // Can't do anything from CANCELLED
        vm.expectRevert("Wrong state");
        clause.actionCancel(INSTANCE_1);

        vm.prank(alice);
        vm.expectRevert("Wrong state");
        clause.actionSign(INSTANCE_1, abi.encodePacked("sig"));

        vm.expectRevert("Wrong state");
        clause.handoffSigners(INSTANCE_1);
    }

    // =============================================================
    // EDGE CASES
    // =============================================================

    function test_SingleSigner_ImmediateComplete() public {
        address[] memory signers = new address[](1);
        signers[0] = alice;
        clause.intakeSigners(INSTANCE_1, signers);
        clause.intakeDocumentHash(INSTANCE_1, keccak256("doc"));

        vm.prank(alice);
        clause.actionSign(INSTANCE_1, abi.encodePacked("sig"));

        // Should be complete after single signature
        assertEq(clause.queryStatus(INSTANCE_1), COMPLETE);
    }

    function test_NonSignerCanStillSign() public {
        // Note: The v3 spec doesn't restrict who can sign - that's for the Agreement to enforce
        // The clause just records that msg.sender signed
        address[] memory signers = new address[](1);
        signers[0] = alice;
        clause.intakeSigners(INSTANCE_1, signers);
        clause.intakeDocumentHash(INSTANCE_1, keccak256("doc"));

        // Charlie is not in signers list but can still call actionSign
        // However, _allSigned() checks if all _signers have signed
        vm.prank(charlie);
        clause.actionSign(INSTANCE_1, abi.encodePacked("charlie-sig"));

        // Charlie's signature is recorded
        assertTrue(clause.queryHasSigned(INSTANCE_1, charlie));

        // But not complete because alice hasn't signed
        assertEq(clause.queryStatus(INSTANCE_1), PENDING);

        // Now alice signs
        vm.prank(alice);
        clause.actionSign(INSTANCE_1, abi.encodePacked("alice-sig"));

        // Now complete
        assertEq(clause.queryStatus(INSTANCE_1), COMPLETE);
    }

    // =============================================================
    // FUZZ TESTS
    // =============================================================

    function testFuzz_IntakeSigners_VariableCounts(uint8 count) public {
        vm.assume(count > 0 && count <= 20);

        address[] memory signers = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            signers[i] = address(uint160(i + 1));
        }

        clause.intakeSigners(INSTANCE_1, signers);

        address[] memory stored = clause.querySigners(INSTANCE_1);
        assertEq(stored.length, count);
    }

    function testFuzz_InstanceIsolation(bytes32 id1, bytes32 id2) public {
        vm.assume(id1 != id2);

        address[] memory signers = new address[](1);
        signers[0] = alice;

        // Setup first instance
        clause.intakeSigners(id1, signers);
        clause.intakeDocumentHash(id1, keccak256("doc1"));

        // Second instance should be unaffected
        assertEq(clause.queryStatus(id2), 0);
        assertEq(clause.querySigners(id2).length, 0);
    }

    // =============================================================
    // TRUSTED ATTESTOR TESTS
    // =============================================================

    function test_SetTrustedAttestor_Success() public {
        address testAttestor = makeAddr("testAttestor");

        clause.setTrustedAttestor(testAttestor, true);

        assertTrue(clause.queryIsTrustedAttestor(testAttestor));
    }

    function test_SetTrustedAttestor_Revoke() public {
        address testAttestor = makeAddr("testAttestor");

        // First set as trusted
        clause.setTrustedAttestor(testAttestor, true);
        assertTrue(clause.queryIsTrustedAttestor(testAttestor));

        // Then revoke
        clause.setTrustedAttestor(testAttestor, false);
        assertFalse(clause.queryIsTrustedAttestor(testAttestor));
    }

    function test_QueryIsTrustedAttestor_True() public {
        address testAttestor = makeAddr("testAttestor");
        clause.setTrustedAttestor(testAttestor, true);
        assertTrue(clause.queryIsTrustedAttestor(testAttestor));
    }

    function test_QueryIsTrustedAttestor_False() public {
        address testAttestor = makeAddr("testAttestor");
        assertFalse(clause.queryIsTrustedAttestor(testAttestor));
    }

    // =============================================================
    // PENDING SLOT TRACKING TESTS
    // =============================================================

    function test_IntakeSigners_WithPendingSlot_TracksIndex() public {
        address[] memory signers = new address[](2);
        signers[0] = alice;
        signers[1] = address(0); // Pending slot

        clause.intakeSigners(INSTANCE_1, signers);

        (bool hasPending, uint256 count, uint256[] memory indices) = clause.queryHasPendingSlots(INSTANCE_1);

        assertTrue(hasPending);
        assertEq(count, 1);
        assertEq(indices.length, 1);
        assertEq(indices[0], 1); // Index 1 is pending
    }

    function test_IntakeSigners_MultiplePendingSlots() public {
        address[] memory signers = new address[](3);
        signers[0] = address(0); // Pending slot
        signers[1] = alice;
        signers[2] = address(0); // Pending slot

        clause.intakeSigners(INSTANCE_1, signers);

        (bool hasPending, uint256 count, uint256[] memory indices) = clause.queryHasPendingSlots(INSTANCE_1);

        assertTrue(hasPending);
        assertEq(count, 2);
        assertEq(indices.length, 2);
        // Note: indices may be in any order
        assertTrue(indices[0] == 0 || indices[0] == 2);
        assertTrue(indices[1] == 0 || indices[1] == 2);
        assertTrue(indices[0] != indices[1]);
    }

    function test_QueryHasPendingSlots_WithPending() public {
        address[] memory signers = new address[](2);
        signers[0] = alice;
        signers[1] = address(0);

        clause.intakeSigners(INSTANCE_1, signers);

        (bool hasPending, uint256 count,) = clause.queryHasPendingSlots(INSTANCE_1);

        assertTrue(hasPending);
        assertEq(count, 1);
    }

    function test_QueryHasPendingSlots_NoPending() public {
        address[] memory signers = new address[](2);
        signers[0] = alice;
        signers[1] = bob;

        clause.intakeSigners(INSTANCE_1, signers);

        (bool hasPending, uint256 count, uint256[] memory indices) = clause.queryHasPendingSlots(INSTANCE_1);

        assertFalse(hasPending);
        assertEq(count, 0);
        assertEq(indices.length, 0);
    }

    // =============================================================
    // CLAIM SLOT TESTS (ECDSA)
    // =============================================================

    uint256 constant ATTESTOR_PK = 0xA77E5702;
    address attestor;

    function _setupAttestor() internal {
        attestor = vm.addr(ATTESTOR_PK);
        clause.setTrustedAttestor(attestor, true);
    }

    function _createAttestation(
        bytes32 instanceId,
        uint256 slotIndex,
        address claimer
    ) internal view returns (bytes memory) {
        bytes32 messageHash = keccak256(abi.encode(
            address(clause),
            instanceId,
            slotIndex,
            claimer,
            "CLAIM_SIGNER_SLOT"
        ));
        bytes32 ethSignedHash = messageHash.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ATTESTOR_PK, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }

    function test_ClaimSignerSlot_Success() public {
        _setupAttestor();

        // Setup with pending slot at index 1
        address[] memory signers = new address[](2);
        signers[0] = alice;
        signers[1] = address(0); // Pending slot for contractor

        clause.intakeSigners(INSTANCE_1, signers);
        clause.intakeDocumentHash(INSTANCE_1, keccak256("doc"));

        // Create attestation for bob to claim slot 1
        bytes memory attestation = _createAttestation(INSTANCE_1, 1, bob);

        // Bob claims the slot
        vm.prank(bob);
        clause.actionClaimSignerSlot(INSTANCE_1, 1, bob, attestation);

        // Verify bob is now in the signers list
        address[] memory updatedSigners = clause.querySigners(INSTANCE_1);
        assertEq(updatedSigners[1], bob);

        // Verify no more pending slots
        (bool hasPending,,) = clause.queryHasPendingSlots(INSTANCE_1);
        assertFalse(hasPending);
    }

    function test_ClaimSignerSlot_EmitsEvent() public {
        _setupAttestor();

        address[] memory signers = new address[](2);
        signers[0] = alice;
        signers[1] = address(0);

        clause.intakeSigners(INSTANCE_1, signers);
        clause.intakeDocumentHash(INSTANCE_1, keccak256("doc"));

        bytes memory attestation = _createAttestation(INSTANCE_1, 1, bob);

        vm.expectEmit(true, true, true, true);
        emit SignatureClauseLogicV3.SignerSlotClaimed(INSTANCE_1, 1, bob, attestor);

        vm.prank(bob);
        clause.actionClaimSignerSlot(INSTANCE_1, 1, bob, attestation);
    }

    function test_ClaimSignerSlot_RevertsSlotNotPending() public {
        _setupAttestor();

        // Setup with no pending slots
        address[] memory signers = new address[](2);
        signers[0] = alice;
        signers[1] = bob;

        clause.intakeSigners(INSTANCE_1, signers);
        clause.intakeDocumentHash(INSTANCE_1, keccak256("doc"));

        bytes memory attestation = _createAttestation(INSTANCE_1, 1, charlie);

        vm.expectRevert(abi.encodeWithSelector(
            SignatureClauseLogicV3.SlotAlreadyFilled.selector,
            INSTANCE_1,
            1
        ));
        vm.prank(charlie);
        clause.actionClaimSignerSlot(INSTANCE_1, 1, charlie, attestation);
    }

    function test_ClaimSignerSlot_RevertsSlotAlreadyFilled() public {
        _setupAttestor();

        address[] memory signers = new address[](2);
        signers[0] = alice;
        signers[1] = address(0);

        clause.intakeSigners(INSTANCE_1, signers);
        clause.intakeDocumentHash(INSTANCE_1, keccak256("doc"));

        // Bob claims first
        bytes memory attestation1 = _createAttestation(INSTANCE_1, 1, bob);
        vm.prank(bob);
        clause.actionClaimSignerSlot(INSTANCE_1, 1, bob, attestation1);

        // Charlie tries to claim same slot
        bytes memory attestation2 = _createAttestation(INSTANCE_1, 1, charlie);
        vm.expectRevert(abi.encodeWithSelector(
            SignatureClauseLogicV3.SlotAlreadyFilled.selector,
            INSTANCE_1,
            1
        ));
        vm.prank(charlie);
        clause.actionClaimSignerSlot(INSTANCE_1, 1, charlie, attestation2);
    }

    function test_ClaimSignerSlot_RevertsUnauthorizedAttestor() public {
        // Note: Don't setup attestor - leave untrusted
        _setupAttestor();
        // Now revoke trust
        clause.setTrustedAttestor(attestor, false);

        address[] memory signers = new address[](2);
        signers[0] = alice;
        signers[1] = address(0);

        clause.intakeSigners(INSTANCE_1, signers);
        clause.intakeDocumentHash(INSTANCE_1, keccak256("doc"));

        // Create attestation with now-untrusted attestor
        bytes memory attestation = _createAttestation(INSTANCE_1, 1, bob);

        // The recovered address will be the attestor, but it's not trusted
        vm.expectRevert(abi.encodeWithSelector(
            SignatureClauseLogicV3.UnauthorizedAttestor.selector,
            attestor
        ));
        vm.prank(bob);
        clause.actionClaimSignerSlot(INSTANCE_1, 1, bob, attestation);
    }

    function test_ClaimSignerSlot_RevertsInvalidAttestation() public {
        _setupAttestor();

        address[] memory signers = new address[](2);
        signers[0] = alice;
        signers[1] = address(0);

        clause.intakeSigners(INSTANCE_1, signers);
        clause.intakeDocumentHash(INSTANCE_1, keccak256("doc"));

        // Create attestation for wrong claimer (charlie instead of bob)
        bytes memory attestationForCharlie = _createAttestation(INSTANCE_1, 1, charlie);

        // Bob tries to use attestation meant for charlie
        // This will recover a DIFFERENT address because the message doesn't match
        // (the message includes the claimer, so changing the claimer changes the recovered address)
        // Instead of checking for a specific address, we just verify it reverts
        vm.expectRevert(); // Generic revert - either UnauthorizedAttestor or invalid signature
        vm.prank(bob);
        clause.actionClaimSignerSlot(INSTANCE_1, 1, bob, attestationForCharlie);
    }

    function test_ClaimSignerSlot_ClaimerCanThenSign() public {
        _setupAttestor();

        address[] memory signers = new address[](2);
        signers[0] = alice;
        signers[1] = address(0);

        clause.intakeSigners(INSTANCE_1, signers);
        clause.intakeDocumentHash(INSTANCE_1, keccak256("doc"));

        // Bob claims slot
        bytes memory attestation = _createAttestation(INSTANCE_1, 1, bob);
        vm.prank(bob);
        clause.actionClaimSignerSlot(INSTANCE_1, 1, bob, attestation);

        // Alice signs
        vm.prank(alice);
        clause.actionSign(INSTANCE_1, abi.encodePacked("alice-sig"));

        // Bob can now sign
        vm.prank(bob);
        clause.actionSign(INSTANCE_1, abi.encodePacked("bob-sig"));

        // Both have signed, should be complete
        assertEq(clause.queryStatus(INSTANCE_1), COMPLETE);
        assertTrue(clause.queryHasSigned(INSTANCE_1, alice));
        assertTrue(clause.queryHasSigned(INSTANCE_1, bob));
    }

    function test_ClaimSignerSlot_RevertsClaimerAlreadySigner() public {
        _setupAttestor();

        address[] memory signers = new address[](2);
        signers[0] = alice;
        signers[1] = address(0);

        clause.intakeSigners(INSTANCE_1, signers);
        clause.intakeDocumentHash(INSTANCE_1, keccak256("doc"));

        // Alice tries to claim the pending slot (but she's already a signer at index 0)
        bytes memory attestation = _createAttestation(INSTANCE_1, 1, alice);

        vm.expectRevert(abi.encodeWithSelector(
            SignatureClauseLogicV3.ClaimerAlreadySigner.selector,
            INSTANCE_1,
            alice
        ));
        vm.prank(alice);
        clause.actionClaimSignerSlot(INSTANCE_1, 1, alice, attestation);
    }

    // =============================================================
    // SIGNING WITH PENDING SLOTS TESTS
    // =============================================================

    function test_ActionSign_SkipsPendingSlots() public {
        // Setup with one real signer and one pending
        address[] memory signers = new address[](2);
        signers[0] = alice;
        signers[1] = address(0); // Pending - should be skipped

        clause.intakeSigners(INSTANCE_1, signers);
        clause.intakeDocumentHash(INSTANCE_1, keccak256("doc"));

        // Alice signs
        vm.prank(alice);
        clause.actionSign(INSTANCE_1, abi.encodePacked("alice-sig"));

        // Should be complete even though slot 1 is pending (address(0))
        // because _allSigned skips address(0) entries
        assertEq(clause.queryStatus(INSTANCE_1), COMPLETE);
    }

    function test_Complete_WhenAllNonPendingSigned() public {
        // Setup with 3 signers: alice, pending, bob
        address[] memory signers = new address[](3);
        signers[0] = alice;
        signers[1] = address(0); // Pending
        signers[2] = bob;

        clause.intakeSigners(INSTANCE_1, signers);
        clause.intakeDocumentHash(INSTANCE_1, keccak256("doc"));

        // Alice signs
        vm.prank(alice);
        clause.actionSign(INSTANCE_1, abi.encodePacked("alice-sig"));

        // Not complete yet - bob hasn't signed
        assertEq(clause.queryStatus(INSTANCE_1), PENDING);

        // Bob signs
        vm.prank(bob);
        clause.actionSign(INSTANCE_1, abi.encodePacked("bob-sig"));

        // Now complete - pending slot is skipped
        assertEq(clause.queryStatus(INSTANCE_1), COMPLETE);
    }

    function test_PendingSlotClaimed_ThenMustSign() public {
        _setupAttestor();

        // Setup with 2 signers: alice, pending
        address[] memory signers = new address[](2);
        signers[0] = alice;
        signers[1] = address(0);

        clause.intakeSigners(INSTANCE_1, signers);
        clause.intakeDocumentHash(INSTANCE_1, keccak256("doc"));

        // Alice signs first (before slot is claimed)
        vm.prank(alice);
        clause.actionSign(INSTANCE_1, abi.encodePacked("alice-sig"));

        // With pending slot, signing should be complete
        assertEq(clause.queryStatus(INSTANCE_1), COMPLETE);

        // Now let's test a different scenario in a new instance
        bytes32 INSTANCE_3 = bytes32(uint256(3));

        clause.intakeSigners(INSTANCE_3, signers);
        clause.intakeDocumentHash(INSTANCE_3, keccak256("doc"));

        // Charlie claims the pending slot BEFORE anyone signs
        bytes memory attestation = _createAttestation(INSTANCE_3, 1, charlie);
        vm.prank(charlie);
        clause.actionClaimSignerSlot(INSTANCE_3, 1, charlie, attestation);

        // Alice signs
        vm.prank(alice);
        clause.actionSign(INSTANCE_3, abi.encodePacked("alice-sig"));

        // Not complete yet because charlie (who claimed) hasn't signed
        assertEq(clause.queryStatus(INSTANCE_3), PENDING);

        // Charlie signs
        vm.prank(charlie);
        clause.actionSign(INSTANCE_3, abi.encodePacked("charlie-sig"));

        // Now complete
        assertEq(clause.queryStatus(INSTANCE_3), COMPLETE);
    }
}
