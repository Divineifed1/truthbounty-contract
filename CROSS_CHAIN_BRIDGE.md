# Cross-Chain Reputation Bridge (Future)

## Overview

This document outlines the design and architecture for a cross-chain reputation bridge mechanism that enables reputation data to be securely transferred between different blockchain networks (e.g., Ethereum ↔ Stellar). The bridge allows users to maintain their reputation identity across multiple chains, supporting the expansion of the TruthBounty ecosystem to multi-chain environments.

## 🎯 Objectives

- **Enable Cross-Chain Identity**: Allow users to carry their reputation scores across different blockchain networks
- **Support Multi-Chain Expansion**: Provide a scalable foundation for integrating with additional chains in the future
- **Maintain Security**: Ensure reputation data integrity and prevent manipulation during cross-chain transfers

## 🧠 Scope

### Core Components

1. **Reputation Snapshot Mechanism**
2. **Bridge Verification System** (Merkle Proof or Oracle-based)
3. **Destination Chain Integration**

### Implementation Approaches

#### Option 1: Merkle Proof Bridge
- Construct a Merkle tree of reputation scores on the source chain
- Generate inclusion proofs for individual users
- Verify proofs on the destination chain

#### Option 2: Oracle Bridge
- Use trusted oracles to attest to reputation data
- Relay attested data across chains via bridge protocols
- Verify oracle signatures on destination chain

## Architecture

### Source Chain (Ethereum) Components

#### ReputationSnapshot Contract
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "./IReputationOracle.sol";

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

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(SNAPSHOT_ROLE, admin);
    }

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

    function getMerkleProof(
        uint256 snapshotId,
        address user
    ) external view returns (bytes32[] memory proof, uint256 index) {
        ReputationData[] storage data = snapshots[snapshotId];
        uint256 length = data.length;

        for (uint256 i = 0; i < length; i++) {
            if (data[i].user == user) {
                return (_generateProof(snapshotId, i), i);
            }
        }
        revert("User not in snapshot");
    }

    // Internal functions for Merkle tree computation
    function _computeMerkleRoot(bytes32[] memory leaves) internal pure returns (bytes32) {
        // Implementation of Merkle root computation
    }

    function _generateProof(uint256 snapshotId, uint256 index) internal view returns (bytes32[] memory) {
        // Implementation of Merkle proof generation
    }
}
```

#### ReputationBridge Contract
```solidity
contract ReputationBridge is AccessControl {
    bytes32 public constant BRIDGE_ROLE = keccak256("BRIDGE_ROLE");

    struct BridgeRequest {
        address user;
        uint256 snapshotId;
        uint256 destinationChainId;
        bytes32 expectedRoot;
        bytes proofData;
        bool executed;
    }

    mapping(bytes32 => BridgeRequest) public bridgeRequests;

    function requestBridge(
        address user,
        uint256 snapshotId,
        uint256 destinationChainId,
        bytes32 expectedRoot,
        bytes calldata proofData
    ) external returns (bytes32 requestId) {
        // Implementation
    }

    function executeBridge(
        bytes32 requestId,
        bytes calldata bridgeMessage
    ) external onlyRole(BRIDGE_ROLE) {
        // Implementation
    }
}
```

### Destination Chain Components

#### ReputationReceiver Contract
```solidity
contract ReputationReceiver is AccessControl {
    bytes32 public constant RECEIVER_ROLE = keccak256("RECEIVER_ROLE");

    IReputationOracle public reputationOracle;

    mapping(address => mapping(uint256 => uint256)) public bridgedReputations;

    function receiveBridgedReputation(
        address user,
        uint256 sourceChainId,
        uint256 score,
        bytes32 snapshotRoot,
        bytes32[] calldata proof,
        uint256 proofIndex
    ) external onlyRole(RECEIVER_ROLE) {
        // Verify Merkle proof
        bytes32 leaf = keccak256(abi.encodePacked(user, score, block.timestamp));
        require(_verifyProof(leaf, proof, snapshotRoot, proofIndex), "Invalid proof");

        bridgedReputations[user][sourceChainId] = score;

        emit ReputationBridged(user, sourceChainId, score, block.timestamp);
    }

    function getBridgedReputation(
        address user,
        uint256 sourceChainId
    ) external view returns (uint256) {
        return bridgedReputations[user][sourceChainId];
    }

    function _verifyProof(
        bytes32 leaf,
        bytes32[] memory proof,
        bytes32 root,
        uint256 index
    ) internal pure returns (bool) {
        // Merkle proof verification
    }
}
```

### Oracle-Based Alternative

For chains where Merkle proofs are complex, use oracles:

#### OracleBridge Contract
```solidity
contract OracleBridge is AccessControl {
    struct OracleAttestation {
        address user;
        uint256 score;
        uint256 timestamp;
        bytes signature;
    }

    mapping(bytes32 => OracleAttestation) public attestations;

    function attestReputation(
        address user,
        uint256 score,
        bytes calldata signature
    ) external onlyRole(ORACLE_ROLE) {
        // Verify and store attestation
    }
}
```

## Bridge Protocol Integration

### Supported Bridge Protocols

1. **Wormhole**
   - Cross-chain messaging protocol
   - Guardian network for security
   - Support for EVM and non-EVM chains (including Stellar)

2. **LayerZero**
   - Omnichain interoperability protocol
   - Ultra Light Nodes (ULNs) for verification
   - Configurable security parameters

3. **Chainlink CCIP**
   - Cross-chain communication protocol
   - Decentralized oracle network
   - Token and data transfer capabilities

### Integration Example (Wormhole)

```solidity
contract WormholeReputationBridge {
    IWormhole public wormhole;

    function sendReputation(
        address user,
        uint256 score,
        uint16 destinationChain
    ) external payable {
        bytes memory payload = abi.encode(user, score, block.timestamp);
        wormhole.publishMessage{value: msg.value}(
            0, // nonce
            payload,
            200 // consistency level
        );
    }
}
```

## Verification Process

### Merkle Proof Verification
1. User requests bridge from source chain
2. Snapshot contract generates Merkle proof
3. Proof submitted to bridge protocol
4. Destination chain verifies proof against known snapshot root
5. Reputation updated if verification succeeds

### Oracle Verification
1. Authorized oracle attests to user's reputation
2. Attestation signed and submitted to bridge
3. Bridge relays attestation to destination chain
4. Destination chain verifies oracle signature
5. Reputation updated if verification succeeds

## Security Considerations

### Data Integrity
- Merkle proofs ensure data hasn't been tampered with
- Oracle signatures provide cryptographic verification
- Bridge protocols provide cross-chain security guarantees

### Freshness
- Include timestamps in all data structures
- Implement expiration mechanisms for old attestations
- Allow reputation updates to override stale data

### Access Control
- Restrict snapshot creation to authorized entities
- Limit bridge execution to verified bridge contracts
- Use multi-signature requirements for critical operations

## Risks and Limitations

### Technical Risks
1. **Bridge Protocol Risks**
   - Bridge hacks or exploits could compromise reputation data
   - Network congestion could delay reputation transfers
   - Protocol upgrades might break compatibility

2. **Oracle Risks**
   - Oracle manipulation or compromise
   - Single point of failure if using centralized oracles
   - Oracle network downtime affects bridging

3. **Merkle Tree Risks**
   - Large tree sizes could increase gas costs
   - Tree reconstruction complexity on destination chains
   - Proof verification gas costs

### Operational Risks
1. **Data Staleness**
   - Reputation may become outdated during transfer
   - No mechanism to update bridged reputation automatically
   - Users may need to re-bridge periodically

2. **Chain-Specific Limitations**
   - Different consensus mechanisms affect finality times
   - Varying gas costs impact economic viability
   - Cross-chain communication delays

3. **Regulatory Risks**
   - Cross-border data transfer regulations
   - Jurisdiction-specific compliance requirements
   - Changing regulatory landscape for cross-chain operations

### Economic Considerations
1. **Bridge Fees**
   - Cross-chain transfers incur protocol fees
   - Gas costs for proof verification
   - Oracle service fees

2. **Liquidity**
   - Insufficient liquidity in bridge protocols
   - Token requirements for bridge operations
   - Economic incentives for bridge validators

## Future Enhancements

### Automated Updates
- Implement periodic reputation syncing
- Event-driven bridge triggers
- Reputation change notifications

### Multi-Chain Reputation Aggregation
- Combine reputations from multiple chains
- Weighted averaging algorithms
- Reputation conflict resolution

### Enhanced Security
- Multi-oracle consensus mechanisms
- Zero-knowledge proofs for privacy
- Decentralized bridge networks

## Implementation Roadmap

### Phase 1: Design and Testing (Current)
- [x] Architecture documentation
- [x] Unit tests for bridge contracts
- [ ] Integration tests with mock bridges

### Phase 2: Single Chain Prototype
- [ ] Deploy testnet bridge between two EVM chains
- [ ] Implement Merkle proof verification
- [ ] Test oracle-based alternative

### Phase 3: Multi-Chain Expansion
- [ ] Integrate with Wormhole/LayerZero
- [ ] Add Stellar support
- [ ] Mainnet deployment and audits

### Phase 4: Production Optimization
- [ ] Gas optimization for proof verification
- [ ] Batch processing for multiple users
- [ ] Monitoring and alerting systems

## Conclusion

The cross-chain reputation bridge provides a secure and scalable foundation for multi-chain reputation management. By supporting both Merkle proof and oracle-based approaches, the system offers flexibility for different chain architectures while maintaining strong security guarantees. The modular design allows for incremental implementation and future enhancements as the ecosystem grows.