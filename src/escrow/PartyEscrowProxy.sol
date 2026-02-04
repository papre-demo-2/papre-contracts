// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PartyEscrowProxy
/// @notice Minimal 2-of-2 multisig escrow owned by parties, not Papre
/// @dev Designed for party-controlled fund custody. Papre has ZERO access.
///
///      ARCHITECTURE:
///      - ONE proxy per agreement (not per milestone)
///      - Supports unlimited milestones via unique releaseIds
///      - Both parties must approve any fund movement
///      - Configurable dispute resolution modes
///
///      DISPUTE MODES (chosen at initialization):
///      - FROZEN: Funds locked until both parties agree (default)
///      - AUTO_REFUND: After timeout, funds auto-return to client
///      - AUTO_RELEASE: After timeout, funds auto-release to contractor
///
///      SECURITY:
///      - No owner, no admin, no Papre role
///      - Immutable parties after initialization
///      - Reentrancy protected
///
contract PartyEscrowProxy is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════
    //                          ENUMS
    // ═══════════════════════════════════════════════════════════════

    enum DisputeMode {
        FROZEN,        // 0 - Funds locked until both parties agree
        AUTO_REFUND,   // 1 - After timeout, refund to client
        AUTO_RELEASE   // 2 - After timeout, release to contractor
    }

    // ═══════════════════════════════════════════════════════════════
    //                          STATE
    // ═══════════════════════════════════════════════════════════════

    /// @notice The client (payer/depositor)
    address public client;

    /// @notice The contractor (payee/beneficiary)
    address public contractor;

    /// @notice Payment token (address(0) for native ETH/AVAX)
    address public token;

    /// @notice Dispute resolution mode
    DisputeMode public disputeMode;

    /// @notice Timeout in seconds for auto-resolution (0 for FROZEN mode)
    uint256 public disputeTimeout;

    /// @notice Timestamp of last activity (deposit/release/refund)
    uint256 public lastActivityTimestamp;

    /// @notice Whether the proxy has been initialized
    bool public initialized;

    /// @notice Total amount deposited
    uint256 public totalDeposited;

    /// @notice Total amount released to contractor
    uint256 public totalReleased;

    /// @notice Total amount refunded to client
    uint256 public totalRefunded;

    // Approval tracking for releases
    // releaseId => party => approved
    mapping(bytes32 => mapping(address => bool)) public releaseApprovals;
    // releaseId => amount
    mapping(bytes32 => uint256) public releaseAmounts;
    // releaseId => executed
    mapping(bytes32 => bool) public releaseExecuted;

    // Approval tracking for refunds
    // refundId => party => approved
    mapping(bytes32 => mapping(address => bool)) public refundApprovals;
    // refundId => amount
    mapping(bytes32 => uint256) public refundAmounts;
    // refundId => executed
    mapping(bytes32 => bool) public refundExecuted;

    // ═══════════════════════════════════════════════════════════════
    //                          ERRORS
    // ═══════════════════════════════════════════════════════════════

    error AlreadyInitialized();
    error NotInitialized();
    error ZeroAddress();
    error OnlyParty();
    error AmountMismatch();
    error InsufficientBalance();
    error AlreadyApproved();
    error NotBothApproved();
    error AlreadyExecuted();
    error DisputeTimeoutNotElapsed();
    error AutoResolutionNotEnabled();
    error TransferFailed();

    // ═══════════════════════════════════════════════════════════════
    //                          EVENTS
    // ═══════════════════════════════════════════════════════════════

    event Initialized(
        address indexed client,
        address indexed contractor,
        address token,
        DisputeMode disputeMode,
        uint256 disputeTimeout
    );

    event Deposited(
        address indexed depositor,
        uint256 amount,
        uint256 totalDeposited
    );

    event ReleaseApproved(
        bytes32 indexed releaseId,
        address indexed approver,
        uint256 amount
    );

    event ReleaseExecuted(
        bytes32 indexed releaseId,
        address indexed contractor,
        uint256 amount
    );

    event RefundApproved(
        bytes32 indexed refundId,
        address indexed approver,
        uint256 amount
    );

    event RefundExecuted(
        bytes32 indexed refundId,
        address indexed client,
        uint256 amount
    );

    event DisputeAutoResolved(
        address indexed recipient,
        uint256 amount,
        DisputeMode mode
    );

    // ═══════════════════════════════════════════════════════════════
    //                          MODIFIERS
    // ═══════════════════════════════════════════════════════════════

    modifier onlyParty() {
        if (msg.sender != client && msg.sender != contractor) {
            revert OnlyParty();
        }
        _;
    }

    modifier whenInitialized() {
        if (!initialized) {
            revert NotInitialized();
        }
        _;
    }

    // ═══════════════════════════════════════════════════════════════
    //                       INITIALIZATION
    // ═══════════════════════════════════════════════════════════════

    /// @notice Initialize the escrow proxy (called once via factory)
    /// @param _client The client address (depositor)
    /// @param _contractor The contractor address (beneficiary)
    /// @param _token Payment token (address(0) for native)
    /// @param _disputeMode How disputes are resolved
    /// @param _disputeTimeoutDays Days before auto-resolution (0 for FROZEN)
    function initialize(
        address _client,
        address _contractor,
        address _token,
        DisputeMode _disputeMode,
        uint256 _disputeTimeoutDays
    ) external {
        if (initialized) revert AlreadyInitialized();
        if (_client == address(0)) revert ZeroAddress();
        if (_contractor == address(0)) revert ZeroAddress();

        client = _client;
        contractor = _contractor;
        token = _token;
        disputeMode = _disputeMode;
        disputeTimeout = _disputeTimeoutDays * 1 days;
        lastActivityTimestamp = block.timestamp;
        initialized = true;

        emit Initialized(_client, _contractor, _token, _disputeMode, disputeTimeout);
    }

    // ═══════════════════════════════════════════════════════════════
    //                          DEPOSIT
    // ═══════════════════════════════════════════════════════════════

    /// @notice Deposit funds into escrow
    /// @dev Anyone can deposit, but typically the client
    /// @param amount Amount to deposit (ignored for native token, uses msg.value)
    function deposit(uint256 amount) external payable whenInitialized nonReentrant {
        uint256 depositAmount;

        if (token == address(0)) {
            // Native token
            depositAmount = msg.value;
            if (depositAmount == 0) revert AmountMismatch();
        } else {
            // ERC20
            if (msg.value != 0) revert AmountMismatch();
            depositAmount = amount;
            IERC20(token).safeTransferFrom(msg.sender, address(this), depositAmount);
        }

        totalDeposited += depositAmount;
        lastActivityTimestamp = block.timestamp;

        emit Deposited(msg.sender, depositAmount, totalDeposited);
    }

    // ═══════════════════════════════════════════════════════════════
    //                          RELEASE
    // ═══════════════════════════════════════════════════════════════

    /// @notice Approve release of funds to contractor
    /// @dev Both client AND contractor must approve before execution
    /// @param releaseId Unique identifier for this release (e.g., keccak256(instanceId, milestoneIndex))
    /// @param amount Amount to release
    function approveRelease(bytes32 releaseId, uint256 amount)
        external
        whenInitialized
        onlyParty
        nonReentrant
    {
        if (releaseExecuted[releaseId]) revert AlreadyExecuted();
        if (releaseApprovals[releaseId][msg.sender]) revert AlreadyApproved();

        // If first approval, set the amount
        if (releaseAmounts[releaseId] == 0) {
            releaseAmounts[releaseId] = amount;
        } else {
            // Second approval must match the amount
            if (releaseAmounts[releaseId] != amount) revert AmountMismatch();
        }

        releaseApprovals[releaseId][msg.sender] = true;
        lastActivityTimestamp = block.timestamp;

        emit ReleaseApproved(releaseId, msg.sender, amount);
    }

    /// @notice Execute a release after both parties approved
    /// @param releaseId The release to execute
    function executeRelease(bytes32 releaseId)
        external
        whenInitialized
        nonReentrant
    {
        if (releaseExecuted[releaseId]) revert AlreadyExecuted();
        if (!releaseApprovals[releaseId][client] || !releaseApprovals[releaseId][contractor]) {
            revert NotBothApproved();
        }

        uint256 amount = releaseAmounts[releaseId];
        if (amount > balance()) revert InsufficientBalance();

        releaseExecuted[releaseId] = true;
        totalReleased += amount;
        lastActivityTimestamp = block.timestamp;

        _transfer(contractor, amount);

        emit ReleaseExecuted(releaseId, contractor, amount);
    }

    // ═══════════════════════════════════════════════════════════════
    //                          REFUND
    // ═══════════════════════════════════════════════════════════════

    /// @notice Approve refund of funds to client
    /// @dev Both client AND contractor must approve before execution
    /// @param refundId Unique identifier for this refund
    /// @param amount Amount to refund
    function approveRefund(bytes32 refundId, uint256 amount)
        external
        whenInitialized
        onlyParty
        nonReentrant
    {
        if (refundExecuted[refundId]) revert AlreadyExecuted();
        if (refundApprovals[refundId][msg.sender]) revert AlreadyApproved();

        // If first approval, set the amount
        if (refundAmounts[refundId] == 0) {
            refundAmounts[refundId] = amount;
        } else {
            // Second approval must match the amount
            if (refundAmounts[refundId] != amount) revert AmountMismatch();
        }

        refundApprovals[refundId][msg.sender] = true;
        lastActivityTimestamp = block.timestamp;

        emit RefundApproved(refundId, msg.sender, amount);
    }

    /// @notice Execute a refund after both parties approved
    /// @param refundId The refund to execute
    function executeRefund(bytes32 refundId)
        external
        whenInitialized
        nonReentrant
    {
        if (refundExecuted[refundId]) revert AlreadyExecuted();
        if (!refundApprovals[refundId][client] || !refundApprovals[refundId][contractor]) {
            revert NotBothApproved();
        }

        uint256 amount = refundAmounts[refundId];
        if (amount > balance()) revert InsufficientBalance();

        refundExecuted[refundId] = true;
        totalRefunded += amount;
        lastActivityTimestamp = block.timestamp;

        _transfer(client, amount);

        emit RefundExecuted(refundId, client, amount);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    DISPUTE AUTO-RESOLUTION
    // ═══════════════════════════════════════════════════════════════

    /// @notice Execute automatic dispute resolution after timeout
    /// @dev Callable by anyone after disputeTimeout has elapsed
    function executeDisputeResolution()
        external
        whenInitialized
        nonReentrant
    {
        if (disputeMode == DisputeMode.FROZEN) {
            revert AutoResolutionNotEnabled();
        }

        if (block.timestamp < lastActivityTimestamp + disputeTimeout) {
            revert DisputeTimeoutNotElapsed();
        }

        uint256 currentBalance = balance();
        if (currentBalance == 0) revert InsufficientBalance();

        address recipient;
        if (disputeMode == DisputeMode.AUTO_REFUND) {
            recipient = client;
            totalRefunded += currentBalance;
        } else {
            // AUTO_RELEASE
            recipient = contractor;
            totalReleased += currentBalance;
        }

        lastActivityTimestamp = block.timestamp;
        _transfer(recipient, currentBalance);

        emit DisputeAutoResolved(recipient, currentBalance, disputeMode);
    }

    // ═══════════════════════════════════════════════════════════════
    //                        VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    /// @notice Get current escrow balance
    function balance() public view returns (uint256) {
        if (token == address(0)) {
            return address(this).balance;
        } else {
            return IERC20(token).balanceOf(address(this));
        }
    }

    /// @notice Check if dispute auto-resolution can be executed
    function canAutoResolve() external view returns (bool) {
        if (disputeMode == DisputeMode.FROZEN) return false;
        if (balance() == 0) return false;
        return block.timestamp >= lastActivityTimestamp + disputeTimeout;
    }

    /// @notice Get release approval status
    /// @param releaseId The release to check
    /// @return clientApproved Whether client has approved
    /// @return contractorApproved Whether contractor has approved
    /// @return amount The approved amount
    /// @return executed Whether the release has been executed
    function getReleaseStatus(bytes32 releaseId)
        external
        view
        returns (
            bool clientApproved,
            bool contractorApproved,
            uint256 amount,
            bool executed
        )
    {
        return (
            releaseApprovals[releaseId][client],
            releaseApprovals[releaseId][contractor],
            releaseAmounts[releaseId],
            releaseExecuted[releaseId]
        );
    }

    /// @notice Get refund approval status
    /// @param refundId The refund to check
    /// @return clientApproved Whether client has approved
    /// @return contractorApproved Whether contractor has approved
    /// @return amount The approved amount
    /// @return executed Whether the refund has been executed
    function getRefundStatus(bytes32 refundId)
        external
        view
        returns (
            bool clientApproved,
            bool contractorApproved,
            uint256 amount,
            bool executed
        )
    {
        return (
            refundApprovals[refundId][client],
            refundApprovals[refundId][contractor],
            refundAmounts[refundId],
            refundExecuted[refundId]
        );
    }

    /// @notice Get escrow configuration
    function getConfig()
        external
        view
        returns (
            address _client,
            address _contractor,
            address _token,
            DisputeMode _disputeMode,
            uint256 _disputeTimeout,
            uint256 _lastActivityTimestamp
        )
    {
        return (
            client,
            contractor,
            token,
            disputeMode,
            disputeTimeout,
            lastActivityTimestamp
        );
    }

    /// @notice Get escrow totals
    function getTotals()
        external
        view
        returns (
            uint256 deposited,
            uint256 released,
            uint256 refunded,
            uint256 currentBalance
        )
    {
        return (
            totalDeposited,
            totalReleased,
            totalRefunded,
            balance()
        );
    }

    // ═══════════════════════════════════════════════════════════════
    //                          INTERNAL
    // ═══════════════════════════════════════════════════════════════

    /// @notice Transfer funds to recipient
    function _transfer(address recipient, uint256 amount) internal {
        if (token == address(0)) {
            (bool success,) = payable(recipient).call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            IERC20(token).safeTransfer(recipient, amount);
        }
    }

    /// @notice Receive native tokens
    receive() external payable {}
}
