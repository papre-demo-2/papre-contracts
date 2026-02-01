// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/contracts/applications/CCIPReceiver.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title CrossChainControllerV3
/// @notice Infrastructure singleton for cross-chain communication using Chainlink CCIP
/// @dev This controller handles CCIP messaging between Agreement proxies on different chains.
///      It works with CrossChainClauseLogicV3 to enable cross-chain clause triggers.
///
///      Architecture:
///      ┌─────────────────────────────────────────────────────────────────────────┐
///      │ Chain A (Source)                   Chain B (Destination)                 │
///      │                                                                         │
///      │  Agreement Proxy ─────┐                           ┌───── Agreement Proxy │
///      │  (has CrossChain-    │                           │  (has CrossChain-    │
///      │   ClauseLogicV3)     │                           │   ClauseLogicV3)     │
///      │         │            │                           │          ▲           │
///      │         ▼            ▼                           ▼          │           │
///      │  CrossChainControllerV3  ────── CCIP ──────  CrossChainControllerV3     │
///      │  (this contract)                            (partner controller)         │
///      └─────────────────────────────────────────────────────────────────────────┘
///
///      Flow:
///      1. Agreement on Chain A calls controller.sendMessage()
///      2. Controller validates, builds CCIP message, sends via router
///      3. CCIP delivers to partner controller on Chain B
///      4. Partner controller calls destination Agreement's receiveCrossChainMessage()
///      5. Agreement dispatches to appropriate clause handler
contract CrossChainControllerV3 is CCIPReceiver, Ownable {
    using SafeERC20 for IERC20;

    // =============================================================
    // STATE
    // =============================================================

    /// @notice LINK token address on this chain
    address public linkToken;

    /// @notice Mapping from chain selector to partner controller address
    mapping(uint64 => address) public partnerControllers;

    /// @notice Mapping from chain selector to whether it's allowed
    mapping(uint64 => bool) public allowedChains;

    /// @notice Mapping from agreement address to whether it's authorized to send
    mapping(address => bool) public authorizedAgreements;

    /// @notice Mapping from chain selector + source agreement to whether it's allowed to receive
    mapping(uint64 => mapping(address => bool)) public allowedSources;

    /// @notice Default gas limit for cross-chain messages
    uint256 public defaultGasLimit = 300_000;

    // =============================================================
    // STRUCTS
    // =============================================================

    /// @notice Payload sent cross-chain
    struct CrossChainPayload {
        address sourceAgreement;
        address destinationAgreement;
        bytes32 contentHash;
        uint8 action;
        bytes extraData;
    }

    // =============================================================
    // ERRORS
    // =============================================================

    error InvalidChainSelector();
    error InvalidPartnerController();
    error InvalidSourceAgreement();
    error NotAuthorizedAgreement(address agreement);
    error InsufficientFee(uint256 required, uint256 provided);
    error InvalidFeeToken();
    error TransferFailed();
    error PartnerControllerNotSet(uint64 chainSelector);

    // =============================================================
    // EVENTS
    // =============================================================

    event CrossChainMessageSent(
        bytes32 indexed messageId,
        uint64 indexed destinationChainSelector,
        address sourceAgreement,
        address destinationAgreement,
        bytes32 contentHash,
        uint8 action
    );

    event CrossChainMessageReceived(
        bytes32 indexed messageId,
        uint64 indexed sourceChainSelector,
        address sourceAgreement,
        address destinationAgreement,
        bytes32 contentHash,
        uint8 action
    );

    event PartnerControllerSet(uint64 indexed chainSelector, address indexed controller);
    event ChainAllowanceSet(uint64 indexed chainSelector, bool allowed);
    event AgreementAuthorized(address indexed agreement, bool authorized);
    event SourceAllowanceSet(uint64 indexed chainSelector, address indexed sourceAgreement, bool allowed);

    // =============================================================
    // CONSTRUCTOR
    // =============================================================

    /// @param router The CCIP router address for this chain
    /// @param _linkToken The LINK token address (address(0) if not using LINK)
    constructor(address router, address _linkToken) CCIPReceiver(router) Ownable(msg.sender) {
        linkToken = _linkToken;
    }

    // =============================================================
    // ADMIN FUNCTIONS
    // =============================================================

    /// @notice Set the LINK token address
    /// @param _linkToken The LINK token address
    function setLinkToken(address _linkToken) external onlyOwner {
        linkToken = _linkToken;
    }

    /// @notice Set the partner controller on another chain
    /// @param chainSelector The CCIP chain selector
    /// @param controller The CrossChainControllerV3 address on that chain
    function setPartnerController(uint64 chainSelector, address controller) external onlyOwner {
        partnerControllers[chainSelector] = controller;
        emit PartnerControllerSet(chainSelector, controller);
    }

    /// @notice Allow or disallow a chain for cross-chain messaging
    /// @param chainSelector The CCIP chain selector
    /// @param allowed Whether the chain is allowed
    function setAllowedChain(uint64 chainSelector, bool allowed) external onlyOwner {
        allowedChains[chainSelector] = allowed;
        emit ChainAllowanceSet(chainSelector, allowed);
    }

    /// @notice Authorize or deauthorize an agreement to send cross-chain messages
    /// @param agreement The agreement address
    /// @param authorized Whether the agreement is authorized
    function setAuthorizedAgreement(address agreement, bool authorized) external onlyOwner {
        authorizedAgreements[agreement] = authorized;
        emit AgreementAuthorized(agreement, authorized);
    }

    /// @notice Allow or disallow a source for receiving messages
    /// @param chainSelector The source chain selector
    /// @param sourceAgreement The source agreement address
    /// @param allowed Whether the source is allowed
    function setAllowedSource(uint64 chainSelector, address sourceAgreement, bool allowed) external onlyOwner {
        allowedSources[chainSelector][sourceAgreement] = allowed;
        emit SourceAllowanceSet(chainSelector, sourceAgreement, allowed);
    }

    /// @notice Set the default gas limit for cross-chain messages
    /// @param gasLimit The new default gas limit
    function setDefaultGasLimit(uint256 gasLimit) external onlyOwner {
        defaultGasLimit = gasLimit;
    }

    // =============================================================
    // SEND MESSAGE
    // =============================================================

    /// @notice Send a cross-chain message (pay with native token)
    /// @param destinationChainSelector The destination chain's CCIP selector
    /// @param destinationAgreement The agreement address on the destination chain
    /// @param contentHash The content hash being referenced
    /// @param action The action to trigger on the destination
    /// @param extraData Additional data for the action
    /// @return messageId The CCIP message ID
    function sendMessage(
        uint64 destinationChainSelector,
        address destinationAgreement,
        bytes32 contentHash,
        uint8 action,
        bytes calldata extraData
    ) external payable returns (bytes32 messageId) {
        return sendMessageWithFeeToken(
            destinationChainSelector, destinationAgreement, contentHash, action, extraData, address(0)
        );
    }

    /// @notice Send a cross-chain message with choice of fee token
    /// @param destinationChainSelector The destination chain's CCIP selector
    /// @param destinationAgreement The agreement address on the destination chain
    /// @param contentHash The content hash being referenced
    /// @param action The action to trigger on the destination
    /// @param extraData Additional data for the action
    /// @param feeToken The token to pay fees with (address(0) for native, or LINK)
    /// @return messageId The CCIP message ID
    function sendMessageWithFeeToken(
        uint64 destinationChainSelector,
        address destinationAgreement,
        bytes32 contentHash,
        uint8 action,
        bytes calldata extraData,
        address feeToken
    ) public payable returns (bytes32 messageId) {
        // Validate caller is authorized
        if (!authorizedAgreements[msg.sender]) {
            revert NotAuthorizedAgreement(msg.sender);
        }

        // Validate destination chain
        if (!allowedChains[destinationChainSelector]) {
            revert InvalidChainSelector();
        }

        // Get partner controller
        address partnerController = partnerControllers[destinationChainSelector];
        if (partnerController == address(0)) {
            revert PartnerControllerNotSet(destinationChainSelector);
        }

        // Validate fee token
        bool payInLink = feeToken != address(0);
        if (payInLink && feeToken != linkToken) revert InvalidFeeToken();

        // Build payload
        CrossChainPayload memory payload = CrossChainPayload({
            sourceAgreement: msg.sender,
            destinationAgreement: destinationAgreement,
            contentHash: contentHash,
            action: action,
            extraData: extraData
        });

        // Build CCIP message
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(partnerController),
            data: abi.encode(payload),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({gasLimit: defaultGasLimit})),
            feeToken: feeToken
        });

        // Get the fee
        IRouterClient router = IRouterClient(this.getRouter());
        uint256 fee = router.getFee(destinationChainSelector, message);

        if (payInLink) {
            // Pay with LINK
            IERC20(linkToken).safeTransferFrom(msg.sender, address(this), fee);
            IERC20(linkToken).forceApprove(address(router), fee);
            messageId = router.ccipSend(destinationChainSelector, message);
        } else {
            // Pay with native token
            if (msg.value < fee) revert InsufficientFee(fee, msg.value);
            messageId = router.ccipSend{value: fee}(destinationChainSelector, message);

            // Refund excess
            if (msg.value > fee) {
                (bool success,) = msg.sender.call{value: msg.value - fee}("");
                if (!success) revert TransferFailed();
            }
        }

        emit CrossChainMessageSent(
            messageId, destinationChainSelector, msg.sender, destinationAgreement, contentHash, action
        );
    }

    /// @notice Get the fee required to send a cross-chain message
    /// @param destinationChainSelector The destination chain's CCIP selector
    /// @param destinationAgreement The agreement address on the destination chain
    /// @param contentHash The content hash being referenced
    /// @param action The action to trigger on the destination
    /// @param extraData Additional data for the action
    /// @return fee The fee in native token
    function getFee(
        uint64 destinationChainSelector,
        address destinationAgreement,
        bytes32 contentHash,
        uint8 action,
        bytes calldata extraData
    ) external view returns (uint256 fee) {
        return getFeeWithToken(
            destinationChainSelector, destinationAgreement, contentHash, action, extraData, address(0)
        );
    }

    /// @notice Get the fee required to send a cross-chain message with specific fee token
    /// @param destinationChainSelector The destination chain's CCIP selector
    /// @param destinationAgreement The agreement address on the destination chain
    /// @param contentHash The content hash being referenced
    /// @param action The action to trigger on the destination
    /// @param extraData Additional data for the action
    /// @param feeToken The token to pay fees with (address(0) for native, or LINK)
    /// @return fee The fee amount
    function getFeeWithToken(
        uint64 destinationChainSelector,
        address destinationAgreement,
        bytes32 contentHash,
        uint8 action,
        bytes calldata extraData,
        address feeToken
    ) public view returns (uint256 fee) {
        address partnerController = partnerControllers[destinationChainSelector];
        if (partnerController == address(0)) return 0;

        CrossChainPayload memory payload = CrossChainPayload({
            sourceAgreement: address(0), // Will be filled by sender
            destinationAgreement: destinationAgreement,
            contentHash: contentHash,
            action: action,
            extraData: extraData
        });

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(partnerController),
            data: abi.encode(payload),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({gasLimit: defaultGasLimit})),
            feeToken: feeToken
        });

        IRouterClient router = IRouterClient(this.getRouter());
        fee = router.getFee(destinationChainSelector, message);
    }

    // =============================================================
    // RECEIVE MESSAGE
    // =============================================================

    /// @notice Handle incoming CCIP message
    /// @dev Called by the CCIP router
    function _ccipReceive(Client.Any2EVMMessage memory message) internal override {
        uint64 sourceChainSelector = message.sourceChainSelector;

        // Decode payload
        CrossChainPayload memory payload = abi.decode(message.data, (CrossChainPayload));

        // Verify source is allowed
        if (!allowedSources[sourceChainSelector][payload.sourceAgreement]) {
            revert InvalidSourceAgreement();
        }

        emit CrossChainMessageReceived(
            message.messageId,
            sourceChainSelector,
            payload.sourceAgreement,
            payload.destinationAgreement,
            payload.contentHash,
            payload.action
        );

        // Forward to destination agreement
        ICrossChainReceiver(payload.destinationAgreement)
            .receiveCrossChainMessage(
                sourceChainSelector, payload.sourceAgreement, payload.contentHash, payload.action, payload.extraData
            );
    }

    // =============================================================
    // RECEIVE NATIVE TOKEN
    // =============================================================

    receive() external payable {}
}

/// @notice Interface that Agreements must implement to receive cross-chain messages
interface ICrossChainReceiver {
    /// @notice Called by the controller when a cross-chain message arrives
    /// @param sourceChainSelector The source chain's CCIP selector
    /// @param sourceAgreement The source agreement address
    /// @param contentHash The content hash being referenced
    /// @param action The action to execute
    /// @param extraData Additional data for the action
    function receiveCrossChainMessage(
        uint64 sourceChainSelector,
        address sourceAgreement,
        bytes32 contentHash,
        uint8 action,
        bytes calldata extraData
    ) external;
}
