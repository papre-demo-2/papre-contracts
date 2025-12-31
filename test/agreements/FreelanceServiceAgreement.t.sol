// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {FreelanceServiceAgreement} from "../../src/agreements/FreelanceServiceAgreement.sol";
import {SignatureClauseLogicV3} from "../../src/clauses/attestation/SignatureClauseLogicV3.sol";
import {EscrowClauseLogicV3} from "../../src/clauses/financial/EscrowClauseLogicV3.sol";
import {DeclarativeClauseLogicV3} from "../../src/clauses/content/DeclarativeClauseLogicV3.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title FreelanceServiceAgreementTest
 * @notice Comprehensive tests for FreelanceServiceAgreement
 *         Covers full lifecycle, singleton mode, proxy mode, edge cases, fuzz and invariant tests
 */
contract FreelanceServiceAgreementTest is Test {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // Clause contracts (deployed once, shared)
    SignatureClauseLogicV3 public signatureClause;
    EscrowClauseLogicV3 public escrowClause;
    DeclarativeClauseLogicV3 public declarativeClause;

    // Agreement implementation (for cloning and singleton)
    FreelanceServiceAgreement public implementation;

    // Test accounts
    uint256 clientPk;
    uint256 freelancerPk;
    address client;
    address freelancer;

    // Test constants
    bytes32 constant SCOPE_HASH = keccak256("Logo design for Acme Corp");
    bytes32 constant DELIVERABLE_HASH = keccak256("ipfs://QmLogoDesignFinal");
    bytes32 constant DOCUMENT_CID = keccak256("ipfs://QmAgreementDocument");
    uint256 constant PAYMENT_AMOUNT = 1 ether;
    uint256 constant KILL_FEE_BPS = 2000; // 20%

    // Events to test
    event InstanceCreated(
        uint256 indexed instanceId,
        address indexed client,
        address indexed freelancer,
        uint256 parentInstanceId
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

    function setUp() public {
        // Deploy clause logic contracts
        signatureClause = new SignatureClauseLogicV3();
        escrowClause = new EscrowClauseLogicV3();
        declarativeClause = new DeclarativeClauseLogicV3();

        // Deploy implementation (works as both singleton and proxy implementation)
        implementation = new FreelanceServiceAgreement(
            address(signatureClause),
            address(escrowClause),
            address(declarativeClause)
        );

        // Create test accounts with known private keys for signing
        clientPk = 0x1;
        freelancerPk = 0x2;
        client = vm.addr(clientPk);
        freelancer = vm.addr(freelancerPk);

        // Fund accounts
        vm.deal(client, 100 ether);
        vm.deal(freelancer, 10 ether);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    HELPER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    function _createProxyAgreement() internal returns (FreelanceServiceAgreement) {
        return _createProxyAgreement(client, freelancer, SCOPE_HASH, PAYMENT_AMOUNT, address(0), KILL_FEE_BPS, DOCUMENT_CID);
    }

    function _createProxyAgreement(
        address _client,
        address _freelancer,
        bytes32 _scopeHash,
        uint256 _paymentAmount,
        address _paymentToken,
        uint256 _killFeeBps,
        bytes32 _documentCID
    ) internal returns (FreelanceServiceAgreement) {
        FreelanceServiceAgreement agreement = FreelanceServiceAgreement(
            payable(Clones.clone(address(implementation)))
        );

        agreement.initialize(
            _client,
            _freelancer,
            _scopeHash,
            _paymentAmount,
            _paymentToken,
            _killFeeBps,
            _documentCID
        );

        return agreement;
    }

    function _createSingletonInstance() internal returns (uint256 instanceId) {
        return implementation.createInstance(
            client,
            freelancer,
            SCOPE_HASH,
            PAYMENT_AMOUNT,
            address(0),
            KILL_FEE_BPS,
            0, // parentInstanceId
            DOCUMENT_CID
        );
    }

    function _signMessage(uint256 pk, bytes32 hash) internal pure returns (bytes memory) {
        bytes32 ethSignedHash = hash.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }

    function _signTermsProxy(FreelanceServiceAgreement agreement, uint256 pk) internal {
        bytes32 scopeHash = agreement.getScopeHash();
        bytes memory signature = _signMessage(pk, scopeHash);

        vm.prank(vm.addr(pk));
        agreement.signTerms(0, signature);  // Use instance 0 for proxy mode
    }

    function _signTermsSingleton(uint256 instanceId, uint256 pk) internal {
        (,,,,,, bytes32 scopeHash,,) = implementation.getInstance(instanceId);
        bytes memory signature = _signMessage(pk, scopeHash);

        vm.prank(vm.addr(pk));
        implementation.signTerms(instanceId, signature);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    PROXY MODE INITIALIZATION TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_Proxy_Initialize_Success() public {
        vm.expectEmit(true, true, true, true);
        emit AgreementConfigured(0, client, freelancer, SCOPE_HASH, PAYMENT_AMOUNT, address(0));

        FreelanceServiceAgreement agreement = _createProxyAgreement();

        assertEq(agreement.getClient(), client);
        assertEq(agreement.getFreelancer(), freelancer);
        assertEq(agreement.getScopeHash(), SCOPE_HASH);
        assertEq(agreement.getDocumentCID(0), DOCUMENT_CID);
        (uint256 amount, address token) = agreement.getPaymentDetails();
        assertEq(amount, PAYMENT_AMOUNT);
        assertEq(token, address(0));

        (bool termsAccepted,, bool workDelivered, bool clientApproved) = agreement.getState();
        assertFalse(termsAccepted);
        assertFalse(workDelivered);
        assertFalse(clientApproved);
    }

    function test_Proxy_Initialize_SetsPartiesCorrectly() public {
        FreelanceServiceAgreement agreement = _createProxyAgreement();

        assertTrue(agreement.isParty(client));
        assertTrue(agreement.isParty(freelancer));
        assertEq(agreement.getPartyCount(), 2);
    }

    function test_Proxy_Initialize_CannotReinitialize() public {
        FreelanceServiceAgreement agreement = _createProxyAgreement();

        vm.expectRevert();
        agreement.initialize(
            client,
            freelancer,
            SCOPE_HASH,
            PAYMENT_AMOUNT,
            address(0),
            KILL_FEE_BPS,
            DOCUMENT_CID
        );
    }

    // ═══════════════════════════════════════════════════════════════
    //                    SINGLETON MODE TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_Singleton_CreateInstance_Success() public {
        vm.expectEmit(true, true, true, true);
        emit InstanceCreated(1, client, freelancer, 0);

        uint256 instanceId = _createSingletonInstance();
        assertEq(instanceId, 1);

        (uint256 instNum,,,, address c, address f, bytes32 scope,,) = implementation.getInstance(instanceId);
        assertEq(instNum, 1);
        assertEq(c, client);
        assertEq(f, freelancer);
        assertEq(scope, SCOPE_HASH);
        assertEq(implementation.getDocumentCID(instanceId), DOCUMENT_CID);
    }

    function test_Singleton_MultipleInstances() public {
        uint256 id1 = _createSingletonInstance();

        // Create second instance with different scope
        uint256 id2 = implementation.createInstance(
            client,
            freelancer,
            keccak256("Project B"),
            2 ether,
            address(0),
            3000,
            0,
            keccak256("doc2")
        );

        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(implementation.getInstanceCount(), 2);

        // Verify independence
        (,,,,,, bytes32 scope1,,) = implementation.getInstance(id1);
        (,,,,,, bytes32 scope2,,) = implementation.getInstance(id2);
        assertEq(scope1, SCOPE_HASH);
        assertEq(scope2, keccak256("Project B"));
    }

    function test_Singleton_GetUserInstances() public {
        uint256 id1 = _createSingletonInstance();
        uint256 id2 = implementation.createInstance(
            client,
            freelancer,
            keccak256("Project B"),
            2 ether,
            address(0),
            3000,
            0,
            keccak256("doc2")
        );

        uint256[] memory clientInstances = implementation.getUserInstances(client);
        assertEq(clientInstances.length, 2);
        assertEq(clientInstances[0], id1);
        assertEq(clientInstances[1], id2);

        uint256[] memory freelancerInstances = implementation.getUserInstances(freelancer);
        assertEq(freelancerInstances.length, 2);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    PROXY MODE SIGN TERMS TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_Proxy_SignTerms_ClientSignsFirst() public {
        FreelanceServiceAgreement agreement = _createProxyAgreement();

        _signTermsProxy(agreement, clientPk);

        (bool termsAccepted,,,) = agreement.getState();
        assertFalse(termsAccepted); // Not complete until both sign
    }

    function test_Proxy_SignTerms_BothSign_EmitsTermsAccepted() public {
        FreelanceServiceAgreement agreement = _createProxyAgreement();

        _signTermsProxy(agreement, clientPk);

        vm.expectEmit(true, true, false, false);
        emit TermsAccepted(0, client, freelancer);

        _signTermsProxy(agreement, freelancerPk);

        (bool termsAccepted,,,) = agreement.getState();
        assertTrue(termsAccepted);
    }

    function test_Proxy_SignTerms_RevertsIfNotParty() public {
        FreelanceServiceAgreement agreement = _createProxyAgreement();

        address stranger = makeAddr("stranger");
        vm.deal(stranger, 1 ether);

        bytes memory signature = _signMessage(0x999, SCOPE_HASH);

        vm.prank(stranger);
        vm.expectRevert(FreelanceServiceAgreement.OnlyClientOrFreelancer.selector);
        agreement.signTerms(0, signature);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    PROXY MODE DEPOSIT TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_Proxy_DepositPayment_Success() public {
        FreelanceServiceAgreement agreement = _createProxyAgreement();

        _signTermsProxy(agreement, clientPk);
        _signTermsProxy(agreement, freelancerPk);

        uint256 balanceBefore = address(agreement).balance;

        vm.expectEmit(true, false, false, true);
        emit PaymentDeposited(0, client, PAYMENT_AMOUNT);

        vm.prank(client);
        agreement.depositPayment{value: PAYMENT_AMOUNT}(0);

        assertEq(address(agreement).balance, balanceBefore + PAYMENT_AMOUNT);
    }

    function test_Proxy_DepositPayment_RevertsIfTermsNotAccepted() public {
        FreelanceServiceAgreement agreement = _createProxyAgreement();

        vm.prank(client);
        vm.expectRevert(FreelanceServiceAgreement.TermsNotAccepted.selector);
        agreement.depositPayment{value: PAYMENT_AMOUNT}(0);
    }

    function test_Proxy_DepositPayment_RevertsIfNotClient() public {
        FreelanceServiceAgreement agreement = _createProxyAgreement();

        _signTermsProxy(agreement, clientPk);
        _signTermsProxy(agreement, freelancerPk);

        vm.prank(freelancer);
        vm.expectRevert(FreelanceServiceAgreement.OnlyClient.selector);
        agreement.depositPayment{value: PAYMENT_AMOUNT}(0);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    PROXY MODE DELIVERY TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_Proxy_MarkDelivered_Success() public {
        FreelanceServiceAgreement agreement = _createProxyAgreement();

        _signTermsProxy(agreement, clientPk);
        _signTermsProxy(agreement, freelancerPk);

        vm.prank(client);
        agreement.depositPayment{value: PAYMENT_AMOUNT}(0);

        vm.expectEmit(true, false, false, true);
        emit WorkDelivered(0, freelancer, DELIVERABLE_HASH);

        vm.prank(freelancer);
        agreement.markDelivered(0, DELIVERABLE_HASH);

        (,, bool workDelivered,) = agreement.getState();
        assertTrue(workDelivered);
    }

    function test_Proxy_MarkDelivered_RevertsIfNotFunded() public {
        FreelanceServiceAgreement agreement = _createProxyAgreement();

        _signTermsProxy(agreement, clientPk);
        _signTermsProxy(agreement, freelancerPk);

        vm.prank(freelancer);
        vm.expectRevert(FreelanceServiceAgreement.NotFunded.selector);
        agreement.markDelivered(0, DELIVERABLE_HASH);
    }

    function test_Proxy_MarkDelivered_RevertsIfNotFreelancer() public {
        FreelanceServiceAgreement agreement = _createProxyAgreement();

        _signTermsProxy(agreement, clientPk);
        _signTermsProxy(agreement, freelancerPk);

        vm.prank(client);
        agreement.depositPayment{value: PAYMENT_AMOUNT}(0);

        vm.prank(client);
        vm.expectRevert(FreelanceServiceAgreement.OnlyFreelancer.selector);
        agreement.markDelivered(0, DELIVERABLE_HASH);
    }

    function test_Proxy_MarkDelivered_RevertsIfAlreadyDelivered() public {
        FreelanceServiceAgreement agreement = _createProxyAgreement();

        _signTermsProxy(agreement, clientPk);
        _signTermsProxy(agreement, freelancerPk);

        vm.prank(client);
        agreement.depositPayment{value: PAYMENT_AMOUNT}(0);

        vm.prank(freelancer);
        agreement.markDelivered(0, DELIVERABLE_HASH);

        vm.prank(freelancer);
        vm.expectRevert(FreelanceServiceAgreement.AlreadyDelivered.selector);
        agreement.markDelivered(0, DELIVERABLE_HASH);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    PROXY MODE APPROVE & RELEASE TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_Proxy_ApproveAndRelease_Success() public {
        FreelanceServiceAgreement agreement = _createProxyAgreement();

        _signTermsProxy(agreement, clientPk);
        _signTermsProxy(agreement, freelancerPk);

        vm.prank(client);
        agreement.depositPayment{value: PAYMENT_AMOUNT}(0);

        vm.prank(freelancer);
        agreement.markDelivered(0, DELIVERABLE_HASH);

        uint256 freelancerBalanceBefore = freelancer.balance;

        bytes memory signature = _signMessage(clientPk, DELIVERABLE_HASH);

        vm.expectEmit(true, false, false, false);
        emit DeliveryApproved(0, client);

        vm.prank(client);
        agreement.approveAndRelease(0, signature);

        (,,, bool clientApproved) = agreement.getState();
        assertTrue(clientApproved);
        assertEq(freelancer.balance, freelancerBalanceBefore + PAYMENT_AMOUNT);
    }

    function test_Proxy_ApproveAndRelease_RevertsIfWorkNotDelivered() public {
        FreelanceServiceAgreement agreement = _createProxyAgreement();

        _signTermsProxy(agreement, clientPk);
        _signTermsProxy(agreement, freelancerPk);

        vm.prank(client);
        agreement.depositPayment{value: PAYMENT_AMOUNT}(0);

        bytes memory signature = _signMessage(clientPk, DELIVERABLE_HASH);

        vm.prank(client);
        vm.expectRevert(FreelanceServiceAgreement.WorkNotDelivered.selector);
        agreement.approveAndRelease(0, signature);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    PROXY MODE CANCELLATION TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_Proxy_Cancel_ClientCancels_FreelancerGetsKillFee() public {
        FreelanceServiceAgreement agreement = _createProxyAgreement();

        _signTermsProxy(agreement, clientPk);
        _signTermsProxy(agreement, freelancerPk);

        vm.prank(client);
        agreement.depositPayment{value: PAYMENT_AMOUNT}(0);

        uint256 freelancerBalanceBefore = freelancer.balance;
        uint256 clientBalanceBefore = client.balance;

        vm.prank(client);
        agreement.cancel(0);

        // Freelancer should get kill fee (20%)
        uint256 killFee = (PAYMENT_AMOUNT * KILL_FEE_BPS) / 10000;
        uint256 refund = PAYMENT_AMOUNT - killFee;

        assertEq(freelancer.balance, freelancerBalanceBefore + killFee);
        assertEq(client.balance, clientBalanceBefore + refund);
    }

    function test_Proxy_Cancel_FreelancerCancels() public {
        FreelanceServiceAgreement agreement = _createProxyAgreement();

        _signTermsProxy(agreement, clientPk);
        _signTermsProxy(agreement, freelancerPk);

        vm.prank(client);
        agreement.depositPayment{value: PAYMENT_AMOUNT}(0);

        uint256 freelancerBalanceBefore = freelancer.balance;
        uint256 clientBalanceBefore = client.balance;

        vm.prank(freelancer);
        agreement.cancel(0);

        // Same split regardless of who cancels
        uint256 killFee = (PAYMENT_AMOUNT * KILL_FEE_BPS) / 10000;
        uint256 refund = PAYMENT_AMOUNT - killFee;

        assertEq(freelancer.balance, freelancerBalanceBefore + killFee);
        assertEq(client.balance, clientBalanceBefore + refund);
    }

    function test_Proxy_Cancel_RevertsIfNotParty() public {
        FreelanceServiceAgreement agreement = _createProxyAgreement();

        _signTermsProxy(agreement, clientPk);
        _signTermsProxy(agreement, freelancerPk);

        vm.prank(client);
        agreement.depositPayment{value: PAYMENT_AMOUNT}(0);

        address stranger = makeAddr("stranger");

        vm.prank(stranger);
        vm.expectRevert(FreelanceServiceAgreement.OnlyClientOrFreelancer.selector);
        agreement.cancel(0);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    FULL LIFECYCLE TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_Proxy_FullLifecycle_HappyPath() public {
        // 1. Create agreement
        FreelanceServiceAgreement agreement = _createProxyAgreement();

        // 2. Both parties sign
        _signTermsProxy(agreement, clientPk);
        _signTermsProxy(agreement, freelancerPk);

        // 3. Client deposits
        vm.prank(client);
        agreement.depositPayment{value: PAYMENT_AMOUNT}(0);

        // 4. Freelancer delivers
        vm.prank(freelancer);
        agreement.markDelivered(0, DELIVERABLE_HASH);

        // 5. Client approves
        uint256 freelancerBalanceBefore = freelancer.balance;
        bytes memory signature = _signMessage(clientPk, DELIVERABLE_HASH);
        vm.prank(client);
        agreement.approveAndRelease(0, signature);

        // 6. Verify final state
        (bool termsAccepted,, bool workDelivered, bool clientApproved) = agreement.getState();
        assertTrue(termsAccepted);
        assertTrue(workDelivered);
        assertTrue(clientApproved);
        assertEq(freelancer.balance, freelancerBalanceBefore + PAYMENT_AMOUNT);
    }

    function test_Singleton_FullLifecycle_HappyPath() public {
        // 1. Create instance
        uint256 instanceId = _createSingletonInstance();

        // 2. Both parties sign
        _signTermsSingleton(instanceId, clientPk);
        _signTermsSingleton(instanceId, freelancerPk);

        // 3. Client deposits
        vm.prank(client);
        implementation.depositPayment{value: PAYMENT_AMOUNT}(instanceId);

        // 4. Freelancer delivers
        vm.prank(freelancer);
        implementation.markDelivered(instanceId, DELIVERABLE_HASH);

        // 5. Client approves
        uint256 freelancerBalanceBefore = freelancer.balance;
        bytes memory signature = _signMessage(clientPk, DELIVERABLE_HASH);
        vm.prank(client);
        implementation.approveAndRelease(instanceId, signature);

        // 6. Verify final state
        (bool termsAccepted, bool workDelivered, bool clientApproved, bool cancelled) = implementation.getInstanceState(instanceId);
        assertTrue(termsAccepted);
        assertTrue(workDelivered);
        assertTrue(clientApproved);
        assertFalse(cancelled);
        assertEq(freelancer.balance, freelancerBalanceBefore + PAYMENT_AMOUNT);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    DOCUMENT CID TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_GetDocumentCID_Proxy() public {
        FreelanceServiceAgreement agreement = _createProxyAgreement();
        assertEq(agreement.getDocumentCID(0), DOCUMENT_CID);
    }

    function test_GetDocumentCID_Singleton() public {
        uint256 instanceId = _createSingletonInstance();
        assertEq(implementation.getDocumentCID(instanceId), DOCUMENT_CID);
    }

    function test_GetDocumentCID_DifferentPerInstance() public {
        bytes32 doc1 = keccak256("document1");
        bytes32 doc2 = keccak256("document2");

        uint256 id1 = implementation.createInstance(client, freelancer, SCOPE_HASH, PAYMENT_AMOUNT, address(0), KILL_FEE_BPS, 0, doc1);
        uint256 id2 = implementation.createInstance(client, freelancer, SCOPE_HASH, PAYMENT_AMOUNT, address(0), KILL_FEE_BPS, 0, doc2);

        assertEq(implementation.getDocumentCID(id1), doc1);
        assertEq(implementation.getDocumentCID(id2), doc2);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    PAUSE TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_Pause_BlocksOperations() public {
        FreelanceServiceAgreement agreement = _createProxyAgreement();

        _signTermsProxy(agreement, clientPk);
        _signTermsProxy(agreement, freelancerPk);

        // Pause the agreement (only creator can pause)
        vm.prank(client);
        agreement.pause();

        assertTrue(agreement.isPaused());

        vm.prank(client);
        vm.expectRevert();
        agreement.depositPayment{value: PAYMENT_AMOUNT}(0);
    }

    function test_Unpause_AllowsOperations() public {
        FreelanceServiceAgreement agreement = _createProxyAgreement();

        _signTermsProxy(agreement, clientPk);
        _signTermsProxy(agreement, freelancerPk);

        vm.prank(client);
        agreement.pause();

        vm.prank(client);
        agreement.unpause();

        assertFalse(agreement.isPaused());

        vm.prank(client);
        agreement.depositPayment{value: PAYMENT_AMOUNT}(0);
        // Should not revert
    }

    // ═══════════════════════════════════════════════════════════════
    //                    MULTIPLE AGREEMENTS TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_MultipleProxyAgreements_Independent() public {
        // Create two independent proxy agreements
        FreelanceServiceAgreement agreement1 = _createProxyAgreement(
            client, freelancer, keccak256("Project A"), 1 ether, address(0), KILL_FEE_BPS, keccak256("docA")
        );
        FreelanceServiceAgreement agreement2 = _createProxyAgreement(
            client, freelancer, keccak256("Project B"), 2 ether, address(0), KILL_FEE_BPS, keccak256("docB")
        );

        // Complete agreement 1
        bytes32 scope1 = agreement1.getScopeHash();
        vm.prank(client);
        agreement1.signTerms(0, _signMessage(clientPk, scope1));
        vm.prank(freelancer);
        agreement1.signTerms(0, _signMessage(freelancerPk, scope1));
        vm.prank(client);
        agreement1.depositPayment{value: 1 ether}(0);
        vm.prank(freelancer);
        agreement1.markDelivered(0, keccak256("deliverable-a"));

        bytes memory sig = _signMessage(clientPk, keccak256("deliverable-a"));
        vm.prank(client);
        agreement1.approveAndRelease(0, sig);

        // Agreement 2 should be unaffected
        (bool terms2Accepted,,,) = agreement2.getState();
        assertFalse(terms2Accepted);
    }

    // Allow receiving ETH
    receive() external payable {}
}

/**
 * @title FreelanceServiceAgreementFuzzTest
 * @notice Fuzz tests for FreelanceServiceAgreement
 */
contract FreelanceServiceAgreementFuzzTest is Test {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    SignatureClauseLogicV3 public signatureClause;
    EscrowClauseLogicV3 public escrowClause;
    DeclarativeClauseLogicV3 public declarativeClause;
    FreelanceServiceAgreement public implementation;

    function setUp() public {
        signatureClause = new SignatureClauseLogicV3();
        escrowClause = new EscrowClauseLogicV3();
        declarativeClause = new DeclarativeClauseLogicV3();
        implementation = new FreelanceServiceAgreement(
            address(signatureClause),
            address(escrowClause),
            address(declarativeClause)
        );
    }

    function testFuzz_Initialize_VariablePayments(uint256 paymentAmount) public {
        paymentAmount = bound(paymentAmount, 0.001 ether, 1000 ether);

        uint256 clientPk = 0x1;
        uint256 freelancerPk = 0x2;
        address client = vm.addr(clientPk);
        address freelancer = vm.addr(freelancerPk);
        vm.deal(client, paymentAmount + 1 ether);

        FreelanceServiceAgreement agreement = FreelanceServiceAgreement(
            payable(Clones.clone(address(implementation)))
        );

        agreement.initialize(
            client,
            freelancer,
            keccak256("test"),
            paymentAmount,
            address(0),
            1000,
            keccak256("doc")
        );

        (uint256 amount,) = agreement.getPaymentDetails();
        assertEq(amount, paymentAmount);
    }

    function testFuzz_Cancel_KillFeeSplit(uint256 paymentAmount, uint256 killFeeBps) public {
        paymentAmount = bound(paymentAmount, 0.01 ether, 100 ether);
        killFeeBps = bound(killFeeBps, 0, 10000); // 0% to 100%

        uint256 clientPk = 0x1;
        uint256 freelancerPk = 0x2;
        address client = vm.addr(clientPk);
        address freelancer = vm.addr(freelancerPk);
        vm.deal(client, paymentAmount + 1 ether);
        vm.deal(freelancer, 1 ether);

        FreelanceServiceAgreement agreement = FreelanceServiceAgreement(
            payable(Clones.clone(address(implementation)))
        );

        bytes32 scopeHash = keccak256(abi.encode(paymentAmount, killFeeBps));
        agreement.initialize(
            client,
            freelancer,
            scopeHash,
            paymentAmount,
            address(0),
            killFeeBps,
            keccak256("doc")
        );

        // Sign terms
        bytes memory clientSig = _signMessage(clientPk, scopeHash);
        vm.prank(client);
        agreement.signTerms(0, clientSig);

        bytes memory freelancerSig = _signMessage(freelancerPk, scopeHash);
        vm.prank(freelancer);
        agreement.signTerms(0, freelancerSig);

        // Deposit
        vm.prank(client);
        agreement.depositPayment{value: paymentAmount}(0);

        uint256 freelancerBefore = freelancer.balance;
        uint256 clientBefore = client.balance;

        // Cancel
        vm.prank(client);
        agreement.cancel(0);

        uint256 expectedKillFee = (paymentAmount * killFeeBps) / 10000;
        uint256 expectedRefund = paymentAmount - expectedKillFee;

        assertEq(freelancer.balance, freelancerBefore + expectedKillFee);
        assertEq(client.balance, clientBefore + expectedRefund);

        // Invariant: total distributed equals payment
        assertEq(expectedKillFee + expectedRefund, paymentAmount);
    }

    function testFuzz_Singleton_MultipleInstances(uint8 numInstances) public {
        numInstances = uint8(bound(uint256(numInstances), 1, 10));

        for (uint256 i = 0; i < numInstances; i++) {
            uint256 clientPk = i * 2 + 1;
            uint256 freelancerPk = i * 2 + 2;
            address _client = vm.addr(clientPk);
            address _freelancer = vm.addr(freelancerPk);

            uint256 instanceId = implementation.createInstance(
                _client,
                _freelancer,
                keccak256(abi.encode("project", i)),
                1 ether,
                address(0),
                2000,
                0,
                keccak256(abi.encode("doc", i))
            );

            assertEq(instanceId, i + 1);
        }

        assertEq(implementation.getInstanceCount(), numInstances);
    }

    function _signMessage(uint256 pk, bytes32 hash) internal pure returns (bytes memory) {
        bytes32 ethSignedHash = hash.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }

    receive() external payable {}
}

/**
 * @title FreelanceServiceAgreementInvariantTest
 * @notice Invariant tests for FreelanceServiceAgreement
 */
contract FreelanceServiceAgreementInvariantTest is Test {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    SignatureClauseLogicV3 public signatureClause;
    EscrowClauseLogicV3 public escrowClause;
    DeclarativeClauseLogicV3 public declarativeClause;
    FreelanceServiceAgreement public implementation;

    FreelanceServiceAgreementHandler public handler;

    function setUp() public {
        signatureClause = new SignatureClauseLogicV3();
        escrowClause = new EscrowClauseLogicV3();
        declarativeClause = new DeclarativeClauseLogicV3();
        implementation = new FreelanceServiceAgreement(
            address(signatureClause),
            address(escrowClause),
            address(declarativeClause)
        );

        handler = new FreelanceServiceAgreementHandler(implementation);

        targetContract(address(handler));
    }

    function invariant_InstanceCountMatchesCreated() public view {
        assertEq(implementation.getInstanceCount(), handler.instancesCreated());
    }

    function invariant_AllInstancesHaveValidCreator() public view {
        uint256 count = implementation.getInstanceCount();
        for (uint256 i = 1; i <= count; i++) {
            (,, address creator,,,,,,) = implementation.getInstance(i);
            assertTrue(creator != address(0));
        }
    }

    receive() external payable {}
}

/**
 * @title FreelanceServiceAgreementHandler
 * @notice Handler contract for invariant testing
 */
contract FreelanceServiceAgreementHandler is Test {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    FreelanceServiceAgreement public implementation;
    uint256 public instancesCreated;

    uint256 public constant MAX_INSTANCES = 10;

    constructor(FreelanceServiceAgreement _implementation) {
        implementation = _implementation;
    }

    function createInstance(uint256 seed) external {
        if (instancesCreated >= MAX_INSTANCES) return;

        uint256 clientPk = seed % 1000 + 1;
        uint256 freelancerPk = seed % 1000 + 1001;
        address client = vm.addr(clientPk);
        address freelancer = vm.addr(freelancerPk);

        vm.deal(client, 100 ether);
        vm.deal(freelancer, 10 ether);

        bytes32 scopeHash = keccak256(abi.encode("scope", seed));

        implementation.createInstance(
            client,
            freelancer,
            scopeHash,
            1 ether,
            address(0),
            2000,
            0,
            keccak256(abi.encode("doc", seed))
        );

        instancesCreated++;
    }

    receive() external payable {}
}
