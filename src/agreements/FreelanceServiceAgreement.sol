// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AgreementBaseV3} from "../base/AgreementBaseV3.sol";
import {SignatureClauseLogicV3} from "../clauses/attestation/SignatureClauseLogicV3.sol";
import {EscrowClauseLogicV3} from "../clauses/financial/EscrowClauseLogicV3.sol";
import {DeclarativeClauseLogicV3} from "../clauses/content/DeclarativeClauseLogicV3.sol";

/// @title FreelanceServiceAgreement
/// @notice Simple escrow-backed agreement for one-off freelance services
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
///      - More expensive: ~50k gas for proxy deployment
///      - Identified by: proxy address only
///
///      REAL-WORLD USE CASE:
///      A client hires a freelancer for a logo design, website, or consulting session.
///      - Client deposits payment upfront into escrow
///      - Freelancer delivers work
///      - Client approves (signs) to release payment
///      - If dispute: cancellation policy splits funds fairly
///
///      CLAUSES COMPOSED:
///      - SignatureClauseLogicV3: Both parties sign to agree on terms
///      - EscrowClauseLogicV3: Hold funds until work approved
///      - DeclarativeClauseLogicV3: Store scope of work reference
contract FreelanceServiceAgreement is AgreementBaseV3 {
    // ═══════════════════════════════════════════════════════════════
    //                        IMMUTABLES
    // ═══════════════════════════════════════════════════════════════

    /// @notice Clause logic implementations (deployed once, shared by all)
    SignatureClauseLogicV3 public immutable signatureClause;
    EscrowClauseLogicV3 public immutable escrowClause;
    DeclarativeClauseLogicV3 public immutable declarativeClause;

    // ═══════════════════════════════════════════════════════════════
    //                    INSTANCE DATA STRUCT
    // ═══════════════════════════════════════════════════════════════

    /// @notice Per-instance agreement data
    struct InstanceData {
        // Instance metadata
        uint256 instanceNumber; // Sequential: 1, 2, 3...
        uint256 parentInstanceId; // 0 if original, else points to countered agreement
        address creator; // Who created this instance
        uint256 createdAt; // Block timestamp
        // Clause instance IDs
        bytes32 termsSignatureId; // Signature instance for initial terms
        bytes32 deliveryApprovalId; // Signature instance for delivery approval
        bytes32 escrowId; // Escrow instance
        bytes32 scopeId; // Declarative clause for scope of work
        // Agreement-specific data
        address client;
        address freelancer;
        bytes32 scopeHash; // IPFS CID or hash of scope document
        uint256 paymentAmount;
        address paymentToken; // address(0) for ETH
        uint256 cancellationFeeBps; // Kill fee in basis points
        bytes32 documentCID; // IPFS CID of the agreement document
        // State flags
        bool termsAccepted; // Both parties signed terms
        bool workDelivered; // Freelancer marked work as delivered
        bool clientApproved; // Client approved the delivery
        bool cancelled; // Agreement was cancelled
    }

    // ═══════════════════════════════════════════════════════════════
    //                    AGREEMENT STORAGE
    // ═══════════════════════════════════════════════════════════════

    /// @custom:storage-location erc7201:papre.agreement.freelanceservice.storage
    struct FreelanceStorage {
        // Instance management (Simple mode)
        uint256 instanceCounter;
        mapping(uint256 => InstanceData) instances;
        mapping(address => uint256[]) userInstances;
        // Proxy mode storage (Technical mode) - uses instanceId = 0
        // When deployed as proxy, only instance 0 is used
        bool isProxyMode;
    }

    // keccak256(abi.encode(uint256(keccak256("papre.agreement.freelanceservice.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant FREELANCE_STORAGE_SLOT =
        0x2a1b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a00;

    function _getFreelanceStorage() internal pure returns (FreelanceStorage storage $) {
        assembly {
            $.slot := FREELANCE_STORAGE_SLOT
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //                          ERRORS
    // ═══════════════════════════════════════════════════════════════

    error OnlyClient();
    error OnlyFreelancer();
    error OnlyClientOrFreelancer();
    error TermsNotAccepted();
    error NotFunded();
    error WorkNotDelivered();
    error AlreadyApproved();
    error AlreadyDelivered();
    error AlreadyCancelled();
    error InstanceNotFound();
    error ProxyModeOnly();
    error SingletonModeOnly();

    // ═══════════════════════════════════════════════════════════════
    //                          EVENTS
    // ═══════════════════════════════════════════════════════════════

    event InstanceCreated(
        uint256 indexed instanceId, address indexed client, address indexed freelancer, uint256 parentInstanceId
    );
    event AgreementConfigured(
        uint256 indexed instanceId,
        address indexed client,
        address indexed freelancer,
        bytes32 scopeHash,
        uint256 paymentAmount,
        address paymentToken
    );
    event TermsAccepted(uint256 indexed instanceId, address indexed client, address indexed freelancer);
    event PaymentDeposited(uint256 indexed instanceId, address indexed client, uint256 amount);
    event WorkDelivered(uint256 indexed instanceId, address indexed freelancer, bytes32 deliverableHash);
    event DeliveryApproved(uint256 indexed instanceId, address indexed client);
    event PaymentReleased(uint256 indexed instanceId, address indexed freelancer, uint256 amount);
    event AgreementCancelled(uint256 indexed instanceId, address indexed cancelledBy);

    // ═══════════════════════════════════════════════════════════════
    //                        MODIFIERS
    // ═══════════════════════════════════════════════════════════════

    modifier validInstance(uint256 instanceId) {
        if (_getFreelanceStorage().instances[instanceId].creator == address(0)) {
            revert InstanceNotFound();
        }
        _;
    }

    modifier onlyInstanceClient(uint256 instanceId) {
        if (msg.sender != _getFreelanceStorage().instances[instanceId].client) {
            revert OnlyClient();
        }
        _;
    }

    modifier onlyInstanceFreelancer(uint256 instanceId) {
        if (msg.sender != _getFreelanceStorage().instances[instanceId].freelancer) {
            revert OnlyFreelancer();
        }
        _;
    }

    modifier onlyInstanceParty(uint256 instanceId) {
        InstanceData storage inst = _getFreelanceStorage().instances[instanceId];
        if (msg.sender != inst.client && msg.sender != inst.freelancer) {
            revert OnlyClientOrFreelancer();
        }
        _;
    }

    modifier notCancelled(uint256 instanceId) {
        if (_getFreelanceStorage().instances[instanceId].cancelled) {
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
    /// @param _declarativeClause DeclarativeClauseLogicV3 address
    constructor(address _signatureClause, address _escrowClause, address _declarativeClause) {
        signatureClause = SignatureClauseLogicV3(_signatureClause);
        escrowClause = EscrowClauseLogicV3(_escrowClause);
        declarativeClause = DeclarativeClauseLogicV3(_declarativeClause);
        // Note: We don't call _disableInitializers() here because
        // the singleton needs to remain usable for createInstance()
    }

    // ═══════════════════════════════════════════════════════════════
    //                    SIMPLE MODE: CREATE INSTANCE
    // ═══════════════════════════════════════════════════════════════

    /// @notice Create a new agreement instance (Simple mode)
    /// @param _client Address of the client (pays for work)
    /// @param _freelancer Address of the freelancer (delivers work)
    /// @param _scopeHash Hash/CID of the scope of work document
    /// @param _paymentAmount Payment amount in token units
    /// @param _paymentToken Token address (address(0) for ETH)
    /// @param _cancellationFeeBps Kill fee in basis points if cancelled (e.g., 1000 = 10%)
    /// @param _parentInstanceId Instance ID being countered (0 for new agreement)
    /// @param _documentCID IPFS CID of the agreement document (bytes32)
    /// @return instanceId The created instance ID
    function createInstance(
        address _client,
        address _freelancer,
        bytes32 _scopeHash,
        uint256 _paymentAmount,
        address _paymentToken,
        uint256 _cancellationFeeBps,
        uint256 _parentInstanceId,
        bytes32 _documentCID
    ) external returns (uint256 instanceId) {
        FreelanceStorage storage $ = _getFreelanceStorage();

        // Cannot use createInstance on a proxy
        if ($.isProxyMode) revert SingletonModeOnly();

        // Increment counter and create instance
        $.instanceCounter++;
        instanceId = $.instanceCounter;

        InstanceData storage inst = $.instances[instanceId];
        inst.instanceNumber = instanceId;
        inst.parentInstanceId = _parentInstanceId;
        inst.creator = msg.sender;
        inst.createdAt = block.timestamp;
        inst.client = _client;
        inst.freelancer = _freelancer;
        inst.scopeHash = _scopeHash;
        inst.paymentAmount = _paymentAmount;
        inst.paymentToken = _paymentToken;
        inst.cancellationFeeBps = _cancellationFeeBps;
        inst.documentCID = _documentCID;

        // Generate unique clause instance IDs
        inst.termsSignatureId = keccak256(abi.encode(address(this), instanceId, "terms"));
        inst.deliveryApprovalId = keccak256(abi.encode(address(this), instanceId, "approval"));
        inst.escrowId = keccak256(abi.encode(address(this), instanceId, "escrow"));
        inst.scopeId = keccak256(abi.encode(address(this), instanceId, "scope"));

        // Track instances by user
        $.userInstances[_client].push(instanceId);
        if (_freelancer != _client) {
            $.userInstances[_freelancer].push(instanceId);
        }

        // Initialize clauses
        _initializeClauses(inst);

        emit InstanceCreated(instanceId, _client, _freelancer, _parentInstanceId);
        emit AgreementConfigured(instanceId, _client, _freelancer, _scopeHash, _paymentAmount, _paymentToken);

        return instanceId;
    }

    // ═══════════════════════════════════════════════════════════════
    //                    TECHNICAL MODE: INITIALIZE (PROXY)
    // ═══════════════════════════════════════════════════════════════

    /// @notice Initialize a proxy-deployed agreement (Technical mode)
    /// @dev Called once when factory clones this contract
    function initialize(
        address _client,
        address _freelancer,
        bytes32 _scopeHash,
        uint256 _paymentAmount,
        address _paymentToken,
        uint256 _cancellationFeeBps,
        bytes32 _documentCID
    ) external initializer {
        __AgreementBase_init(_client);

        FreelanceStorage storage $ = _getFreelanceStorage();
        $.isProxyMode = true;

        // Use instance 0 for proxy mode
        uint256 instanceId = 0;
        InstanceData storage inst = $.instances[instanceId];

        inst.instanceNumber = 0;
        inst.parentInstanceId = 0;
        inst.creator = _client;
        inst.createdAt = block.timestamp;
        inst.client = _client;
        inst.freelancer = _freelancer;
        inst.scopeHash = _scopeHash;
        inst.paymentAmount = _paymentAmount;
        inst.paymentToken = _paymentToken;
        inst.cancellationFeeBps = _cancellationFeeBps;
        inst.documentCID = _documentCID;

        // Generate unique clause instance IDs
        inst.termsSignatureId = keccak256(abi.encode(address(this), "terms", _scopeHash));
        inst.deliveryApprovalId = keccak256(abi.encode(address(this), "approval", _scopeHash));
        inst.escrowId = keccak256(abi.encode(address(this), "escrow", _scopeHash));
        inst.scopeId = keccak256(abi.encode(address(this), "scope", _scopeHash));

        // Add parties
        _addParty(_freelancer);

        // Initialize clauses
        _initializeClauses(inst);

        emit AgreementConfigured(0, _client, _freelancer, _scopeHash, _paymentAmount, _paymentToken);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    INTERNAL: CLAUSE INITIALIZATION
    // ═══════════════════════════════════════════════════════════════

    function _initializeClauses(InstanceData storage inst) internal {
        // Initialize terms signature clause (both parties must sign)
        address[] memory signers = new address[](2);
        signers[0] = inst.client;
        signers[1] = inst.freelancer;

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
            abi.encodeCall(EscrowClauseLogicV3.intakeBeneficiary, (inst.escrowId, inst.freelancer))
        );
        _delegateToClause(
            address(escrowClause), abi.encodeCall(EscrowClauseLogicV3.intakeToken, (inst.escrowId, inst.paymentToken))
        );
        _delegateToClause(
            address(escrowClause), abi.encodeCall(EscrowClauseLogicV3.intakeAmount, (inst.escrowId, inst.paymentAmount))
        );

        // Configure cancellation policy
        _delegateToClause(
            address(escrowClause), abi.encodeCall(EscrowClauseLogicV3.intakeCancellationEnabled, (inst.escrowId, true))
        );
        _delegateToClause(
            address(escrowClause),
            abi.encodeCall(
                EscrowClauseLogicV3.intakeCancellableBy, (inst.escrowId, EscrowClauseLogicV3.CancellableBy.EITHER)
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
            abi.encodeCall(EscrowClauseLogicV3.intakeCancellationFeeAmount, (inst.escrowId, inst.cancellationFeeBps))
        );

        // Finalize escrow configuration
        _delegateToClause(address(escrowClause), abi.encodeCall(EscrowClauseLogicV3.intakeReady, (inst.escrowId)));

        // Initialize scope declarative clause
        _delegateToClause(
            address(declarativeClause),
            abi.encodeCall(DeclarativeClauseLogicV3.intakeContentHash, (inst.scopeId, inst.scopeHash))
        );
    }

    // ═══════════════════════════════════════════════════════════════
    //                    PHASE 1: SIGN TERMS
    // ═══════════════════════════════════════════════════════════════

    /// @notice Sign the terms of the agreement
    /// @param instanceId The instance to sign
    /// @param signature Cryptographic signature of the scope hash
    function signTerms(uint256 instanceId, bytes calldata signature)
        external
        validInstance(instanceId)
        onlyInstanceParty(instanceId)
        notCancelled(instanceId)
    {
        InstanceData storage inst = _getFreelanceStorage().instances[instanceId];

        _delegateToClause(
            address(signatureClause),
            abi.encodeCall(SignatureClauseLogicV3.actionSign, (inst.termsSignatureId, signature))
        );

        // Check if both have signed
        bytes memory statusResult = _delegateViewToClause(
            address(signatureClause), abi.encodeCall(SignatureClauseLogicV3.queryStatus, (inst.termsSignatureId))
        );
        uint16 status = abi.decode(statusResult, (uint16));

        if (status == 0x0004) {
            // COMPLETE
            inst.termsAccepted = true;
            emit TermsAccepted(instanceId, inst.client, inst.freelancer);
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //                    PHASE 2: DEPOSIT PAYMENT
    // ═══════════════════════════════════════════════════════════════

    /// @notice Client deposits payment into escrow
    /// @param instanceId The instance to deposit for
    function depositPayment(uint256 instanceId)
        external
        payable
        whenNotPaused
        validInstance(instanceId)
        onlyInstanceClient(instanceId)
        notCancelled(instanceId)
    {
        InstanceData storage inst = _getFreelanceStorage().instances[instanceId];

        if (!inst.termsAccepted) revert TermsNotAccepted();

        _delegateToClause(address(escrowClause), abi.encodeCall(EscrowClauseLogicV3.actionDeposit, (inst.escrowId)));

        emit PaymentDeposited(instanceId, inst.client, inst.paymentAmount);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    PHASE 3: DELIVER WORK
    // ═══════════════════════════════════════════════════════════════

    /// @notice Freelancer marks work as delivered
    /// @param instanceId The instance to mark delivered
    /// @param deliverableHash Hash/CID of the delivered work
    function markDelivered(uint256 instanceId, bytes32 deliverableHash)
        external
        validInstance(instanceId)
        onlyInstanceFreelancer(instanceId)
        notCancelled(instanceId)
    {
        InstanceData storage inst = _getFreelanceStorage().instances[instanceId];

        // Check escrow is funded
        bytes memory fundedResult = _delegateViewToClause(
            address(escrowClause), abi.encodeCall(EscrowClauseLogicV3.queryIsFunded, (inst.escrowId))
        );
        if (!abi.decode(fundedResult, (bool))) revert NotFunded();

        if (inst.workDelivered) revert AlreadyDelivered();

        inst.workDelivered = true;

        // Initialize delivery approval signature (client only needs to sign)
        address[] memory approver = new address[](1);
        approver[0] = inst.client;

        _delegateToClause(
            address(signatureClause),
            abi.encodeCall(SignatureClauseLogicV3.intakeSigners, (inst.deliveryApprovalId, approver))
        );
        _delegateToClause(
            address(signatureClause),
            abi.encodeCall(SignatureClauseLogicV3.intakeDocumentHash, (inst.deliveryApprovalId, deliverableHash))
        );

        emit WorkDelivered(instanceId, inst.freelancer, deliverableHash);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    PHASE 4: APPROVE & RELEASE
    // ═══════════════════════════════════════════════════════════════

    /// @notice Client approves delivery and releases payment
    /// @param instanceId The instance to approve
    /// @param signature Client's signature approving the deliverable
    function approveAndRelease(uint256 instanceId, bytes calldata signature)
        external
        validInstance(instanceId)
        onlyInstanceClient(instanceId)
        notCancelled(instanceId)
    {
        InstanceData storage inst = _getFreelanceStorage().instances[instanceId];

        if (!inst.workDelivered) revert WorkNotDelivered();
        if (inst.clientApproved) revert AlreadyApproved();

        // Sign approval
        _delegateToClause(
            address(signatureClause),
            abi.encodeCall(SignatureClauseLogicV3.actionSign, (inst.deliveryApprovalId, signature))
        );

        inst.clientApproved = true;

        // Release escrow to freelancer
        _delegateToClause(address(escrowClause), abi.encodeCall(EscrowClauseLogicV3.actionRelease, (inst.escrowId)));

        emit DeliveryApproved(instanceId, inst.client);
        emit PaymentReleased(instanceId, inst.freelancer, inst.paymentAmount);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    CANCELLATION
    // ═══════════════════════════════════════════════════════════════

    /// @notice Cancel the agreement and split funds per cancellation policy
    /// @param instanceId The instance to cancel
    function cancel(uint256 instanceId)
        external
        validInstance(instanceId)
        onlyInstanceParty(instanceId)
        notCancelled(instanceId)
    {
        InstanceData storage inst = _getFreelanceStorage().instances[instanceId];

        inst.cancelled = true;

        _delegateToClause(
            address(escrowClause), abi.encodeCall(EscrowClauseLogicV3.actionInitiateCancel, (inst.escrowId))
        );

        emit AgreementCancelled(instanceId, msg.sender);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    /// @notice Get the total number of instances
    function getInstanceCount() external view returns (uint256) {
        return _getFreelanceStorage().instanceCounter;
    }

    /// @notice Get all instance IDs for a user
    function getUserInstances(address user) external view returns (uint256[] memory) {
        return _getFreelanceStorage().userInstances[user];
    }

    /// @notice Get instance data
    function getInstance(uint256 instanceId)
        external
        view
        returns (
            uint256 instanceNumber,
            uint256 parentInstanceId,
            address creator,
            uint256 createdAt,
            address client,
            address freelancer,
            bytes32 scopeHash,
            uint256 paymentAmount,
            address paymentToken
        )
    {
        InstanceData storage inst = _getFreelanceStorage().instances[instanceId];
        return (
            inst.instanceNumber,
            inst.parentInstanceId,
            inst.creator,
            inst.createdAt,
            inst.client,
            inst.freelancer,
            inst.scopeHash,
            inst.paymentAmount,
            inst.paymentToken
        );
    }

    /// @notice Get instance state
    function getInstanceState(uint256 instanceId)
        external
        view
        returns (bool termsAccepted, bool workDelivered, bool clientApproved, bool cancelled)
    {
        InstanceData storage inst = _getFreelanceStorage().instances[instanceId];
        return (inst.termsAccepted, inst.workDelivered, inst.clientApproved, inst.cancelled);
    }

    /// @notice Check if escrow is funded for an instance
    function isFunded(uint256 instanceId) external validInstance(instanceId) returns (bool) {
        InstanceData storage inst = _getFreelanceStorage().instances[instanceId];
        bytes memory result = _delegateViewToClause(
            address(escrowClause), abi.encodeCall(EscrowClauseLogicV3.queryIsFunded, (inst.escrowId))
        );
        return abi.decode(result, (bool));
    }

    /// @notice Check if payment has been released for an instance
    function isReleased(uint256 instanceId) external validInstance(instanceId) returns (bool) {
        InstanceData storage inst = _getFreelanceStorage().instances[instanceId];
        bytes memory result = _delegateViewToClause(
            address(escrowClause), abi.encodeCall(EscrowClauseLogicV3.queryIsReleased, (inst.escrowId))
        );
        return abi.decode(result, (bool));
    }

    /// @notice Get the document CID for an instance
    /// @param instanceId The instance ID
    /// @return The IPFS CID as bytes32
    function getDocumentCID(uint256 instanceId) external view returns (bytes32) {
        return _getFreelanceStorage().instances[instanceId].documentCID;
    }

    /// @notice Check if this is running in proxy mode
    function isProxyMode() external view returns (bool) {
        return _getFreelanceStorage().isProxyMode;
    }

    /// @notice Get clause instance IDs for an agreement instance
    function getClauseInstanceIds(uint256 instanceId)
        external
        view
        validInstance(instanceId)
        returns (bytes32 termsSignatureId, bytes32 deliveryApprovalId, bytes32 escrowId, bytes32 scopeId)
    {
        InstanceData storage inst = _getFreelanceStorage().instances[instanceId];
        return (inst.termsSignatureId, inst.deliveryApprovalId, inst.escrowId, inst.scopeId);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    LEGACY COMPATIBILITY (PROXY MODE)
    // ═══════════════════════════════════════════════════════════════

    /// @notice Legacy: Get client (proxy mode only, uses instance 0)
    function getClient() external view returns (address) {
        return _getFreelanceStorage().instances[0].client;
    }

    /// @notice Legacy: Get freelancer (proxy mode only, uses instance 0)
    function getFreelancer() external view returns (address) {
        return _getFreelanceStorage().instances[0].freelancer;
    }

    /// @notice Legacy: Get scope hash (proxy mode only, uses instance 0)
    function getScopeHash() external view returns (bytes32) {
        return _getFreelanceStorage().instances[0].scopeHash;
    }

    /// @notice Legacy: Get payment details (proxy mode only, uses instance 0)
    function getPaymentDetails() external view returns (uint256 amount, address token) {
        InstanceData storage inst = _getFreelanceStorage().instances[0];
        return (inst.paymentAmount, inst.paymentToken);
    }

    /// @notice Legacy: Get state (proxy mode only, uses instance 0)
    function getState()
        external
        view
        returns (bool termsAccepted, bool funded, bool workDelivered, bool clientApproved)
    {
        InstanceData storage inst = _getFreelanceStorage().instances[0];
        return (inst.termsAccepted, false, inst.workDelivered, inst.clientApproved);
    }

    // Allow receiving ETH for escrow deposits
    receive() external payable {}
}
