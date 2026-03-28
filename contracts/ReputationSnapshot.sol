// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "./IReputationOracle.sol";

/**
 * @title ReputationSnapshot
 * @notice Creates snapshots of reputation data for cross-chain bridging
 * @dev Generates Merkle trees from reputation data for efficient verification
 */
contract ReputationSnapshot is AccessControl {
    bytes32 public constant SNAPSHOT_ROLE = keccak256("SNAPSHOT_ROLE");

    struct ReputationData {
        address user;
        uint256 score;
        uint256 timestamp;
        uint256 blockNumber;
    }

    // Snapshot storage
    mapping(uint256 => ReputationData[]) public snapshots;
    mapping(uint256 => bytes32) public snapshotRoots; // Merkle roots

    // Events
    event SnapshotCreated(uint256 indexed snapshotId, uint256 userCount, bytes32 root);
    event ReputationBridged(address indexed user, uint256 snapshotId, uint256 destinationChainId);

    // Errors
    error UserNotInSnapshot();
    error InvalidSnapshot();

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(SNAPSHOT_ROLE, admin);
    }

    /**
     * @notice Create a snapshot of reputation scores for given users
     * @param users Array of user addresses to include in snapshot
     * @param oracle The reputation oracle to query scores from
     * @return snapshotId The ID of the created snapshot (timestamp-based)
     */
    function createSnapshot(
        address[] calldata users,
        IReputationOracle oracle
    ) external onlyRole(SNAPSHOT_ROLE) returns (uint256 snapshotId) {
        snapshotId = block.timestamp;
        uint256 length = users.length;

        for (uint256 i = 0; i < length; i++) {
            address user = users[i];
            uint256 score = oracle.getReputationScore(user);

            snapshots[snapshotId].push(ReputationData({
                user: user,
                score: score,
                timestamp: block.timestamp,
                blockNumber: block.number
            }));
        }

        // Generate Merkle root
        bytes32[] memory leaves = new bytes32[](length);
        for (uint256 i = 0; i < length; i++) {
            leaves[i] = keccak256(abi.encodePacked(
                snapshots[snapshotId][i].user,
                snapshots[snapshotId][i].score,
                snapshots[snapshotId][i].timestamp
            ));
        }

        snapshotRoots[snapshotId] = _computeMerkleRoot(leaves);

        emit SnapshotCreated(snapshotId, length, snapshotRoots[snapshotId]);
    }

    /**
     * @notice Get Merkle proof for a user's reputation in a snapshot
     * @param snapshotId The snapshot ID
     * @param user The user address
     * @return proof The Merkle proof
     * @return index The index of the user in the snapshot
     */
    function getMerkleProof(
        uint256 snapshotId,
        address user
    ) external view returns (bytes32[] memory proof, uint256 index) {
        if (snapshotRoots[snapshotId] == bytes32(0)) revert InvalidSnapshot();

        ReputationData[] storage data = snapshots[snapshotId];
        uint256 length = data.length;

        for (uint256 i = 0; i < length; i++) {
            if (data[i].user == user) {
                return (_generateProof(snapshotId, i), i);
            }
        }
        revert UserNotInSnapshot();
    }

    /**
     * @notice Get reputation data for a user in a snapshot
     * @param snapshotId The snapshot ID
     * @param user The user address
     * @return data The reputation data
     */
    function getSnapshotData(
        uint256 snapshotId,
        address user
    ) external view returns (ReputationData memory data) {
        ReputationData[] storage snapshotData = snapshots[snapshotId];
        uint256 length = snapshotData.length;

        for (uint256 i = 0; i < length; i++) {
            if (snapshotData[i].user == user) {
                return snapshotData[i];
            }
        }
        revert UserNotInSnapshot();
    }

    /**
     * @notice Get the number of users in a snapshot
     * @param snapshotId The snapshot ID
     * @return The number of users
     */
    function getSnapshotLength(uint256 snapshotId) external view returns (uint256) {
        return snapshots[snapshotId].length;
    }

    // ============ Internal Functions ============

    /**
     * @dev Compute Merkle root from leaves
     * @param leaves Array of leaf hashes
     * @return The Merkle root
     */
    function _computeMerkleRoot(bytes32[] memory leaves) internal pure returns (bytes32) {
        uint256 length = leaves.length;
        if (length == 0) return bytes32(0);
        if (length == 1) return leaves[0];

        while (length > 1) {
            if (length % 2 != 0) {
                leaves[length] = leaves[length - 1]; // Duplicate last element
                length++;
            }

            for (uint256 i = 0; i < length; i += 2) {
                leaves[i / 2] = keccak256(abi.encodePacked(leaves[i], leaves[i + 1]));
            }
            length /= 2;
        }

        return leaves[0];
    }

    /**
     * @dev Generate Merkle proof for a leaf at given index
     * @param snapshotId The snapshot ID
     * @param index The index of the leaf
     * @return proof Array of proof hashes
     */
    function _generateProof(
        uint256 snapshotId,
        uint256 index
    ) internal view returns (bytes32[] memory proof) {
        ReputationData[] storage data = snapshots[snapshotId];
        uint256 length = data.length;

        // Calculate number of levels needed
        uint256 levels = 0;
        uint256 tempLength = length;
        while (tempLength > 1) {
            if (tempLength % 2 != 0) tempLength++;
            tempLength /= 2;
            levels++;
        }

        proof = new bytes32[](levels);

        uint256 currentIndex = index;
        uint256 currentLength = length;

        for (uint256 level = 0; level < levels; level++) {
            uint256 pairIndex;
            if (currentIndex % 2 == 0) {
                pairIndex = currentIndex + 1;
            } else {
                pairIndex = currentIndex - 1;
            }

            if (pairIndex < currentLength) {
                // Get the hash from the current level
                bytes32 hash = keccak256(abi.encodePacked(
                    data[pairIndex].user,
                    data[pairIndex].score,
                    data[pairIndex].timestamp
                ));
                proof[level] = hash;
            } else {
                // If no pair exists, use the same hash (duplicate)
                bytes32 hash = keccak256(abi.encodePacked(
                    data[currentIndex].user,
                    data[currentIndex].score,
                    data[currentIndex].timestamp
                ));
                proof[level] = hash;
            }

            currentIndex /= 2;
            if (currentLength % 2 != 0) currentLength++;
            currentLength /= 2;
        }

        return proof;
    }
}