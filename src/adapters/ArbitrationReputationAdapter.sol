// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ReputationClauseLogicV3} from "../clauses/reputation/ReputationClauseLogicV3.sol";

/// @title ArbitrationReputationAdapter
/// @notice Adapter for arbitrator reputation tracking across any IDisputable agreement
/// @dev This adapter wraps ReputationClauseLogicV3 to provide arbitrator rating functionality
///      for any agreement that implements IDisputable. It is designed to be called via
///      delegatecall from Agreement contracts, preserving msg.sender as the original caller.
///
///      The adapter is stateless - all storage lives in the calling Agreement via ERC-7201
///      namespaced storage slots.
///
///      Architecture:
///      ┌─────────────────────────────────────────────────────────────────────────┐
///      │                    ANY IDISPUTABLE AGREEMENT                            │
///      │  (MilestonePaymentAgreement, SafetyNetAgreement, etc.)                 │
///      │  Storage: ERC-7201 namespace for adapter storage                       │
///      └─────────────────────────────────────────────────────────────────────────┘
///                                      │
///                             delegatecall to adapter
///                                      │
///                                      ▼
///      ┌─────────────────────────────────────────────────────────────────────────┐
///      │                  ArbitrationReputationAdapter                           │
///      │                                                                          │
///      │  openReputationWindow():                                                │
///      │    1. Generate unique reputation instance ID                            │
///      │    2. Store mapping: agreementInstanceId => reputationInstanceId        │
///      │    3. Configure ReputationClause (intakeConfig)                        │
///      │    4. Open rating window (intakeRatingWindow)                          │
///      │                                                                          │
///      │  rateArbitrator():                                                      │
///      │    1. Look up reputationInstanceId from storage                        │
///      │    2. Delegate to ReputationClause.actionSubmitRating()               │
///      │                                                                          │
///      │  getArbitratorProfile(): Query global reputation via handoff           │
///      └─────────────────────────────────────────────────────────────────────────┘
///                                      │
///                             delegatecall to clause
///                                      │
///                                      ▼
///      ┌─────────────────────────────────────────────────────────────────────────┐
///      │                      ReputationClauseLogicV3                            │
///      │                          (stateless)                                    │
///      └─────────────────────────────────────────────────────────────────────────┘
///
///      Usage:
///      1. Agreement holds immutable reference to this adapter
///      2. After arbitration ruling: agreement calls adapter.openReputationWindow()
///      3. Parties call agreement.rateArbitrator() -> delegatecalls adapter
///      4. Ratings aggregate into global arbitrator profile
contract ArbitrationReputationAdapter {
    // =============================================================
    // IMMUTABLES
    // =============================================================

    /// @notice Address of ReputationClauseLogicV3 implementation
    ReputationClauseLogicV3 public immutable reputationClause;

    // =============================================================
    // CONSTANTS
    // =============================================================

    /// @notice Role identifier for arbitrators
    bytes32 public constant ARBITRATOR_ROLE = keccak256("arbitrator");

    /// @notice Default rating window duration (14 days)
    uint32 public constant DEFAULT_RATING_WINDOW = 14 days;

    // =============================================================
    // ERC-7201 STORAGE (in calling Agreement)
    // =============================================================

    /// @custom:storage-location erc7201:papre.adapter.arbitrationreputation.storage
    struct AdapterStorage {
        /// @notice Maps agreement instanceId => reputation instanceId
        mapping(bytes32 => bytes32) reputationInstanceIds;
        /// @notice Maps agreement instanceId => arbitrator being rated
        mapping(bytes32 => address) ratedArbitrators;
        /// @notice Maps agreement instanceId => whether reputation is configured
        mapping(bytes32 => bool) reputationConfigured;
    }

    // keccak256(abi.encode(uint256(keccak256("papre.adapter.arbitrationreputation.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT =
        0x3a8f9d2c1b4e7f6a5d0c9b8e7f4a3d2c1b0a9e8d7c6b5a4f3e2d1c0b9a8f7e00;

    function _getStorage() internal pure returns (AdapterStorage storage $) {
        assembly {
            $.slot := STORAGE_SLOT
        }
    }

    // =============================================================
    // ERRORS
    // =============================================================

    error ReputationNotConfigured();
    error ReputationWindowNotOpen();
    error ReputationAlreadyConfigured();
    error NoArbitratorToRate();
    error ConfigFailed(bytes reason);
    error OpenWindowFailed(bytes reason);
    error SubmitRatingFailed(bytes reason);
    error UpdateRatingFailed(bytes reason);
    error CloseWindowFailed(bytes reason);
    error ArrayLengthMismatch();

    // =============================================================
    // EVENTS
    // =============================================================

    /// @notice Emitted when a reputation window is opened for rating an arbitrator
    event ReputationWindowOpened(
        bytes32 indexed agreementInstanceId,
        bytes32 indexed reputationInstanceId,
        address indexed arbitrator,
        uint48 windowClosesAt
    );

    /// @notice Emitted when an arbitrator is rated
    event ArbitratorRated(
        bytes32 indexed agreementInstanceId,
        address indexed rater,
        address indexed arbitrator,
        uint8 score
    );

    /// @notice Emitted when a reputation window is closed
    event ReputationWindowClosed(bytes32 indexed agreementInstanceId);

    // =============================================================
    // CONSTRUCTOR
    // =============================================================

    /// @notice Create a new ArbitrationReputationAdapter
    /// @param _reputationClause Address of ReputationClauseLogicV3 implementation
    constructor(address _reputationClause) {
        reputationClause = ReputationClauseLogicV3(_reputationClause);
    }

    // =============================================================
    // ADAPTER FUNCTIONS (called via delegatecall from Agreement)
    // =============================================================

    /// @notice Configure and open a reputation window for rating an arbitrator
    /// @dev Combines config + window opening into a single call for convenience.
    ///      Called via delegatecall from Agreement after arbitration ruling.
    /// @param agreementInstanceId The agreement instance ID (as bytes32)
    /// @param arbitrator Address of the arbitrator to be rated
    /// @param raters Addresses eligible to rate (typically claimant + respondent)
    /// @param outcomes Outcome for each rater (1=winner, 2=loser, 3=split)
    /// @param windowDuration Duration of rating window (0 = use default 14 days)
    function openReputationWindow(
        bytes32 agreementInstanceId,
        address arbitrator,
        address[] calldata raters,
        uint8[] calldata outcomes,
        uint32 windowDuration
    ) external {
        if (arbitrator == address(0)) revert NoArbitratorToRate();
        if (raters.length != outcomes.length) revert ArrayLengthMismatch();

        AdapterStorage storage $ = _getStorage();

        // Check not already configured
        if ($.reputationConfigured[agreementInstanceId]) {
            revert ReputationAlreadyConfigured();
        }

        // Generate unique reputation instance ID
        bytes32 reputationInstanceId = keccak256(
            abi.encode(address(this), agreementInstanceId, "arbitration-reputation", block.timestamp)
        );

        // Store mappings
        $.reputationInstanceIds[agreementInstanceId] = reputationInstanceId;
        $.ratedArbitrators[agreementInstanceId] = arbitrator;
        $.reputationConfigured[agreementInstanceId] = true;

        // Determine window duration
        uint32 duration = windowDuration > 0 ? windowDuration : DEFAULT_RATING_WINDOW;

        // Configure reputation clause
        ReputationClauseLogicV3.ReputationConfig memory config = ReputationClauseLogicV3.ReputationConfig({
            weightStrategy: reputationClause.WEIGHT_EQUAL(),
            winnerWeightBps: 10000,
            visibilityMode: reputationClause.VISIBILITY_BLIND_UNTIL_ALL(),
            blindThreshold: uint8(raters.length),
            ratingWindowSeconds: duration,
            allowUpdates: true,
            aggregationMethod: reputationClause.AGGREGATION_SIMPLE(),
            minimumRatingsToDisplay: 1,
            ratedRole: ARBITRATOR_ROLE
        });

        (bool success, bytes memory data) = address(reputationClause).delegatecall(
            abi.encodeCall(ReputationClauseLogicV3.intakeConfig, (reputationInstanceId, config))
        );
        if (!success) revert ConfigFailed(data);

        // Prepare subjects array (just the arbitrator)
        address[] memory subjects = new address[](1);
        subjects[0] = arbitrator;

        // Open the rating window
        (success, data) = address(reputationClause).delegatecall(
            abi.encodeCall(
                ReputationClauseLogicV3.intakeRatingWindow, (reputationInstanceId, raters, subjects, outcomes)
            )
        );
        if (!success) revert OpenWindowFailed(data);

        uint48 windowClosesAt = uint48(block.timestamp + duration);
        emit ReputationWindowOpened(agreementInstanceId, reputationInstanceId, arbitrator, windowClosesAt);
    }

    /// @notice Submit a rating for the arbitrator
    /// @dev Called via delegatecall from Agreement
    /// @param agreementInstanceId The agreement instance ID
    /// @param score Rating 1-5 stars
    /// @param feedbackCID Optional IPFS CID for text feedback
    function rateArbitrator(bytes32 agreementInstanceId, uint8 score, bytes32 feedbackCID) external {
        AdapterStorage storage $ = _getStorage();
        bytes32 reputationInstanceId = $.reputationInstanceIds[agreementInstanceId];
        address arbitrator = $.ratedArbitrators[agreementInstanceId];

        if (reputationInstanceId == bytes32(0)) revert ReputationWindowNotOpen();

        (bool success, bytes memory data) = address(reputationClause).delegatecall(
            abi.encodeCall(
                ReputationClauseLogicV3.actionSubmitRating, (reputationInstanceId, arbitrator, score, feedbackCID)
            )
        );
        if (!success) revert SubmitRatingFailed(data);

        emit ArbitratorRated(agreementInstanceId, msg.sender, arbitrator, score);
    }

    /// @notice Update an existing rating
    /// @dev Called via delegatecall from Agreement
    /// @param agreementInstanceId The agreement instance ID
    /// @param score New rating 1-5 stars
    /// @param feedbackCID New feedback CID
    function updateArbitratorRating(bytes32 agreementInstanceId, uint8 score, bytes32 feedbackCID) external {
        AdapterStorage storage $ = _getStorage();
        bytes32 reputationInstanceId = $.reputationInstanceIds[agreementInstanceId];
        address arbitrator = $.ratedArbitrators[agreementInstanceId];

        if (reputationInstanceId == bytes32(0)) revert ReputationWindowNotOpen();

        (bool success, bytes memory data) = address(reputationClause).delegatecall(
            abi.encodeCall(
                ReputationClauseLogicV3.actionUpdateRating, (reputationInstanceId, arbitrator, score, feedbackCID)
            )
        );
        if (!success) revert UpdateRatingFailed(data);
    }

    /// @notice Close the reputation window early
    /// @dev Called via delegatecall from Agreement
    /// @param agreementInstanceId The agreement instance ID
    function closeReputationWindow(bytes32 agreementInstanceId) external {
        AdapterStorage storage $ = _getStorage();
        bytes32 reputationInstanceId = $.reputationInstanceIds[agreementInstanceId];

        if (reputationInstanceId == bytes32(0)) revert ReputationWindowNotOpen();

        (bool success, bytes memory data) = address(reputationClause).delegatecall(
            abi.encodeCall(ReputationClauseLogicV3.actionCloseWindow, (reputationInstanceId))
        );
        if (!success) revert CloseWindowFailed(data);

        emit ReputationWindowClosed(agreementInstanceId);
    }

    // =============================================================
    // QUERY FUNCTIONS (view - reads from storage)
    // =============================================================

    /// @notice Get the reputation instance ID for an agreement instance
    /// @param agreementInstanceId The agreement instance ID
    /// @return reputationInstanceId The reputation clause instance ID (bytes32(0) if not configured)
    function getReputationInstanceId(bytes32 agreementInstanceId) external view returns (bytes32) {
        return _getStorage().reputationInstanceIds[agreementInstanceId];
    }

    /// @notice Get the arbitrator being rated for an instance
    /// @param agreementInstanceId The agreement instance ID
    /// @return arbitrator The arbitrator address (address(0) if not configured)
    function getRatedArbitrator(bytes32 agreementInstanceId) external view returns (address) {
        return _getStorage().ratedArbitrators[agreementInstanceId];
    }

    /// @notice Check if reputation is configured for an instance
    /// @param agreementInstanceId The agreement instance ID
    /// @return configured Whether reputation window has been opened
    function isReputationConfigured(bytes32 agreementInstanceId) external view returns (bool) {
        return _getStorage().reputationConfigured[agreementInstanceId];
    }

    // =============================================================
    // QUERY FUNCTIONS (delegatecall - cannot be view)
    // =============================================================

    /// @notice Check if caller can rate the arbitrator
    /// @dev Uses delegatecall so cannot be view
    /// @param agreementInstanceId The agreement instance ID
    /// @return canRate Whether caller can submit a rating
    /// @return reason Human-readable reason if not allowed
    function canRateArbitrator(bytes32 agreementInstanceId)
        external
        returns (bool canRate, string memory reason)
    {
        AdapterStorage storage $ = _getStorage();
        bytes32 reputationInstanceId = $.reputationInstanceIds[agreementInstanceId];
        address arbitrator = $.ratedArbitrators[agreementInstanceId];

        if (reputationInstanceId == bytes32(0)) {
            return (false, "Reputation window not open");
        }

        (bool success, bytes memory data) = address(reputationClause).delegatecall(
            abi.encodeCall(ReputationClauseLogicV3.queryCanRate, (reputationInstanceId, msg.sender, arbitrator))
        );

        if (!success) return (false, "Query failed");
        return abi.decode(data, (bool, string));
    }

    /// @notice Get the reputation window status
    /// @dev Uses delegatecall so cannot be view
    /// @param agreementInstanceId The agreement instance ID
    /// @return isOpen Whether window is open
    /// @return opensAt When window opened
    /// @return closesAt When window closes
    /// @return ratingsSubmitted Number of ratings submitted
    /// @return ratersCount Total eligible raters
    function getWindowStatus(bytes32 agreementInstanceId)
        external
        returns (bool isOpen, uint48 opensAt, uint48 closesAt, uint8 ratingsSubmitted, uint8 ratersCount)
    {
        AdapterStorage storage $ = _getStorage();
        bytes32 reputationInstanceId = $.reputationInstanceIds[agreementInstanceId];

        if (reputationInstanceId == bytes32(0)) {
            return (false, 0, 0, 0, 0);
        }

        (bool success, bytes memory data) = address(reputationClause).delegatecall(
            abi.encodeCall(ReputationClauseLogicV3.queryWindowStatus, (reputationInstanceId))
        );

        if (!success) return (false, 0, 0, 0, 0);
        return abi.decode(data, (bool, uint48, uint48, uint8, uint8));
    }

    // =============================================================
    // GLOBAL PROFILE QUERIES (delegatecall - cannot be view)
    // =============================================================

    /// @notice Get arbitrator's global reputation profile
    /// @dev Uses delegatecall so cannot be view
    /// @param arbitrator Address of arbitrator to query
    /// @return totalRatings Total number of ratings received
    /// @return averageScore Average score scaled by 100 (e.g., 450 = 4.50)
    /// @return firstRatingAt When first rated
    /// @return lastRatingAt When last rated
    function getArbitratorProfile(address arbitrator)
        external
        returns (uint64 totalRatings, uint16 averageScore, uint48 firstRatingAt, uint48 lastRatingAt)
    {
        (bool success, bytes memory data) =
            address(reputationClause).delegatecall(abi.encodeCall(ReputationClauseLogicV3.queryProfile, (arbitrator)));

        if (!success) return (0, 0, 0, 0);
        return abi.decode(data, (uint64, uint16, uint48, uint48));
    }

    /// @notice Get arbitrator's role-specific reputation
    /// @dev Uses delegatecall so cannot be view
    /// @param arbitrator Address of arbitrator to query
    /// @return count Number of ratings as arbitrator
    /// @return averageScore Average score scaled by 100
    function getArbitratorRoleReputation(address arbitrator) external returns (uint32 count, uint16 averageScore) {
        (bool success, bytes memory data) = address(reputationClause).delegatecall(
            abi.encodeCall(ReputationClauseLogicV3.queryRoleReputation, (arbitrator, ARBITRATOR_ROLE))
        );

        if (!success) return (0, 0);
        return abi.decode(data, (uint32, uint16));
    }

    /// @notice Get top arbitrators by reputation
    /// @dev Uses delegatecall so cannot be view
    /// @param limit Maximum number of arbitrators to return (0 = all)
    /// @param minRatings Minimum number of ratings required to be included
    /// @return arbitrators Addresses sorted by score descending
    /// @return scores Average scores scaled by 100
    function getTopArbitrators(uint8 limit, uint8 minRatings)
        external
        returns (address[] memory arbitrators, uint16[] memory scores)
    {
        (bool success, bytes memory data) = address(reputationClause).delegatecall(
            abi.encodeCall(ReputationClauseLogicV3.handoffTopSubjects, (bytes32(0), ARBITRATOR_ROLE, limit, minRatings))
        );

        if (!success) {
            return (new address[](0), new uint16[](0));
        }
        return abi.decode(data, (address[], uint16[]));
    }
}
