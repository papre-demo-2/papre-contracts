// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {DeclarativeClauseLogicV3} from "../../src/clauses/content/DeclarativeClauseLogicV3.sol";
import {SignatureClauseLogicV3} from "../../src/clauses/attestation/SignatureClauseLogicV3.sol";
import {PartyRegistryClauseLogicV3} from "../../src/clauses/access/PartyRegistryClauseLogicV3.sol";

/// @title Declarative → Signature Handoff Integration Tests
/// @notice Tests handoff patterns from DeclarativeClauseLogicV3 to SignatureClauseLogicV3
/// @dev The primary handoff: handoffContentHash() → intakeDocumentHash()
contract DeclarativeToSignatureHandoffTest is Test {

    DeclarativeClauseLogicV3 public declarative;
    SignatureClauseLogicV3 public signature;
    PartyRegistryClauseLogicV3 public registry;

    // Test accounts
    address alice;
    address bob;
    address charlie;

    // Instance IDs
    bytes32 constant DECLARATIVE_INSTANCE = bytes32(uint256(1));
    bytes32 constant SIGNATURE_INSTANCE = bytes32(uint256(2));
    bytes32 constant REGISTRY_INSTANCE = bytes32(uint256(3));

    // Role constant
    bytes32 constant SIGNER = keccak256("SIGNER");

    // State constants
    uint16 constant REGISTERED = 1 << 1;  // 0x0002 - Declarative
    uint16 constant SEALED     = 1 << 2;  // 0x0004 - Declarative
    uint16 constant PENDING    = 1 << 1;  // 0x0002 - Signature
    uint16 constant COMPLETE   = 1 << 2;  // 0x0004 - Signature
    uint16 constant ACTIVE     = 1 << 1;  // 0x0002 - Registry

    // Test content
    bytes32 constant CONTENT_HASH = keccak256("test-document-content");
    string constant CONTENT_URI = "ipfs://QmTestDocument123";

    function setUp() public {
        declarative = new DeclarativeClauseLogicV3();
        signature = new SignatureClauseLogicV3();
        registry = new PartyRegistryClauseLogicV3();

        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");
    }

    // =============================================================
    // BASIC HANDOFF PATTERNS
    // =============================================================

    /// @notice Basic handoff: register content, then sign it
    function test_Handoff_BasicContentToSignature() public {
        // Register content
        vm.prank(alice);
        declarative.intakeContent(DECLARATIVE_INSTANCE, CONTENT_HASH, CONTENT_URI);

        // Handoff content hash to signature clause
        bytes32 docHash = declarative.handoffContentHash(DECLARATIVE_INSTANCE);

        // Setup signers
        address[] memory signers = new address[](1);
        signers[0] = alice;
        signature.intakeSigners(SIGNATURE_INSTANCE, signers);
        signature.intakeDocumentHash(SIGNATURE_INSTANCE, docHash);

        // Verify handoff worked
        assertEq(signature.queryStatus(SIGNATURE_INSTANCE), PENDING);

        // Complete signing
        vm.prank(alice);
        signature.actionSign(SIGNATURE_INSTANCE, abi.encodePacked("alice-sig"));
        assertEq(signature.queryStatus(SIGNATURE_INSTANCE), COMPLETE);

        // Verify document hash matches through the chain
        assertEq(signature.handoffDocumentHash(SIGNATURE_INSTANCE), CONTENT_HASH);
    }

    /// @notice Handoff from sealed content (immutable)
    function test_Handoff_SealedContentToSignature() public {
        // Register and seal content
        vm.startPrank(alice);
        declarative.intakeContent(DECLARATIVE_INSTANCE, CONTENT_HASH, CONTENT_URI);
        declarative.actionSeal(DECLARATIVE_INSTANCE);
        vm.stopPrank();

        assertTrue(declarative.queryIsSealed(DECLARATIVE_INSTANCE));

        // Handoff still works after sealing
        bytes32 docHash = declarative.handoffContentHash(DECLARATIVE_INSTANCE);
        assertEq(docHash, CONTENT_HASH);

        // Setup and complete signing
        address[] memory signers = new address[](2);
        signers[0] = alice;
        signers[1] = bob;
        signature.intakeSigners(SIGNATURE_INSTANCE, signers);
        signature.intakeDocumentHash(SIGNATURE_INSTANCE, docHash);

        vm.prank(alice);
        signature.actionSign(SIGNATURE_INSTANCE, abi.encodePacked("alice-sig"));
        vm.prank(bob);
        signature.actionSign(SIGNATURE_INSTANCE, abi.encodePacked("bob-sig"));

        assertEq(signature.queryStatus(SIGNATURE_INSTANCE), COMPLETE);
    }

    /// @notice Handoff fails from revoked content
    function test_Handoff_RevokedContentFails() public {
        // Register and revoke content
        vm.startPrank(alice);
        declarative.intakeContent(DECLARATIVE_INSTANCE, CONTENT_HASH, CONTENT_URI);
        declarative.actionRevoke(DECLARATIVE_INSTANCE);
        vm.stopPrank();

        assertTrue(declarative.queryIsRevoked(DECLARATIVE_INSTANCE));

        // Handoff should fail
        vm.expectRevert("Wrong state");
        declarative.handoffContentHash(DECLARATIVE_INSTANCE);
    }

    /// @notice Handoff fails from uninitialized content
    function test_Handoff_UninitializedContentFails() public {
        vm.expectRevert("Wrong state");
        declarative.handoffContentHash(DECLARATIVE_INSTANCE);
    }

    // =============================================================
    // FULL PIPELINE TESTS (Registry → Declarative → Signature)
    // =============================================================

    /// @notice Full pipeline: PartyRegistry → DeclarativeClause → SignatureClause
    function test_Handoff_FullPipeline_RegistryToDeclarativeToSignature() public {
        // Step 1: Setup party registry
        registry.intakeParty(REGISTRY_INSTANCE, alice, SIGNER);
        registry.intakeParty(REGISTRY_INSTANCE, bob, SIGNER);
        registry.intakeReady(REGISTRY_INSTANCE);

        // Step 2: Register content (by any party)
        vm.prank(alice);
        declarative.intakeContent(DECLARATIVE_INSTANCE, CONTENT_HASH, CONTENT_URI);

        // Step 3: Wire handoffs
        address[] memory signers = registry.handoffPartiesInRole(REGISTRY_INSTANCE, SIGNER);
        bytes32 docHash = declarative.handoffContentHash(DECLARATIVE_INSTANCE);

        signature.intakeSigners(SIGNATURE_INSTANCE, signers);
        signature.intakeDocumentHash(SIGNATURE_INSTANCE, docHash);

        // Step 4: All parties sign the registered content
        vm.prank(alice);
        signature.actionSign(SIGNATURE_INSTANCE, abi.encodePacked("alice-sig"));
        assertEq(signature.queryStatus(SIGNATURE_INSTANCE), PENDING);

        vm.prank(bob);
        signature.actionSign(SIGNATURE_INSTANCE, abi.encodePacked("bob-sig"));
        assertEq(signature.queryStatus(SIGNATURE_INSTANCE), COMPLETE);

        // Verify end-to-end data integrity
        assertEq(signature.handoffDocumentHash(SIGNATURE_INSTANCE), CONTENT_HASH);
        assertEq(signature.handoffSigners(SIGNATURE_INSTANCE).length, 2);
    }

    /// @notice Pipeline with content sealed before signing
    function test_Handoff_FullPipeline_SealThenSign() public {
        // Setup registry
        registry.intakeParty(REGISTRY_INSTANCE, alice, SIGNER);
        registry.intakeReady(REGISTRY_INSTANCE);

        // Register content
        vm.prank(alice);
        declarative.intakeContent(DECLARATIVE_INSTANCE, CONTENT_HASH, CONTENT_URI);

        // Seal before signing (makes content immutable)
        vm.prank(alice);
        declarative.actionSeal(DECLARATIVE_INSTANCE);

        // Wire handoffs
        address[] memory signers = registry.handoffPartiesInRole(REGISTRY_INSTANCE, SIGNER);
        bytes32 docHash = declarative.handoffContentHash(DECLARATIVE_INSTANCE);

        signature.intakeSigners(SIGNATURE_INSTANCE, signers);
        signature.intakeDocumentHash(SIGNATURE_INSTANCE, docHash);

        // Sign
        vm.prank(alice);
        signature.actionSign(SIGNATURE_INSTANCE, abi.encodePacked("alice-sig"));

        assertEq(signature.queryStatus(SIGNATURE_INSTANCE), COMPLETE);
    }

    // =============================================================
    // MULTIPLE INSTANCE PATTERNS
    // =============================================================

    /// @notice Same content, different signature instances
    function test_Handoff_OneContentToMultipleSignatures() public {
        bytes32 sigInstance1 = keccak256("signing-1");
        bytes32 sigInstance2 = keccak256("signing-2");

        // Register content once
        vm.prank(alice);
        declarative.intakeContent(DECLARATIVE_INSTANCE, CONTENT_HASH, CONTENT_URI);

        bytes32 docHash = declarative.handoffContentHash(DECLARATIVE_INSTANCE);

        // First signing instance (alice signs alone)
        address[] memory signers1 = new address[](1);
        signers1[0] = alice;
        signature.intakeSigners(sigInstance1, signers1);
        signature.intakeDocumentHash(sigInstance1, docHash);

        // Second signing instance (bob signs alone)
        address[] memory signers2 = new address[](1);
        signers2[0] = bob;
        signature.intakeSigners(sigInstance2, signers2);
        signature.intakeDocumentHash(sigInstance2, docHash);

        // Complete first
        vm.prank(alice);
        signature.actionSign(sigInstance1, abi.encodePacked("alice-sig"));
        assertEq(signature.queryStatus(sigInstance1), COMPLETE);
        assertEq(signature.queryStatus(sigInstance2), PENDING);

        // Complete second
        vm.prank(bob);
        signature.actionSign(sigInstance2, abi.encodePacked("bob-sig"));
        assertEq(signature.queryStatus(sigInstance2), COMPLETE);

        // Both signed same document
        assertEq(signature.handoffDocumentHash(sigInstance1), CONTENT_HASH);
        assertEq(signature.handoffDocumentHash(sigInstance2), CONTENT_HASH);
    }

    /// @notice Multiple contents, same signers
    function test_Handoff_MultipleContentsToSameSigners() public {
        bytes32 declInstance1 = keccak256("content-1");
        bytes32 declInstance2 = keccak256("content-2");
        bytes32 sigInstance1 = keccak256("signing-1");
        bytes32 sigInstance2 = keccak256("signing-2");

        bytes32 hash1 = keccak256("document-1");
        bytes32 hash2 = keccak256("document-2");

        // Register two different contents
        vm.prank(alice);
        declarative.intakeContent(declInstance1, hash1, "ipfs://doc1");
        vm.prank(alice);
        declarative.intakeContent(declInstance2, hash2, "ipfs://doc2");

        // Same signers for both
        address[] memory signers = new address[](2);
        signers[0] = alice;
        signers[1] = bob;

        // Wire first content to first signing
        signature.intakeSigners(sigInstance1, signers);
        signature.intakeDocumentHash(sigInstance1, declarative.handoffContentHash(declInstance1));

        // Wire second content to second signing
        signature.intakeSigners(sigInstance2, signers);
        signature.intakeDocumentHash(sigInstance2, declarative.handoffContentHash(declInstance2));

        // Sign both
        vm.startPrank(alice);
        signature.actionSign(sigInstance1, abi.encodePacked("sig1"));
        signature.actionSign(sigInstance2, abi.encodePacked("sig2"));
        vm.stopPrank();

        vm.startPrank(bob);
        signature.actionSign(sigInstance1, abi.encodePacked("sig1"));
        signature.actionSign(sigInstance2, abi.encodePacked("sig2"));
        vm.stopPrank();

        // Both complete with correct hashes
        assertEq(signature.queryStatus(sigInstance1), COMPLETE);
        assertEq(signature.queryStatus(sigInstance2), COMPLETE);
        assertEq(signature.handoffDocumentHash(sigInstance1), hash1);
        assertEq(signature.handoffDocumentHash(sigInstance2), hash2);
    }

    // =============================================================
    // CONTENT VERIFICATION INTEGRATION
    // =============================================================

    /// @notice Verify content before signing
    function test_Handoff_VerifyContentBeforeSigning() public {
        vm.prank(alice);
        declarative.intakeContent(DECLARATIVE_INSTANCE, CONTENT_HASH, CONTENT_URI);

        // Signers can verify content before signing
        assertTrue(declarative.queryVerifyContent(DECLARATIVE_INSTANCE, CONTENT_HASH));
        assertFalse(declarative.queryVerifyContent(DECLARATIVE_INSTANCE, keccak256("wrong")));

        // Proceed with signing
        bytes32 docHash = declarative.handoffContentHash(DECLARATIVE_INSTANCE);
        address[] memory signers = new address[](1);
        signers[0] = bob;
        signature.intakeSigners(SIGNATURE_INSTANCE, signers);
        signature.intakeDocumentHash(SIGNATURE_INSTANCE, docHash);

        // Bob verifies before signing
        assertTrue(declarative.queryVerifyContent(DECLARATIVE_INSTANCE, docHash));

        vm.prank(bob);
        signature.actionSign(SIGNATURE_INSTANCE, abi.encodePacked("bob-sig"));

        assertEq(signature.queryStatus(SIGNATURE_INSTANCE), COMPLETE);
    }

    /// @notice URI and registrant available for context
    function test_Handoff_AdditionalContextAvailable() public {
        vm.prank(alice);
        declarative.intakeContent(DECLARATIVE_INSTANCE, CONTENT_HASH, CONTENT_URI);

        // Before signing, signers can query context
        string memory uri = declarative.handoffContentUri(DECLARATIVE_INSTANCE);
        address registrant = declarative.handoffRegistrant(DECLARATIVE_INSTANCE);

        assertEq(uri, CONTENT_URI);
        assertEq(registrant, alice);

        // This context helps signers verify what they're signing
    }

    // =============================================================
    // STATE SEQUENCE TESTS
    // =============================================================

    /// @notice Content stays in REGISTERED during signing
    function test_Handoff_ContentStatePreserved() public {
        vm.prank(alice);
        declarative.intakeContent(DECLARATIVE_INSTANCE, CONTENT_HASH, CONTENT_URI);

        assertEq(declarative.queryStatus(DECLARATIVE_INSTANCE), REGISTERED);

        // Setup signing
        address[] memory signers = new address[](1);
        signers[0] = alice;
        signature.intakeSigners(SIGNATURE_INSTANCE, signers);
        signature.intakeDocumentHash(SIGNATURE_INSTANCE, declarative.handoffContentHash(DECLARATIVE_INSTANCE));

        // Content still REGISTERED
        assertEq(declarative.queryStatus(DECLARATIVE_INSTANCE), REGISTERED);

        // Complete signing
        vm.prank(alice);
        signature.actionSign(SIGNATURE_INSTANCE, abi.encodePacked("sig"));

        // Content still REGISTERED (signing doesn't affect declarative state)
        assertEq(declarative.queryStatus(DECLARATIVE_INSTANCE), REGISTERED);
        assertEq(signature.queryStatus(SIGNATURE_INSTANCE), COMPLETE);
    }

    /// @notice Can seal content after signing starts
    function test_Handoff_SealAfterSigningStarts() public {
        vm.prank(alice);
        declarative.intakeContent(DECLARATIVE_INSTANCE, CONTENT_HASH, CONTENT_URI);

        // Start signing
        address[] memory signers = new address[](2);
        signers[0] = alice;
        signers[1] = bob;
        signature.intakeSigners(SIGNATURE_INSTANCE, signers);
        signature.intakeDocumentHash(SIGNATURE_INSTANCE, declarative.handoffContentHash(DECLARATIVE_INSTANCE));

        vm.prank(alice);
        signature.actionSign(SIGNATURE_INSTANCE, abi.encodePacked("alice-sig"));

        // Alice seals the content mid-signing
        vm.prank(alice);
        declarative.actionSeal(DECLARATIVE_INSTANCE);

        assertTrue(declarative.queryIsSealed(DECLARATIVE_INSTANCE));
        assertEq(signature.queryStatus(SIGNATURE_INSTANCE), PENDING);

        // Bob can still complete signing
        vm.prank(bob);
        signature.actionSign(SIGNATURE_INSTANCE, abi.encodePacked("bob-sig"));

        assertEq(signature.queryStatus(SIGNATURE_INSTANCE), COMPLETE);
    }

    /// @notice Cannot use revoked content for new signatures
    function test_Handoff_RevokeBlocksNewSignatures() public {
        vm.prank(alice);
        declarative.intakeContent(DECLARATIVE_INSTANCE, CONTENT_HASH, CONTENT_URI);

        // Start first signing
        bytes32 sigInstance1 = keccak256("sig-1");
        address[] memory signers = new address[](1);
        signers[0] = bob;
        signature.intakeSigners(sigInstance1, signers);
        signature.intakeDocumentHash(sigInstance1, declarative.handoffContentHash(DECLARATIVE_INSTANCE));

        // Revoke content
        vm.prank(alice);
        declarative.actionRevoke(DECLARATIVE_INSTANCE);

        // Can't create new signature instance from revoked content
        vm.expectRevert("Wrong state");
        declarative.handoffContentHash(DECLARATIVE_INSTANCE);

        // But existing signature can still complete
        vm.prank(bob);
        signature.actionSign(sigInstance1, abi.encodePacked("bob-sig"));
        assertEq(signature.queryStatus(sigInstance1), COMPLETE);
    }

    // =============================================================
    // FUZZ TESTS
    // =============================================================

    /// @notice Fuzz: any content hash works
    function testFuzz_Handoff_AnyContentHash(bytes32 contentHash) public {
        vm.assume(contentHash != bytes32(0));

        vm.prank(alice);
        declarative.intakeContent(DECLARATIVE_INSTANCE, contentHash, "");

        bytes32 handedOff = declarative.handoffContentHash(DECLARATIVE_INSTANCE);
        assertEq(handedOff, contentHash);

        // Use in signature
        address[] memory signers = new address[](1);
        signers[0] = alice;
        signature.intakeSigners(SIGNATURE_INSTANCE, signers);
        signature.intakeDocumentHash(SIGNATURE_INSTANCE, handedOff);

        vm.prank(alice);
        signature.actionSign(SIGNATURE_INSTANCE, abi.encodePacked("sig"));

        assertEq(signature.handoffDocumentHash(SIGNATURE_INSTANCE), contentHash);
    }

    /// @notice Fuzz: variable signer counts
    function testFuzz_Handoff_VariableSignerCount(uint8 signerCount) public {
        vm.assume(signerCount > 0 && signerCount <= 20);

        vm.prank(alice);
        declarative.intakeContent(DECLARATIVE_INSTANCE, CONTENT_HASH, CONTENT_URI);

        bytes32 docHash = declarative.handoffContentHash(DECLARATIVE_INSTANCE);

        // Create signers
        address[] memory signers = new address[](signerCount);
        for (uint256 i = 0; i < signerCount; i++) {
            signers[i] = address(uint160(i + 1));
        }

        signature.intakeSigners(SIGNATURE_INSTANCE, signers);
        signature.intakeDocumentHash(SIGNATURE_INSTANCE, docHash);

        // All sign
        for (uint256 i = 0; i < signerCount; i++) {
            vm.prank(signers[i]);
            signature.actionSign(SIGNATURE_INSTANCE, abi.encodePacked("sig"));
        }

        assertEq(signature.queryStatus(SIGNATURE_INSTANCE), COMPLETE);
        assertEq(signature.handoffDocumentHash(SIGNATURE_INSTANCE), CONTENT_HASH);
    }

    /// @notice Fuzz: instance isolation
    function testFuzz_Handoff_InstanceIsolation(bytes32 declId, bytes32 sigId) public {
        vm.assume(declId != bytes32(0));
        vm.assume(sigId != bytes32(0));

        bytes32 uniqueHash = keccak256(abi.encode(declId, sigId));

        vm.prank(alice);
        declarative.intakeContent(declId, uniqueHash, "");

        bytes32 docHash = declarative.handoffContentHash(declId);

        address[] memory signers = new address[](1);
        signers[0] = alice;
        signature.intakeSigners(sigId, signers);
        signature.intakeDocumentHash(sigId, docHash);

        vm.prank(alice);
        signature.actionSign(sigId, abi.encodePacked("sig"));

        assertEq(signature.queryStatus(sigId), COMPLETE);
        assertEq(signature.handoffDocumentHash(sigId), uniqueHash);

        // Other IDs unaffected
        bytes32 otherId = keccak256(abi.encode(declId, sigId, "other"));
        assertEq(declarative.queryStatus(otherId), 0);
        assertEq(signature.queryStatus(otherId), 0);
    }

    /// @notice Fuzz: multiple handoffs from same content
    function testFuzz_Handoff_MultipleFromSameContent(uint8 handoffCount) public {
        vm.assume(handoffCount > 0 && handoffCount <= 10);

        vm.prank(alice);
        declarative.intakeContent(DECLARATIVE_INSTANCE, CONTENT_HASH, CONTENT_URI);

        bytes32 docHash = declarative.handoffContentHash(DECLARATIVE_INSTANCE);

        for (uint256 i = 0; i < handoffCount; i++) {
            bytes32 sigInstance = keccak256(abi.encode("sig", i));

            address[] memory signers = new address[](1);
            signers[0] = address(uint160(i + 1));

            signature.intakeSigners(sigInstance, signers);
            signature.intakeDocumentHash(sigInstance, docHash);

            vm.prank(signers[0]);
            signature.actionSign(sigInstance, abi.encodePacked("sig"));

            assertEq(signature.queryStatus(sigInstance), COMPLETE);
            assertEq(signature.handoffDocumentHash(sigInstance), CONTENT_HASH);
        }
    }
}

/// @title Declarative → Signature Invariant Tests
contract DeclarativeToSignatureInvariantTest is Test {

    DeclarativeClauseLogicV3 public declarative;
    SignatureClauseLogicV3 public signature;
    DeclarativeSignatureHandler public handler;

    function setUp() public {
        declarative = new DeclarativeClauseLogicV3();
        signature = new SignatureClauseLogicV3();
        handler = new DeclarativeSignatureHandler(declarative, signature);

        targetContract(address(handler));
    }

    /// @notice Invariant: Content hash is preserved through handoff
    function invariant_ContentHashPreserved() public view {
        bytes32[] memory pairs = handler.getHandoffPairs();

        for (uint256 i = 0; i < pairs.length; i += 2) {
            bytes32 declInstance = pairs[i];
            bytes32 sigInstance = pairs[i + 1];

            bytes32 declHash = handler.getContentHash(declInstance);
            bytes32 sigHash = handler.getDocumentHash(sigInstance);

            assertEq(declHash, sigHash, "Content hash mismatch");
        }
    }

    /// @notice Invariant: Completed signatures have valid document hashes
    function invariant_CompletedSignaturesHaveValidHashes() public view {
        bytes32[] memory completed = handler.getCompletedSignatures();
        uint16 COMPLETE = 1 << 2;

        for (uint256 i = 0; i < completed.length; i++) {
            bytes32 instance = completed[i];

            if (signature.queryStatus(instance) == COMPLETE) {
                bytes32 docHash = signature.handoffDocumentHash(instance);
                assertTrue(docHash != bytes32(0), "Zero document hash in completed signature");
            }
        }
    }

    /// @notice Invariant: Declarative states are valid
    function invariant_DeclarativeStatesValid() public view {
        bytes32[] memory instances = handler.getDeclarativeInstances();

        uint16 REGISTERED = 1 << 1;
        uint16 SEALED = 1 << 2;
        uint16 REVOKED = 1 << 3;

        for (uint256 i = 0; i < instances.length; i++) {
            uint16 status = declarative.queryStatus(instances[i]);
            assertTrue(
                status == 0 || status == REGISTERED || status == SEALED || status == REVOKED,
                "Invalid declarative state"
            );
        }
    }
}

/// @title Handler for invariant testing
contract DeclarativeSignatureHandler is Test {

    DeclarativeClauseLogicV3 public declarative;
    SignatureClauseLogicV3 public signature;

    bytes32[] public handoffPairs;  // [decl1, sig1, decl2, sig2, ...]
    bytes32[] public declarativeInstances;
    bytes32[] public completedSignatures;

    mapping(bytes32 => bytes32) public contentHashes;
    mapping(bytes32 => bytes32) public documentHashes;

    uint256 public instanceCounter;

    constructor(DeclarativeClauseLogicV3 _declarative, SignatureClauseLogicV3 _signature) {
        declarative = _declarative;
        signature = _signature;
    }

    /// @notice Create content and wire to signature
    function createHandoff(bytes32 contentHash, uint8 signerCount) public {
        if (contentHash == bytes32(0)) return;
        if (signerCount == 0 || signerCount > 10) return;

        bytes32 declInstance = bytes32(instanceCounter++);
        bytes32 sigInstance = bytes32(instanceCounter++);

        // Register content
        declarative.intakeContent(declInstance, contentHash, "");
        declarativeInstances.push(declInstance);
        contentHashes[declInstance] = contentHash;

        // Handoff to signature
        bytes32 docHash = declarative.handoffContentHash(declInstance);

        address[] memory signers = new address[](signerCount);
        for (uint256 i = 0; i < signerCount; i++) {
            signers[i] = address(uint160(uint256(declInstance) + i + 1));
        }

        signature.intakeSigners(sigInstance, signers);
        signature.intakeDocumentHash(sigInstance, docHash);

        documentHashes[sigInstance] = docHash;
        handoffPairs.push(declInstance);
        handoffPairs.push(sigInstance);
    }

    /// @notice Sign for a random instance
    function signRandom(uint256 pairIndex, uint256 signerIndex) public {
        if (handoffPairs.length < 2) return;

        pairIndex = (pairIndex % (handoffPairs.length / 2)) * 2;
        bytes32 sigInstance = handoffPairs[pairIndex + 1];

        address[] memory signers = signature.querySigners(sigInstance);
        if (signers.length == 0) return;

        signerIndex = signerIndex % signers.length;
        address signer = signers[signerIndex];

        uint16 status = signature.queryStatus(sigInstance);
        uint16 PENDING = 1 << 1;

        if (status == PENDING && !signature.queryHasSigned(sigInstance, signer)) {
            vm.prank(signer);
            signature.actionSign(sigInstance, abi.encodePacked("sig"));

            uint16 COMPLETE = 1 << 2;
            if (signature.queryStatus(sigInstance) == COMPLETE) {
                completedSignatures.push(sigInstance);
            }
        }
    }

    /// @notice Seal a declarative instance (placeholder for invariant testing)
    function sealDeclarative(uint256 instanceIndex) public view {
        if (declarativeInstances.length == 0) return;

        instanceIndex = instanceIndex % declarativeInstances.length;
        bytes32 instance = declarativeInstances[instanceIndex];

        uint16 REGISTERED = 1 << 1;
        if (declarative.queryStatus(instance) == REGISTERED) {
            // Note: we'd need to track registrant to call this properly
            // For now, this just demonstrates the pattern
        }
    }

    // Getters
    function getHandoffPairs() external view returns (bytes32[] memory) {
        return handoffPairs;
    }

    function getDeclarativeInstances() external view returns (bytes32[] memory) {
        return declarativeInstances;
    }

    function getCompletedSignatures() external view returns (bytes32[] memory) {
        return completedSignatures;
    }

    function getContentHash(bytes32 instance) external view returns (bytes32) {
        return contentHashes[instance];
    }

    function getDocumentHash(bytes32 instance) external view returns (bytes32) {
        return documentHashes[instance];
    }
}
