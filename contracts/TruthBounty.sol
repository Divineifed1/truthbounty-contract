// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title TruthBountyToken
 * @notice ERC20 token for TruthBounty rewards with staking capabilities
 */
contract TruthBountyToken is ERC20, Ownable {
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

    modifier onlySettlement() {
        require(msg.sender == settlementContract, "Unauthorized slashing");
        _;
    }

    constructor() ERC20("TruthBounty", "BOUNTY") Ownable(msg.sender) {
        _mint(msg.sender, 10_000_000 * 10 ** decimals());
    }

    function setSettlementContract(address _settlement) external onlyOwner {
        settlementContract = _settlement;
    }

    function setSlashPercentage(uint256 percentage) external onlyOwner {
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
    ) external onlySettlement {
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
contract TruthBounty is Ownable, ReentrancyGuard {
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

    // Configuration
    uint256 public constant VERIFICATION_WINDOW_DURATION = 7 days;
    uint256 public constant MIN_STAKE_AMOUNT = 100 * 10**18;
    uint256 public constant SETTLEMENT_THRESHOLD_PERCENT = 60;
    uint256 public constant REWARD_PERCENT = 80;
    uint256 public constant SLASH_PERCENT = 20;

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

    constructor(address _bountyToken) Ownable(msg.sender) {
        require(_bountyToken != address(0), "Invalid token address");
        bountyToken = IERC20(_bountyToken);
    }

    function createClaim(string memory content) external returns (uint256) {
        uint256 claimId = claimCounter++;
        uint256 verificationWindowEnd = block.timestamp + VERIFICATION_WINDOW_DURATION;

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

    function stake(uint256 amount) external nonReentrant {
        require(amount >= MIN_STAKE_AMOUNT, "Stake below minimum");
        require(bountyToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");

        verifierStakes[msg.sender].totalStaked += amount;

        emit StakeDeposited(msg.sender, amount);
    }

    function vote(uint256 claimId, bool support, uint256 stakeAmount) external nonReentrant {
        Claim storage claim = claims[claimId];
        require(claim.id == claimId, "Claim does not exist");
        require(block.timestamp < claim.verificationWindowEnd, "Verification window closed");
        require(!claim.settled, "Claim already settled");
        require(!votes[claimId][msg.sender].voted, "Already voted");
        require(stakeAmount >= MIN_STAKE_AMOUNT, "Stake below minimum");
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
        require(claim.id == claimId, "Claim does not exist");
        require(block.timestamp >= claim.verificationWindowEnd, "Verification window not closed");
        require(!claim.settled, "Claim already settled");
        require(claim.totalStakeAmount > 0, "No votes cast");

        claim.settled = true;
        bool passed = _determineOutcome(claim.totalStakedFor, claim.totalStakedAgainst);

        (uint256 rewardAmount, uint256 slashedAmount) = _calculateSettlement(claimId, passed);

        emit ClaimSettled(claimId, passed, claim.totalStakedFor, claim.totalStakedAgainst, rewardAmount, slashedAmount);
    }

    function _determineOutcome(uint256 stakedFor, uint256 stakedAgainst) internal pure returns (bool) {
        uint256 totalStake = stakedFor + stakedAgainst;
        if (totalStake == 0) return false;
        uint256 forPercent = (stakedFor * 100) / totalStake;
        return forPercent >= SETTLEMENT_THRESHOLD_PERCENT;
    }

    function _calculateSettlement(uint256 claimId, bool passed) internal returns (uint256 rewardAmount, uint256 slashedAmount) {
        Claim storage claim = claims[claimId];
        uint256 winnerStake = passed ? claim.totalStakedFor : claim.totalStakedAgainst;
        uint256 loserStake = passed ? claim.totalStakedAgainst : claim.totalStakedFor;

        slashedAmount = (loserStake * SLASH_PERCENT) / 100;
        rewardAmount = (slashedAmount * REWARD_PERCENT) / 100;

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
}
