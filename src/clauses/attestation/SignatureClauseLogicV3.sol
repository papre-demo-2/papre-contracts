// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ClauseBase} from "../../base/ClauseBase.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title SignatureClauseLogicV3
/// @notice Self-describing signature collection clause following v3 specification
/// @dev Logic contract executed via delegatecall from Agreement proxies.
///      Uses ERC-7201 namespaced storage to prevent collisions with other clauses.
///      All functions take instanceId as first parameter for multi-instance support.
///
///      PENDING COUNTERPARTY SUPPORT:
///      Signers can include address(0) to represent pending slots that will be
///      claimed later via backend-signed attestations. This enables creating
///      agreements before knowing the counterparty's wallet address.
contract SignatureClauseLogicV3 is ClauseBase {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // =============================================================
    // ERRORS
    // =============================================================

    error SlotNotPending(bytes32 instanceId, uint256 slotIndex);
    error SlotAlreadyFilled(bytes32 instanceId, uint256 slotIndex);
    error UnauthorizedAttestor(address attestor);
    error InvalidClaimAttestation();
    error ClaimerAlreadySigner(bytes32 instanceId, address claimer);

    // =============================================================
    // EVENTS
    // =============================================================

    event SignerSlotClaimed(
        bytes32 indexed instanceId,
        uint256 indexed slotIndex,
        address indexed claimer,
        address attestor
    );
    event TrustedAttestorSet(address indexed attestor, bool trusted);

    // =============================================================
    // ERC-7201 NAMESPACED STORAGE
    // =============================================================

    /// @custom:storage-location erc7201:papre.clause.signature.storage
    struct SignatureStorage {
        /// @notice instanceId => clause state
        mapping(bytes32 => uint16) status;
        /// @notice instanceId => array of required signers
        mapping(bytes32 => address[]) signers;
        /// @notice instanceId => signer => their signature
        mapping(bytes32 => mapping(address => bytes)) signatures;
        /// @notice instanceId => document hash being signed
        mapping(bytes32 => bytes32) documentHash;
        /// @notice instanceId => indices of pending (unclaimed) signer slots
        mapping(bytes32 => uint256[]) pendingSlotIndices;
        /// @notice Trusted attestor addresses that can authorize slot claims
        mapping(address => bool) trustedAttestors;
    }

    // keccak256(abi.encode(uint256(keccak256("papre.clause.signature.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT =
        0xb9275fdc74765a832627ae6dd03da7014a07edb33b727516e7623706fd582300;

    function _getStorage() internal pure returns (SignatureStorage storage $) {
        assembly {
            $.slot := STORAGE_SLOT
        }
    }

    // =============================================================
    // INTAKE (from previous clause)
    // =============================================================

    /// @notice Set the required signers for this instance
    /// @dev address(0) entries are treated as pending slots that can be claimed later
    /// @param instanceId Unique identifier for this signing instance
    /// @param signers Array of addresses required to sign (address(0) = pending slot)
    function intakeSigners(bytes32 instanceId, address[] calldata signers) external {
        SignatureStorage storage $ = _getStorage();
        // Status 0 means uninitialized (fresh storage)
        require($.status[instanceId] == 0, "Wrong state");

        // Store signers and track pending slots (address(0))
        for (uint256 i = 0; i < signers.length; i++) {
            $.signers[instanceId].push(signers[i]);
            if (signers[i] == address(0)) {
                // Track this as a pending slot that needs to be claimed
                $.pendingSlotIndices[instanceId].push(i);
            }
        }
    }

    /// @notice Set the document hash and transition to PENDING
    /// @param instanceId Unique identifier for this signing instance
    /// @param docHash Hash of the document being signed
    function intakeDocumentHash(bytes32 instanceId, bytes32 docHash) external {
        SignatureStorage storage $ = _getStorage();
        // Status 0 means uninitialized (fresh storage)
        require($.status[instanceId] == 0, "Wrong state");
        $.documentHash[instanceId] = docHash;
        $.status[instanceId] = PENDING;
    }

    // =============================================================
    // ACTIONS (state-changing)
    // =============================================================

    /// @notice Submit a signature for the document
    /// @param instanceId Unique identifier for this signing instance
    /// @param signature The cryptographic signature
    /// @custom:papre-style primary
    function actionSign(bytes32 instanceId, bytes calldata signature) external {
        SignatureStorage storage $ = _getStorage();
        require($.status[instanceId] == PENDING, "Wrong state");

        $.signatures[instanceId][msg.sender] = signature;
        if (_allSigned($, instanceId)) {
            $.status[instanceId] = COMPLETE;
        }
    }

    /// @notice Cancel the signing process
    /// @param instanceId Unique identifier for this signing instance
    /// @custom:papre-style destructive
    function actionCancel(bytes32 instanceId) external {
        SignatureStorage storage $ = _getStorage();
        require($.status[instanceId] == PENDING, "Wrong state");
        $.status[instanceId] = CANCELLED;
    }

    /// @notice Claim a pending signer slot using backend attestation
    /// @dev Called by the counterparty after receiving an invitation.
    ///      Backend signs attestation after verifying email ownership via Privy.
    /// @param instanceId Unique identifier for this signing instance
    /// @param slotIndex Index in the signers array to claim
    /// @param claimer Address claiming the slot
    /// @param attestation ECDSA signature from trusted attestor
    function actionClaimSignerSlot(
        bytes32 instanceId,
        uint256 slotIndex,
        address claimer,
        bytes calldata attestation
    ) external {
        SignatureStorage storage $ = _getStorage();

        // Validate slot is pending (address(0))
        if (slotIndex >= $.signers[instanceId].length) {
            revert SlotNotPending(instanceId, slotIndex);
        }
        if ($.signers[instanceId][slotIndex] != address(0)) {
            revert SlotAlreadyFilled(instanceId, slotIndex);
        }

        // Check claimer isn't already a signer in another slot
        for (uint256 i = 0; i < $.signers[instanceId].length; i++) {
            if ($.signers[instanceId][i] == claimer) {
                revert ClaimerAlreadySigner(instanceId, claimer);
            }
        }

        // Verify attestation signature
        // Message format matches what backend signs:
        // keccak256(abi.encode(agreement, instanceId, slotIndex, claimer, "CLAIM_SIGNER_SLOT"))
        bytes32 messageHash = keccak256(
            abi.encode(
                address(this),  // agreement
                instanceId,
                slotIndex,
                claimer,
                "CLAIM_SIGNER_SLOT"
            )
        );

        // Recover signer using EIP-191 personal sign
        bytes32 ethSignedHash = messageHash.toEthSignedMessageHash();
        address recoveredAttestor = ethSignedHash.recover(attestation);

        // Verify attestor is trusted
        if (!$.trustedAttestors[recoveredAttestor]) {
            revert UnauthorizedAttestor(recoveredAttestor);
        }

        // Fill the slot
        $.signers[instanceId][slotIndex] = claimer;

        // Remove from pending slots
        _removePendingSlot($, instanceId, slotIndex);

        emit SignerSlotClaimed(instanceId, slotIndex, claimer, recoveredAttestor);
    }

    /// @notice Set trusted attestor status (called by agreement admin)
    /// @param attestor Address to set trust status for
    /// @param trusted Whether the attestor is trusted
    function setTrustedAttestor(address attestor, bool trusted) external {
        SignatureStorage storage $ = _getStorage();
        $.trustedAttestors[attestor] = trusted;
        emit TrustedAttestorSet(attestor, trusted);
    }

    // =============================================================
    // HANDOFF (to next clause)
    // =============================================================

    /// @notice Get the signers after successful completion
    /// @param instanceId Unique identifier for this signing instance
    /// @return Array of signer addresses
    function handoffSigners(bytes32 instanceId) external view returns (address[] memory) {
        SignatureStorage storage $ = _getStorage();
        require($.status[instanceId] == COMPLETE, "Wrong state");
        return $.signers[instanceId];
    }

    /// @notice Get the document hash after successful completion
    /// @param instanceId Unique identifier for this signing instance
    /// @return The document hash
    function handoffDocumentHash(bytes32 instanceId) external view returns (bytes32) {
        SignatureStorage storage $ = _getStorage();
        require($.status[instanceId] == COMPLETE, "Wrong state");
        return $.documentHash[instanceId];
    }

    // =============================================================
    // QUERIES (always available)
    // =============================================================

    /// @notice Get the current state of an instance
    /// @param instanceId Unique identifier for this signing instance
    /// @return Current state bitmask
    function queryStatus(bytes32 instanceId) external view returns (uint16) {
        return _getStorage().status[instanceId];
    }

    /// @notice Check if an address has signed
    /// @param instanceId Unique identifier for this signing instance
    /// @param signer Address to check
    /// @return True if the address has submitted a signature
    function queryHasSigned(bytes32 instanceId, address signer) external view returns (bool) {
        return _getStorage().signatures[instanceId][signer].length > 0;
    }

    /// @notice Get the list of required signers
    /// @param instanceId Unique identifier for this signing instance
    /// @return Array of signer addresses
    function querySigners(bytes32 instanceId) external view returns (address[] memory) {
        return _getStorage().signers[instanceId];
    }

    /// @notice Check if instance has any pending (unclaimed) signer slots
    /// @param instanceId Unique identifier for this signing instance
    /// @return hasPending True if there are pending slots
    /// @return pendingCount Number of pending slots
    /// @return indices Array of indices that are pending
    function queryHasPendingSlots(bytes32 instanceId)
        external
        view
        returns (bool hasPending, uint256 pendingCount, uint256[] memory indices)
    {
        SignatureStorage storage $ = _getStorage();
        indices = $.pendingSlotIndices[instanceId];
        pendingCount = indices.length;
        hasPending = pendingCount > 0;
    }

    /// @notice Check if an attestor is trusted
    /// @param attestor Address to check
    /// @return True if the attestor is trusted
    function queryIsTrustedAttestor(address attestor) external view returns (bool) {
        return _getStorage().trustedAttestors[attestor];
    }

    // =============================================================
    // INTERNAL
    // =============================================================

    /// @notice Check if all required signers have signed
    /// @dev Skips address(0) entries as they are pending slots
    function _allSigned(SignatureStorage storage $, bytes32 instanceId) private view returns (bool) {
        address[] storage signers = $.signers[instanceId];
        for (uint256 i = 0; i < signers.length; i++) {
            // Skip pending slots (address(0)) - they can't sign
            if (signers[i] == address(0)) continue;
            if ($.signatures[instanceId][signers[i]].length == 0) return false;
        }
        return true;
    }

    /// @notice Remove a slot index from the pending slots array
    function _removePendingSlot(
        SignatureStorage storage $,
        bytes32 instanceId,
        uint256 slotIndex
    ) private {
        uint256[] storage pending = $.pendingSlotIndices[instanceId];
        for (uint256 i = 0; i < pending.length; i++) {
            if (pending[i] == slotIndex) {
                // Swap with last element and pop
                pending[i] = pending[pending.length - 1];
                pending.pop();
                return;
            }
        }
    }
}
