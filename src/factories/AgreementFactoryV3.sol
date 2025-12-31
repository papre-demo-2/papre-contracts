// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title AgreementFactoryV3
/// @notice Factory for deploying Agreement proxies (ERC-1167 clones)
/// @dev Supports template-based Agreement creation with deterministic addresses.
///
///      ARCHITECTURE:
///      - Each template type (freelance, milestone, etc.) has a registered implementation
///      - Factory deploys minimal proxies (clones) pointing to implementations
///      - Deterministic addresses via CREATE2 using (typeId, creator, salt)
///
///      USAGE:
///      1. Owner registers implementation: registerTemplate(typeId, name, impl)
///      2. Users create agreements: createAgreement(typeId, salt, initData)
///      3. Created agreement is a clone that delegates to implementation
contract AgreementFactoryV3 is Ownable {
    using Clones for address;

    // ═══════════════════════════════════════════════════════════════
    //                           STORAGE
    // ═══════════════════════════════════════════════════════════════

    struct TemplateInfo {
        string name;
        address implementation;
        bool active;
    }

    /// @notice Registered templates by typeId
    mapping(bytes32 => TemplateInfo) public templates;

    /// @notice List of all registered type IDs
    bytes32[] public registeredTypes;

    /// @notice All deployed agreements
    address[] public allAgreements;

    /// @notice Check if address is an agreement created by this factory
    mapping(address => bool) public isAgreement;

    /// @notice Get the type ID of an agreement
    mapping(address => bytes32) public agreementType;

    /// @notice Get the creator of an agreement
    mapping(address => address) public agreementCreator;

    /// @notice Get agreements created by a user
    mapping(address => address[]) public userAgreements;

    // ═══════════════════════════════════════════════════════════════
    //                           EVENTS
    // ═══════════════════════════════════════════════════════════════

    event ImplementationRegistered(
        bytes32 indexed typeId,
        string name,
        address indexed implementation
    );

    event ImplementationUpdated(
        bytes32 indexed typeId,
        address indexed oldImplementation,
        address indexed newImplementation
    );

    event ImplementationDeactivated(bytes32 indexed typeId);

    event AgreementCreated(
        address indexed agreement,
        bytes32 indexed typeId,
        address indexed creator,
        bytes32 salt
    );

    // ═══════════════════════════════════════════════════════════════
    //                           ERRORS
    // ═══════════════════════════════════════════════════════════════

    error TemplateNotRegistered(bytes32 typeId);
    error TemplateNotActive(bytes32 typeId);
    error TemplateAlreadyRegistered(bytes32 typeId);
    error ZeroAddress();
    error InitializationFailed();

    // ═══════════════════════════════════════════════════════════════
    //                         CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════

    constructor(address _owner) Ownable(_owner) {}

    // ═══════════════════════════════════════════════════════════════
    //                    TEMPLATE REGISTRATION
    // ═══════════════════════════════════════════════════════════════

    /// @notice Register a new template implementation
    /// @param _typeId Unique identifier for the template type (e.g., keccak256("freelance"))
    /// @param _name Human-readable name
    /// @param _implementation Address of the implementation contract
    function registerTemplate(
        bytes32 _typeId,
        string calldata _name,
        address _implementation
    ) external onlyOwner {
        if (_implementation == address(0)) revert ZeroAddress();
        if (templates[_typeId].implementation != address(0)) {
            revert TemplateAlreadyRegistered(_typeId);
        }

        templates[_typeId] = TemplateInfo({
            name: _name,
            implementation: _implementation,
            active: true
        });

        registeredTypes.push(_typeId);

        emit ImplementationRegistered(_typeId, _name, _implementation);
    }

    /// @notice Update a template's implementation
    /// @param _typeId The template type ID
    /// @param _newImplementation New implementation address
    function updateTemplate(
        bytes32 _typeId,
        address _newImplementation
    ) external onlyOwner {
        if (_newImplementation == address(0)) revert ZeroAddress();
        if (templates[_typeId].implementation == address(0)) {
            revert TemplateNotRegistered(_typeId);
        }

        address oldImpl = templates[_typeId].implementation;
        templates[_typeId].implementation = _newImplementation;

        emit ImplementationUpdated(_typeId, oldImpl, _newImplementation);
    }

    /// @notice Deactivate a template (prevents new deployments)
    /// @param _typeId The template type ID
    function deactivateTemplate(bytes32 _typeId) external onlyOwner {
        if (templates[_typeId].implementation == address(0)) {
            revert TemplateNotRegistered(_typeId);
        }
        templates[_typeId].active = false;
        emit ImplementationDeactivated(_typeId);
    }

    /// @notice Reactivate a deactivated template
    /// @param _typeId The template type ID
    function reactivateTemplate(bytes32 _typeId) external onlyOwner {
        if (templates[_typeId].implementation == address(0)) {
            revert TemplateNotRegistered(_typeId);
        }
        templates[_typeId].active = true;
    }

    // ═══════════════════════════════════════════════════════════════
    //                    AGREEMENT CREATION
    // ═══════════════════════════════════════════════════════════════

    /// @notice Create a new Agreement instance
    /// @param _typeId Template type ID (e.g., keccak256("freelance"))
    /// @param salt Unique salt for deterministic address
    /// @param initData Encoded initialize() call data
    /// @return agreement The deployed Agreement address
    function createAgreement(
        bytes32 _typeId,
        bytes32 salt,
        bytes calldata initData
    ) external returns (address agreement) {
        return _createAgreement(_typeId, salt, initData, 0);
    }

    /// @notice Create a new Agreement instance with ETH value
    /// @param _typeId Template type ID
    /// @param salt Unique salt for deterministic address
    /// @param initData Encoded initialize() call data
    /// @return agreement The deployed Agreement address
    function createAgreementWithValue(
        bytes32 _typeId,
        bytes32 salt,
        bytes calldata initData
    ) external payable returns (address agreement) {
        return _createAgreement(_typeId, salt, initData, msg.value);
    }

    /// @dev Internal implementation of agreement creation
    function _createAgreement(
        bytes32 _typeId,
        bytes32 salt,
        bytes calldata initData,
        uint256 value
    ) internal returns (address agreement) {
        TemplateInfo storage template = templates[_typeId];

        if (template.implementation == address(0)) {
            revert TemplateNotRegistered(_typeId);
        }
        if (!template.active) {
            revert TemplateNotActive(_typeId);
        }

        // Create deterministic salt from typeId, creator, and user salt
        bytes32 finalSalt = keccak256(abi.encode(_typeId, msg.sender, salt));

        // Deploy clone
        agreement = template.implementation.cloneDeterministic(finalSalt);

        // Initialize if initData provided
        if (initData.length > 0) {
            (bool success, ) = agreement.call{value: value}(initData);
            if (!success) revert InitializationFailed();
        }

        // Track the agreement
        isAgreement[agreement] = true;
        agreementType[agreement] = _typeId;
        agreementCreator[agreement] = msg.sender;
        allAgreements.push(agreement);
        userAgreements[msg.sender].push(agreement);

        emit AgreementCreated(agreement, _typeId, msg.sender, salt);
    }

    // ═══════════════════════════════════════════════════════════════
    //                      VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    /// @notice Get template info by type ID
    /// @param _typeId The template type ID
    /// @return name Template name
    /// @return implementation Implementation address
    function getTemplateInfo(bytes32 _typeId) external view returns (
        string memory name,
        address implementation
    ) {
        TemplateInfo storage info = templates[_typeId];
        return (info.name, info.implementation);
    }

    /// @notice Get the implementation address for a type ID
    function implementations(bytes32 _typeId) external view returns (address) {
        return templates[_typeId].implementation;
    }

    /// @notice Predict the address of an agreement before creation
    /// @param _typeId Template type ID
    /// @param _creator The creator's address
    /// @param salt The salt value
    /// @return The predicted address
    function predictAddress(
        bytes32 _typeId,
        address _creator,
        bytes32 salt
    ) external view returns (address) {
        TemplateInfo storage template = templates[_typeId];
        if (template.implementation == address(0)) {
            revert TemplateNotRegistered(_typeId);
        }

        bytes32 finalSalt = keccak256(abi.encode(_typeId, _creator, salt));
        return template.implementation.predictDeterministicAddress(finalSalt, address(this));
    }

    /// @notice Get all deployed agreements
    function getAllAgreements() external view returns (address[] memory) {
        return allAgreements;
    }

    /// @notice Get the total number of deployed agreements
    function getAgreementCount() external view returns (uint256) {
        return allAgreements.length;
    }

    /// @notice Get all registered template types
    function getRegisteredTypes() external view returns (bytes32[] memory) {
        return registeredTypes;
    }

    /// @notice Get the number of registered templates
    function getTemplateCount() external view returns (uint256) {
        return registeredTypes.length;
    }

    /// @notice Get agreements created by a user
    function getUserAgreements(address user) external view returns (address[] memory) {
        return userAgreements[user];
    }
}
