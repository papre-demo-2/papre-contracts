// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ClauseBase} from "../../base/ClauseBase.sol";

/// @title ArbitrationClauseLogicV3
/// @notice Self-describing arbitration clause following v3 specification
/// @dev Logic contract executed via delegatecall from Agreement proxies.
///      Uses ERC-7201 namespaced storage to prevent collisions with other clauses.
///      All functions take instanceId as first parameter for multi-instance support.
///
///      Provides dispute resolution for freelance agreements:
///      - Single arbitrator model (pre-selected)
///      - Evidence submission by both parties
///      - Binding rulings that authorize escrow release/refund
///
///      State Machine:
///      ┌────────────────┐
///      │  Uninitialized │
///      │    (status=0)  │
///      └───────┬────────┘
///              │ intakeArbitrator(), intakeParties(), intakeReady()
///              ▼
///      ┌────────────────┐
///      │    STANDBY     │ ← Ready for disputes
///      │   (0x0002)     │
///      └───────┬────────┘
///              │ actionFileClaim()
///              ▼
///      ┌────────────────┐
///      │     FILED      │ ← Claim submitted, evidence period
///      │   (0x0010)     │
///      └───────┬────────┘
///              │ actionCloseEvidence() or deadline
///              ▼
///      ┌────────────────┐
///      │AWAITING_RULING │ ← Evidence closed, awaiting decision
///      │   (0x0020)     │
///      └───────┬────────┘
///              │ actionRule() [arbitrator only]
///              ▼
///      ┌────────────────┐
///      │     RULED      │ ← Decision issued
///      │   (0x0040)     │
///      └───────┬────────┘
///              │ actionMarkExecuted() [agreement calls after escrow action]
///              ▼
///      ┌────────────────┐
///      │   EXECUTED     │ ← Ruling enforced (terminal)
///      │   (0x0004)     │
///      └────────────────┘
contract ArbitrationClauseLogicV3 is ClauseBase {
    // =============================================================
    // CONSTANTS
    // =============================================================

    /// @notice Default evidence window duration
    uint64 public constant DEFAULT_EVIDENCE_WINDOW = 7 days;

    /// @notice Maximum split percentage (100% = 10000 basis points)
    uint16 public constant MAX_SPLIT = 10000;

    // =============================================================
    // EXTENDED STATES (bitmask)
    // =============================================================

    uint16 internal constant STANDBY = 1 << 1;         // 0x0002
    uint16 internal constant FILED = 1 << 4;           // 0x0010
    uint16 internal constant AWAITING_RULING = 1 << 5; // 0x0020
    uint16 internal constant RULED = 1 << 6;           // 0x0040
    uint16 internal constant EXECUTED = 1 << 2;        // 0x0004 (same as COMPLETE)

    // =============================================================
    // RULING OUTCOMES
    // =============================================================

    /// @notice Possible ruling outcomes
    enum Ruling {
        NONE,            // No ruling yet
        CLAIMANT_WINS,   // Release to claimant (beneficiary)
        RESPONDENT_WINS, // Refund to respondent (client)
        SPLIT            // Split between parties (uses splitBasisPoints)
    }

    // =============================================================
    // ERRORS
    // =============================================================

    error ZeroAddress();
    error WrongState(uint16 expected, uint16 actual);
    error NotArbitrator(address caller, address arbitrator);
    error NotParty(address caller);
    error EvidenceWindowStillOpen(uint64 deadline, uint64 current);
    error EvidenceWindowExpired(uint64 deadline, uint64 current);
    error InvalidSplit(uint16 splitBasisPoints);
    error AlreadySubmittedEvidence(address party);
    error InvalidRuling();

    // =============================================================
    // EVENTS
    // =============================================================

    event ArbitrationConfigured(
        bytes32 indexed instanceId,
        address indexed arbitrator,
        address claimant,
        address respondent,
        uint64 evidenceWindow
    );

    event ClaimFiled(
        bytes32 indexed instanceId,
        address indexed claimant,
        bytes32 claimHash,
        uint64 evidenceDeadline
    );

    event EvidenceSubmitted(
        bytes32 indexed instanceId,
        address indexed party,
        bytes32 evidenceHash,
        uint256 evidenceIndex
    );

    event EvidenceWindowClosed(
        bytes32 indexed instanceId,
        uint256 claimantEvidenceCount,
        uint256 respondentEvidenceCount
    );

    event RulingIssued(
        bytes32 indexed instanceId,
        address indexed arbitrator,
        Ruling ruling,
        bytes32 rulingHash,
        uint16 splitBasisPoints
    );

    event RulingExecuted(
        bytes32 indexed instanceId,
        Ruling ruling
    );

    // =============================================================
    // STRUCTS
    // =============================================================

    /// @notice Evidence item
    struct Evidence {
        address submitter;
        bytes32 evidenceHash;
        uint64 submittedAt;
    }

    // =============================================================
    // ERC-7201 NAMESPACED STORAGE
    // =============================================================

    /// @custom:storage-location erc7201:papre.clause.arbitration.storage
    struct ArbitrationStorage {
        /// @notice instanceId => clause state
        mapping(bytes32 => uint16) status;
        /// @notice instanceId => arbitrator address
        mapping(bytes32 => address) arbitrator;
        /// @notice instanceId => claimant address (who files dispute)
        mapping(bytes32 => address) claimant;
        /// @notice instanceId => respondent address (other party)
        mapping(bytes32 => address) respondent;
        /// @notice instanceId => evidence window duration
        mapping(bytes32 => uint64) evidenceWindow;
        /// @notice instanceId => claim content hash
        mapping(bytes32 => bytes32) claimHash;
        /// @notice instanceId => evidence deadline timestamp
        mapping(bytes32 => uint64) evidenceDeadline;
        /// @notice instanceId => filed timestamp
        mapping(bytes32 => uint64) filedAt;
        /// @notice instanceId => evidence items
        mapping(bytes32 => Evidence[]) evidence;
        /// @notice instanceId => party => has submitted initial evidence
        mapping(bytes32 => mapping(address => bool)) hasSubmittedEvidence;
        /// @notice instanceId => ruling outcome
        mapping(bytes32 => Ruling) ruling;
        /// @notice instanceId => ruling justification hash
        mapping(bytes32 => bytes32) rulingHash;
        /// @notice instanceId => split percentage for SPLIT ruling (basis points)
        mapping(bytes32 => uint16) splitBasisPoints;
        /// @notice instanceId => ruled timestamp
        mapping(bytes32 => uint64) ruledAt;
    }

    // keccak256(abi.encode(uint256(keccak256("papre.clause.arbitration.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT =
        0x674709657d7ade951545e2c3bfcf0e54c24915e3d073a53388af441ccee72a00;

    function _getStorage() internal pure returns (ArbitrationStorage storage $) {
        assembly {
            $.slot := STORAGE_SLOT
        }
    }

    // =============================================================
    // INTAKE (from previous clause or setup)
    // =============================================================

    /// @notice Set the arbitrator for this instance
    /// @param instanceId Unique identifier for this arbitration instance
    /// @param _arbitrator Address of the arbitrator
    function intakeArbitrator(bytes32 instanceId, address _arbitrator) external {
        if (_arbitrator == address(0)) revert ZeroAddress();
        ArbitrationStorage storage $ = _getStorage();
        require($.status[instanceId] == 0, "Wrong state");
        $.arbitrator[instanceId] = _arbitrator;
    }

    /// @notice Set the claimant (typically the beneficiary/freelancer)
    /// @param instanceId Unique identifier for this arbitration instance
    /// @param _claimant Address of the claimant
    function intakeClaimant(bytes32 instanceId, address _claimant) external {
        if (_claimant == address(0)) revert ZeroAddress();
        ArbitrationStorage storage $ = _getStorage();
        require($.status[instanceId] == 0, "Wrong state");
        $.claimant[instanceId] = _claimant;
    }

    /// @notice Set the respondent (typically the client)
    /// @param instanceId Unique identifier for this arbitration instance
    /// @param _respondent Address of the respondent
    function intakeRespondent(bytes32 instanceId, address _respondent) external {
        if (_respondent == address(0)) revert ZeroAddress();
        ArbitrationStorage storage $ = _getStorage();
        require($.status[instanceId] == 0, "Wrong state");
        $.respondent[instanceId] = _respondent;
    }

    /// @notice Set the evidence window duration
    /// @param instanceId Unique identifier for this arbitration instance
    /// @param _evidenceWindow Duration in seconds for evidence submission
    function intakeEvidenceWindow(bytes32 instanceId, uint64 _evidenceWindow) external {
        ArbitrationStorage storage $ = _getStorage();
        require($.status[instanceId] == 0, "Wrong state");
        $.evidenceWindow[instanceId] = _evidenceWindow;
    }

    /// @notice Finalize configuration and transition to STANDBY
    /// @param instanceId Unique identifier for this arbitration instance
    function intakeReady(bytes32 instanceId) external {
        ArbitrationStorage storage $ = _getStorage();
        require($.status[instanceId] == 0, "Wrong state");
        require($.arbitrator[instanceId] != address(0), "No arbitrator");
        require($.claimant[instanceId] != address(0), "No claimant");
        require($.respondent[instanceId] != address(0), "No respondent");

        // Set default evidence window if not specified
        if ($.evidenceWindow[instanceId] == 0) {
            $.evidenceWindow[instanceId] = DEFAULT_EVIDENCE_WINDOW;
        }

        $.status[instanceId] = STANDBY;

        emit ArbitrationConfigured(
            instanceId,
            $.arbitrator[instanceId],
            $.claimant[instanceId],
            $.respondent[instanceId],
            $.evidenceWindow[instanceId]
        );
    }

    // =============================================================
    // ACTIONS (state-changing)
    // =============================================================

    /// @notice File a dispute claim
    /// @param instanceId Unique identifier for this arbitration instance
    /// @param _claimHash Hash of the claim content (off-chain)
    /// @dev Can be called by either party once in STANDBY
    /// @custom:papre-style destructive
    function actionFileClaim(bytes32 instanceId, bytes32 _claimHash) external {
        ArbitrationStorage storage $ = _getStorage();
        require($.status[instanceId] == STANDBY, "Wrong state");

        // Either party can file
        address claimant = $.claimant[instanceId];
        address respondent = $.respondent[instanceId];
        require(msg.sender == claimant || msg.sender == respondent, "Not a party");

        // Update claimant/respondent based on who filed
        if (msg.sender != claimant) {
            // Swap roles if respondent files
            $.claimant[instanceId] = msg.sender;
            $.respondent[instanceId] = claimant;
        }

        $.claimHash[instanceId] = _claimHash;
        $.filedAt[instanceId] = uint64(block.timestamp);
        $.evidenceDeadline[instanceId] = uint64(block.timestamp) + $.evidenceWindow[instanceId];
        $.status[instanceId] = FILED;

        emit ClaimFiled(
            instanceId,
            msg.sender,
            _claimHash,
            $.evidenceDeadline[instanceId]
        );
    }

    /// @notice Submit evidence for the dispute
    /// @param instanceId Unique identifier for this arbitration instance
    /// @param evidenceHash Hash of the evidence content (off-chain)
    /// @custom:papre-style primary
    function actionSubmitEvidence(bytes32 instanceId, bytes32 evidenceHash) external {
        ArbitrationStorage storage $ = _getStorage();
        require($.status[instanceId] == FILED, "Wrong state");

        // Validate caller is a party
        address claimant = $.claimant[instanceId];
        address respondent = $.respondent[instanceId];
        if (msg.sender != claimant && msg.sender != respondent) {
            revert NotParty(msg.sender);
        }

        // Check evidence window
        if (block.timestamp > $.evidenceDeadline[instanceId]) {
            revert EvidenceWindowExpired($.evidenceDeadline[instanceId], uint64(block.timestamp));
        }

        // Store evidence
        uint256 evidenceIndex = $.evidence[instanceId].length;
        $.evidence[instanceId].push(Evidence({
            submitter: msg.sender,
            evidenceHash: evidenceHash,
            submittedAt: uint64(block.timestamp)
        }));
        $.hasSubmittedEvidence[instanceId][msg.sender] = true;

        emit EvidenceSubmitted(instanceId, msg.sender, evidenceHash, evidenceIndex);
    }

    /// @notice Close the evidence window and move to awaiting ruling
    /// @param instanceId Unique identifier for this arbitration instance
    /// @dev Can be called by arbitrator at any time, or by anyone after deadline
    function actionCloseEvidence(bytes32 instanceId) external {
        ArbitrationStorage storage $ = _getStorage();
        require($.status[instanceId] == FILED, "Wrong state");

        bool deadlinePassed = block.timestamp > $.evidenceDeadline[instanceId];

        if (!deadlinePassed) {
            // Only arbitrator can close early
            if (msg.sender != $.arbitrator[instanceId]) {
                revert EvidenceWindowStillOpen($.evidenceDeadline[instanceId], uint64(block.timestamp));
            }
        }

        $.status[instanceId] = AWAITING_RULING;

        // Count evidence per party
        uint256 claimantCount;
        uint256 respondentCount;
        Evidence[] storage evidenceList = $.evidence[instanceId];
        address claimant = $.claimant[instanceId];

        for (uint256 i = 0; i < evidenceList.length; i++) {
            if (evidenceList[i].submitter == claimant) {
                claimantCount++;
            } else {
                respondentCount++;
            }
        }

        emit EvidenceWindowClosed(instanceId, claimantCount, respondentCount);
    }

    /// @notice Issue the arbitration ruling
    /// @param instanceId Unique identifier for this arbitration instance
    /// @param _ruling The ruling outcome
    /// @param _rulingHash Hash of ruling justification (off-chain)
    /// @param _splitBasisPoints For SPLIT ruling, claimant's share in basis points (0-10000)
    /// @custom:papre-style primary
    function actionRule(
        bytes32 instanceId,
        Ruling _ruling,
        bytes32 _rulingHash,
        uint16 _splitBasisPoints
    ) external {
        ArbitrationStorage storage $ = _getStorage();

        uint16 status = $.status[instanceId];
        // Can rule from AWAITING_RULING, or FILED if evidence deadline passed
        if (status != AWAITING_RULING) {
            if (status == FILED && block.timestamp > $.evidenceDeadline[instanceId]) {
                // Auto-close evidence window
                $.status[instanceId] = AWAITING_RULING;
            } else {
                revert WrongState(AWAITING_RULING, status);
            }
        }

        // Only arbitrator can rule
        address arbitrator = $.arbitrator[instanceId];
        if (msg.sender != arbitrator) {
            revert NotArbitrator(msg.sender, arbitrator);
        }

        // Validate ruling
        if (_ruling == Ruling.NONE) revert InvalidRuling();
        if (_ruling == Ruling.SPLIT && _splitBasisPoints > MAX_SPLIT) {
            revert InvalidSplit(_splitBasisPoints);
        }

        // Store ruling
        $.ruling[instanceId] = _ruling;
        $.rulingHash[instanceId] = _rulingHash;
        $.splitBasisPoints[instanceId] = _splitBasisPoints;
        $.ruledAt[instanceId] = uint64(block.timestamp);
        $.status[instanceId] = RULED;

        emit RulingIssued(instanceId, msg.sender, _ruling, _rulingHash, _splitBasisPoints);
    }

    /// @notice Mark the ruling as executed (after agreement enforces it)
    /// @param instanceId Unique identifier for this arbitration instance
    /// @dev Called by Agreement after executing the ruling (release/refund)
    function actionMarkExecuted(bytes32 instanceId) external {
        ArbitrationStorage storage $ = _getStorage();
        require($.status[instanceId] == RULED, "Wrong state");

        $.status[instanceId] = EXECUTED;

        emit RulingExecuted(instanceId, $.ruling[instanceId]);
    }

    // =============================================================
    // HANDOFF (to next clause / agreement)
    // =============================================================

    /// @notice Get the ruling after it's been issued
    /// @param instanceId Unique identifier for this arbitration instance
    /// @return The ruling outcome
    function handoffRuling(bytes32 instanceId) external view returns (Ruling) {
        ArbitrationStorage storage $ = _getStorage();
        uint16 status = $.status[instanceId];
        require(status == RULED || status == EXECUTED, "Wrong state");
        return $.ruling[instanceId];
    }

    /// @notice Get the split basis points for SPLIT ruling
    /// @param instanceId Unique identifier for this arbitration instance
    /// @return Claimant's share in basis points (0-10000)
    function handoffSplitBasisPoints(bytes32 instanceId) external view returns (uint16) {
        ArbitrationStorage storage $ = _getStorage();
        uint16 status = $.status[instanceId];
        require(status == RULED || status == EXECUTED, "Wrong state");
        return $.splitBasisPoints[instanceId];
    }

    /// @notice Get the claimant (winner if CLAIMANT_WINS)
    /// @param instanceId Unique identifier for this arbitration instance
    /// @return The claimant address
    function handoffClaimant(bytes32 instanceId) external view returns (address) {
        ArbitrationStorage storage $ = _getStorage();
        uint16 status = $.status[instanceId];
        require(status == RULED || status == EXECUTED, "Wrong state");
        return $.claimant[instanceId];
    }

    /// @notice Get the respondent (winner if RESPONDENT_WINS)
    /// @param instanceId Unique identifier for this arbitration instance
    /// @return The respondent address
    function handoffRespondent(bytes32 instanceId) external view returns (address) {
        ArbitrationStorage storage $ = _getStorage();
        uint16 status = $.status[instanceId];
        require(status == RULED || status == EXECUTED, "Wrong state");
        return $.respondent[instanceId];
    }

    /// @notice Get the ruling hash (justification)
    /// @param instanceId Unique identifier for this arbitration instance
    /// @return The ruling justification hash
    function handoffRulingHash(bytes32 instanceId) external view returns (bytes32) {
        ArbitrationStorage storage $ = _getStorage();
        uint16 status = $.status[instanceId];
        require(status == RULED || status == EXECUTED, "Wrong state");
        return $.rulingHash[instanceId];
    }

    // =============================================================
    // QUERIES (always available)
    // =============================================================

    /// @notice Get the current state of an instance
    /// @param instanceId Unique identifier for this arbitration instance
    /// @return Current state bitmask
    function queryStatus(bytes32 instanceId) external view returns (uint16) {
        return _getStorage().status[instanceId];
    }

    /// @notice Get the arbitrator for an instance
    /// @param instanceId Unique identifier for this arbitration instance
    /// @return The arbitrator address
    function queryArbitrator(bytes32 instanceId) external view returns (address) {
        return _getStorage().arbitrator[instanceId];
    }

    /// @notice Get the claimant for an instance
    /// @param instanceId Unique identifier for this arbitration instance
    /// @return The claimant address
    function queryClaimant(bytes32 instanceId) external view returns (address) {
        return _getStorage().claimant[instanceId];
    }

    /// @notice Get the respondent for an instance
    /// @param instanceId Unique identifier for this arbitration instance
    /// @return The respondent address
    function queryRespondent(bytes32 instanceId) external view returns (address) {
        return _getStorage().respondent[instanceId];
    }

    /// @notice Get the claim hash
    /// @param instanceId Unique identifier for this arbitration instance
    /// @return The claim content hash
    function queryClaimHash(bytes32 instanceId) external view returns (bytes32) {
        return _getStorage().claimHash[instanceId];
    }

    /// @notice Get the evidence deadline
    /// @param instanceId Unique identifier for this arbitration instance
    /// @return The evidence deadline timestamp
    function queryEvidenceDeadline(bytes32 instanceId) external view returns (uint64) {
        return _getStorage().evidenceDeadline[instanceId];
    }

    /// @notice Get the number of evidence items
    /// @param instanceId Unique identifier for this arbitration instance
    /// @return Total evidence count
    function queryEvidenceCount(bytes32 instanceId) external view returns (uint256) {
        return _getStorage().evidence[instanceId].length;
    }

    /// @notice Get evidence by index
    /// @param instanceId Unique identifier for this arbitration instance
    /// @param index Evidence index
    /// @return submitter The address that submitted the evidence
    /// @return evidenceHash The evidence content hash
    /// @return submittedAt When the evidence was submitted
    function queryEvidence(
        bytes32 instanceId,
        uint256 index
    ) external view returns (address submitter, bytes32 evidenceHash, uint64 submittedAt) {
        Evidence storage e = _getStorage().evidence[instanceId][index];
        return (e.submitter, e.evidenceHash, e.submittedAt);
    }

    /// @notice Check if a party has submitted evidence
    /// @param instanceId Unique identifier for this arbitration instance
    /// @param party Address to check
    /// @return True if the party has submitted evidence
    function queryHasSubmittedEvidence(bytes32 instanceId, address party) external view returns (bool) {
        return _getStorage().hasSubmittedEvidence[instanceId][party];
    }

    /// @notice Get the ruling
    /// @param instanceId Unique identifier for this arbitration instance
    /// @return The ruling outcome
    function queryRuling(bytes32 instanceId) external view returns (Ruling) {
        return _getStorage().ruling[instanceId];
    }

    /// @notice Get the ruling hash
    /// @param instanceId Unique identifier for this arbitration instance
    /// @return The ruling justification hash
    function queryRulingHash(bytes32 instanceId) external view returns (bytes32) {
        return _getStorage().rulingHash[instanceId];
    }

    /// @notice Get the split basis points
    /// @param instanceId Unique identifier for this arbitration instance
    /// @return Claimant's share in basis points (0-10000)
    function querySplitBasisPoints(bytes32 instanceId) external view returns (uint16) {
        return _getStorage().splitBasisPoints[instanceId];
    }

    /// @notice Get the ruling timestamp
    /// @param instanceId Unique identifier for this arbitration instance
    /// @return When the ruling was issued
    function queryRuledAt(bytes32 instanceId) external view returns (uint64) {
        return _getStorage().ruledAt[instanceId];
    }

    /// @notice Check if arbitration is in STANDBY (ready for disputes)
    /// @param instanceId Unique identifier for this arbitration instance
    /// @return True if in STANDBY state
    function queryIsStandby(bytes32 instanceId) external view returns (bool) {
        return _getStorage().status[instanceId] == STANDBY;
    }

    /// @notice Check if a dispute has been filed
    /// @param instanceId Unique identifier for this arbitration instance
    /// @return True if dispute is filed (FILED, AWAITING_RULING, RULED, or EXECUTED)
    function queryIsDisputed(bytes32 instanceId) external view returns (bool) {
        uint16 status = _getStorage().status[instanceId];
        return status == FILED || status == AWAITING_RULING || status == RULED || status == EXECUTED;
    }

    /// @notice Check if ruling has been issued
    /// @param instanceId Unique identifier for this arbitration instance
    /// @return True if in RULED or EXECUTED state
    function queryIsRuled(bytes32 instanceId) external view returns (bool) {
        uint16 status = _getStorage().status[instanceId];
        return status == RULED || status == EXECUTED;
    }

    /// @notice Check if ruling has been executed
    /// @param instanceId Unique identifier for this arbitration instance
    /// @return True if in EXECUTED state
    function queryIsExecuted(bytes32 instanceId) external view returns (bool) {
        return _getStorage().status[instanceId] == EXECUTED;
    }

    /// @notice Check if evidence window is still open
    /// @param instanceId Unique identifier for this arbitration instance
    /// @return True if evidence can still be submitted
    function queryIsEvidenceWindowOpen(bytes32 instanceId) external view returns (bool) {
        ArbitrationStorage storage $ = _getStorage();
        if ($.status[instanceId] != FILED) return false;
        return block.timestamp <= $.evidenceDeadline[instanceId];
    }

    /// @notice Get the filed timestamp
    /// @param instanceId Unique identifier for this arbitration instance
    /// @return When the claim was filed
    function queryFiledAt(bytes32 instanceId) external view returns (uint64) {
        return _getStorage().filedAt[instanceId];
    }
}
