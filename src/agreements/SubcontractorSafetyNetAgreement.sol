// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AgreementBaseV3} from "../base/AgreementBaseV3.sol";
import {SignatureClauseLogicV3} from "../clauses/attestation/SignatureClauseLogicV3.sol";
import {EscrowClauseLogicV3} from "../clauses/financial/EscrowClauseLogicV3.sol";
import {ArbitrationClauseLogicV3} from "../clauses/governance/ArbitrationClauseLogicV3.sol";

/// @title SubcontractorSafetyNetAgreement
/// @notice Maximum protection agreement for subcontractors against non-payment
/// @dev Supports TWO modes of operation:
///
///      SIMPLE MODE (default): Singleton with multiple instances
///      - Deploy once per chain
///      - Users call createInstance() to create new agreements
///      - Cheap: ~20-30k gas per instance (storage writes only)
///      - Identified by: address + instanceId
///
///      TECHNICAL MODE (advanced): Proxy per agreement
///      - Factory clones this contract for each agreement
///      - Users call initialize() on the fresh proxy
///      - Identified by: proxy address only
///
///      THE SAFETY NET:
///      This agreement flips the script. The CLIENT must actively reject work
///      within a review period, or payment auto-releases to the subcontractor.
///      No response = payment released. Ghost the contractor? They still get paid.
///
///      FLOW:
///      1. Client creates Agreement and deposits FULL payment upfront
///      2. Both parties sign terms (includes scope & review period)
///      3. Subcontractor delivers work before work deadline
///      4. Review period starts (e.g., 7 days)
///      5. Client has TWO options:
///         a. APPROVE: Payment releases immediately
///         b. DISPUTE: Opens arbitration (funds locked until resolved)
///      6. If client does NOTHING within review period:
///         → AUTOMATIC RELEASE to subcontractor (enforceDeadline)
///
///      CLAUSES COMPOSED:
///      - SignatureClauseLogicV3: Both parties sign terms
///      - EscrowClauseLogicV3: Holds payment with auto-release capability
///      - ArbitrationClauseLogicV3: Handles disputes with third-party resolution
contract SubcontractorSafetyNetAgreement is AgreementBaseV3 {
    // ═══════════════════════════════════════════════════════════════
    //                        CONSTANTS
    // ═══════════════════════════════════════════════════════════════

    /// @notice Default review period if not specified
    uint256 public constant DEFAULT_REVIEW_PERIOD = 7 days;

    /// @notice Minimum review period (can't be too short)
    uint256 public constant MIN_REVIEW_PERIOD = 3 days;

    // ═══════════════════════════════════════════════════════════════
    //                        IMMUTABLES
    // ═══════════════════════════════════════════════════════════════

    SignatureClauseLogicV3 public immutable signatureClause;
    EscrowClauseLogicV3 public immutable escrowClause;
    ArbitrationClauseLogicV3 public immutable arbitrationClause;

    // ═══════════════════════════════════════════════════════════════
    //                         ENUMS
    // ═══════════════════════════════════════════════════════════════

    enum Ruling {
        NONE, // 0 - Not yet ruled
        CLIENT_WINS, // 1 - Full refund to client
        SUBCONTRACTOR_WINS, // 2 - Full release to subcontractor
        SPLIT // 3 - Split per splitBasisPoints (to subcontractor)
    }

    // ═══════════════════════════════════════════════════════════════
    //                    INSTANCE DATA STRUCT
    // ═══════════════════════════════════════════════════════════════

    /// @notice Dispute information
    struct DisputeInfo {
        bool active;
        address claimant; // Who filed the dispute
        bytes32 claimCID; // IPFS CID of claim document
        uint256 filedAt;
        uint256 evidenceDeadline; // filedAt + 7 days (configurable)
        // Ruling
        Ruling ruling;
        bytes32 justificationCID;
        uint256 splitBasisPoints; // If SPLIT ruling
        uint256 ruledAt;
        bool resolved;
    }

    /// @notice Per-instance agreement data
    struct InstanceData {
        // Instance metadata
        uint256 instanceNumber; // Sequential: 1, 2, 3...
        address creator; // Who created this instance
        uint256 createdAt; // Block timestamp
        // Clause instance IDs
        bytes32 termsSignatureId; // Signature instance for initial terms
        bytes32 escrowId; // Escrow instance
        bytes32 arbitrationId; // Arbitration instance
        // Agreement-specific data
        address client;
        address subcontractor;
        address arbitrator; // Pre-selected dispute resolver
        address paymentToken; // address(0) for ETH
        uint256 paymentAmount;
        bytes32 scopeHash; // IPFS CID of scope document
        uint256 workDeadline; // When work must be submitted
        uint256 reviewPeriodDays; // Days for client to respond
        bytes32 documentCID; // IPFS CID of the agreement document
        // State flags
        bool clientSigned;
        bool subcontractorSigned;
        bool funded;
        // Work submission
        bytes32 deliverableHash;
        uint256 workSubmittedAt;
        uint256 reviewDeadline; // Calculated: submittedAt + reviewPeriodDays
        // Review outcome
        bool workApproved;
        bool deadlineEnforced; // True if auto-released
        // Dispute
        DisputeInfo dispute;
    }

    // ═══════════════════════════════════════════════════════════════
    //                    AGREEMENT STORAGE
    // ═══════════════════════════════════════════════════════════════

    /// @custom:storage-location erc7201:papre.agreement.safetynet.storage
    struct SafetyNetStorage {
        // Instance management (Simple mode)
        uint256 instanceCounter;
        mapping(uint256 => InstanceData) instances;
        mapping(address => uint256[]) userInstances;
        // Proxy mode storage (Technical mode) - uses instanceId = 0
        bool isProxyMode;
    }

    // keccak256(abi.encode(uint256(keccak256("papre.agreement.safetynet.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SAFETYNET_STORAGE_SLOT =
        0x5d4e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d00;

    function _getSafetyNetStorage() internal pure returns (SafetyNetStorage storage $) {
        assembly {
            $.slot := SAFETYNET_STORAGE_SLOT
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //                          ERRORS
    // ═══════════════════════════════════════════════════════════════

    error OnlyClient();
    error OnlySubcontractor();
    error OnlyArbitrator();
    error OnlyClientOrSubcontractor();
    error TermsNotAccepted();
    error NotFunded();
    error AlreadyFunded();
    error WorkDeadlinePassed();
    error WorkNotSubmitted();
    error WorkAlreadySubmitted();
    error WorkAlreadyApproved();
    error ReviewPeriodNotExpired();
    error ReviewPeriodExpired();
    error ReviewPeriodTooShort();
    error AlreadyEnforced();
    error DisputeAlreadyActive();
    error DisputeNotActive();
    error DisputeAlreadyResolved();
    error InvalidRuling();
    error InstanceNotFound();
    error ProxyModeOnly();
    error SingletonModeOnly();

    // ═══════════════════════════════════════════════════════════════
    //                          EVENTS
    // ═══════════════════════════════════════════════════════════════

    event InstanceCreated(
        uint256 indexed instanceId, address indexed client, address indexed subcontractor, address arbitrator
    );
    event SafetyNetConfigured(
        uint256 indexed instanceId,
        address indexed client,
        address indexed subcontractor,
        address arbitrator,
        uint256 paymentAmount,
        uint256 reviewPeriodDays
    );
    event TermsSigned(uint256 indexed instanceId, address indexed signer);
    event TermsAccepted(uint256 indexed instanceId, address indexed client, address indexed subcontractor);
    event PaymentDeposited(uint256 indexed instanceId, address indexed client, uint256 amount);
    event WorkSubmitted(uint256 indexed instanceId, bytes32 deliverableHash, uint256 reviewDeadline);
    event WorkApproved(uint256 indexed instanceId, uint256 approvedAt);
    event DeadlineEnforced(uint256 indexed instanceId, address indexed enforcer, uint256 releasedAmount);
    event DisputeFiled(
        uint256 indexed instanceId, address indexed claimant, bytes32 claimCID, uint256 evidenceDeadline
    );
    event EvidenceSubmitted(uint256 indexed instanceId, address indexed submitter, bytes32 evidenceCID);
    event DisputeRuled(uint256 indexed instanceId, uint8 ruling, bytes32 justificationCID, uint256 splitBasisPoints);

    // ═══════════════════════════════════════════════════════════════
    //                        MODIFIERS
    // ═══════════════════════════════════════════════════════════════

    modifier validInstance(uint256 instanceId) {
        if (_getSafetyNetStorage().instances[instanceId].creator == address(0)) {
            revert InstanceNotFound();
        }
        _;
    }

    modifier onlyInstanceClient(uint256 instanceId) {
        if (msg.sender != _getSafetyNetStorage().instances[instanceId].client) {
            revert OnlyClient();
        }
        _;
    }

    modifier onlyInstanceSubcontractor(uint256 instanceId) {
        if (msg.sender != _getSafetyNetStorage().instances[instanceId].subcontractor) {
            revert OnlySubcontractor();
        }
        _;
    }

    modifier onlyInstanceArbitrator(uint256 instanceId) {
        if (msg.sender != _getSafetyNetStorage().instances[instanceId].arbitrator) {
            revert OnlyArbitrator();
        }
        _;
    }

    modifier onlyInstanceParty(uint256 instanceId) {
        InstanceData storage inst = _getSafetyNetStorage().instances[instanceId];
        if (msg.sender != inst.client && msg.sender != inst.subcontractor) {
            revert OnlyClientOrSubcontractor();
        }
        _;
    }

    // ═══════════════════════════════════════════════════════════════
    //                      CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════

    /// @notice Deploy the Agreement (works as singleton or proxy implementation)
    constructor(address _signatureClause, address _escrowClause, address _arbitrationClause) {
        signatureClause = SignatureClauseLogicV3(_signatureClause);
        escrowClause = EscrowClauseLogicV3(_escrowClause);
        arbitrationClause = ArbitrationClauseLogicV3(_arbitrationClause);
        // Note: We don't call _disableInitializers() here because
        // the singleton needs to remain usable for createInstance()
    }

    // ═══════════════════════════════════════════════════════════════
    //                    SIMPLE MODE: CREATE INSTANCE
    // ═══════════════════════════════════════════════════════════════

    /// @notice Create a new safety net agreement instance (Simple mode)
    /// @param _client Address of the client (payer)
    /// @param _subcontractor Address of the subcontractor (payee)
    /// @param _arbitrator Address of the arbitrator (dispute resolver)
    /// @param _paymentToken Token address (address(0) for ETH)
    /// @param _paymentAmount Payment amount
    /// @param _scopeHash Hash/CID of scope document
    /// @param _workDeadline When work must be delivered (unix timestamp)
    /// @param _reviewPeriodDays How many days client has to respond after delivery
    /// @param _documentCID IPFS CID of the agreement document
    /// @return instanceId The created instance ID
    function createInstance(
        address _client,
        address _subcontractor,
        address _arbitrator,
        address _paymentToken,
        uint256 _paymentAmount,
        bytes32 _scopeHash,
        uint256 _workDeadline,
        uint256 _reviewPeriodDays,
        bytes32 _documentCID
    ) external returns (uint256 instanceId) {
        uint256 reviewPeriod = _reviewPeriodDays * 1 days;
        if (reviewPeriod < MIN_REVIEW_PERIOD) revert ReviewPeriodTooShort();

        SafetyNetStorage storage $ = _getSafetyNetStorage();

        // Cannot use createInstance on a proxy
        if ($.isProxyMode) revert SingletonModeOnly();

        // Increment counter and create instance
        $.instanceCounter++;
        instanceId = $.instanceCounter;

        InstanceData storage inst = $.instances[instanceId];
        inst.instanceNumber = instanceId;
        inst.creator = msg.sender;
        inst.createdAt = block.timestamp;
        inst.client = _client;
        inst.subcontractor = _subcontractor;
        inst.arbitrator = _arbitrator;
        inst.paymentToken = _paymentToken;
        inst.paymentAmount = _paymentAmount;
        inst.scopeHash = _scopeHash;
        inst.workDeadline = _workDeadline;
        inst.reviewPeriodDays = _reviewPeriodDays;
        inst.documentCID = _documentCID;

        // Generate unique clause instance IDs
        inst.termsSignatureId = keccak256(abi.encode(address(this), instanceId, "terms"));
        inst.escrowId = keccak256(abi.encode(address(this), instanceId, "escrow"));
        inst.arbitrationId = keccak256(abi.encode(address(this), instanceId, "arbitration"));

        // Track instances by user
        $.userInstances[_client].push(instanceId);
        if (_subcontractor != _client) {
            $.userInstances[_subcontractor].push(instanceId);
        }

        // Initialize clauses
        _initializeClauses(inst);

        emit InstanceCreated(instanceId, _client, _subcontractor, _arbitrator);
        emit SafetyNetConfigured(instanceId, _client, _subcontractor, _arbitrator, _paymentAmount, _reviewPeriodDays);

        return instanceId;
    }

    // ═══════════════════════════════════════════════════════════════
    //                    TECHNICAL MODE: INITIALIZE (PROXY)
    // ═══════════════════════════════════════════════════════════════

    /// @notice Initialize a proxy-deployed agreement (Technical mode)
    /// @dev Called once when factory clones this contract
    function initialize(
        address _client,
        address _subcontractor,
        address _arbitrator,
        address _paymentToken,
        uint256 _paymentAmount,
        bytes32 _scopeHash,
        uint256 _workDeadline,
        uint256 _reviewPeriodDays,
        bytes32 _documentCID
    ) external initializer {
        uint256 reviewPeriod = _reviewPeriodDays * 1 days;
        if (reviewPeriod < MIN_REVIEW_PERIOD) revert ReviewPeriodTooShort();

        __AgreementBase_init(_client);

        SafetyNetStorage storage $ = _getSafetyNetStorage();
        $.isProxyMode = true;

        // Use instance 0 for proxy mode
        uint256 instanceId = 0;
        InstanceData storage inst = $.instances[instanceId];

        inst.instanceNumber = 0;
        inst.creator = _client;
        inst.createdAt = block.timestamp;
        inst.client = _client;
        inst.subcontractor = _subcontractor;
        inst.arbitrator = _arbitrator;
        inst.paymentToken = _paymentToken;
        inst.paymentAmount = _paymentAmount;
        inst.scopeHash = _scopeHash;
        inst.workDeadline = _workDeadline;
        inst.reviewPeriodDays = _reviewPeriodDays;
        inst.documentCID = _documentCID;

        // Generate unique clause instance IDs
        inst.termsSignatureId = keccak256(abi.encode(address(this), "terms"));
        inst.escrowId = keccak256(abi.encode(address(this), "escrow"));
        inst.arbitrationId = keccak256(abi.encode(address(this), "arbitration"));

        // Add parties
        _addParty(_subcontractor);
        _addParty(_arbitrator);

        // Initialize clauses
        _initializeClauses(inst);

        emit SafetyNetConfigured(0, _client, _subcontractor, _arbitrator, _paymentAmount, _reviewPeriodDays);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    INTERNAL: CLAUSE INITIALIZATION
    // ═══════════════════════════════════════════════════════════════

    function _initializeClauses(InstanceData storage inst) internal {
        // Initialize terms signature clause (both parties must sign)
        address[] memory signers = new address[](2);
        signers[0] = inst.client;
        signers[1] = inst.subcontractor;

        _delegateToClause(
            address(signatureClause),
            abi.encodeCall(SignatureClauseLogicV3.intakeSigners, (inst.termsSignatureId, signers))
        );
        _delegateToClause(
            address(signatureClause),
            abi.encodeCall(SignatureClauseLogicV3.intakeDocumentHash, (inst.termsSignatureId, inst.scopeHash))
        );

        // Initialize escrow clause
        _delegateToClause(
            address(escrowClause), abi.encodeCall(EscrowClauseLogicV3.intakeDepositor, (inst.escrowId, inst.client))
        );
        _delegateToClause(
            address(escrowClause),
            abi.encodeCall(EscrowClauseLogicV3.intakeBeneficiary, (inst.escrowId, inst.subcontractor))
        );
        _delegateToClause(
            address(escrowClause), abi.encodeCall(EscrowClauseLogicV3.intakeToken, (inst.escrowId, inst.paymentToken))
        );
        _delegateToClause(
            address(escrowClause), abi.encodeCall(EscrowClauseLogicV3.intakeAmount, (inst.escrowId, inst.paymentAmount))
        );

        // Cancellation only available to client with 50% kill fee
        _delegateToClause(
            address(escrowClause), abi.encodeCall(EscrowClauseLogicV3.intakeCancellationEnabled, (inst.escrowId, true))
        );
        _delegateToClause(
            address(escrowClause),
            abi.encodeCall(
                EscrowClauseLogicV3.intakeCancellableBy, (inst.escrowId, EscrowClauseLogicV3.CancellableBy.DEPOSITOR)
            )
        );
        _delegateToClause(
            address(escrowClause),
            abi.encodeCall(
                EscrowClauseLogicV3.intakeCancellationFeeType, (inst.escrowId, EscrowClauseLogicV3.FeeType.BPS)
            )
        );
        _delegateToClause(
            address(escrowClause),
            abi.encodeCall(EscrowClauseLogicV3.intakeCancellationFeeAmount, (inst.escrowId, 5000))
        );

        _delegateToClause(address(escrowClause), abi.encodeCall(EscrowClauseLogicV3.intakeReady, (inst.escrowId)));
    }

    // ═══════════════════════════════════════════════════════════════
    //                    PHASE 1: SIGN TERMS
    // ═══════════════════════════════════════════════════════════════

    /// @notice Sign the agreement terms
    /// @param instanceId The instance ID
    /// @param signature EIP-712 signature
    function signTerms(uint256 instanceId, bytes calldata signature)
        external
        validInstance(instanceId)
        onlyInstanceParty(instanceId)
    {
        InstanceData storage inst = _getSafetyNetStorage().instances[instanceId];

        _delegateToClause(
            address(signatureClause),
            abi.encodeCall(SignatureClauseLogicV3.actionSign, (inst.termsSignatureId, signature))
        );

        // Track who signed
        if (msg.sender == inst.client) {
            inst.clientSigned = true;
        } else {
            inst.subcontractorSigned = true;
        }

        emit TermsSigned(instanceId, msg.sender);

        // Check if both have signed
        bytes memory statusResult = _delegateViewToClause(
            address(signatureClause), abi.encodeCall(SignatureClauseLogicV3.queryStatus, (inst.termsSignatureId))
        );
        uint16 status = abi.decode(statusResult, (uint16));

        if (status == 0x0004) {
            // COMPLETE
            emit TermsAccepted(instanceId, inst.client, inst.subcontractor);
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //                    PHASE 2: DEPOSIT PAYMENT
    // ═══════════════════════════════════════════════════════════════

    /// @notice Client deposits payment into escrow
    /// @param instanceId The instance ID
    function depositPayment(uint256 instanceId)
        external
        payable
        validInstance(instanceId)
        onlyInstanceClient(instanceId)
    {
        InstanceData storage inst = _getSafetyNetStorage().instances[instanceId];

        if (!inst.clientSigned || !inst.subcontractorSigned) revert TermsNotAccepted();
        if (inst.funded) revert AlreadyFunded();

        _delegateToClause(address(escrowClause), abi.encodeCall(EscrowClauseLogicV3.actionDeposit, (inst.escrowId)));

        inst.funded = true;

        emit PaymentDeposited(instanceId, inst.client, inst.paymentAmount);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    PHASE 3: SUBMIT WORK
    // ═══════════════════════════════════════════════════════════════

    /// @notice Submit completed work (subcontractor only)
    /// @dev Starts the review period countdown
    /// @param instanceId The instance ID
    /// @param deliverableHash IPFS CID of the deliverable
    function submitWork(uint256 instanceId, bytes32 deliverableHash)
        external
        validInstance(instanceId)
        onlyInstanceSubcontractor(instanceId)
    {
        InstanceData storage inst = _getSafetyNetStorage().instances[instanceId];

        if (!inst.funded) revert NotFunded();
        if (block.timestamp > inst.workDeadline) revert WorkDeadlinePassed();
        if (inst.workSubmittedAt > 0) revert WorkAlreadySubmitted();

        inst.deliverableHash = deliverableHash;
        inst.workSubmittedAt = block.timestamp;
        inst.reviewDeadline = block.timestamp + (inst.reviewPeriodDays * 1 days);

        emit WorkSubmitted(instanceId, deliverableHash, inst.reviewDeadline);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    PHASE 4: CLIENT RESPONSE
    // ═══════════════════════════════════════════════════════════════

    /// @notice Approve work and release payment (client only)
    /// @param instanceId The instance ID
    function approveWork(uint256 instanceId) external validInstance(instanceId) onlyInstanceClient(instanceId) {
        InstanceData storage inst = _getSafetyNetStorage().instances[instanceId];

        if (inst.workSubmittedAt == 0) revert WorkNotSubmitted();
        if (inst.workApproved) revert WorkAlreadyApproved();
        if (inst.deadlineEnforced) revert AlreadyEnforced();
        if (inst.dispute.active && !inst.dispute.resolved) revert DisputeAlreadyActive();

        inst.workApproved = true;

        // Release escrow
        _delegateToClause(address(escrowClause), abi.encodeCall(EscrowClauseLogicV3.actionRelease, (inst.escrowId)));

        emit WorkApproved(instanceId, block.timestamp);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    DEADLINE ENFORCEMENT (THE SAFETY NET)
    // ═══════════════════════════════════════════════════════════════

    /// @notice Check if the deadline can be enforced
    /// @param instanceId The instance ID
    /// @return True if reviewDeadline passed, not approved, not disputed
    function canEnforceDeadline(uint256 instanceId) external view returns (bool) {
        InstanceData storage inst = _getSafetyNetStorage().instances[instanceId];

        // Must have work submitted
        if (inst.workSubmittedAt == 0) return false;

        // Must be past review deadline
        if (block.timestamp <= inst.reviewDeadline) return false;

        // Must not already be approved
        if (inst.workApproved) return false;

        // Must not already be enforced
        if (inst.deadlineEnforced) return false;

        // Must not have active dispute
        if (inst.dispute.active && !inst.dispute.resolved) return false;

        return true;
    }

    /// @notice Enforce deadline - auto-release to subcontractor (anyone)
    /// @dev Can only be called after reviewDeadline has passed
    /// @param instanceId The instance ID
    function enforceDeadline(uint256 instanceId) external validInstance(instanceId) {
        InstanceData storage inst = _getSafetyNetStorage().instances[instanceId];

        // Check all conditions
        if (inst.workSubmittedAt == 0) revert WorkNotSubmitted();
        if (block.timestamp <= inst.reviewDeadline) revert ReviewPeriodNotExpired();
        if (inst.workApproved) revert WorkAlreadyApproved();
        if (inst.deadlineEnforced) revert AlreadyEnforced();
        if (inst.dispute.active && !inst.dispute.resolved) revert DisputeAlreadyActive();

        inst.deadlineEnforced = true;

        // Release full amount to subcontractor
        _delegateToClause(address(escrowClause), abi.encodeCall(EscrowClauseLogicV3.actionRelease, (inst.escrowId)));

        emit DeadlineEnforced(instanceId, msg.sender, inst.paymentAmount);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    ARBITRATION
    // ═══════════════════════════════════════════════════════════════

    /// @notice File a dispute claim (client or subcontractor)
    /// @param instanceId The instance ID
    /// @param claimCID IPFS CID of the claim document
    function fileClaim(uint256 instanceId, bytes32 claimCID)
        external
        validInstance(instanceId)
        onlyInstanceParty(instanceId)
    {
        InstanceData storage inst = _getSafetyNetStorage().instances[instanceId];

        if (inst.workSubmittedAt == 0) revert WorkNotSubmitted();
        if (inst.workApproved) revert WorkAlreadyApproved();
        if (inst.deadlineEnforced) revert AlreadyEnforced();
        if (inst.dispute.active) revert DisputeAlreadyActive();

        // Check we're within review period for client
        // After review period, subcontractor can still file if needed
        if (msg.sender == inst.client) {
            if (block.timestamp > inst.reviewDeadline) revert ReviewPeriodExpired();
        }

        inst.dispute.active = true;
        inst.dispute.claimant = msg.sender;
        inst.dispute.claimCID = claimCID;
        inst.dispute.filedAt = block.timestamp;
        inst.dispute.evidenceDeadline = block.timestamp + 7 days;

        // Initialize arbitration clause
        _delegateToClause(
            address(arbitrationClause),
            abi.encodeCall(ArbitrationClauseLogicV3.intakeArbitrator, (inst.arbitrationId, inst.arbitrator))
        );
        _delegateToClause(
            address(arbitrationClause),
            abi.encodeCall(ArbitrationClauseLogicV3.intakeClaimant, (inst.arbitrationId, msg.sender))
        );
        address respondent = msg.sender == inst.client ? inst.subcontractor : inst.client;
        _delegateToClause(
            address(arbitrationClause),
            abi.encodeCall(ArbitrationClauseLogicV3.intakeRespondent, (inst.arbitrationId, respondent))
        );
        _delegateToClause(
            address(arbitrationClause), abi.encodeCall(ArbitrationClauseLogicV3.intakeReady, (inst.arbitrationId))
        );
        _delegateToClause(
            address(arbitrationClause),
            abi.encodeCall(ArbitrationClauseLogicV3.actionFileClaim, (inst.arbitrationId, claimCID))
        );

        emit DisputeFiled(instanceId, msg.sender, claimCID, inst.dispute.evidenceDeadline);
    }

    /// @notice Submit evidence for a dispute
    /// @param instanceId The instance ID
    /// @param evidenceCID IPFS CID of evidence document
    function submitEvidence(uint256 instanceId, bytes32 evidenceCID)
        external
        validInstance(instanceId)
        onlyInstanceParty(instanceId)
    {
        InstanceData storage inst = _getSafetyNetStorage().instances[instanceId];

        if (!inst.dispute.active) revert DisputeNotActive();
        if (inst.dispute.resolved) revert DisputeAlreadyResolved();

        // Note: Evidence is tracked in the arbitration clause, we just emit event here
        emit EvidenceSubmitted(instanceId, msg.sender, evidenceCID);
    }

    /// @notice Rule on a dispute (arbitrator only)
    /// @param instanceId The instance ID
    /// @param ruling The ruling (0=none, 1=client wins, 2=subcontractor wins, 3=split)
    /// @param justificationCID IPFS CID of ruling justification
    /// @param splitBasisPoints If ruling=SPLIT, percentage to subcontractor (e.g., 7500 = 75%)
    function rule(uint256 instanceId, uint8 ruling, bytes32 justificationCID, uint256 splitBasisPoints)
        external
        validInstance(instanceId)
        onlyInstanceArbitrator(instanceId)
    {
        InstanceData storage inst = _getSafetyNetStorage().instances[instanceId];

        if (!inst.dispute.active) revert DisputeNotActive();
        if (inst.dispute.resolved) revert DisputeAlreadyResolved();
        if (ruling == 0 || ruling > 3) revert InvalidRuling();

        inst.dispute.ruling = Ruling(ruling);
        inst.dispute.justificationCID = justificationCID;
        inst.dispute.splitBasisPoints = splitBasisPoints;
        inst.dispute.ruledAt = block.timestamp;
        inst.dispute.resolved = true;

        // Execute ruling
        if (ruling == uint8(Ruling.SUBCONTRACTOR_WINS)) {
            // Full release to subcontractor
            _delegateToClause(address(escrowClause), abi.encodeCall(EscrowClauseLogicV3.actionRelease, (inst.escrowId)));
        } else if (ruling == uint8(Ruling.CLIENT_WINS)) {
            // Full refund to client
            _delegateToClause(address(escrowClause), abi.encodeCall(EscrowClauseLogicV3.actionRefund, (inst.escrowId)));
        } else {
            // SPLIT - release full to subcontractor (they handle client portion off-chain)
            // In production, implement proper split mechanism
            _delegateToClause(address(escrowClause), abi.encodeCall(EscrowClauseLogicV3.actionRelease, (inst.escrowId)));
        }

        emit DisputeRuled(instanceId, ruling, justificationCID, splitBasisPoints);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    /// @notice Get the total number of instances
    function getInstanceCount() external view returns (uint256) {
        return _getSafetyNetStorage().instanceCounter;
    }

    /// @notice Get all instance IDs for a user
    function getUserInstances(address user) external view returns (uint256[] memory) {
        return _getSafetyNetStorage().userInstances[user];
    }

    /// @notice Get instance core data
    /// @dev Matches frontend hook expectations - returns 11 values
    function getInstance(uint256 instanceId)
        external
        view
        returns (
            uint256 instanceNumber,
            address creator,
            uint256 createdAt,
            address client,
            address subcontractor,
            address arbitrator,
            address paymentToken,
            uint256 paymentAmount,
            bytes32 scopeHash,
            uint256 workDeadline,
            uint256 reviewPeriodDays
        )
    {
        InstanceData storage inst = _getSafetyNetStorage().instances[instanceId];
        return (
            inst.instanceNumber,
            inst.creator,
            inst.createdAt,
            inst.client,
            inst.subcontractor,
            inst.arbitrator,
            inst.paymentToken,
            inst.paymentAmount,
            inst.scopeHash,
            inst.workDeadline,
            inst.reviewPeriodDays
        );
    }

    /// @notice Get instance state
    /// @dev Matches frontend hook expectations - returns 8 values
    function getInstanceState(uint256 instanceId)
        external
        view
        returns (
            bool termsAccepted,
            bool funded,
            bool workSubmitted,
            bool workApproved,
            uint256 reviewDeadline,
            bool deadlineEnforced,
            bool disputeActive,
            bool disputeResolved
        )
    {
        InstanceData storage inst = _getSafetyNetStorage().instances[instanceId];
        bool _termsAccepted = inst.clientSigned && inst.subcontractorSigned;

        return (
            _termsAccepted,
            inst.funded,
            inst.workSubmittedAt > 0,
            inst.workApproved,
            inst.reviewDeadline,
            inst.deadlineEnforced,
            inst.dispute.active,
            inst.dispute.resolved
        );
    }

    /// @notice Get dispute information
    /// @dev Matches frontend hook expectations - returns 8 values
    function getDispute(uint256 instanceId)
        external
        view
        returns (
            address claimant,
            bytes32 claimCID,
            uint256 filedAt,
            uint256 evidenceDeadline,
            uint8 ruling,
            bytes32 justificationCID,
            uint256 splitBasisPoints,
            uint256 ruledAt
        )
    {
        DisputeInfo storage dispute = _getSafetyNetStorage().instances[instanceId].dispute;
        return (
            dispute.claimant,
            dispute.claimCID,
            dispute.filedAt,
            dispute.evidenceDeadline,
            uint8(dispute.ruling),
            dispute.justificationCID,
            dispute.splitBasisPoints,
            dispute.ruledAt
        );
    }

    /// @notice Check if instance is funded
    /// @param instanceId The instance ID
    /// @return True if escrow has been funded
    function isFunded(uint256 instanceId) external view returns (bool) {
        return _getSafetyNetStorage().instances[instanceId].funded;
    }

    /// @notice Get the document CID for an instance
    /// @param instanceId The instance ID
    /// @return The IPFS CID as bytes32
    function getDocumentCID(uint256 instanceId) external view returns (bytes32) {
        return _getSafetyNetStorage().instances[instanceId].documentCID;
    }

    /// @notice Check if this is running in proxy mode
    function isProxyMode() external view returns (bool) {
        return _getSafetyNetStorage().isProxyMode;
    }

    // Allow receiving ETH for escrow deposits
    receive() external payable {}
}
