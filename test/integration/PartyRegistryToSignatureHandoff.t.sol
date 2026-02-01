// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {PartyRegistryClauseLogicV3} from "../../src/clauses/access/PartyRegistryClauseLogicV3.sol";
import {SignatureClauseLogicV3} from "../../src/clauses/attestation/SignatureClauseLogicV3.sol";

/// @title PartyRegistry → Signature Handoff Integration Tests
/// @notice Tests all handoff patterns from PartyRegistryClauseLogicV3 to SignatureClauseLogicV3
/// @dev Includes unit tests, fuzz tests, and invariant tests
contract PartyRegistryToSignatureHandoffTest is Test {
    PartyRegistryClauseLogicV3 public registry;
    SignatureClauseLogicV3 public signature;

    // Test accounts
    address alice;
    address bob;
    address charlie;
    address david;
    address eve;

    // Instance IDs
    bytes32 constant REGISTRY_INSTANCE = bytes32(uint256(1));
    bytes32 constant SIGNATURE_INSTANCE = bytes32(uint256(2));

    // Role constants
    bytes32 constant SIGNER = keccak256("SIGNER");
    bytes32 constant ARBITER = keccak256("ARBITER");
    bytes32 constant BENEFICIARY = keccak256("BENEFICIARY");
    bytes32 constant WITNESS = keccak256("WITNESS");

    // State constants
    uint16 constant ACTIVE = 1 << 1;
    uint16 constant PENDING = 1 << 1;
    uint16 constant COMPLETE = 1 << 2;

    function setUp() public {
        registry = new PartyRegistryClauseLogicV3();
        signature = new SignatureClauseLogicV3();

        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");
        david = makeAddr("david");
        eve = makeAddr("eve");
    }

    // =============================================================
    // BASIC HANDOFF PATTERNS
    // =============================================================

    /// @notice Single signer handoff - simplest case
    function test_Handoff_SingleSigner() public {
        // Setup registry with one signer
        registry.intakeParty(REGISTRY_INSTANCE, alice, SIGNER);
        registry.intakeReady(REGISTRY_INSTANCE);

        // Handoff to signature clause
        address[] memory signers = registry.handoffPartiesInRole(REGISTRY_INSTANCE, SIGNER);
        signature.intakeSigners(SIGNATURE_INSTANCE, signers);
        signature.intakeDocumentHash(SIGNATURE_INSTANCE, keccak256("document"));

        // Verify handoff worked
        assertEq(signature.querySigners(SIGNATURE_INSTANCE).length, 1);
        assertEq(signature.querySigners(SIGNATURE_INSTANCE)[0], alice);

        // Complete signing
        vm.prank(alice);
        signature.actionSign(SIGNATURE_INSTANCE, abi.encodePacked("alice-sig"));
        assertEq(signature.queryStatus(SIGNATURE_INSTANCE), COMPLETE);
    }

    /// @notice Multiple signers handoff
    function test_Handoff_MultipleSigners() public {
        // Setup registry with multiple signers
        registry.intakeParty(REGISTRY_INSTANCE, alice, SIGNER);
        registry.intakeParty(REGISTRY_INSTANCE, bob, SIGNER);
        registry.intakeParty(REGISTRY_INSTANCE, charlie, SIGNER);
        registry.intakeReady(REGISTRY_INSTANCE);

        // Handoff to signature clause
        address[] memory signers = registry.handoffPartiesInRole(REGISTRY_INSTANCE, SIGNER);
        signature.intakeSigners(SIGNATURE_INSTANCE, signers);
        signature.intakeDocumentHash(SIGNATURE_INSTANCE, keccak256("document"));

        // Verify all signers transferred
        assertEq(signature.querySigners(SIGNATURE_INSTANCE).length, 3);

        // All must sign for completion
        vm.prank(alice);
        signature.actionSign(SIGNATURE_INSTANCE, abi.encodePacked("alice-sig"));
        assertEq(signature.queryStatus(SIGNATURE_INSTANCE), PENDING);

        vm.prank(bob);
        signature.actionSign(SIGNATURE_INSTANCE, abi.encodePacked("bob-sig"));
        assertEq(signature.queryStatus(SIGNATURE_INSTANCE), PENDING);

        vm.prank(charlie);
        signature.actionSign(SIGNATURE_INSTANCE, abi.encodePacked("charlie-sig"));
        assertEq(signature.queryStatus(SIGNATURE_INSTANCE), COMPLETE);
    }

    /// @notice Handoff only SIGNER role, ignoring other roles
    function test_Handoff_OnlySignerRole_IgnoresOtherRoles() public {
        // Setup registry with mixed roles
        registry.intakeParty(REGISTRY_INSTANCE, alice, SIGNER);
        registry.intakeParty(REGISTRY_INSTANCE, bob, SIGNER);
        registry.intakeParty(REGISTRY_INSTANCE, charlie, ARBITER); // Not a signer
        registry.intakeParty(REGISTRY_INSTANCE, david, BENEFICIARY); // Not a signer
        registry.intakeReady(REGISTRY_INSTANCE);

        // Handoff only signers
        address[] memory signers = registry.handoffPartiesInRole(REGISTRY_INSTANCE, SIGNER);
        signature.intakeSigners(SIGNATURE_INSTANCE, signers);
        signature.intakeDocumentHash(SIGNATURE_INSTANCE, keccak256("document"));

        // Only alice and bob should be signers
        assertEq(signature.querySigners(SIGNATURE_INSTANCE).length, 2);

        // Charlie and david cannot complete the signing
        vm.prank(charlie);
        signature.actionSign(SIGNATURE_INSTANCE, abi.encodePacked("charlie-sig"));
        assertEq(signature.queryStatus(SIGNATURE_INSTANCE), PENDING); // Still pending

        // alice and bob must sign
        vm.prank(alice);
        signature.actionSign(SIGNATURE_INSTANCE, abi.encodePacked("alice-sig"));
        vm.prank(bob);
        signature.actionSign(SIGNATURE_INSTANCE, abi.encodePacked("bob-sig"));
        assertEq(signature.queryStatus(SIGNATURE_INSTANCE), COMPLETE);
    }

    /// @notice Party with multiple roles - only counted once as signer
    function test_Handoff_PartyWithMultipleRoles() public {
        // Alice has both SIGNER and ARBITER roles
        registry.intakeParty(REGISTRY_INSTANCE, alice, SIGNER);
        registry.intakeParty(REGISTRY_INSTANCE, alice, ARBITER);
        registry.intakeParty(REGISTRY_INSTANCE, bob, SIGNER);
        registry.intakeReady(REGISTRY_INSTANCE);

        // Handoff signers
        address[] memory signers = registry.handoffPartiesInRole(REGISTRY_INSTANCE, SIGNER);
        signature.intakeSigners(SIGNATURE_INSTANCE, signers);
        signature.intakeDocumentHash(SIGNATURE_INSTANCE, keccak256("document"));

        // Alice should appear only once
        assertEq(signature.querySigners(SIGNATURE_INSTANCE).length, 2);

        // Both must sign
        vm.prank(alice);
        signature.actionSign(SIGNATURE_INSTANCE, abi.encodePacked("alice-sig"));
        vm.prank(bob);
        signature.actionSign(SIGNATURE_INSTANCE, abi.encodePacked("bob-sig"));
        assertEq(signature.queryStatus(SIGNATURE_INSTANCE), COMPLETE);
    }

    /// @notice Empty signer list handoff (edge case)
    function test_Handoff_EmptySignerList() public {
        // Registry with no signers (only other roles)
        registry.intakeParty(REGISTRY_INSTANCE, alice, ARBITER);
        registry.intakeParty(REGISTRY_INSTANCE, bob, BENEFICIARY);
        registry.intakeReady(REGISTRY_INSTANCE);

        // Handoff empty signer list
        address[] memory signers = registry.handoffPartiesInRole(REGISTRY_INSTANCE, SIGNER);
        assertEq(signers.length, 0);

        signature.intakeSigners(SIGNATURE_INSTANCE, signers);
        signature.intakeDocumentHash(SIGNATURE_INSTANCE, keccak256("document"));

        // After intakeDocumentHash, status is PENDING
        assertEq(signature.queryStatus(SIGNATURE_INSTANCE), PENDING);

        // With no signers required, anyone calling actionSign will trigger completion
        // because _allSigned() returns true for an empty signer list
        vm.prank(alice); // Alice is not a signer, but can still call
        signature.actionSign(SIGNATURE_INSTANCE, abi.encodePacked("trigger"));

        // Now it should be complete
        assertEq(signature.queryStatus(SIGNATURE_INSTANCE), COMPLETE);
    }

    // =============================================================
    // MULTIPLE INSTANCE HANDOFF PATTERNS
    // =============================================================

    /// @notice Same registry feeding multiple signature instances
    function test_Handoff_OneRegistryToMultipleSignatures() public {
        bytes32 sigInstance1 = keccak256("signing-1");
        bytes32 sigInstance2 = keccak256("signing-2");

        // Setup registry with signers
        registry.intakeParty(REGISTRY_INSTANCE, alice, SIGNER);
        registry.intakeParty(REGISTRY_INSTANCE, bob, SIGNER);
        registry.intakeReady(REGISTRY_INSTANCE);

        // Handoff to first signature instance
        address[] memory signers = registry.handoffPartiesInRole(REGISTRY_INSTANCE, SIGNER);
        signature.intakeSigners(sigInstance1, signers);
        signature.intakeDocumentHash(sigInstance1, keccak256("document-1"));

        // Handoff to second signature instance (same signers, different doc)
        signature.intakeSigners(sigInstance2, signers);
        signature.intakeDocumentHash(sigInstance2, keccak256("document-2"));

        // Complete first signing
        vm.startPrank(alice);
        signature.actionSign(sigInstance1, abi.encodePacked("alice-sig-1"));
        vm.stopPrank();
        vm.startPrank(bob);
        signature.actionSign(sigInstance1, abi.encodePacked("bob-sig-1"));
        vm.stopPrank();

        // First complete, second still pending
        assertEq(signature.queryStatus(sigInstance1), COMPLETE);
        assertEq(signature.queryStatus(sigInstance2), PENDING);

        // Complete second signing
        vm.startPrank(alice);
        signature.actionSign(sigInstance2, abi.encodePacked("alice-sig-2"));
        vm.stopPrank();
        vm.startPrank(bob);
        signature.actionSign(sigInstance2, abi.encodePacked("bob-sig-2"));
        vm.stopPrank();

        assertEq(signature.queryStatus(sigInstance2), COMPLETE);
    }

    /// @notice Different roles to different signature instances
    function test_Handoff_DifferentRolesToDifferentSignatures() public {
        bytes32 signerSigning = keccak256("signer-signing");
        bytes32 witnessSigning = keccak256("witness-signing");

        // Setup registry with multiple roles
        registry.intakeParty(REGISTRY_INSTANCE, alice, SIGNER);
        registry.intakeParty(REGISTRY_INSTANCE, bob, SIGNER);
        registry.intakeParty(REGISTRY_INSTANCE, charlie, WITNESS);
        registry.intakeParty(REGISTRY_INSTANCE, david, WITNESS);
        registry.intakeReady(REGISTRY_INSTANCE);

        // Signers sign main document
        address[] memory signers = registry.handoffPartiesInRole(REGISTRY_INSTANCE, SIGNER);
        signature.intakeSigners(signerSigning, signers);
        signature.intakeDocumentHash(signerSigning, keccak256("main-document"));

        // Witnesses sign attestation
        address[] memory witnesses = registry.handoffPartiesInRole(REGISTRY_INSTANCE, WITNESS);
        signature.intakeSigners(witnessSigning, witnesses);
        signature.intakeDocumentHash(witnessSigning, keccak256("attestation"));

        // Verify correct parties in each
        assertEq(signature.querySigners(signerSigning).length, 2);
        assertEq(signature.querySigners(witnessSigning).length, 2);

        // Complete both independently
        vm.prank(alice);
        signature.actionSign(signerSigning, abi.encodePacked("alice-sig"));
        vm.prank(bob);
        signature.actionSign(signerSigning, abi.encodePacked("bob-sig"));

        vm.prank(charlie);
        signature.actionSign(witnessSigning, abi.encodePacked("charlie-sig"));
        vm.prank(david);
        signature.actionSign(witnessSigning, abi.encodePacked("david-sig"));

        assertEq(signature.queryStatus(signerSigning), COMPLETE);
        assertEq(signature.queryStatus(witnessSigning), COMPLETE);
    }

    /// @notice Multiple registries to one signature (union of signers)
    function test_Handoff_MultipleRegistriesToOneSignature() public {
        bytes32 registry1 = keccak256("registry-1");
        bytes32 registry2 = keccak256("registry-2");

        // First registry
        registry.intakeParty(registry1, alice, SIGNER);
        registry.intakeParty(registry1, bob, SIGNER);
        registry.intakeReady(registry1);

        // Second registry
        registry.intakeParty(registry2, charlie, SIGNER);
        registry.intakeParty(registry2, david, SIGNER);
        registry.intakeReady(registry2);

        // Combine signers from both registries
        address[] memory signers1 = registry.handoffPartiesInRole(registry1, SIGNER);
        address[] memory signers2 = registry.handoffPartiesInRole(registry2, SIGNER);

        // Manually combine (in real Agreement, this would be done in orchestration logic)
        address[] memory allSigners = new address[](4);
        allSigners[0] = signers1[0];
        allSigners[1] = signers1[1];
        allSigners[2] = signers2[0];
        allSigners[3] = signers2[1];

        signature.intakeSigners(SIGNATURE_INSTANCE, allSigners);
        signature.intakeDocumentHash(SIGNATURE_INSTANCE, keccak256("combined-document"));

        // All four must sign
        assertEq(signature.querySigners(SIGNATURE_INSTANCE).length, 4);

        vm.prank(alice);
        signature.actionSign(SIGNATURE_INSTANCE, abi.encodePacked("sig"));
        vm.prank(bob);
        signature.actionSign(SIGNATURE_INSTANCE, abi.encodePacked("sig"));
        vm.prank(charlie);
        signature.actionSign(SIGNATURE_INSTANCE, abi.encodePacked("sig"));
        assertEq(signature.queryStatus(SIGNATURE_INSTANCE), PENDING);

        vm.prank(david);
        signature.actionSign(SIGNATURE_INSTANCE, abi.encodePacked("sig"));
        assertEq(signature.queryStatus(SIGNATURE_INSTANCE), COMPLETE);
    }

    // =============================================================
    // HANDOFF CHAIN TESTS
    // =============================================================

    /// @notice Verify signature handoff can feed back data
    function test_Handoff_SignatureHandoffAfterComplete() public {
        // Setup and complete signing
        registry.intakeParty(REGISTRY_INSTANCE, alice, SIGNER);
        registry.intakeParty(REGISTRY_INSTANCE, bob, SIGNER);
        registry.intakeReady(REGISTRY_INSTANCE);

        bytes32 docHash = keccak256("important-document");

        address[] memory signers = registry.handoffPartiesInRole(REGISTRY_INSTANCE, SIGNER);
        signature.intakeSigners(SIGNATURE_INSTANCE, signers);
        signature.intakeDocumentHash(SIGNATURE_INSTANCE, docHash);

        vm.prank(alice);
        signature.actionSign(SIGNATURE_INSTANCE, abi.encodePacked("alice-sig"));
        vm.prank(bob);
        signature.actionSign(SIGNATURE_INSTANCE, abi.encodePacked("bob-sig"));

        // Now signature can handoff to next clause
        address[] memory completedSigners = signature.handoffSigners(SIGNATURE_INSTANCE);
        bytes32 completedDocHash = signature.handoffDocumentHash(SIGNATURE_INSTANCE);

        assertEq(completedSigners.length, 2);
        assertEq(completedDocHash, docHash);

        // Could feed to another clause (escrow, etc.)
    }

    // =============================================================
    // STATE VERIFICATION TESTS
    // =============================================================

    /// @notice Cannot handoff from uninitialized registry
    function test_Handoff_FailsFromUninitializedRegistry() public {
        registry.intakeParty(REGISTRY_INSTANCE, alice, SIGNER);
        // NOT calling intakeReady()

        vm.expectRevert("Wrong state");
        registry.handoffPartiesInRole(REGISTRY_INSTANCE, SIGNER);
    }

    /// @notice Cannot intake to already-initialized signature
    function test_Handoff_FailsToInitializedSignature() public {
        registry.intakeParty(REGISTRY_INSTANCE, alice, SIGNER);
        registry.intakeReady(REGISTRY_INSTANCE);

        address[] memory signers = registry.handoffPartiesInRole(REGISTRY_INSTANCE, SIGNER);
        signature.intakeSigners(SIGNATURE_INSTANCE, signers);
        signature.intakeDocumentHash(SIGNATURE_INSTANCE, keccak256("doc"));

        // Try to intake again
        vm.expectRevert("Wrong state");
        signature.intakeSigners(SIGNATURE_INSTANCE, signers);
    }

    // =============================================================
    // FUZZ TESTS
    // =============================================================

    /// @notice Fuzz test: variable number of signers
    function testFuzz_Handoff_VariableSignerCount(uint8 signerCount) public {
        vm.assume(signerCount > 0 && signerCount <= 20);

        bytes32 regInstance = keccak256(abi.encode("reg", signerCount));
        bytes32 sigInstance = keccak256(abi.encode("sig", signerCount));

        // Create signers
        address[] memory expectedSigners = new address[](signerCount);
        for (uint256 i = 0; i < signerCount; i++) {
            expectedSigners[i] = address(uint160(i + 1));
            registry.intakeParty(regInstance, expectedSigners[i], SIGNER);
        }
        registry.intakeReady(regInstance);

        // Handoff
        address[] memory handedOff = registry.handoffPartiesInRole(regInstance, SIGNER);
        signature.intakeSigners(sigInstance, handedOff);
        signature.intakeDocumentHash(sigInstance, keccak256(abi.encode("doc", signerCount)));

        // Verify count matches
        assertEq(signature.querySigners(sigInstance).length, signerCount);

        // All sign
        for (uint256 i = 0; i < signerCount; i++) {
            vm.prank(expectedSigners[i]);
            signature.actionSign(sigInstance, abi.encodePacked("sig"));
        }

        assertEq(signature.queryStatus(sigInstance), COMPLETE);
    }

    /// @notice Fuzz test: random role assignments, only signers should transfer
    function testFuzz_Handoff_RandomRoleAssignments(uint8 signerCount, uint8 nonSignerCount) public {
        vm.assume(signerCount > 0 && signerCount <= 10);
        vm.assume(nonSignerCount <= 10);

        bytes32 regInstance = keccak256(abi.encode("reg", signerCount, nonSignerCount));
        bytes32 sigInstance = keccak256(abi.encode("sig", signerCount, nonSignerCount));

        // Add signers
        for (uint256 i = 0; i < signerCount; i++) {
            registry.intakeParty(regInstance, address(uint160(i + 1)), SIGNER);
        }

        // Add non-signers with various roles
        bytes32[] memory otherRoles = new bytes32[](3);
        otherRoles[0] = ARBITER;
        otherRoles[1] = BENEFICIARY;
        otherRoles[2] = WITNESS;

        for (uint256 i = 0; i < nonSignerCount; i++) {
            address nonSigner = address(uint160(100 + i));
            bytes32 role = otherRoles[i % 3];
            registry.intakeParty(regInstance, nonSigner, role);
        }

        registry.intakeReady(regInstance);

        // Handoff only signers
        address[] memory handedOff = registry.handoffPartiesInRole(regInstance, SIGNER);

        // Verify only signers transferred
        assertEq(handedOff.length, signerCount);

        signature.intakeSigners(sigInstance, handedOff);
        signature.intakeDocumentHash(sigInstance, keccak256("doc"));

        // All signers must sign for completion
        for (uint256 i = 0; i < signerCount; i++) {
            vm.prank(address(uint160(i + 1)));
            signature.actionSign(sigInstance, abi.encodePacked("sig"));
        }

        assertEq(signature.queryStatus(sigInstance), COMPLETE);
    }

    /// @notice Fuzz test: multiple handoffs from same registry
    function testFuzz_Handoff_MultipleFromSameRegistry(uint8 handoffCount) public {
        vm.assume(handoffCount > 0 && handoffCount <= 10);

        // Setup registry once
        registry.intakeParty(REGISTRY_INSTANCE, alice, SIGNER);
        registry.intakeParty(REGISTRY_INSTANCE, bob, SIGNER);
        registry.intakeReady(REGISTRY_INSTANCE);

        address[] memory signers = registry.handoffPartiesInRole(REGISTRY_INSTANCE, SIGNER);

        // Create multiple signature instances from same handoff
        for (uint256 i = 0; i < handoffCount; i++) {
            bytes32 sigInstance = keccak256(abi.encode("sig", i));

            signature.intakeSigners(sigInstance, signers);
            signature.intakeDocumentHash(sigInstance, keccak256(abi.encode("doc", i)));

            // Complete each
            vm.prank(alice);
            signature.actionSign(sigInstance, abi.encodePacked("alice-sig"));
            vm.prank(bob);
            signature.actionSign(sigInstance, abi.encodePacked("bob-sig"));

            assertEq(signature.queryStatus(sigInstance), COMPLETE);
        }
    }

    /// @notice Fuzz test: instance isolation under random IDs
    function testFuzz_Handoff_InstanceIsolation(bytes32 regId, bytes32 sigId) public {
        vm.assume(regId != bytes32(0));
        vm.assume(sigId != bytes32(0));

        registry.intakeParty(regId, alice, SIGNER);
        registry.intakeReady(regId);

        address[] memory signers = registry.handoffPartiesInRole(regId, SIGNER);
        signature.intakeSigners(sigId, signers);
        signature.intakeDocumentHash(sigId, keccak256("doc"));

        // Different IDs should be unaffected
        bytes32 otherId = keccak256(abi.encode(regId, sigId));
        if (otherId != regId) {
            assertEq(registry.queryStatus(otherId), 0);
        }
        if (otherId != sigId) {
            assertEq(signature.queryStatus(otherId), 0);
        }
    }
}

/// @title Handoff Invariant Tests
/// @notice Invariant tests for PartyRegistry → Signature handoff
contract PartyRegistryToSignatureInvariantTest is Test {
    PartyRegistryClauseLogicV3 public registry;
    SignatureClauseLogicV3 public signature;
    HandoffHandler public handler;

    function setUp() public {
        registry = new PartyRegistryClauseLogicV3();
        signature = new SignatureClauseLogicV3();
        handler = new HandoffHandler(registry, signature);

        targetContract(address(handler));
    }

    /// @notice Invariant: Signer count is preserved through handoff
    function invariant_SignerCountPreserved() public view {
        bytes32[] memory completedInstances = handler.getCompletedInstances();

        for (uint256 i = 0; i < completedInstances.length; i++) {
            bytes32 instance = completedInstances[i];
            uint256 registryCount = handler.getRegistrySignerCount(instance);
            uint256 signatureCount = handler.getSignatureSignerCount(instance);

            assertEq(registryCount, signatureCount, "Signer count mismatch");
        }
    }

    /// @notice Invariant: All handoffs maintain address integrity
    function invariant_AddressIntegrity() public view {
        bytes32[] memory completedInstances = handler.getCompletedInstances();

        for (uint256 i = 0; i < completedInstances.length; i++) {
            bytes32 instance = completedInstances[i];
            address[] memory regSigners = handler.getRegistrySigners(instance);
            address[] memory sigSigners = handler.getSignatureSigners(instance);

            assertEq(regSigners.length, sigSigners.length, "Length mismatch");

            for (uint256 j = 0; j < regSigners.length; j++) {
                assertEq(regSigners[j], sigSigners[j], "Address mismatch");
            }
        }
    }

    /// @notice Invariant: Completed signatures have all required signers signed
    function invariant_CompletedSignaturesFullySigned() public view {
        bytes32[] memory signedInstances = handler.getSignedInstances();
        uint16 COMPLETE = 1 << 2;

        for (uint256 i = 0; i < signedInstances.length; i++) {
            bytes32 instance = signedInstances[i];

            if (signature.queryStatus(instance) == COMPLETE) {
                address[] memory signers = signature.querySigners(instance);
                for (uint256 j = 0; j < signers.length; j++) {
                    assertTrue(signature.queryHasSigned(instance, signers[j]), "Incomplete signature in COMPLETE state");
                }
            }
        }
    }

    /// @notice Invariant: Instance states are always valid
    function invariant_ValidStates() public view {
        bytes32[] memory allInstances = handler.getAllInstances();

        uint16 ACTIVE = 1 << 1;
        uint16 PENDING = 1 << 1;
        uint16 COMPLETE = 1 << 2;
        uint16 CANCELLED = 1 << 3;

        for (uint256 i = 0; i < allInstances.length; i++) {
            bytes32 instance = allInstances[i];

            uint16 regStatus = registry.queryStatus(instance);
            uint16 sigStatus = signature.queryStatus(instance);

            // Registry can be 0 (uninitialized) or ACTIVE
            assertTrue(regStatus == 0 || regStatus == ACTIVE, "Invalid registry state");

            // Signature can be 0, PENDING, COMPLETE, or CANCELLED
            assertTrue(
                sigStatus == 0 || sigStatus == PENDING || sigStatus == COMPLETE || sigStatus == CANCELLED,
                "Invalid signature state"
            );
        }
    }
}

/// @title Handler contract for invariant testing
/// @notice Manages state for invariant tests
contract HandoffHandler is Test {
    PartyRegistryClauseLogicV3 public registry;
    SignatureClauseLogicV3 public signature;

    bytes32[] public allInstances;
    bytes32[] public completedInstances; // Handoff completed
    bytes32[] public signedInstances; // Signing completed

    mapping(bytes32 => address[]) public registrySigners;
    mapping(bytes32 => address[]) public signatureSigners;
    mapping(bytes32 => bool) public instanceExists;

    uint256 public instanceCounter;

    bytes32 constant SIGNER = keccak256("SIGNER");

    constructor(PartyRegistryClauseLogicV3 _registry, SignatureClauseLogicV3 _signature) {
        registry = _registry;
        signature = _signature;
    }

    /// @notice Create a new handoff from registry to signature
    function createHandoff(uint8 signerCount) public {
        if (signerCount == 0 || signerCount > 10) return;

        bytes32 instance = bytes32(instanceCounter++);

        // Create signers in registry
        address[] memory signers = new address[](signerCount);
        for (uint256 i = 0; i < signerCount; i++) {
            signers[i] = address(uint160(uint256(instance) + i + 1));
            registry.intakeParty(instance, signers[i], SIGNER);
        }
        registry.intakeReady(instance);

        // Store for invariant checks
        registrySigners[instance] = signers;

        // Handoff
        address[] memory handedOff = registry.handoffPartiesInRole(instance, SIGNER);
        signature.intakeSigners(instance, handedOff);
        signature.intakeDocumentHash(instance, keccak256(abi.encode(instance)));

        signatureSigners[instance] = handedOff;
        instanceExists[instance] = true;
        allInstances.push(instance);
        completedInstances.push(instance);
    }

    /// @notice Sign for a random instance
    function signRandom(uint256 instanceIndex, uint256 signerIndex) public {
        if (completedInstances.length == 0) return;

        instanceIndex = instanceIndex % completedInstances.length;
        bytes32 instance = completedInstances[instanceIndex];

        address[] memory signers = signatureSigners[instance];
        if (signers.length == 0) return;

        signerIndex = signerIndex % signers.length;
        address signer = signers[signerIndex];

        uint16 status = signature.queryStatus(instance);
        uint16 PENDING = 1 << 1;

        if (status == PENDING && !signature.queryHasSigned(instance, signer)) {
            vm.prank(signer);
            signature.actionSign(instance, abi.encodePacked("sig"));

            uint16 COMPLETE = 1 << 2;
            if (signature.queryStatus(instance) == COMPLETE) {
                signedInstances.push(instance);
            }
        }
    }

    // Getters for invariant tests
    function getAllInstances() external view returns (bytes32[] memory) {
        return allInstances;
    }

    function getCompletedInstances() external view returns (bytes32[] memory) {
        return completedInstances;
    }

    function getSignedInstances() external view returns (bytes32[] memory) {
        return signedInstances;
    }

    function getRegistrySignerCount(bytes32 instance) external view returns (uint256) {
        return registrySigners[instance].length;
    }

    function getSignatureSignerCount(bytes32 instance) external view returns (uint256) {
        return signatureSigners[instance].length;
    }

    function getRegistrySigners(bytes32 instance) external view returns (address[] memory) {
        return registrySigners[instance];
    }

    function getSignatureSigners(bytes32 instance) external view returns (address[] memory) {
        return signatureSigners[instance];
    }
}
