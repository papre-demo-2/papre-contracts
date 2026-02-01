// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {SubcontractorSafetyNetAgreement} from "../../src/agreements/SubcontractorSafetyNetAgreement.sol";
import {SignatureClauseLogicV3} from "../../src/clauses/attestation/SignatureClauseLogicV3.sol";
import {EscrowClauseLogicV3} from "../../src/clauses/financial/EscrowClauseLogicV3.sol";
import {ArbitrationClauseLogicV3} from "../../src/clauses/governance/ArbitrationClauseLogicV3.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title SubcontractorSafetyNetAgreementTest
 * @notice Comprehensive tests for SubcontractorSafetyNetAgreement
 *         Covers auto-release (THE SAFETY NET), arbitration, both singleton and proxy modes
 */
contract SubcontractorSafetyNetAgreementTest is Test {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // Clause contracts
    SignatureClauseLogicV3 public signatureClause;
    EscrowClauseLogicV3 public escrowClause;
    ArbitrationClauseLogicV3 public arbitrationClause;

    // Agreement implementation (singleton)
    SubcontractorSafetyNetAgreement public safetyNet;

    // Test accounts
    uint256 clientPk;
    uint256 subcontractorPk;
    uint256 arbitratorPk;
    address client;
    address subcontractor;
    address arbitrator;

    // Constants
    bytes32 constant SCOPE_HASH = keccak256("Build mobile app prototype");
    bytes32 constant DELIVERABLE_HASH = keccak256("ipfs://QmAppPrototype");
    bytes32 constant DOCUMENT_CID = keccak256("ipfs://QmSafetyNetDocument");
    bytes32 constant CLAIM_CID = keccak256("ipfs://QmClaimDocument");
    bytes32 constant EVIDENCE_CID = keccak256("ipfs://QmEvidenceDocument");
    bytes32 constant JUSTIFICATION_CID = keccak256("ipfs://QmJustificationDocument");
    uint256 constant PAYMENT_AMOUNT = 5 ether;
    uint256 constant WORK_DEADLINE_OFFSET = 4 weeks;
    uint256 constant REVIEW_PERIOD_DAYS = 7;

    // Events (match contract)
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

    function setUp() public {
        // Deploy clauses
        signatureClause = new SignatureClauseLogicV3();
        escrowClause = new EscrowClauseLogicV3();
        arbitrationClause = new ArbitrationClauseLogicV3();

        // Deploy safetyNet singleton (3 args: signatureClause, escrowClause, arbitrationClause)
        safetyNet = new SubcontractorSafetyNetAgreement(
            address(signatureClause), address(escrowClause), address(arbitrationClause)
        );

        // Create accounts
        clientPk = 0x1;
        subcontractorPk = 0x2;
        arbitratorPk = 0x3;
        client = vm.addr(clientPk);
        subcontractor = vm.addr(subcontractorPk);
        arbitrator = vm.addr(arbitratorPk);

        vm.deal(client, 100 ether);
        vm.deal(subcontractor, 10 ether);
        vm.deal(arbitrator, 10 ether);
        vm.deal(address(safetyNet), 100 ether); // Fund singleton for escrow
    }

    // ═══════════════════════════════════════════════════════════════
    //                    HELPER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    /// @notice Create a proxy-based agreement
    function _createProxyAgreement() internal returns (SubcontractorSafetyNetAgreement) {
        return _createProxyAgreement(PAYMENT_AMOUNT, block.timestamp + WORK_DEADLINE_OFFSET, REVIEW_PERIOD_DAYS);
    }

    function _createProxyAgreement(uint256 paymentAmount, uint256 workDeadline, uint256 reviewPeriodDays)
        internal
        returns (SubcontractorSafetyNetAgreement)
    {
        SubcontractorSafetyNetAgreement agreement =
            SubcontractorSafetyNetAgreement(payable(Clones.clone(address(safetyNet))));

        vm.deal(address(agreement), 100 ether); // Fund for escrow

        agreement.initialize(
            client,
            subcontractor,
            arbitrator,
            address(0), // ETH
            paymentAmount,
            SCOPE_HASH,
            workDeadline,
            reviewPeriodDays,
            DOCUMENT_CID
        );

        return agreement;
    }

    /// @notice Create a singleton instance (returns instanceId)
    function _createSingletonInstance() internal returns (uint256 instanceId) {
        return _createSingletonInstance(PAYMENT_AMOUNT, block.timestamp + WORK_DEADLINE_OFFSET, REVIEW_PERIOD_DAYS);
    }

    function _createSingletonInstance(uint256 paymentAmount, uint256 workDeadline, uint256 reviewPeriodDays)
        internal
        returns (uint256 instanceId)
    {
        return safetyNet.createInstance(
            client,
            subcontractor,
            arbitrator,
            address(0), // ETH
            paymentAmount,
            SCOPE_HASH,
            workDeadline,
            reviewPeriodDays,
            DOCUMENT_CID
        );
    }

    function _signMessage(uint256 pk, bytes32 hash) internal pure returns (bytes memory) {
        bytes32 ethSignedHash = hash.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }

    /// @notice Sign terms for proxy mode (instanceId = 0)
    function _signTermsProxy(SubcontractorSafetyNetAgreement agreement) internal {
        vm.prank(client);
        agreement.signTerms(0, _signMessage(clientPk, SCOPE_HASH));

        vm.prank(subcontractor);
        agreement.signTerms(0, _signMessage(subcontractorPk, SCOPE_HASH));
    }

    /// @notice Sign terms for singleton mode
    function _signTermsSingleton(uint256 instanceId) internal {
        vm.prank(client);
        safetyNet.signTerms(instanceId, _signMessage(clientPk, SCOPE_HASH));

        vm.prank(subcontractor);
        safetyNet.signTerms(instanceId, _signMessage(subcontractorPk, SCOPE_HASH));
    }

    /// @notice Complete proxy mode setup: sign and deposit
    function _signAndDepositProxy(SubcontractorSafetyNetAgreement agreement) internal {
        _signTermsProxy(agreement);

        vm.prank(client);
        agreement.depositPayment{value: PAYMENT_AMOUNT}(0);
    }

    /// @notice Complete singleton mode setup: sign and deposit
    function _signAndDepositSingleton(uint256 instanceId) internal {
        _signTermsSingleton(instanceId);

        vm.prank(client);
        safetyNet.depositPayment{value: PAYMENT_AMOUNT}(instanceId);
    }

    /// @notice Submit work for singleton mode
    function _submitWorkSingleton(uint256 instanceId) internal {
        vm.prank(subcontractor);
        safetyNet.submitWork(instanceId, DELIVERABLE_HASH);
    }

    /// @notice Submit work for proxy mode
    function _submitWorkProxy(SubcontractorSafetyNetAgreement agreement) internal {
        vm.prank(subcontractor);
        agreement.submitWork(0, DELIVERABLE_HASH);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    SINGLETON MODE: CREATE INSTANCE
    // ═══════════════════════════════════════════════════════════════

    function test_CreateInstance_Success() public {
        vm.expectEmit(true, true, true, true);
        emit InstanceCreated(1, client, subcontractor, arbitrator);

        uint256 instanceId = _createSingletonInstance();

        assertEq(instanceId, 1);
        assertEq(safetyNet.getInstanceCount(), 1);

        (
            uint256 instanceNumber,
            address creator,,
            address _client,
            address _subcontractor,
            address _arbitrator,
            address paymentToken,
            uint256 paymentAmount,
            bytes32 scopeHash,,
        ) = safetyNet.getInstance(instanceId);

        assertEq(instanceNumber, 1);
        assertEq(creator, address(this));
        assertEq(_client, client);
        assertEq(_subcontractor, subcontractor);
        assertEq(_arbitrator, arbitrator);
        assertEq(paymentToken, address(0));
        assertEq(paymentAmount, PAYMENT_AMOUNT);
        assertEq(scopeHash, SCOPE_HASH);
    }

    function test_CreateInstance_MultipleInstances() public {
        uint256 id1 = _createSingletonInstance();
        uint256 id2 = _createSingletonInstance();
        uint256 id3 = _createSingletonInstance();

        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(id3, 3);
        assertEq(safetyNet.getInstanceCount(), 3);
    }

    function test_CreateInstance_TracksUserInstances() public {
        _createSingletonInstance();
        _createSingletonInstance();

        uint256[] memory clientInstances = safetyNet.getUserInstances(client);
        uint256[] memory subcontractorInstances = safetyNet.getUserInstances(subcontractor);

        assertEq(clientInstances.length, 2);
        assertEq(subcontractorInstances.length, 2);
    }

    function test_CreateInstance_RevertsIfReviewPeriodTooShort() public {
        vm.expectRevert(SubcontractorSafetyNetAgreement.ReviewPeriodTooShort.selector);
        safetyNet.createInstance(
            client,
            subcontractor,
            arbitrator,
            address(0),
            PAYMENT_AMOUNT,
            SCOPE_HASH,
            block.timestamp + WORK_DEADLINE_OFFSET,
            2, // Less than minimum 3 days
            DOCUMENT_CID
        );
    }

    // ═══════════════════════════════════════════════════════════════
    //                    PROXY MODE: INITIALIZE
    // ═══════════════════════════════════════════════════════════════

    function test_Initialize_Proxy_Success() public {
        SubcontractorSafetyNetAgreement agreement = _createProxyAgreement();

        assertTrue(agreement.isProxyMode());

        (
            uint256 instanceNumber,,,
            address _client,
            address _subcontractor,
            address _arbitrator,,
            uint256 paymentAmount,,,
        ) = agreement.getInstance(0);

        assertEq(instanceNumber, 0);
        assertEq(_client, client);
        assertEq(_subcontractor, subcontractor);
        assertEq(_arbitrator, arbitrator);
        assertEq(paymentAmount, PAYMENT_AMOUNT);
    }

    function test_Initialize_Proxy_RevertsOnSecondInit() public {
        SubcontractorSafetyNetAgreement agreement = _createProxyAgreement();

        vm.expectRevert();
        agreement.initialize(
            client,
            subcontractor,
            arbitrator,
            address(0),
            PAYMENT_AMOUNT,
            SCOPE_HASH,
            block.timestamp + WORK_DEADLINE_OFFSET,
            REVIEW_PERIOD_DAYS,
            DOCUMENT_CID
        );
    }

    function test_CreateInstance_RevertsOnProxy() public {
        SubcontractorSafetyNetAgreement agreement = _createProxyAgreement();

        vm.expectRevert(SubcontractorSafetyNetAgreement.SingletonModeOnly.selector);
        agreement.createInstance(
            client,
            subcontractor,
            arbitrator,
            address(0),
            PAYMENT_AMOUNT,
            SCOPE_HASH,
            block.timestamp + WORK_DEADLINE_OFFSET,
            REVIEW_PERIOD_DAYS,
            DOCUMENT_CID
        );
    }

    // ═══════════════════════════════════════════════════════════════
    //                    SIGN TERMS TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_SignTerms_Singleton_BothSign() public {
        uint256 instanceId = _createSingletonInstance();

        vm.expectEmit(true, true, false, false);
        emit TermsSigned(instanceId, client);

        vm.prank(client);
        safetyNet.signTerms(instanceId, _signMessage(clientPk, SCOPE_HASH));

        vm.expectEmit(true, true, true, false);
        emit TermsAccepted(instanceId, client, subcontractor);

        vm.prank(subcontractor);
        safetyNet.signTerms(instanceId, _signMessage(subcontractorPk, SCOPE_HASH));

        (bool termsAccepted,,,,,,,) = safetyNet.getInstanceState(instanceId);
        assertTrue(termsAccepted);
    }

    function test_SignTerms_Proxy_BothSign() public {
        SubcontractorSafetyNetAgreement agreement = _createProxyAgreement();

        vm.prank(client);
        agreement.signTerms(0, _signMessage(clientPk, SCOPE_HASH));

        vm.prank(subcontractor);
        agreement.signTerms(0, _signMessage(subcontractorPk, SCOPE_HASH));

        (bool termsAccepted,,,,,,,) = agreement.getInstanceState(0);
        assertTrue(termsAccepted);
    }

    function test_SignTerms_RevertsIfNotParty() public {
        uint256 instanceId = _createSingletonInstance();

        address stranger = makeAddr("stranger");

        vm.prank(stranger);
        vm.expectRevert(SubcontractorSafetyNetAgreement.OnlyClientOrSubcontractor.selector);
        safetyNet.signTerms(instanceId, _signMessage(0x999, SCOPE_HASH));
    }

    function test_SignTerms_RevertsIfInvalidInstance() public {
        vm.prank(client);
        vm.expectRevert(SubcontractorSafetyNetAgreement.InstanceNotFound.selector);
        safetyNet.signTerms(999, _signMessage(clientPk, SCOPE_HASH));
    }

    // ═══════════════════════════════════════════════════════════════
    //                    DEPOSIT PAYMENT TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_DepositPayment_Singleton_Success() public {
        uint256 instanceId = _createSingletonInstance();
        _signTermsSingleton(instanceId);

        vm.expectEmit(true, true, false, true);
        emit PaymentDeposited(instanceId, client, PAYMENT_AMOUNT);

        vm.prank(client);
        safetyNet.depositPayment{value: PAYMENT_AMOUNT}(instanceId);

        (, bool funded,,,,,,) = safetyNet.getInstanceState(instanceId);
        assertTrue(funded);
    }

    function test_DepositPayment_Proxy_Success() public {
        SubcontractorSafetyNetAgreement agreement = _createProxyAgreement();
        _signTermsProxy(agreement);

        vm.prank(client);
        agreement.depositPayment{value: PAYMENT_AMOUNT}(0);

        (, bool funded,,,,,,) = agreement.getInstanceState(0);
        assertTrue(funded);
    }

    function test_DepositPayment_RevertsIfTermsNotAccepted() public {
        uint256 instanceId = _createSingletonInstance();

        vm.prank(client);
        vm.expectRevert(SubcontractorSafetyNetAgreement.TermsNotAccepted.selector);
        safetyNet.depositPayment{value: PAYMENT_AMOUNT}(instanceId);
    }

    function test_DepositPayment_RevertsIfNotClient() public {
        uint256 instanceId = _createSingletonInstance();
        _signTermsSingleton(instanceId);

        vm.prank(subcontractor);
        vm.expectRevert(SubcontractorSafetyNetAgreement.OnlyClient.selector);
        safetyNet.depositPayment{value: PAYMENT_AMOUNT}(instanceId);
    }

    function test_DepositPayment_RevertsIfAlreadyFunded() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndDepositSingleton(instanceId);

        vm.prank(client);
        vm.expectRevert(SubcontractorSafetyNetAgreement.AlreadyFunded.selector);
        safetyNet.depositPayment{value: PAYMENT_AMOUNT}(instanceId);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    WORK SUBMISSION TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_SubmitWork_Singleton_Success() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndDepositSingleton(instanceId);

        uint256 expectedDeadline = block.timestamp + (REVIEW_PERIOD_DAYS * 1 days);

        vm.expectEmit(true, false, false, true);
        emit WorkSubmitted(instanceId, DELIVERABLE_HASH, expectedDeadline);

        _submitWorkSingleton(instanceId);

        (,, bool workSubmitted,, uint256 reviewDeadline,,,) = safetyNet.getInstanceState(instanceId);
        assertTrue(workSubmitted);
        assertEq(reviewDeadline, expectedDeadline);
    }

    function test_SubmitWork_Proxy_Success() public {
        SubcontractorSafetyNetAgreement agreement = _createProxyAgreement();
        _signAndDepositProxy(agreement);

        _submitWorkProxy(agreement);

        (,, bool workSubmitted,,,,,) = agreement.getInstanceState(0);
        assertTrue(workSubmitted);
    }

    function test_SubmitWork_RevertsIfNotSubcontractor() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndDepositSingleton(instanceId);

        vm.prank(client);
        vm.expectRevert(SubcontractorSafetyNetAgreement.OnlySubcontractor.selector);
        safetyNet.submitWork(instanceId, DELIVERABLE_HASH);
    }

    function test_SubmitWork_RevertsIfNotFunded() public {
        uint256 instanceId = _createSingletonInstance();
        _signTermsSingleton(instanceId);

        vm.prank(subcontractor);
        vm.expectRevert(SubcontractorSafetyNetAgreement.NotFunded.selector);
        safetyNet.submitWork(instanceId, DELIVERABLE_HASH);
    }

    function test_SubmitWork_RevertsIfPastDeadline() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndDepositSingleton(instanceId);

        vm.warp(block.timestamp + WORK_DEADLINE_OFFSET + 1);

        vm.prank(subcontractor);
        vm.expectRevert(SubcontractorSafetyNetAgreement.WorkDeadlinePassed.selector);
        safetyNet.submitWork(instanceId, DELIVERABLE_HASH);
    }

    function test_SubmitWork_RevertsIfAlreadySubmitted() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndDepositSingleton(instanceId);
        _submitWorkSingleton(instanceId);

        vm.prank(subcontractor);
        vm.expectRevert(SubcontractorSafetyNetAgreement.WorkAlreadySubmitted.selector);
        safetyNet.submitWork(instanceId, keccak256("other work"));
    }

    // ═══════════════════════════════════════════════════════════════
    //                    WORK APPROVAL TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_ApproveWork_Singleton_Success() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndDepositSingleton(instanceId);
        _submitWorkSingleton(instanceId);

        vm.expectEmit(true, false, false, false);
        emit WorkApproved(instanceId, block.timestamp);

        vm.prank(client);
        safetyNet.approveWork(instanceId);

        (,,, bool workApproved,,,,) = safetyNet.getInstanceState(instanceId);
        assertTrue(workApproved);
    }

    function test_ApproveWork_Proxy_Success() public {
        SubcontractorSafetyNetAgreement agreement = _createProxyAgreement();
        _signAndDepositProxy(agreement);
        _submitWorkProxy(agreement);

        vm.prank(client);
        agreement.approveWork(0);

        (,,, bool workApproved,,,,) = agreement.getInstanceState(0);
        assertTrue(workApproved);
    }

    function test_ApproveWork_RevertsIfNotClient() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndDepositSingleton(instanceId);
        _submitWorkSingleton(instanceId);

        vm.prank(subcontractor);
        vm.expectRevert(SubcontractorSafetyNetAgreement.OnlyClient.selector);
        safetyNet.approveWork(instanceId);
    }

    function test_ApproveWork_RevertsIfWorkNotSubmitted() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndDepositSingleton(instanceId);

        vm.prank(client);
        vm.expectRevert(SubcontractorSafetyNetAgreement.WorkNotSubmitted.selector);
        safetyNet.approveWork(instanceId);
    }

    function test_ApproveWork_RevertsIfAlreadyApproved() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndDepositSingleton(instanceId);
        _submitWorkSingleton(instanceId);

        vm.prank(client);
        safetyNet.approveWork(instanceId);

        vm.prank(client);
        vm.expectRevert(SubcontractorSafetyNetAgreement.WorkAlreadyApproved.selector);
        safetyNet.approveWork(instanceId);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    DEADLINE ENFORCEMENT (THE SAFETY NET)
    // ═══════════════════════════════════════════════════════════════

    function test_CanEnforceDeadline_FalseBeforeReviewPeriod() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndDepositSingleton(instanceId);
        _submitWorkSingleton(instanceId);

        assertFalse(safetyNet.canEnforceDeadline(instanceId));
    }

    function test_CanEnforceDeadline_TrueAfterReviewPeriod() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndDepositSingleton(instanceId);
        _submitWorkSingleton(instanceId);

        // Warp past review period
        vm.warp(block.timestamp + (REVIEW_PERIOD_DAYS * 1 days) + 1);

        assertTrue(safetyNet.canEnforceDeadline(instanceId));
    }

    function test_CanEnforceDeadline_FalseIfAlreadyApproved() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndDepositSingleton(instanceId);
        _submitWorkSingleton(instanceId);

        vm.prank(client);
        safetyNet.approveWork(instanceId);

        vm.warp(block.timestamp + (REVIEW_PERIOD_DAYS * 1 days) + 1);

        assertFalse(safetyNet.canEnforceDeadline(instanceId));
    }

    function test_CanEnforceDeadline_FalseIfDisputed() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndDepositSingleton(instanceId);
        _submitWorkSingleton(instanceId);

        vm.prank(client);
        safetyNet.fileClaim(instanceId, CLAIM_CID);

        vm.warp(block.timestamp + (REVIEW_PERIOD_DAYS * 1 days) + 1);

        assertFalse(safetyNet.canEnforceDeadline(instanceId));
    }

    function test_EnforceDeadline_Singleton_Success() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndDepositSingleton(instanceId);
        _submitWorkSingleton(instanceId);

        vm.warp(block.timestamp + (REVIEW_PERIOD_DAYS * 1 days) + 1);

        vm.expectEmit(true, true, false, true);
        emit DeadlineEnforced(instanceId, address(this), PAYMENT_AMOUNT);

        safetyNet.enforceDeadline(instanceId);

        (,,,,, bool deadlineEnforced,,) = safetyNet.getInstanceState(instanceId);
        assertTrue(deadlineEnforced);
    }

    function test_EnforceDeadline_Proxy_Success() public {
        SubcontractorSafetyNetAgreement agreement = _createProxyAgreement();
        _signAndDepositProxy(agreement);
        _submitWorkProxy(agreement);

        vm.warp(block.timestamp + (REVIEW_PERIOD_DAYS * 1 days) + 1);

        agreement.enforceDeadline(0);

        (,,,,, bool deadlineEnforced,,) = agreement.getInstanceState(0);
        assertTrue(deadlineEnforced);
    }

    function test_EnforceDeadline_AnyoneCanCall() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndDepositSingleton(instanceId);
        _submitWorkSingleton(instanceId);

        vm.warp(block.timestamp + (REVIEW_PERIOD_DAYS * 1 days) + 1);

        address randomPerson = makeAddr("random");
        vm.prank(randomPerson);
        safetyNet.enforceDeadline(instanceId);

        (,,,,, bool deadlineEnforced,,) = safetyNet.getInstanceState(instanceId);
        assertTrue(deadlineEnforced);
    }

    function test_EnforceDeadline_RevertsBeforeReviewPeriod() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndDepositSingleton(instanceId);
        _submitWorkSingleton(instanceId);

        vm.expectRevert(SubcontractorSafetyNetAgreement.ReviewPeriodNotExpired.selector);
        safetyNet.enforceDeadline(instanceId);
    }

    function test_EnforceDeadline_RevertsIfWorkNotSubmitted() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndDepositSingleton(instanceId);

        vm.warp(block.timestamp + (REVIEW_PERIOD_DAYS * 1 days) + 1);

        vm.expectRevert(SubcontractorSafetyNetAgreement.WorkNotSubmitted.selector);
        safetyNet.enforceDeadline(instanceId);
    }

    function test_EnforceDeadline_RevertsIfAlreadyApproved() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndDepositSingleton(instanceId);
        _submitWorkSingleton(instanceId);

        vm.prank(client);
        safetyNet.approveWork(instanceId);

        vm.warp(block.timestamp + (REVIEW_PERIOD_DAYS * 1 days) + 1);

        vm.expectRevert(SubcontractorSafetyNetAgreement.WorkAlreadyApproved.selector);
        safetyNet.enforceDeadline(instanceId);
    }

    function test_EnforceDeadline_RevertsIfAlreadyEnforced() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndDepositSingleton(instanceId);
        _submitWorkSingleton(instanceId);

        vm.warp(block.timestamp + (REVIEW_PERIOD_DAYS * 1 days) + 1);

        safetyNet.enforceDeadline(instanceId);

        vm.expectRevert(SubcontractorSafetyNetAgreement.AlreadyEnforced.selector);
        safetyNet.enforceDeadline(instanceId);
    }

    function test_EnforceDeadline_RevertsIfDisputed() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndDepositSingleton(instanceId);
        _submitWorkSingleton(instanceId);

        vm.prank(client);
        safetyNet.fileClaim(instanceId, CLAIM_CID);

        vm.warp(block.timestamp + (REVIEW_PERIOD_DAYS * 1 days) + 1);

        vm.expectRevert(SubcontractorSafetyNetAgreement.DisputeAlreadyActive.selector);
        safetyNet.enforceDeadline(instanceId);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    DISPUTE / ARBITRATION TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_FileClaim_ClientSuccess() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndDepositSingleton(instanceId);
        _submitWorkSingleton(instanceId);

        vm.expectEmit(true, true, false, false);
        emit DisputeFiled(instanceId, client, CLAIM_CID, block.timestamp + 7 days);

        vm.prank(client);
        safetyNet.fileClaim(instanceId, CLAIM_CID);

        (,,,,,, bool disputeActive,) = safetyNet.getInstanceState(instanceId);
        assertTrue(disputeActive);

        (address claimant, bytes32 claimCID,,,,,,) = safetyNet.getDispute(instanceId);
        assertEq(claimant, client);
        assertEq(claimCID, CLAIM_CID);
    }

    function test_FileClaim_SubcontractorSuccess() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndDepositSingleton(instanceId);
        _submitWorkSingleton(instanceId);

        // Subcontractor can file after review period too
        vm.warp(block.timestamp + (REVIEW_PERIOD_DAYS * 1 days) + 1);

        vm.prank(subcontractor);
        safetyNet.fileClaim(instanceId, CLAIM_CID);

        (address claimant,,,,,,,) = safetyNet.getDispute(instanceId);
        assertEq(claimant, subcontractor);
    }

    function test_FileClaim_RevertsIfClientAfterReviewPeriod() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndDepositSingleton(instanceId);
        _submitWorkSingleton(instanceId);

        vm.warp(block.timestamp + (REVIEW_PERIOD_DAYS * 1 days) + 1);

        vm.prank(client);
        vm.expectRevert(SubcontractorSafetyNetAgreement.ReviewPeriodExpired.selector);
        safetyNet.fileClaim(instanceId, CLAIM_CID);
    }

    function test_FileClaim_RevertsIfWorkNotSubmitted() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndDepositSingleton(instanceId);

        vm.prank(client);
        vm.expectRevert(SubcontractorSafetyNetAgreement.WorkNotSubmitted.selector);
        safetyNet.fileClaim(instanceId, CLAIM_CID);
    }

    function test_FileClaim_RevertsIfAlreadyApproved() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndDepositSingleton(instanceId);
        _submitWorkSingleton(instanceId);

        vm.prank(client);
        safetyNet.approveWork(instanceId);

        vm.prank(client);
        vm.expectRevert(SubcontractorSafetyNetAgreement.WorkAlreadyApproved.selector);
        safetyNet.fileClaim(instanceId, CLAIM_CID);
    }

    function test_FileClaim_RevertsIfAlreadyDisputed() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndDepositSingleton(instanceId);
        _submitWorkSingleton(instanceId);

        vm.prank(client);
        safetyNet.fileClaim(instanceId, CLAIM_CID);

        vm.prank(subcontractor);
        vm.expectRevert(SubcontractorSafetyNetAgreement.DisputeAlreadyActive.selector);
        safetyNet.fileClaim(instanceId, keccak256("other claim"));
    }

    function test_SubmitEvidence_Success() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndDepositSingleton(instanceId);
        _submitWorkSingleton(instanceId);

        vm.prank(client);
        safetyNet.fileClaim(instanceId, CLAIM_CID);

        vm.expectEmit(true, true, false, true);
        emit EvidenceSubmitted(instanceId, subcontractor, EVIDENCE_CID);

        vm.prank(subcontractor);
        safetyNet.submitEvidence(instanceId, EVIDENCE_CID);
    }

    function test_SubmitEvidence_RevertsIfNoDispute() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndDepositSingleton(instanceId);
        _submitWorkSingleton(instanceId);

        vm.prank(subcontractor);
        vm.expectRevert(SubcontractorSafetyNetAgreement.DisputeNotActive.selector);
        safetyNet.submitEvidence(instanceId, EVIDENCE_CID);
    }

    function test_Rule_SubcontractorWins() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndDepositSingleton(instanceId);
        _submitWorkSingleton(instanceId);

        vm.prank(client);
        safetyNet.fileClaim(instanceId, CLAIM_CID);

        vm.expectEmit(true, false, false, true);
        emit DisputeRuled(instanceId, 2, JUSTIFICATION_CID, 0);

        vm.prank(arbitrator);
        safetyNet.rule(instanceId, 2, JUSTIFICATION_CID, 0); // SUBCONTRACTOR_WINS

        (,,,, uint8 ruling,,, uint256 ruledAt) = safetyNet.getDispute(instanceId);
        assertEq(ruling, 2);
        assertGt(ruledAt, 0);

        (,,,,,,, bool disputeResolved) = safetyNet.getInstanceState(instanceId);
        assertTrue(disputeResolved);
    }

    function test_Rule_ClientWins() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndDepositSingleton(instanceId);
        _submitWorkSingleton(instanceId);

        vm.prank(client);
        safetyNet.fileClaim(instanceId, CLAIM_CID);

        vm.prank(arbitrator);
        safetyNet.rule(instanceId, 1, JUSTIFICATION_CID, 0); // CLIENT_WINS

        (,,,, uint8 ruling,,,) = safetyNet.getDispute(instanceId);
        assertEq(ruling, 1);
    }

    function test_Rule_Split() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndDepositSingleton(instanceId);
        _submitWorkSingleton(instanceId);

        vm.prank(client);
        safetyNet.fileClaim(instanceId, CLAIM_CID);

        vm.prank(arbitrator);
        safetyNet.rule(instanceId, 3, JUSTIFICATION_CID, 7500); // SPLIT - 75% to subcontractor

        (,,,, uint8 ruling,, uint256 splitBasisPoints,) = safetyNet.getDispute(instanceId);
        assertEq(ruling, 3);
        assertEq(splitBasisPoints, 7500);
    }

    function test_Rule_RevertsIfNotArbitrator() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndDepositSingleton(instanceId);
        _submitWorkSingleton(instanceId);

        vm.prank(client);
        safetyNet.fileClaim(instanceId, CLAIM_CID);

        vm.prank(client);
        vm.expectRevert(SubcontractorSafetyNetAgreement.OnlyArbitrator.selector);
        safetyNet.rule(instanceId, 2, JUSTIFICATION_CID, 0);
    }

    function test_Rule_RevertsIfNoDispute() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndDepositSingleton(instanceId);
        _submitWorkSingleton(instanceId);

        vm.prank(arbitrator);
        vm.expectRevert(SubcontractorSafetyNetAgreement.DisputeNotActive.selector);
        safetyNet.rule(instanceId, 2, JUSTIFICATION_CID, 0);
    }

    function test_Rule_RevertsIfInvalidRuling() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndDepositSingleton(instanceId);
        _submitWorkSingleton(instanceId);

        vm.prank(client);
        safetyNet.fileClaim(instanceId, CLAIM_CID);

        vm.prank(arbitrator);
        vm.expectRevert(SubcontractorSafetyNetAgreement.InvalidRuling.selector);
        safetyNet.rule(instanceId, 0, JUSTIFICATION_CID, 0); // NONE is invalid

        vm.prank(arbitrator);
        vm.expectRevert(SubcontractorSafetyNetAgreement.InvalidRuling.selector);
        safetyNet.rule(instanceId, 4, JUSTIFICATION_CID, 0); // Out of range
    }

    function test_Rule_RevertsIfAlreadyResolved() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndDepositSingleton(instanceId);
        _submitWorkSingleton(instanceId);

        vm.prank(client);
        safetyNet.fileClaim(instanceId, CLAIM_CID);

        vm.prank(arbitrator);
        safetyNet.rule(instanceId, 2, JUSTIFICATION_CID, 0);

        vm.prank(arbitrator);
        vm.expectRevert(SubcontractorSafetyNetAgreement.DisputeAlreadyResolved.selector);
        safetyNet.rule(instanceId, 1, JUSTIFICATION_CID, 0);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    DOCUMENT CID TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_GetDocumentCID_Singleton() public {
        uint256 instanceId = _createSingletonInstance();

        bytes32 cid = safetyNet.getDocumentCID(instanceId);
        assertEq(cid, DOCUMENT_CID);
    }

    function test_GetDocumentCID_Proxy() public {
        SubcontractorSafetyNetAgreement agreement = _createProxyAgreement();

        bytes32 cid = agreement.getDocumentCID(0);
        assertEq(cid, DOCUMENT_CID);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    VIEW FUNCTIONS TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_GetInstance_ReturnsCorrectData() public {
        uint256 instanceId = _createSingletonInstance();

        (
            uint256 instanceNumber,
            address creator,
            uint256 createdAt,
            address _client,
            address _subcontractor,
            address _arbitrator,
            address paymentToken,
            uint256 paymentAmount,
            bytes32 scopeHash,
            uint256 workDeadline,
            uint256 reviewPeriodDays
        ) = safetyNet.getInstance(instanceId);

        assertEq(instanceNumber, 1);
        assertEq(creator, address(this));
        assertEq(createdAt, block.timestamp);
        assertEq(_client, client);
        assertEq(_subcontractor, subcontractor);
        assertEq(_arbitrator, arbitrator);
        assertEq(paymentToken, address(0));
        assertEq(paymentAmount, PAYMENT_AMOUNT);
        assertEq(scopeHash, SCOPE_HASH);
        assertEq(workDeadline, block.timestamp + WORK_DEADLINE_OFFSET);
        assertEq(reviewPeriodDays, REVIEW_PERIOD_DAYS);
    }

    function test_GetInstanceState_ReturnsCorrectData() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndDepositSingleton(instanceId);
        _submitWorkSingleton(instanceId);

        (
            bool termsAccepted,
            bool funded,
            bool workSubmitted,
            bool workApproved,
            uint256 reviewDeadline,
            bool deadlineEnforced,
            bool disputeActive,
            bool disputeResolved
        ) = safetyNet.getInstanceState(instanceId);

        assertTrue(termsAccepted);
        assertTrue(funded);
        assertTrue(workSubmitted);
        assertFalse(workApproved);
        assertEq(reviewDeadline, block.timestamp + (REVIEW_PERIOD_DAYS * 1 days));
        assertFalse(deadlineEnforced);
        assertFalse(disputeActive);
        assertFalse(disputeResolved);
    }

    function test_GetDispute_ReturnsCorrectData() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndDepositSingleton(instanceId);
        _submitWorkSingleton(instanceId);

        vm.prank(client);
        safetyNet.fileClaim(instanceId, CLAIM_CID);

        (
            address claimant,
            bytes32 claimCID,
            uint256 filedAt,
            uint256 evidenceDeadline,
            uint8 ruling,
            bytes32 justificationCID,
            uint256 splitBasisPoints,
            uint256 ruledAt
        ) = safetyNet.getDispute(instanceId);

        assertEq(claimant, client);
        assertEq(claimCID, CLAIM_CID);
        assertEq(filedAt, block.timestamp);
        assertEq(evidenceDeadline, block.timestamp + 7 days);
        assertEq(ruling, 0); // NONE
        assertEq(justificationCID, bytes32(0));
        assertEq(splitBasisPoints, 0);
        assertEq(ruledAt, 0);
    }

    function test_IsFunded() public {
        uint256 instanceId = _createSingletonInstance();

        assertFalse(safetyNet.isFunded(instanceId));

        _signAndDepositSingleton(instanceId);

        assertTrue(safetyNet.isFunded(instanceId));
    }

    function test_IsProxyMode() public {
        assertFalse(safetyNet.isProxyMode());

        SubcontractorSafetyNetAgreement agreement = _createProxyAgreement();
        assertTrue(agreement.isProxyMode());
    }

    // ═══════════════════════════════════════════════════════════════
    //                    FULL LIFECYCLE TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_FullLifecycle_HappyPath_ClientApproves() public {
        uint256 instanceId = _createSingletonInstance();

        // 1. Sign
        _signTermsSingleton(instanceId);

        // 2. Deposit
        vm.prank(client);
        safetyNet.depositPayment{value: PAYMENT_AMOUNT}(instanceId);

        // 3. Submit work
        _submitWorkSingleton(instanceId);

        // 4. Approve
        vm.prank(client);
        safetyNet.approveWork(instanceId);

        (,,, bool workApproved,,,,) = safetyNet.getInstanceState(instanceId);
        assertTrue(workApproved);
    }

    function test_FullLifecycle_ClientGhosts_AutoRelease() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndDepositSingleton(instanceId);
        _submitWorkSingleton(instanceId);

        // Client does nothing (ghosts)
        vm.warp(block.timestamp + (REVIEW_PERIOD_DAYS * 1 days) + 1);

        // Anyone can trigger auto-release
        safetyNet.enforceDeadline(instanceId);

        (,,,,, bool deadlineEnforced,,) = safetyNet.getInstanceState(instanceId);
        assertTrue(deadlineEnforced);
    }

    function test_FullLifecycle_DisputeToArbitration_SubcontractorWins() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndDepositSingleton(instanceId);
        _submitWorkSingleton(instanceId);

        // Client disputes
        vm.prank(client);
        safetyNet.fileClaim(instanceId, CLAIM_CID);

        // Both submit evidence
        vm.prank(subcontractor);
        safetyNet.submitEvidence(instanceId, EVIDENCE_CID);

        vm.prank(client);
        safetyNet.submitEvidence(instanceId, keccak256("client evidence"));

        // Arbitrator rules in favor of subcontractor
        vm.prank(arbitrator);
        safetyNet.rule(instanceId, 2, JUSTIFICATION_CID, 0);

        (,,,, uint8 ruling,,,) = safetyNet.getDispute(instanceId);
        assertEq(ruling, 2); // SUBCONTRACTOR_WINS
    }

    function test_FullLifecycle_MultipleInstances_Independent() public {
        uint256 id1 = _createSingletonInstance();
        uint256 id2 = _createSingletonInstance();

        // Sign and fund both
        _signAndDepositSingleton(id1);
        _signAndDepositSingleton(id2);

        // Submit work on id1 only
        _submitWorkSingleton(id1);

        // Approve id1
        vm.prank(client);
        safetyNet.approveWork(id1);

        // id2 should be unaffected
        (,,, bool approved1,,,,) = safetyNet.getInstanceState(id1);
        (,, bool workSubmitted2, bool approved2,,,,) = safetyNet.getInstanceState(id2);

        assertTrue(approved1);
        assertFalse(workSubmitted2);
        assertFalse(approved2);
    }

    receive() external payable {}
}

/**
 * @title SubcontractorSafetyNetFuzzTest
 * @notice Fuzz tests for variable safety net configurations
 */
contract SubcontractorSafetyNetFuzzTest is Test {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    SignatureClauseLogicV3 public signatureClause;
    EscrowClauseLogicV3 public escrowClause;
    ArbitrationClauseLogicV3 public arbitrationClause;
    SubcontractorSafetyNetAgreement public safetyNet;

    function setUp() public {
        signatureClause = new SignatureClauseLogicV3();
        escrowClause = new EscrowClauseLogicV3();
        arbitrationClause = new ArbitrationClauseLogicV3();
        safetyNet = new SubcontractorSafetyNetAgreement(
            address(signatureClause), address(escrowClause), address(arbitrationClause)
        );
        vm.deal(address(safetyNet), 1000 ether);
    }

    function testFuzz_VariablePaymentAmounts(uint128 paymentAmount) public {
        paymentAmount = uint128(bound(uint256(paymentAmount), 0.01 ether, 100 ether));

        uint256 clientPk = 0x1;
        uint256 subcontractorPk = 0x2;
        address client = vm.addr(clientPk);
        address subcontractor = vm.addr(subcontractorPk);
        address arbitrator = makeAddr("arb");

        vm.deal(client, paymentAmount + 10 ether);

        bytes32 scopeHash = keccak256(abi.encode(paymentAmount));

        uint256 instanceId = safetyNet.createInstance(
            client,
            subcontractor,
            arbitrator,
            address(0),
            paymentAmount,
            scopeHash,
            block.timestamp + 4 weeks,
            7,
            keccak256("doc")
        );

        (,,,,,,, uint256 amount,,,) = safetyNet.getInstance(instanceId);
        assertEq(amount, paymentAmount);
    }

    function testFuzz_VariableReviewPeriods(uint8 reviewDays) public {
        reviewDays = uint8(bound(uint256(reviewDays), 3, 30)); // Minimum 3 days

        uint256 clientPk = 0x1;
        uint256 subcontractorPk = 0x2;
        address client = vm.addr(clientPk);
        address subcontractor = vm.addr(subcontractorPk);
        address arbitrator = makeAddr("arb");

        vm.deal(client, 100 ether);

        bytes32 scopeHash = keccak256(abi.encode(reviewDays));

        uint256 instanceId = safetyNet.createInstance(
            client,
            subcontractor,
            arbitrator,
            address(0),
            5 ether,
            scopeHash,
            block.timestamp + 4 weeks,
            reviewDays,
            keccak256("doc")
        );

        // Sign and fund
        vm.prank(client);
        safetyNet.signTerms(instanceId, _signMessage(clientPk, scopeHash));

        vm.prank(subcontractor);
        safetyNet.signTerms(instanceId, _signMessage(subcontractorPk, scopeHash));

        vm.prank(client);
        safetyNet.depositPayment{value: 5 ether}(instanceId);

        vm.prank(subcontractor);
        safetyNet.submitWork(instanceId, keccak256("work"));

        // Should not be able to enforce before review period
        vm.warp(block.timestamp + (reviewDays * 1 days) - 1);
        assertFalse(safetyNet.canEnforceDeadline(instanceId));

        // Should be able to enforce after review period
        vm.warp(block.timestamp + 2);
        assertTrue(safetyNet.canEnforceDeadline(instanceId));
    }

    function testFuzz_ArbitrationRulings(uint8 ruling) public {
        ruling = uint8(bound(uint256(ruling), 1, 3)); // Valid rulings: 1, 2, 3

        uint256 clientPk = 0x1;
        uint256 subcontractorPk = 0x2;
        address client = vm.addr(clientPk);
        address subcontractor = vm.addr(subcontractorPk);
        address arbitrator = makeAddr("arb");

        vm.deal(client, 100 ether);

        bytes32 scopeHash = keccak256("test");

        uint256 instanceId = safetyNet.createInstance(
            client,
            subcontractor,
            arbitrator,
            address(0),
            5 ether,
            scopeHash,
            block.timestamp + 4 weeks,
            7,
            keccak256("doc")
        );

        // Sign, fund, submit
        vm.prank(client);
        safetyNet.signTerms(instanceId, _signMessage(clientPk, scopeHash));
        vm.prank(subcontractor);
        safetyNet.signTerms(instanceId, _signMessage(subcontractorPk, scopeHash));
        vm.prank(client);
        safetyNet.depositPayment{value: 5 ether}(instanceId);
        vm.prank(subcontractor);
        safetyNet.submitWork(instanceId, keccak256("work"));

        // File dispute
        vm.prank(client);
        safetyNet.fileClaim(instanceId, keccak256("claim"));

        // Rule
        uint256 splitBps = ruling == 3 ? 5000 : 0;
        vm.prank(arbitrator);
        safetyNet.rule(instanceId, ruling, keccak256("justification"), splitBps);

        (,,,, uint8 actualRuling,,,) = safetyNet.getDispute(instanceId);
        assertEq(actualRuling, ruling);
    }

    function _signMessage(uint256 pk, bytes32 hash) internal pure returns (bytes memory) {
        bytes32 ethSignedHash = hash.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }

    receive() external payable {}
}

/**
 * @title SubcontractorSafetyNetInvariantTest
 * @notice Invariant tests for safety net agreement
 */
contract SubcontractorSafetyNetInvariantTest is Test {
    SignatureClauseLogicV3 public signatureClause;
    EscrowClauseLogicV3 public escrowClause;
    ArbitrationClauseLogicV3 public arbitrationClause;
    SubcontractorSafetyNetAgreement public safetyNet;

    SafetyNetHandler public handler;

    function setUp() public {
        signatureClause = new SignatureClauseLogicV3();
        escrowClause = new EscrowClauseLogicV3();
        arbitrationClause = new ArbitrationClauseLogicV3();
        safetyNet = new SubcontractorSafetyNetAgreement(
            address(signatureClause), address(escrowClause), address(arbitrationClause)
        );
        vm.deal(address(safetyNet), 1000 ether);

        handler = new SafetyNetHandler(safetyNet);
        targetContract(address(handler));
    }

    function invariant_InstanceCountNeverDecreases() public view {
        assertGe(safetyNet.getInstanceCount(), handler.getInstanceIds().length);
    }

    function invariant_ApprovedMeansNotEnforced() public view {
        uint256[] memory instanceIds = handler.getInstanceIds();
        for (uint256 i = 0; i < instanceIds.length; i++) {
            uint256 id = instanceIds[i];
            (,,, bool workApproved,, bool deadlineEnforced,,) = safetyNet.getInstanceState(id);
            // Can't have both approved and deadline enforced
            assertFalse(workApproved && deadlineEnforced);
        }
    }

    receive() external payable {}
}

/**
 * @title SafetyNetHandler
 * @notice Handler for invariant testing
 */
contract SafetyNetHandler is Test {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    SubcontractorSafetyNetAgreement public safetyNet;
    uint256[] public instanceIds;

    uint256 public constant MAX_INSTANCES = 3;
    uint256 constant PAYMENT_AMOUNT = 5 ether;

    constructor(SubcontractorSafetyNetAgreement _safetyNet) {
        safetyNet = _safetyNet;
    }

    function createInstance(uint256 seed) external {
        if (instanceIds.length >= MAX_INSTANCES) return;

        uint256 clientPk = seed % 1000 + 1;
        address client = vm.addr(clientPk);
        uint256 subcontractorPk = seed % 1000 + 1001;
        address subcontractor = vm.addr(subcontractorPk);
        address arbitrator = makeAddr(string(abi.encode("arb", seed)));

        vm.deal(client, PAYMENT_AMOUNT * 10);

        bytes32 scopeHash = keccak256(abi.encode("scope", seed));

        uint256 instanceId = safetyNet.createInstance(
            client,
            subcontractor,
            arbitrator,
            address(0),
            PAYMENT_AMOUNT,
            scopeHash,
            block.timestamp + 4 weeks,
            7,
            keccak256(abi.encode("doc", seed))
        );

        instanceIds.push(instanceId);

        // Sign terms
        vm.prank(client);
        safetyNet.signTerms(instanceId, _signMessage(clientPk, scopeHash));
        vm.prank(subcontractor);
        safetyNet.signTerms(instanceId, _signMessage(subcontractorPk, scopeHash));

        // Fund
        vm.prank(client);
        safetyNet.depositPayment{value: PAYMENT_AMOUNT}(instanceId);
    }

    function submitWork(uint256 instanceIndex) external {
        if (instanceIds.length == 0) return;
        instanceIndex = instanceIndex % instanceIds.length;
        uint256 instanceId = instanceIds[instanceIndex];

        // Get subcontractor
        (,,,, address subcontractor,,,,,,) = safetyNet.getInstance(instanceId);

        // Check state
        (,, bool workSubmitted,,,,,) = safetyNet.getInstanceState(instanceId);
        if (workSubmitted) return;

        vm.prank(subcontractor);
        try safetyNet.submitWork(instanceId, keccak256(abi.encode("work", instanceId))) {} catch {}
    }

    function approveWork(uint256 instanceIndex) external {
        if (instanceIds.length == 0) return;
        instanceIndex = instanceIndex % instanceIds.length;
        uint256 instanceId = instanceIds[instanceIndex];

        (,,, address client,,,,,,,) = safetyNet.getInstance(instanceId);

        vm.prank(client);
        try safetyNet.approveWork(instanceId) {} catch {}
    }

    function enforceDeadline(uint256 instanceIndex) external {
        if (instanceIds.length == 0) return;
        instanceIndex = instanceIndex % instanceIds.length;
        uint256 instanceId = instanceIds[instanceIndex];

        try safetyNet.enforceDeadline(instanceId) {} catch {}
    }

    function warpTime(uint256 seconds_) external {
        seconds_ = bound(seconds_, 1, 30 days);
        vm.warp(block.timestamp + seconds_);
    }

    function getInstanceIds() external view returns (uint256[] memory) {
        return instanceIds;
    }

    function _signMessage(uint256 pk, bytes32 hash) internal pure returns (bytes memory) {
        bytes32 ethSignedHash = hash.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }

    receive() external payable {}
}
