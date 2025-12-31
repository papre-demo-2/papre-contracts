// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @title AgreementBaseV3
/// @notice Base contract for v3 Agreement proxies
/// @dev Provides initialization, pause/unpause, party management, and clause delegation helpers.
///      All v3 Agreements inherit from this base and compose clauses via delegatecall.
///
///      Key Features:
///      - ERC-7201 namespaced storage for collision-free multi-clause composition
///      - Party-based access control (creator, parties)
///      - Pause/unpause for emergency stops
///      - Helper functions for delegating to clause logic contracts
///
///      Delegatecall Pattern:
///      When an Agreement calls _delegateToClause(), the clause logic executes
///      in the Agreement's storage context:
///      - msg.sender = original caller (preserved)
///      - address(this) = Agreement proxy address
///      - Storage reads/writes go to Agreement's storage
abstract contract AgreementBaseV3 is Initializable {

    // ═══════════════════════════════════════════════════════════════
    //                    ERC-7201 STORAGE LAYOUT
    // ═══════════════════════════════════════════════════════════════

    /// @custom:storage-location erc7201:papre.agreement.base.storage
    struct BaseStorage {
        bool initialized;
        bool paused;
        address creator;
        address[] parties;
        mapping(address => bool) isParty;
    }

    // keccak256(abi.encode(uint256(keccak256("papre.agreement.base.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BASE_STORAGE_SLOT =
        0x4a8c5d2e1f3b6a7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b00;

    function _getBaseStorage() internal pure returns (BaseStorage storage $) {
        assembly {
            $.slot := BASE_STORAGE_SLOT
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //                          ERRORS
    // ═══════════════════════════════════════════════════════════════

    error AlreadyInitialized();
    error NotInitialized();
    error Paused();
    error NotCreator();
    error NotParty();
    error ClauseCallFailed(bytes reason);
    error ZeroAddress();

    // ═══════════════════════════════════════════════════════════════
    //                          EVENTS
    // ═══════════════════════════════════════════════════════════════

    event AgreementInitialized(address indexed creator);
    event AgreementPaused(address indexed by);
    event AgreementUnpaused(address indexed by);
    event PartyAdded(address indexed party);
    event PartyRemoved(address indexed party);

    // ═══════════════════════════════════════════════════════════════
    //                        MODIFIERS
    // ═══════════════════════════════════════════════════════════════

    modifier whenNotPaused() {
        if (_getBaseStorage().paused) revert Paused();
        _;
    }

    modifier onlyCreator() {
        if (msg.sender != _getBaseStorage().creator) revert NotCreator();
        _;
    }

    modifier onlyParty() {
        if (!_getBaseStorage().isParty[msg.sender]) revert NotParty();
        _;
    }

    // ═══════════════════════════════════════════════════════════════
    //                    INITIALIZATION
    // ═══════════════════════════════════════════════════════════════

    /// @notice Initialize the base Agreement
    /// @param _creator The Agreement creator/owner
    /// @dev Call this in your Agreement's initialize() function
    function __AgreementBase_init(address _creator) internal onlyInitializing {
        if (_creator == address(0)) revert ZeroAddress();

        BaseStorage storage $ = _getBaseStorage();
        $.creator = _creator;
        $.initialized = true;
        $.isParty[_creator] = true;
        $.parties.push(_creator);

        emit AgreementInitialized(_creator);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    CLAUSE DELEGATION
    // ═══════════════════════════════════════════════════════════════

    /// @notice Delegate a call to a clause logic contract
    /// @param clauseLogic The clause logic contract address
    /// @param data The encoded function call
    /// @return result The returned data
    /// @dev Uses delegatecall - clause executes in Agreement's storage context
    function _delegateToClause(
        address clauseLogic,
        bytes memory data
    ) internal returns (bytes memory result) {
        (bool success, bytes memory returnData) = clauseLogic.delegatecall(data);
        if (!success) {
            // Bubble up revert reason if available
            if (returnData.length > 0) {
                assembly {
                    revert(add(returnData, 32), mload(returnData))
                }
            }
            revert ClauseCallFailed(returnData);
        }
        return returnData;
    }

    /// @notice Delegate a view call to a clause logic contract
    /// @dev Still uses delegatecall internally. Call via eth_call for gas-free reads.
    ///      Cannot be marked view due to delegatecall.
    function _delegateViewToClause(
        address clauseLogic,
        bytes memory data
    ) internal returns (bytes memory result) {
        return _delegateToClause(clauseLogic, data);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    PARTY MANAGEMENT
    // ═══════════════════════════════════════════════════════════════

    /// @notice Add a party to the Agreement
    /// @param party Address to add as party
    function _addParty(address party) internal {
        if (party == address(0)) revert ZeroAddress();

        BaseStorage storage $ = _getBaseStorage();
        if (!$.isParty[party]) {
            $.isParty[party] = true;
            $.parties.push(party);
            emit PartyAdded(party);
        }
    }

    /// @notice Add multiple parties to the Agreement
    /// @param _parties Addresses to add as parties
    function _addParties(address[] memory _parties) internal {
        for (uint256 i = 0; i < _parties.length; i++) {
            _addParty(_parties[i]);
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //                    PAUSE / UNPAUSE
    // ═══════════════════════════════════════════════════════════════

    /// @notice Pause the Agreement (blocks all whenNotPaused functions)
    function pause() external onlyCreator {
        _getBaseStorage().paused = true;
        emit AgreementPaused(msg.sender);
    }

    /// @notice Unpause the Agreement
    function unpause() external onlyCreator {
        _getBaseStorage().paused = false;
        emit AgreementUnpaused(msg.sender);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    /// @notice Get the Agreement creator
    function creator() external view returns (address) {
        return _getBaseStorage().creator;
    }

    /// @notice Check if the Agreement is paused
    function isPaused() external view returns (bool) {
        return _getBaseStorage().paused;
    }

    /// @notice Get all parties to the Agreement
    function getParties() external view returns (address[] memory) {
        return _getBaseStorage().parties;
    }

    /// @notice Check if an address is a party to the Agreement
    function isParty(address account) external view returns (bool) {
        return _getBaseStorage().isParty[account];
    }

    /// @notice Get the number of parties
    function getPartyCount() external view returns (uint256) {
        return _getBaseStorage().parties.length;
    }
}
