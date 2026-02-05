// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IReputationClause
/// @notice Interface for querying reputation data from external contracts
/// @dev This interface exposes only the query and handoff functions that external
///      contracts (like arbitrator selection systems) might need to call.
interface IReputationClause {
    // =============================================================
    // STRUCTS
    // =============================================================

    struct ReputationConfig {
        uint8 weightStrategy;
        uint16 winnerWeightBps;
        uint8 visibilityMode;
        uint8 blindThreshold;
        uint32 ratingWindowSeconds;
        bool allowUpdates;
        uint8 aggregationMethod;
        uint8 minimumRatingsToDisplay;
        bytes32 ratedRole;
    }

    struct Rating {
        uint8 score;
        uint48 timestamp;
        bytes32 feedbackCID;
        uint16 weight;
        bool visible;
        bool exists;
    }

    // =============================================================
    // QUERIES
    // =============================================================

    /// @notice Get the current state of an instance
    function queryStatus(bytes32 instanceId) external view returns (uint16);

    /// @notice Get the configuration for an instance
    function queryConfig(bytes32 instanceId) external view returns (ReputationConfig memory);

    /// @notice Check if someone can rate a subject
    function queryCanRate(bytes32 instanceId, address rater, address subject)
        external
        view
        returns (bool canRate, string memory reason);

    /// @notice Get window status
    function queryWindowStatus(bytes32 instanceId)
        external
        view
        returns (
            bool isOpen,
            uint48 opensAt,
            uint48 closesAt,
            uint8 ratingsSubmitted,
            uint8 ratersCount
        );

    /// @notice Get a subject's global reputation profile
    function queryProfile(address subject)
        external
        view
        returns (
            uint64 totalRatings,
            uint16 averageScore,
            uint48 firstRatingAt,
            uint48 lastRatingAt
        );

    /// @notice Get role-specific reputation
    function queryRoleReputation(address subject, bytes32 role)
        external
        view
        returns (uint32 count, uint16 averageScore);

    /// @notice Get a specific rating
    function queryRating(bytes32 instanceId, address rater, address subject)
        external
        view
        returns (Rating memory rating);

    /// @notice Get eligible raters for an instance
    function queryEligibleRaters(bytes32 instanceId)
        external
        view
        returns (address[] memory raters);

    /// @notice Get ratable subjects for an instance
    function queryRatableSubjects(bytes32 instanceId)
        external
        view
        returns (address[] memory subjects);

    /// @notice Get the outcome assigned to a rater
    function queryRaterOutcome(bytes32 instanceId, address rater)
        external
        view
        returns (uint8 outcome);

    /// @notice Get total ratings count for an instance
    function queryRatingsCount(bytes32 instanceId) external view returns (uint8 count);

    // =============================================================
    // HANDOFF
    // =============================================================

    /// @notice Get top-rated subjects for a role
    function handoffTopSubjects(
        bytes32 instanceId,
        bytes32 role,
        uint8 limit,
        uint8 minRatings
    ) external view returns (address[] memory subjects, uint16[] memory scores);

    /// @notice Get average score for a subject
    function handoffSubjectScore(bytes32 instanceId, address subject)
        external
        view
        returns (uint16 score, uint64 count);
}
