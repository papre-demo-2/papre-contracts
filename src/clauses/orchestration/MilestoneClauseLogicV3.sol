// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ClauseBase} from "../../base/ClauseBase.sol";

/// @title MilestoneClauseLogicV3
/// @notice Self-describing milestone orchestration clause following v3 specification
/// @dev Logic contract executed via delegatecall from Agreement proxies.
///      Uses ERC-7201 namespaced storage to prevent collisions with other clauses.
///      All functions take instanceId as first parameter for multi-instance support.
///
///      This is an ORCHESTRATION clause that coordinates multiple escrow instances.
///      Each milestone maps to a separate EscrowClauseLogicV3 instance.
///      The Agreement is responsible for creating escrow instances and linking them.
///
///      ADAPTER INTEGRATION:
///      This clause is designed to work with MilestoneEscrowAdapter, which provides
///      atomic operations that combine milestone confirmation with escrow release.
///      When using Milestone + Escrow together, the frontend should auto-include
///      the adapter to provide one-click confirm-and-release functionality.
///      See: src/adapters/MilestoneEscrowAdapter.sol
///
///      State Machine (Overall Instance):
///      ┌────────────────┐
///      │  Uninitialized │
///      │    (status=0)  │
///      └───────┬────────┘
///              │ intakeMilestone(), intakeBeneficiary(), intakeClient()
///              │ intakeToken(), intakeReady()
///              ▼
///      ┌────────────────┐
///      │    PENDING     │ ← Awaiting escrow funding
///      │   (0x0002)     │
///      └───────┬────────┘
///              │ actionActivate() [all escrows funded]
///              ▼
///      ┌────────────────┐
///      │    ACTIVE      │ ← Work in progress
///      │   (0x0010)     │
///      └───────┬────────┘
///              │ actionConfirm() per milestone
///              │ OR actionDispute() OR actionCancel()
///              ▼
///      ┌────────────────┐   ┌────────────────┐   ┌────────────────┐
///      │   COMPLETE     │   │   DISPUTED     │   │   CANCELLED    │
///      │   (0x0004)     │   │   (0x0020)     │   │   (0x0008)     │
///      └────────────────┘   └────────────────┘   └────────────────┘
///
///      Per-Milestone States:
///      - MILESTONE_NONE (0)      - Not configured
///      - MILESTONE_PENDING (1)   - Awaiting work
///      - MILESTONE_REQUESTED (2) - Freelancer requested confirmation
///      - MILESTONE_CONFIRMED (3) - Client confirmed, ready for release
///      - MILESTONE_DISPUTED (4)  - Dispute filed, awaiting resolution
///      - MILESTONE_RELEASED (5)  - Released to beneficiary
///      - MILESTONE_REFUNDED (6)  - Refunded to client
contract MilestoneClauseLogicV3 is ClauseBase {
    // =============================================================
    // CONSTANTS
    // =============================================================

    /// @notice Maximum number of milestones per instance
    uint256 public constant MAX_MILESTONES = 20;

    // =============================================================
    // EXTENDED STATES (bitmask for overall instance)
    // =============================================================

    // Note: PENDING (0x0002), COMPLETE (0x0004), CANCELLED (0x0008) from ClauseBase
    uint16 internal constant ACTIVE = 1 << 4; // 0x0010
    uint16 internal constant DISPUTED = 1 << 5; // 0x0020

    // =============================================================
    // MILESTONE STATES (per-milestone, not bitmask)
    // =============================================================

    uint8 public constant MILESTONE_NONE = 0;
    uint8 public constant MILESTONE_PENDING = 1;
    uint8 public constant MILESTONE_REQUESTED = 2;
    uint8 public constant MILESTONE_CONFIRMED = 3;
    uint8 public constant MILESTONE_DISPUTED = 4;
    uint8 public constant MILESTONE_RELEASED = 5;
    uint8 public constant MILESTONE_REFUNDED = 6;

    // =============================================================
    // ERRORS
    // =============================================================

    error WrongState(uint16 expected, uint16 actual);
    error WrongMilestoneState(uint8 expected, uint8 actual);
    error ZeroAddress();
    error ZeroAmount();
    error InvalidMilestoneIndex(uint256 index, uint256 count);
    error TooManyMilestones(uint256 requested, uint256 max);
    error NotClient(address caller, address client);
    error NotBeneficiary(address caller, address beneficiary);
    error NoMilestones();
    error EscrowNotLinked(uint256 milestoneIndex);
    error MilestoneAlreadyConfigured(uint256 index);

    // =============================================================
    // EVENTS
    // =============================================================

    event MilestoneAdded(
        bytes32 indexed instanceId, uint256 indexed milestoneIndex, bytes32 descriptionHash, uint256 amount
    );

    event MilestoneConfigured(
        bytes32 indexed instanceId,
        address indexed beneficiary,
        address indexed client,
        address token,
        uint256 milestoneCount
    );

    event MilestoneEscrowLinked(bytes32 indexed instanceId, uint256 indexed milestoneIndex, bytes32 escrowInstanceId);

    event MilestoneActivated(bytes32 indexed instanceId);

    event MilestoneRequested(bytes32 indexed instanceId, uint256 indexed milestoneIndex, address indexed beneficiary);

    event MilestoneConfirmed(bytes32 indexed instanceId, uint256 indexed milestoneIndex, address indexed client);

    event MilestoneDisputed(
        bytes32 indexed instanceId, uint256 indexed milestoneIndex, address indexed disputer, bytes32 reasonHash
    );

    event MilestoneRejectedForRevision(
        bytes32 indexed instanceId, uint256 indexed milestoneIndex, address indexed client, bytes32 reasonHash
    );

    event MilestoneReleased(bytes32 indexed instanceId, uint256 indexed milestoneIndex);

    event MilestoneRefunded(bytes32 indexed instanceId, uint256 indexed milestoneIndex);

    event MilestoneCancelled(bytes32 indexed instanceId);

    event MilestoneCompleted(bytes32 indexed instanceId, uint256 totalReleased);

    // =============================================================
    // STRUCTS
    // =============================================================

    /// @notice Individual milestone data
    struct Milestone {
        bytes32 descriptionHash; // Hash of milestone description (off-chain content)
        uint256 amount; // Amount for this milestone
        bytes32 escrowInstanceId; // Linked escrow instance
        uint8 status; // Per-milestone status
        uint256 confirmedAt; // Timestamp when confirmed (0 if not)
        uint256 releasedAt; // Timestamp when released (0 if not)
    }

    // =============================================================
    // ERC-7201 NAMESPACED STORAGE
    // =============================================================

    /// @custom:storage-location erc7201:papre.clause.milestone.storage
    struct MilestoneStorage {
        /// @notice instanceId => overall clause state
        mapping(bytes32 => uint16) status;
        /// @notice instanceId => freelancer/worker address
        mapping(bytes32 => address) beneficiary;
        /// @notice instanceId => client address
        mapping(bytes32 => address) client;
        /// @notice instanceId => token address (address(0) for ETH)
        mapping(bytes32 => address) token;
        /// @notice instanceId => number of milestones
        mapping(bytes32 => uint256) milestoneCount;
        /// @notice instanceId => milestone index => milestone data
        mapping(bytes32 => mapping(uint256 => Milestone)) milestones;
        /// @notice instanceId => number of released milestones
        mapping(bytes32 => uint256) releasedCount;
        /// @notice instanceId => total amount released
        mapping(bytes32 => uint256) totalReleased;
    }

    // keccak256(abi.encode(uint256(keccak256("papre.clause.milestone.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT = 0xd1fa2eb20138c5e640790d1c85f543f18433228b10feda9cc53b499d48509d00;

    function _getStorage() internal pure returns (MilestoneStorage storage $) {
        assembly {
            $.slot := STORAGE_SLOT
        }
    }

    // =============================================================
    // INTAKE (from previous clause or setup)
    // =============================================================

    /// @notice Add a milestone to this instance
    /// @param instanceId Unique identifier for this milestone instance
    /// @param descriptionHash Hash of the milestone description (e.g., IPFS CID hash)
    /// @param amount Amount to be released for this milestone
    function intakeMilestone(bytes32 instanceId, bytes32 descriptionHash, uint256 amount) external {
        if (amount == 0) revert ZeroAmount();

        MilestoneStorage storage $ = _getStorage();
        require($.status[instanceId] == 0, "Wrong state");

        uint256 index = $.milestoneCount[instanceId];
        if (index >= MAX_MILESTONES) revert TooManyMilestones(index + 1, MAX_MILESTONES);

        $.milestones[instanceId][index] = Milestone({
            descriptionHash: descriptionHash,
            amount: amount,
            escrowInstanceId: bytes32(0),
            status: MILESTONE_NONE,
            confirmedAt: 0,
            releasedAt: 0
        });
        $.milestoneCount[instanceId] = index + 1;

        emit MilestoneAdded(instanceId, index, descriptionHash, amount);
    }

    /// @notice Set the beneficiary (freelancer/worker) for this instance
    /// @param instanceId Unique identifier for this milestone instance
    /// @param _beneficiary Address that will receive payments
    function intakeBeneficiary(bytes32 instanceId, address _beneficiary) external {
        if (_beneficiary == address(0)) revert ZeroAddress();
        MilestoneStorage storage $ = _getStorage();
        require($.status[instanceId] == 0, "Wrong state");
        $.beneficiary[instanceId] = _beneficiary;
    }

    /// @notice Set the client for this instance
    /// @param instanceId Unique identifier for this milestone instance
    /// @param _client Address of the client (who funds and confirms)
    function intakeClient(bytes32 instanceId, address _client) external {
        if (_client == address(0)) revert ZeroAddress();
        MilestoneStorage storage $ = _getStorage();
        require($.status[instanceId] == 0, "Wrong state");
        $.client[instanceId] = _client;
    }

    /// @notice Set the token for this instance
    /// @param instanceId Unique identifier for this milestone instance
    /// @param _token Token address (address(0) for ETH)
    function intakeToken(bytes32 instanceId, address _token) external {
        MilestoneStorage storage $ = _getStorage();
        require($.status[instanceId] == 0, "Wrong state");
        $.token[instanceId] = _token;
    }

    /// @notice Link an escrow instance to a milestone
    /// @param instanceId Unique identifier for this milestone instance
    /// @param milestoneIndex Index of the milestone to link
    /// @param escrowInstanceId The escrow instance ID to link
    /// @dev Can be called in uninitialized or PENDING state
    function intakeMilestoneEscrowId(bytes32 instanceId, uint256 milestoneIndex, bytes32 escrowInstanceId) external {
        MilestoneStorage storage $ = _getStorage();
        uint16 status = $.status[instanceId];
        require(status == 0 || status == PENDING, "Wrong state");

        uint256 count = $.milestoneCount[instanceId];
        if (milestoneIndex >= count) revert InvalidMilestoneIndex(milestoneIndex, count);

        $.milestones[instanceId][milestoneIndex].escrowInstanceId = escrowInstanceId;

        emit MilestoneEscrowLinked(instanceId, milestoneIndex, escrowInstanceId);
    }

    /// @notice Finalize configuration and transition to PENDING
    /// @param instanceId Unique identifier for this milestone instance
    /// @dev Requires beneficiary, client, and at least one milestone
    function intakeReady(bytes32 instanceId) external {
        MilestoneStorage storage $ = _getStorage();
        require($.status[instanceId] == 0, "Wrong state");
        require($.beneficiary[instanceId] != address(0), "No beneficiary");
        require($.client[instanceId] != address(0), "No client");
        require($.milestoneCount[instanceId] > 0, "No milestones");

        // Initialize all milestones to PENDING state
        uint256 count = $.milestoneCount[instanceId];
        for (uint256 i = 0; i < count; i++) {
            $.milestones[instanceId][i].status = MILESTONE_PENDING;
        }

        $.status[instanceId] = PENDING;

        emit MilestoneConfigured(
            instanceId, $.beneficiary[instanceId], $.client[instanceId], $.token[instanceId], count
        );
    }

    // =============================================================
    // ACTIONS (state-changing)
    // =============================================================

    /// @notice Activate the milestone instance after all escrows are funded
    /// @param instanceId Unique identifier for this milestone instance
    /// @dev Called by Agreement after verifying all escrow instances are FUNDED.
    ///      Marked payable to allow delegatecall from payable functions.
    /// @custom:papre-style primary
    function actionActivate(bytes32 instanceId) external payable {
        MilestoneStorage storage $ = _getStorage();
        require($.status[instanceId] == PENDING, "Wrong state");

        // Verify all milestones have linked escrows
        uint256 count = $.milestoneCount[instanceId];
        for (uint256 i = 0; i < count; i++) {
            if ($.milestones[instanceId][i].escrowInstanceId == bytes32(0)) {
                revert EscrowNotLinked(i);
            }
        }

        $.status[instanceId] = ACTIVE;

        emit MilestoneActivated(instanceId);
    }

    /// @notice Request confirmation for a milestone (freelancer action)
    /// @param instanceId Unique identifier for this milestone instance
    /// @param milestoneIndex Index of the milestone to request
    /// @dev Also callable from DISPUTED state to allow non-disputed milestones to proceed
    /// @custom:papre-style primary
    function actionRequestConfirmation(bytes32 instanceId, uint256 milestoneIndex) external {
        MilestoneStorage storage $ = _getStorage();
        uint16 status = $.status[instanceId];
        // Allow requests from ACTIVE or DISPUTED state
        // Non-disputed milestones should still be requestable even when some are disputed
        require(status == ACTIVE || status == DISPUTED, "Wrong state");

        address beneficiary = $.beneficiary[instanceId];
        if (msg.sender != beneficiary) revert NotBeneficiary(msg.sender, beneficiary);

        uint256 count = $.milestoneCount[instanceId];
        if (milestoneIndex >= count) revert InvalidMilestoneIndex(milestoneIndex, count);

        Milestone storage m = $.milestones[instanceId][milestoneIndex];
        if (m.status != MILESTONE_PENDING) {
            revert WrongMilestoneState(MILESTONE_PENDING, m.status);
        }

        m.status = MILESTONE_REQUESTED;

        emit MilestoneRequested(instanceId, milestoneIndex, beneficiary);
    }

    /// @notice Confirm a milestone and authorize release (client action)
    /// @param instanceId Unique identifier for this milestone instance
    /// @param milestoneIndex Index of the milestone to confirm
    /// @dev After confirmation, Agreement should call escrow.actionRelease()
    ///      Also callable from DISPUTED state to allow non-disputed milestones to proceed
    /// @custom:papre-style primary
    function actionConfirm(bytes32 instanceId, uint256 milestoneIndex) external {
        MilestoneStorage storage $ = _getStorage();
        uint16 status = $.status[instanceId];
        // Allow confirmation from ACTIVE or DISPUTED state
        // Non-disputed milestones should still be confirmable even when some are disputed
        require(status == ACTIVE || status == DISPUTED, "Wrong state");

        address client = $.client[instanceId];
        if (msg.sender != client) revert NotClient(msg.sender, client);

        uint256 count = $.milestoneCount[instanceId];
        if (milestoneIndex >= count) revert InvalidMilestoneIndex(milestoneIndex, count);

        Milestone storage m = $.milestones[instanceId][milestoneIndex];
        // Can confirm from PENDING (skip request) or REQUESTED state
        if (m.status != MILESTONE_PENDING && m.status != MILESTONE_REQUESTED) {
            revert WrongMilestoneState(MILESTONE_REQUESTED, m.status);
        }

        m.status = MILESTONE_CONFIRMED;
        m.confirmedAt = block.timestamp;

        emit MilestoneConfirmed(instanceId, milestoneIndex, client);
    }

    /// @notice Confirm a milestone via deadline enforcement (permissionless)
    /// @param instanceId Unique identifier for this milestone instance
    /// @param milestoneIndex Index of the milestone to confirm
    /// @dev NO caller restriction - the caller (adapter) is responsible for verifying
    ///      that the deadline has actually expired before calling this.
    ///      This enables permissionless deadline enforcement where anyone can trigger
    ///      the auto-release after a deadline passes.
    ///      Only callable from ACTIVE or DISPUTED state.
    function actionDeadlineConfirm(bytes32 instanceId, uint256 milestoneIndex) external {
        MilestoneStorage storage $ = _getStorage();
        uint16 status = $.status[instanceId];
        require(status == ACTIVE || status == DISPUTED, "Wrong state");

        uint256 count = $.milestoneCount[instanceId];
        if (milestoneIndex >= count) revert InvalidMilestoneIndex(milestoneIndex, count);

        Milestone storage m = $.milestones[instanceId][milestoneIndex];
        // Same state requirements as actionConfirm
        if (m.status != MILESTONE_PENDING && m.status != MILESTONE_REQUESTED) {
            revert WrongMilestoneState(MILESTONE_REQUESTED, m.status);
        }

        m.status = MILESTONE_CONFIRMED;
        m.confirmedAt = block.timestamp;

        // Emit with address(0) to indicate automated confirmation (not client)
        emit MilestoneConfirmed(instanceId, milestoneIndex, address(0));
    }

    /// @notice Mark a milestone as released (after escrow release)
    /// @param instanceId Unique identifier for this milestone instance
    /// @param milestoneIndex Index of the milestone that was released
    /// @dev Called by Agreement after successful escrow.actionRelease()
    ///      Also callable from DISPUTED state when resolving disputes in favor of beneficiary
    function actionMarkReleased(bytes32 instanceId, uint256 milestoneIndex) external {
        MilestoneStorage storage $ = _getStorage();
        uint16 status = $.status[instanceId];
        // Allow marking as released from ACTIVE or DISPUTED state
        // DISPUTED is needed when resolving disputes in favor of beneficiary
        // while other milestones may still be disputed
        require(status == ACTIVE || status == DISPUTED, "Wrong state");

        uint256 count = $.milestoneCount[instanceId];
        if (milestoneIndex >= count) revert InvalidMilestoneIndex(milestoneIndex, count);

        Milestone storage m = $.milestones[instanceId][milestoneIndex];
        if (m.status != MILESTONE_CONFIRMED) {
            revert WrongMilestoneState(MILESTONE_CONFIRMED, m.status);
        }

        m.status = MILESTONE_RELEASED;
        m.releasedAt = block.timestamp;

        $.releasedCount[instanceId]++;
        $.totalReleased[instanceId] += m.amount;

        emit MilestoneReleased(instanceId, milestoneIndex);

        // Check if all milestones are released
        if ($.releasedCount[instanceId] == count) {
            $.status[instanceId] = COMPLETE;
            emit MilestoneCompleted(instanceId, $.totalReleased[instanceId]);
        }
    }

    /// @notice Mark a milestone as refunded (after escrow refund)
    /// @param instanceId Unique identifier for this milestone instance
    /// @param milestoneIndex Index of the milestone that was refunded
    /// @dev Called by Agreement after successful escrow.actionRefund()
    function actionMarkRefunded(bytes32 instanceId, uint256 milestoneIndex) external {
        MilestoneStorage storage $ = _getStorage();
        uint16 status = $.status[instanceId];
        require(status == ACTIVE || status == DISPUTED, "Wrong state");

        uint256 count = $.milestoneCount[instanceId];
        if (milestoneIndex >= count) revert InvalidMilestoneIndex(milestoneIndex, count);

        Milestone storage m = $.milestones[instanceId][milestoneIndex];
        // Can refund from PENDING, REQUESTED, or DISPUTED states
        if (m.status != MILESTONE_PENDING && m.status != MILESTONE_REQUESTED && m.status != MILESTONE_DISPUTED) {
            revert WrongMilestoneState(MILESTONE_PENDING, m.status);
        }

        m.status = MILESTONE_REFUNDED;

        emit MilestoneRefunded(instanceId, milestoneIndex);
    }

    /// @notice File a dispute for a milestone
    /// @param instanceId Unique identifier for this milestone instance
    /// @param milestoneIndex Index of the milestone to dispute
    /// @param reasonHash Hash of the dispute reason (off-chain content)
    /// @custom:papre-style destructive
    function actionDispute(bytes32 instanceId, uint256 milestoneIndex, bytes32 reasonHash) external {
        MilestoneStorage storage $ = _getStorage();
        uint16 status = $.status[instanceId];
        // Can dispute from ACTIVE or DISPUTED state (multiple milestones can be disputed)
        require(status == ACTIVE || status == DISPUTED, "Wrong state");

        // Either party can dispute
        address client = $.client[instanceId];
        address beneficiary = $.beneficiary[instanceId];
        require(msg.sender == client || msg.sender == beneficiary, "Not a party");

        uint256 count = $.milestoneCount[instanceId];
        if (milestoneIndex >= count) revert InvalidMilestoneIndex(milestoneIndex, count);

        Milestone storage m = $.milestones[instanceId][milestoneIndex];
        // Can dispute from PENDING or REQUESTED states
        if (m.status != MILESTONE_PENDING && m.status != MILESTONE_REQUESTED) {
            revert WrongMilestoneState(MILESTONE_PENDING, m.status);
        }

        m.status = MILESTONE_DISPUTED;

        // If any milestone is disputed, overall status becomes DISPUTED
        $.status[instanceId] = DISPUTED;

        emit MilestoneDisputed(instanceId, milestoneIndex, msg.sender, reasonHash);
    }

    /// @notice Reject a milestone and reset to PENDING for revision (not dispute)
    /// @param instanceId Unique identifier for this milestone instance
    /// @param milestoneIndex Index of the milestone to reject
    /// @param reasonHash Hash of the rejection reason (off-chain content)
    /// @dev Only the client can reject for revision. The milestone goes back to PENDING
    ///      so the contractor can resubmit. This does NOT trigger dispute status.
    ///      Use actionDispute for serious disputes requiring arbitration.
    /// @custom:papre-style secondary
    function actionRejectAndReset(bytes32 instanceId, uint256 milestoneIndex, bytes32 reasonHash) external {
        MilestoneStorage storage $ = _getStorage();
        uint16 status = $.status[instanceId];
        // Can reject from ACTIVE or DISPUTED state (for non-disputed milestones)
        require(status == ACTIVE || status == DISPUTED, "Wrong state");

        // Only client can reject for revision
        address client = $.client[instanceId];
        if (msg.sender != client) revert NotClient(msg.sender, client);

        uint256 count = $.milestoneCount[instanceId];
        if (milestoneIndex >= count) revert InvalidMilestoneIndex(milestoneIndex, count);

        Milestone storage m = $.milestones[instanceId][milestoneIndex];
        // Can only reject from REQUESTED state (submitted work)
        if (m.status != MILESTONE_REQUESTED) {
            revert WrongMilestoneState(MILESTONE_REQUESTED, m.status);
        }

        // Reset to PENDING (not DISPUTED) - contractor can resubmit
        m.status = MILESTONE_PENDING;

        emit MilestoneRejectedForRevision(instanceId, milestoneIndex, client, reasonHash);
    }

    /// @notice Resolve a disputed milestone (after arbitration ruling)
    /// @param instanceId Unique identifier for this milestone instance
    /// @param milestoneIndex Index of the milestone to resolve
    /// @param releaseTobeneficiary True to release, false to refund
    /// @dev Called by Agreement after arbitration ruling
    function actionResolveDispute(bytes32 instanceId, uint256 milestoneIndex, bool releaseTobeneficiary) external {
        MilestoneStorage storage $ = _getStorage();
        require($.status[instanceId] == DISPUTED, "Wrong state");

        uint256 count = $.milestoneCount[instanceId];
        if (milestoneIndex >= count) revert InvalidMilestoneIndex(milestoneIndex, count);

        Milestone storage m = $.milestones[instanceId][milestoneIndex];
        if (m.status != MILESTONE_DISPUTED) {
            revert WrongMilestoneState(MILESTONE_DISPUTED, m.status);
        }

        if (releaseTobeneficiary) {
            m.status = MILESTONE_CONFIRMED;
            m.confirmedAt = block.timestamp;
            emit MilestoneConfirmed(instanceId, milestoneIndex, address(0)); // address(0) = arbitrator
        } else {
            m.status = MILESTONE_REFUNDED;
            emit MilestoneRefunded(instanceId, milestoneIndex);
        }

        // Check if we can return to ACTIVE state (no more disputed milestones)
        bool hasDisputed = false;
        for (uint256 i = 0; i < count; i++) {
            if ($.milestones[instanceId][i].status == MILESTONE_DISPUTED) {
                hasDisputed = true;
                break;
            }
        }
        if (!hasDisputed) {
            $.status[instanceId] = ACTIVE;
        }
    }

    /// @notice Cancel the milestone agreement
    /// @param instanceId Unique identifier for this milestone instance
    /// @dev Can only cancel from PENDING state (before activation)
    /// @custom:papre-style destructive
    function actionCancel(bytes32 instanceId) external {
        MilestoneStorage storage $ = _getStorage();
        require($.status[instanceId] == PENDING, "Wrong state");

        // Either party can cancel before activation
        address client = $.client[instanceId];
        address beneficiary = $.beneficiary[instanceId];
        require(msg.sender == client || msg.sender == beneficiary, "Not a party");

        $.status[instanceId] = CANCELLED;

        emit MilestoneCancelled(instanceId);
    }

    // =============================================================
    // HANDOFF (to next clause)
    // =============================================================

    /// @notice Get total amount released after completion
    /// @param instanceId Unique identifier for this milestone instance
    /// @return Total amount released
    function handoffTotalReleased(bytes32 instanceId) external view returns (uint256) {
        MilestoneStorage storage $ = _getStorage();
        require($.status[instanceId] == COMPLETE, "Wrong state");
        return $.totalReleased[instanceId];
    }

    /// @notice Get beneficiary after completion
    /// @param instanceId Unique identifier for this milestone instance
    /// @return The beneficiary address
    function handoffBeneficiary(bytes32 instanceId) external view returns (address) {
        MilestoneStorage storage $ = _getStorage();
        require($.status[instanceId] == COMPLETE, "Wrong state");
        return $.beneficiary[instanceId];
    }

    /// @notice Get escrow instance ID for a confirmed milestone
    /// @param instanceId Unique identifier for this milestone instance
    /// @param milestoneIndex Index of the milestone
    /// @return The escrow instance ID
    function handoffMilestoneEscrowId(bytes32 instanceId, uint256 milestoneIndex) external view returns (bytes32) {
        MilestoneStorage storage $ = _getStorage();
        // Available when milestone is confirmed (ready for release)
        Milestone storage m = $.milestones[instanceId][milestoneIndex];
        require(m.status == MILESTONE_CONFIRMED, "Wrong milestone state");
        return m.escrowInstanceId;
    }

    // =============================================================
    // QUERIES (always available)
    // =============================================================

    /// @notice Get the current overall state of an instance
    /// @param instanceId Unique identifier for this milestone instance
    /// @return Current state bitmask
    function queryStatus(bytes32 instanceId) external view returns (uint16) {
        return _getStorage().status[instanceId];
    }

    /// @notice Get the beneficiary for an instance
    /// @param instanceId Unique identifier for this milestone instance
    /// @return The beneficiary address
    function queryBeneficiary(bytes32 instanceId) external view returns (address) {
        return _getStorage().beneficiary[instanceId];
    }

    /// @notice Get the client for an instance
    /// @param instanceId Unique identifier for this milestone instance
    /// @return The client address
    function queryClient(bytes32 instanceId) external view returns (address) {
        return _getStorage().client[instanceId];
    }

    /// @notice Get the token for an instance
    /// @param instanceId Unique identifier for this milestone instance
    /// @return The token address (address(0) for ETH)
    function queryToken(bytes32 instanceId) external view returns (address) {
        return _getStorage().token[instanceId];
    }

    /// @notice Get the number of milestones for an instance
    /// @param instanceId Unique identifier for this milestone instance
    /// @return Number of milestones
    function queryMilestoneCount(bytes32 instanceId) external view returns (uint256) {
        return _getStorage().milestoneCount[instanceId];
    }

    /// @notice Get a milestone by index
    /// @param instanceId Unique identifier for this milestone instance
    /// @param milestoneIndex Index of the milestone
    /// @return descriptionHash Hash of milestone description
    /// @return amount Amount for this milestone
    /// @return escrowInstanceId Linked escrow instance
    /// @return status Per-milestone status
    /// @return confirmedAt Confirmation timestamp
    /// @return releasedAt Release timestamp
    function queryMilestone(bytes32 instanceId, uint256 milestoneIndex)
        external
        view
        returns (
            bytes32 descriptionHash,
            uint256 amount,
            bytes32 escrowInstanceId,
            uint8 status,
            uint256 confirmedAt,
            uint256 releasedAt
        )
    {
        MilestoneStorage storage $ = _getStorage();
        Milestone storage m = $.milestones[instanceId][milestoneIndex];
        return (m.descriptionHash, m.amount, m.escrowInstanceId, m.status, m.confirmedAt, m.releasedAt);
    }

    /// @notice Get the status of a specific milestone
    /// @param instanceId Unique identifier for this milestone instance
    /// @param milestoneIndex Index of the milestone
    /// @return Per-milestone status
    function queryMilestoneStatus(bytes32 instanceId, uint256 milestoneIndex) external view returns (uint8) {
        return _getStorage().milestones[instanceId][milestoneIndex].status;
    }

    /// @notice Get the escrow instance ID for a milestone
    /// @param instanceId Unique identifier for this milestone instance
    /// @param milestoneIndex Index of the milestone
    /// @return The escrow instance ID
    function queryMilestoneEscrowId(bytes32 instanceId, uint256 milestoneIndex) external view returns (bytes32) {
        return _getStorage().milestones[instanceId][milestoneIndex].escrowInstanceId;
    }

    /// @notice Get the number of released milestones
    /// @param instanceId Unique identifier for this milestone instance
    /// @return Number of released milestones
    function queryReleasedCount(bytes32 instanceId) external view returns (uint256) {
        return _getStorage().releasedCount[instanceId];
    }

    /// @notice Get the total amount released so far
    /// @param instanceId Unique identifier for this milestone instance
    /// @return Total amount released
    function queryTotalReleased(bytes32 instanceId) external view returns (uint256) {
        return _getStorage().totalReleased[instanceId];
    }

    /// @notice Get the total amount across all milestones
    /// @param instanceId Unique identifier for this milestone instance
    /// @return Total amount
    function queryTotalAmount(bytes32 instanceId) external view returns (uint256) {
        MilestoneStorage storage $ = _getStorage();
        uint256 count = $.milestoneCount[instanceId];
        uint256 total = 0;
        for (uint256 i = 0; i < count; i++) {
            total += $.milestones[instanceId][i].amount;
        }
        return total;
    }

    /// @notice Check if the milestone instance is active
    /// @param instanceId Unique identifier for this milestone instance
    /// @return True if in ACTIVE state
    function queryIsActive(bytes32 instanceId) external view returns (bool) {
        return _getStorage().status[instanceId] == ACTIVE;
    }

    /// @notice Check if the milestone instance is complete
    /// @param instanceId Unique identifier for this milestone instance
    /// @return True if in COMPLETE state
    function queryIsComplete(bytes32 instanceId) external view returns (bool) {
        return _getStorage().status[instanceId] == COMPLETE;
    }

    /// @notice Check if the milestone instance is disputed
    /// @param instanceId Unique identifier for this milestone instance
    /// @return True if in DISPUTED state
    function queryIsDisputed(bytes32 instanceId) external view returns (bool) {
        return _getStorage().status[instanceId] == DISPUTED;
    }

    /// @notice Check if a milestone is ready for release
    /// @param instanceId Unique identifier for this milestone instance
    /// @param milestoneIndex Index of the milestone
    /// @return True if milestone is in CONFIRMED state
    function queryIsMilestoneReadyForRelease(bytes32 instanceId, uint256 milestoneIndex) external view returns (bool) {
        return _getStorage().milestones[instanceId][milestoneIndex].status == MILESTONE_CONFIRMED;
    }
}
