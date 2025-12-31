// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ClauseBase} from "../../base/ClauseBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title EscrowClauseLogicV3
/// @notice Self-describing escrow clause following v3 specification
/// @dev Logic contract executed via delegatecall from Agreement proxies.
///      Uses ERC-7201 namespaced storage to prevent collisions with other clauses.
///      All functions take instanceId as first parameter for multi-instance support.
///
///      ADAPTER INTEGRATION:
///      When used with MilestoneClauseLogicV3, this clause works with
///      MilestoneEscrowAdapter which provides atomic confirm-and-release operations.
///      The adapter calls actionRelease() automatically after milestone confirmation.
///      See: src/adapters/MilestoneEscrowAdapter.sol
///
///      CANCELLATION POLICY:
///      Escrow instances can optionally have a cancellation policy that defines:
///      - Who can cancel (depositor, beneficiary, or either)
///      - Notice period before cancellation executes
///      - How funds are split (fixed fee, percentage, or time-based proration)
///
///      State Machine:
///      ┌────────────────┐
///      │  Uninitialized │
///      │    (status=0)  │
///      └───────┬────────┘
///              │ intakeDepositor(), intakeBeneficiary(), intakeToken()
///              │ [optional] intakeCancellation*() functions
///              │ intakeReady()
///              ▼
///      ┌────────────────┐
///      │    PENDING     │ ← Awaiting deposit
///      │   (0x0002)     │
///      └───────┬────────┘
///              │ actionDeposit() [payable for ETH]
///              ▼
///      ┌────────────────┐
///      │    FUNDED      │ ← Can release, refund, or cancel
///      │   (0x0004)     │
///      └───┬─────┬────┬─┘
///          │     │    │
///     release refund cancel
///          │     │    │
///          ▼     ▼    ▼
///      ┌────────┐ ┌────────┐ ┌──────────────────┐
///      │RELEASED│ │REFUNDED│ │  CANCEL_PENDING  │ ← Notice period active
///      │(0x0008)│ │(0x0010)│ │     (0x0020)     │   (if noticePeriod > 0)
///      └────────┘ └────────┘ └────────┬─────────┘
///                                     │ actionExecuteCancel()
///                                     │ (or immediate if noticePeriod = 0)
///                                     ▼
///                              ┌──────────────────┐
///                              │  CANCEL_EXECUTED │ ← Funds split per policy
///                              │     (0x0040)     │
///                              └──────────────────┘
contract EscrowClauseLogicV3 is ClauseBase {
    using SafeERC20 for IERC20;

    // =============================================================
    // CONSTANTS
    // =============================================================

    /// @notice ETH is represented by address(0)
    address public constant ETH = address(0);

    // =============================================================
    // ENUMS (for cancellation policy)
    // =============================================================

    /// @notice How cancellation fees are calculated
    enum FeeType {
        NONE,      // 0 - Full refund to depositor (no fee to beneficiary)
        FIXED,     // 1 - Fixed amount to beneficiary, rest to depositor
        BPS,       // 2 - Percentage to beneficiary (basis points, 10000 = 100%)
        PRORATED   // 3 - Based on time elapsed since proration start date
    }

    /// @notice Who is authorized to initiate cancellation
    enum CancellableBy {
        NONE,        // 0 - Nobody can cancel (cancellation disabled)
        DEPOSITOR,   // 1 - Only depositor can cancel
        BENEFICIARY, // 2 - Only beneficiary can cancel
        EITHER       // 3 - Either party can cancel
    }

    // =============================================================
    // EXTENDED STATES (bitmask)
    // =============================================================

    // Note: PENDING (0x0002), COMPLETE (0x0004), CANCELLED (0x0008) from ClauseBase
    // We define escrow-specific states:
    uint16 internal constant FUNDED = 1 << 2;            // 0x0004 (same position as COMPLETE)
    uint16 internal constant RELEASED = 1 << 3;          // 0x0008
    uint16 internal constant REFUNDED = 1 << 4;          // 0x0010
    uint16 internal constant CANCEL_PENDING = 1 << 5;    // 0x0020 - notice period active
    uint16 internal constant CANCEL_EXECUTED = 1 << 6;   // 0x0040 - cancellation executed

    // =============================================================
    // ERRORS
    // =============================================================

    error WrongState(uint16 expected, uint16 actual);
    error ZeroAddress();
    error ZeroAmount();
    error InsufficientDeposit(uint256 required, uint256 provided);
    error NotDepositor(address caller, address depositor);
    error TransferFailed();

    // Cancellation errors
    error CancellationNotEnabled(bytes32 instanceId);
    error NotAuthorizedToCancel(address caller, CancellableBy policy);
    error NoticePeriodNotElapsed(bytes32 instanceId, uint256 remaining);
    error CancellationNotInitiated(bytes32 instanceId);
    error ProrationNotConfigured(bytes32 instanceId);
    error InvalidProrationConfig(bytes32 instanceId);

    // =============================================================
    // EVENTS
    // =============================================================

    event EscrowConfigured(
        bytes32 indexed instanceId,
        address indexed depositor,
        address indexed beneficiary,
        address token
    );

    event EscrowFunded(
        bytes32 indexed instanceId,
        address indexed depositor,
        address token,
        uint256 amount
    );

    event EscrowReleased(
        bytes32 indexed instanceId,
        address indexed beneficiary,
        address token,
        uint256 amount
    );

    event EscrowRefunded(
        bytes32 indexed instanceId,
        address indexed depositor,
        address token,
        uint256 amount
    );

    event CancellationInitiated(
        bytes32 indexed instanceId,
        address indexed initiatedBy,
        uint256 noticeEndsAt
    );

    event EscrowCancelled(
        bytes32 indexed instanceId,
        address indexed cancelledBy,
        uint256 toBeneficiary,
        uint256 toDepositor
    );

    // =============================================================
    // ERC-7201 NAMESPACED STORAGE
    // =============================================================

    /// @custom:storage-location erc7201:papre.clause.escrow.storage
    struct EscrowStorage {
        /// @notice instanceId => clause state
        mapping(bytes32 => uint16) status;
        /// @notice instanceId => depositor address
        mapping(bytes32 => address) depositor;
        /// @notice instanceId => beneficiary address
        mapping(bytes32 => address) beneficiary;
        /// @notice instanceId => token address (address(0) for ETH)
        mapping(bytes32 => address) token;
        /// @notice instanceId => required deposit amount
        mapping(bytes32 => uint256) amount;
        /// @notice instanceId => timestamp when funded
        mapping(bytes32 => uint256) fundedAt;

        // ============ Cancellation Policy Configuration ============
        /// @notice instanceId => whether cancellation is enabled
        mapping(bytes32 => bool) cancellationEnabled;
        /// @notice instanceId => notice period in seconds (0 = immediate)
        mapping(bytes32 => uint256) cancellationNoticePeriod;
        /// @notice instanceId => fee type (FeeType enum as uint8)
        mapping(bytes32 => uint8) cancellationFeeType;
        /// @notice instanceId => fee amount (fixed amount or basis points)
        mapping(bytes32 => uint256) cancellationFeeAmount;
        /// @notice instanceId => who can cancel (CancellableBy enum as uint8)
        mapping(bytes32 => uint8) cancellableBy;
        /// @notice instanceId => proration start date (for PRORATED fee type)
        mapping(bytes32 => uint256) prorationStartDate;
        /// @notice instanceId => proration duration in seconds (for PRORATED fee type)
        mapping(bytes32 => uint256) prorationDuration;

        // ============ Cancellation State ============
        /// @notice instanceId => timestamp when cancellation was initiated
        mapping(bytes32 => uint256) cancellationInitiatedAt;
        /// @notice instanceId => address that initiated cancellation
        mapping(bytes32 => address) cancellationInitiatedBy;
    }

    // keccak256(abi.encode(uint256(keccak256("papre.clause.escrow.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT =
        0xba5260908d84ea3d59c0d07001243bfdfa609ca3585b936064d1e40950544d00;

    function _getStorage() internal pure returns (EscrowStorage storage $) {
        assembly {
            $.slot := STORAGE_SLOT
        }
    }

    // =============================================================
    // INTAKE (from previous clause)
    // =============================================================

    /// @notice Set the depositor for this escrow instance
    /// @param instanceId Unique identifier for this escrow instance
    /// @param _depositor Address that will deposit funds
    function intakeDepositor(bytes32 instanceId, address _depositor) external {
        if (_depositor == address(0)) revert ZeroAddress();
        EscrowStorage storage $ = _getStorage();
        // Status 0 means uninitialized (fresh storage)
        require($.status[instanceId] == 0, "Wrong state");
        $.depositor[instanceId] = _depositor;
    }

    /// @notice Set the beneficiary for this escrow instance
    /// @param instanceId Unique identifier for this escrow instance
    /// @param _beneficiary Address that will receive funds on release
    function intakeBeneficiary(bytes32 instanceId, address _beneficiary) external {
        if (_beneficiary == address(0)) revert ZeroAddress();
        EscrowStorage storage $ = _getStorage();
        require($.status[instanceId] == 0, "Wrong state");
        $.beneficiary[instanceId] = _beneficiary;
    }

    /// @notice Set the token for this escrow instance
    /// @param instanceId Unique identifier for this escrow instance
    /// @param _token Token address (address(0) for ETH)
    function intakeToken(bytes32 instanceId, address _token) external {
        EscrowStorage storage $ = _getStorage();
        require($.status[instanceId] == 0, "Wrong state");
        $.token[instanceId] = _token;
    }

    /// @notice Set the required deposit amount
    /// @param instanceId Unique identifier for this escrow instance
    /// @param _amount Required deposit amount
    function intakeAmount(bytes32 instanceId, uint256 _amount) external {
        if (_amount == 0) revert ZeroAmount();
        EscrowStorage storage $ = _getStorage();
        require($.status[instanceId] == 0, "Wrong state");
        $.amount[instanceId] = _amount;
    }

    // =============================================================
    // INTAKE - CANCELLATION POLICY (optional)
    // =============================================================

    /// @notice Enable cancellation for this escrow instance
    /// @param instanceId Unique identifier for this escrow instance
    /// @param enabled Whether cancellation is enabled
    /// @dev Must be called before intakeReady()
    function intakeCancellationEnabled(bytes32 instanceId, bool enabled) external {
        EscrowStorage storage $ = _getStorage();
        require($.status[instanceId] == 0, "Wrong state");
        $.cancellationEnabled[instanceId] = enabled;
    }

    /// @notice Set the notice period for cancellation
    /// @param instanceId Unique identifier for this escrow instance
    /// @param _noticePeriod Notice period in seconds (0 = immediate cancellation)
    function intakeCancellationNoticePeriod(bytes32 instanceId, uint256 _noticePeriod) external {
        EscrowStorage storage $ = _getStorage();
        require($.status[instanceId] == 0, "Wrong state");
        $.cancellationNoticePeriod[instanceId] = _noticePeriod;
    }

    /// @notice Set how cancellation fees are calculated
    /// @param instanceId Unique identifier for this escrow instance
    /// @param _feeType Fee calculation type (NONE, FIXED, BPS, PRORATED)
    function intakeCancellationFeeType(bytes32 instanceId, FeeType _feeType) external {
        EscrowStorage storage $ = _getStorage();
        require($.status[instanceId] == 0, "Wrong state");
        $.cancellationFeeType[instanceId] = uint8(_feeType);
    }

    /// @notice Set the cancellation fee amount
    /// @param instanceId Unique identifier for this escrow instance
    /// @param _feeAmount For FIXED: the actual amount. For BPS: basis points (10000 = 100%)
    function intakeCancellationFeeAmount(bytes32 instanceId, uint256 _feeAmount) external {
        EscrowStorage storage $ = _getStorage();
        require($.status[instanceId] == 0, "Wrong state");
        $.cancellationFeeAmount[instanceId] = _feeAmount;
    }

    /// @notice Set who is authorized to cancel
    /// @param instanceId Unique identifier for this escrow instance
    /// @param _cancellableBy Who can initiate cancellation (NONE, DEPOSITOR, BENEFICIARY, EITHER)
    function intakeCancellableBy(bytes32 instanceId, CancellableBy _cancellableBy) external {
        EscrowStorage storage $ = _getStorage();
        require($.status[instanceId] == 0, "Wrong state");
        $.cancellableBy[instanceId] = uint8(_cancellableBy);
    }

    /// @notice Set the proration start date (for PRORATED fee type)
    /// @param instanceId Unique identifier for this escrow instance
    /// @param _startDate Timestamp when the "work period" starts
    /// @dev For retainers/contracts, this is typically when the counterparty signs
    function intakeProrationStartDate(bytes32 instanceId, uint256 _startDate) external {
        EscrowStorage storage $ = _getStorage();
        require($.status[instanceId] == 0, "Wrong state");
        $.prorationStartDate[instanceId] = _startDate;
    }

    /// @notice Set the proration duration (for PRORATED fee type)
    /// @param instanceId Unique identifier for this escrow instance
    /// @param _duration Total duration of the work period in seconds
    /// @dev Proration = elapsed / duration * totalAmount
    function intakeProrationDuration(bytes32 instanceId, uint256 _duration) external {
        EscrowStorage storage $ = _getStorage();
        require($.status[instanceId] == 0, "Wrong state");
        $.prorationDuration[instanceId] = _duration;
    }

    /// @notice Finalize configuration and transition to PENDING
    /// @param instanceId Unique identifier for this escrow instance
    /// @dev Requires depositor, beneficiary, and amount to be set
    function intakeReady(bytes32 instanceId) external {
        EscrowStorage storage $ = _getStorage();
        require($.status[instanceId] == 0, "Wrong state");
        require($.depositor[instanceId] != address(0), "No depositor");
        require($.beneficiary[instanceId] != address(0), "No beneficiary");
        require($.amount[instanceId] > 0, "No amount");

        $.status[instanceId] = PENDING;

        emit EscrowConfigured(
            instanceId,
            $.depositor[instanceId],
            $.beneficiary[instanceId],
            $.token[instanceId]
        );
    }

    // =============================================================
    // ACTIONS (state-changing)
    // =============================================================

    /// @notice Deposit funds into escrow
    /// @param instanceId Unique identifier for this escrow instance
    /// @dev For ETH: send msg.value. For ERC20: approve first, then call.
    ///      Must be called by the designated depositor.
    /// @custom:papre-style primary
    function actionDeposit(bytes32 instanceId) external payable {
        EscrowStorage storage $ = _getStorage();
        require($.status[instanceId] == PENDING, "Wrong state");

        address depositor = $.depositor[instanceId];
        if (msg.sender != depositor) revert NotDepositor(msg.sender, depositor);

        address token = $.token[instanceId];
        uint256 requiredAmount = $.amount[instanceId];

        if (token == ETH) {
            // ETH deposit
            if (msg.value < requiredAmount) {
                revert InsufficientDeposit(requiredAmount, msg.value);
            }
            // Refund excess
            if (msg.value > requiredAmount) {
                (bool success,) = msg.sender.call{value: msg.value - requiredAmount}("");
                if (!success) revert TransferFailed();
            }
        } else {
            // ERC20 deposit - transfer from depositor to this contract (Agreement)
            IERC20(token).safeTransferFrom(msg.sender, address(this), requiredAmount);
        }

        $.fundedAt[instanceId] = block.timestamp;
        $.status[instanceId] = FUNDED;

        emit EscrowFunded(instanceId, depositor, token, requiredAmount);
    }

    /// @notice Mark escrow as funded without depositing (caller has funds)
    /// @param instanceId Unique identifier for this escrow instance
    /// @dev Use when Agreement already holds the funds (e.g., multi-escrow batch deposits).
    ///      Caller is responsible for ensuring address(this) has sufficient balance.
    ///      On release, funds will transfer from address(this) to beneficiary.
    ///      Marked payable to allow delegatecall from payable functions.
    /// @custom:papre-style primary
    function actionMarkFunded(bytes32 instanceId) external payable {
        EscrowStorage storage $ = _getStorage();
        require($.status[instanceId] == PENDING, "Wrong state");

        $.fundedAt[instanceId] = block.timestamp;
        $.status[instanceId] = FUNDED;

        emit EscrowFunded(
            instanceId,
            $.depositor[instanceId],
            $.token[instanceId],
            $.amount[instanceId]
        );
    }

    /// @notice Release funds to beneficiary
    /// @param instanceId Unique identifier for this escrow instance
    /// @dev Can be called by anyone once funded. Authorization should be at Agreement level.
    /// @custom:papre-style primary
    function actionRelease(bytes32 instanceId) external {
        EscrowStorage storage $ = _getStorage();
        require($.status[instanceId] == FUNDED, "Wrong state");

        address beneficiary = $.beneficiary[instanceId];
        address token = $.token[instanceId];
        uint256 amount = $.amount[instanceId];

        $.status[instanceId] = RELEASED;

        _transfer(token, beneficiary, amount);

        emit EscrowReleased(instanceId, beneficiary, token, amount);
    }

    /// @notice Refund funds to depositor
    /// @param instanceId Unique identifier for this escrow instance
    /// @dev Can be called by anyone once funded. Authorization should be at Agreement level.
    /// @custom:papre-style destructive
    function actionRefund(bytes32 instanceId) external {
        EscrowStorage storage $ = _getStorage();
        require($.status[instanceId] == FUNDED, "Wrong state");

        address depositor = $.depositor[instanceId];
        address token = $.token[instanceId];
        uint256 amount = $.amount[instanceId];

        $.status[instanceId] = REFUNDED;

        _transfer(token, depositor, amount);

        emit EscrowRefunded(instanceId, depositor, token, amount);
    }

    // =============================================================
    // ACTIONS - CANCELLATION
    // =============================================================

    /// @notice Initiate cancellation of the escrow
    /// @param instanceId Unique identifier for this escrow instance
    /// @dev If notice period is 0, immediately executes cancellation.
    ///      If notice period > 0, enters CANCELLING state and requires actionExecuteCancel().
    ///      Caller must be authorized based on cancellableBy policy.
    /// @custom:papre-style destructive
    function actionInitiateCancel(bytes32 instanceId) external {
        EscrowStorage storage $ = _getStorage();
        require($.status[instanceId] == FUNDED, "Wrong state");

        // Check cancellation is enabled
        if (!$.cancellationEnabled[instanceId]) {
            revert CancellationNotEnabled(instanceId);
        }

        // Check caller is authorized
        CancellableBy policy = CancellableBy($.cancellableBy[instanceId]);
        if (!_isAuthorizedToCancel(instanceId, msg.sender, policy)) {
            revert NotAuthorizedToCancel(msg.sender, policy);
        }

        uint256 noticePeriod = $.cancellationNoticePeriod[instanceId];

        if (noticePeriod == 0) {
            // Immediate cancellation - execute directly
            _executeCancel(instanceId, msg.sender);
        } else {
            // Deferred cancellation - enter CANCELLING state
            $.status[instanceId] = CANCEL_PENDING;
            $.cancellationInitiatedAt[instanceId] = block.timestamp;
            $.cancellationInitiatedBy[instanceId] = msg.sender;

            emit CancellationInitiated(
                instanceId,
                msg.sender,
                block.timestamp + noticePeriod
            );
        }
    }

    /// @notice Execute cancellation after notice period has elapsed
    /// @param instanceId Unique identifier for this escrow instance
    /// @dev Only callable after actionInitiateCancel() and notice period has elapsed.
    ///      Anyone can call this once notice period expires.
    /// @custom:papre-style destructive
    function actionExecuteCancel(bytes32 instanceId) external {
        EscrowStorage storage $ = _getStorage();
        require($.status[instanceId] == CANCEL_PENDING, "Wrong state");

        uint256 initiatedAt = $.cancellationInitiatedAt[instanceId];
        if (initiatedAt == 0) {
            revert CancellationNotInitiated(instanceId);
        }

        uint256 noticePeriod = $.cancellationNoticePeriod[instanceId];
        uint256 noticeEndsAt = initiatedAt + noticePeriod;

        if (block.timestamp < noticeEndsAt) {
            revert NoticePeriodNotElapsed(instanceId, noticeEndsAt - block.timestamp);
        }

        address initiator = $.cancellationInitiatedBy[instanceId];
        _executeCancel(instanceId, initiator);
    }

    // =============================================================
    // HANDOFF (to next clause)
    // =============================================================

    /// @notice Get the amount after successful release
    /// @param instanceId Unique identifier for this escrow instance
    /// @return The escrow amount
    function handoffAmount(bytes32 instanceId) external view returns (uint256) {
        EscrowStorage storage $ = _getStorage();
        require($.status[instanceId] == RELEASED, "Wrong state");
        return $.amount[instanceId];
    }

    /// @notice Get the beneficiary after successful release
    /// @param instanceId Unique identifier for this escrow instance
    /// @return The beneficiary address
    function handoffBeneficiary(bytes32 instanceId) external view returns (address) {
        EscrowStorage storage $ = _getStorage();
        require($.status[instanceId] == RELEASED, "Wrong state");
        return $.beneficiary[instanceId];
    }

    /// @notice Get the token after successful release
    /// @param instanceId Unique identifier for this escrow instance
    /// @return The token address (address(0) for ETH)
    function handoffToken(bytes32 instanceId) external view returns (address) {
        EscrowStorage storage $ = _getStorage();
        require($.status[instanceId] == RELEASED, "Wrong state");
        return $.token[instanceId];
    }

    /// @notice Get the depositor after refund
    /// @param instanceId Unique identifier for this escrow instance
    /// @return The depositor address
    function handoffDepositor(bytes32 instanceId) external view returns (address) {
        EscrowStorage storage $ = _getStorage();
        require($.status[instanceId] == REFUNDED, "Wrong state");
        return $.depositor[instanceId];
    }

    // =============================================================
    // HANDOFF - CANCELLATION
    // =============================================================

    /// @notice Get the cancellation split after cancellation
    /// @param instanceId Unique identifier for this escrow instance
    /// @return toBeneficiary Amount sent to beneficiary
    /// @return toDepositor Amount sent to depositor
    /// @dev Only available after CANCELLED state
    function handoffCancellationSplit(bytes32 instanceId) external view returns (uint256 toBeneficiary, uint256 toDepositor) {
        EscrowStorage storage $ = _getStorage();
        require($.status[instanceId] == CANCEL_EXECUTED, "Wrong state");
        return _calculateSplit(instanceId);
    }

    /// @notice Get who cancelled the escrow
    /// @param instanceId Unique identifier for this escrow instance
    /// @return Address that initiated the cancellation
    function handoffCancelledBy(bytes32 instanceId) external view returns (address) {
        EscrowStorage storage $ = _getStorage();
        require($.status[instanceId] == CANCEL_EXECUTED, "Wrong state");
        return $.cancellationInitiatedBy[instanceId];
    }

    // =============================================================
    // QUERIES (always available)
    // =============================================================

    /// @notice Get the current state of an instance
    /// @param instanceId Unique identifier for this escrow instance
    /// @return Current state bitmask
    function queryStatus(bytes32 instanceId) external view returns (uint16) {
        return _getStorage().status[instanceId];
    }

    /// @notice Get the depositor for an instance
    /// @param instanceId Unique identifier for this escrow instance
    /// @return The depositor address
    function queryDepositor(bytes32 instanceId) external view returns (address) {
        return _getStorage().depositor[instanceId];
    }

    /// @notice Get the beneficiary for an instance
    /// @param instanceId Unique identifier for this escrow instance
    /// @return The beneficiary address
    function queryBeneficiary(bytes32 instanceId) external view returns (address) {
        return _getStorage().beneficiary[instanceId];
    }

    /// @notice Get the token for an instance
    /// @param instanceId Unique identifier for this escrow instance
    /// @return The token address (address(0) for ETH)
    function queryToken(bytes32 instanceId) external view returns (address) {
        return _getStorage().token[instanceId];
    }

    /// @notice Get the required amount for an instance
    /// @param instanceId Unique identifier for this escrow instance
    /// @return The required deposit amount
    function queryAmount(bytes32 instanceId) external view returns (uint256) {
        return _getStorage().amount[instanceId];
    }

    /// @notice Get the timestamp when the escrow was funded
    /// @param instanceId Unique identifier for this escrow instance
    /// @return The funding timestamp (0 if not funded)
    function queryFundedAt(bytes32 instanceId) external view returns (uint256) {
        return _getStorage().fundedAt[instanceId];
    }

    /// @notice Check if an escrow is funded
    /// @param instanceId Unique identifier for this escrow instance
    /// @return True if in FUNDED state
    function queryIsFunded(bytes32 instanceId) external view returns (bool) {
        return _getStorage().status[instanceId] == FUNDED;
    }

    /// @notice Check if an escrow is released
    /// @param instanceId Unique identifier for this escrow instance
    /// @return True if in RELEASED state
    function queryIsReleased(bytes32 instanceId) external view returns (bool) {
        return _getStorage().status[instanceId] == RELEASED;
    }

    /// @notice Check if an escrow is refunded
    /// @param instanceId Unique identifier for this escrow instance
    /// @return True if in REFUNDED state
    function queryIsRefunded(bytes32 instanceId) external view returns (bool) {
        return _getStorage().status[instanceId] == REFUNDED;
    }

    // =============================================================
    // QUERIES - CANCELLATION
    // =============================================================

    /// @notice Check if cancellation is enabled for this instance
    /// @param instanceId Unique identifier for this escrow instance
    /// @return True if cancellation is enabled
    function queryCancellationEnabled(bytes32 instanceId) external view returns (bool) {
        return _getStorage().cancellationEnabled[instanceId];
    }

    /// @notice Get the cancellation notice period
    /// @param instanceId Unique identifier for this escrow instance
    /// @return Notice period in seconds (0 = immediate)
    function queryCancellationNoticePeriod(bytes32 instanceId) external view returns (uint256) {
        return _getStorage().cancellationNoticePeriod[instanceId];
    }

    /// @notice Get the cancellation fee type
    /// @param instanceId Unique identifier for this escrow instance
    /// @return Fee type as uint8 (see FeeType enum)
    function queryCancellationFeeType(bytes32 instanceId) external view returns (FeeType) {
        return FeeType(_getStorage().cancellationFeeType[instanceId]);
    }

    /// @notice Get the cancellation fee amount
    /// @param instanceId Unique identifier for this escrow instance
    /// @return Fee amount (interpretation depends on FeeType)
    function queryCancellationFeeAmount(bytes32 instanceId) external view returns (uint256) {
        return _getStorage().cancellationFeeAmount[instanceId];
    }

    /// @notice Get who can cancel this escrow
    /// @param instanceId Unique identifier for this escrow instance
    /// @return CancellableBy policy
    function queryCancellableBy(bytes32 instanceId) external view returns (CancellableBy) {
        return CancellableBy(_getStorage().cancellableBy[instanceId]);
    }

    /// @notice Get the proration start date
    /// @param instanceId Unique identifier for this escrow instance
    /// @return Start timestamp (0 if not configured)
    function queryProrationStartDate(bytes32 instanceId) external view returns (uint256) {
        return _getStorage().prorationStartDate[instanceId];
    }

    /// @notice Get the proration duration
    /// @param instanceId Unique identifier for this escrow instance
    /// @return Duration in seconds (0 if not configured)
    function queryProrationDuration(bytes32 instanceId) external view returns (uint256) {
        return _getStorage().prorationDuration[instanceId];
    }

    /// @notice Get when cancellation was initiated
    /// @param instanceId Unique identifier for this escrow instance
    /// @return Timestamp when cancellation was initiated (0 if not initiated)
    function queryCancellationInitiatedAt(bytes32 instanceId) external view returns (uint256) {
        return _getStorage().cancellationInitiatedAt[instanceId];
    }

    /// @notice Get who initiated cancellation
    /// @param instanceId Unique identifier for this escrow instance
    /// @return Address that initiated cancellation (address(0) if not initiated)
    function queryCancellationInitiatedBy(bytes32 instanceId) external view returns (address) {
        return _getStorage().cancellationInitiatedBy[instanceId];
    }

    /// @notice Check if escrow is in CANCEL_PENDING state (notice period active)
    /// @param instanceId Unique identifier for this escrow instance
    /// @return True if in CANCEL_PENDING state
    function queryIsCancelPending(bytes32 instanceId) external view returns (bool) {
        return _getStorage().status[instanceId] == CANCEL_PENDING;
    }

    /// @notice Check if escrow cancellation has been executed
    /// @param instanceId Unique identifier for this escrow instance
    /// @return True if in CANCEL_EXECUTED state
    function queryIsCancelExecuted(bytes32 instanceId) external view returns (bool) {
        return _getStorage().status[instanceId] == CANCEL_EXECUTED;
    }

    /// @notice Calculate how funds would be split if cancelled now
    /// @param instanceId Unique identifier for this escrow instance
    /// @return toBeneficiary Amount that would go to beneficiary
    /// @return toDepositor Amount that would go to depositor
    /// @dev Can be called even before cancellation to preview the split
    function queryCancellationSplit(bytes32 instanceId) external view returns (uint256 toBeneficiary, uint256 toDepositor) {
        return _calculateSplit(instanceId);
    }

    /// @notice Get the timestamp when notice period ends
    /// @param instanceId Unique identifier for this escrow instance
    /// @return Timestamp when cancellation can be executed (0 if not in CANCELLING state)
    function queryNoticeEndsAt(bytes32 instanceId) external view returns (uint256) {
        EscrowStorage storage $ = _getStorage();
        uint256 initiatedAt = $.cancellationInitiatedAt[instanceId];
        if (initiatedAt == 0) return 0;
        return initiatedAt + $.cancellationNoticePeriod[instanceId];
    }

    /// @notice Check if cancellation can be executed now (notice period elapsed)
    /// @param instanceId Unique identifier for this escrow instance
    /// @return True if in CANCEL_PENDING state and notice period has elapsed
    function queryCanExecuteCancel(bytes32 instanceId) external view returns (bool) {
        EscrowStorage storage $ = _getStorage();
        if ($.status[instanceId] != CANCEL_PENDING) return false;
        uint256 initiatedAt = $.cancellationInitiatedAt[instanceId];
        if (initiatedAt == 0) return false;
        uint256 noticeEndsAt = initiatedAt + $.cancellationNoticePeriod[instanceId];
        return block.timestamp >= noticeEndsAt;
    }

    // =============================================================
    // INTERNAL
    // =============================================================

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

    /// @notice Check if caller is authorized to cancel based on policy
    /// @param instanceId Unique identifier for this escrow instance
    /// @param caller Address attempting to cancel
    /// @param policy Who is authorized to cancel
    /// @return True if caller is authorized
    function _isAuthorizedToCancel(
        bytes32 instanceId,
        address caller,
        CancellableBy policy
    ) internal view returns (bool) {
        if (policy == CancellableBy.NONE) {
            return false;
        }

        EscrowStorage storage $ = _getStorage();
        address depositor = $.depositor[instanceId];
        address beneficiary = $.beneficiary[instanceId];

        if (policy == CancellableBy.DEPOSITOR) {
            return caller == depositor;
        } else if (policy == CancellableBy.BENEFICIARY) {
            return caller == beneficiary;
        } else if (policy == CancellableBy.EITHER) {
            return caller == depositor || caller == beneficiary;
        }

        return false;
    }

    /// @notice Execute the actual cancellation and fund split
    /// @param instanceId Unique identifier for this escrow instance
    /// @param cancelledBy Address that initiated/executed the cancellation
    function _executeCancel(bytes32 instanceId, address cancelledBy) internal {
        EscrowStorage storage $ = _getStorage();

        (uint256 toBeneficiary, uint256 toDepositor) = _calculateSplit(instanceId);

        $.status[instanceId] = CANCEL_EXECUTED;

        // For immediate cancellations, store who cancelled
        if ($.cancellationInitiatedBy[instanceId] == address(0)) {
            $.cancellationInitiatedBy[instanceId] = cancelledBy;
        }

        address token = $.token[instanceId];
        address depositor = $.depositor[instanceId];
        address beneficiary = $.beneficiary[instanceId];

        // Transfer funds
        if (toBeneficiary > 0) {
            _transfer(token, beneficiary, toBeneficiary);
        }
        if (toDepositor > 0) {
            _transfer(token, depositor, toDepositor);
        }

        emit EscrowCancelled(instanceId, cancelledBy, toBeneficiary, toDepositor);
    }

    /// @notice Calculate how funds should be split on cancellation
    /// @param instanceId Unique identifier for this escrow instance
    /// @return toBeneficiary Amount to send to beneficiary
    /// @return toDepositor Amount to refund to depositor
    function _calculateSplit(bytes32 instanceId) internal view returns (uint256 toBeneficiary, uint256 toDepositor) {
        EscrowStorage storage $ = _getStorage();

        uint256 totalAmount = $.amount[instanceId];
        FeeType feeType = FeeType($.cancellationFeeType[instanceId]);
        uint256 feeAmount = $.cancellationFeeAmount[instanceId];

        if (feeType == FeeType.NONE) {
            // Full refund to depositor
            return (0, totalAmount);
        } else if (feeType == FeeType.FIXED) {
            // Fixed amount to beneficiary
            if (feeAmount >= totalAmount) {
                return (totalAmount, 0);
            }
            return (feeAmount, totalAmount - feeAmount);
        } else if (feeType == FeeType.BPS) {
            // Percentage (basis points) to beneficiary
            // 10000 BPS = 100%
            toBeneficiary = (totalAmount * feeAmount) / 10000;
            if (toBeneficiary > totalAmount) {
                toBeneficiary = totalAmount;
            }
            return (toBeneficiary, totalAmount - toBeneficiary);
        } else if (feeType == FeeType.PRORATED) {
            // Time-based proration
            uint256 startDate = $.prorationStartDate[instanceId];
            uint256 duration = $.prorationDuration[instanceId];

            // Proration requires valid config
            if (startDate == 0 || duration == 0) {
                revert ProrationNotConfigured(instanceId);
            }

            // If cancellation is before start date, full refund
            if (block.timestamp <= startDate) {
                return (0, totalAmount);
            }

            // Calculate elapsed time
            uint256 elapsed = block.timestamp - startDate;

            // If past full duration, full payment to beneficiary
            if (elapsed >= duration) {
                return (totalAmount, 0);
            }

            // Prorate: (elapsed / duration) * totalAmount
            toBeneficiary = (totalAmount * elapsed) / duration;
            return (toBeneficiary, totalAmount - toBeneficiary);
        }

        // Default: full refund (should not reach here)
        return (0, totalAmount);
    }
}
