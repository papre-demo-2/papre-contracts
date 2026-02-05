// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ClauseBase} from "../../base/ClauseBase.sol";

/// @title ReputationClauseLogicV3
/// @notice Self-describing reputation clause following v3 specification
/// @dev Logic contract executed via delegatecall from Agreement proxies.
///      Uses ERC-7201 namespaced storage to prevent collisions with other clauses.
///      All functions take instanceId as first parameter for multi-instance support.
///
///      Provides on-chain reputation tracking for any ratable subject:
///      - Configurable rating windows with visibility modes
///      - Role-based reputation (e.g., arbitrator, contractor, client)
///      - Global reputation profiles that aggregate across instances
///      - Anti-gaming measures (participant-only, one rating per instance)
///
///      State Machine:
///      ┌────────────────┐
///      │  Uninitialized │
///      │    (status=0)  │
///      └───────┬────────┘
///              │ intakeConfig()
///              ▼
///      ┌────────────────┐
///      │   CONFIGURED   │ ← Ready to open rating windows
///      │   (0x0002)     │
///      └───────┬────────┘
///              │ intakeRatingWindow()
///              ▼
///      ┌────────────────┐
///      │  WINDOW_OPEN   │ ← Accepting ratings
///      │   (0x0010)     │
///      └───────┬────────┘
///              │ window expires OR actionCloseWindow()
///              ▼
///      ┌────────────────┐
///      │ WINDOW_CLOSED  │ ← Terminal state (COMPLETE)
///      │   (0x0004)     │
///      └────────────────┘
contract ReputationClauseLogicV3 is ClauseBase {
    // =============================================================
    // CONSTANTS
    // =============================================================

    /// @notice Default rating window duration (14 days)
    uint32 public constant DEFAULT_RATING_WINDOW = 14 days;

    /// @notice Maximum score value (5 stars)
    uint8 public constant MAX_SCORE = 5;

    /// @notice Minimum score value (1 star)
    uint8 public constant MIN_SCORE = 1;

    /// @notice Maximum basis points (100%)
    uint16 public constant MAX_BPS = 10000;

    /// @notice Default weight (1.0x in basis points)
    uint16 public constant DEFAULT_WEIGHT = 10000;

    // =============================================================
    // EXTENDED STATES (bitmask)
    // =============================================================

    uint16 internal constant CONFIGURED = 1 << 1; // 0x0002 (same as PENDING)
    uint16 internal constant WINDOW_OPEN = 1 << 4; // 0x0010
    uint16 internal constant WINDOW_CLOSED = 1 << 2; // 0x0004 (same as COMPLETE)

    // =============================================================
    // WEIGHT STRATEGIES
    // =============================================================

    uint8 public constant WEIGHT_EQUAL = 0;
    uint8 public constant WEIGHT_OUTCOME = 1;
    uint8 public constant WEIGHT_ROLE = 2;

    // =============================================================
    // VISIBILITY MODES
    // =============================================================

    uint8 public constant VISIBILITY_IMMEDIATE = 0;
    uint8 public constant VISIBILITY_BLIND_UNTIL_ALL = 1;
    uint8 public constant VISIBILITY_AFTER_WINDOW = 2;

    // =============================================================
    // AGGREGATION METHODS
    // =============================================================

    uint8 public constant AGGREGATION_SIMPLE = 0;
    uint8 public constant AGGREGATION_WEIGHTED = 1;

    // =============================================================
    // OUTCOME TYPES
    // =============================================================

    uint8 public constant OUTCOME_NONE = 0;
    uint8 public constant OUTCOME_WINNER = 1;
    uint8 public constant OUTCOME_LOSER = 2;
    uint8 public constant OUTCOME_SPLIT = 3;

    // =============================================================
    // ERRORS
    // =============================================================

    error ZeroAddress();
    error WrongState(uint16 expected, uint16 actual);
    error NotEligibleRater(address caller);
    error NotRatableSubject(address subject);
    error AlreadyRated(address rater, address subject);
    error WindowClosed();
    error RatingWindowStillOpen();
    error UpdatesNotAllowed();
    error InvalidScore(uint8 score);
    error InvalidConfig();
    error ArrayLengthMismatch();

    // =============================================================
    // EVENTS
    // =============================================================

    event ReputationConfigured(
        bytes32 indexed instanceId,
        bytes32 indexed ratedRole,
        uint32 ratingWindowSeconds,
        uint8 visibilityMode
    );

    event RatingWindowOpened(
        bytes32 indexed instanceId,
        uint48 opensAt,
        uint48 closesAt,
        uint8 ratersCount,
        uint8 subjectsCount
    );

    event RatingSubmitted(
        bytes32 indexed instanceId,
        address indexed rater,
        address indexed subject,
        uint8 score,
        bytes32 feedbackCID
    );

    event RatingUpdated(
        bytes32 indexed instanceId,
        address indexed rater,
        address indexed subject,
        uint8 oldScore,
        uint8 newScore
    );

    event RatingWindowClosed(bytes32 indexed instanceId, uint8 totalRatings);

    event RatingsRevealed(bytes32 indexed instanceId, uint8 ratingsCount);

    // =============================================================
    // STRUCTS
    // =============================================================

    /// @notice Configuration for a reputation instance
    struct ReputationConfig {
        /// @notice Weight strategy: 0=equal, 1=outcome_weighted, 2=role_weighted
        uint8 weightStrategy;
        /// @notice For outcome_weighted (10000 = 1.0x, 15000 = 1.5x)
        uint16 winnerWeightBps;
        /// @notice Visibility: 0=immediate, 1=blind_until_all, 2=after_window
        uint8 visibilityMode;
        /// @notice How many must rate before reveal (for blind modes)
        uint8 blindThreshold;
        /// @notice How long window stays open
        uint32 ratingWindowSeconds;
        /// @notice Can change rating within window
        bool allowUpdates;
        /// @notice Aggregation: 0=simple_average, 1=weighted_average
        uint8 aggregationMethod;
        /// @notice Min ratings before showing aggregate
        uint8 minimumRatingsToDisplay;
        /// @notice Role being rated (e.g., keccak256("arbitrator"))
        bytes32 ratedRole;
    }

    /// @notice Individual rating record
    struct Rating {
        /// @notice Score 1-5 stars
        uint8 score;
        /// @notice When the rating was submitted
        uint48 timestamp;
        /// @notice Optional IPFS hash for text feedback
        bytes32 feedbackCID;
        /// @notice Applied weight (in basis points)
        uint16 weight;
        /// @notice Whether currently visible
        bool visible;
        /// @notice Whether this rating exists
        bool exists;
    }

    /// @notice Global reputation profile for a subject
    struct ReputationProfile {
        /// @notice Total number of ratings received
        uint64 totalRatings;
        /// @notice Sum of all scores (for simple average)
        uint64 sumScores;
        /// @notice Weighted sum of scores (scaled by 10000)
        uint64 weightedSumScores;
        /// @notice Total weight applied (scaled by 10000)
        uint64 weightedCount;
        /// @notice When first rated
        uint48 firstRatingAt;
        /// @notice When last rated
        uint48 lastRatingAt;
    }

    /// @notice Role-specific statistics
    struct RoleStats {
        /// @notice Number of ratings for this role
        uint32 count;
        /// @notice Sum of scores
        uint32 sumScores;
        /// @notice Weighted sum (scaled)
        uint32 weightedSum;
        /// @notice Total weight applied
        uint32 weightedCount;
    }

    // =============================================================
    // ERC-7201 NAMESPACED STORAGE
    // =============================================================

    /// @custom:storage-location erc7201:papre.clause.reputation.storage
    struct ReputationStorage {
        // ═══════════════════════════════════════════════════════════════
        // INSTANCE CONFIG (set at intake, immutable per instance)
        // ═══════════════════════════════════════════════════════════════
        mapping(bytes32 => ReputationConfig) configs;
        // ═══════════════════════════════════════════════════════════════
        // RATING WINDOWS (per instance)
        // ═══════════════════════════════════════════════════════════════
        mapping(bytes32 => uint16) status;
        mapping(bytes32 => uint48) windowOpensAt;
        mapping(bytes32 => uint48) windowClosesAt;
        mapping(bytes32 => address[]) eligibleRaters;
        mapping(bytes32 => address[]) ratableSubjects;
        mapping(bytes32 => mapping(address => uint8)) raterOutcome;
        // ═══════════════════════════════════════════════════════════════
        // RATINGS (per instance, per rater, per subject)
        // ═══════════════════════════════════════════════════════════════
        mapping(bytes32 => mapping(address => mapping(address => Rating))) ratings;
        mapping(bytes32 => uint8) ratingsCount;
        // ═══════════════════════════════════════════════════════════════
        // GLOBAL REPUTATION PROFILES (cross-instance aggregates)
        // ═══════════════════════════════════════════════════════════════
        mapping(address => ReputationProfile) profiles;
        mapping(address => mapping(bytes32 => RoleStats)) roleStats;
        // ═══════════════════════════════════════════════════════════════
        // SUBJECT TRACKING BY ROLE (for handoffTopSubjects)
        // ═══════════════════════════════════════════════════════════════
        mapping(bytes32 => address[]) subjectsByRole;
        mapping(bytes32 => mapping(address => bool)) isSubjectInRole;
    }

    // keccak256(abi.encode(uint256(keccak256("papre.clause.reputation.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT = 0x7a9c0e5d1f8b3a2c4d6e0f9a8b7c5d4e3f2a1b0c9d8e7f6a5b4c3d2e1f0a9b00;

    function _getStorage() internal pure returns (ReputationStorage storage $) {
        assembly {
            $.slot := STORAGE_SLOT
        }
    }

    // =============================================================
    // INTAKE (from previous clause or setup)
    // =============================================================

    /// @notice Configure a reputation instance
    /// @param instanceId Unique identifier for this reputation instance
    /// @param config Configuration parameters
    function intakeConfig(bytes32 instanceId, ReputationConfig calldata config) external {
        ReputationStorage storage $ = _getStorage();
        require($.status[instanceId] == 0, "Wrong state");

        // Validate config
        if (config.ratingWindowSeconds == 0) revert InvalidConfig();
        if (config.visibilityMode > VISIBILITY_AFTER_WINDOW) revert InvalidConfig();
        if (config.weightStrategy > WEIGHT_ROLE) revert InvalidConfig();
        if (config.aggregationMethod > AGGREGATION_WEIGHTED) revert InvalidConfig();

        $.configs[instanceId] = config;
        $.status[instanceId] = CONFIGURED;

        emit ReputationConfigured(
            instanceId, config.ratedRole, config.ratingWindowSeconds, config.visibilityMode
        );
    }

    /// @notice Open a rating window after an event (e.g., dispute resolved)
    /// @param instanceId The instance to open rating for
    /// @param raters Addresses eligible to rate
    /// @param subjects Addresses that can be rated
    /// @param outcomes Outcome for each rater (1=winner, 2=loser, 3=split)
    function intakeRatingWindow(
        bytes32 instanceId,
        address[] calldata raters,
        address[] calldata subjects,
        uint8[] calldata outcomes
    ) external {
        ReputationStorage storage $ = _getStorage();
        uint16 status = $.status[instanceId];
        if (status != CONFIGURED) revert WrongState(CONFIGURED, status);

        if (raters.length != outcomes.length) revert ArrayLengthMismatch();
        if (raters.length == 0) revert InvalidConfig();
        if (subjects.length == 0) revert InvalidConfig();

        // Validate addresses
        for (uint256 i = 0; i < raters.length; i++) {
            if (raters[i] == address(0)) revert ZeroAddress();
        }
        for (uint256 i = 0; i < subjects.length; i++) {
            if (subjects[i] == address(0)) revert ZeroAddress();
        }

        // Store raters and their outcomes
        $.eligibleRaters[instanceId] = raters;
        for (uint256 i = 0; i < raters.length; i++) {
            $.raterOutcome[instanceId][raters[i]] = outcomes[i];
        }

        // Store subjects
        $.ratableSubjects[instanceId] = subjects;

        // Set window timing
        uint48 opensAt = uint48(block.timestamp);
        uint48 closesAt = opensAt + uint48($.configs[instanceId].ratingWindowSeconds);
        $.windowOpensAt[instanceId] = opensAt;
        $.windowClosesAt[instanceId] = closesAt;

        $.status[instanceId] = WINDOW_OPEN;

        emit RatingWindowOpened(
            instanceId, opensAt, closesAt, uint8(raters.length), uint8(subjects.length)
        );
    }

    // =============================================================
    // ACTIONS (state-changing)
    // =============================================================

    /// @notice Submit a rating for a subject
    /// @param instanceId The rating instance
    /// @param subject Who is being rated
    /// @param score Rating 1-5
    /// @param feedbackCID Optional IPFS hash for text feedback
    /// @custom:papre-style primary
    function actionSubmitRating(bytes32 instanceId, address subject, uint8 score, bytes32 feedbackCID)
        external
    {
        ReputationStorage storage $ = _getStorage();
        uint16 status = $.status[instanceId];
        if (status != WINDOW_OPEN) revert WrongState(WINDOW_OPEN, status);

        // Check window is open
        if (block.timestamp > $.windowClosesAt[instanceId]) {
            revert WindowClosed();
        }

        // Validate caller is eligible
        if (!_isEligibleRater($, instanceId, msg.sender)) {
            revert NotEligibleRater(msg.sender);
        }

        // Validate subject is ratable
        if (!_isRatableSubject($, instanceId, subject)) {
            revert NotRatableSubject(subject);
        }

        // Check not already rated
        if ($.ratings[instanceId][msg.sender][subject].exists) {
            revert AlreadyRated(msg.sender, subject);
        }

        // Validate score
        if (score < MIN_SCORE || score > MAX_SCORE) {
            revert InvalidScore(score);
        }

        // Calculate weight
        uint16 weight = _calculateWeight($, instanceId, msg.sender);

        // Determine visibility
        bool visible = $.configs[instanceId].visibilityMode == VISIBILITY_IMMEDIATE;

        // Store rating
        $.ratings[instanceId][msg.sender][subject] = Rating({
            score: score,
            timestamp: uint48(block.timestamp),
            feedbackCID: feedbackCID,
            weight: weight,
            visible: visible,
            exists: true
        });
        $.ratingsCount[instanceId]++;

        // Update global profile
        _updateProfile($, subject, score, weight, $.configs[instanceId].ratedRole);

        emit RatingSubmitted(instanceId, msg.sender, subject, score, feedbackCID);

        // Check if blind reveal threshold met
        if (
            $.configs[instanceId].visibilityMode == VISIBILITY_BLIND_UNTIL_ALL
                && $.ratingsCount[instanceId] >= $.configs[instanceId].blindThreshold
        ) {
            _revealRatings($, instanceId);
        }
    }

    /// @notice Update an existing rating (if config allows)
    /// @param instanceId The rating instance
    /// @param subject Who was rated
    /// @param score New rating 1-5
    /// @param feedbackCID New feedback CID
    function actionUpdateRating(bytes32 instanceId, address subject, uint8 score, bytes32 feedbackCID)
        external
    {
        ReputationStorage storage $ = _getStorage();
        uint16 status = $.status[instanceId];
        if (status != WINDOW_OPEN) revert WrongState(WINDOW_OPEN, status);

        if (!$.configs[instanceId].allowUpdates) {
            revert UpdatesNotAllowed();
        }

        // Check window is open
        if (block.timestamp > $.windowClosesAt[instanceId]) {
            revert WindowClosed();
        }

        // Check rating exists
        Rating storage existingRating = $.ratings[instanceId][msg.sender][subject];
        if (!existingRating.exists) {
            revert NotEligibleRater(msg.sender);
        }

        // Validate score
        if (score < MIN_SCORE || score > MAX_SCORE) {
            revert InvalidScore(score);
        }

        uint8 oldScore = existingRating.score;

        // Update global profile (subtract old, add new)
        _updateProfileForChange($, subject, oldScore, score, existingRating.weight, $.configs[instanceId].ratedRole);

        // Update rating
        existingRating.score = score;
        existingRating.timestamp = uint48(block.timestamp);
        existingRating.feedbackCID = feedbackCID;

        emit RatingUpdated(instanceId, msg.sender, subject, oldScore, score);
    }

    /// @notice Close rating window early (admin only via Agreement)
    /// @param instanceId The rating instance to close
    /// @custom:papre-style destructive
    function actionCloseWindow(bytes32 instanceId) external {
        ReputationStorage storage $ = _getStorage();
        uint16 status = $.status[instanceId];
        if (status != WINDOW_OPEN) revert WrongState(WINDOW_OPEN, status);

        $.status[instanceId] = WINDOW_CLOSED;

        // Reveal if in blind mode
        if ($.configs[instanceId].visibilityMode != VISIBILITY_IMMEDIATE) {
            _revealRatings($, instanceId);
        }

        emit RatingWindowClosed(instanceId, $.ratingsCount[instanceId]);
    }

    /// @notice Reveal ratings (for blind modes) - callable after window closes
    /// @param instanceId The rating instance
    function actionRevealRatings(bytes32 instanceId) external {
        ReputationStorage storage $ = _getStorage();
        uint16 status = $.status[instanceId];

        // Can reveal if window closed or deadline passed
        bool windowExpired = status == WINDOW_OPEN && block.timestamp > $.windowClosesAt[instanceId];
        bool alreadyClosed = status == WINDOW_CLOSED;

        if (!windowExpired && !alreadyClosed) {
            revert RatingWindowStillOpen();
        }

        // Auto-close if expired but not closed
        if (windowExpired) {
            $.status[instanceId] = WINDOW_CLOSED;
            emit RatingWindowClosed(instanceId, $.ratingsCount[instanceId]);
        }

        _revealRatings($, instanceId);
    }

    // =============================================================
    // QUERIES (always available)
    // =============================================================

    /// @notice Get the current state of an instance
    /// @param instanceId Unique identifier for this reputation instance
    /// @return Current state bitmask
    function queryStatus(bytes32 instanceId) external view returns (uint16) {
        return _getStorage().status[instanceId];
    }

    /// @notice Get the configuration for an instance
    /// @param instanceId Unique identifier for this reputation instance
    /// @return The configuration struct
    function queryConfig(bytes32 instanceId) external view returns (ReputationConfig memory) {
        return _getStorage().configs[instanceId];
    }

    /// @notice Check if someone can rate a subject
    /// @param instanceId The rating instance
    /// @param rater Address of potential rater
    /// @param subject Address to be rated
    /// @return canRate Whether the rating is allowed
    /// @return reason Human-readable reason if not allowed
    function queryCanRate(bytes32 instanceId, address rater, address subject)
        external
        view
        returns (bool canRate, string memory reason)
    {
        ReputationStorage storage $ = _getStorage();

        if ($.status[instanceId] != WINDOW_OPEN) {
            return (false, "Window not open");
        }
        if (block.timestamp > $.windowClosesAt[instanceId]) {
            return (false, "Window expired");
        }
        if (!_isEligibleRater($, instanceId, rater)) {
            return (false, "Not eligible rater");
        }
        if (!_isRatableSubject($, instanceId, subject)) {
            return (false, "Not ratable subject");
        }
        if ($.ratings[instanceId][rater][subject].exists) {
            return (false, "Already rated");
        }

        return (true, "");
    }

    /// @notice Get window status
    /// @param instanceId The rating instance
    /// @return isOpen Whether window is open
    /// @return opensAt When window opened
    /// @return closesAt When window closes
    /// @return ratingsSubmitted Number of ratings submitted
    /// @return ratersCount Total eligible raters
    function queryWindowStatus(bytes32 instanceId)
        external
        view
        returns (bool isOpen, uint48 opensAt, uint48 closesAt, uint8 ratingsSubmitted, uint8 ratersCount)
    {
        ReputationStorage storage $ = _getStorage();
        uint16 status = $.status[instanceId];

        isOpen = status == WINDOW_OPEN && block.timestamp <= $.windowClosesAt[instanceId];
        opensAt = $.windowOpensAt[instanceId];
        closesAt = $.windowClosesAt[instanceId];
        ratingsSubmitted = $.ratingsCount[instanceId];
        ratersCount = uint8($.eligibleRaters[instanceId].length);
    }

    /// @notice Get a subject's global reputation profile
    /// @param subject Address to query
    /// @return totalRatings Total number of ratings received
    /// @return averageScore Average score scaled by 100 (e.g., 450 = 4.50)
    /// @return firstRatingAt When first rated
    /// @return lastRatingAt When last rated
    function queryProfile(address subject)
        external
        view
        returns (uint64 totalRatings, uint16 averageScore, uint48 firstRatingAt, uint48 lastRatingAt)
    {
        ReputationStorage storage $ = _getStorage();
        ReputationProfile storage profile = $.profiles[subject];

        totalRatings = profile.totalRatings;
        firstRatingAt = profile.firstRatingAt;
        lastRatingAt = profile.lastRatingAt;

        if (totalRatings > 0) {
            // Scale by 100 for 2 decimal places
            averageScore = uint16((profile.sumScores * 100) / totalRatings);
        }
    }

    /// @notice Get role-specific reputation
    /// @param subject Address to query
    /// @param role Role identifier (e.g., keccak256("arbitrator"))
    /// @return count Number of ratings for this role
    /// @return averageScore Average score scaled by 100
    function queryRoleReputation(address subject, bytes32 role)
        external
        view
        returns (uint32 count, uint16 averageScore)
    {
        ReputationStorage storage $ = _getStorage();
        RoleStats storage stats = $.roleStats[subject][role];

        count = stats.count;
        if (count > 0) {
            averageScore = uint16((stats.sumScores * 100) / count);
        }
    }

    /// @notice Get a specific rating
    /// @param instanceId The rating instance
    /// @param rater Who gave the rating
    /// @param subject Who was rated
    /// @return rating The rating details (may have visible=false)
    function queryRating(bytes32 instanceId, address rater, address subject)
        external
        view
        returns (Rating memory rating)
    {
        return _getStorage().ratings[instanceId][rater][subject];
    }

    /// @notice Get eligible raters for an instance
    /// @param instanceId The rating instance
    /// @return raters Array of eligible rater addresses
    function queryEligibleRaters(bytes32 instanceId) external view returns (address[] memory raters) {
        return _getStorage().eligibleRaters[instanceId];
    }

    /// @notice Get ratable subjects for an instance
    /// @param instanceId The rating instance
    /// @return subjects Array of ratable subject addresses
    function queryRatableSubjects(bytes32 instanceId)
        external
        view
        returns (address[] memory subjects)
    {
        return _getStorage().ratableSubjects[instanceId];
    }

    /// @notice Get the outcome assigned to a rater
    /// @param instanceId The rating instance
    /// @param rater The rater address
    /// @return outcome The outcome type (0=none, 1=winner, 2=loser, 3=split)
    function queryRaterOutcome(bytes32 instanceId, address rater) external view returns (uint8 outcome) {
        return _getStorage().raterOutcome[instanceId][rater];
    }

    /// @notice Get total ratings count for an instance
    /// @param instanceId The rating instance
    /// @return count Number of ratings submitted
    function queryRatingsCount(bytes32 instanceId) external view returns (uint8 count) {
        return _getStorage().ratingsCount[instanceId];
    }

    // =============================================================
    // HANDOFF (to next clause / agreement)
    // =============================================================

    /// @notice Get top-rated subjects for a role (for arbitrator selection)
    /// @dev Returns subjects sorted by score descending, filtered by minimum ratings
    /// @param instanceId Unused (kept for v3 interface consistency)
    /// @param role Role identifier (e.g., keccak256("arbitrator"))
    /// @param limit Maximum number of subjects to return (0 = all)
    /// @param minRatings Minimum number of ratings required to be included
    /// @return subjects Addresses of top subjects (sorted by score descending)
    /// @return scores Average scores (scaled by 100)
    function handoffTopSubjects(bytes32 instanceId, bytes32 role, uint8 limit, uint8 minRatings)
        external
        view
        returns (address[] memory subjects, uint16[] memory scores)
    {
        (instanceId); // Silence unused warning

        ReputationStorage storage $ = _getStorage();
        address[] storage allSubjects = $.subjectsByRole[role];
        uint256 totalSubjects = allSubjects.length;

        if (totalSubjects == 0) {
            return (new address[](0), new uint16[](0));
        }

        // First pass: count qualifying subjects
        uint256 qualifyingCount = 0;
        for (uint256 i = 0; i < totalSubjects; i++) {
            RoleStats storage stats = $.roleStats[allSubjects[i]][role];
            if (stats.count >= minRatings) {
                qualifyingCount++;
            }
        }

        if (qualifyingCount == 0) {
            return (new address[](0), new uint16[](0));
        }

        // Determine result size
        uint256 resultSize = limit == 0 ? qualifyingCount : (qualifyingCount < limit ? qualifyingCount : limit);

        // Build arrays of qualifying subjects and their scores
        address[] memory tempSubjects = new address[](qualifyingCount);
        uint16[] memory tempScores = new uint16[](qualifyingCount);
        uint256 idx = 0;

        for (uint256 i = 0; i < totalSubjects && idx < qualifyingCount; i++) {
            RoleStats storage stats = $.roleStats[allSubjects[i]][role];
            if (stats.count >= minRatings) {
                tempSubjects[idx] = allSubjects[i];
                tempScores[idx] = uint16((uint256(stats.sumScores) * 100) / stats.count);
                idx++;
            }
        }

        // Sort by score descending (simple insertion sort - fine for small arrays)
        for (uint256 i = 1; i < qualifyingCount; i++) {
            uint16 keyScore = tempScores[i];
            address keySubject = tempSubjects[i];
            int256 j = int256(i) - 1;

            while (j >= 0 && tempScores[uint256(j)] < keyScore) {
                tempScores[uint256(j + 1)] = tempScores[uint256(j)];
                tempSubjects[uint256(j + 1)] = tempSubjects[uint256(j)];
                j--;
            }
            tempScores[uint256(j + 1)] = keyScore;
            tempSubjects[uint256(j + 1)] = keySubject;
        }

        // Return limited results
        subjects = new address[](resultSize);
        scores = new uint16[](resultSize);
        for (uint256 i = 0; i < resultSize; i++) {
            subjects[i] = tempSubjects[i];
            scores[i] = tempScores[i];
        }
    }

    /// @notice Get average score for a subject (for gating)
    /// @param instanceId The instance (unused, for interface consistency)
    /// @param subject Address to query
    /// @return score Average score (scaled by 100)
    /// @return count Total number of ratings
    function handoffSubjectScore(bytes32 instanceId, address subject)
        external
        view
        returns (uint16 score, uint64 count)
    {
        (instanceId); // Silence unused warning

        ReputationStorage storage $ = _getStorage();
        ReputationProfile storage profile = $.profiles[subject];

        count = profile.totalRatings;
        if (count > 0) {
            score = uint16((profile.sumScores * 100) / count);
        }
    }

    /// @notice Get weighted average score for a subject
    /// @param instanceId The instance (unused, for interface consistency)
    /// @param subject Address to query
    /// @return score Weighted average score (scaled by 100)
    /// @return totalWeight Total weight applied
    function handoffSubjectScoreWeighted(bytes32 instanceId, address subject)
        external
        view
        returns (uint16 score, uint64 totalWeight)
    {
        (instanceId); // Silence unused warning

        ReputationStorage storage $ = _getStorage();
        ReputationProfile storage profile = $.profiles[subject];

        totalWeight = profile.weightedCount;
        if (totalWeight > 0) {
            // weightedSumScores is score * weight, divide by total weight, scale by 100
            score = uint16((profile.weightedSumScores * 100) / totalWeight);
        }
    }

    /// @notice Get all subjects rated for a specific role
    /// @param instanceId The instance (unused, for interface consistency)
    /// @param role Role identifier (e.g., keccak256("arbitrator"))
    /// @return subjects Array of addresses that have been rated in this role
    function handoffSubjectsByRole(bytes32 instanceId, bytes32 role)
        external
        view
        returns (address[] memory subjects)
    {
        (instanceId); // Silence unused warning
        return _getStorage().subjectsByRole[role];
    }

    /// @notice Get role-specific weighted average
    /// @param subject Address to query
    /// @param role Role identifier
    /// @return count Number of ratings
    /// @return averageScore Simple average (scaled by 100)
    /// @return weightedScore Weighted average (scaled by 100)
    function handoffRoleReputationWeighted(address subject, bytes32 role)
        external
        view
        returns (uint32 count, uint16 averageScore, uint16 weightedScore)
    {
        ReputationStorage storage $ = _getStorage();
        RoleStats storage stats = $.roleStats[subject][role];

        count = stats.count;
        if (count > 0) {
            averageScore = uint16((uint256(stats.sumScores) * 100) / count);
            if (stats.weightedCount > 0) {
                weightedScore = uint16((uint256(stats.weightedSum) * 100) / stats.weightedCount);
            }
        }
    }

    /// @notice Get time-decayed score for a subject
    /// @dev Uses exponential decay: score * 2^(-age/halfLife)
    ///      Approximated using linear decay for gas efficiency
    /// @param instanceId The instance (unused, for interface consistency)
    /// @param subject Address to query
    /// @param halfLifeDays Number of days for score to decay by 50%
    /// @return score Time-decayed average score (scaled by 100)
    /// @return count Total number of ratings
    /// @return decayFactor Current decay factor (10000 = 100%, 5000 = 50%)
    function handoffSubjectScoreWithDecay(bytes32 instanceId, address subject, uint32 halfLifeDays)
        external
        view
        returns (uint16 score, uint64 count, uint16 decayFactor)
    {
        (instanceId); // Silence unused warning

        ReputationStorage storage $ = _getStorage();
        ReputationProfile storage profile = $.profiles[subject];

        count = profile.totalRatings;
        if (count == 0 || halfLifeDays == 0) {
            return (0, count, MAX_BPS);
        }

        // Calculate days since last rating
        uint256 daysSinceLastRating = (block.timestamp - profile.lastRatingAt) / 1 days;

        // Linear approximation of exponential decay
        // decay = max(0, 1 - daysSinceLastRating / (2 * halfLifeDays))
        // This reaches 0 after 2 * halfLifeDays
        uint256 maxDays = uint256(halfLifeDays) * 2;
        if (daysSinceLastRating >= maxDays) {
            decayFactor = 0;
            score = 0;
        } else {
            decayFactor = uint16(MAX_BPS - (daysSinceLastRating * MAX_BPS / maxDays));
            uint256 baseScore = (profile.sumScores * 100) / count;
            score = uint16((baseScore * decayFactor) / MAX_BPS);
        }
    }

    // =============================================================
    // INTERNAL HELPERS
    // =============================================================

    /// @notice Check if address is an eligible rater
    function _isEligibleRater(ReputationStorage storage $, bytes32 instanceId, address rater)
        internal
        view
        returns (bool)
    {
        address[] storage raters = $.eligibleRaters[instanceId];
        for (uint256 i = 0; i < raters.length; i++) {
            if (raters[i] == rater) return true;
        }
        return false;
    }

    /// @notice Check if address is a ratable subject
    function _isRatableSubject(ReputationStorage storage $, bytes32 instanceId, address subject)
        internal
        view
        returns (bool)
    {
        address[] storage subjects = $.ratableSubjects[instanceId];
        for (uint256 i = 0; i < subjects.length; i++) {
            if (subjects[i] == subject) return true;
        }
        return false;
    }

    /// @notice Calculate weight for a rater based on strategy
    function _calculateWeight(ReputationStorage storage $, bytes32 instanceId, address rater)
        internal
        view
        returns (uint16)
    {
        ReputationConfig storage config = $.configs[instanceId];

        if (config.weightStrategy == WEIGHT_EQUAL) {
            return DEFAULT_WEIGHT;
        }

        if (config.weightStrategy == WEIGHT_OUTCOME) {
            uint8 outcome = $.raterOutcome[instanceId][rater];
            if (outcome == OUTCOME_WINNER) {
                return config.winnerWeightBps;
            }
            // Losers get inverse weight
            if (outcome == OUTCOME_LOSER && config.winnerWeightBps > DEFAULT_WEIGHT) {
                return DEFAULT_WEIGHT - (config.winnerWeightBps - DEFAULT_WEIGHT);
            }
        }

        return DEFAULT_WEIGHT;
    }

    /// @notice Update global profile with new rating
    function _updateProfile(
        ReputationStorage storage $,
        address subject,
        uint8 score,
        uint16 weight,
        bytes32 role
    ) internal {
        ReputationProfile storage profile = $.profiles[subject];

        profile.totalRatings++;
        profile.sumScores += score;
        profile.weightedSumScores += uint64(score) * uint64(weight);
        profile.weightedCount += weight;
        profile.lastRatingAt = uint48(block.timestamp);

        if (profile.firstRatingAt == 0) {
            profile.firstRatingAt = uint48(block.timestamp);
        }

        // Update role-specific stats
        if (role != bytes32(0)) {
            RoleStats storage stats = $.roleStats[subject][role];
            stats.count++;
            stats.sumScores += score;
            stats.weightedSum += uint32(score) * uint32(weight);
            stats.weightedCount += uint32(weight);

            // Track subject in role list (for handoffTopSubjects)
            if (!$.isSubjectInRole[role][subject]) {
                $.isSubjectInRole[role][subject] = true;
                $.subjectsByRole[role].push(subject);
            }
        }
    }

    /// @notice Update global profile when rating changes
    function _updateProfileForChange(
        ReputationStorage storage $,
        address subject,
        uint8 oldScore,
        uint8 newScore,
        uint16 weight,
        bytes32 role
    ) internal {
        ReputationProfile storage profile = $.profiles[subject];

        // Adjust sums (totalRatings stays the same)
        profile.sumScores = profile.sumScores - oldScore + newScore;
        profile.weightedSumScores =
            profile.weightedSumScores - (uint64(oldScore) * uint64(weight)) + (uint64(newScore) * uint64(weight));
        profile.lastRatingAt = uint48(block.timestamp);

        // Update role-specific stats
        if (role != bytes32(0)) {
            RoleStats storage stats = $.roleStats[subject][role];
            stats.sumScores = stats.sumScores - oldScore + newScore;
            stats.weightedSum = stats.weightedSum - (uint32(oldScore) * uint32(weight))
                + (uint32(newScore) * uint32(weight));
        }
    }

    /// @notice Reveal all ratings for an instance
    function _revealRatings(ReputationStorage storage $, bytes32 instanceId) internal {
        address[] storage raters = $.eligibleRaters[instanceId];
        address[] storage subjects = $.ratableSubjects[instanceId];
        uint8 revealedCount = 0;

        for (uint256 i = 0; i < raters.length; i++) {
            for (uint256 j = 0; j < subjects.length; j++) {
                Rating storage rating = $.ratings[instanceId][raters[i]][subjects[j]];
                if (rating.exists && !rating.visible) {
                    rating.visible = true;
                    revealedCount++;
                }
            }
        }

        if (revealedCount > 0) {
            emit RatingsRevealed(instanceId, revealedCount);
        }
    }
}
