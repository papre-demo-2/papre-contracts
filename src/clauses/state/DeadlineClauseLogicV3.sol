// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ClauseBase} from "../../base/ClauseBase.sol";

/// @title DeadlineClauseLogicV3
/// @notice Self-describing deadline management clause following v3 specification
/// @dev Logic contract executed via delegatecall from Agreement proxies.
///      Uses ERC-7201 namespaced storage to prevent collisions with other clauses.
///
///      This clause stores deadline configurations separately from the clauses
///      they govern (e.g., milestones). This follows the adapter pattern where
///      clauses are "pure lego bricks" - they don't need modification to add
///      deadline functionality.
///
///      DESIGN PHILOSOPHY:
///      Rather than modifying MilestoneClauseLogicV3 to add deadline fields,
///      we create a separate clause that owns deadline data. This allows:
///      - Adding deadlines to any milestone-based workflow
///      - Future reuse for non-milestone contexts
///      - Clean separation of concerns
///
///      ADAPTER INTEGRATION:
///      This clause works with DeadlineEnforcementAdapter which orchestrates:
///      1. Check deadline expiry (this clause)
///      2. Execute appropriate action on MilestoneClause
///      3. Execute corresponding Escrow action
///      4. Mark deadline as enforced (this clause)
///
///      State Machine (per deadline):
///      ┌────────────────┐
///      │    NOT SET     │ ← deadline.deadline == 0
///      └───────┬────────┘
///              │ intakeSetDeadline()
///              ▼
///      ┌────────────────┐
///      │     ACTIVE     │ ← deadline set, not enforced
///      └───────┬────────┘
///              │ block.timestamp >= deadline
///              ▼
///      ┌────────────────┐
///      │    EXPIRED     │ ← can be enforced
///      └───────┬────────┘
///              │ actionMarkEnforced()
///              ▼
///      ┌────────────────┐
///      │   ENFORCED     │ ← terminal state
///      └────────────────┘
///
///      Actions:
///      - RELEASE (1): Auto-confirm and release to beneficiary
///      - REFUND (2): Auto-refund to depositor/client
contract DeadlineClauseLogicV3 is ClauseBase {
    // =============================================================
    // CONSTANTS
    // =============================================================

    /// @notice No deadline set
    uint8 public constant ACTION_NONE = 0;

    /// @notice On expiry, release to beneficiary
    uint8 public constant ACTION_RELEASE = 1;

    /// @notice On expiry, refund to depositor/client
    uint8 public constant ACTION_REFUND = 2;

    // =============================================================
    // ERRORS
    // =============================================================

    error DeadlineNotSet();
    error DeadlineAlreadySet();
    error DeadlineNotExpired(uint256 deadline, uint256 currentTime);
    error DeadlineAlreadyEnforced();
    error InvalidDeadline(uint256 deadline);
    error InvalidAction(uint8 action);
    error DeadlineInPast(uint256 deadline, uint256 currentTime);
    error DeadlineImmutable();
    error OnlyController(address caller, address controller);

    // =============================================================
    // EVENTS
    // =============================================================

    /// @notice Emitted when a deadline is set
    event DeadlineSet(
        bytes32 indexed targetInstanceId,
        uint256 indexed targetIndex,
        uint256 deadline,
        uint8 action,
        address controller
    );

    /// @notice Emitted when a deadline is modified
    event DeadlineModified(
        bytes32 indexed targetInstanceId, uint256 indexed targetIndex, uint256 deadline, uint8 action, address modifier_
    );

    /// @notice Emitted when a deadline is marked as enforced
    event DeadlineEnforced(bytes32 indexed targetInstanceId, uint256 indexed targetIndex, uint8 action);

    /// @notice Emitted when a deadline is cleared (before enforcement)
    event DeadlineCleared(bytes32 indexed targetInstanceId, uint256 indexed targetIndex);

    // =============================================================
    // STRUCTS
    // =============================================================

    /// @notice Configuration for a single deadline
    struct DeadlineConfig {
        uint256 deadline; // Unix timestamp (0 = not set)
        uint8 action; // ACTION_RELEASE or ACTION_REFUND
        bool enforced; // Has this deadline been enforced?
        address controller; // Who can modify (address(0) = immutable after set)
    }

    // =============================================================
    // ERC-7201 NAMESPACED STORAGE
    // =============================================================

    /// @custom:storage-location erc7201:papre.clause.deadline.storage
    struct DeadlineStorage {
        /// @notice (targetInstanceId, targetIndex) => deadline configuration
        /// @dev targetInstanceId is the milestone instance, targetIndex is milestone index
        mapping(bytes32 => mapping(uint256 => DeadlineConfig)) deadlines;
    }

    // keccak256(abi.encode(uint256(keccak256("papre.clause.deadline.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT = 0x16ee529f32ee135eb9b99f509138cc2138f9b8bf166ce61d75f9664dfe6bc600;

    function _getStorage() internal pure returns (DeadlineStorage storage $) {
        assembly {
            $.slot := STORAGE_SLOT
        }
    }

    // =============================================================
    // INTAKE (setup)
    // =============================================================

    /// @notice Set a deadline for a target (e.g., milestone) - FIRST TIME ONLY
    /// @param targetInstanceId The instance ID of the target (e.g., milestone instance)
    /// @param targetIndex The index within the target (e.g., milestone index)
    /// @param deadline Unix timestamp when the deadline expires
    /// @param action What to do when deadline expires (ACTION_RELEASE or ACTION_REFUND)
    /// @param controller Who can modify this deadline (address(0) = immutable)
    /// @dev Reverts if deadline already set. Use intakeModifyDeadline to change existing.
    ///      The controller address determines who can modify:
    ///      - address(0): No one can modify (immutable)
    ///      - Single address: Only that address can modify
    ///      - Multisig address: Requires multi-party approval to modify
    function intakeSetDeadline(
        bytes32 targetInstanceId,
        uint256 targetIndex,
        uint256 deadline,
        uint8 action,
        address controller
    ) external {
        if (deadline == 0) revert InvalidDeadline(deadline);
        if (deadline <= block.timestamp) revert DeadlineInPast(deadline, block.timestamp);
        if (action != ACTION_RELEASE && action != ACTION_REFUND) revert InvalidAction(action);

        DeadlineStorage storage $ = _getStorage();
        DeadlineConfig storage config = $.deadlines[targetInstanceId][targetIndex];

        // Cannot set if already set - use intakeModifyDeadline instead
        if (config.deadline != 0) revert DeadlineAlreadySet();

        config.deadline = deadline;
        config.action = action;
        config.controller = controller;

        emit DeadlineSet(targetInstanceId, targetIndex, deadline, action, controller);
    }

    /// @notice Modify an existing deadline
    /// @param targetInstanceId The instance ID of the target
    /// @param targetIndex The index within the target
    /// @param newDeadline New unix timestamp (must be in future)
    /// @param newAction New action (ACTION_RELEASE or ACTION_REFUND)
    /// @dev Only callable by the controller set during intakeSetDeadline.
    ///      If controller is address(0), deadline is immutable and cannot be modified.
    function intakeModifyDeadline(bytes32 targetInstanceId, uint256 targetIndex, uint256 newDeadline, uint8 newAction)
        external
    {
        if (newDeadline == 0) revert InvalidDeadline(newDeadline);
        if (newDeadline <= block.timestamp) revert DeadlineInPast(newDeadline, block.timestamp);
        if (newAction != ACTION_RELEASE && newAction != ACTION_REFUND) revert InvalidAction(newAction);

        DeadlineStorage storage $ = _getStorage();
        DeadlineConfig storage config = $.deadlines[targetInstanceId][targetIndex];

        if (config.deadline == 0) revert DeadlineNotSet();
        if (config.enforced) revert DeadlineAlreadyEnforced();
        if (config.controller == address(0)) revert DeadlineImmutable();
        if (msg.sender != config.controller) revert OnlyController(msg.sender, config.controller);

        config.deadline = newDeadline;
        config.action = newAction;

        emit DeadlineModified(targetInstanceId, targetIndex, newDeadline, newAction, msg.sender);
    }

    /// @notice Clear a deadline (before enforcement)
    /// @param targetInstanceId The instance ID of the target
    /// @param targetIndex The index within the target
    /// @dev Only callable by the controller. Immutable deadlines cannot be cleared.
    function intakeClearDeadline(bytes32 targetInstanceId, uint256 targetIndex) external {
        DeadlineStorage storage $ = _getStorage();
        DeadlineConfig storage config = $.deadlines[targetInstanceId][targetIndex];

        if (config.deadline == 0) revert DeadlineNotSet();
        if (config.enforced) revert DeadlineAlreadyEnforced();
        if (config.controller == address(0)) revert DeadlineImmutable();
        if (msg.sender != config.controller) revert OnlyController(msg.sender, config.controller);

        config.deadline = 0;
        config.action = ACTION_NONE;
        config.controller = address(0);

        emit DeadlineCleared(targetInstanceId, targetIndex);
    }

    // =============================================================
    // ACTIONS (state-changing)
    // =============================================================

    /// @notice Mark a deadline as enforced
    /// @param targetInstanceId The instance ID of the target
    /// @param targetIndex The index within the target
    /// @dev Called by adapter after successfully executing the deadline action
    ///      Caller is responsible for verifying deadline is expired before calling
    function actionMarkEnforced(bytes32 targetInstanceId, uint256 targetIndex) external {
        DeadlineStorage storage $ = _getStorage();
        DeadlineConfig storage config = $.deadlines[targetInstanceId][targetIndex];

        if (config.deadline == 0) revert DeadlineNotSet();
        if (config.enforced) revert DeadlineAlreadyEnforced();
        if (block.timestamp < config.deadline) {
            revert DeadlineNotExpired(config.deadline, block.timestamp);
        }

        config.enforced = true;

        emit DeadlineEnforced(targetInstanceId, targetIndex, config.action);
    }

    // =============================================================
    // QUERIES (always available)
    // =============================================================

    /// @notice Get the full deadline configuration
    /// @param targetInstanceId The instance ID of the target
    /// @param targetIndex The index within the target
    /// @return deadline Unix timestamp (0 if not set)
    /// @return action ACTION_RELEASE, ACTION_REFUND, or ACTION_NONE
    /// @return enforced Whether the deadline has been enforced
    /// @return controller Who can modify (address(0) = immutable)
    function queryDeadline(bytes32 targetInstanceId, uint256 targetIndex)
        external
        view
        returns (uint256 deadline, uint8 action, bool enforced, address controller)
    {
        DeadlineStorage storage $ = _getStorage();
        DeadlineConfig storage config = $.deadlines[targetInstanceId][targetIndex];
        return (config.deadline, config.action, config.enforced, config.controller);
    }

    /// @notice Get the controller address for a deadline
    /// @param targetInstanceId The instance ID of the target
    /// @param targetIndex The index within the target
    /// @return controller The address that can modify this deadline (address(0) = immutable)
    function queryController(bytes32 targetInstanceId, uint256 targetIndex) external view returns (address) {
        return _getStorage().deadlines[targetInstanceId][targetIndex].controller;
    }

    /// @notice Check if a deadline is immutable (cannot be modified)
    /// @param targetInstanceId The instance ID of the target
    /// @param targetIndex The index within the target
    /// @return True if deadline is set and controller is address(0)
    function queryIsImmutable(bytes32 targetInstanceId, uint256 targetIndex) external view returns (bool) {
        DeadlineStorage storage $ = _getStorage();
        DeadlineConfig storage config = $.deadlines[targetInstanceId][targetIndex];
        return config.deadline != 0 && config.controller == address(0);
    }

    /// @notice Check if a deadline is set
    /// @param targetInstanceId The instance ID of the target
    /// @param targetIndex The index within the target
    /// @return True if deadline is set (non-zero)
    function queryIsSet(bytes32 targetInstanceId, uint256 targetIndex) external view returns (bool) {
        return _getStorage().deadlines[targetInstanceId][targetIndex].deadline != 0;
    }

    /// @notice Check if a deadline has expired
    /// @param targetInstanceId The instance ID of the target
    /// @param targetIndex The index within the target
    /// @return True if deadline is set and current time >= deadline
    function queryIsExpired(bytes32 targetInstanceId, uint256 targetIndex) external view returns (bool) {
        DeadlineStorage storage $ = _getStorage();
        uint256 deadline = $.deadlines[targetInstanceId][targetIndex].deadline;
        return deadline != 0 && block.timestamp >= deadline;
    }

    /// @notice Check if a deadline has been enforced
    /// @param targetInstanceId The instance ID of the target
    /// @param targetIndex The index within the target
    /// @return True if deadline was enforced
    function queryIsEnforced(bytes32 targetInstanceId, uint256 targetIndex) external view returns (bool) {
        return _getStorage().deadlines[targetInstanceId][targetIndex].enforced;
    }

    /// @notice Check if a deadline can be enforced right now
    /// @param targetInstanceId The instance ID of the target
    /// @param targetIndex The index within the target
    /// @return True if deadline is set, expired, and not yet enforced
    function queryCanEnforce(bytes32 targetInstanceId, uint256 targetIndex) external view returns (bool) {
        DeadlineStorage storage $ = _getStorage();
        DeadlineConfig storage config = $.deadlines[targetInstanceId][targetIndex];
        return config.deadline != 0 && block.timestamp >= config.deadline && !config.enforced;
    }

    /// @notice Get the configured action for a deadline
    /// @param targetInstanceId The instance ID of the target
    /// @param targetIndex The index within the target
    /// @return action ACTION_RELEASE, ACTION_REFUND, or ACTION_NONE
    function queryAction(bytes32 targetInstanceId, uint256 targetIndex) external view returns (uint8) {
        return _getStorage().deadlines[targetInstanceId][targetIndex].action;
    }

    /// @notice Get time remaining until deadline (0 if expired or not set)
    /// @param targetInstanceId The instance ID of the target
    /// @param targetIndex The index within the target
    /// @return Time in seconds until deadline, 0 if expired or not set
    function queryTimeRemaining(bytes32 targetInstanceId, uint256 targetIndex) external view returns (uint256) {
        DeadlineStorage storage $ = _getStorage();
        uint256 deadline = $.deadlines[targetInstanceId][targetIndex].deadline;
        if (deadline == 0 || block.timestamp >= deadline) {
            return 0;
        }
        return deadline - block.timestamp;
    }
}
