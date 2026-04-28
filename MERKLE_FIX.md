# ReputationSnapshot Merkle Root Fix

## Issue Summary
Fixed out-of-bounds memory write in `ReputationSnapshot._computeMerkleRoot` that occurred when computing Merkle roots for arrays with an odd number of leaves.

## Problem Description

### Original Buggy Code
```solidity
function _computeMerkleRoot(bytes32[] memory leaves) internal pure returns (bytes32) {
    uint256 length = leaves.length;
    if (length == 0) return bytes32(0);
    if (length == 1) return leaves[0];

    while (length > 1) {
        if (length % 2 != 0) {
            leaves[length] = leaves[length - 1]; // ❌ BUG: Out-of-bounds write!
            length++;
        }

        for (uint256 i = 0; i < length; i += 2) {
            leaves[i / 2] = keccak256(abi.encodePacked(leaves[i], leaves[i + 1]));
        }
        length /= 2;
    }

    return leaves[0];
}
```

### The Bug
When `length` is odd (e.g., 3, 5, 7), the code attempts to write to `leaves[length]`, which is **past the end** of the allocated array. 

For example, with 3 leaves:
- Array is allocated as `new bytes32[](3)` with indices [0, 1, 2]
- When `length = 3` (odd), code tries to write to `leaves[3]`
- This causes an **out-of-bounds memory write**
- Results in `Panic(0x32)` revert (out-of-bounds array access)

## The Fix

### New Corrected Code
```solidity
function _computeMerkleRoot(bytes32[] memory leaves) internal pure returns (bytes32) {
    uint256 length = leaves.length;
    if (length == 0) return bytes32(0);
    if (length == 1) return leaves[0];

    // Create a working copy that we can modify
    bytes32[] memory currentLevel = new bytes32[](length);
    for (uint256 i = 0; i < length; i++) {
        currentLevel[i] = leaves[i];
    }

    uint256 currentLength = length;

    while (currentLength > 1) {
        // If odd number of nodes, duplicate the last one
        if (currentLength % 2 != 0) {
            // Create a new level with proper size for the duplicate
            bytes32[] memory nextLevel = new bytes32[]((currentLength + 1) / 2);
            
            // Process pairs
            for (uint256 i = 0; i < currentLength; i += 2) {
                bytes32 left = currentLevel[i];
                bytes32 right = (i + 1 < currentLength) ? currentLevel[i + 1] : currentLevel[i]; // Duplicate last if odd
                nextLevel[i / 2] = keccak256(abi.encodePacked(left, right));
            }
            
            currentLevel = nextLevel;
            currentLength = (currentLength + 1) / 2;
        } else {
            // Even number of nodes
            bytes32[] memory nextLevel = new bytes32[](currentLength / 2);
            
            for (uint256 i = 0; i < currentLength; i += 2) {
                nextLevel[i / 2] = keccak256(abi.encodePacked(currentLevel[i], currentLevel[i + 1]));
            }
            
            currentLevel = nextLevel;
            currentLength = currentLength / 2;
        }
    }

    return currentLevel[0];
}
```

### How It Works

The fix uses a **level-by-level** approach:

1. **Create a working copy** of the leaves array
2. **For each level** of the Merkle tree:
   - If the current level has an **odd** number of nodes:
     - Create a `nextLevel` array sized correctly: `(currentLength + 1) / 2`
     - When processing pairs, **duplicate the last node** if there's no pair: 
       ```solidity
       bytes32 right = (i + 1 < currentLength) ? currentLevel[i + 1] : currentLevel[i];
       ```
   - If the current level has an **even** number of nodes:
     - Create a `nextLevel` array sized: `currentLength / 2`
     - Process all pairs normally
3. **Replace** `currentLevel` with `nextLevel` and continue
4. **Return** the single remaining node (the Merkle root)

## Example Walkthrough

### With 3 leaves [A, B, C]:

**Level 0** (3 nodes - odd):
- Pair (A, B) → hash(AB)
- C has no pair, duplicate → hash(CC)
- Next level: [hash(AB), hash(CC)] (2 nodes)

**Level 1** (2 nodes - even):
- Pair (hash(AB), hash(CC)) → hash(hash(AB), hash(CC))
- Next level: [root] (1 node)

**Result**: Merkle root = hash(hash(AB), hash(CC))

### With 5 leaves [A, B, C, D, E]:

**Level 0** (5 nodes - odd):
- Pair (A, B) → hash(AB)
- Pair (C, D) → hash(CD)
- E has no pair, duplicate → hash(EE)
- Next level: [hash(AB), hash(CD), hash(EE)] (3 nodes)

**Level 1** (3 nodes - odd):
- Pair (hash(AB), hash(CD)) → hash(ABCD)
- hash(EE) has no pair, duplicate → hash(EEEE)
- Next level: [hash(ABCD), hash(EEEE)] (2 nodes)

**Level 2** (2 nodes - even):
- Pair (hash(ABCD), hash(EEEE)) → root
- Next level: [root] (1 node)

**Result**: Merkle root computed correctly!

## Benefits of This Fix

1. ✅ **No out-of-bounds writes** - Each level is allocated with the correct size
2. ✅ **Works for any array size** - Handles 1, 2, 3, 4, 5, ... N leaves correctly
3. ✅ **Standard Merkle tree behavior** - Duplicates last node when odd (consistent with Merkle tree standards)
4. ✅ **Memory safe** - Uses properly sized arrays at each level
5. ✅ **Gas efficient** - Only allocates what's needed for each level

## Testing

The fix should be tested with:
- ✅ Single leaf (1 user)
- ✅ Even number of leaves (2, 4, 6 users)
- ✅ Odd number of leaves (3, 5, 7 users)
- ✅ Empty array (0 users)

All cases should compute the Merkle root without reverting.

## Files Modified

- `contracts/ReputationSnapshot.sol` - Fixed `_computeMerkleRoot` function (lines 140-182)

## Impact

- **Before**: Any snapshot with an odd number of users would revert with `Panic(0x32)`
- **After**: Snapshots work correctly for any number of users (odd or even)
- **Breaking Changes**: None - the function signature and behavior remain the same
- **Gas Impact**: Minimal - slightly more memory allocations but safer and correct

## Additional Notes

This fix follows the standard Merkle tree construction approach where:
- Odd-length levels duplicate the last element
- Each level is half the size of the previous (rounded up)
- The tree is built bottom-up until a single root remains

The implementation is now consistent with Merkle tree libraries like OpenZeppelin's MerkleTree utilities.
