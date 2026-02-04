// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {PartyEscrowProxy} from "./PartyEscrowProxy.sol";

/// @title PartyEscrowFactory
/// @notice Factory for deploying PartyEscrowProxy instances via ERC-1167 minimal proxies
/// @dev Uses CREATE2 for deterministic addresses. Either party can deploy.
///
///      GAS SAVINGS:
///      - Full deployment: ~200k gas
///      - Minimal proxy: ~50k gas (75% savings)
///
///      DETERMINISTIC ADDRESSES:
///      - predictAddress() returns the address before deployment
///      - Useful for pre-funding or linking to agreements
///
contract PartyEscrowFactory {
    using Clones for address;

    // ═══════════════════════════════════════════════════════════════
    //                          STATE
    // ═══════════════════════════════════════════════════════════════

    /// @notice The PartyEscrowProxy implementation contract
    address public immutable implementation;

    /// @notice Track all deployed proxies
    address[] private _proxies;

    /// @notice Check if address is a factory-deployed proxy
    mapping(address => bool) public isProxy;

    /// @notice Get proxies by party address
    mapping(address => address[]) public proxyesByParty;

    // ═══════════════════════════════════════════════════════════════
    //                          ERRORS
    // ═══════════════════════════════════════════════════════════════

    error ZeroAddress();
    error ProxyAlreadyExists();
    error InitializationFailed();

    // ═══════════════════════════════════════════════════════════════
    //                          EVENTS
    // ═══════════════════════════════════════════════════════════════

    event ProxyCreated(
        address indexed proxy,
        address indexed client,
        address indexed contractor,
        address token,
        PartyEscrowProxy.DisputeMode disputeMode,
        uint256 disputeTimeoutDays,
        bytes32 salt
    );

    // ═══════════════════════════════════════════════════════════════
    //                       CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════

    constructor() {
        // Deploy the implementation contract
        implementation = address(new PartyEscrowProxy());
    }

    // ═══════════════════════════════════════════════════════════════
    //                    FACTORY FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    /// @notice Create a new PartyEscrowProxy for an agreement
    /// @param client The client address (depositor)
    /// @param contractor The contractor address (beneficiary)
    /// @param token Payment token (address(0) for native ETH/AVAX)
    /// @param disputeMode How disputes are resolved (0=FROZEN, 1=AUTO_REFUND, 2=AUTO_RELEASE)
    /// @param disputeTimeoutDays Days before auto-resolution (ignored for FROZEN mode)
    /// @param salt Unique salt for deterministic address
    /// @return proxy The deployed proxy address
    function createEscrow(
        address client,
        address contractor,
        address token,
        PartyEscrowProxy.DisputeMode disputeMode,
        uint256 disputeTimeoutDays,
        bytes32 salt
    ) external returns (address proxy) {
        if (client == address(0)) revert ZeroAddress();
        if (contractor == address(0)) revert ZeroAddress();

        // Compute deterministic address
        bytes32 finalSalt = _computeSalt(client, contractor, salt);
        address predicted = implementation.predictDeterministicAddress(finalSalt, address(this));

        // Check not already deployed
        if (isProxy[predicted]) revert ProxyAlreadyExists();

        // Deploy minimal proxy
        proxy = implementation.cloneDeterministic(finalSalt);

        // Initialize
        try PartyEscrowProxy(payable(proxy)).initialize(client, contractor, token, disputeMode, disputeTimeoutDays) {}
        catch {
            revert InitializationFailed();
        }

        // Track
        _proxies.push(proxy);
        isProxy[proxy] = true;
        proxyesByParty[client].push(proxy);
        proxyesByParty[contractor].push(proxy);

        emit ProxyCreated(proxy, client, contractor, token, disputeMode, disputeTimeoutDays, salt);
    }

    /// @notice Predict the address of a proxy before deployment
    /// @param client The client address
    /// @param contractor The contractor address
    /// @param salt Unique salt
    /// @return The predicted proxy address
    function predictAddress(address client, address contractor, bytes32 salt) external view returns (address) {
        bytes32 finalSalt = _computeSalt(client, contractor, salt);
        return implementation.predictDeterministicAddress(finalSalt, address(this));
    }

    // ═══════════════════════════════════════════════════════════════
    //                        VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    /// @notice Get all deployed proxies
    function getAllProxies() external view returns (address[] memory) {
        return _proxies;
    }

    /// @notice Get total number of deployed proxies
    function getProxyCount() external view returns (uint256) {
        return _proxies.length;
    }

    /// @notice Get all proxies for a party
    /// @param party The party address (client or contractor)
    function getProxiesForParty(address party) external view returns (address[] memory) {
        return proxyesByParty[party];
    }

    // ═══════════════════════════════════════════════════════════════
    //                          INTERNAL
    // ═══════════════════════════════════════════════════════════════

    /// @notice Compute the final salt from client, contractor, and user salt
    /// @dev This ensures the same parties with the same salt always get the same address
    function _computeSalt(address client, address contractor, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encode(client, contractor, salt));
    }
}
