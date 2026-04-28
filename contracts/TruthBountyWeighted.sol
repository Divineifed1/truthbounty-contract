// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./IReputationOracle.sol";

/**
 * @title TruthBountyWeighted
 * @notice Enhanced TruthBounty contract with reputation-weighted staking
 * @dev Integrates reputation scores to calculate effective voting power
 *
 * Key Enhancements:
 * - Reputation-weighted voting power
 * - Deterministic effective stake calculation
 * - Prevents low-reputation dominance
 * - Maintains backward compatibility with equal-weight fallback
 */
contract TruthBountyWeighted is AccessControl, ReentrancyGuard, Pausable {
    // ============ Roles ============

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant RESOLVER_ROLE = keccak256("RESOLVER_ROLE");
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // ============ State Variables ============

    /// @notice Token contract for staking and rewards
    IERC20 public immutable bountyToken;

    /// @notice Reputation oracle for score lookups
    IReputationOracle public reputationOracle;

    // ============ Configuration Constants ============

    uint256 public constant VERIFICATION_WINDOW_DURATION = 7 days;
    uint256 public constant MIN_STAKE_AMOUNT = 100 * 10**18;
    uint256 public constant SETTLEMENT_THRESHOLD_PERCENT = 60;
    uint256 public constant REWARD_PERCENT = 80;
    uint256 public constant SLASH_PERCENT = 20;

    /// @notice Base multiplier for reputation scaling (1e18 = 100%)
    uint256 public constant BASE_MULTIPLIER = 1e18;

    /// @notice Minimum reputation score (10% = 0.1)
    uint256 public minReputationScore = 1e17;

    /// @notice Maximum reputation score (1000% = 10x)
    uint256 public maxReputationScore = 10e18;

    /// @notice Default reputation for users without a score (100% = 1.0)
    uint256 public defaultReputationScore = 1e18;

    /// @notice Whether weighted staking is enabled
    bool public weightedStakingEnabled = true;

    // ============ Structs ============

    struct Claim {
        uint256 id;
        address submitter;
        string content;
        uint256 createdAt;
        uint256 verificationWindowEnd;
        bool settled;
        uint256 totalWeightedFor;      // Weighted votes for claim (NEW)
        uint256 totalWeightedAgainst;  // Weighted votes against claim (NEW)
        uint256 totalStakeAmount;      // Total raw stake amount
    }

    struct Vote {
        bool voted;
        bool support;
        uint256 stakeAmount;           // Raw stake amount
        uint256 effectiveStake;        // Weighted stake amount (NEW)
        uint256 reputationScore;       // Reputation score at vote time (NEW)
        bool rewardClaimed;
        bool stakeReturned;
        uint256 slashAmount;           // Per-vote slash amount calculated at settlement (prevents double-slash)
    }

    struct SettlementResult {
        bool passed;
        uint256 totalRewards;
        uint256 totalSlashed;
        uint256 winnerWeightedStake;   // Changed to weighted (NEW)
        uint256 loserWeightedStake;    // Changed to weighted (NEW)
    }

    struct VerifierStake {
        uint256 totalStaked;
        uint256 activeStakes;
    }

    // ============ Storage Mappings ============

    mapping(uint256 => Claim) public claims;
    mapping(uint256 => SettlementResult) public settlementResults;
    mapping(uint256 => mapping(address => Vote)) public votes;
    mapping(address => VerifierStake) public verifierStakes;
    mapping(uint256 => address[]) private claimVoters;  // Track all voters per claim for settlement

    uint256 public claimCounter;
    uint256 public totalSlashed;
    uint256 public totalRewarded;

    // ============ Events ============

    event ClaimCreated(
        uint256 indexed claimId,
        address indexed submitter,
        string content,
        uint256 verificationWindowEnd
    );

    event VoteCast(
        uint256 indexed claimId,
        address indexed verifier,
        bool support,
        uint256 rawStake,
        uint256 effectiveStake,
        uint256 reputationScore
    );

    event ClaimSettled(
        uint256 indexed claimId,
        bool passed,
        uint256 totalWeightedFor,
        uint256 totalWeightedAgainst,
        uint256 totalRewards,
        uint256 totalSlashed
    );

    event RewardsDistributed(
        uint256 indexed claimId,
        address indexed verifier,
        uint256 amount
    );

    event StakeSlashed(
        uint256 indexed claimId,
        address indexed verifier,
        uint256 amount
    );

    event StakeDeposited(address indexed verifier, uint256 amount);
    event StakeWithdrawn(address indexed verifier, uint256 amount);
    event ReputationOracleUpdated(address indexed oldOracle, address indexed newOracle);
    event ReputationBoundsUpdated(uint256 minScore, uint256 maxScore);
    event WeightedStakingToggled(bool enabled);

    // ============ Errors ============

    error InvalidReputationOracle();
    error InvalidReputationBounds();

    // ============ Constructor ============

    constructor(
        address _bountyToken,
        address _reputationOracle,
        address initialAdmin
    ) {
        require(_bountyToken != address(0), "Invalid token address");
        require(_reputationOracle != address(0), "Invalid oracle address");
        require(initialAdmin != address(0), "Invalid admin address");
        
        bountyToken = IERC20(_bountyToken);
        reputationOracle = IReputationOracle(_reputationOracle);
        
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(ADMIN_ROLE, initialAdmin);
        _grantRole(PAUSER_ROLE, initialAdmin);
        
        _setRoleAdmin(RESOLVER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(TREASURY_ROLE, ADMIN_ROLE);
        _setRoleAdmin(PAUSER_ROLE, ADMIN_ROLE);
    }

    // ============ Core Functions ============

    /**
     * @notice Create a new claim for verification
     * @param content IPFS hash or content reference
     * @return claimId The ID of the newly created claim
     */
    function createClaim(string memory content) external whenNotPaused returns (uint256) {
        uint256 claimId = claimCounter++;
        uint256 verificationWindowEnd = block.timestamp + VERIFICATION_WINDOW_DURATION;

        claims[claimId] = Claim({
            id: claimId,
            submitter: msg.sender,
            content: content,
            createdAt: block.timestamp,
            verificationWindowEnd: verificationWindowEnd,
            settled: false,
            totalWeightedFor: 0,
            totalWeightedAgainst: 0,
            totalStakeAmount: 0
        });

        emit ClaimCreated(claimId, msg.sender, content, verificationWindowEnd);
        return claimId;
    }

    /**
     * @notice Stake tokens to participate in verification
     * @param amount Amount of tokens to stake
     */
    function stake(uint256 amount) external nonReentrant whenNotPaused {
        require(amount >= MIN_STAKE_AMOUNT, "Stake below minimum");
        require(bountyToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");

        verifierStakes[msg.sender].totalStaked += amount;

        emit StakeDeposited(msg.sender, amount);
    }

    /**
     * @notice Vote on a claim with reputation-weighted stake
     * @param claimId The ID of the claim to vote on
     * @param support true for pass, false for fail
     * @param stakeAmount Amount of stake to commit to this vote
     */
    function vote(
        uint256 claimId,
        bool support,
        uint256 stakeAmount
    ) external nonReentrant whenNotPaused {
        Claim storage claim = claims[claimId];
        require(claim.submitter != address(0), "Claim does not exist");
        require(block.timestamp < claim.verificationWindowEnd, "Verification window closed");
        require(!claim.settled, "Claim already settled");
        require(!votes[claimId][msg.sender].voted, "Already voted");
        require(stakeAmount >= MIN_STAKE_AMOUNT, "Stake below minimum");
        require(
            verifierStakes[msg.sender].totalStaked >=
                verifierStakes[msg.sender].activeStakes + stakeAmount,
            "Insufficient available stake"
        );

        // Calculate weighted stake based on reputation
        uint256 reputationScore = _getReputationScore(msg.sender);
        uint256 effectiveStake = _calculateEffectiveStake(stakeAmount, reputationScore);

        // Lock the raw stake
        verifierStakes[msg.sender].activeStakes += stakeAmount;

        // Record the vote with both raw and effective stakes
        votes[claimId][msg.sender] = Vote({
            voted: true,
            support: support,
            stakeAmount: stakeAmount,
            effectiveStake: effectiveStake,
            reputationScore: reputationScore,
            rewardClaimed: false,
            stakeReturned: false,
            slashAmount: 0
        });

        // Track this voter for settlement calculations
        claimVoters[claimId].push(msg.sender);

        // Update claim totals with WEIGHTED stakes
        if (support) {
            claim.totalWeightedFor += effectiveStake;
        } else {
            claim.totalWeightedAgainst += effectiveStake;
        }
        claim.totalStakeAmount += stakeAmount; // Still track raw stake total

        emit VoteCast(claimId, msg.sender, support, stakeAmount, effectiveStake, reputationScore);
    }

    /**
     * @notice Settle a claim after verification window closes
     * @param claimId The ID of the claim to settle
     */
    function settleClaim(uint256 claimId) external nonReentrant {
        Claim storage claim = claims[claimId];
        require(claim.submitter != address(0), "Claim does not exist");
        require(block.timestamp >= claim.verificationWindowEnd, "Verification window not closed");
        require(!claim.settled, "Claim already settled");
        require(claim.totalStakeAmount > 0, "No votes cast");

        claim.settled = true;

        // Determine outcome based on WEIGHTED votes
        bool passed = _determineOutcome(claim.totalWeightedFor, claim.totalWeightedAgainst);

        // Calculate rewards and slashing
        (uint256 rewardAmount, uint256 slashedAmount) = _calculateSettlement(
            claimId,
            passed
        );

        emit ClaimSettled(
            claimId,
            passed,
            claim.totalWeightedFor,
            claim.totalWeightedAgainst,
            rewardAmount,
            slashedAmount
        );
    }

    /**
     * @notice Claim rewards for winning a vote
     * @param claimId The ID of the settled claim
     */
    function claimSettlementRewards(uint256 claimId) external nonReentrant {
        Claim storage claim = claims[claimId];
        require(claim.submitter != address(0), "Claim does not exist");
        require(claim.settled, "Claim not settled");

        Vote storage vote = votes[claimId][msg.sender];
        require(vote.voted, "No vote cast");
        require(!vote.rewardClaimed, "Rewards already claimed");

        SettlementResult storage settlement = settlementResults[claimId];
        require(settlement.winnerWeightedStake > 0, "No winners");

        // Check if verifier was on the winning side
        bool isWinner = (vote.support == settlement.passed);
        require(isWinner, "Not a winner");

        // Calculate proportional reward based on EFFECTIVE stake
        uint256 reward = (vote.effectiveStake * settlement.totalRewards) / settlement.winnerWeightedStake;

        // Mark as claimed
        vote.rewardClaimed = true;

        // Transfer reward
        if (reward > 0) {
            require(bountyToken.transfer(msg.sender, reward), "Reward transfer failed");
            emit RewardsDistributed(claimId, msg.sender, reward);
        }

        // Return stake (winners get full RAW stake back)
        if (!vote.stakeReturned) {
            vote.stakeReturned = true;
            verifierStakes[msg.sender].activeStakes -= vote.stakeAmount;
            require(bountyToken.transfer(msg.sender, vote.stakeAmount), "Stake transfer failed");
        }
    }

    /**
     * @notice Withdraw stake after settlement (for losers)
     * @param claimId The ID of the settled claim
     */
    function withdrawSettledStake(uint256 claimId) external nonReentrant {
        Claim storage claim = claims[claimId];
        require(claim.submitter != address(0), "Claim does not exist");
        require(claim.settled, "Claim not settled");

        Vote storage vote = votes[claimId][msg.sender];
        require(vote.voted, "No vote cast");
        require(!vote.stakeReturned, "Stake already returned");

        SettlementResult storage settlement = settlementResults[claimId];
        bool isWinner = (vote.support == settlement.passed);

        uint256 stakeToReturn;
        uint256 slashAmount = vote.slashAmount; // Use pre-calculated slash amount (no recalculation)

        if (isWinner) {
            stakeToReturn = vote.stakeAmount;
        } else {
            // Losers get stake back minus slashing (pre-calculated at settlement)
            stakeToReturn = vote.stakeAmount - slashAmount;

            emit StakeSlashed(claimId, msg.sender, slashAmount);
        }

        vote.stakeReturned = true;
        verifierStakes[msg.sender].activeStakes -= vote.stakeAmount;

        if (!isWinner) {
            verifierStakes[msg.sender].totalStaked -= slashAmount;
        }

        if (stakeToReturn > 0) {
            require(bountyToken.transfer(msg.sender, stakeToReturn), "Stake transfer failed");
        }
    }

    /**
     * @notice Withdraw available stake (not locked in active claims)
     */
    function withdrawStake(uint256 amount) external nonReentrant {
        VerifierStake storage stake = verifierStakes[msg.sender];
        require(
            stake.totalStaked >= stake.activeStakes + amount,
            "Insufficient available stake"
        );

        stake.totalStaked -= amount;
        require(bountyToken.transfer(msg.sender, amount), "Transfer failed");

        emit StakeWithdrawn(msg.sender, amount);
    }

    // ============ Internal Helper Functions ============

    /**
     * @notice Get reputation score with bounds and fallback
     * @param user The address to query
     * @return score The bounded reputation score
     */
    function _getReputationScore(address user) internal view returns (uint256 score) {
        if (!weightedStakingEnabled) {
            return BASE_MULTIPLIER;
        }

        // Try to get score from oracle
        try reputationOracle.isActive() returns (bool active) {
            if (!active) {
                return defaultReputationScore;
            }
        } catch {
            return defaultReputationScore;
        }

        try reputationOracle.getReputationScore(user) returns (uint256 reputationScore) {
            if (reputationScore == 0) {
                return defaultReputationScore;
            }
            return _applyReputationBounds(reputationScore);
        } catch {
            return defaultReputationScore;
        }
    }

    /**
     * @notice Apply min/max bounds to reputation score
     */
    function _applyReputationBounds(uint256 score) internal view returns (uint256) {
        if (score < minReputationScore) return minReputationScore;
        if (score > maxReputationScore) return maxReputationScore;
        return score;
    }

    /**
     * @notice Calculate effective stake from raw stake and reputation
     * @param stakeAmount Raw stake amount
     * @param reputationScore Reputation score (scaled by 1e18)
     * @return effectiveStake Weighted stake amount
     */
    function _calculateEffectiveStake(
        uint256 stakeAmount,
        uint256 reputationScore
    ) internal pure returns (uint256 effectiveStake) {
        return (stakeAmount * reputationScore) / BASE_MULTIPLIER;
    }

    /**
     * @notice Determine outcome based on weighted votes
     */
    function _determineOutcome(
        uint256 weightedFor,
        uint256 weightedAgainst
    ) internal pure returns (bool) {
        uint256 totalWeighted = weightedFor + weightedAgainst;
        if (totalWeighted == 0) return false;

        uint256 forPercent = (weightedFor * 100) / totalWeighted;
        return forPercent >= SETTLEMENT_THRESHOLD_PERCENT;
    }

    /**
     * @notice Calculate settlement based on weighted stakes
     * @dev Assigns per-vote slash amounts to prevent double-slashing
     */
    function _calculateSettlement(
        uint256 claimId,
        bool passed
    ) internal returns (uint256 rewardAmount, uint256 slashedAmount) {
        Claim storage claim = claims[claimId];

        // Use WEIGHTED stakes for determining winner/loser totals
        uint256 winnerWeightedStake = passed ? claim.totalWeightedFor : claim.totalWeightedAgainst;
        uint256 loserWeightedStake = passed ? claim.totalWeightedAgainst : claim.totalWeightedFor;

        // Calculate and assign per-vote slash amounts, returns total slashed
        slashedAmount = _assignPerVoteSlashes(claimId, passed);

        // 80% of slashed goes to winners as rewards
        rewardAmount = (slashedAmount * REWARD_PERCENT) / 100;

        totalSlashed += slashedAmount;
        totalRewarded += rewardAmount;

        settlementResults[claimId] = SettlementResult({
            passed: passed,
            totalRewards: rewardAmount,
            totalSlashed: slashedAmount,
            winnerWeightedStake: winnerWeightedStake,
            loserWeightedStake: loserWeightedStake
        });
    }

    /**
     * @notice Assign per-vote slash amounts to each loser
     * @dev Iterates through all voters and stores slash amount in Vote struct for losers
     * @return totalSlashed Sum of all slash amounts
     */
    function _assignPerVoteSlashes(
        uint256 claimId,
        bool passed
    ) internal returns (uint256 totalSlashed) {
        address[] storage voters = claimVoters[claimId];
        
        for (uint256 i = 0; i < voters.length; i++) {
            address voter = voters[i];
            Vote storage vote = votes[claimId][voter];
            
            bool isLoser = (vote.support != passed);
            
            if (isLoser) {
                // Calculate slash as 20% of their RAW stake
                uint256 slashAmount = (vote.stakeAmount * SLASH_PERCENT) / 100;
                vote.slashAmount = slashAmount;
                totalSlashed += slashAmount;
            } else {
                // Winners are not slashed
                vote.slashAmount = 0;
            }
        }
    }

    /**
     * @notice Helper to calculate total raw stake from losing side
     * @dev Iterates through votes - in production, consider off-chain indexing
     */
    function _calculateLoserRawStake(
        uint256 claimId,
        bool passed
    ) internal view returns (uint256 total) {
        // Note: This is a simplified implementation
        // In production, you'd want to track this during voting or use off-chain indexing
        // For now, we'll use the total stake as an approximation
        Claim storage claim = claims[claimId];

        // Rough approximation: total stake * (loser weighted / total weighted)
        uint256 totalWeighted = claim.totalWeightedFor + claim.totalWeightedAgainst;
        uint256 loserWeighted = passed ? claim.totalWeightedAgainst : claim.totalWeightedFor;

        if (totalWeighted == 0) return 0;

        return (claim.totalStakeAmount * loserWeighted) / totalWeighted;
    }

    // ============ Admin Functions ============

    /**
     * @notice Update the reputation oracle
     */
    function setReputationOracle(address _newOracle) external onlyRole(ADMIN_ROLE) {
        if (_newOracle == address(0)) revert InvalidReputationOracle();

        address oldOracle = address(reputationOracle);
        reputationOracle = IReputationOracle(_newOracle);

        emit ReputationOracleUpdated(oldOracle, _newOracle);
    }

    /**
     * @notice Update reputation score bounds
     */
    function setReputationBounds(uint256 _minScore, uint256 _maxScore) external onlyRole(ADMIN_ROLE) {
        if (_minScore == 0 || _minScore >= _maxScore) revert InvalidReputationBounds();

        minReputationScore = _minScore;
        maxReputationScore = _maxScore;

        emit ReputationBoundsUpdated(_minScore, _maxScore);
    }

    /**
     * @notice Toggle weighted staking on/off
     */
    function setWeightedStakingEnabled(bool _enabled) external onlyRole(ADMIN_ROLE) {
        weightedStakingEnabled = _enabled;
        emit WeightedStakingToggled(_enabled);
    }

    /**
     * @notice Set default reputation score
     */
    function setDefaultReputationScore(uint256 _defaultScore) external onlyRole(ADMIN_ROLE) {
        require(_defaultScore > 0, "Invalid default");
        defaultReputationScore = _defaultScore;
    }

    // ============ View Functions ============

    function getClaim(uint256 claimId) external view returns (Claim memory) {
        return claims[claimId];
    }

    function getVote(uint256 claimId, address verifier) external view returns (Vote memory) {
        return votes[claimId][verifier];
    }

    function getVerifierStake(address verifier) external view returns (VerifierStake memory) {
        return verifierStakes[verifier];
    }

    /**
     * @notice Preview the effective stake for a user
     */
    function previewEffectiveStake(
        address user,
        uint256 stakeAmount
    ) external view returns (uint256 effectiveStake, uint256 reputationScore) {
        reputationScore = _getReputationScore(user);
        effectiveStake = _calculateEffectiveStake(stakeAmount, reputationScore);
    }

    // ============ Admin & Pauser Functions ============

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
}
