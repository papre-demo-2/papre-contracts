// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title ICrossChainTransport
/// @notice Interface for cross-chain message transport following v3 clause patterns
/// @dev Implementations may use CCIP, LayerZero, Hyperlane, etc.
interface ICrossChainTransport {
    // =============================================================
    // EVENTS
    // =============================================================

    /// @notice Emitted when a message is queued for sending
    event MessageQueued(
        bytes32 indexed instanceId, uint64 indexed destChainSelector, address destAddress, bytes32 payloadHash
    );

    /// @notice Emitted when a message is sent cross-chain
    event MessageSent(bytes32 indexed instanceId, bytes32 indexed messageId, uint64 destChainSelector);

    /// @notice Emitted when a message is received from another chain
    event MessageReceived(
        bytes32 indexed instanceId, bytes32 indexed messageId, uint64 sourceChainSelector, address sourceAddress
    );

    // =============================================================
    // ERRORS
    // =============================================================

    error ChainNotAllowed(uint64 chainSelector);
    error SourceNotAllowed(uint64 chainSelector, address source);
    error InsufficientFee(uint256 required, uint256 provided);
    error MessageNotReady();
    error AlreadySent();
    error AlreadyProcessed();

    // =============================================================
    // STRUCTS
    // =============================================================

    /// @notice Configuration for a destination chain
    struct ChainConfig {
        bool allowed;
        address transportContract; // CrossChainTransport on destination chain
    }

    /// @notice Outbound message ready to be sent
    struct OutboundMessage {
        uint64 destChainSelector;
        address destAddress;
        bytes payload;
        bool sent;
    }

    /// @notice Inbound message received from another chain
    struct InboundMessage {
        uint64 sourceChainSelector;
        address sourceAddress;
        bytes payload;
        uint256 receivedAt;
        bool processed;
    }

    // =============================================================
    // INTAKE FUNCTIONS
    // =============================================================

    /// @notice Queue a message for cross-chain delivery
    /// @param instanceId Unique identifier for this transport instance
    /// @param destChainSelector The destination chain selector
    /// @param destAddress The destination contract address
    /// @param payload The encoded message payload (from CrossChainCodec)
    function intakeQueueMessage(
        bytes32 instanceId,
        uint64 destChainSelector,
        address destAddress,
        bytes calldata payload
    ) external;

    // =============================================================
    // ACTION FUNCTIONS
    // =============================================================

    /// @notice Send a queued message cross-chain
    /// @param instanceId Unique identifier for this transport instance
    /// @return messageId The transport-specific message ID
    function actionSend(bytes32 instanceId) external payable returns (bytes32 messageId);

    /// @notice Mark a received message as processed
    /// @param instanceId Unique identifier for this transport instance
    function actionMarkProcessed(bytes32 instanceId) external;

    // =============================================================
    // HANDOFF FUNCTIONS
    // =============================================================

    /// @notice Get the payload from a received message for processing
    /// @param instanceId Unique identifier for this transport instance
    /// @return payload The message payload
    function handoffPayload(bytes32 instanceId) external view returns (bytes memory payload);

    /// @notice Get the source information from a received message
    /// @param instanceId Unique identifier for this transport instance
    /// @return sourceChainSelector The source chain
    /// @return sourceAddress The source contract address
    function handoffSource(bytes32 instanceId)
        external
        view
        returns (uint64 sourceChainSelector, address sourceAddress);

    // =============================================================
    // QUERY FUNCTIONS
    // =============================================================

    /// @notice Get the current status of a transport instance
    /// @param instanceId Unique identifier for this transport instance
    /// @return status The current state (0=uninitialized, 1=queued, 2=sent, 3=received, 4=processed)
    function queryStatus(bytes32 instanceId) external view returns (uint16 status);

    /// @notice Get fee estimate for sending a message
    /// @param instanceId Unique identifier for this transport instance
    /// @return fee The estimated fee in native token
    function queryFee(bytes32 instanceId) external view returns (uint256 fee);

    /// @notice Check if a chain is allowed for transport
    /// @param chainSelector The chain selector to check
    /// @return allowed True if the chain is allowed
    function queryChainAllowed(uint64 chainSelector) external view returns (bool allowed);
}
