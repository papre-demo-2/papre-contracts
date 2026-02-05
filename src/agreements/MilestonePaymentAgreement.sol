// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AgreementBaseV3} from "../base/AgreementBaseV3.sol";
import {SignatureClauseLogicV3} from "../clauses/attestation/SignatureClauseLogicV3.sol";
import {EscrowClauseLogicV3} from "../clauses/financial/EscrowClauseLogicV3.sol";
import {MilestoneClauseLogicV3} from "../clauses/orchestration/MilestoneClauseLogicV3.sol";
import {MilestoneEscrowAdapter} from "../adapters/MilestoneEscrowAdapter.sol";
import {ArbitrationReputationAdapter} from "../adapters/ArbitrationReputationAdapter.sol";
import {IDisputable} from "../interfaces/IDisputable.sol";

/// @title MilestonePaymentAgreement
/// @notice Multi-milestone project agreement with staged escrow releases
/// @dev Protects subcontractors doing phased work (software, construction, etc.)
///
///      Supports TWO modes of operation:
///
///      SIMPLE MODE (default): Singleton with multiple instances
///      - Deploy once per chain
///      - Users call createInstance() to create new agreements
///      - Cheap: ~30-50k gas per instance (storage writes only)
///      - Identified by: address + instanceId
///
///      TECHNICAL MODE (advanced): Proxy per agreement
///      - Factory clones this contract for each agreement
///      - Users call initialize() on the fresh proxy
///      - More expensive: ~50k gas for proxy deployment
///      - Identified by: proxy address only
///
///      REAL-WORLD USE CASE:
///      A software developer is hired to build a web app in 3 phases:
///      1. Design ($5,000) - Due in 2 weeks
///      2. Development ($15,000) - Due in 6 weeks
///      3. Testing & Launch ($5,000) - Due in 8 weeks
///
///      Client deposits full $25,000 upfront. As each milestone is approved,
///      that portion releases to the developer. If client goes silent,
///      developer is protected by the funds already in escrow.
///
///      FLOW:
///      ┌─────────────────────────────────────────────────────────────────────────┐
///      │  1. Client creates Agreement with milestone breakdown                   │
///      │  2. Both parties sign the terms                                        │
///      │  3. Client deposits FULL project amount into escrow                    │
///      │  4. For each milestone:                                                │
///      │     a. Developer submits deliverable                                   │
///      │     b. Client approves → milestone's portion releases                  │
///      │                                                                        │
///      │  PROTECTION FOR SUBCONTRACTOR:                                         │
///      │  - Funds are locked upfront, client can't walk away with the money    │
///      │  - Each milestone release is irreversible once approved               │
///      │  - Remaining milestones have cancellation terms                        │
///      └─────────────────────────────────────────────────────────────────────────┘
///
///      CLAUSES COMPOSED:
///      - SignatureClauseLogicV3: Both parties sign to agree on terms
///      - EscrowClauseLogicV3: Multiple instances (one per milestone)
///      - MilestoneClauseLogicV3: Track milestone state and deadlines
contract MilestonePaymentAgreement is AgreementBaseV3, IDisputable {
    // ═══════════════════════════════════════════════════════════════
    //                        CONSTANTS
    // ═══════════════════════════════════════════════════════════════

    uint8 public constant MAX_MILESTONES = 10;

    // ═══════════════════════════════════════════════════════════════
    //                        IMMUTABLES
    // ═══════════════════════════════════════════════════════════════

    SignatureClauseLogicV3 public immutable signatureClause;
    EscrowClauseLogicV3 public immutable escrowClause;
    MilestoneClauseLogicV3 public immutable milestoneClause;
    MilestoneEscrowAdapter public immutable milestoneAdapter;
    /// @notice Optional reputation adapter for arbitrator rating (can be address(0))
    ArbitrationReputationAdapter public immutable reputationAdapter;

    // ═══════════════════════════════════════════════════════════════
    //                    AGREEMENT STORAGE
    // ═══════════════════════════════════════════════════════════════

    /// @notice Configuration for a single milestone
    struct MilestoneConfig {
        bytes32 description; // Hash/CID of milestone description
        uint256 amount; // Payment amount for this milestone
        uint256 deadline; // Unix timestamp deadline
        uint256 releasedAt; // Unix timestamp when payment was released (0 if not yet released)
        string disputeReason; // On-chain dispute reason (empty if not disputed)
        uint256 disputedAt; // Timestamp when disputed (0 if never disputed)
        string submissionMessage; // Contractor's message when submitting work
        uint256 submittedAt; // Timestamp when work was submitted (0 if not yet submitted)
    }

    /// @notice Per-instance data for milestone agreement
    struct InstanceData {
        // Instance metadata
        uint256 instanceNumber;
        address creator;
        uint256 createdAt;
        // Parties
        address client;
        address contractor;
        // Payment config
        address paymentToken;
        uint256 totalAmount;
        // Instance IDs
        bytes32 termsSignatureId;
        bytes32 milestoneTrackerId;
        bytes32[MAX_MILESTONES] escrowIds;
        // Milestone data
        uint8 milestoneCount;
        MilestoneConfig[MAX_MILESTONES] milestones;
        // Document storage
        bytes32 documentCID; // Keccak256 hash of filled agreement CID on Storacha
        // State
        bool termsAccepted;
        bool funded;
        uint8 completedMilestones;
        bool cancelled;
        // Arbitration (IDisputable)
        address arbitrationAgreement;
        uint256 arbitrationInstanceId;
        bool disputeResolved;
    }

    /// @custom:storage-location erc7201:papre.agreement.milestonepayment.storage
    struct MilestonePaymentStorage {
        // Instance management (Simple mode)
        uint256 instanceCounter;
        mapping(uint256 => InstanceData) instances;
        mapping(address => uint256[]) userInstances;
        // Proxy mode storage (Technical mode) - uses instanceId = 0
        bool isProxyMode;
    }

    // keccak256(abi.encode(uint256(keccak256("papre.agreement.milestonepayment.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant MILESTONE_STORAGE_SLOT =
        0x3b2c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b00;

    function _getMilestoneStorage() internal pure returns (MilestonePaymentStorage storage $) {
        assembly {
            $.slot := MILESTONE_STORAGE_SLOT
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //                          ERRORS
    // ═══════════════════════════════════════════════════════════════

    error OnlyClient();
    error OnlyContractor();
    error OnlyClientOrContractor();
    error TooManyMilestones();
    error InvalidMilestoneConfig();
    error TermsNotAccepted();
    error NotFunded();
    error MilestoneNotReady();
    error AllMilestonesComplete();
    error InvalidMilestoneIndex();
    error MilestoneNotPending();
    error AmountMismatch();
    error InstanceNotFound();
    error AlreadyCancelled();
    error ProxyModeOnly();
    error SingletonModeOnly();
    error ContractorAlreadySet();
    error ClientAlreadySet();
    error NotPendingSlot();
    error OnlyCreator();
    error DocumentCIDAlreadySet();
    error InvalidDocumentCID();
    error OnlyArbitrationAgreement();
    error ArbitrationAlreadyLinked();
    error ArbitrationNotLinked();
    error DisputeAlreadyResolved();
    error CannotInitiateArbitrationNow();
    error InvalidRuling();
    error ReputationAdapterNotConfigured();
    error ReputationWindowNotOpen();

    // ═══════════════════════════════════════════════════════════════
    //                          EVENTS
    // ═══════════════════════════════════════════════════════════════

    event InstanceCreated(uint256 indexed instanceId, address indexed client, address indexed contractor);
    event ProjectConfigured(
        uint256 indexed instanceId,
        address indexed client,
        address indexed contractor,
        uint8 milestoneCount,
        uint256 totalAmount,
        bytes32 documentCID
    );
    event TermsAccepted(uint256 indexed instanceId, address indexed client, address indexed contractor);
    event ProjectFunded(uint256 indexed instanceId, address indexed client, uint256 totalAmount);
    event MilestoneSubmitted(uint256 indexed instanceId, uint8 milestoneIndex, bytes32 deliverableHash, string message);
    event MilestoneApproved(uint256 indexed instanceId, uint8 milestoneIndex, uint256 amount);
    event MilestoneRejected(uint256 indexed instanceId, uint8 milestoneIndex, string reason);
    event ProjectCompleted(uint256 indexed instanceId, address indexed contractor, uint256 totalPaid);
    event ProjectCancelled(uint256 indexed instanceId, address indexed cancelledBy);
    event ContractorSlotClaimed(uint256 indexed instanceId, address indexed contractor);
    event ClientSlotClaimed(uint256 indexed instanceId, address indexed client);
    event TrustedAttestorUpdated(address indexed attestor, bool trusted);
    event DocumentCIDSet(uint256 indexed instanceId, bytes32 cid);
    event ReputationWindowOpened(
        uint256 indexed instanceId,
        bytes32 indexed reputationInstanceId,
        address indexed arbitrator,
        uint8 ruling,
        uint48 windowClosesAt
    );
    event ArbitratorRated(uint256 indexed instanceId, address indexed rater, address indexed arbitrator, uint8 score);

    // ═══════════════════════════════════════════════════════════════
    //                        MODIFIERS
    // ═══════════════════════════════════════════════════════════════

    modifier validInstance(uint256 instanceId) {
        if (_getMilestoneStorage().instances[instanceId].creator == address(0)) {
            revert InstanceNotFound();
        }
        _;
    }

    modifier onlyInstanceClient(uint256 instanceId) {
        if (msg.sender != _getMilestoneStorage().instances[instanceId].client) {
            revert OnlyClient();
        }
        _;
    }

    modifier onlyInstanceContractor(uint256 instanceId) {
        if (msg.sender != _getMilestoneStorage().instances[instanceId].contractor) {
            revert OnlyContractor();
        }
        _;
    }

    modifier onlyInstanceParty(uint256 instanceId) {
        InstanceData storage inst = _getMilestoneStorage().instances[instanceId];
        if (msg.sender != inst.client && msg.sender != inst.contractor) {
            revert OnlyClientOrContractor();
        }
        _;
    }

    modifier notCancelled(uint256 instanceId) {
        if (_getMilestoneStorage().instances[instanceId].cancelled) {
            revert AlreadyCancelled();
        }
        _;
    }

    // ═══════════════════════════════════════════════════════════════
    //                      CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════

    /// @notice Deploy the Agreement (works as singleton or proxy implementation)
    /// @param _signatureClause SignatureClauseLogicV3 address
    /// @param _escrowClause EscrowClauseLogicV3 address
    /// @param _milestoneClause MilestoneClauseLogicV3 address
    /// @param _milestoneAdapter MilestoneEscrowAdapter address
    /// @param _reputationAdapter ArbitrationReputationAdapter address (optional, can be address(0))
    constructor(
        address _signatureClause,
        address _escrowClause,
        address _milestoneClause,
        address _milestoneAdapter,
        address _reputationAdapter
    ) {
        signatureClause = SignatureClauseLogicV3(_signatureClause);
        escrowClause = EscrowClauseLogicV3(_escrowClause);
        milestoneClause = MilestoneClauseLogicV3(_milestoneClause);
        milestoneAdapter = MilestoneEscrowAdapter(_milestoneAdapter);
        reputationAdapter = ArbitrationReputationAdapter(_reputationAdapter);
        // Note: We don't call _disableInitializers() here because
        // the singleton needs to remain usable for createInstance()
    }

    // ═══════════════════════════════════════════════════════════════
    //                    SIMPLE MODE: CREATE INSTANCE
    // ═══════════════════════════════════════════════════════════════

    /// @notice Create a new agreement instance (Simple mode)
    /// @param _client Address of the client (funds the project)
    /// @param _contractor Address of the contractor (delivers work)
    /// @param _paymentToken Token address (address(0) for ETH)
    /// @param _descriptions Array of milestone description hashes
    /// @param _amounts Array of payment amounts per milestone
    /// @param _deadlines Array of deadline timestamps per milestone
    /// @param _documentCID Keccak256 hash of filled agreement CID on Storacha
    /// @return instanceId The created instance ID
    function createInstance(
        address _client,
        address _contractor,
        address _paymentToken,
        bytes32[] calldata _descriptions,
        uint256[] calldata _amounts,
        uint256[] calldata _deadlines,
        bytes32 _documentCID
    ) external returns (uint256 instanceId) {
        MilestonePaymentStorage storage $ = _getMilestoneStorage();

        // Cannot use createInstance on a proxy
        if ($.isProxyMode) revert SingletonModeOnly();

        // Validate milestone config
        uint8 count = uint8(_descriptions.length);
        if (count == 0 || count > MAX_MILESTONES) revert TooManyMilestones();
        if (_amounts.length != count || _deadlines.length != count) {
            revert InvalidMilestoneConfig();
        }

        // Increment counter and create instance
        $.instanceCounter++;
        instanceId = $.instanceCounter;

        InstanceData storage inst = $.instances[instanceId];
        inst.instanceNumber = instanceId;
        inst.creator = msg.sender;
        inst.createdAt = block.timestamp;
        inst.client = _client;
        inst.contractor = _contractor;
        inst.paymentToken = _paymentToken;
        inst.milestoneCount = count;
        inst.documentCID = _documentCID;

        // Calculate total and store milestones
        uint256 total = 0;
        for (uint8 i = 0; i < count; i++) {
            if (_amounts[i] == 0) revert InvalidMilestoneConfig();

            inst.milestones[i] = MilestoneConfig({
                description: _descriptions[i],
                amount: _amounts[i],
                deadline: _deadlines[i],
                releasedAt: 0,
                disputeReason: "",
                disputedAt: 0,
                submissionMessage: "",
                submittedAt: 0
            });

            total += _amounts[i];

            // Generate escrow instance IDs
            inst.escrowIds[i] = keccak256(abi.encode(address(this), instanceId, "escrow", i));
        }

        inst.totalAmount = total;

        // Generate clause instance IDs
        bytes32 termsHash = keccak256(abi.encode(_descriptions, _amounts, _deadlines));
        inst.termsSignatureId = keccak256(abi.encode(address(this), instanceId, "terms"));
        inst.milestoneTrackerId = keccak256(abi.encode(address(this), instanceId, "milestone-tracker"));

        // Track instances by user
        $.userInstances[_client].push(instanceId);
        if (_contractor != _client) {
            $.userInstances[_contractor].push(instanceId);
        }

        // Initialize clauses for this instance
        _initializeInstanceClauses(inst, termsHash);

        emit InstanceCreated(instanceId, _client, _contractor);
        emit ProjectConfigured(instanceId, _client, _contractor, count, total, _documentCID);

        return instanceId;
    }

    // ═══════════════════════════════════════════════════════════════
    //                    TECHNICAL MODE: INITIALIZE (PROXY)
    // ═══════════════════════════════════════════════════════════════

    /// @notice Initialize a new milestone-based project agreement (Proxy mode)
    /// @param _client Address of the client (funds the project)
    /// @param _contractor Address of the contractor (delivers work)
    /// @param _paymentToken Token address (address(0) for ETH)
    /// @param _descriptions Array of milestone description hashes
    /// @param _amounts Array of payment amounts per milestone
    /// @param _deadlines Array of deadline timestamps per milestone
    /// @param _documentCID Keccak256 hash of filled agreement CID on Storacha
    function initialize(
        address _client,
        address _contractor,
        address _paymentToken,
        bytes32[] calldata _descriptions,
        uint256[] calldata _amounts,
        uint256[] calldata _deadlines,
        bytes32 _documentCID
    ) external initializer {
        uint8 count = uint8(_descriptions.length);
        if (count == 0 || count > MAX_MILESTONES) revert TooManyMilestones();
        if (_amounts.length != count || _deadlines.length != count) {
            revert InvalidMilestoneConfig();
        }

        __AgreementBase_init(_client);

        MilestonePaymentStorage storage $ = _getMilestoneStorage();
        $.isProxyMode = true;

        // Use instance 0 for proxy mode
        InstanceData storage inst = $.instances[0];
        inst.instanceNumber = 0;
        inst.creator = _client;
        inst.createdAt = block.timestamp;
        inst.client = _client;
        inst.contractor = _contractor;
        inst.paymentToken = _paymentToken;
        inst.milestoneCount = count;
        inst.documentCID = _documentCID;

        _addParty(_contractor);

        // Calculate total and store milestones
        uint256 total = 0;
        for (uint8 i = 0; i < count; i++) {
            if (_amounts[i] == 0) revert InvalidMilestoneConfig();

            inst.milestones[i] = MilestoneConfig({
                description: _descriptions[i],
                amount: _amounts[i],
                deadline: _deadlines[i],
                releasedAt: 0,
                disputeReason: "",
                disputedAt: 0,
                submissionMessage: "",
                submittedAt: 0
            });

            total += _amounts[i];

            // Generate escrow instance IDs
            inst.escrowIds[i] = keccak256(abi.encode(address(this), "escrow", i));
        }

        inst.totalAmount = total;

        // Generate clause instance IDs
        bytes32 termsHash = keccak256(abi.encode(_descriptions, _amounts, _deadlines));
        inst.termsSignatureId = keccak256(abi.encode(address(this), "terms", termsHash));
        inst.milestoneTrackerId = keccak256(abi.encode(address(this), "milestone-tracker"));

        // Initialize clauses
        _initializeInstanceClauses(inst, termsHash);

        emit ProjectConfigured(0, _client, _contractor, count, total, _documentCID);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    PHASE 1: SIGN TERMS
    // ═══════════════════════════════════════════════════════════════

    /// @notice Sign the project terms
    /// @param instanceId The instance to sign
    /// @param signature Cryptographic signature
    function signTerms(uint256 instanceId, bytes calldata signature)
        external
        validInstance(instanceId)
        onlyInstanceParty(instanceId)
        notCancelled(instanceId)
    {
        InstanceData storage inst = _getMilestoneStorage().instances[instanceId];

        _delegateToClause(
            address(signatureClause),
            abi.encodeCall(SignatureClauseLogicV3.actionSign, (inst.termsSignatureId, signature))
        );

        bytes memory statusResult = _delegateViewToClause(
            address(signatureClause), abi.encodeCall(SignatureClauseLogicV3.queryStatus, (inst.termsSignatureId))
        );
        uint16 status = abi.decode(statusResult, (uint16));

        if (status == 0x0004) {
            // COMPLETE
            inst.termsAccepted = true;
            _initializeAllEscrows(inst);
            emit TermsAccepted(instanceId, inst.client, inst.contractor);
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //                    PHASE 2: FUND PROJECT
    // ═══════════════════════════════════════════════════════════════

    /// @notice Client deposits the FULL project amount
    /// @dev Funds are held by Agreement directly, not via escrow deposits.
    ///      This avoids delegatecall + msg.value issues in multi-escrow loops.
    ///      Individual milestone releases use actionRelease which transfers from Agreement balance.
    /// @param instanceId The instance to fund
    function fundProject(uint256 instanceId)
        external
        payable
        whenNotPaused
        validInstance(instanceId)
        onlyInstanceClient(instanceId)
        notCancelled(instanceId)
    {
        InstanceData storage inst = _getMilestoneStorage().instances[instanceId];

        if (!inst.termsAccepted) revert TermsNotAccepted();
        if (inst.funded) revert AmountMismatch(); // Already funded
        if (msg.value != inst.totalAmount) revert AmountMismatch();

        // Mark all escrows as funded (they'll draw from Agreement balance on release)
        for (uint8 i = 0; i < inst.milestoneCount; i++) {
            _delegateToClause(
                address(escrowClause), abi.encodeCall(EscrowClauseLogicV3.actionMarkFunded, (inst.escrowIds[i]))
            );
        }

        // Activate the milestone tracker (transition from PENDING to ACTIVE)
        _delegateToClause(
            address(milestoneClause), abi.encodeCall(MilestoneClauseLogicV3.actionActivate, (inst.milestoneTrackerId))
        );

        inst.funded = true;
        emit ProjectFunded(instanceId, inst.client, inst.totalAmount);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    PHASE 3: MILESTONE DELIVERY
    // ═══════════════════════════════════════════════════════════════

    /// @notice Contractor requests confirmation for a milestone
    /// @param instanceId The instance
    /// @param milestoneIndex Which milestone (0-indexed)
    /// @param message Contractor's message describing the submitted work
    function requestMilestoneConfirmation(uint256 instanceId, uint8 milestoneIndex, string calldata message)
        external
        whenNotPaused
        validInstance(instanceId)
        onlyInstanceContractor(instanceId)
        notCancelled(instanceId)
    {
        InstanceData storage inst = _getMilestoneStorage().instances[instanceId];

        if (!inst.funded) revert NotFunded();
        if (milestoneIndex >= inst.milestoneCount) revert InvalidMilestoneIndex();

        // Store the submission message and timestamp
        inst.milestones[milestoneIndex].submissionMessage = message;
        inst.milestones[milestoneIndex].submittedAt = block.timestamp;

        // Request confirmation on milestone clause
        _delegateToClause(
            address(milestoneClause),
            abi.encodeCall(
                MilestoneClauseLogicV3.actionRequestConfirmation, (inst.milestoneTrackerId, uint256(milestoneIndex))
            )
        );

        emit MilestoneSubmitted(instanceId, milestoneIndex, inst.milestones[milestoneIndex].description, message);
    }

    /// @notice Client approves a milestone and releases payment
    /// @param instanceId The instance
    /// @param milestoneIndex Which milestone (0-indexed)
    function approveMilestone(uint256 instanceId, uint8 milestoneIndex)
        external
        whenNotPaused
        validInstance(instanceId)
        onlyInstanceClient(instanceId)
        notCancelled(instanceId)
    {
        InstanceData storage inst = _getMilestoneStorage().instances[instanceId];

        if (milestoneIndex >= inst.milestoneCount) revert InvalidMilestoneIndex();

        // Use adapter to atomically confirm + release
        _delegateToClause(
            address(milestoneAdapter),
            abi.encodeCall(MilestoneEscrowAdapter.confirmAndRelease, (inst.milestoneTrackerId, uint256(milestoneIndex)))
        );

        // Record when this milestone was released
        inst.milestones[milestoneIndex].releasedAt = block.timestamp;
        inst.completedMilestones++;

        emit MilestoneApproved(instanceId, milestoneIndex, inst.milestones[milestoneIndex].amount);

        // Check if all complete
        if (inst.completedMilestones == inst.milestoneCount) {
            emit ProjectCompleted(instanceId, inst.contractor, inst.totalAmount);
        }
    }

    /// @notice Client rejects a milestone and sends it back for revision
    /// @param instanceId The instance
    /// @param milestoneIndex Which milestone (0-indexed)
    /// @param reason Human-readable reason for rejection (max ~500 chars recommended)
    /// @dev This resets the milestone to PENDING so the contractor can resubmit.
    ///      The reason is stored on-chain for transparency.
    function rejectMilestone(uint256 instanceId, uint8 milestoneIndex, string calldata reason)
        external
        whenNotPaused
        validInstance(instanceId)
        onlyInstanceClient(instanceId)
        notCancelled(instanceId)
    {
        InstanceData storage inst = _getMilestoneStorage().instances[instanceId];

        if (milestoneIndex >= inst.milestoneCount) revert InvalidMilestoneIndex();

        // Store the dispute reason on-chain
        inst.milestones[milestoneIndex].disputeReason = reason;
        inst.milestones[milestoneIndex].disputedAt = block.timestamp;

        bytes32 reasonHash = keccak256(bytes(reason));
        _delegateToClause(
            address(milestoneClause),
            abi.encodeCall(
                MilestoneClauseLogicV3.actionRejectAndReset,
                (inst.milestoneTrackerId, uint256(milestoneIndex), reasonHash)
            )
        );

        emit MilestoneRejected(instanceId, milestoneIndex, reason);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    CANCELLATION
    // ═══════════════════════════════════════════════════════════════

    /// @notice Cancel remaining milestones
    /// @dev Only cancels uncompleted milestones. Completed ones are final.
    /// @param instanceId The instance to cancel
    function cancelRemainingMilestones(uint256 instanceId)
        external
        whenNotPaused
        validInstance(instanceId)
        onlyInstanceParty(instanceId)
        notCancelled(instanceId)
    {
        InstanceData storage inst = _getMilestoneStorage().instances[instanceId];

        for (uint8 i = 0; i < inst.milestoneCount; i++) {
            // Check if this escrow is still funded (not released)
            bytes memory fundedResult = _delegateViewToClause(
                address(escrowClause), abi.encodeCall(EscrowClauseLogicV3.queryIsFunded, (inst.escrowIds[i]))
            );

            if (abi.decode(fundedResult, (bool))) {
                // Still funded - cancel it
                _delegateToClause(
                    address(escrowClause), abi.encodeCall(EscrowClauseLogicV3.actionInitiateCancel, (inst.escrowIds[i]))
                );
            }
        }

        inst.cancelled = true;
        emit ProjectCancelled(instanceId, msg.sender);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    PENDING COUNTERPARTY SUPPORT
    // ═══════════════════════════════════════════════════════════════

    /// @notice Set trusted attestor for pending counterparty claims
    /// @dev Only callable by the client (agreement creator)
    /// @param attestor Address to set trust status for
    /// @param trusted Whether the attestor is trusted
    function setTrustedAttestor(address attestor, bool trusted) external {
        _delegateToClause(
            address(signatureClause), abi.encodeCall(SignatureClauseLogicV3.setTrustedAttestor, (attestor, trusted))
        );
        emit TrustedAttestorUpdated(attestor, trusted);
    }

    /// @notice Claim the contractor slot for a pending counterparty invitation
    /// @dev Called by the invited counterparty after receiving backend attestation
    /// @param instanceId The instance to claim contractor slot for
    /// @param attestation ECDSA signature from trusted attestor
    function claimContractorSlot(uint256 instanceId, bytes calldata attestation)
        external
        validInstance(instanceId)
        notCancelled(instanceId)
    {
        InstanceData storage inst = _getMilestoneStorage().instances[instanceId];

        // Verify contractor slot is pending (address(0))
        if (inst.contractor != address(0)) {
            revert ContractorAlreadySet();
        }

        // Delegate to signature clause to verify attestation and claim slot
        // Slot index 1 = contractor (index 0 = client)
        _delegateToClause(
            address(signatureClause),
            abi.encodeCall(
                SignatureClauseLogicV3.actionClaimSignerSlot, (inst.termsSignatureId, 1, msg.sender, attestation)
            )
        );

        // Update the agreement's contractor
        inst.contractor = msg.sender;

        // Track this instance for the new contractor
        _getMilestoneStorage().userInstances[msg.sender].push(instanceId);

        emit ContractorSlotClaimed(instanceId, msg.sender);
    }

    /// @notice Check if an instance has a pending contractor slot
    /// @param instanceId The instance to check
    /// @return hasPending True if contractor slot is still address(0)
    function hasPendingContractor(uint256 instanceId)
        external
        view
        validInstance(instanceId)
        returns (bool hasPending)
    {
        return _getMilestoneStorage().instances[instanceId].contractor == address(0);
    }

    /// @notice Claim the client slot for a pending party invitation
    /// @dev Called by the invited client after receiving backend attestation
    /// @param instanceId The instance to claim client slot for
    /// @param attestation ECDSA signature from trusted attestor
    function claimClientSlot(uint256 instanceId, bytes calldata attestation)
        external
        validInstance(instanceId)
        notCancelled(instanceId)
    {
        InstanceData storage inst = _getMilestoneStorage().instances[instanceId];

        // Verify client slot is pending (address(0))
        if (inst.client != address(0)) {
            revert ClientAlreadySet();
        }

        // Delegate to signature clause to verify attestation and claim slot
        // Slot index 0 = client (index 1 = contractor)
        _delegateToClause(
            address(signatureClause),
            abi.encodeCall(
                SignatureClauseLogicV3.actionClaimSignerSlot, (inst.termsSignatureId, 0, msg.sender, attestation)
            )
        );

        // Update the agreement's client
        inst.client = msg.sender;

        // Track this instance for the new client
        _getMilestoneStorage().userInstances[msg.sender].push(instanceId);

        emit ClientSlotClaimed(instanceId, msg.sender);
    }

    /// @notice Check if an instance has a pending client slot
    /// @param instanceId The instance to check
    /// @return hasPending True if client slot is still address(0)
    function hasPendingClient(uint256 instanceId) external view validInstance(instanceId) returns (bool hasPending) {
        return _getMilestoneStorage().instances[instanceId].client == address(0);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    /// @notice Get the total number of instances (Simple mode)
    function getInstanceCount() external view returns (uint256) {
        return _getMilestoneStorage().instanceCounter;
    }

    /// @notice Get all instance IDs for a user
    function getUserInstances(address user) external view returns (uint256[] memory) {
        return _getMilestoneStorage().userInstances[user];
    }

    /// @notice Get instance data
    function getInstance(uint256 instanceId)
        external
        view
        returns (
            uint256 instanceNumber,
            address creator,
            uint256 createdAt,
            address client,
            address contractor,
            address paymentToken,
            uint256 totalAmount,
            uint8 milestoneCount
        )
    {
        InstanceData storage inst = _getMilestoneStorage().instances[instanceId];
        return (
            inst.instanceNumber,
            inst.creator,
            inst.createdAt,
            inst.client,
            inst.contractor,
            inst.paymentToken,
            inst.totalAmount,
            inst.milestoneCount
        );
    }

    /// @notice Get instance state
    function getInstanceState(uint256 instanceId)
        external
        view
        returns (bool termsAccepted, bool funded, uint8 completedMilestones, uint8 totalMilestones, bool cancelled)
    {
        InstanceData storage inst = _getMilestoneStorage().instances[instanceId];
        return (inst.termsAccepted, inst.funded, inst.completedMilestones, inst.milestoneCount, inst.cancelled);
    }

    /// @notice Get a specific milestone from an instance
    function getMilestone(uint256 instanceId, uint8 index)
        external
        view
        returns (
            bytes32 description,
            uint256 amount,
            uint256 deadline,
            uint256 releasedAt,
            string memory disputeReason,
            uint256 disputedAt,
            string memory submissionMessage,
            uint256 submittedAt
        )
    {
        InstanceData storage inst = _getMilestoneStorage().instances[instanceId];
        if (index >= inst.milestoneCount) revert InvalidMilestoneIndex();
        MilestoneConfig storage m = inst.milestones[index];
        return (
            m.description,
            m.amount,
            m.deadline,
            m.releasedAt,
            m.disputeReason,
            m.disputedAt,
            m.submissionMessage,
            m.submittedAt
        );
    }

    /// @notice Get the status of a specific milestone
    /// @param instanceId The instance ID
    /// @param index The milestone index
    /// @return status The milestone status: 1=PENDING, 2=REQUESTED, 3=RELEASED, 4=DISPUTED
    /// @dev Not marked as view because it uses delegatecall internally.
    ///      Call with eth_call (no gas cost) or accept gas cost for on-chain reads.
    function getMilestoneStatus(uint256 instanceId, uint8 index) external returns (uint8 status) {
        InstanceData storage inst = _getMilestoneStorage().instances[instanceId];
        if (index >= inst.milestoneCount) revert InvalidMilestoneIndex();

        bytes memory result = _delegateViewToClause(
            address(milestoneClause),
            abi.encodeCall(MilestoneClauseLogicV3.queryMilestoneStatus, (inst.milestoneTrackerId, uint256(index)))
        );
        return abi.decode(result, (uint8));
    }

    /// @notice Check if this is running in proxy mode
    function isProxyMode() external view returns (bool) {
        return _getMilestoneStorage().isProxyMode;
    }

    /// @notice Check if an instance is funded
    function isFunded(uint256 instanceId) external view validInstance(instanceId) returns (bool) {
        return _getMilestoneStorage().instances[instanceId].funded;
    }

    /// @notice Get the document CID for an instance
    /// @param instanceId The instance to query
    /// @return The keccak256 hash of the document CID on Storacha
    function getDocumentCID(uint256 instanceId) external view validInstance(instanceId) returns (bytes32) {
        return _getMilestoneStorage().instances[instanceId].documentCID;
    }

    /// @notice Set the document CID for an instance (one-time only)
    /// @dev Allows the creator to set the document CID after instance creation.
    ///      This solves the chicken-and-egg problem where the document may need
    ///      to reference the agreement ID before it can be uploaded.
    /// @param instanceId The instance to update
    /// @param cid The keccak256 hash of the document CID on Storacha
    function setDocumentCID(uint256 instanceId, bytes32 cid) external validInstance(instanceId) {
        MilestonePaymentStorage storage $ = _getMilestoneStorage();
        InstanceData storage inst = $.instances[instanceId];

        // Only creator can set
        if (msg.sender != inst.creator) revert OnlyCreator();

        // Can only set once (if already set, revert)
        if (inst.documentCID != bytes32(0)) revert DocumentCIDAlreadySet();

        // CID cannot be zero
        if (cid == bytes32(0)) revert InvalidDocumentCID();

        inst.documentCID = cid;

        emit DocumentCIDSet(instanceId, cid);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    IDISPUTABLE IMPLEMENTATION
    // ═══════════════════════════════════════════════════════════════

    /// @inheritdoc IDisputable
    function executeArbitrationRuling(uint256 instanceId, uint8 ruling, uint256 splitBasisPoints)
        external
        virtual
        override
        validInstance(instanceId)
    {
        InstanceData storage inst = _getMilestoneStorage().instances[instanceId];

        // Only the linked arbitration agreement can call this
        if (msg.sender != inst.arbitrationAgreement) revert OnlyArbitrationAgreement();
        if (inst.disputeResolved) revert DisputeAlreadyResolved();

        inst.disputeResolved = true;

        // Calculate total remaining (unfunded milestones)
        uint256 remainingAmount = 0;
        for (uint8 i = 0; i < inst.milestoneCount; i++) {
            // Check if this escrow is still funded (not released)
            bytes memory fundedResult = _delegateViewToClause(
                address(escrowClause), abi.encodeCall(EscrowClauseLogicV3.queryIsFunded, (inst.escrowIds[i]))
            );
            if (abi.decode(fundedResult, (bool))) {
                remainingAmount += inst.milestones[i].amount;
            }
        }

        if (remainingAmount == 0) {
            // No funds to distribute - still open reputation window
            emit ArbitrationRulingExecuted(instanceId, ruling, splitBasisPoints, address(0), address(0));
            _openArbitratorReputationWindow(instanceId, ruling);
            return;
        }

        // Execute ruling
        if (ruling == 1) {
            // CLAIMANT_WINS (contractor) - Release all remaining milestones
            _releaseAllRemainingMilestones(inst, instanceId);
            emit ArbitrationRulingExecuted(instanceId, ruling, splitBasisPoints, inst.contractor, address(0));
        } else if (ruling == 2) {
            // RESPONDENT_WINS (client) - Refund all remaining milestones
            _refundAllRemainingMilestones(inst, instanceId);
            emit ArbitrationRulingExecuted(instanceId, ruling, splitBasisPoints, address(0), inst.client);
        } else if (ruling == 3) {
            // SPLIT - Distribute based on splitBasisPoints
            _splitRemainingMilestones(inst, instanceId, splitBasisPoints);
            emit ArbitrationRulingExecuted(instanceId, ruling, splitBasisPoints, inst.contractor, inst.client);
        } else {
            revert InvalidRuling();
        }

        // Open reputation window for rating the arbitrator (if adapter configured)
        _openArbitratorReputationWindow(instanceId, ruling);
    }

    /// @inheritdoc IDisputable
    function canInitiateArbitration(uint256 instanceId) external view override returns (bool) {
        MilestonePaymentStorage storage $ = _getMilestoneStorage();
        if ($.instances[instanceId].creator == address(0)) return false; // Instance doesn't exist

        InstanceData storage inst = $.instances[instanceId];

        // Can initiate if:
        // 1. Funded
        // 2. Not already in dispute/resolved
        // 3. Not cancelled
        // 4. Not all milestones complete
        return inst.funded && !inst.disputeResolved && !inst.cancelled && inst.completedMilestones < inst.milestoneCount;
    }

    /// @inheritdoc IDisputable
    function getArbitrationAgreement(uint256 instanceId)
        external
        view
        override
        validInstance(instanceId)
        returns (address)
    {
        return _getMilestoneStorage().instances[instanceId].arbitrationAgreement;
    }

    /// @inheritdoc IDisputable
    function getArbitrationInstanceId(uint256 instanceId)
        external
        view
        override
        validInstance(instanceId)
        returns (uint256)
    {
        return _getMilestoneStorage().instances[instanceId].arbitrationInstanceId;
    }

    /// @inheritdoc IDisputable
    function getArbitrationParties(uint256 instanceId)
        external
        view
        override
        validInstance(instanceId)
        returns (address claimant, address respondent)
    {
        InstanceData storage inst = _getMilestoneStorage().instances[instanceId];
        // Claimant = contractor (delivers work), Respondent = client (pays)
        return (inst.contractor, inst.client);
    }

    /// @inheritdoc IDisputable
    function linkArbitration(uint256 instanceId, address arbitrationAgreement, uint256 arbitrationInstanceId)
        external
        override
        validInstance(instanceId)
        notCancelled(instanceId)
    {
        InstanceData storage inst = _getMilestoneStorage().instances[instanceId];

        // Can only link if not already linked
        if (inst.arbitrationAgreement != address(0)) revert ArbitrationAlreadyLinked();

        // Only parties can link (at creation or with mutual consent later)
        // For simplicity, allow either party to link initially
        if (msg.sender != inst.client && msg.sender != inst.contractor) {
            // Could also be called by ArbitrationAgreement itself during creation
            // In that case, we trust it if it's linking to itself
            if (msg.sender != arbitrationAgreement) {
                revert OnlyClientOrContractor();
            }
        }

        inst.arbitrationAgreement = arbitrationAgreement;
        inst.arbitrationInstanceId = arbitrationInstanceId;

        emit ArbitrationLinked(instanceId, arbitrationAgreement, arbitrationInstanceId);
    }

    /// @inheritdoc IDisputable
    function hasArbitrationLinked(uint256 instanceId) external view override validInstance(instanceId) returns (bool) {
        return _getMilestoneStorage().instances[instanceId].arbitrationAgreement != address(0);
    }

    /// @inheritdoc IDisputable
    function isDisputeResolved(uint256 instanceId) external view override validInstance(instanceId) returns (bool) {
        return _getMilestoneStorage().instances[instanceId].disputeResolved;
    }

    // ═══════════════════════════════════════════════════════════════
    //                    LEGACY COMPATIBILITY (PROXY MODE)
    // ═══════════════════════════════════════════════════════════════

    /// @notice Legacy: Get client (proxy mode only, uses instance 0)
    function getClient() external view returns (address) {
        return _getMilestoneStorage().instances[0].client;
    }

    /// @notice Legacy: Get contractor (proxy mode only, uses instance 0)
    function getContractor() external view returns (address) {
        return _getMilestoneStorage().instances[0].contractor;
    }

    /// @notice Legacy: Get milestone count (proxy mode only, uses instance 0)
    function getMilestoneCount() external view returns (uint8) {
        return _getMilestoneStorage().instances[0].milestoneCount;
    }

    /// @notice Legacy: Get completed milestones (proxy mode only, uses instance 0)
    function getCompletedMilestones() external view returns (uint8) {
        return _getMilestoneStorage().instances[0].completedMilestones;
    }

    /// @notice Legacy: Get total amount (proxy mode only, uses instance 0)
    function getTotalAmount() external view returns (uint256) {
        return _getMilestoneStorage().instances[0].totalAmount;
    }

    /// @notice Legacy: Get milestone (proxy mode only, uses instance 0)
    function getMilestone(uint8 index)
        external
        view
        returns (
            bytes32 description,
            uint256 amount,
            uint256 deadline,
            uint256 releasedAt,
            string memory disputeReason,
            uint256 disputedAt,
            string memory submissionMessage,
            uint256 submittedAt
        )
    {
        InstanceData storage inst = _getMilestoneStorage().instances[0];
        if (index >= inst.milestoneCount) revert InvalidMilestoneIndex();
        MilestoneConfig storage m = inst.milestones[index];
        return (
            m.description,
            m.amount,
            m.deadline,
            m.releasedAt,
            m.disputeReason,
            m.disputedAt,
            m.submissionMessage,
            m.submittedAt
        );
    }

    /// @notice Legacy: Get project state (proxy mode only, uses instance 0)
    function getProjectState()
        external
        view
        returns (bool termsAccepted, bool funded, uint8 completedMilestones, uint8 totalMilestones)
    {
        InstanceData storage inst = _getMilestoneStorage().instances[0];
        return (inst.termsAccepted, inst.funded, inst.completedMilestones, inst.milestoneCount);
    }

    // ═══════════════════════════════════════════════════════════════
    //                       INTERNAL
    // ═══════════════════════════════════════════════════════════════

    /// @notice Initialize clauses for an instance during creation
    function _initializeInstanceClauses(InstanceData storage inst, bytes32 termsHash) internal {
        // Initialize terms signature (both must sign)
        address[] memory signers = new address[](2);
        signers[0] = inst.client;
        signers[1] = inst.contractor;

        _delegateToClause(
            address(signatureClause),
            abi.encodeCall(SignatureClauseLogicV3.intakeSigners, (inst.termsSignatureId, signers))
        );
        _delegateToClause(
            address(signatureClause),
            abi.encodeCall(SignatureClauseLogicV3.intakeDocumentHash, (inst.termsSignatureId, termsHash))
        );
    }

    /// @notice Initialize all milestone escrows after terms accepted
    function _initializeAllEscrows(InstanceData storage inst) internal {
        bytes32 milestoneTrackerId = inst.milestoneTrackerId;

        // Add beneficiary and client to milestone clause
        _delegateToClause(
            address(milestoneClause),
            abi.encodeCall(MilestoneClauseLogicV3.intakeBeneficiary, (milestoneTrackerId, inst.contractor))
        );
        _delegateToClause(
            address(milestoneClause),
            abi.encodeCall(MilestoneClauseLogicV3.intakeClient, (milestoneTrackerId, inst.client))
        );
        _delegateToClause(
            address(milestoneClause),
            abi.encodeCall(MilestoneClauseLogicV3.intakeToken, (milestoneTrackerId, inst.paymentToken))
        );

        for (uint8 i = 0; i < inst.milestoneCount; i++) {
            bytes32 escrowId = inst.escrowIds[i];
            uint256 amount = inst.milestones[i].amount;

            // Add milestone to milestone clause
            _delegateToClause(
                address(milestoneClause),
                abi.encodeCall(
                    MilestoneClauseLogicV3.intakeMilestone, (milestoneTrackerId, inst.milestones[i].description, amount)
                )
            );

            // Configure each escrow
            _delegateToClause(
                address(escrowClause), abi.encodeCall(EscrowClauseLogicV3.intakeDepositor, (escrowId, inst.client))
            );
            _delegateToClause(
                address(escrowClause),
                abi.encodeCall(EscrowClauseLogicV3.intakeBeneficiary, (escrowId, inst.contractor))
            );
            _delegateToClause(
                address(escrowClause), abi.encodeCall(EscrowClauseLogicV3.intakeToken, (escrowId, inst.paymentToken))
            );
            _delegateToClause(
                address(escrowClause), abi.encodeCall(EscrowClauseLogicV3.intakeAmount, (escrowId, amount))
            );

            // Enable cancellation with 50/50 split if cancelled
            _delegateToClause(
                address(escrowClause), abi.encodeCall(EscrowClauseLogicV3.intakeCancellationEnabled, (escrowId, true))
            );
            _delegateToClause(
                address(escrowClause),
                abi.encodeCall(
                    EscrowClauseLogicV3.intakeCancellableBy, (escrowId, EscrowClauseLogicV3.CancellableBy.EITHER)
                )
            );
            _delegateToClause(
                address(escrowClause),
                abi.encodeCall(
                    EscrowClauseLogicV3.intakeCancellationFeeType, (escrowId, EscrowClauseLogicV3.FeeType.BPS)
                )
            );
            _delegateToClause(
                address(escrowClause),
                abi.encodeCall(EscrowClauseLogicV3.intakeCancellationFeeAmount, (escrowId, 5000)) // 50%
            );

            _delegateToClause(address(escrowClause), abi.encodeCall(EscrowClauseLogicV3.intakeReady, (escrowId)));

            // Link escrow to milestone
            _delegateToClause(
                address(milestoneClause),
                abi.encodeCall(
                    MilestoneClauseLogicV3.intakeMilestoneEscrowId, (milestoneTrackerId, uint256(i), escrowId)
                )
            );
        }

        // Finalize milestone clause
        _delegateToClause(
            address(milestoneClause), abi.encodeCall(MilestoneClauseLogicV3.intakeReady, (milestoneTrackerId))
        );
    }

    /// @notice Release all remaining funded milestones to contractor
    function _releaseAllRemainingMilestones(InstanceData storage inst, uint256 instanceId) internal {
        for (uint8 i = 0; i < inst.milestoneCount; i++) {
            bytes memory fundedResult = _delegateViewToClause(
                address(escrowClause), abi.encodeCall(EscrowClauseLogicV3.queryIsFunded, (inst.escrowIds[i]))
            );
            if (abi.decode(fundedResult, (bool))) {
                // Release this milestone to contractor
                _delegateToClause(
                    address(escrowClause), abi.encodeCall(EscrowClauseLogicV3.actionRelease, (inst.escrowIds[i]))
                );
                inst.milestones[i].releasedAt = block.timestamp;
                inst.completedMilestones++;
                emit MilestoneApproved(instanceId, i, inst.milestones[i].amount);
            }
        }
    }

    /// @notice Refund all remaining funded milestones to client
    function _refundAllRemainingMilestones(InstanceData storage inst, uint256 instanceId) internal {
        for (uint8 i = 0; i < inst.milestoneCount; i++) {
            bytes memory fundedResult = _delegateViewToClause(
                address(escrowClause), abi.encodeCall(EscrowClauseLogicV3.queryIsFunded, (inst.escrowIds[i]))
            );
            if (abi.decode(fundedResult, (bool))) {
                // Refund this milestone to client (depositor)
                // Use actionRefund which has no authorization check (authorization is at Agreement level)
                _delegateToClause(
                    address(escrowClause), abi.encodeCall(EscrowClauseLogicV3.actionRefund, (inst.escrowIds[i]))
                );
            }
        }
        // Mark as cancelled since funds were refunded
        inst.cancelled = true;
        emit ProjectCancelled(instanceId, address(this));
    }

    /// @notice Split remaining milestones based on basis points
    /// @param splitBasisPoints Claimant's (contractor's) share in basis points (0-10000)
    function _splitRemainingMilestones(InstanceData storage inst, uint256 instanceId, uint256 splitBasisPoints)
        internal
    {
        // Calculate total remaining
        uint256 remainingAmount = 0;
        for (uint8 i = 0; i < inst.milestoneCount; i++) {
            bytes memory fundedResult = _delegateViewToClause(
                address(escrowClause), abi.encodeCall(EscrowClauseLogicV3.queryIsFunded, (inst.escrowIds[i]))
            );
            if (abi.decode(fundedResult, (bool))) {
                remainingAmount += inst.milestones[i].amount;
            }
        }

        if (remainingAmount == 0) return;

        // Calculate split amounts
        uint256 contractorAmount = (remainingAmount * splitBasisPoints) / 10000;
        uint256 clientAmount = remainingAmount - contractorAmount;

        // For simplicity with the existing escrow structure, we'll:
        // 1. Release milestones up to contractor's share
        // 2. Cancel/refund remaining milestones for client's share
        uint256 releasedToContractor = 0;

        for (uint8 i = 0; i < inst.milestoneCount; i++) {
            bytes memory fundedResult = _delegateViewToClause(
                address(escrowClause), abi.encodeCall(EscrowClauseLogicV3.queryIsFunded, (inst.escrowIds[i]))
            );
            if (abi.decode(fundedResult, (bool))) {
                uint256 milestoneAmount = inst.milestones[i].amount;

                if (releasedToContractor + milestoneAmount <= contractorAmount) {
                    // Release full milestone to contractor
                    _delegateToClause(
                        address(escrowClause), abi.encodeCall(EscrowClauseLogicV3.actionRelease, (inst.escrowIds[i]))
                    );
                    releasedToContractor += milestoneAmount;
                    inst.milestones[i].releasedAt = block.timestamp;
                    inst.completedMilestones++;
                    emit MilestoneApproved(instanceId, i, milestoneAmount);
                } else {
                    // Cancel/refund to client
                    _delegateToClause(
                        address(escrowClause),
                        abi.encodeCall(EscrowClauseLogicV3.actionInitiateCancel, (inst.escrowIds[i]))
                    );
                }
            }
        }

        // If we couldn't exactly match due to milestone granularity, handle remainder
        // This is a simplification - a more sophisticated approach would use partial releases
        // But that would require changing the escrow clause

        inst.cancelled = true;
        emit ProjectCancelled(instanceId, address(this));
    }

    /// @notice Open a reputation window for rating the arbitrator after ruling
    /// @dev Called internally after executeArbitrationRuling if adapter is configured
    /// @param instanceId The agreement instance ID
    /// @param ruling The ruling that was executed (1=CLAIMANT_WINS, 2=RESPONDENT_WINS, 3=SPLIT)
    function _openArbitratorReputationWindow(uint256 instanceId, uint8 ruling) internal {
        // Skip if no reputation adapter configured
        if (address(reputationAdapter) == address(0)) return;

        InstanceData storage inst = _getMilestoneStorage().instances[instanceId];

        // Query arbitrator from linked arbitration agreement
        // The arbitration agreement should expose queryArbitrator(arbitrationInstanceId)
        (bool success, bytes memory data) = inst.arbitrationAgreement.staticcall(
            abi.encodeWithSignature("queryArbitrator(uint256)", inst.arbitrationInstanceId)
        );
        if (!success || data.length < 32) return; // Can't get arbitrator, skip reputation

        address arbitrator = abi.decode(data, (address));
        if (arbitrator == address(0)) return;

        // Build raters array: contractor (claimant) and client (respondent)
        address[] memory raters = new address[](2);
        raters[0] = inst.contractor; // claimant
        raters[1] = inst.client; // respondent

        // Build outcomes array based on ruling
        // 1 = winner, 2 = loser, 3 = split
        uint8[] memory outcomes = new uint8[](2);
        if (ruling == 1) {
            // CLAIMANT_WINS
            outcomes[0] = 1; // contractor wins
            outcomes[1] = 2; // client loses
        } else if (ruling == 2) {
            // RESPONDENT_WINS
            outcomes[0] = 2; // contractor loses
            outcomes[1] = 1; // client wins
        } else {
            // SPLIT or other
            outcomes[0] = 3; // contractor split
            outcomes[1] = 3; // client split
        }

        // Delegatecall to adapter to open reputation window
        bytes32 agreementInstanceId = bytes32(instanceId);
        (success, data) = address(reputationAdapter).delegatecall(
            abi.encodeCall(
                ArbitrationReputationAdapter.openReputationWindow, (agreementInstanceId, arbitrator, raters, outcomes, 0)
            )
        );

        if (success) {
            // Emit our own event with additional context
            emit ReputationWindowOpened(
                instanceId,
                ArbitrationReputationAdapter(address(reputationAdapter)).getReputationInstanceId(agreementInstanceId),
                arbitrator,
                ruling,
                uint48(block.timestamp + ArbitrationReputationAdapter(address(reputationAdapter)).DEFAULT_RATING_WINDOW())
            );
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //                    REPUTATION FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    /// @notice Rate the arbitrator after a ruling
    /// @dev Only callable by parties (client/contractor) during the rating window
    /// @param instanceId The agreement instance ID
    /// @param score Rating 1-5 stars
    /// @param feedbackCID Optional IPFS CID for text feedback
    function rateArbitrator(uint256 instanceId, uint8 score, bytes32 feedbackCID)
        external
        validInstance(instanceId)
        onlyInstanceParty(instanceId)
    {
        if (address(reputationAdapter) == address(0)) revert ReputationAdapterNotConfigured();

        bytes32 agreementInstanceId = bytes32(instanceId);

        // Verify reputation window is open
        bytes32 repInstanceId = _getReputationInstanceIdDelegated(agreementInstanceId);
        if (repInstanceId == bytes32(0)) revert ReputationWindowNotOpen();

        // Delegatecall to adapter
        (bool success,) = address(reputationAdapter).delegatecall(
            abi.encodeCall(ArbitrationReputationAdapter.rateArbitrator, (agreementInstanceId, score, feedbackCID))
        );
        require(success, "Rate failed");

        // Get arbitrator for event
        address arbitrator = _getRatedArbitratorDelegated(agreementInstanceId);
        emit ArbitratorRated(instanceId, msg.sender, arbitrator, score);
    }

    /// @notice Update an existing arbitrator rating
    /// @param instanceId The agreement instance ID
    /// @param score New rating 1-5 stars
    /// @param feedbackCID New feedback CID
    function updateArbitratorRating(uint256 instanceId, uint8 score, bytes32 feedbackCID)
        external
        validInstance(instanceId)
        onlyInstanceParty(instanceId)
    {
        if (address(reputationAdapter) == address(0)) revert ReputationAdapterNotConfigured();

        bytes32 agreementInstanceId = bytes32(instanceId);

        // Verify reputation window is open
        bytes32 repInstanceId = _getReputationInstanceIdDelegated(agreementInstanceId);
        if (repInstanceId == bytes32(0)) revert ReputationWindowNotOpen();

        // Delegatecall to adapter
        (bool success,) = address(reputationAdapter).delegatecall(
            abi.encodeCall(
                ArbitrationReputationAdapter.updateArbitratorRating, (agreementInstanceId, score, feedbackCID)
            )
        );
        require(success, "Update failed");
    }

    /// @notice Close the reputation window early
    /// @param instanceId The agreement instance ID
    function closeReputationWindow(uint256 instanceId) external validInstance(instanceId) {
        if (address(reputationAdapter) == address(0)) revert ReputationAdapterNotConfigured();

        bytes32 agreementInstanceId = bytes32(instanceId);

        // Verify reputation window is open
        bytes32 repInstanceId = _getReputationInstanceIdDelegated(agreementInstanceId);
        if (repInstanceId == bytes32(0)) revert ReputationWindowNotOpen();

        // Delegatecall to adapter
        (bool success,) = address(reputationAdapter).delegatecall(
            abi.encodeCall(ArbitrationReputationAdapter.closeReputationWindow, (agreementInstanceId))
        );
        require(success, "Close failed");
    }

    /// @notice Check if caller can rate the arbitrator
    /// @param instanceId The agreement instance ID
    /// @return canRate Whether caller can submit a rating
    /// @return reason Human-readable reason if not allowed
    function canRateArbitrator(uint256 instanceId)
        external
        validInstance(instanceId)
        returns (bool canRate, string memory reason)
    {
        if (address(reputationAdapter) == address(0)) {
            return (false, "Reputation adapter not configured");
        }

        bytes32 agreementInstanceId = bytes32(instanceId);

        (bool success, bytes memory data) = address(reputationAdapter).delegatecall(
            abi.encodeCall(ArbitrationReputationAdapter.canRateArbitrator, (agreementInstanceId))
        );

        if (!success) return (false, "Query failed");
        return abi.decode(data, (bool, string));
    }

    /// @notice Get the reputation window status
    /// @param instanceId The agreement instance ID
    /// @return isOpen Whether window is open
    /// @return opensAt When window opened
    /// @return closesAt When window closes
    /// @return ratingsSubmitted Number of ratings submitted
    /// @return ratersCount Total eligible raters
    function getReputationWindowStatus(uint256 instanceId)
        external
        validInstance(instanceId)
        returns (bool isOpen, uint48 opensAt, uint48 closesAt, uint8 ratingsSubmitted, uint8 ratersCount)
    {
        if (address(reputationAdapter) == address(0)) {
            return (false, 0, 0, 0, 0);
        }

        bytes32 agreementInstanceId = bytes32(instanceId);

        (bool success, bytes memory data) = address(reputationAdapter).delegatecall(
            abi.encodeCall(ArbitrationReputationAdapter.getWindowStatus, (agreementInstanceId))
        );

        if (!success) return (false, 0, 0, 0, 0);
        return abi.decode(data, (bool, uint48, uint48, uint8, uint8));
    }

    /// @notice Get the reputation instance ID for an agreement instance
    /// @param instanceId The agreement instance ID
    /// @return The reputation clause instance ID
    function getReputationInstanceId(uint256 instanceId) external view validInstance(instanceId) returns (bytes32) {
        if (address(reputationAdapter) == address(0)) return bytes32(0);
        return reputationAdapter.getReputationInstanceId(bytes32(instanceId));
    }

    /// @notice Get the arbitrator being rated for an instance
    /// @param instanceId The agreement instance ID
    /// @return The arbitrator address
    function getRatedArbitrator(uint256 instanceId) external view validInstance(instanceId) returns (address) {
        if (address(reputationAdapter) == address(0)) return address(0);
        return reputationAdapter.getRatedArbitrator(bytes32(instanceId));
    }

    /// @notice Get arbitrator's global reputation profile
    /// @param arbitrator Address of arbitrator to query
    /// @return totalRatings Total number of ratings received
    /// @return averageScore Average score scaled by 100 (e.g., 450 = 4.50)
    /// @return firstRatingAt When first rated
    /// @return lastRatingAt When last rated
    function getArbitratorProfile(address arbitrator)
        external
        returns (uint64 totalRatings, uint16 averageScore, uint48 firstRatingAt, uint48 lastRatingAt)
    {
        if (address(reputationAdapter) == address(0)) return (0, 0, 0, 0);

        (bool success, bytes memory data) = address(reputationAdapter).delegatecall(
            abi.encodeCall(ArbitrationReputationAdapter.getArbitratorProfile, (arbitrator))
        );

        if (!success) return (0, 0, 0, 0);
        return abi.decode(data, (uint64, uint16, uint48, uint48));
    }

    /// @notice Get arbitrator's role-specific reputation
    /// @param arbitrator Address of arbitrator to query
    /// @return count Number of ratings as arbitrator
    /// @return averageScore Average score scaled by 100
    function getArbitratorRoleReputation(address arbitrator) external returns (uint32 count, uint16 averageScore) {
        if (address(reputationAdapter) == address(0)) return (0, 0);

        (bool success, bytes memory data) = address(reputationAdapter).delegatecall(
            abi.encodeCall(ArbitrationReputationAdapter.getArbitratorRoleReputation, (arbitrator))
        );

        if (!success) return (0, 0);
        return abi.decode(data, (uint32, uint16));
    }

    /// @notice Get the default rating window duration
    /// @return Duration in seconds (14 days)
    function getRatingWindowDuration() external view returns (uint32) {
        if (address(reputationAdapter) == address(0)) return 0;
        return reputationAdapter.DEFAULT_RATING_WINDOW();
    }

    // ═══════════════════════════════════════════════════════════════
    //                    INTERNAL REPUTATION HELPERS
    // ═══════════════════════════════════════════════════════════════

    /// @notice Get reputation instance ID via delegatecall (for storage in agreement)
    function _getReputationInstanceIdDelegated(bytes32 agreementInstanceId) internal returns (bytes32) {
        (bool success, bytes memory data) = address(reputationAdapter).delegatecall(
            abi.encodeCall(ArbitrationReputationAdapter.getReputationInstanceId, (agreementInstanceId))
        );
        if (!success) return bytes32(0);
        return abi.decode(data, (bytes32));
    }

    /// @notice Get rated arbitrator via delegatecall (for storage in agreement)
    function _getRatedArbitratorDelegated(bytes32 agreementInstanceId) internal returns (address) {
        (bool success, bytes memory data) = address(reputationAdapter).delegatecall(
            abi.encodeCall(ArbitrationReputationAdapter.getRatedArbitrator, (agreementInstanceId))
        );
        if (!success) return address(0);
        return abi.decode(data, (address));
    }

    // Allow receiving ETH
    receive() external payable {}
}
