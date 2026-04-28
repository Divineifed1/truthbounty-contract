// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./governance/GovernanceOwnable.sol";
import "./governance/GovernanceHooks.sol";

/**
 * @title TruthBountyToken
 * @notice ERC20 token for TruthBounty rewards with staking capabilities
 */
contract TruthBountyToken is ERC20, AccessControl {
    // ============ Roles ============

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant RESOLVER_ROLE = keccak256("RESOLVER_ROLE");
    
    // Legacy mapping
    bytes32 public constant SETTLEMENT_ROLE = RESOLVER_ROLE;
    address public settlementContract;
    uint256 public slashPercentage = 10; // 10%

    mapping(address => uint256) public verifierStake;

    event StakeDeposited(address indexed verifier, uint256 amount);
    event StakeWithdrawn(address indexed verifier, uint256 amount);
    event VerifierSlashed(
        address indexed verifier,
        uint256 slashedAmount,
        uint256 remainingStake,
        string reason
    );

    // Restricts access to the resolver (formerly settlement) role
    modifier onlyResolver() {
        _checkRole(RESOLVER_ROLE, msg.sender);
        _;
    }

    constructor(address initialAdmin) ERC20("TruthBounty", "BOUNTY") {
        require(initialAdmin != address(0), "Invalid admin address");
        _mint(initialAdmin, 10_000_000 * 10 ** decimals());
        
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(ADMIN_ROLE, initialAdmin);
        
        _setRoleAdmin(RESOLVER_ROLE, ADMIN_ROLE);
    }

    function setSettlementContract(address _settlement) external onlyRole(ADMIN_ROLE) {
        settlementContract = _settlement;
        // Automatically grant RESOLVER_ROLE to the settlement contract
        _grantRole(RESOLVER_ROLE, _settlement);
    }

    function setSlashPercentage(uint256 percentage) external onlyRole(ADMIN_ROLE) {
        require(percentage <= 100, "Invalid percentage");
        slashPercentage = percentage;
    }

    function stake(uint256 amount) external {
        require(amount > 0, "Invalid amount");
        _transfer(msg.sender, address(this), amount);
        verifierStake[msg.sender] += amount;

        emit StakeDeposited(msg.sender, amount);
    }

    function withdrawStake(uint256 amount) external {
        require(verifierStake[msg.sender] >= amount, "Insufficient stake");

        verifierStake[msg.sender] -= amount;
        _transfer(address(this), msg.sender, amount);

        emit StakeWithdrawn(msg.sender, amount);
    }

    function slashVerifier(
        address verifier,
        string calldata reason
    ) external onlyResolver {
        uint256 verifierStakeAmount = verifierStake[verifier];
        require(verifierStakeAmount > 0, "No stake to slash");

        uint256 slashedAmount = (verifierStakeAmount * slashPercentage) / 100;
        verifierStake[verifier] -= slashedAmount;

        _burn(address(this), slashedAmount);

        emit VerifierSlashed(
            verifier,
            slashedAmount,
            verifierStake[verifier],
            reason
        );
    }
}

/**
 * @title TruthBounty
 * @notice Main contract for claim verification, voting, and settlement
 */
contract TruthBounty is AccessControl, ReentrancyGuard, Pausable, GovernanceOwnable {
    // ============ Roles ============

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant RESOLVER_ROLE = keccak256("RESOLVER_ROLE");
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    // Token contract
    IERC20 public immutable bountyToken;

    // Claim structure
    struct Claim {
        uint256 id;
        address submitter;
        string content; // IPFS hash or content reference
        uint256 createdAt;
        uint256 verificationWindowEnd; // Timestamp when verification window closes
        bool settled;
        uint256 totalStakedFor; // Weighted votes for claim (pass)
        uint256 totalStakedAgainst; // Weighted votes against claim (fail)
        uint256 totalStakeAmount; // Total stake amount in this claim
    }

    // Vote structure
    struct Vote {
        bool voted;
        bool support; // true = pass, false = fail
        uint256 stakeAmount;
        bool rewardClaimed; // Whether rewards have been claimed for this vote
        bool stakeReturned; // Whether stake has been returned
    }

    // Settlement result for a claim
    struct SettlementResult {
        bool passed;
        uint256 totalRewards;
        uint256 totalSlashed;
        uint256 winnerStake;
        uint256 loserStake;
    }

    // Verifier staking information
    struct VerifierStake {
        uint256 totalStaked;
        uint256 activeStakes; // Stakes currently locked in active claims
    }

    // Claim state
    mapping(uint256 => Claim) public claims;
    mapping(uint256 => SettlementResult) public settlementResults;
    mapping(uint256 => mapping(address => Vote)) public votes;
    mapping(address => VerifierStake) public verifierStakes;
    mapping(address => uint256) public verifierRewards;

    // Configuration ( Governance-controlled parameters )
    uint256 public verificationWindowDuration = 7 days;
    uint256 public minStakeAmount = 100 * 10**18;
    uint256 public settlementThresholdPercent = 60;
    uint256 public rewardPercent = 80;
    uint256 public slashPercent = 20;
    
    // Governance parameter IDs for reference
    bytes32 public constant GOVERNANCE_PARAM_VERIFICATION_WINDOW = keccak256("VERIFICATION_WINDOW_DURATION");
    bytes32 public constant GOVERNANCE_PARAM_MIN_STAKE = keccak256("MIN_STAKE_AMOUNT");
    bytes32 public constant GOVERNANCE_PARAM_THRESHOLD = keccak256("SETTLEMENT_THRESHOLD_PERCENT");
    bytes32 public constant GOVERNANCE_PARAM_REWARD = keccak256("REWARD_PERCENT");
    bytes32 public constant GOVERNANCE_PARAM_SLASH = keccak256("SLASH_PERCENT");

    // State
    uint256 public claimCounter;
    uint256 public totalSlashed;
    uint256 public totalRewarded;

    // Events
    event ClaimCreated(uint256 indexed claimId, address indexed submitter, string content, uint256 verificationWindowEnd);
    event VoteCast(uint256 indexed claimId, address indexed verifier, bool support, uint256 stakeAmount);
    event ClaimSettled(uint256 indexed claimId, bool passed, uint256 totalStakedFor, uint256 totalStakedAgainst, uint256 totalRewards, uint256 totalSlashed);
    event RewardsDistributed(uint256 indexed claimId, address indexed verifier, uint256 amount);
    event StakeSlashed(uint256 indexed claimId, address indexed verifier, uint256 amount);
    event StakeDeposited(address indexed verifier, uint256 amount);
    event StakeWithdrawn(address indexed verifier, uint256 amount);
    event RewardsClaimed(address indexed verifier, uint256 amount);

    constructor(address _bountyToken, address initialAdmin, address _governanceController) {
        require(_bountyToken != address(0), "Invalid token address");
        require(initialAdmin != address(0), "Invalid admin address");
        
        bountyToken = IERC20(_bountyToken);
        
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(ADMIN_ROLE, initialAdmin);
        _grantRole(PAUSER_ROLE, initialAdmin);
        
        _setRoleAdmin(RESOLVER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(TREASURY_ROLE, ADMIN_ROLE);
        _setRoleAdmin(PAUSER_ROLE, ADMIN_ROLE);
        
        // Initialize governance
        _initializeGovernance(_governanceController, initialAdmin, initialAdmin);
    }

    function createClaim(string memory content) external whenNotPaused returns (uint256) {
        uint256 claimId = claimCounter++;
        uint256 verificationWindowEnd = block.timestamp + verificationWindowDuration;

        claims[claimId] = Claim({
            id: claimId,
            submitter: msg.sender,
            content: content,
            createdAt: block.timestamp,
            verificationWindowEnd: verificationWindowEnd,
            settled: false,
            totalStakedFor: 0,
            totalStakedAgainst: 0,
            totalStakeAmount: 0
        });

        emit ClaimCreated(claimId, msg.sender, content, verificationWindowEnd);
        return claimId;
    }

    function stake(uint256 amount) external nonReentrant whenNotPaused {
        require(amount >= minStakeAmount, "Stake below minimum");
        require(bountyToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");

        verifierStakes[msg.sender].totalStaked += amount;

        emit StakeDeposited(msg.sender, amount);
    }

    function vote(uint256 claimId, bool support, uint256 stakeAmount) external nonReentrant whenNotPaused {
        Claim storage claim = claims[claimId];
        require(claim.submitter != address(0), "Claim does not exist");
        require(block.timestamp < claim.verificationWindowEnd, "Verification window closed");
        require(!claim.settled, "Claim already settled");
        require(!votes[claimId][msg.sender].voted, "Already voted");
        require(stakeAmount >= minStakeAmount, "Stake below minimum");
        require(verifierStakes[msg.sender].totalStaked >= verifierStakes[msg.sender].activeStakes + stakeAmount, "Insufficient available stake");

        verifierStakes[msg.sender].activeStakes += stakeAmount;

        votes[claimId][msg.sender] = Vote({
            voted: true,
            support: support,
            stakeAmount: stakeAmount,
            rewardClaimed: false,
            stakeReturned: false
        });

        if (support) claim.totalStakedFor += stakeAmount;
        else claim.totalStakedAgainst += stakeAmount;
        claim.totalStakeAmount += stakeAmount;

        emit VoteCast(claimId, msg.sender, support, stakeAmount);
    }

    function settleClaim(uint256 claimId) external nonReentrant {
        Claim storage claim = claims[claimId];
        require(claim.submitter != address(0), "Claim does not exist");
        require(block.timestamp >= claim.verificationWindowEnd, "Verification window not closed");
        require(!claim.settled, "Claim already settled");
        require(claim.totalStakeAmount > 0, "No votes cast");

        claim.settled = true;
        bool passed = _determineOutcome(claim.totalStakedFor, claim.totalStakedAgainst);

        (uint256 rewardAmount, uint256 slashedAmount) = _calculateSettlement(claimId, passed);

        emit ClaimSettled(claimId, passed, claim.totalStakedFor, claim.totalStakedAgainst, rewardAmount, slashedAmount);
    }

    function _determineOutcome(uint256 stakedFor, uint256 stakedAgainst) internal view returns (bool) {
        uint256 totalStake = stakedFor + stakedAgainst;
        if (totalStake == 0) return false;
        uint256 forPercent = (stakedFor * 100) / totalStake;
        return forPercent >= settlementThresholdPercent;
    }

    function _calculateSettlement(uint256 claimId, bool passed) internal returns (uint256 rewardAmount, uint256 slashedAmount) {
        Claim storage claim = claims[claimId];
        uint256 winnerStake = passed ? claim.totalStakedFor : claim.totalStakedAgainst;
        uint256 loserStake = passed ? claim.totalStakedAgainst : claim.totalStakedFor;

        slashedAmount = (loserStake * slashPercent) / 100;
        rewardAmount = (slashedAmount * rewardPercent) / 100;

        totalSlashed += slashedAmount;
        totalRewarded += rewardAmount;

        settlementResults[claimId] = SettlementResult({
            passed: passed,
            totalRewards: rewardAmount,
            totalSlashed: slashedAmount,
            winnerStake: winnerStake,
            loserStake: loserStake
        });
    }

    function claimSettlementRewards(uint256 claimId) external nonReentrant {
        Claim storage claim = claims[claimId];
        require(claim.settled, "Claim not settled");

        Vote storage vote = votes[claimId][msg.sender];
        require(vote.voted, "No vote cast");
        require(!vote.rewardClaimed, "Rewards already claimed");

        SettlementResult storage settlement = settlementResults[claimId];
        require(settlement.winnerStake > 0, "No winners");

        bool isWinner = (vote.support == settlement.passed);
        require(isWinner, "Not a winner");

        uint256 reward = (vote.stakeAmount * settlement.totalRewards) / settlement.winnerStake;
        vote.rewardClaimed = true;

        if (reward > 0) {
            require(bountyToken.transfer(msg.sender, reward), "Reward transfer failed");
            emit RewardsDistributed(claimId, msg.sender, reward);
        }

        if (!vote.stakeReturned) {
            vote.stakeReturned = true;
            verifierStakes[msg.sender].activeStakes -= vote.stakeAmount;
            require(bountyToken.transfer(msg.sender, vote.stakeAmount), "Stake transfer failed");
        }
    }

    function withdrawSettledStake(uint256 claimId) external nonReentrant {
        Claim storage claim = claims[claimId];
        require(claim.settled, "Claim not settled");

        Vote storage vote = votes[claimId][msg.sender];
        require(vote.voted, "No vote cast");
        require(!vote.stakeReturned, "Stake already returned");

        SettlementResult storage settlement = settlementResults[claimId];

        bool isWinner = (vote.support == settlement.passed);
        require(!isWinner, "Winners should use claimSettlementRewards");

        // Calculate slashed portion
        uint256 slashedAmount = (vote.stakeAmount * slashPercent) / 100;
        uint256 returnAmount = vote.stakeAmount - slashedAmount;

        vote.stakeReturned = true;

        // Update accounting
        verifierStakes[msg.sender].activeStakes -= vote.stakeAmount;

        // Transfer remaining stake
        if (returnAmount > 0) {
            require(
                bountyToken.transfer(msg.sender, returnAmount),
                "Stake transfer failed"
            );
        }

        emit StakeWithdrawn(msg.sender, returnAmount);
    }

    function withdrawStake(uint256 amount) external nonReentrant {
        VerifierStake storage stake = verifierStakes[msg.sender];
        require(stake.totalStaked >= stake.activeStakes + amount, "Insufficient available stake");

        stake.totalStaked -= amount;
        require(bountyToken.transfer(msg.sender, amount), "Transfer failed");

        emit StakeWithdrawn(msg.sender, amount);
    }

    function getClaim(uint256 claimId) external view returns (Claim memory) {
        return claims[claimId];
    }

    function getVote(uint256 claimId, address verifier) external view returns (Vote memory) {
        return votes[claimId][verifier];
    }

    function getVerifierStake(address verifier) external view returns (VerifierStake memory) {
        return verifierStakes[verifier];
    }

    // ============ Governance Parameter Updates ============
    
    /**
     * @notice Update verification window duration ( governance or admin )
     * @param newDuration New duration in seconds
     */
    function setVerificationWindowDuration(uint256 newDuration) external onlyGovernanceOrAdmin {
        require(newDuration >= 1 days && newDuration <= 30 days, "Invalid duration");
        
        uint256 oldDuration = verificationWindowDuration;
        verificationWindowDuration = newDuration;
        
        emit ParameterUpdatedByGovernance(GOVERNANCE_PARAM_VERIFICATION_WINDOW, oldDuration, newDuration);
    }
    
    /**
     * @notice Update minimum stake amount ( governance or admin )
     * @param newAmount New minimum stake amount
     */
    function setMinStakeAmount(uint256 newAmount) external onlyGovernanceOrAdmin {
        require(newAmount > 0, "Invalid amount");
        
        uint256 oldAmount = minStakeAmount;
        minStakeAmount = newAmount;
        
        emit ParameterUpdatedByGovernance(GOVERNANCE_PARAM_MIN_STAKE, oldAmount, newAmount);
    }
    
    /**
     * @notice Update settlement threshold percentage ( governance or admin )
     * @param newThreshold New threshold ( 1-100 )
     */
    function setSettlementThresholdPercent(uint256 newThreshold) external onlyGovernanceOrAdmin {
        require(newThreshold > 0 && newThreshold <= 100, "Invalid threshold");
        
        uint256 old = settlementThresholdPercent;
        settlementThresholdPercent = newThreshold;
        
        emit ParameterUpdatedByGovernance(GOVERNANCE_PARAM_THRESHOLD, old, newThreshold);
    }
    
    /**
     * @notice Update reward percentage ( governance or admin )
     * @param newPercent New reward percent ( 1-100 )
     */
    function setRewardPercent(uint256 newPercent) external onlyGovernanceOrAdmin {
        require(newPercent > 0 && newPercent <= 100, "Invalid percent");
        
        uint256 old = rewardPercent;
        rewardPercent = newPercent;
        
        emit ParameterUpdatedByGovernance(GOVERNANCE_PARAM_REWARD, old, newPercent);
    }
    
    /**
     * @notice Update slash percentage ( governance or admin )
     * @param newPercent New slash percent ( 1-100 )
     */
    function setSlashPercent(uint256 newPercent) external onlyGovernanceOrAdmin {
        require(newPercent > 0 && newPercent <= 100, "Invalid percent");
        
        uint256 old = slashPercent;
        slashPercent = newPercent;
        
        emit ParameterUpdatedByGovernance(GOVERNANCE_PARAM_SLASH, old, newPercent);
    }

    // ============ Admin & Pauser Functions ============

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
}
