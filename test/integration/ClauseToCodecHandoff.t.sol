// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {CrossChainCodec} from "../../src/libraries/CrossChainCodec.sol";
import {SignatureClauseLogicV3} from "../../src/clauses/attestation/SignatureClauseLogicV3.sol";
import {DeclarativeClauseLogicV3} from "../../src/clauses/content/DeclarativeClauseLogicV3.sol";
import {PartyRegistryClauseLogicV3} from "../../src/clauses/access/PartyRegistryClauseLogicV3.sol";

/// @title Clause to CrossChainCodec Handoff Tests
/// @notice Tests demonstrating how v3 clause outputs get encoded for cross-chain transport
/// @dev These patterns show the integration between clause handoffs and the codec library
contract ClauseToCodecHandoffTest is Test {
    SignatureClauseLogicV3 public signature;
    DeclarativeClauseLogicV3 public declarative;
    PartyRegistryClauseLogicV3 public registry;

    address alice;
    address bob;
    address charlie;

    // Instance IDs
    bytes32 constant SIG_INSTANCE = bytes32(uint256(1));
    bytes32 constant DECL_INSTANCE = bytes32(uint256(2));
    bytes32 constant REG_INSTANCE = bytes32(uint256(3));

    // Role
    bytes32 constant SIGNER = keccak256("SIGNER");

    // State constants
    uint16 constant PENDING = 1 << 1;
    uint16 constant COMPLETE = 1 << 2;
    uint16 constant REGISTERED = 1 << 1;
    uint16 constant SEALED = 1 << 2;
    uint16 constant ACTIVE = 1 << 1;

    function setUp() public {
        signature = new SignatureClauseLogicV3();
        declarative = new DeclarativeClauseLogicV3();
        registry = new PartyRegistryClauseLogicV3();

        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");
    }

    // =============================================================
    // SIGNATURE CLAUSE → CODEC
    // =============================================================

    /// @notice Pattern: SignatureClause completion → SignaturesComplete message
    function test_Pattern_SignatureComplete_ToCodec() public {
        // Setup: Register signers and document
        bytes32 docHash = keccak256("legal-agreement.pdf");
        address[] memory signers = new address[](2);
        signers[0] = alice;
        signers[1] = bob;

        signature.intakeSigners(SIG_INSTANCE, signers);
        signature.intakeDocumentHash(SIG_INSTANCE, docHash);

        // Action: Both signers sign
        vm.prank(alice);
        signature.actionSign(SIG_INSTANCE, abi.encodePacked("alice-signature"));
        vm.prank(bob);
        signature.actionSign(SIG_INSTANCE, abi.encodePacked("bob-signature"));

        // Verify: Clause is complete
        assertEq(signature.queryStatus(SIG_INSTANCE), COMPLETE);

        // Handoff: Get data from clause
        bytes32 handoffDocHash = signature.handoffDocumentHash(SIG_INSTANCE);
        address[] memory handoffSigners = signature.handoffSigners(SIG_INSTANCE);

        // Encode: Create cross-chain message
        bytes memory payload = CrossChainCodec.encodeSignaturesComplete(handoffDocHash, handoffSigners);

        // Verify: Message can be decoded correctly
        (bytes32 decodedHash, address[] memory decodedSigners) = CrossChainCodec.decodeSignaturesComplete(payload);

        assertEq(decodedHash, docHash);
        assertEq(decodedSigners.length, 2);
        assertEq(decodedSigners[0], alice);
        assertEq(decodedSigners[1], bob);

        // Schema verification
        assertTrue(CrossChainCodec.isSchema(payload, CrossChainCodec.SIGNATURES_COMPLETE_V1));
    }

    // =============================================================
    // DECLARATIVE CLAUSE → CODEC
    // =============================================================

    /// @notice Pattern: DeclarativeClause sealed → ContentSealed message
    function test_Pattern_ContentSealed_ToCodec() public {
        // Setup: Register and seal content
        bytes32 contentHash = keccak256("important-document-content");
        string memory uri = "ipfs://QmContentHash123";

        vm.prank(alice);
        declarative.intakeContent(DECL_INSTANCE, contentHash, uri);

        vm.prank(alice);
        declarative.actionSeal(DECL_INSTANCE);

        // Verify: Content is sealed
        assertTrue(declarative.queryIsSealed(DECL_INSTANCE));

        // Handoff: Get data from clause
        bytes32 handoffHash = declarative.handoffContentHash(DECL_INSTANCE);
        string memory handoffUri = declarative.handoffContentUri(DECL_INSTANCE);
        address handoffRegistrant = declarative.handoffRegistrant(DECL_INSTANCE);

        // Encode: Create cross-chain message
        bytes memory payload = CrossChainCodec.encodeContentSealed(handoffHash, handoffUri, handoffRegistrant);

        // Verify: Message can be decoded correctly
        (bytes32 decodedHash, string memory decodedUri, address decodedRegistrant) =
            CrossChainCodec.decodeContentSealed(payload);

        assertEq(decodedHash, contentHash);
        assertEq(decodedUri, uri);
        assertEq(decodedRegistrant, alice);

        // Schema verification
        assertTrue(CrossChainCodec.isSchema(payload, CrossChainCodec.CONTENT_SEALED_V1));
    }

    /// @notice Pattern: DeclarativeClause registered (not sealed) → ContentRegistered message
    function test_Pattern_ContentRegistered_ToCodec() public {
        // Setup: Register content (don't seal)
        bytes32 contentHash = keccak256("draft-document");
        string memory uri = "ar://ArweaveDraft123";

        vm.prank(bob);
        declarative.intakeContent(DECL_INSTANCE, contentHash, uri);

        // Verify: Content is registered but not sealed
        assertEq(declarative.queryStatus(DECL_INSTANCE), REGISTERED);
        assertFalse(declarative.queryIsSealed(DECL_INSTANCE));

        // Handoff: Get data from clause
        bytes32 handoffHash = declarative.handoffContentHash(DECL_INSTANCE);
        string memory handoffUri = declarative.handoffContentUri(DECL_INSTANCE);
        address handoffRegistrant = declarative.handoffRegistrant(DECL_INSTANCE);

        // Encode: Create cross-chain message for registered (not sealed) content
        bytes memory payload = CrossChainCodec.encodeContentRegistered(handoffHash, handoffUri, handoffRegistrant);

        // Verify: Message can be decoded correctly
        (bytes32 decodedHash, string memory decodedUri, address decodedRegistrant) =
            CrossChainCodec.decodeContentRegistered(payload);

        assertEq(decodedHash, contentHash);
        assertEq(decodedUri, uri);
        assertEq(decodedRegistrant, bob);
    }

    // =============================================================
    // PARTY REGISTRY CLAUSE → CODEC
    // =============================================================

    /// @notice Pattern: PartyRegistryClause → PartiesRegistered message
    function test_Pattern_PartiesRegistered_ToCodec() public {
        // Setup: Register parties with SIGNER role
        registry.intakeParty(REG_INSTANCE, alice, SIGNER);
        registry.intakeParty(REG_INSTANCE, bob, SIGNER);
        registry.intakeParty(REG_INSTANCE, charlie, SIGNER);
        registry.intakeReady(REG_INSTANCE);

        // Verify: Registry is active
        assertEq(registry.queryStatus(REG_INSTANCE), ACTIVE);

        // Handoff: Get parties with SIGNER role
        address[] memory signerParties = registry.handoffPartiesInRole(REG_INSTANCE, SIGNER);

        // Encode: Create cross-chain message
        bytes memory payload = CrossChainCodec.encodePartiesRegistered(SIGNER, signerParties);

        // Verify: Message can be decoded correctly
        (bytes32 decodedRole, address[] memory decodedParties) = CrossChainCodec.decodePartiesRegistered(payload);

        assertEq(decodedRole, SIGNER);
        assertEq(decodedParties.length, 3);
        assertEq(decodedParties[0], alice);
        assertEq(decodedParties[1], bob);
        assertEq(decodedParties[2], charlie);
    }

    // =============================================================
    // FULL PIPELINE TESTS
    // =============================================================

    /// @notice Full pipeline: Registry → Declarative → Signature → Codec
    function test_FullPipeline_ToSignaturesComplete() public {
        // Step 1: Set up party registry
        registry.intakeParty(REG_INSTANCE, alice, SIGNER);
        registry.intakeParty(REG_INSTANCE, bob, SIGNER);
        registry.intakeReady(REG_INSTANCE);

        // Step 2: Register and seal content
        bytes32 contentHash = keccak256("agreement-v1.0");
        vm.prank(alice);
        declarative.intakeContent(DECL_INSTANCE, contentHash, "ipfs://QmAgreement");
        vm.prank(alice);
        declarative.actionSeal(DECL_INSTANCE);

        // Step 3: Wire handoffs for signature
        address[] memory signers = registry.handoffPartiesInRole(REG_INSTANCE, SIGNER);
        bytes32 docHash = declarative.handoffContentHash(DECL_INSTANCE);

        signature.intakeSigners(SIG_INSTANCE, signers);
        signature.intakeDocumentHash(SIG_INSTANCE, docHash);

        // Step 4: All parties sign
        vm.prank(alice);
        signature.actionSign(SIG_INSTANCE, abi.encodePacked("alice-sig"));
        vm.prank(bob);
        signature.actionSign(SIG_INSTANCE, abi.encodePacked("bob-sig"));

        // Step 5: Create cross-chain message from completed signature
        assertEq(signature.queryStatus(SIG_INSTANCE), COMPLETE);

        bytes32 finalDocHash = signature.handoffDocumentHash(SIG_INSTANCE);
        address[] memory finalSigners = signature.handoffSigners(SIG_INSTANCE);

        bytes memory payload = CrossChainCodec.encodeSignaturesComplete(finalDocHash, finalSigners);

        // Verify: Full pipeline data integrity
        (bytes32 decodedHash, address[] memory decodedSigners) = CrossChainCodec.decodeSignaturesComplete(payload);

        assertEq(decodedHash, contentHash); // Original content hash preserved
        assertEq(decodedSigners.length, 2);
        assertEq(decodedSigners[0], alice);
        assertEq(decodedSigners[1], bob);
    }

    /// @notice Multiple clauses → Multiple messages pattern
    function test_MultipleClauseOutputs_ToMultipleMessages() public {
        // Setup all clauses
        bytes32 contentHash = keccak256("multi-clause-test");

        // Registry
        registry.intakeParty(REG_INSTANCE, alice, SIGNER);
        registry.intakeReady(REG_INSTANCE);

        // Declarative
        vm.prank(alice);
        declarative.intakeContent(DECL_INSTANCE, contentHash, "ipfs://test");
        vm.prank(alice);
        declarative.actionSeal(DECL_INSTANCE);

        // Signature
        address[] memory signers = registry.handoffPartiesInRole(REG_INSTANCE, SIGNER);
        signature.intakeSigners(SIG_INSTANCE, signers);
        signature.intakeDocumentHash(SIG_INSTANCE, contentHash);
        vm.prank(alice);
        signature.actionSign(SIG_INSTANCE, abi.encodePacked("sig"));

        // Create multiple cross-chain messages
        bytes memory partiesMsg =
            CrossChainCodec.encodePartiesRegistered(SIGNER, registry.handoffPartiesInRole(REG_INSTANCE, SIGNER));

        bytes memory contentMsg = CrossChainCodec.encodeContentSealed(
            declarative.handoffContentHash(DECL_INSTANCE),
            declarative.handoffContentUri(DECL_INSTANCE),
            declarative.handoffRegistrant(DECL_INSTANCE)
        );

        bytes memory signaturesMsg = CrossChainCodec.encodeSignaturesComplete(
            signature.handoffDocumentHash(SIG_INSTANCE), signature.handoffSigners(SIG_INSTANCE)
        );

        // Verify all messages have correct schemas
        assertTrue(CrossChainCodec.isSchema(partiesMsg, CrossChainCodec.PARTIES_REGISTERED_V1));
        assertTrue(CrossChainCodec.isSchema(contentMsg, CrossChainCodec.CONTENT_SEALED_V1));
        assertTrue(CrossChainCodec.isSchema(signaturesMsg, CrossChainCodec.SIGNATURES_COMPLETE_V1));

        // All three could be sent cross-chain as separate messages or combined
    }

    // =============================================================
    // FUZZ TESTS
    // =============================================================

    function testFuzz_SignatureHandoff_ToCodec(bytes32 docHash, uint8 signerCount) public {
        vm.assume(signerCount > 0 && signerCount <= 10);
        vm.assume(docHash != bytes32(0));

        bytes32 instanceId = keccak256(abi.encode("fuzz-sig", docHash, signerCount));

        // Setup signers
        address[] memory signers = new address[](signerCount);
        for (uint256 i = 0; i < signerCount; i++) {
            signers[i] = address(uint160(i + 1));
        }

        signature.intakeSigners(instanceId, signers);
        signature.intakeDocumentHash(instanceId, docHash);

        // All sign
        for (uint256 i = 0; i < signerCount; i++) {
            vm.prank(signers[i]);
            signature.actionSign(instanceId, abi.encodePacked("sig", i));
        }

        // Handoff and encode
        bytes memory payload = CrossChainCodec.encodeSignaturesComplete(
            signature.handoffDocumentHash(instanceId), signature.handoffSigners(instanceId)
        );

        // Verify roundtrip
        (bytes32 decodedHash, address[] memory decodedSigners) = CrossChainCodec.decodeSignaturesComplete(payload);

        assertEq(decodedHash, docHash);
        assertEq(decodedSigners.length, signerCount);
    }

    function testFuzz_DeclarativeHandoff_ToCodec(bytes32 contentHash, string calldata uri, address registrant) public {
        vm.assume(contentHash != bytes32(0));
        vm.assume(registrant != address(0));

        bytes32 instanceId = keccak256(abi.encode("fuzz-decl", contentHash));

        vm.prank(registrant);
        declarative.intakeContent(instanceId, contentHash, uri);

        vm.prank(registrant);
        declarative.actionSeal(instanceId);

        // Handoff and encode
        bytes memory payload = CrossChainCodec.encodeContentSealed(
            declarative.handoffContentHash(instanceId),
            declarative.handoffContentUri(instanceId),
            declarative.handoffRegistrant(instanceId)
        );

        // Verify roundtrip
        (bytes32 decodedHash, string memory decodedUri, address decodedRegistrant) =
            CrossChainCodec.decodeContentSealed(payload);

        assertEq(decodedHash, contentHash);
        assertEq(decodedUri, uri);
        assertEq(decodedRegistrant, registrant);
    }

    function testFuzz_PartyRegistryHandoff_ToCodec(bytes32 role, uint8 partyCount) public {
        vm.assume(role != bytes32(0));
        vm.assume(partyCount > 0 && partyCount <= 10);

        bytes32 instanceId = keccak256(abi.encode("fuzz-reg", role, partyCount));

        // Register parties
        for (uint256 i = 0; i < partyCount; i++) {
            registry.intakeParty(instanceId, address(uint160(i + 100)), role);
        }
        registry.intakeReady(instanceId);

        // Handoff and encode
        address[] memory parties = registry.handoffPartiesInRole(instanceId, role);

        bytes memory payload = CrossChainCodec.encodePartiesRegistered(role, parties);

        // Verify roundtrip
        (bytes32 decodedRole, address[] memory decodedParties) = CrossChainCodec.decodePartiesRegistered(payload);

        assertEq(decodedRole, role);
        assertEq(decodedParties.length, partyCount);
    }
}

/// @title Clause to Codec Invariant Tests
contract ClauseToCodecInvariantTest is Test {
    ClauseCodecHandler public handler;

    function setUp() public {
        handler = new ClauseCodecHandler();
        targetContract(address(handler));
    }

    /// @notice Invariant: All generated payloads have valid schema IDs
    function invariant_AllPayloadsHaveValidSchemas() public view {
        bytes[] memory payloads = handler.getGeneratedPayloads();

        for (uint256 i = 0; i < payloads.length; i++) {
            bytes32 schemaId = CrossChainCodec.getSchemaId(payloads[i]);
            assertTrue(schemaId != bytes32(0), "Schema ID should not be zero");
        }
    }

    /// @notice Invariant: Completed signatures produce valid payloads
    function invariant_CompletedSignaturesProduceValidPayloads() public view {
        bytes[] memory sigPayloads = handler.getSignaturePayloads();

        for (uint256 i = 0; i < sigPayloads.length; i++) {
            assertTrue(
                CrossChainCodec.isSchema(sigPayloads[i], CrossChainCodec.SIGNATURES_COMPLETE_V1),
                "Signature payload should have correct schema"
            );

            // Should be decodable without revert
            CrossChainCodec.decodeSignaturesComplete(sigPayloads[i]);
        }
    }
}

/// @title Handler for invariant testing
contract ClauseCodecHandler is Test {
    SignatureClauseLogicV3 public signature;
    DeclarativeClauseLogicV3 public declarative;

    bytes[] public generatedPayloads;
    bytes[] public signaturePayloads;

    uint256 public counter;

    constructor() {
        signature = new SignatureClauseLogicV3();
        declarative = new DeclarativeClauseLogicV3();
    }

    function createAndEncodeSignature(uint8 signerCount) public {
        if (signerCount == 0 || signerCount > 5) return;

        bytes32 instanceId = bytes32(counter++);
        bytes32 docHash = keccak256(abi.encode("doc", instanceId));

        address[] memory signers = new address[](signerCount);
        for (uint256 i = 0; i < signerCount; i++) {
            signers[i] = address(uint160(uint256(instanceId) + i + 1));
        }

        signature.intakeSigners(instanceId, signers);
        signature.intakeDocumentHash(instanceId, docHash);

        // All sign
        for (uint256 i = 0; i < signerCount; i++) {
            vm.prank(signers[i]);
            signature.actionSign(instanceId, abi.encodePacked("sig"));
        }

        // Encode
        bytes memory payload = CrossChainCodec.encodeSignaturesComplete(
            signature.handoffDocumentHash(instanceId), signature.handoffSigners(instanceId)
        );

        generatedPayloads.push(payload);
        signaturePayloads.push(payload);
    }

    function createAndEncodeContent(bytes32 contentHash) public {
        if (contentHash == bytes32(0)) return;

        bytes32 instanceId = bytes32(counter++);
        address registrant = address(uint160(uint256(instanceId) + 1000));

        vm.prank(registrant);
        declarative.intakeContent(instanceId, contentHash, "ipfs://test");

        vm.prank(registrant);
        declarative.actionSeal(instanceId);

        bytes memory payload = CrossChainCodec.encodeContentSealed(
            declarative.handoffContentHash(instanceId),
            declarative.handoffContentUri(instanceId),
            declarative.handoffRegistrant(instanceId)
        );

        generatedPayloads.push(payload);
    }

    function getGeneratedPayloads() external view returns (bytes[] memory) {
        return generatedPayloads;
    }

    function getSignaturePayloads() external view returns (bytes[] memory) {
        return signaturePayloads;
    }
}
