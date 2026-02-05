// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IDisputable
/// @notice Interface for agreements that support external arbitration
/// @dev Agreements implementing this interface can be linked to an ArbitrationAgreement
///      which manages the dispute resolution process. When the arbitrator rules,
///      ArbitrationAgreement calls executeArbitrationRuling() to trigger fund distribution.
///
///      USAGE FLOW:
///      1. Agreement created with arbitration config (or links arbitration later)
///      2. ArbitrationAgreement instance created, linked to this agreement
///      3. On dispute: parties interact with ArbitrationAgreement
///      4. When arbitrator rules: ArbitrationAgreement calls executeArbitrationRuling()
///      5. This agreement validates caller and distributes funds accordingly
interface IDisputable {
    /// @notice Execute an arbitration ruling from the linked ArbitrationAgreement
    /// @dev Only callable by the linked ArbitrationAgreement contract
    /// @param instanceId The agreement instance being ruled upon
    /// @param ruling The ruling: 1=CLAIMANT_WINS, 2=RESPONDENT_WINS, 3=SPLIT
    /// @param splitBasisPoints If SPLIT, claimant's share in basis points (0-10000)
    function executeArbitrationRuling(
        uint256 instanceId,
        uint8 ruling,
        uint256 splitBasisPoints
    ) external;

    /// @notice Check if arbitration can be initiated for an instance
    /// @dev Returns true if: instance is funded, not already in dispute, not completed
    /// @param instanceId The agreement instance to check
    /// @return canInitiate True if a dispute can be filed
    function canInitiateArbitration(uint256 instanceId) external view returns (bool canInitiate);

    /// @notice Get the linked ArbitrationAgreement address for an instance
    /// @param instanceId The agreement instance to query
    /// @return arbitrationAgreement The ArbitrationAgreement address (address(0) if none)
    function getArbitrationAgreement(uint256 instanceId) external view returns (address arbitrationAgreement);

    /// @notice Get the arbitration instance ID within the ArbitrationAgreement
    /// @param instanceId The agreement instance to query
    /// @return arbitrationInstanceId The instance ID in ArbitrationAgreement (0 if none)
    function getArbitrationInstanceId(uint256 instanceId) external view returns (uint256 arbitrationInstanceId);

    /// @notice Get the parties for arbitration purposes
    /// @dev Claimant is typically the party delivering work (contractor/freelancer)
    ///      Respondent is typically the party paying (client)
    /// @param instanceId The agreement instance to query
    /// @return claimant Default claimant address (e.g., contractor)
    /// @return respondent Default respondent address (e.g., client)
    function getArbitrationParties(uint256 instanceId) external view returns (
        address claimant,
        address respondent
    );

    /// @notice Link an ArbitrationAgreement to this instance
    /// @dev Can be called at creation or later (with appropriate consent checks)
    /// @param instanceId The agreement instance to link
    /// @param arbitrationAgreement The ArbitrationAgreement contract address
    /// @param arbitrationInstanceId The instance ID within ArbitrationAgreement
    function linkArbitration(
        uint256 instanceId,
        address arbitrationAgreement,
        uint256 arbitrationInstanceId
    ) external;

    /// @notice Check if an instance has arbitration linked
    /// @param instanceId The agreement instance to check
    /// @return hasArbitration True if arbitration is configured
    function hasArbitrationLinked(uint256 instanceId) external view returns (bool hasArbitration);

    /// @notice Check if an instance's dispute has been resolved
    /// @param instanceId The agreement instance to check
    /// @return isResolved True if ruling has been executed
    function isDisputeResolved(uint256 instanceId) external view returns (bool isResolved);

    // ═══════════════════════════════════════════════════════════════
    //                          EVENTS
    // ═══════════════════════════════════════════════════════════════

    /// @notice Emitted when arbitration is linked to an instance
    event ArbitrationLinked(
        uint256 indexed instanceId,
        address indexed arbitrationAgreement,
        uint256 arbitrationInstanceId
    );

    /// @notice Emitted when an arbitration ruling is executed
    event ArbitrationRulingExecuted(
        uint256 indexed instanceId,
        uint8 ruling,
        uint256 splitBasisPoints,
        address claimantPayout,
        address respondentPayout
    );
}
