// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ClauseBase} from "../../base/ClauseBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title StreamingClauseLogicV3
/// @notice Clause for continuous payment streaming with rate per second (Sablier-like)
/// @dev Logic contract executed via delegatecall from Agreement proxies.
///      Uses ERC-7201 namespaced storage to prevent collisions with other clauses.
///      All functions take instanceId as first parameter for multi-instance support.
///
///      STREAMING MODEL:
///      Funds are deposited upfront and stream continuously to the recipient.
///      The recipient can claim accrued funds at any time. The claimable amount
///      is calculated in real-time based on elapsed time since start:
///        streamed = ratePerSecond × elapsed
///        claimable = streamed - alreadyClaimed
///
///      REAL-WORLD USE CASES:
///      - Monthly retainer payments (contractor can claim daily/weekly)
///      - Salary streaming (employees claim whenever needed)
///      - Subscription services with continuous access
///
///      State Machine:
///      ┌────────────────┐
///      │  CONFIGURING   │ ← intake*() calls
///      │    (status=0)  │
///      └───────┬────────┘
///              │ intakeReady()
///              ▼
///      ┌────────────────┐
///      │    PENDING     │ ← Awaiting deposit
///      │   (0x0002)     │
///      └───────┬────────┘
///              │ actionDeposit() [payable for ETH]
///              ▼
///      ┌────────────────┐
///      │   STREAMING    │ ← Active stream, can claim or cancel
///      │   (0x0004)     │
///      └───┬─────────┬──┘
///          │         │
///       complete   cancel
///       (all claimed) │
///          │         │
///          ▼         ▼
///      ┌────────┐ ┌──────────┐
///      │COMPLETE│ │CANCELLED │ ← Remaining split between parties
///      │(0x0008)│ │ (0x0010) │
///      └────────┘ └──────────┘
contract StreamingClauseLogicV3 is ClauseBase {
    using SafeERC20 for IERC20;

    // =============================================================
    // CONSTANTS
    // =============================================================

    /// @notice ETH is represented by address(0)
    address public constant ETH = address(0);

    // =============================================================
    // EXTENDED STATES (bitmask)
    // =============================================================

    // CONFIGURING = 0 (implicit - before intakeReady)
    // PENDING = 0x0002 (from ClauseBase) - awaiting deposit
    uint16 internal constant STREAMING = 1 << 2;     // 0x0004 - actively streaming
    uint16 internal constant COMPLETED = 1 << 3;     // 0x0008 - all funds claimed
    uint16 internal constant STREAM_CANCELLED = 1 << 4;  // 0x0010 - cancelled with split

    // =============================================================
    // ERRORS
    // =============================================================

    error WrongState(uint16 expected, uint16 actual);
    error ZeroAddress();
    error ZeroAmount();
    error InvalidRate();
    error InvalidStartTime();
    error InsufficientDeposit(uint256 required, uint256 provided);
    error NotSender(address caller, address sender);
    error NotRecipient(address caller, address recipient);
    error NotSenderOrRecipient(address caller);
    error NothingToClaim();
    error InsufficientAvailable(uint256 requested, uint256 available);
    error StreamAlreadyFinished();
    error TransferFailed();

    // =============================================================
    // EVENTS
    // =============================================================

    event StreamConfigured(
        bytes32 indexed instanceId,
        address indexed sender,
        address indexed recipient,
        address token,
        uint256 deposit,
        uint256 ratePerSecond
    );

    event StreamStarted(
        bytes32 indexed instanceId,
        address indexed sender,
        uint256 deposit,
        uint48 startTime,
        uint48 stopTime
    );

    event TokensClaimed(
        bytes32 indexed instanceId,
        address indexed recipient,
        uint256 amount,
        uint256 totalClaimed
    );

    event StreamCancelled(
        bytes32 indexed instanceId,
        address indexed cancelledBy,
        uint256 toRecipient,
        uint256 toSender
    );

    event StreamCompleted(
        bytes32 indexed instanceId,
        address indexed recipient,
        uint256 totalAmount
    );

    // =============================================================
    // ERC-7201 NAMESPACED STORAGE
    // =============================================================

    /// @custom:storage-location erc7201:papre.clause.streaming.storage
    struct StreamingStorage {
        /// @notice instanceId => clause state
        mapping(bytes32 => uint16) status;
        /// @notice instanceId => sender (depositor) address
        mapping(bytes32 => address) sender;
        /// @notice instanceId => recipient (beneficiary) address
        mapping(bytes32 => address) recipient;
        /// @notice instanceId => token address (address(0) for ETH)
        mapping(bytes32 => address) token;
        /// @notice instanceId => total deposit amount
        mapping(bytes32 => uint256) deposit;
        /// @notice instanceId => streaming rate per second
        mapping(bytes32 => uint256) ratePerSecond;
        /// @notice instanceId => amount already withdrawn by recipient
        mapping(bytes32 => uint256) withdrawn;
        /// @notice instanceId => stream start timestamp
        mapping(bytes32 => uint48) startTime;
        /// @notice instanceId => stream stop timestamp (calculated)
        mapping(bytes32 => uint48) stopTime;
        /// @notice instanceId => timestamp when cancelled (0 if not cancelled)
        mapping(bytes32 => uint48) cancelledAt;
        /// @notice instanceId => who cancelled the stream
        mapping(bytes32 => address) cancelledBy;
    }

    // keccak256(abi.encode(uint256(keccak256("papre.clause.streaming.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT =
        0x7d3e8f2a1b4c5d6e9f0a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0b9c8d00;

    function _getStorage() internal pure returns (StreamingStorage storage $) {
        assembly {
            $.slot := STORAGE_SLOT
        }
    }

    // =============================================================
    // INTAKE (configuration phase)
    // =============================================================

    /// @notice Set the sender (depositor) for this stream instance
    /// @param instanceId Unique identifier for this stream instance
    /// @param _sender Address that will deposit funds
    function intakeSender(bytes32 instanceId, address _sender) external {
        if (_sender == address(0)) revert ZeroAddress();
        StreamingStorage storage $ = _getStorage();
        require($.status[instanceId] == 0, "Wrong state");
        $.sender[instanceId] = _sender;
    }

    /// @notice Set the recipient (beneficiary) for this stream instance
    /// @param instanceId Unique identifier for this stream instance
    /// @param _recipient Address that will receive streamed funds
    function intakeRecipient(bytes32 instanceId, address _recipient) external {
        if (_recipient == address(0)) revert ZeroAddress();
        StreamingStorage storage $ = _getStorage();
        require($.status[instanceId] == 0, "Wrong state");
        $.recipient[instanceId] = _recipient;
    }

    /// @notice Set the token for this stream instance
    /// @param instanceId Unique identifier for this stream instance
    /// @param _token Token address (address(0) for ETH)
    function intakeToken(bytes32 instanceId, address _token) external {
        StreamingStorage storage $ = _getStorage();
        require($.status[instanceId] == 0, "Wrong state");
        $.token[instanceId] = _token;
    }

    /// @notice Set the deposit amount for this stream instance
    /// @param instanceId Unique identifier for this stream instance
    /// @param _deposit Total amount to be streamed
    function intakeDeposit(bytes32 instanceId, uint256 _deposit) external {
        if (_deposit == 0) revert ZeroAmount();
        StreamingStorage storage $ = _getStorage();
        require($.status[instanceId] == 0, "Wrong state");
        $.deposit[instanceId] = _deposit;
    }

    /// @notice Set the streaming rate per second
    /// @param instanceId Unique identifier for this stream instance
    /// @param _ratePerSecond Amount streamed per second
    /// @dev stopTime will be calculated as: startTime + (deposit / ratePerSecond)
    function intakeRatePerSecond(bytes32 instanceId, uint256 _ratePerSecond) external {
        if (_ratePerSecond == 0) revert InvalidRate();
        StreamingStorage storage $ = _getStorage();
        require($.status[instanceId] == 0, "Wrong state");
        $.ratePerSecond[instanceId] = _ratePerSecond;
    }

    /// @notice Set the stream start time
    /// @param instanceId Unique identifier for this stream instance
    /// @param _startTime Unix timestamp when streaming begins
    /// @dev Can be in the future for delayed start
    function intakeStartTime(bytes32 instanceId, uint48 _startTime) external {
        if (_startTime == 0) revert InvalidStartTime();
        StreamingStorage storage $ = _getStorage();
        require($.status[instanceId] == 0, "Wrong state");
        $.startTime[instanceId] = _startTime;
    }

    /// @notice Finalize configuration and transition to PENDING
    /// @param instanceId Unique identifier for this stream instance
    /// @dev Requires sender, recipient, deposit, and ratePerSecond to be set.
    ///      If startTime is not set, defaults to current block timestamp.
    ///      Calculates stopTime based on deposit / ratePerSecond.
    function intakeReady(bytes32 instanceId) external {
        StreamingStorage storage $ = _getStorage();
        require($.status[instanceId] == 0, "Wrong state");
        require($.sender[instanceId] != address(0), "No sender");
        require($.recipient[instanceId] != address(0), "No recipient");
        require($.deposit[instanceId] > 0, "No deposit");
        require($.ratePerSecond[instanceId] > 0, "No rate");

        // Default startTime to now if not set
        if ($.startTime[instanceId] == 0) {
            $.startTime[instanceId] = uint48(block.timestamp);
        }

        // Calculate stopTime: startTime + (deposit / ratePerSecond)
        uint256 duration = $.deposit[instanceId] / $.ratePerSecond[instanceId];
        $.stopTime[instanceId] = $.startTime[instanceId] + uint48(duration);

        $.status[instanceId] = PENDING;

        emit StreamConfigured(
            instanceId,
            $.sender[instanceId],
            $.recipient[instanceId],
            $.token[instanceId],
            $.deposit[instanceId],
            $.ratePerSecond[instanceId]
        );
    }

    // =============================================================
    // ACTIONS (state-changing)
    // =============================================================

    /// @notice Deposit funds to start the stream
    /// @param instanceId Unique identifier for this stream instance
    /// @dev For ETH: send msg.value. For ERC20: approve first, then call.
    ///      Must be called by the designated sender.
    /// @custom:papre-style primary
    function actionDeposit(bytes32 instanceId) external payable {
        StreamingStorage storage $ = _getStorage();
        require($.status[instanceId] == PENDING, "Wrong state");

        address sender = $.sender[instanceId];
        if (msg.sender != sender) revert NotSender(msg.sender, sender);

        address token = $.token[instanceId];
        uint256 requiredDeposit = $.deposit[instanceId];

        if (token == ETH) {
            if (msg.value < requiredDeposit) {
                revert InsufficientDeposit(requiredDeposit, msg.value);
            }
            // Refund excess
            if (msg.value > requiredDeposit) {
                (bool success,) = msg.sender.call{value: msg.value - requiredDeposit}("");
                if (!success) revert TransferFailed();
            }
        } else {
            IERC20(token).safeTransferFrom(msg.sender, address(this), requiredDeposit);
        }

        $.status[instanceId] = STREAMING;

        emit StreamStarted(
            instanceId,
            sender,
            requiredDeposit,
            $.startTime[instanceId],
            $.stopTime[instanceId]
        );
    }

    /// @notice Claim streamed tokens (recipient only)
    /// @param instanceId Unique identifier for this stream instance
    /// @param amount Amount to claim (0 = claim all available)
    /// @return claimed The amount actually claimed
    /// @custom:papre-style primary
    function actionClaim(bytes32 instanceId, uint256 amount) external returns (uint256 claimed) {
        StreamingStorage storage $ = _getStorage();
        require($.status[instanceId] == STREAMING, "Wrong state");

        address recipient = $.recipient[instanceId];
        if (msg.sender != recipient) revert NotRecipient(msg.sender, recipient);

        // Calculate available
        uint256 streamed = _calculateStreamed($, instanceId);
        uint256 available = streamed - $.withdrawn[instanceId];

        if (available == 0) revert NothingToClaim();

        // If amount is 0, claim all available
        claimed = amount == 0 ? available : amount;

        if (claimed > available) {
            revert InsufficientAvailable(claimed, available);
        }

        // Update state
        $.withdrawn[instanceId] += claimed;

        // Check if stream is complete
        if ($.withdrawn[instanceId] >= $.deposit[instanceId]) {
            $.status[instanceId] = COMPLETED;
            emit StreamCompleted(instanceId, recipient, $.deposit[instanceId]);
        }

        // Transfer tokens
        _transfer($.token[instanceId], recipient, claimed);

        emit TokensClaimed(instanceId, recipient, claimed, $.withdrawn[instanceId]);

        return claimed;
    }

    /// @notice Cancel stream and split funds
    /// @param instanceId Unique identifier for this stream instance
    /// @dev Either sender or recipient can cancel.
    ///      Recipient receives streamed-but-unclaimed amount.
    ///      Sender receives unstreamed amount.
    /// @return toRecipient Amount sent to recipient
    /// @return toSender Amount refunded to sender
    /// @custom:papre-style destructive
    function actionCancel(bytes32 instanceId) external returns (uint256 toRecipient, uint256 toSender) {
        StreamingStorage storage $ = _getStorage();
        require($.status[instanceId] == STREAMING, "Wrong state");

        address sender = $.sender[instanceId];
        address recipient = $.recipient[instanceId];

        if (msg.sender != sender && msg.sender != recipient) {
            revert NotSenderOrRecipient(msg.sender);
        }

        // Check if stream already finished (all funds streamed)
        if (block.timestamp >= $.stopTime[instanceId]) {
            revert StreamAlreadyFinished();
        }

        // Calculate split
        uint256 streamed = _calculateStreamed($, instanceId);
        uint256 alreadyWithdrawn = $.withdrawn[instanceId];

        // Recipient gets: streamed - already withdrawn
        toRecipient = streamed - alreadyWithdrawn;

        // Sender gets: total - streamed
        toSender = $.deposit[instanceId] - streamed;

        // Update state
        $.status[instanceId] = STREAM_CANCELLED;
        $.cancelledAt[instanceId] = uint48(block.timestamp);
        $.cancelledBy[instanceId] = msg.sender;

        address token = $.token[instanceId];

        // Transfer to recipient
        if (toRecipient > 0) {
            _transfer(token, recipient, toRecipient);
        }

        // Refund to sender
        if (toSender > 0) {
            _transfer(token, sender, toSender);
        }

        emit StreamCancelled(instanceId, msg.sender, toRecipient, toSender);

        return (toRecipient, toSender);
    }

    // =============================================================
    // HANDOFF (to next clause)
    // =============================================================

    /// @notice Get the total amount after stream completion
    /// @param instanceId Unique identifier for this stream instance
    /// @return The total streamed amount
    function handoffAmount(bytes32 instanceId) external view returns (uint256) {
        StreamingStorage storage $ = _getStorage();
        require($.status[instanceId] == COMPLETED, "Wrong state");
        return $.deposit[instanceId];
    }

    /// @notice Get the recipient after stream completion
    /// @param instanceId Unique identifier for this stream instance
    /// @return The recipient address
    function handoffRecipient(bytes32 instanceId) external view returns (address) {
        StreamingStorage storage $ = _getStorage();
        require($.status[instanceId] == COMPLETED, "Wrong state");
        return $.recipient[instanceId];
    }

    /// @notice Get the cancellation split
    /// @param instanceId Unique identifier for this stream instance
    /// @return toRecipient Amount sent to recipient
    /// @return toSender Amount refunded to sender
    function handoffCancellationSplit(bytes32 instanceId) external view returns (uint256 toRecipient, uint256 toSender) {
        StreamingStorage storage $ = _getStorage();
        require($.status[instanceId] == STREAM_CANCELLED, "Wrong state");

        uint256 streamed = _calculateStreamedAt($, instanceId, $.cancelledAt[instanceId]);
        uint256 alreadyWithdrawn = $.withdrawn[instanceId];

        toRecipient = streamed - alreadyWithdrawn;
        toSender = $.deposit[instanceId] - streamed;
    }

    // =============================================================
    // QUERIES (always available)
    // =============================================================

    /// @notice Get the current status of an instance
    /// @param instanceId Unique identifier for this stream instance
    /// @return Current status bitmask
    function queryStatus(bytes32 instanceId) external view returns (uint16) {
        return _getStorage().status[instanceId];
    }

    /// @notice Get the sender for an instance
    /// @param instanceId Unique identifier for this stream instance
    /// @return The sender address
    function querySender(bytes32 instanceId) external view returns (address) {
        return _getStorage().sender[instanceId];
    }

    /// @notice Get the recipient for an instance
    /// @param instanceId Unique identifier for this stream instance
    /// @return The recipient address
    function queryRecipient(bytes32 instanceId) external view returns (address) {
        return _getStorage().recipient[instanceId];
    }

    /// @notice Get the token for an instance
    /// @param instanceId Unique identifier for this stream instance
    /// @return The token address (address(0) for ETH)
    function queryToken(bytes32 instanceId) external view returns (address) {
        return _getStorage().token[instanceId];
    }

    /// @notice Get the total deposit amount
    /// @param instanceId Unique identifier for this stream instance
    /// @return The total deposit
    function queryDeposit(bytes32 instanceId) external view returns (uint256) {
        return _getStorage().deposit[instanceId];
    }

    /// @notice Get the streaming rate per second
    /// @param instanceId Unique identifier for this stream instance
    /// @return The rate per second
    function queryRatePerSecond(bytes32 instanceId) external view returns (uint256) {
        return _getStorage().ratePerSecond[instanceId];
    }

    /// @notice Get the amount already withdrawn
    /// @param instanceId Unique identifier for this stream instance
    /// @return The withdrawn amount
    function queryWithdrawn(bytes32 instanceId) external view returns (uint256) {
        return _getStorage().withdrawn[instanceId];
    }

    /// @notice Get the start time
    /// @param instanceId Unique identifier for this stream instance
    /// @return The start timestamp
    function queryStartTime(bytes32 instanceId) external view returns (uint48) {
        return _getStorage().startTime[instanceId];
    }

    /// @notice Get the stop time
    /// @param instanceId Unique identifier for this stream instance
    /// @return The stop timestamp
    function queryStopTime(bytes32 instanceId) external view returns (uint48) {
        return _getStorage().stopTime[instanceId];
    }

    /// @notice Get the total amount streamed so far (real-time)
    /// @param instanceId Unique identifier for this stream instance
    /// @return The streamed amount
    function queryStreamed(bytes32 instanceId) external view returns (uint256) {
        StreamingStorage storage $ = _getStorage();
        return _calculateStreamed($, instanceId);
    }

    /// @notice Get the available (claimable) amount (real-time)
    /// @param instanceId Unique identifier for this stream instance
    /// @return The available amount to claim
    function queryAvailable(bytes32 instanceId) external view returns (uint256) {
        StreamingStorage storage $ = _getStorage();
        uint256 streamed = _calculateStreamed($, instanceId);
        uint256 withdrawn = $.withdrawn[instanceId];
        return streamed > withdrawn ? streamed - withdrawn : 0;
    }

    /// @notice Get remaining time until stream ends
    /// @param instanceId Unique identifier for this stream instance
    /// @return Seconds remaining (0 if ended or not started)
    function queryRemainingTime(bytes32 instanceId) external view returns (uint256) {
        StreamingStorage storage $ = _getStorage();
        uint48 stopTime = $.stopTime[instanceId];
        if (block.timestamp >= stopTime) return 0;
        return stopTime - block.timestamp;
    }

    /// @notice Get remaining amount to be streamed
    /// @param instanceId Unique identifier for this stream instance
    /// @return Amount not yet streamed
    function queryRemainingAmount(bytes32 instanceId) external view returns (uint256) {
        StreamingStorage storage $ = _getStorage();
        uint256 streamed = _calculateStreamed($, instanceId);
        uint256 deposit = $.deposit[instanceId];
        return deposit > streamed ? deposit - streamed : 0;
    }

    /// @notice Check if stream is currently active
    /// @param instanceId Unique identifier for this stream instance
    /// @return True if in STREAMING state
    function queryIsStreaming(bytes32 instanceId) external view returns (bool) {
        return _getStorage().status[instanceId] == STREAMING;
    }

    /// @notice Check if stream is complete
    /// @param instanceId Unique identifier for this stream instance
    /// @return True if in COMPLETED state
    function queryIsComplete(bytes32 instanceId) external view returns (bool) {
        return _getStorage().status[instanceId] == COMPLETED;
    }

    /// @notice Check if stream is cancelled
    /// @param instanceId Unique identifier for this stream instance
    /// @return True if in STREAM_CANCELLED state
    function queryIsCancelled(bytes32 instanceId) external view returns (bool) {
        return _getStorage().status[instanceId] == STREAM_CANCELLED;
    }

    /// @notice Get cancellation details
    /// @param instanceId Unique identifier for this stream instance
    /// @return cancelledAt Timestamp when cancelled (0 if not cancelled)
    /// @return cancelledBy Address that cancelled (address(0) if not cancelled)
    function queryCancellation(bytes32 instanceId) external view returns (uint48 cancelledAt, address cancelledBy) {
        StreamingStorage storage $ = _getStorage();
        return ($.cancelledAt[instanceId], $.cancelledBy[instanceId]);
    }

    /// @notice Get comprehensive stream state
    /// @param instanceId Unique identifier for this stream instance
    /// @return status Current status
    /// @return streamed Total streamed so far
    /// @return available Available to claim
    /// @return withdrawn Already withdrawn
    /// @return remaining Remaining to stream
    function queryStreamState(bytes32 instanceId) external view returns (
        uint16 status,
        uint256 streamed,
        uint256 available,
        uint256 withdrawn,
        uint256 remaining
    ) {
        StreamingStorage storage $ = _getStorage();
        status = $.status[instanceId];
        streamed = _calculateStreamed($, instanceId);
        withdrawn = $.withdrawn[instanceId];
        available = streamed > withdrawn ? streamed - withdrawn : 0;
        remaining = $.deposit[instanceId] > streamed ? $.deposit[instanceId] - streamed : 0;
    }

    // =============================================================
    // INTERNAL
    // =============================================================

    /// @notice Calculate streamed amount at current timestamp
    /// @param $ Storage pointer
    /// @param instanceId Unique identifier for this stream instance
    /// @return The streamed amount
    function _calculateStreamed(StreamingStorage storage $, bytes32 instanceId) internal view returns (uint256) {
        return _calculateStreamedAt($, instanceId, block.timestamp);
    }

    /// @notice Calculate streamed amount at a specific timestamp
    /// @param $ Storage pointer
    /// @param instanceId Unique identifier for this stream instance
    /// @param timestamp The timestamp to calculate at
    /// @return The streamed amount
    function _calculateStreamedAt(
        StreamingStorage storage $,
        bytes32 instanceId,
        uint256 timestamp
    ) internal view returns (uint256) {
        uint48 startTime = $.startTime[instanceId];
        uint48 stopTime = $.stopTime[instanceId];
        uint256 deposit = $.deposit[instanceId];
        uint256 ratePerSecond = $.ratePerSecond[instanceId];

        // Before start, nothing streamed
        if (timestamp <= startTime) {
            return 0;
        }

        // After stop, everything streamed
        if (timestamp >= stopTime) {
            return deposit;
        }

        // Linear streaming: ratePerSecond × elapsed
        uint256 elapsed = timestamp - startTime;
        uint256 streamed = elapsed * ratePerSecond;

        // Cap at deposit (handles rounding)
        return streamed > deposit ? deposit : streamed;
    }

    /// @notice Transfer ETH or ERC20 tokens
    /// @param token Token address (address(0) for ETH)
    /// @param to Recipient address
    /// @param amount Amount to transfer
    function _transfer(address token, address to, uint256 amount) internal {
        if (token == ETH) {
            (bool success,) = to.call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    // =============================================================
    // ETH RECEIVE
    // =============================================================

    /// @notice Receive ETH for streaming
    receive() external payable {}
}
