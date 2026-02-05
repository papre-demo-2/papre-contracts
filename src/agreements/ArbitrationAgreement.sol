// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IDisputable} from "../interfaces/IDisputable.sol";

/// @title ArbitrationAgreement
/// @notice Standalone arbitration protocol that manages disputes for IDisputable agreements
/// @dev Singleton pattern - one deployment serves all arbitrations on the chain.
///      Links to IDisputable agreements and executes rulings that trigger fund distribution.
///
///      PRESETS:
///      - SIMPLE: Single arbitrator, 7-day evidence window, no appeals, fees split 50/50
///      - BALANCED: Single arbitrator (mutual), 14-day evidence, one appeal, loser pays
///      - PANEL: 3 arbitrators, 21-day evidence, majority vote, no appeals
///      - CUSTOM: Full control over all parameters
///
///      STATE MACHINE:
///      ┌──────────────┐
///      │  CONFIGURED  │ ← Arbitration linked, waiting for dispute
///      │   (0x0002)   │
///      └──────┬───────┘
///             │ fileClaim()
///             ▼
///      ┌──────────────┐
///      │    FILED     │ ← Claim filed, evidence period
///      │   (0x0010)   │
///      └──────┬───────┘
///             │ evidence deadline or closeEvidence()
///             ▼
///      ┌──────────────┐
///      │  AWAITING    │ ← Evidence closed, awaiting ruling
///      │   (0x0020)   │
///      └──────┬───────┘
///             │ rule() [arbitrator(s)]
///             ▼
///      ┌──────────────┐        appeal()
///      │    RULED     │ ◄──────────────┐
///      │   (0x0040)   │                │
///      └──────┬───────┘                │
///             │ appeal window expires  │
///             │ or no appeals allowed  │
///             ▼                        │
///      ┌──────────────┐        ┌───────┴──────┐
///      │   EXECUTED   │        │   APPEALED   │
///      │   (0x0004)   │        │   (0x0080)   │
///      └──────────────┘        └──────────────┘
contract ArbitrationAgreement {
    // ═══════════════════════════════════════════════════════════════
    //                        CONSTANTS
    // ═══════════════════════════════════════════════════════════════

    uint16 public constant MAX_SPLIT = 10000; // 100% in basis points
    uint8 public constant MAX_ARBITRATORS = 3;

    // Preset IDs
    uint8 public constant PRESET_SIMPLE = 1;
    uint8 public constant PRESET_BALANCED = 2;
    uint8 public constant PRESET_PANEL = 3;
    uint8 public constant PRESET_CUSTOM = 4;

    // Resolution methods
    uint8 public constant RESOLUTION_SINGLE_CREATOR = 1;   // Creator picks arbitrator
    uint8 public constant RESOLUTION_SINGLE_MUTUAL = 2;    // Both parties must agree
    uint8 public constant RESOLUTION_TWO_PARTY = 3;        // Each party picks one
    uint8 public constant RESOLUTION_PANEL = 4;            // 3 arbitrators

    // Fee payment methods
    uint8 public constant FEE_SPLIT = 1;          // Split 50/50
    uint8 public constant FEE_LOSER_PAYS = 2;     // Loser pays all
    uint8 public constant FEE_CLAIMANT_PAYS = 3;  // Claimant pays
    uint8 public constant FEE_RESPONDENT_PAYS = 4; // Respondent pays

    // Withdrawal policies
    uint8 public constant WITHDRAW_ANYTIME = 1;       // Before ruling
    uint8 public constant WITHDRAW_MUTUAL = 2;        // Both must agree
    uint8 public constant WITHDRAW_NOT_ALLOWED = 3;   // Cannot withdraw

    // Voting methods (for multi-arbitrator)
    uint8 public constant VOTE_UNANIMOUS = 1;
    uint8 public constant VOTE_MAJORITY = 2;

    // Deadlock resolution
    uint8 public constant DEADLOCK_TIEBREAKER = 1;     // Third arbitrator decides
    uint8 public constant DEADLOCK_FUNDS_RETURNED = 2; // Return to original state
    uint8 public constant DEADLOCK_TIMEOUT_DEFAULT = 3; // Default to claimant after timeout

    // Replacement triggers (bitmask)
    uint8 public constant REPLACE_DEATH = 1;
    uint8 public constant REPLACE_INCAPACITY = 2;
    uint8 public constant REPLACE_CONFLICT = 4;
    uint8 public constant REPLACE_TIMEOUT = 8;

    // Replacement methods
    uint8 public constant REPLACE_BACKUP = 1;      // Use named backup
    uint8 public constant REPLACE_MUTUAL = 2;      // Parties must agree
    uint8 public constant REPLACE_COURT = 3;       // External appointment

    // States (bitmask)
    uint16 internal constant CONFIGURED = 1 << 1;      // 0x0002
    uint16 internal constant FILED = 1 << 4;           // 0x0010
    uint16 internal constant AWAITING_RULING = 1 << 5; // 0x0020
    uint16 internal constant RULED = 1 << 6;           // 0x0040
    uint16 internal constant EXECUTED = 1 << 2;        // 0x0004 (terminal)
    uint16 internal constant APPEALED = 1 << 7;        // 0x0080
    uint16 internal constant WITHDRAWN = 1 << 8;       // 0x0100 (terminal)

    // Rulings
    uint8 public constant RULING_NONE = 0;
    uint8 public constant RULING_CLAIMANT_WINS = 1;
    uint8 public constant RULING_RESPONDENT_WINS = 2;
    uint8 public constant RULING_SPLIT = 3;

    // ═══════════════════════════════════════════════════════════════
    //                        STRUCTS
    // ═══════════════════════════════════════════════════════════════

    /// @notice Arbitration configuration (from preset or custom)
    struct ArbitrationConfig {
        uint8 presetId;                   // Which preset (or CUSTOM)
        uint8 resolutionMethod;           // How arbitrators are selected
        uint64 evidenceWindowDays;        // Days for evidence submission
        uint64 arbitratorTimeoutDays;     // Days before arbitrator is unresponsive
        uint8 feePaymentMethod;           // Who pays arbitrator fees
        uint256 feeAmount;                // Fee amount (in payment token)
        bool appealsAllowed;              // Can parties appeal?
        uint8 maxAppeals;                 // Maximum appeal rounds
        uint8 appealArbitratorMethod;     // 1=same, 2=different, 3=panel
        uint64 appealWindowDays;          // Days to file appeal after ruling
        uint8 withdrawalPolicy;           // When can claimant withdraw?
        uint8 replacementTriggers;        // Bitmask of replacement conditions
        uint8 replacementMethod;          // How to replace arbitrator
        uint8 votingMethod;               // For multi-arbitrator
        uint8 deadlockResolution;         // How to handle ties
        address backupArbitrator;         // If replacement method is BACKUP
    }

    /// @notice Evidence item
    struct Evidence {
        address submitter;
        bytes32 evidenceHash;
        uint64 submittedAt;
    }

    /// @notice Arbitration instance data
    struct ArbitrationInstance {
        // Linked agreement
        address linkedAgreement;
        uint256 linkedInstanceId;

        // Parties (may swap if respondent files first)
        address claimant;
        address respondent;

        // Arbitrators (up to 3 for panel)
        address[MAX_ARBITRATORS] arbitrators;
        uint8 arbitratorCount;

        // Configuration
        ArbitrationConfig config;

        // State
        uint16 status;
        uint64 createdAt;
        uint64 filedAt;
        uint64 evidenceDeadline;

        // Claim
        bytes32 claimHash;
        address originalClaimant; // Who filed (for role swap tracking)

        // Evidence count (stored separately for gas)
        uint256 claimantEvidenceCount;
        uint256 respondentEvidenceCount;

        // Ruling
        uint8 ruling;
        uint256 splitBasisPoints;
        bytes32 justificationHash;
        uint64 ruledAt;
        uint8[MAX_ARBITRATORS] arbitratorVotes; // Each arbitrator's vote

        // Appeals
        uint8 appealCount;
        uint64 appealDeadline;

        // Consent tracking
        bool claimantConsentedToArbitrator;
        bool respondentConsentedToArbitrator;

        // Withdrawal tracking
        bool withdrawalRequested;
        address withdrawalRequestedBy;
    }

    /// @notice Storage for arbitration
    struct ArbitrationStorage {
        uint256 instanceCounter;
        mapping(uint256 => ArbitrationInstance) instances;
        mapping(uint256 => Evidence[]) evidence; // instanceId => evidence array
        mapping(uint256 => mapping(address => bool)) hasSubmittedEvidence;
        // User tracking
        mapping(address => uint256[]) userInstances;
    }

    // ═══════════════════════════════════════════════════════════════
    //                        STORAGE
    // ═══════════════════════════════════════════════════════════════

    // keccak256(abi.encode(uint256(keccak256("papre.agreement.arbitration.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT =
        0x8a2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b00;

    function _getStorage() internal pure returns (ArbitrationStorage storage $) {
        assembly {
            $.slot := STORAGE_SLOT
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //                        ERRORS
    // ═══════════════════════════════════════════════════════════════

    error InvalidPreset();
    error InvalidConfig();
    error InvalidLinkedAgreement();
    error CannotInitiateArbitration();
    error WrongState(uint16 expected, uint16 actual);
    error NotParty();
    error NotArbitrator();
    error InvalidRuling();
    error InvalidSplit();
    error EvidenceWindowOpen();
    error EvidenceWindowClosed();
    error AppealWindowOpen();
    error AppealWindowClosed();
    error AppealsNotAllowed();
    error MaxAppealsReached();
    error WithdrawalNotAllowed();
    error MutualConsentRequired();
    error ArbitratorNotConfirmed();
    error ZeroAddress();

    // ═══════════════════════════════════════════════════════════════
    //                        EVENTS
    // ═══════════════════════════════════════════════════════════════

    event ArbitrationCreated(
        uint256 indexed instanceId,
        address indexed linkedAgreement,
        uint256 linkedInstanceId,
        uint8 presetId
    );

    event ArbitratorSet(
        uint256 indexed instanceId,
        uint8 arbitratorIndex,
        address arbitrator
    );

    event ArbitratorConfirmed(
        uint256 indexed instanceId,
        address indexed confirmedBy,
        bool isClaimant
    );

    event ClaimFiled(
        uint256 indexed instanceId,
        address indexed claimant,
        bytes32 claimHash,
        uint64 evidenceDeadline
    );

    event EvidenceSubmitted(
        uint256 indexed instanceId,
        address indexed submitter,
        bytes32 evidenceHash,
        uint256 evidenceIndex
    );

    event EvidenceClosed(
        uint256 indexed instanceId,
        uint256 claimantEvidenceCount,
        uint256 respondentEvidenceCount
    );

    event ArbitratorVoted(
        uint256 indexed instanceId,
        address indexed arbitrator,
        uint8 vote
    );

    event RulingIssued(
        uint256 indexed instanceId,
        uint8 ruling,
        uint256 splitBasisPoints,
        bytes32 justificationHash
    );

    event AppealFiled(
        uint256 indexed instanceId,
        address indexed appellant,
        uint8 appealNumber
    );

    event RulingExecuted(
        uint256 indexed instanceId,
        uint8 ruling
    );

    event DisputeWithdrawn(
        uint256 indexed instanceId,
        address indexed withdrawnBy
    );

    // ═══════════════════════════════════════════════════════════════
    //                    CREATE INSTANCE
    // ═══════════════════════════════════════════════════════════════

    /// @notice Create a new arbitration instance with a preset
    /// @param linkedAgreement The IDisputable agreement to arbitrate
    /// @param linkedInstanceId The instance ID in that agreement
    /// @param presetId The preset to use (SIMPLE, BALANCED, PANEL, CUSTOM)
    /// @param arbitrator Primary arbitrator address (for SIMPLE/BALANCED)
    /// @return instanceId The created arbitration instance ID
    function createInstance(
        address linkedAgreement,
        uint256 linkedInstanceId,
        uint8 presetId,
        address arbitrator
    ) external returns (uint256 instanceId) {
        if (linkedAgreement == address(0)) revert ZeroAddress();
        if (presetId == 0 || presetId > PRESET_CUSTOM) revert InvalidPreset();

        // Verify the linked agreement supports arbitration
        if (!IDisputable(linkedAgreement).canInitiateArbitration(linkedInstanceId)) {
            revert CannotInitiateArbitration();
        }

        ArbitrationStorage storage $ = _getStorage();
        $.instanceCounter++;
        instanceId = $.instanceCounter;

        ArbitrationInstance storage inst = $.instances[instanceId];
        inst.linkedAgreement = linkedAgreement;
        inst.linkedInstanceId = linkedInstanceId;
        inst.createdAt = uint64(block.timestamp);

        // Get parties from linked agreement
        (address claimant, address respondent) = IDisputable(linkedAgreement).getArbitrationParties(linkedInstanceId);
        inst.claimant = claimant;
        inst.respondent = respondent;

        // Apply preset configuration
        _applyPreset(inst, presetId);

        // Set arbitrator(s) based on preset
        if (presetId == PRESET_SIMPLE || presetId == PRESET_BALANCED) {
            if (arbitrator == address(0)) revert ZeroAddress();
            inst.arbitrators[0] = arbitrator;
            inst.arbitratorCount = 1;
        }
        // PANEL preset: arbitrators are set later via setArbitrator()

        inst.status = CONFIGURED;

        // Track for users
        $.userInstances[claimant].push(instanceId);
        if (respondent != claimant) {
            $.userInstances[respondent].push(instanceId);
        }

        // Link this arbitration to the source agreement
        IDisputable(linkedAgreement).linkArbitration(linkedInstanceId, address(this), instanceId);

        emit ArbitrationCreated(instanceId, linkedAgreement, linkedInstanceId, presetId);
        if (arbitrator != address(0)) {
            emit ArbitratorSet(instanceId, 0, arbitrator);
        }

        return instanceId;
    }

    /// @notice Create instance with custom configuration
    /// @param linkedAgreement The IDisputable agreement to arbitrate
    /// @param linkedInstanceId The instance ID in that agreement
    /// @param config Custom arbitration configuration
    /// @param arbitrators Array of arbitrator addresses
    /// @return instanceId The created arbitration instance ID
    function createInstanceCustom(
        address linkedAgreement,
        uint256 linkedInstanceId,
        ArbitrationConfig calldata config,
        address[] calldata arbitrators
    ) external returns (uint256 instanceId) {
        if (linkedAgreement == address(0)) revert ZeroAddress();
        if (config.evidenceWindowDays == 0) revert InvalidConfig();
        if (arbitrators.length == 0 || arbitrators.length > MAX_ARBITRATORS) revert InvalidConfig();

        // Verify the linked agreement supports arbitration
        if (!IDisputable(linkedAgreement).canInitiateArbitration(linkedInstanceId)) {
            revert CannotInitiateArbitration();
        }

        ArbitrationStorage storage $ = _getStorage();
        $.instanceCounter++;
        instanceId = $.instanceCounter;

        ArbitrationInstance storage inst = $.instances[instanceId];
        inst.linkedAgreement = linkedAgreement;
        inst.linkedInstanceId = linkedInstanceId;
        inst.createdAt = uint64(block.timestamp);

        // Get parties from linked agreement
        (address claimant, address respondent) = IDisputable(linkedAgreement).getArbitrationParties(linkedInstanceId);
        inst.claimant = claimant;
        inst.respondent = respondent;

        // Apply custom config
        inst.config = config;
        inst.config.presetId = PRESET_CUSTOM;

        // Set arbitrators
        for (uint8 i = 0; i < arbitrators.length; i++) {
            if (arbitrators[i] == address(0)) revert ZeroAddress();
            inst.arbitrators[i] = arbitrators[i];
            emit ArbitratorSet(instanceId, i, arbitrators[i]);
        }
        inst.arbitratorCount = uint8(arbitrators.length);

        inst.status = CONFIGURED;

        // Track for users
        $.userInstances[claimant].push(instanceId);
        if (respondent != claimant) {
            $.userInstances[respondent].push(instanceId);
        }

        // Link this arbitration to the source agreement
        IDisputable(linkedAgreement).linkArbitration(linkedInstanceId, address(this), instanceId);

        emit ArbitrationCreated(instanceId, linkedAgreement, linkedInstanceId, PRESET_CUSTOM);

        return instanceId;
    }

    // ═══════════════════════════════════════════════════════════════
    //                    DISPUTE ACTIONS
    // ═══════════════════════════════════════════════════════════════

    /// @notice File a dispute claim
    /// @param instanceId The arbitration instance
    /// @param claimHash Hash of the claim content (stored off-chain)
    function fileClaim(uint256 instanceId, bytes32 claimHash) external {
        ArbitrationStorage storage $ = _getStorage();
        ArbitrationInstance storage inst = $.instances[instanceId];

        if (inst.status != CONFIGURED) revert WrongState(CONFIGURED, inst.status);

        // Either party can file
        if (msg.sender != inst.claimant && msg.sender != inst.respondent) {
            revert NotParty();
        }

        // If respondent files first, swap roles
        if (msg.sender != inst.claimant) {
            address originalClaimant = inst.claimant;
            inst.claimant = msg.sender;
            inst.respondent = originalClaimant;
        }

        inst.originalClaimant = msg.sender;
        inst.claimHash = claimHash;
        inst.filedAt = uint64(block.timestamp);
        inst.evidenceDeadline = uint64(block.timestamp) + (inst.config.evidenceWindowDays * 1 days);
        inst.status = FILED;

        emit ClaimFiled(instanceId, msg.sender, claimHash, inst.evidenceDeadline);
    }

    /// @notice Submit evidence for the dispute
    /// @param instanceId The arbitration instance
    /// @param evidenceHash Hash of evidence content (stored off-chain)
    function submitEvidence(uint256 instanceId, bytes32 evidenceHash) external {
        ArbitrationStorage storage $ = _getStorage();
        ArbitrationInstance storage inst = $.instances[instanceId];

        // Can submit during FILED or APPEALED (new evidence round)
        if (inst.status != FILED && inst.status != APPEALED) {
            revert WrongState(FILED, inst.status);
        }

        if (msg.sender != inst.claimant && msg.sender != inst.respondent) {
            revert NotParty();
        }

        if (block.timestamp > inst.evidenceDeadline) {
            revert EvidenceWindowClosed();
        }

        uint256 evidenceIndex = $.evidence[instanceId].length;
        $.evidence[instanceId].push(Evidence({
            submitter: msg.sender,
            evidenceHash: evidenceHash,
            submittedAt: uint64(block.timestamp)
        }));
        $.hasSubmittedEvidence[instanceId][msg.sender] = true;

        // Track counts
        if (msg.sender == inst.claimant) {
            inst.claimantEvidenceCount++;
        } else {
            inst.respondentEvidenceCount++;
        }

        emit EvidenceSubmitted(instanceId, msg.sender, evidenceHash, evidenceIndex);
    }

    /// @notice Close the evidence window (arbitrator can close early, anyone after deadline)
    /// @param instanceId The arbitration instance
    function closeEvidence(uint256 instanceId) external {
        ArbitrationStorage storage $ = _getStorage();
        ArbitrationInstance storage inst = $.instances[instanceId];

        if (inst.status != FILED && inst.status != APPEALED) {
            revert WrongState(FILED, inst.status);
        }

        bool deadlinePassed = block.timestamp > inst.evidenceDeadline;

        if (!deadlinePassed) {
            // Only arbitrator can close early
            bool isArbitrator = false;
            for (uint8 i = 0; i < inst.arbitratorCount; i++) {
                if (msg.sender == inst.arbitrators[i]) {
                    isArbitrator = true;
                    break;
                }
            }
            if (!isArbitrator) revert EvidenceWindowOpen();
        }

        inst.status = AWAITING_RULING;

        emit EvidenceClosed(instanceId, inst.claimantEvidenceCount, inst.respondentEvidenceCount);
    }

    /// @notice Submit ruling (for single arbitrator) or vote (for panel)
    /// @param instanceId The arbitration instance
    /// @param ruling The ruling: 1=CLAIMANT_WINS, 2=RESPONDENT_WINS, 3=SPLIT
    /// @param splitBasisPoints If SPLIT, claimant's share (0-10000)
    /// @param justificationHash Hash of ruling justification (off-chain)
    function rule(
        uint256 instanceId,
        uint8 ruling,
        uint256 splitBasisPoints,
        bytes32 justificationHash
    ) external {
        ArbitrationStorage storage $ = _getStorage();
        ArbitrationInstance storage inst = $.instances[instanceId];

        // Can rule from AWAITING_RULING, or FILED if deadline passed
        if (inst.status != AWAITING_RULING) {
            if (inst.status == FILED && block.timestamp > inst.evidenceDeadline) {
                inst.status = AWAITING_RULING;
            } else {
                revert WrongState(AWAITING_RULING, inst.status);
            }
        }

        // Validate ruling
        if (ruling == RULING_NONE || ruling > RULING_SPLIT) revert InvalidRuling();
        if (ruling == RULING_SPLIT && splitBasisPoints > MAX_SPLIT) revert InvalidSplit();

        // Find which arbitrator is voting
        int8 arbitratorIndex = -1;
        for (uint8 i = 0; i < inst.arbitratorCount; i++) {
            if (msg.sender == inst.arbitrators[i]) {
                arbitratorIndex = int8(i);
                break;
            }
        }
        if (arbitratorIndex < 0) revert NotArbitrator();

        // Record vote
        inst.arbitratorVotes[uint8(arbitratorIndex)] = ruling;
        emit ArbitratorVoted(instanceId, msg.sender, ruling);

        // For single arbitrator, ruling is immediate
        if (inst.arbitratorCount == 1) {
            _finalizeRuling(inst, ruling, splitBasisPoints, justificationHash);
        } else {
            // For panel, check if we have enough votes
            _checkPanelVotes(inst, splitBasisPoints, justificationHash);
        }
    }

    /// @notice File an appeal against the ruling
    /// @param instanceId The arbitration instance
    function appeal(uint256 instanceId) external {
        ArbitrationStorage storage $ = _getStorage();
        ArbitrationInstance storage inst = $.instances[instanceId];

        if (inst.status != RULED) revert WrongState(RULED, inst.status);
        if (!inst.config.appealsAllowed) revert AppealsNotAllowed();
        if (inst.appealCount >= inst.config.maxAppeals) revert MaxAppealsReached();

        if (msg.sender != inst.claimant && msg.sender != inst.respondent) {
            revert NotParty();
        }

        // Check appeal window
        uint64 appealDeadline = inst.ruledAt + (inst.config.appealWindowDays * 1 days);
        if (block.timestamp > appealDeadline) revert AppealWindowClosed();

        inst.appealCount++;
        inst.status = APPEALED;

        // Reset for new evidence round
        inst.evidenceDeadline = uint64(block.timestamp) + (inst.config.evidenceWindowDays * 1 days);

        // Reset arbitrator votes
        for (uint8 i = 0; i < MAX_ARBITRATORS; i++) {
            inst.arbitratorVotes[i] = RULING_NONE;
        }

        emit AppealFiled(instanceId, msg.sender, inst.appealCount);
    }

    /// @notice Withdraw the dispute (based on withdrawal policy)
    /// @param instanceId The arbitration instance
    function withdraw(uint256 instanceId) external {
        ArbitrationStorage storage $ = _getStorage();
        ArbitrationInstance storage inst = $.instances[instanceId];

        if (inst.status == EXECUTED || inst.status == WITHDRAWN) {
            revert WrongState(FILED, inst.status);
        }

        if (msg.sender != inst.claimant && msg.sender != inst.respondent) {
            revert NotParty();
        }

        uint8 policy = inst.config.withdrawalPolicy;

        if (policy == WITHDRAW_NOT_ALLOWED) {
            revert WithdrawalNotAllowed();
        }

        if (policy == WITHDRAW_ANYTIME) {
            // Must be before ruling
            if (inst.status == RULED) revert WithdrawalNotAllowed();
            inst.status = WITHDRAWN;
            emit DisputeWithdrawn(instanceId, msg.sender);
        } else if (policy == WITHDRAW_MUTUAL) {
            if (!inst.withdrawalRequested) {
                // First party requests
                inst.withdrawalRequested = true;
                inst.withdrawalRequestedBy = msg.sender;
            } else {
                // Second party confirms
                if (msg.sender == inst.withdrawalRequestedBy) {
                    revert MutualConsentRequired();
                }
                inst.status = WITHDRAWN;
                emit DisputeWithdrawn(instanceId, msg.sender);
            }
        }
    }

    /// @notice Execute the ruling on the linked agreement (called after appeal window or when final)
    /// @param instanceId The arbitration instance
    function executeRuling(uint256 instanceId) external {
        ArbitrationStorage storage $ = _getStorage();
        ArbitrationInstance storage inst = $.instances[instanceId];

        if (inst.status != RULED) revert WrongState(RULED, inst.status);

        // Check appeal window has passed (if appeals allowed)
        if (inst.config.appealsAllowed && inst.appealCount < inst.config.maxAppeals) {
            uint64 appealDeadline = inst.ruledAt + (inst.config.appealWindowDays * 1 days);
            if (block.timestamp <= appealDeadline) revert AppealWindowOpen();
        }

        inst.status = EXECUTED;

        // Execute ruling on linked agreement
        IDisputable(inst.linkedAgreement).executeArbitrationRuling(
            inst.linkedInstanceId,
            inst.ruling,
            inst.splitBasisPoints
        );

        emit RulingExecuted(instanceId, inst.ruling);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    ARBITRATOR MANAGEMENT
    // ═══════════════════════════════════════════════════════════════

    /// @notice Set an arbitrator (for PANEL preset or late selection)
    /// @param instanceId The arbitration instance
    /// @param arbitratorIndex Which arbitrator slot (0, 1, or 2)
    /// @param arbitrator The arbitrator address
    function setArbitrator(uint256 instanceId, uint8 arbitratorIndex, address arbitrator) external {
        ArbitrationStorage storage $ = _getStorage();
        ArbitrationInstance storage inst = $.instances[instanceId];

        if (inst.status != CONFIGURED) revert WrongState(CONFIGURED, inst.status);
        if (arbitrator == address(0)) revert ZeroAddress();
        if (arbitratorIndex >= MAX_ARBITRATORS) revert InvalidConfig();

        // Only parties can set arbitrators (based on resolution method)
        if (msg.sender != inst.claimant && msg.sender != inst.respondent) {
            revert NotParty();
        }

        inst.arbitrators[arbitratorIndex] = arbitrator;
        if (arbitratorIndex >= inst.arbitratorCount) {
            inst.arbitratorCount = arbitratorIndex + 1;
        }

        emit ArbitratorSet(instanceId, arbitratorIndex, arbitrator);
    }

    /// @notice Confirm arbitrator selection (for BALANCED preset requiring mutual consent)
    /// @param instanceId The arbitration instance
    function confirmArbitrator(uint256 instanceId) external {
        ArbitrationStorage storage $ = _getStorage();
        ArbitrationInstance storage inst = $.instances[instanceId];

        if (inst.status != CONFIGURED) revert WrongState(CONFIGURED, inst.status);

        if (msg.sender == inst.claimant) {
            inst.claimantConsentedToArbitrator = true;
            emit ArbitratorConfirmed(instanceId, msg.sender, true);
        } else if (msg.sender == inst.respondent) {
            inst.respondentConsentedToArbitrator = true;
            emit ArbitratorConfirmed(instanceId, msg.sender, false);
        } else {
            revert NotParty();
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //                    VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    /// @notice Get instance count
    function getInstanceCount() external view returns (uint256) {
        return _getStorage().instanceCounter;
    }

    /// @notice Get instances for a user
    function getUserInstances(address user) external view returns (uint256[] memory) {
        return _getStorage().userInstances[user];
    }

    /// @notice Get instance basic info
    function getInstance(uint256 instanceId) external view returns (
        address linkedAgreement,
        uint256 linkedInstanceId,
        address claimant,
        address respondent,
        uint16 status,
        uint8 presetId
    ) {
        ArbitrationInstance storage inst = _getStorage().instances[instanceId];
        return (
            inst.linkedAgreement,
            inst.linkedInstanceId,
            inst.claimant,
            inst.respondent,
            inst.status,
            inst.config.presetId
        );
    }

    /// @notice Get instance state
    function getInstanceState(uint256 instanceId) external view returns (
        uint64 filedAt,
        uint64 evidenceDeadline,
        uint8 ruling,
        uint256 splitBasisPoints,
        uint64 ruledAt,
        uint8 appealCount
    ) {
        ArbitrationInstance storage inst = _getStorage().instances[instanceId];
        return (
            inst.filedAt,
            inst.evidenceDeadline,
            inst.ruling,
            inst.splitBasisPoints,
            inst.ruledAt,
            inst.appealCount
        );
    }

    /// @notice Get arbitrators for an instance
    function getArbitrators(uint256 instanceId) external view returns (
        address[MAX_ARBITRATORS] memory arbitrators,
        uint8 arbitratorCount
    ) {
        ArbitrationInstance storage inst = _getStorage().instances[instanceId];
        return (inst.arbitrators, inst.arbitratorCount);
    }

    /// @notice Get arbitrator votes
    function getArbitratorVotes(uint256 instanceId) external view returns (uint8[MAX_ARBITRATORS] memory) {
        return _getStorage().instances[instanceId].arbitratorVotes;
    }

    /// @notice Get evidence count
    function getEvidenceCount(uint256 instanceId) external view returns (uint256) {
        return _getStorage().evidence[instanceId].length;
    }

    /// @notice Get evidence by index
    function getEvidence(uint256 instanceId, uint256 index) external view returns (
        address submitter,
        bytes32 evidenceHash,
        uint64 submittedAt
    ) {
        Evidence storage e = _getStorage().evidence[instanceId][index];
        return (e.submitter, e.evidenceHash, e.submittedAt);
    }

    /// @notice Get configuration for an instance
    function getConfig(uint256 instanceId) external view returns (ArbitrationConfig memory) {
        return _getStorage().instances[instanceId].config;
    }

    /// @notice Debug function to check what rule() would see
    function debugRuleView(uint256 instanceId, address caller) external view returns (
        uint16 status,
        uint64 evidenceDeadline,
        uint8 arbitratorCount,
        address arb0,
        address arb1,
        address arb2,
        bool callerIsArb
    ) {
        ArbitrationInstance storage inst = _getStorage().instances[instanceId];
        status = inst.status;
        evidenceDeadline = inst.evidenceDeadline;
        arbitratorCount = inst.arbitratorCount;
        arb0 = inst.arbitrators[0];
        arb1 = inst.arbitrators[1];
        arb2 = inst.arbitrators[2];
        callerIsArb = false;
        for (uint8 i = 0; i < arbitratorCount; i++) {
            if (caller == inst.arbitrators[i]) {
                callerIsArb = true;
                break;
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //                    INTERNAL FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    /// @notice Apply preset configuration
    function _applyPreset(ArbitrationInstance storage inst, uint8 presetId) internal {
        if (presetId == PRESET_SIMPLE) {
            inst.config = ArbitrationConfig({
                presetId: PRESET_SIMPLE,
                resolutionMethod: RESOLUTION_SINGLE_CREATOR,
                evidenceWindowDays: 7,
                arbitratorTimeoutDays: 14,
                feePaymentMethod: FEE_SPLIT,
                feeAmount: 0,
                appealsAllowed: false,
                maxAppeals: 0,
                appealArbitratorMethod: 0,
                appealWindowDays: 0,
                withdrawalPolicy: WITHDRAW_ANYTIME,
                replacementTriggers: REPLACE_DEATH | REPLACE_INCAPACITY | REPLACE_TIMEOUT,
                replacementMethod: REPLACE_MUTUAL,
                votingMethod: 0,
                deadlockResolution: 0,
                backupArbitrator: address(0)
            });
        } else if (presetId == PRESET_BALANCED) {
            inst.config = ArbitrationConfig({
                presetId: PRESET_BALANCED,
                resolutionMethod: RESOLUTION_SINGLE_MUTUAL,
                evidenceWindowDays: 14,
                arbitratorTimeoutDays: 14,
                feePaymentMethod: FEE_LOSER_PAYS,
                feeAmount: 0,
                appealsAllowed: true,
                maxAppeals: 1,
                appealArbitratorMethod: 2, // Different arbitrator
                appealWindowDays: 7,
                withdrawalPolicy: WITHDRAW_MUTUAL,
                replacementTriggers: REPLACE_DEATH | REPLACE_INCAPACITY | REPLACE_CONFLICT | REPLACE_TIMEOUT,
                replacementMethod: REPLACE_MUTUAL,
                votingMethod: 0,
                deadlockResolution: 0,
                backupArbitrator: address(0)
            });
        } else if (presetId == PRESET_PANEL) {
            inst.config = ArbitrationConfig({
                presetId: PRESET_PANEL,
                resolutionMethod: RESOLUTION_PANEL,
                evidenceWindowDays: 21,
                arbitratorTimeoutDays: 21,
                feePaymentMethod: FEE_SPLIT,
                feeAmount: 0,
                appealsAllowed: false,
                maxAppeals: 0,
                appealArbitratorMethod: 0,
                appealWindowDays: 0,
                withdrawalPolicy: WITHDRAW_MUTUAL,
                replacementTriggers: REPLACE_DEATH | REPLACE_INCAPACITY | REPLACE_CONFLICT | REPLACE_TIMEOUT,
                replacementMethod: REPLACE_MUTUAL,
                votingMethod: VOTE_MAJORITY,
                deadlockResolution: DEADLOCK_TIEBREAKER,
                backupArbitrator: address(0)
            });
        }
    }

    /// @notice Finalize a ruling
    function _finalizeRuling(
        ArbitrationInstance storage inst,
        uint8 ruling,
        uint256 splitBasisPoints,
        bytes32 justificationHash
    ) internal {
        inst.ruling = ruling;
        inst.splitBasisPoints = splitBasisPoints;
        inst.justificationHash = justificationHash;
        inst.ruledAt = uint64(block.timestamp);
        inst.status = RULED;

        emit RulingIssued(inst.linkedInstanceId, ruling, splitBasisPoints, justificationHash);
    }

    /// @notice Check panel votes and finalize if consensus reached
    function _checkPanelVotes(
        ArbitrationInstance storage inst,
        uint256 splitBasisPoints,
        bytes32 justificationHash
    ) internal {
        uint8 votingMethod = inst.config.votingMethod;

        if (votingMethod == VOTE_UNANIMOUS) {
            // All must vote the same
            uint8 firstVote = inst.arbitratorVotes[0];
            if (firstVote == RULING_NONE) return; // Not all have voted

            for (uint8 i = 1; i < inst.arbitratorCount; i++) {
                if (inst.arbitratorVotes[i] != firstVote) {
                    // Not unanimous - handle deadlock
                    return;
                }
                if (inst.arbitratorVotes[i] == RULING_NONE) return;
            }

            // Unanimous!
            _finalizeRuling(inst, firstVote, splitBasisPoints, justificationHash);

        } else if (votingMethod == VOTE_MAJORITY) {
            // Count votes
            uint8 claimantVotes = 0;
            uint8 respondentVotes = 0;
            uint8 splitVotes = 0;
            uint8 totalVotes = 0;

            for (uint8 i = 0; i < inst.arbitratorCount; i++) {
                uint8 vote = inst.arbitratorVotes[i];
                if (vote == RULING_NONE) continue;
                totalVotes++;
                if (vote == RULING_CLAIMANT_WINS) claimantVotes++;
                else if (vote == RULING_RESPONDENT_WINS) respondentVotes++;
                else if (vote == RULING_SPLIT) splitVotes++;
            }

            // Need majority
            uint8 majority = (inst.arbitratorCount / 2) + 1;

            if (claimantVotes >= majority) {
                _finalizeRuling(inst, RULING_CLAIMANT_WINS, 0, justificationHash);
            } else if (respondentVotes >= majority) {
                _finalizeRuling(inst, RULING_RESPONDENT_WINS, 0, justificationHash);
            } else if (splitVotes >= majority) {
                _finalizeRuling(inst, RULING_SPLIT, splitBasisPoints, justificationHash);
            }
            // Else not enough votes yet
        }
    }
}
