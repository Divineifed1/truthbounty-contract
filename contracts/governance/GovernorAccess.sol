// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title GovernorAccess
 * @notice Library for DAO governance role management and access control
 * @dev Provides role-based access control with governance voting integration
 * 
 * Key Features:
 * - Separates administrative roles from governance roles
 * - Supports time-locked role grants (proposals must pass before execution)
 * - Tracks role assignment history for transparency
 * - Integrates with OpenZeppelin's AccessControl
 */
library GovernorAccess {
    // ============ Custom Errors ============
    
    error InvalidRole(bytes32 role);
    error InvalidAddress(address account);
    error NotGovernance(address caller);
    error NotProposalExecutor(address caller);
    error RoleAlreadyGranted(address account, bytes32 role);
    error RoleNotGranted(address account, bytes32 role);
    error NullProposalId();
    error ProposalNotPending(bytes32 proposalId);
    error ProposalAlreadyExecuted(bytes32 proposalId);

    // ============ Constants ============
    
    /// @notice Role for governance configuration
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    
    /// @notice Role for executing approved proposals
    bytes32 public constant PROPOSAL_EXECUTOR_ROLE = keccak256("PROPOSAL_EXECUTOR_ROLE");
    
    /// @notice Role for managing parameter updates
    bytes32 public constant PARAMETER_MANAGER_ROLE = keccak256("PARAMETER_MANAGER_ROLE");
    
    /// @notice Role for emergency actions
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    // ============ Data Structures ============

    /// @notice Tracks pending role assignment proposals
    struct RoleProposal {
        bytes32 proposalId;
        address account;
        bytes32 role;
        bool grant;
        uint256 executeAfter;
        bool executed;
        address proposer;
        uint256 createdAt;
    }

    /// @notice Role assignment history
    struct RoleAssignment {
        address account;
        bytes32 role;
        bool granted;
        uint256 timestamp;
        bytes32 proposalId;
    }

    // ============ Events ============

    event RoleProposalCreated(
        bytes32 indexed proposalId,
        address indexed account,
        bytes32 indexed role,
        bool grant,
        address proposer
    );

    event RoleProposalExecuted(
        bytes32 indexed proposalId,
        address indexed account,
        bytes32 indexed role,
        bool grant,
        address executor
    );

    event RoleProposalCancelled(
        bytes32 indexed proposalId,
        address indexed canceller
    );

    event RoleAssignmentRecorded(
        address indexed account,
        bytes32 indexed role,
        bool indexed grant,
        uint256 timestamp,
        bytes32 proposalId
    );

    // ============ Helper Functions ============

    /**
     * @notice Generate a deterministic proposal ID from parameters
     * @param account The account for the proposal
     * @param role The role identifier
     * @param grant True for grant, false for revoke
     * @param salt Random salt for uniqueness
     * @return The generated proposal ID
     */
    function generateProposalId(
        address account,
        bytes32 role,
        bool grant,
        uint256 salt
    ) internal view returns (bytes32) {
        return keccak256(abi.encode(
            account,
            role,
            grant,
            salt,
            block.timestamp
        ));
    }

    /**
     * @notice Validate role bytes32
     * @param role The role to validate
     * @return True if valid
     */
    function isValidRole(bytes32 role) internal pure returns (bool) {
        return role != bytes32(0);
    }

    /**
     * @notice Get human-readable role name
     * @param role The role identifier
     * @return The role name string
     */
    function getRoleName(bytes32 role) internal pure returns (string memory) {
        if (role == GOVERNANCE_ROLE) return "GOVERNANCE";
        if (role == PROPOSAL_EXECUTOR_ROLE) return "PROPOSAL_EXECUTOR";
        if (role == PARAMETER_MANAGER_ROLE) return "PARAMETER_MANAGER";
        if (role == EMERGENCY_ROLE) return "EMERGENCY";
        if (role == AccessControl.DEFAULT_ADMIN_ROLE) return "DEFAULT_ADMIN";
        return "UNKNOWN";
    }
}

/**
 * @title GovernorAccessControl
 * @notice Integration contract for GovernorAccess library functionality
 * @dev Provides full role management with governance proposal flow
 */
abstract contract GovernorAccessControl is AccessControl {
    // ============ State Variables ============
    
    using GovernorAccess for *;
    
    /// @notice Mapping of pending role proposals
    mapping(bytes32 => GovernorAccess.RoleProposal) public roleProposals;
    
    /// @notice Role assignment history per user
    mapping(address => mapping(bytes32 => GovernorAccess.RoleAssignment[])) 
        public roleAssignmentHistory;
    
    /// @notice Minimum voting period before execution (1 hour)
    uint256 public constant MIN_EXECUTION_DELAY = 1 hours;
    
    /// @notice Maximum time to execute after voting passes (7 days)
    uint256 public constant MAX_EXECUTION_WINDOW = 7 days;

    // ============ Modifier ============
    
    modifier onlyGovernance() {
        if (!hasRole(GovernorAccess.GOVERNANCE_ROLE, msg.sender)) {
            revert GovernorAccess.NotGovernance(msg.sender);
        }
        _;
    }
    
    modifier onlyProposalExecutor() {
        if (!hasRole(GovernorAccess.PROPOSAL_EXECUTOR_ROLE, msg.sender) && 
            !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert GovernorAccess.NotProposalExecutor(msg.sender);
        }
        _;
    }

    // ============ Role Proposal Functions ============

    /**
     * @notice Create a proposal to grant or revoke a role
     * @param account The account to grant/revoke role
     * @param role The role identifier
     * @param grant True to grant, false to revoke
     * @return proposalId The generated proposal ID
     */
    function createRoleProposal(
        address account,
        bytes32 role,
        bool grant
    ) internal returns (bytes32 proposalId) {
        if (account == address(0)) revert GovernorAccess.InvalidAddress(address(0));
        if (!GovernorAccess.isValidRole(role)) revert GovernorAccess.InvalidRole(role);
        
        // Check current status
        if (grant) {
            if (hasRole(role, account)) revert GovernorAccess.RoleAlreadyGranted(account, role);
        } else {
            if (!hasRole(role, account)) revert GovernorAccess.RoleNotGranted(account, role);
        }
        
        // Generate unique proposal ID
        proposalId = GovernorAccess.generateProposalId(
            account,
            role,
            grant,
            block.timestamp
        );
        
        // Store proposal
        roleProposals[proposalId] = GovernorAccess.RoleProposal({
            proposalId: proposalId,
            account: account,
            role: role,
            grant: grant,
            executeAfter: block.timestamp + MIN_EXECUTION_DELAY,
            executed: false,
            proposer: msg.sender,
            createdAt: block.timestamp
        });
        
        emit GovernorAccess.RoleProposalCreated(
            proposalId,
            account,
            role,
            grant,
            msg.sender
        );
    }

    /**
     * @notice Execute an approved role proposal
     * @param proposalId The proposal ID to execute
     */
    function executeRoleProposal(bytes32 proposalId) internal {
        GovernorAccess.RoleProposal storage proposal = roleProposals[proposalId];
        
        if (proposal.proposalId == bytes32(0)) revert GovernorAccess.NullProposalId();
        if (proposal.executed) revert GovernorAccess.ProposalAlreadyExecuted(proposalId);
        if (block.timestamp < proposal.executeAfter) revert GovernorAccess.ProposalNotPending(proposalId);
        if (block.timestamp > proposal.executeAfter + MAX_EXECUTION_WINDOW) {
            revert GovernorAccess.ProposalNotPending(proposalId);
        }
        
        proposal.executed = true;
        
        // Execute the role assignment
        if (proposal.grant) {
            _grantRole(proposal.role, proposal.account);
        } else {
            _revokeRole(proposal.role, proposal.account);
        }
        
        // Record in history
        roleAssignmentHistory[proposal.account][proposal.role].push(
            GovernorAccess.RoleAssignment({
                account: proposal.account,
                role: proposal.role,
                granted: proposal.grant,
                timestamp: block.timestamp,
                proposalId: proposalId
            })
        );
        
        emit GovernorAccess.RoleProposalExecuted(
            proposalId,
            proposal.account,
            proposal.role,
            proposal.grant,
            msg.sender
        );
        
        emit GovernorAccess.RoleAssignmentRecorded(
            proposal.account,
            proposal.role,
            proposal.grant,
            block.timestamp,
            proposalId
        );
    }

    /**
     * @notice Cancel a pending role proposal
     * @param proposalId The proposal ID to cancel
     */
    function cancelRoleProposal(bytes32 proposalId) internal {
        GovernorAccess.RoleProposal storage proposal = roleProposals[proposalId];
        
        if (proposal.proposalId == bytes32(0)) revert GovernorAccess.NullProposalId();
        if (proposal.executed) revert GovernorAccess.ProposalAlreadyExecuted(proposalId);
        
        // Only proposer or admin can cancel
        if (proposal.proposer != msg.sender && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert AccessControl.AccessDenied();
        }
        
        proposal.executed = true; // Mark as cancelled
        
        emit GovernorAccess.RoleProposalCancelled(proposalId, msg.sender);
    }

    /**
     * @notice Get role proposal details
     * @param proposalId The proposal ID to query
     * @return The role proposal details
     */
    function getRoleProposal(bytes32 proposalId) external view returns (
        address account,
        bytes32 role,
        bool grant,
        uint256 executeAfter,
        bool executed,
        address proposer,
        uint256 createdAt
    ) {
        GovernorAccess.RoleProposal storage p = roleProposals[proposalId];
        return (
            p.account,
            p.role,
            p.grant,
            p.executeAfter,
            p.executed,
            p.proposer,
            p.createdAt
        );
    }

    /**
     * @notice Get role assignment history for an account
     * @param account The account to query
     * @param role The role to query
     * @return Array of role assignments
     */
    function getRoleHistory(address account, bytes32 role) external view returns (
        GovernorAccess.RoleAssignment[] memory
    ) {
        return roleAssignmentHistory[account][role];
    }
}