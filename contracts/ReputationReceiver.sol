// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "./IReputationOracle.sol";

/**
 * @title ReputationReceiver
 * @notice Receives and verifies bridged reputation data from other chains
 * @dev Verifies Merkle proofs and updates bridged reputation records
 */
contract ReputationReceiver is AccessControl {
    bytes32 public constant RECEIVER_ROLE = keccak256("RECEIVER_ROLE");

    IReputationOracle public reputationOracle;

    // Mapping of bridged reputations: user => sourceChainId => score
    mapping(address => mapping(uint256 => uint256)) public bridgedReputations;

    // Mapping of verified snapshot roots: sourceChainId => snapshotId => root
    mapping(uint256 => mapping(uint256 => bytes32)) public verifiedRoots;

    // Events
    event ReputationBridged(
        address indexed user,
        uint256 indexed sourceChainId,
        uint256 score,
        uint256 timestamp
    );

    event SnapshotRootVerified(
        uint256 indexed sourceChainId,
        uint256 indexed snapshotId,
        bytes32 root
    );

    // Errors
    error InvalidProof();
    error RootNotVerified();
    error ReputationAlreadyBridged();

    constructor(address admin, IReputationOracle _oracle) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(RECEIVER_ROLE, admin);
        reputationOracle = _oracle;
    }

    /**
     * @notice Verify and store a snapshot root from a source chain
     * @param sourceChainId The ID of the source chain
     * @param snapshotId The snapshot ID
     * @param root The Merkle root to verify
     */
    function verifySnapshotRoot(
        uint256 sourceChainId,
        uint256 snapshotId,
        bytes32 root
    ) external onlyRole(RECEIVER_ROLE) {
        verifiedRoots[sourceChainId][snapshotId] = root;
        emit SnapshotRootVerified(sourceChainId, snapshotId, root);
    }

    /**
     * @notice Receive bridged reputation with Merkle proof verification
     * @param user The user address
     * @param sourceChainId The source chain ID
     * @param snapshotId The snapshot ID
     * @param score The reputation score
     * @param timestamp The timestamp from the snapshot
     * @param proof The Merkle proof
     * @param proofIndex The index in the Merkle tree
     */
    function receiveBridgedReputation(
        address user,
        uint256 sourceChainId,
        uint256 snapshotId,
        uint256 score,
        uint256 timestamp,
        bytes32[] calldata proof,
        uint256 proofIndex
    ) external onlyRole(RECEIVER_ROLE) {
        bytes32 root = verifiedRoots[sourceChainId][snapshotId];
        if (root == bytes32(0)) revert RootNotVerified();

        // Reconstruct the leaf
        bytes32 leaf = keccak256(abi.encodePacked(user, score, timestamp));

        // Verify the proof
        if (!_verifyProof(leaf, proof, root, proofIndex)) revert InvalidProof();

        // Check if already bridged (optional: allow updates)
        // if (bridgedReputations[user][sourceChainId] != 0) revert ReputationAlreadyBridged();

        // Update bridged reputation
        bridgedReputations[user][sourceChainId] = score;

        emit ReputationBridged(user, sourceChainId, score, block.timestamp);
    }

    /**
     * @notice Get bridged reputation for a user from a source chain
     * @param user The user address
     * @param sourceChainId The source chain ID
     * @return The bridged reputation score
     */
    function getBridgedReputation(
        address user,
        uint256 sourceChainId
    ) external view returns (uint256) {
        return bridgedReputations[user][sourceChainId];
    }

    /**
     * @notice Get the effective reputation combining local and bridged
     * @param user The user address
     * @param sourceChainId The source chain ID
     * @return The combined reputation score
     * @dev This is a simple example - actual implementation may vary
     */
    function getCombinedReputation(
        address user,
        uint256 sourceChainId
    ) external view returns (uint256) {
        uint256 localScore = reputationOracle.getReputationScore(user);
        uint256 bridgedScore = bridgedReputations[user][sourceChainId];

        // Simple average - could be more sophisticated
        if (localScore == 0) return bridgedScore;
        if (bridgedScore == 0) return localScore;

        return (localScore + bridgedScore) / 2;
    }

    // ============ Internal Functions ============

    /**
     * @dev Verify a Merkle proof
     * @param leaf The leaf hash
     * @param proof Array of proof hashes
     * @param root The Merkle root
     * @param index The index of the leaf
     * @return True if proof is valid
     */
    function _verifyProof(
        bytes32 leaf,
        bytes32[] memory proof,
        bytes32 root,
        uint256 index
    ) internal pure returns (bool) {
        bytes32 computedHash = leaf;

        for (uint256 i = 0; i < proof.length; i++) {
            if (index % 2 == 0) {
                computedHash = keccak256(abi.encodePacked(computedHash, proof[i]));
            } else {
                computedHash = keccak256(abi.encodePacked(proof[i], computedHash));
            }
            index /= 2;
        }

        return computedHash == root;
    }
}