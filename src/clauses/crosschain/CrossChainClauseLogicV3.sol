// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ClauseBase} from "../../base/ClauseBase.sol";

/// @title CrossChainClauseLogicV3
/// @notice Self-describing cross-chain messaging clause following v3 specification
/// @dev Logic contract executed via delegatecall from Agreement proxies.
///      Uses ERC-7201 namespaced storage to prevent collisions with other clauses.
///      All functions take instanceId as first parameter for multi-instance support.
///
///      This clause tracks cross-chain message state within an Agreement. It works
///      in conjunction with CrossChainControllerV3, which handles the actual CCIP
///      communication.
///
///      State Machine (OUTGOING messages):
///      ┌────────────────┐
///      │  Uninitialized │
///      │    (status=0)  │
///      └───────┬────────┘
///              │ intakeDestination(), intakeRemoteAgreement(), intakeAction()
///              │ intakeReady()
///              ▼
///      ┌────────────────┐
///      │    PENDING     │ ← Ready to send
///      │   (0x0002)     │
///      └───────┬────────┘
///              │ actionMarkSent() [called by controller]
///              ▼
///      ┌────────────────┐
///      │      SENT      │ ← Message sent via CCIP
///      │   (0x0010)     │
///      └───────┬────────┘
///              │ actionMarkConfirmed() [optional, for tracking]
///              ▼
///      ┌────────────────┐
///      │   CONFIRMED    │ ← Execution confirmed on destination
///      │   (0x0020)     │
///      └────────────────┘
///
///      State Machine (INCOMING messages):
///      ┌────────────────┐
///      │  Uninitialized │
///      └───────┬────────┘
///              │ actionProcessIncoming() [called by controller]
///              ▼
///      ┌────────────────┐
///      │    RECEIVED    │ ← Message received and processed
///      │   (0x0040)     │
///      └────────────────┘
contract CrossChainClauseLogicV3 is ClauseBase {
    // =============================================================
    // EXTENDED STATES (bitmask)
    // =============================================================

    // Note: PENDING (0x0002), COMPLETE (0x0004), CANCELLED (0x0008) from ClauseBase
    // We define cross-chain-specific states:
    uint16 internal constant SENT = 1 << 4; // 0x0010 - message sent via CCIP
    uint16 internal constant CONFIRMED = 1 << 5; // 0x0020 - execution confirmed
    uint16 internal constant RECEIVED = 1 << 6; // 0x0040 - incoming message processed

    // =============================================================
    // ACTION TYPES
    // =============================================================

    /// @notice Actions that can be triggered cross-chain
    /// @dev Matches v2 CrossChainAction enum for compatibility
    uint8 public constant ACTION_NONE = 0;
    uint8 public constant ACTION_SIGNATURES_COMPLETE = 1;
    uint8 public constant ACTION_RELEASE_ESCROW = 2;
    uint8 public constant ACTION_REFUND_ESCROW = 3;
    uint8 public constant ACTION_CANCEL_AGREEMENT = 4;
    uint8 public constant ACTION_TRIGGER_MILESTONE = 5;
    uint8 public constant ACTION_CUSTOM = 255;

    // =============================================================
    // ERRORS
    // =============================================================

    error WrongState(uint16 expected, uint16 actual);
    error ZeroAddress();
    error ZeroChainSelector();
    error InvalidAction();
    error NotAuthorized(address caller, address expected);
    error MissingConfiguration();

    // =============================================================
    // EVENTS
    // =============================================================

    event CrossChainConfigured(
        bytes32 indexed instanceId, uint64 destinationChain, address remoteAgreement, uint8 action
    );

    event CrossChainMessageSent(
        bytes32 indexed instanceId, bytes32 indexed messageId, uint64 destinationChain, address remoteAgreement
    );

    event CrossChainMessageReceived(
        bytes32 indexed instanceId, uint64 sourceChain, address sourceAgreement, uint8 action
    );

    event CrossChainConfirmed(bytes32 indexed instanceId, bytes32 indexed messageId);

    // =============================================================
    // ERC-7201 NAMESPACED STORAGE
    // =============================================================

    /// @custom:storage-location erc7201:papre.clause.crosschain.storage
    struct CrossChainStorage {
        /// @notice instanceId => clause state
        mapping(bytes32 => uint16) status;
        /// @notice instanceId => destination chain selector (for outgoing)
        mapping(bytes32 => uint64) destinationChain;
        /// @notice instanceId => source chain selector (for incoming)
        mapping(bytes32 => uint64) sourceChain;
        /// @notice instanceId => remote agreement address
        mapping(bytes32 => address) remoteAgreement;
        /// @notice instanceId => action type to trigger
        mapping(bytes32 => uint8) action;
        /// @notice instanceId => CCIP message ID (after sending)
        mapping(bytes32 => bytes32) messageId;
        /// @notice instanceId => extra data for the action
        mapping(bytes32 => bytes) extraData;
        /// @notice instanceId => content hash (document/reference being bridged)
        mapping(bytes32 => bytes32) contentHash;
        /// @notice instanceId => timestamp when sent
        mapping(bytes32 => uint256) sentAt;
        /// @notice instanceId => timestamp when received
        mapping(bytes32 => uint256) receivedAt;
        /// @notice Address authorized to call controller functions (set per agreement)
        mapping(bytes32 => address) authorizedController;
    }

    // keccak256(abi.encode(uint256(keccak256("papre.clause.crosschain.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT = 0x8f3b2c1d0e4a5f6789012345678901234567890123456789012345678901ab00;

    function _getStorage() internal pure returns (CrossChainStorage storage $) {
        assembly {
            $.slot := STORAGE_SLOT
        }
    }

    // =============================================================
    // INTAKE (from previous clause or configuration)
    // =============================================================

    /// @notice Set the destination chain selector
    /// @param instanceId Unique identifier for this cross-chain instance
    /// @param chainSelector CCIP chain selector for the destination
    function intakeDestinationChain(bytes32 instanceId, uint64 chainSelector) external {
        if (chainSelector == 0) revert ZeroChainSelector();
        CrossChainStorage storage $ = _getStorage();
        require($.status[instanceId] == 0, "Wrong state");
        $.destinationChain[instanceId] = chainSelector;
    }

    /// @notice Set the remote agreement address
    /// @param instanceId Unique identifier for this cross-chain instance
    /// @param _remoteAgreement Address of the agreement on the destination chain
    function intakeRemoteAgreement(bytes32 instanceId, address _remoteAgreement) external {
        if (_remoteAgreement == address(0)) revert ZeroAddress();
        CrossChainStorage storage $ = _getStorage();
        require($.status[instanceId] == 0, "Wrong state");
        $.remoteAgreement[instanceId] = _remoteAgreement;
    }

    /// @notice Set the action to trigger on the destination
    /// @param instanceId Unique identifier for this cross-chain instance
    /// @param _action Action type to trigger (see ACTION_* constants)
    function intakeAction(bytes32 instanceId, uint8 _action) external {
        CrossChainStorage storage $ = _getStorage();
        require($.status[instanceId] == 0, "Wrong state");
        $.action[instanceId] = _action;
    }

    /// @notice Set the content hash (document being bridged)
    /// @param instanceId Unique identifier for this cross-chain instance
    /// @param _contentHash Hash of the content/document
    function intakeContentHash(bytes32 instanceId, bytes32 _contentHash) external {
        CrossChainStorage storage $ = _getStorage();
        require($.status[instanceId] == 0, "Wrong state");
        $.contentHash[instanceId] = _contentHash;
    }

    /// @notice Set extra data for the action
    /// @param instanceId Unique identifier for this cross-chain instance
    /// @param _extraData Additional data to pass with the action
    function intakeExtraData(bytes32 instanceId, bytes calldata _extraData) external {
        CrossChainStorage storage $ = _getStorage();
        require($.status[instanceId] == 0, "Wrong state");
        $.extraData[instanceId] = _extraData;
    }

    /// @notice Set the authorized controller address
    /// @param instanceId Unique identifier for this cross-chain instance
    /// @param controller Address of the CrossChainControllerV3
    function intakeController(bytes32 instanceId, address controller) external {
        if (controller == address(0)) revert ZeroAddress();
        CrossChainStorage storage $ = _getStorage();
        require($.status[instanceId] == 0, "Wrong state");
        $.authorizedController[instanceId] = controller;
    }

    /// @notice Finalize configuration and transition to PENDING
    /// @param instanceId Unique identifier for this cross-chain instance
    /// @dev Requires destinationChain, remoteAgreement, and action to be set
    function intakeReady(bytes32 instanceId) external {
        CrossChainStorage storage $ = _getStorage();
        require($.status[instanceId] == 0, "Wrong state");

        if ($.destinationChain[instanceId] == 0) revert MissingConfiguration();
        if ($.remoteAgreement[instanceId] == address(0)) revert MissingConfiguration();
        if ($.authorizedController[instanceId] == address(0)) revert MissingConfiguration();

        $.status[instanceId] = PENDING;

        emit CrossChainConfigured(
            instanceId, $.destinationChain[instanceId], $.remoteAgreement[instanceId], $.action[instanceId]
        );
    }

    // =============================================================
    // ACTIONS (state-changing)
    // =============================================================

    /// @notice Mark a message as sent (called after CCIP send)
    /// @param instanceId Unique identifier for this cross-chain instance
    /// @param _messageId CCIP message ID returned from router
    /// @dev In v3 delegatecall pattern, authorization is implicit:
    ///      - This function is executed in the Agreement's context via delegatecall
    ///      - The Agreement holds the storage and controls access to its functions
    ///      - If an adapter or Agreement calls this, it's because the send succeeded
    ///      - The authorizedController field is used for reference/validation, not access control
    /// @custom:papre-style primary
    function actionMarkSent(bytes32 instanceId, bytes32 _messageId) external {
        CrossChainStorage storage $ = _getStorage();
        require($.status[instanceId] == PENDING, "Wrong state");

        // Note: In v3 delegatecall pattern, we don't check msg.sender == controller
        // because msg.sender is preserved from original call and we're executing
        // in Agreement's context. Authorization is handled by the Agreement's
        // access control to its external functions.

        $.messageId[instanceId] = _messageId;
        $.sentAt[instanceId] = block.timestamp;
        $.status[instanceId] = SENT;

        emit CrossChainMessageSent(
            instanceId, _messageId, $.destinationChain[instanceId], $.remoteAgreement[instanceId]
        );
    }

    /// @notice Mark a message as confirmed on destination
    /// @param instanceId Unique identifier for this cross-chain instance
    /// @dev Optional - used for tracking round-trip confirmation
    function actionMarkConfirmed(bytes32 instanceId) external {
        CrossChainStorage storage $ = _getStorage();
        require($.status[instanceId] == SENT, "Wrong state");

        $.status[instanceId] = CONFIRMED;

        emit CrossChainConfirmed(instanceId, $.messageId[instanceId]);
    }

    /// @notice Process an incoming cross-chain message
    /// @param instanceId Unique identifier for this cross-chain instance
    /// @param _sourceChain Source chain selector
    /// @param _sourceAgreement Source agreement address
    /// @param _action Action being triggered
    /// @param _contentHash Content hash being referenced
    /// @param _extraData Extra data for the action
    /// @dev Called by controller when receiving CCIP message
    function actionProcessIncoming(
        bytes32 instanceId,
        uint64 _sourceChain,
        address _sourceAgreement,
        uint8 _action,
        bytes32 _contentHash,
        bytes calldata _extraData
    ) external {
        CrossChainStorage storage $ = _getStorage();
        // For incoming, we expect uninitialized state
        require($.status[instanceId] == 0, "Already processed");

        $.sourceChain[instanceId] = _sourceChain;
        $.remoteAgreement[instanceId] = _sourceAgreement;
        $.action[instanceId] = _action;
        $.contentHash[instanceId] = _contentHash;
        $.extraData[instanceId] = _extraData;
        $.receivedAt[instanceId] = block.timestamp;
        $.status[instanceId] = RECEIVED;

        emit CrossChainMessageReceived(instanceId, _sourceChain, _sourceAgreement, _action);
    }

    /// @notice Cancel a pending cross-chain message
    /// @param instanceId Unique identifier for this cross-chain instance
    /// @custom:papre-style destructive
    function actionCancel(bytes32 instanceId) external {
        CrossChainStorage storage $ = _getStorage();
        require($.status[instanceId] == PENDING, "Wrong state");
        $.status[instanceId] = CANCELLED;
    }

    // =============================================================
    // HANDOFF (to next clause)
    // =============================================================

    /// @notice Get the action to execute after receiving a cross-chain message
    /// @param instanceId Unique identifier for this cross-chain instance
    /// @return The action type
    function handoffAction(bytes32 instanceId) external view returns (uint8) {
        CrossChainStorage storage $ = _getStorage();
        require($.status[instanceId] == RECEIVED, "Wrong state");
        return $.action[instanceId];
    }

    /// @notice Get the extra data after receiving a cross-chain message
    /// @param instanceId Unique identifier for this cross-chain instance
    /// @return The extra data
    function handoffExtraData(bytes32 instanceId) external view returns (bytes memory) {
        CrossChainStorage storage $ = _getStorage();
        require($.status[instanceId] == RECEIVED, "Wrong state");
        return $.extraData[instanceId];
    }

    /// @notice Get the content hash after receiving a cross-chain message
    /// @param instanceId Unique identifier for this cross-chain instance
    /// @return The content hash
    function handoffContentHash(bytes32 instanceId) external view returns (bytes32) {
        CrossChainStorage storage $ = _getStorage();
        require($.status[instanceId] == RECEIVED, "Wrong state");
        return $.contentHash[instanceId];
    }

    /// @notice Get the source agreement after receiving a cross-chain message
    /// @param instanceId Unique identifier for this cross-chain instance
    /// @return The source agreement address
    function handoffSourceAgreement(bytes32 instanceId) external view returns (address) {
        CrossChainStorage storage $ = _getStorage();
        require($.status[instanceId] == RECEIVED, "Wrong state");
        return $.remoteAgreement[instanceId];
    }

    /// @notice Get the CCIP message ID after successful send
    /// @param instanceId Unique identifier for this cross-chain instance
    /// @return The CCIP message ID
    function handoffMessageId(bytes32 instanceId) external view returns (bytes32) {
        CrossChainStorage storage $ = _getStorage();
        require($.status[instanceId] & (SENT | CONFIRMED) != 0, "Wrong state");
        return $.messageId[instanceId];
    }

    // =============================================================
    // QUERIES (always available)
    // =============================================================

    /// @notice Get the current state of an instance
    /// @param instanceId Unique identifier for this cross-chain instance
    /// @return Current state bitmask
    function queryStatus(bytes32 instanceId) external view returns (uint16) {
        return _getStorage().status[instanceId];
    }

    /// @notice Get the destination chain selector
    /// @param instanceId Unique identifier for this cross-chain instance
    /// @return CCIP chain selector
    function queryDestinationChain(bytes32 instanceId) external view returns (uint64) {
        return _getStorage().destinationChain[instanceId];
    }

    /// @notice Get the source chain selector (for received messages)
    /// @param instanceId Unique identifier for this cross-chain instance
    /// @return CCIP chain selector
    function querySourceChain(bytes32 instanceId) external view returns (uint64) {
        return _getStorage().sourceChain[instanceId];
    }

    /// @notice Get the remote agreement address
    /// @param instanceId Unique identifier for this cross-chain instance
    /// @return Remote agreement address
    function queryRemoteAgreement(bytes32 instanceId) external view returns (address) {
        return _getStorage().remoteAgreement[instanceId];
    }

    /// @notice Get the action type
    /// @param instanceId Unique identifier for this cross-chain instance
    /// @return Action type constant
    function queryAction(bytes32 instanceId) external view returns (uint8) {
        return _getStorage().action[instanceId];
    }

    /// @notice Get the CCIP message ID
    /// @param instanceId Unique identifier for this cross-chain instance
    /// @return Message ID (bytes32(0) if not sent)
    function queryMessageId(bytes32 instanceId) external view returns (bytes32) {
        return _getStorage().messageId[instanceId];
    }

    /// @notice Get the content hash
    /// @param instanceId Unique identifier for this cross-chain instance
    /// @return Content hash
    function queryContentHash(bytes32 instanceId) external view returns (bytes32) {
        return _getStorage().contentHash[instanceId];
    }

    /// @notice Get the extra data
    /// @param instanceId Unique identifier for this cross-chain instance
    /// @return Extra data bytes
    function queryExtraData(bytes32 instanceId) external view returns (bytes memory) {
        return _getStorage().extraData[instanceId];
    }

    /// @notice Get the authorized controller address
    /// @param instanceId Unique identifier for this cross-chain instance
    /// @return Controller address
    function queryController(bytes32 instanceId) external view returns (address) {
        return _getStorage().authorizedController[instanceId];
    }

    /// @notice Get the timestamp when message was sent
    /// @param instanceId Unique identifier for this cross-chain instance
    /// @return Unix timestamp (0 if not sent)
    function querySentAt(bytes32 instanceId) external view returns (uint256) {
        return _getStorage().sentAt[instanceId];
    }

    /// @notice Get the timestamp when message was received
    /// @param instanceId Unique identifier for this cross-chain instance
    /// @return Unix timestamp (0 if not received)
    function queryReceivedAt(bytes32 instanceId) external view returns (uint256) {
        return _getStorage().receivedAt[instanceId];
    }

    /// @notice Check if message is pending (ready to send)
    /// @param instanceId Unique identifier for this cross-chain instance
    /// @return True if in PENDING state
    function queryIsPending(bytes32 instanceId) external view returns (bool) {
        return _getStorage().status[instanceId] == PENDING;
    }

    /// @notice Check if message has been sent
    /// @param instanceId Unique identifier for this cross-chain instance
    /// @return True if in SENT or CONFIRMED state
    function queryIsSent(bytes32 instanceId) external view returns (bool) {
        uint16 status = _getStorage().status[instanceId];
        return status == SENT || status == CONFIRMED;
    }

    /// @notice Check if incoming message has been received
    /// @param instanceId Unique identifier for this cross-chain instance
    /// @return True if in RECEIVED state
    function queryIsReceived(bytes32 instanceId) external view returns (bool) {
        return _getStorage().status[instanceId] == RECEIVED;
    }

    /// @notice Get full configuration for an instance
    /// @param instanceId Unique identifier for this cross-chain instance
    /// @return status Current state
    /// @return destinationChain Destination chain selector
    /// @return remoteAgreement Remote agreement address
    /// @return action Action type
    /// @return contentHash Content hash
    function queryConfig(bytes32 instanceId)
        external
        view
        returns (uint16 status, uint64 destinationChain, address remoteAgreement, uint8 action, bytes32 contentHash)
    {
        CrossChainStorage storage $ = _getStorage();
        return (
            $.status[instanceId],
            $.destinationChain[instanceId],
            $.remoteAgreement[instanceId],
            $.action[instanceId],
            $.contentHash[instanceId]
        );
    }
}
