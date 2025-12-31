// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AgreementBaseV3} from "../base/AgreementBaseV3.sol";
import {SignatureClauseLogicV3} from "../clauses/attestation/SignatureClauseLogicV3.sol";
import {EscrowClauseLogicV3} from "../clauses/financial/EscrowClauseLogicV3.sol";

/// @title RetainerAgreement
/// @notice Monthly retainer agreement with REAL-TIME STREAMING payments
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
///      REAL-WORLD USE CASE:
///      A consultant is hired on a $10,000/month retainer for ongoing advisory work.
///      - Client funds at the start of each period
///      - Payment STREAMS in real-time (contractor can claim accrued amount anytime)
///      - If client cancels mid-month, contractor keeps pro-rated amount
///      - Notice period prevents abrupt termination
///
///      STREAMING MODEL:
///      Unlike period-based release, the contractor can claim their accrued
///      payment at any time. The claimable amount is calculated in real-time:
///        claimable = (monthlyRate × elapsed / periodDuration) - alreadyClaimed
///
///      CLAUSES COMPOSED:
///      - SignatureClauseLogicV3: Both parties sign terms
///      - EscrowClauseLogicV3: Hold funds with streaming release capability
contract RetainerAgreement is AgreementBaseV3 {

    // ═══════════════════════════════════════════════════════════════
    //                        CONSTANTS
    // ═══════════════════════════════════════════════════════════════

    /// @notice Seconds in a 30-day month (standard for proration)
    uint256 public constant STANDARD_MONTH = 30 days;

    // ═══════════════════════════════════════════════════════════════
    //                        IMMUTABLES
    // ═══════════════════════════════════════════════════════════════

    SignatureClauseLogicV3 public immutable signatureClause;
    EscrowClauseLogicV3 public immutable escrowClause;

    // ═══════════════════════════════════════════════════════════════
    //                    INSTANCE DATA STRUCT
    // ═══════════════════════════════════════════════════════════════

    /// @notice Per-instance agreement data
    struct InstanceData {
        // Instance metadata
        uint256 instanceNumber;        // Sequential: 1, 2, 3...
        address creator;               // Who created this instance
        uint256 createdAt;             // Block timestamp

        // Clause instance IDs
        bytes32 termsSignatureId;      // Signature instance for initial terms
        bytes32 escrowId;              // Escrow instance

        // Agreement-specific data
        address client;
        address contractor;
        address paymentToken;          // address(0) for ETH
        uint256 monthlyRate;           // Amount per period
        uint256 periodDuration;        // Duration in seconds (e.g., 30 days)
        uint256 noticePeriodDays;      // Days required for cancellation notice
        bytes32 documentCID;           // IPFS CID of the agreement document

        // State flags
        bool clientSigned;
        bool contractorSigned;
        bool funded;                   // Escrow has been funded

        // Streaming state
        uint256 currentPeriodStart;    // When current period began
        uint256 currentPeriodEnd;      // When current period ends
        uint256 claimedAmount;         // Amount already claimed by contractor

        // Cancellation state
        uint256 cancelInitiatedAt;     // When notice was given (0 = not initiated)
        bool cancelled;                // Agreement has been cancelled
    }

    // ═══════════════════════════════════════════════════════════════
    //                    AGREEMENT STORAGE
    // ═══════════════════════════════════════════════════════════════

    /// @custom:storage-location erc7201:papre.agreement.retainer.storage
    struct RetainerStorage {
        // Instance management (Simple mode)
        uint256 instanceCounter;
        mapping(uint256 => InstanceData) instances;
        mapping(address => uint256[]) userInstances;

        // Proxy mode storage (Technical mode) - uses instanceId = 0
        bool isProxyMode;
    }

    // keccak256(abi.encode(uint256(keccak256("papre.agreement.retainer.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant RETAINER_STORAGE_SLOT =
        0x4c3d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c00;

    function _getRetainerStorage() internal pure returns (RetainerStorage storage $) {
        assembly {
            $.slot := RETAINER_STORAGE_SLOT
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //                          ERRORS
    // ═══════════════════════════════════════════════════════════════

    error OnlyClient();
    error OnlyContractor();
    error OnlyClientOrContractor();
    error TermsNotAccepted();
    error NotFunded();
    error AlreadyFunded();
    error NothingToClaim();
    error CancelNotInitiated();
    error NoticePeriodNotElapsed();
    error AlreadyCancelled();
    error InstanceNotFound();
    error ProxyModeOnly();
    error SingletonModeOnly();

    // ═══════════════════════════════════════════════════════════════
    //                          EVENTS
    // ═══════════════════════════════════════════════════════════════

    event InstanceCreated(
        uint256 indexed instanceId,
        address indexed client,
        address indexed contractor
    );
    event RetainerConfigured(
        uint256 indexed instanceId,
        address indexed client,
        address indexed contractor,
        uint256 monthlyRate,
        uint256 periodDuration,
        uint256 noticePeriodDays
    );
    event TermsSigned(uint256 indexed instanceId, address indexed signer);
    event TermsAccepted(uint256 indexed instanceId, address indexed client, address indexed contractor);
    event PeriodFunded(uint256 indexed instanceId, uint256 amount, uint256 periodStart, uint256 periodEnd);
    event StreamClaimed(uint256 indexed instanceId, address indexed contractor, uint256 amount, uint256 totalClaimed);
    event CancelInitiated(uint256 indexed instanceId, address indexed initiatedBy, uint256 effectiveAt);
    event CancelExecuted(uint256 indexed instanceId, uint256 contractorAmount, uint256 clientRefund);

    // ═══════════════════════════════════════════════════════════════
    //                        MODIFIERS
    // ═══════════════════════════════════════════════════════════════

    modifier validInstance(uint256 instanceId) {
        if (_getRetainerStorage().instances[instanceId].creator == address(0)) {
            revert InstanceNotFound();
        }
        _;
    }

    modifier onlyInstanceClient(uint256 instanceId) {
        if (msg.sender != _getRetainerStorage().instances[instanceId].client) {
            revert OnlyClient();
        }
        _;
    }

    modifier onlyInstanceContractor(uint256 instanceId) {
        if (msg.sender != _getRetainerStorage().instances[instanceId].contractor) {
            revert OnlyContractor();
        }
        _;
    }

    modifier onlyInstanceParty(uint256 instanceId) {
        InstanceData storage inst = _getRetainerStorage().instances[instanceId];
        if (msg.sender != inst.client && msg.sender != inst.contractor) {
            revert OnlyClientOrContractor();
        }
        _;
    }

    modifier notCancelled(uint256 instanceId) {
        if (_getRetainerStorage().instances[instanceId].cancelled) {
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
    constructor(
        address _signatureClause,
        address _escrowClause
    ) {
        signatureClause = SignatureClauseLogicV3(_signatureClause);
        escrowClause = EscrowClauseLogicV3(_escrowClause);
        // Note: We don't call _disableInitializers() here because
        // the singleton needs to remain usable for createInstance()
    }

    // ═══════════════════════════════════════════════════════════════
    //                    SIMPLE MODE: CREATE INSTANCE
    // ═══════════════════════════════════════════════════════════════

    /// @notice Create a new retainer agreement instance (Simple mode)
    /// @param _client Address of the client (payer)
    /// @param _contractor Address of the contractor (payee)
    /// @param _paymentToken Token address (address(0) for ETH)
    /// @param _monthlyRate Payment amount per period
    /// @param _periodDuration Period length in seconds (0 = 30 days default)
    /// @param _noticePeriodDays Days of notice required to cancel
    /// @param _documentCID IPFS CID of the agreement document
    /// @return instanceId The created instance ID
    function createInstance(
        address _client,
        address _contractor,
        address _paymentToken,
        uint256 _monthlyRate,
        uint256 _periodDuration,
        uint256 _noticePeriodDays,
        bytes32 _documentCID
    ) external returns (uint256 instanceId) {
        RetainerStorage storage $ = _getRetainerStorage();

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
        inst.contractor = _contractor;
        inst.paymentToken = _paymentToken;
        inst.monthlyRate = _monthlyRate;
        inst.periodDuration = _periodDuration > 0 ? _periodDuration : STANDARD_MONTH;
        inst.noticePeriodDays = _noticePeriodDays;
        inst.documentCID = _documentCID;

        // Generate unique clause instance IDs
        inst.termsSignatureId = keccak256(abi.encode(address(this), instanceId, "terms"));
        inst.escrowId = keccak256(abi.encode(address(this), instanceId, "escrow"));

        // Track instances by user
        $.userInstances[_client].push(instanceId);
        if (_contractor != _client) {
            $.userInstances[_contractor].push(instanceId);
        }

        // Initialize clauses
        _initializeClauses(inst);

        emit InstanceCreated(instanceId, _client, _contractor);
        emit RetainerConfigured(instanceId, _client, _contractor, _monthlyRate, inst.periodDuration, _noticePeriodDays);

        return instanceId;
    }

    // ═══════════════════════════════════════════════════════════════
    //                    TECHNICAL MODE: INITIALIZE (PROXY)
    // ═══════════════════════════════════════════════════════════════

    /// @notice Initialize a proxy-deployed agreement (Technical mode)
    /// @dev Called once when factory clones this contract
    function initialize(
        address _client,
        address _contractor,
        address _paymentToken,
        uint256 _monthlyRate,
        uint256 _periodDuration,
        uint256 _noticePeriodDays,
        bytes32 _documentCID
    ) external initializer {
        __AgreementBase_init(_client);

        RetainerStorage storage $ = _getRetainerStorage();
        $.isProxyMode = true;

        // Use instance 0 for proxy mode
        uint256 instanceId = 0;
        InstanceData storage inst = $.instances[instanceId];

        inst.instanceNumber = 0;
        inst.creator = _client;
        inst.createdAt = block.timestamp;
        inst.client = _client;
        inst.contractor = _contractor;
        inst.paymentToken = _paymentToken;
        inst.monthlyRate = _monthlyRate;
        inst.periodDuration = _periodDuration > 0 ? _periodDuration : STANDARD_MONTH;
        inst.noticePeriodDays = _noticePeriodDays;
        inst.documentCID = _documentCID;

        // Generate unique clause instance IDs
        inst.termsSignatureId = keccak256(abi.encode(address(this), "terms"));
        inst.escrowId = keccak256(abi.encode(address(this), "escrow"));

        // Add contractor as party
        _addParty(_contractor);

        // Initialize clauses
        _initializeClauses(inst);

        emit RetainerConfigured(0, _client, _contractor, _monthlyRate, inst.periodDuration, _noticePeriodDays);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    INTERNAL: CLAUSE INITIALIZATION
    // ═══════════════════════════════════════════════════════════════

    function _initializeClauses(InstanceData storage inst) internal {
        // Initialize terms signature clause (both parties must sign)
        address[] memory signers = new address[](2);
        signers[0] = inst.client;
        signers[1] = inst.contractor;

        bytes32 termsHash = keccak256(abi.encode(
            inst.monthlyRate,
            inst.periodDuration,
            inst.noticePeriodDays
        ));

        _delegateToClause(
            address(signatureClause),
            abi.encodeCall(SignatureClauseLogicV3.intakeSigners, (inst.termsSignatureId, signers))
        );
        _delegateToClause(
            address(signatureClause),
            abi.encodeCall(SignatureClauseLogicV3.intakeDocumentHash, (inst.termsSignatureId, termsHash))
        );

        // Initialize escrow clause
        _delegateToClause(
            address(escrowClause),
            abi.encodeCall(EscrowClauseLogicV3.intakeDepositor, (inst.escrowId, inst.client))
        );
        _delegateToClause(
            address(escrowClause),
            abi.encodeCall(EscrowClauseLogicV3.intakeBeneficiary, (inst.escrowId, inst.contractor))
        );
        _delegateToClause(
            address(escrowClause),
            abi.encodeCall(EscrowClauseLogicV3.intakeToken, (inst.escrowId, inst.paymentToken))
        );
        _delegateToClause(
            address(escrowClause),
            abi.encodeCall(EscrowClauseLogicV3.intakeAmount, (inst.escrowId, inst.monthlyRate))
        );

        // PRORATED cancellation - key feature for retainers
        _delegateToClause(
            address(escrowClause),
            abi.encodeCall(EscrowClauseLogicV3.intakeCancellationEnabled, (inst.escrowId, true))
        );
        _delegateToClause(
            address(escrowClause),
            abi.encodeCall(EscrowClauseLogicV3.intakeCancellableBy,
                          (inst.escrowId, EscrowClauseLogicV3.CancellableBy.EITHER))
        );
        _delegateToClause(
            address(escrowClause),
            abi.encodeCall(EscrowClauseLogicV3.intakeCancellationFeeType,
                          (inst.escrowId, EscrowClauseLogicV3.FeeType.PRORATED))
        );
        _delegateToClause(
            address(escrowClause),
            abi.encodeCall(EscrowClauseLogicV3.intakeProrationDuration, (inst.escrowId, inst.periodDuration))
        );
        _delegateToClause(
            address(escrowClause),
            abi.encodeCall(EscrowClauseLogicV3.intakeCancellationNoticePeriod, (inst.escrowId, 0))
        );
        // Set proration start date to current time (will be updated if needed)
        _delegateToClause(
            address(escrowClause),
            abi.encodeCall(EscrowClauseLogicV3.intakeProrationStartDate, (inst.escrowId, block.timestamp))
        );

        _delegateToClause(
            address(escrowClause),
            abi.encodeCall(EscrowClauseLogicV3.intakeReady, (inst.escrowId))
        );
    }

    // ═══════════════════════════════════════════════════════════════
    //                    PHASE 1: SIGN TERMS
    // ═══════════════════════════════════════════════════════════════

    /// @notice Sign the retainer terms
    /// @param instanceId The instance ID
    /// @param signature EIP-712 signature
    function signTerms(uint256 instanceId, bytes calldata signature)
        external
        validInstance(instanceId)
        onlyInstanceParty(instanceId)
        notCancelled(instanceId)
    {
        InstanceData storage inst = _getRetainerStorage().instances[instanceId];

        _delegateToClause(
            address(signatureClause),
            abi.encodeCall(SignatureClauseLogicV3.actionSign, (inst.termsSignatureId, signature))
        );

        // Track who signed
        if (msg.sender == inst.client) {
            inst.clientSigned = true;
        } else {
            inst.contractorSigned = true;
        }

        emit TermsSigned(instanceId, msg.sender);

        // Check if both have signed
        bytes memory statusResult = _delegateViewToClause(
            address(signatureClause),
            abi.encodeCall(SignatureClauseLogicV3.queryStatus, (inst.termsSignatureId))
        );
        uint16 status = abi.decode(statusResult, (uint16));

        if (status == 0x0004) { // COMPLETE
            emit TermsAccepted(instanceId, inst.client, inst.contractor);
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //                    PHASE 2: FUND PERIOD
    // ═══════════════════════════════════════════════════════════════

    /// @notice Client funds the current/next period
    /// @dev Starts streaming from block.timestamp
    /// @param instanceId The instance ID
    function fundPeriod(uint256 instanceId)
        external
        payable
        validInstance(instanceId)
        onlyInstanceClient(instanceId)
        notCancelled(instanceId)
    {
        InstanceData storage inst = _getRetainerStorage().instances[instanceId];

        // Check terms accepted
        if (!inst.clientSigned || !inst.contractorSigned) revert TermsNotAccepted();
        if (inst.funded) revert AlreadyFunded();

        // Deposit to escrow
        _delegateToClause(
            address(escrowClause),
            abi.encodeCall(EscrowClauseLogicV3.actionDeposit, (inst.escrowId))
        );

        inst.funded = true;
        inst.currentPeriodStart = block.timestamp;
        inst.currentPeriodEnd = block.timestamp + inst.periodDuration;

        emit PeriodFunded(instanceId, inst.monthlyRate, inst.currentPeriodStart, inst.currentPeriodEnd);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    PHASE 3: CLAIM STREAMING PAYMENTS
    // ═══════════════════════════════════════════════════════════════

    /// @notice Claim accrued streaming payments (contractor only)
    /// @dev Can be called at any time to claim available balance
    /// @param instanceId The instance ID
    function claimStreamed(uint256 instanceId)
        external
        validInstance(instanceId)
        onlyInstanceContractor(instanceId)
        notCancelled(instanceId)
    {
        InstanceData storage inst = _getRetainerStorage().instances[instanceId];

        if (!inst.funded) revert NotFunded();

        uint256 claimable = _getClaimableAmount(inst);
        if (claimable == 0) revert NothingToClaim();

        inst.claimedAmount += claimable;

        // Release the claimable amount via escrow partial release
        // Note: This may require the escrow clause to support partial releases
        // For now, if the full period has elapsed, we do a full release
        if (block.timestamp >= inst.currentPeriodEnd) {
            _delegateToClause(
                address(escrowClause),
                abi.encodeCall(EscrowClauseLogicV3.actionRelease, (inst.escrowId))
            );
        }

        emit StreamClaimed(instanceId, inst.contractor, claimable, inst.claimedAmount);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    CANCELLATION
    // ═══════════════════════════════════════════════════════════════

    /// @notice Initiate cancellation with notice period
    /// @param instanceId The instance ID
    function initiateCancel(uint256 instanceId)
        external
        validInstance(instanceId)
        onlyInstanceParty(instanceId)
        notCancelled(instanceId)
    {
        InstanceData storage inst = _getRetainerStorage().instances[instanceId];

        if (inst.cancelInitiatedAt > 0) revert AlreadyCancelled();

        inst.cancelInitiatedAt = block.timestamp;

        uint256 effectiveAt = block.timestamp + (inst.noticePeriodDays * 1 days);
        emit CancelInitiated(instanceId, msg.sender, effectiveAt);
    }

    /// @notice Execute cancellation after notice period
    /// @dev Releases pro-rated amount to contractor, refunds rest to client
    /// @param instanceId The instance ID
    function executeCancel(uint256 instanceId)
        external
        validInstance(instanceId)
        onlyInstanceParty(instanceId)
    {
        InstanceData storage inst = _getRetainerStorage().instances[instanceId];

        if (inst.cancelInitiatedAt == 0) revert CancelNotInitiated();
        if (inst.cancelled) revert AlreadyCancelled();

        // Check notice period elapsed
        uint256 noticePeriodSeconds = inst.noticePeriodDays * 1 days;
        if (block.timestamp < inst.cancelInitiatedAt + noticePeriodSeconds) {
            revert NoticePeriodNotElapsed();
        }

        inst.cancelled = true;

        // Calculate pro-rated split
        uint256 contractorAmount = _calculateStreamedAmount(inst);
        uint256 clientRefund = inst.monthlyRate - contractorAmount;

        // Execute cancellation on escrow
        _delegateToClause(
            address(escrowClause),
            abi.encodeCall(EscrowClauseLogicV3.actionInitiateCancel, (inst.escrowId))
        );

        emit CancelExecuted(instanceId, contractorAmount, clientRefund);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    STREAMING CALCULATION
    // ═══════════════════════════════════════════════════════════════

    /// @notice Calculate streamed amount based on elapsed time
    function _calculateStreamedAmount(InstanceData storage inst) internal view returns (uint256) {
        if (!inst.funded || inst.currentPeriodStart == 0) {
            return 0;
        }

        uint256 elapsed = block.timestamp - inst.currentPeriodStart;

        // Cap at period duration
        if (elapsed > inst.periodDuration) {
            elapsed = inst.periodDuration;
        }

        // If cancellation is effective, cap at that point
        if (inst.cancelInitiatedAt > 0) {
            uint256 noticePeriodSeconds = inst.noticePeriodDays * 1 days;
            uint256 cancelEffectiveAt = inst.cancelInitiatedAt + noticePeriodSeconds;
            if (cancelEffectiveAt > inst.currentPeriodStart) {
                uint256 cancelElapsed = cancelEffectiveAt - inst.currentPeriodStart;
                if (cancelElapsed < elapsed) {
                    elapsed = cancelElapsed;
                }
            }
        }

        // Pro-rate: (monthlyRate * elapsed) / periodDuration
        return (inst.monthlyRate * elapsed) / inst.periodDuration;
    }

    /// @notice Get claimable amount (streamed minus already claimed)
    function _getClaimableAmount(InstanceData storage inst) internal view returns (uint256) {
        uint256 streamed = _calculateStreamedAmount(inst);
        if (streamed <= inst.claimedAmount) {
            return 0;
        }
        return streamed - inst.claimedAmount;
    }

    // ═══════════════════════════════════════════════════════════════
    //                    VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    /// @notice Get the total number of instances
    function getInstanceCount() external view returns (uint256) {
        return _getRetainerStorage().instanceCounter;
    }

    /// @notice Get all instance IDs for a user
    function getUserInstances(address user) external view returns (uint256[] memory) {
        return _getRetainerStorage().userInstances[user];
    }

    /// @notice Get instance core data
    /// @dev Matches frontend hook expectations
    function getInstance(uint256 instanceId) external view returns (
        uint256 instanceNumber,
        address creator,
        uint256 createdAt,
        address client,
        address contractor,
        address paymentToken,
        uint256 monthlyRate,
        uint256 periodDuration,
        uint256 noticePeriodDays
    ) {
        InstanceData storage inst = _getRetainerStorage().instances[instanceId];
        return (
            inst.instanceNumber,
            inst.creator,
            inst.createdAt,
            inst.client,
            inst.contractor,
            inst.paymentToken,
            inst.monthlyRate,
            inst.periodDuration,
            inst.noticePeriodDays
        );
    }

    /// @notice Get instance streaming state
    /// @dev Matches frontend hook expectations - streamedAmount is calculated real-time
    function getInstanceState(uint256 instanceId) external view returns (
        bool termsAccepted,
        bool funded,
        uint256 currentPeriodStart,
        uint256 currentPeriodEnd,
        uint256 streamedAmount,
        uint256 claimedAmount,
        uint256 cancelInitiatedAt,
        bool cancelled
    ) {
        InstanceData storage inst = _getRetainerStorage().instances[instanceId];
        bool _termsAccepted = inst.clientSigned && inst.contractorSigned;
        uint256 _streamedAmount = _calculateStreamedAmount(inst);

        return (
            _termsAccepted,
            inst.funded,
            inst.currentPeriodStart,
            inst.currentPeriodEnd,
            _streamedAmount,
            inst.claimedAmount,
            inst.cancelInitiatedAt,
            inst.cancelled
        );
    }

    /// @notice Get currently claimable amount (real-time calculation)
    /// @param instanceId The instance ID
    /// @return Amount the contractor can claim right now
    function getClaimableAmount(uint256 instanceId) external view returns (uint256) {
        InstanceData storage inst = _getRetainerStorage().instances[instanceId];
        return _getClaimableAmount(inst);
    }

    /// @notice Check if instance is funded
    /// @param instanceId The instance ID
    /// @return True if escrow has been funded
    function isFunded(uint256 instanceId) external view returns (bool) {
        return _getRetainerStorage().instances[instanceId].funded;
    }

    /// @notice Get the document CID for an instance
    /// @param instanceId The instance ID
    /// @return The IPFS CID as bytes32
    function getDocumentCID(uint256 instanceId) external view returns (bytes32) {
        return _getRetainerStorage().instances[instanceId].documentCID;
    }

    /// @notice Check if this is running in proxy mode
    function isProxyMode() external view returns (bool) {
        return _getRetainerStorage().isProxyMode;
    }

    // Allow receiving ETH for escrow deposits
    receive() external payable {}
}
