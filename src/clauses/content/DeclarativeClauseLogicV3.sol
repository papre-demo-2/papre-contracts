// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ClauseBase} from "../../base/ClauseBase.sol";

/// @title DeclarativeClauseLogicV3
/// @notice Self-describing content anchoring clause following v3 specification
/// @dev Logic contract executed via delegatecall from Agreement proxies.
///      Anchors off-chain content (documents, images, data) to on-chain agreements
///      through cryptographic hashes and optional URIs.
///
///      Key features:
///      - Content hash registration (keccak256, IPFS CID, etc.)
///      - URI storage (ipfs://, ar://, https://)
///      - Sealing (make immutable)
///      - Revocation (mark invalid)
///      - Content verification
///
///      State machine:
///      0 (uninitialized) → REGISTERED → SEALED (terminal, handoff available)
///                                    → REVOKED (terminal, dead end)
contract DeclarativeClauseLogicV3 is ClauseBase {

    // =============================================================
    // STATES (bitmask)
    // =============================================================

    // 0 = uninitialized (fresh storage)
    uint16 internal constant REGISTERED = 1 << 1;  // 0x0002 - content registered
    uint16 internal constant SEALED     = 1 << 2;  // 0x0004 - sealed, immutable
    uint16 internal constant REVOKED    = 1 << 3;  // 0x0008 - revoked, invalid

    // =============================================================
    // ERC-7201 NAMESPACED STORAGE
    // =============================================================

    /// @custom:storage-location erc7201:papre.clause.declarative.storage
    struct DeclarativeStorage {
        /// @notice instanceId => clause state
        mapping(bytes32 => uint16) status;
        /// @notice instanceId => content hash (keccak256, IPFS CID digest, etc.)
        mapping(bytes32 => bytes32) contentHash;
        /// @notice instanceId => content URI (ipfs://, ar://, https://)
        mapping(bytes32 => string) contentUri;
        /// @notice instanceId => who registered the content
        mapping(bytes32 => address) registrant;
        /// @notice instanceId => when content was registered
        mapping(bytes32 => uint256) registeredAt;
        /// @notice instanceId => when content was sealed
        mapping(bytes32 => uint256) sealedAt;
    }

    // keccak256(abi.encode(uint256(keccak256("papre.clause.declarative.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT =
        0xcad4214cf727a181b2b5e7d17ad0f0fe8546d67a711bce09636dd570c35e8c00;

    function _getStorage() internal pure returns (DeclarativeStorage storage $) {
        assembly {
            $.slot := STORAGE_SLOT
        }
    }

    // =============================================================
    // INTAKE (from previous clause / setup)
    // =============================================================

    /// @notice Register content with hash and URI, transition to REGISTERED
    /// @param instanceId Unique identifier for this content instance
    /// @param contentHash The content's cryptographic hash (keccak256, IPFS CID digest)
    /// @param contentUri The content's URI (ipfs://, ar://, https://, or empty)
    function intakeContent(
        bytes32 instanceId,
        bytes32 contentHash,
        string calldata contentUri
    ) external {
        DeclarativeStorage storage $ = _getStorage();
        // Status 0 = fresh storage (uninitialized)
        require($.status[instanceId] == 0, "Wrong state");
        require(contentHash != bytes32(0), "Invalid content hash");

        $.contentHash[instanceId] = contentHash;
        $.contentUri[instanceId] = contentUri;
        $.registrant[instanceId] = msg.sender;
        $.registeredAt[instanceId] = block.timestamp;
        $.status[instanceId] = REGISTERED;
    }

    /// @notice Register content with hash only (no URI), transition to REGISTERED
    /// @param instanceId Unique identifier for this content instance
    /// @param contentHash The content's cryptographic hash
    function intakeContentHash(bytes32 instanceId, bytes32 contentHash) external {
        DeclarativeStorage storage $ = _getStorage();
        // Status 0 = fresh storage (uninitialized)
        require($.status[instanceId] == 0, "Wrong state");
        require(contentHash != bytes32(0), "Invalid content hash");

        $.contentHash[instanceId] = contentHash;
        $.registrant[instanceId] = msg.sender;
        $.registeredAt[instanceId] = block.timestamp;
        $.status[instanceId] = REGISTERED;
    }

    // =============================================================
    // ACTIONS (state-changing)
    // =============================================================

    /// @notice Seal the content, making it immutable
    /// @param instanceId Unique identifier for this content instance
    /// @dev Only the registrant can seal. Once sealed, content cannot be modified.
    /// @custom:papre-style primary
    function actionSeal(bytes32 instanceId) external {
        DeclarativeStorage storage $ = _getStorage();
        require($.status[instanceId] == REGISTERED, "Wrong state");
        require($.registrant[instanceId] == msg.sender, "Not registrant");

        $.sealedAt[instanceId] = block.timestamp;
        $.status[instanceId] = SEALED;
    }

    /// @notice Revoke the content declaration
    /// @param instanceId Unique identifier for this content instance
    /// @dev Only the registrant can revoke. Revoked content cannot be used.
    /// @custom:papre-style destructive
    function actionRevoke(bytes32 instanceId) external {
        DeclarativeStorage storage $ = _getStorage();
        require($.status[instanceId] == REGISTERED, "Wrong state");
        require($.registrant[instanceId] == msg.sender, "Not registrant");

        $.status[instanceId] = REVOKED;
    }

    // =============================================================
    // HANDOFF (to next clause)
    // =============================================================

    /// @notice Get the content hash for handoff to downstream clauses
    /// @param instanceId Unique identifier for this content instance
    /// @return The content hash
    /// @dev Available in REGISTERED or SEALED states (not REVOKED)
    function handoffContentHash(bytes32 instanceId) external view returns (bytes32) {
        DeclarativeStorage storage $ = _getStorage();
        uint16 status = $.status[instanceId];
        require((status & (REGISTERED | SEALED)) != 0, "Wrong state");
        return $.contentHash[instanceId];
    }

    /// @notice Get the content URI for handoff to downstream clauses
    /// @param instanceId Unique identifier for this content instance
    /// @return The content URI
    /// @dev Available in REGISTERED or SEALED states (not REVOKED)
    function handoffContentUri(bytes32 instanceId) external view returns (string memory) {
        DeclarativeStorage storage $ = _getStorage();
        uint16 status = $.status[instanceId];
        require((status & (REGISTERED | SEALED)) != 0, "Wrong state");
        return $.contentUri[instanceId];
    }

    /// @notice Get the registrant for handoff to downstream clauses
    /// @param instanceId Unique identifier for this content instance
    /// @return The address that registered the content
    /// @dev Available in REGISTERED or SEALED states (not REVOKED)
    function handoffRegistrant(bytes32 instanceId) external view returns (address) {
        DeclarativeStorage storage $ = _getStorage();
        uint16 status = $.status[instanceId];
        require((status & (REGISTERED | SEALED)) != 0, "Wrong state");
        return $.registrant[instanceId];
    }

    // =============================================================
    // QUERIES (always available)
    // =============================================================

    /// @notice Get the current state of an instance
    /// @param instanceId Unique identifier for this content instance
    /// @return Current state bitmask
    function queryStatus(bytes32 instanceId) external view returns (uint16) {
        return _getStorage().status[instanceId];
    }

    /// @notice Get the content hash
    /// @param instanceId Unique identifier for this content instance
    /// @return The content hash (bytes32(0) if uninitialized)
    function queryContentHash(bytes32 instanceId) external view returns (bytes32) {
        return _getStorage().contentHash[instanceId];
    }

    /// @notice Get the content URI
    /// @param instanceId Unique identifier for this content instance
    /// @return The content URI (empty string if not set)
    function queryContentUri(bytes32 instanceId) external view returns (string memory) {
        return _getStorage().contentUri[instanceId];
    }

    /// @notice Get the registrant address
    /// @param instanceId Unique identifier for this content instance
    /// @return The address that registered the content
    function queryRegistrant(bytes32 instanceId) external view returns (address) {
        return _getStorage().registrant[instanceId];
    }

    /// @notice Get the registration timestamp
    /// @param instanceId Unique identifier for this content instance
    /// @return Unix timestamp when content was registered
    function queryRegisteredAt(bytes32 instanceId) external view returns (uint256) {
        return _getStorage().registeredAt[instanceId];
    }

    /// @notice Get the sealed timestamp
    /// @param instanceId Unique identifier for this content instance
    /// @return Unix timestamp when content was sealed (0 if not sealed)
    function querySealedAt(bytes32 instanceId) external view returns (uint256) {
        return _getStorage().sealedAt[instanceId];
    }

    /// @notice Check if content is sealed
    /// @param instanceId Unique identifier for this content instance
    /// @return True if content is sealed
    function queryIsSealed(bytes32 instanceId) external view returns (bool) {
        return _getStorage().status[instanceId] == SEALED;
    }

    /// @notice Check if content is revoked
    /// @param instanceId Unique identifier for this content instance
    /// @return True if content is revoked
    function queryIsRevoked(bytes32 instanceId) external view returns (bool) {
        return _getStorage().status[instanceId] == REVOKED;
    }

    /// @notice Verify content hash matches stored hash
    /// @param instanceId Unique identifier for this content instance
    /// @param contentHash Hash to verify against stored hash
    /// @return True if hashes match
    function queryVerifyContent(bytes32 instanceId, bytes32 contentHash) external view returns (bool) {
        DeclarativeStorage storage $ = _getStorage();
        // Must be registered and not revoked to verify
        uint16 status = $.status[instanceId];
        if ((status & (REGISTERED | SEALED)) == 0) {
            return false;
        }
        return $.contentHash[instanceId] == contentHash;
    }
}
