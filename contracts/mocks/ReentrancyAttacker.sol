// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ReentrancyAttacker
 * @notice Mock contract designed to attempt reentrancy attacks on TruthBounty contracts
 * @dev Used exclusively for testing reentrancy protection
 */
contract ReentrancyAttacker {
    
    // Attack types for different reentrancy vectors
    enum AttackType {
        STAKE,              // Attack during stake()
        UNSTAKE,            // Attack during unstake()
        CLAIM_REWARDS,      // Attack during claimSettlementRewards()
        WITHDRAW_STAKE,     // Attack during withdrawSettledStake()
        DISPUTE_RESOLUTION, // Attack during dispute resolution
        BATCH_CLAIM         // Attack during batch operations
    }
    
    // State for controlling attack behavior
    AttackType public currentAttack;
    uint256 public attackCount;
    uint256 public maxAttacks;
    bool public attacking;
    address public targetContract;
    IERC20 public token;
    
    // Events for test verification
    event AttackStarted(AttackType attackType, uint256 attempt);
    event AttackFailed(string reason);
    event AttackSucceeded(uint256 attackCount);
    event FundsReceived(uint256 amount);
    
    // Errors
    error AttackNotConfigured();
    error TargetNotSet();
    
    constructor(address _token) {
        token = IERC20(_token);
        maxAttacks = 5; // Limit reentrancy attempts
    }
    
    /**
     * @notice Configure the attack parameters
     */
    function configureAttack(
        AttackType _attackType,
        address _target,
        uint256 _maxAttacks
    ) external {
        currentAttack = _attackType;
        targetContract = _target;
        maxAttacks = _maxAttacks;
        attackCount = 0;
        attacking = false;
    }
    
    /**
     * @notice ERC20 receive hook - primary reentrancy entry point
     */
    function onERC20Received(address, uint256 amount) external returns (bool) {
        emit FundsReceived(amount);
        
        if (attacking && attackCount < maxAttacks) {
            attackCount++;
            _executeAttack();
        }
        
        return true;
    }
    
    /**
     * @notice Execute the configured attack
     */
    function executeAttack() external {
        if (targetContract == address(0)) revert TargetNotSet();
        
        attacking = true;
        attackCount = 0;
        
        emit AttackStarted(currentAttack, attackCount);
        
        _executeAttack();
        
        attacking = false;
    }
    
    /**
     * @dev Internal function to execute reentrancy attack based on type
     */
    function _executeAttack() internal {
        // This will be called recursively if reentrancy is possible
        
        if (currentAttack == AttackType.STAKE) {
            // Try to reenter during stake
            _attemptStakeReentrancy();
        } else if (currentAttack == AttackType.UNSTAKE) {
            // Try to reenter during unstake
            _attemptUnstakeReentrancy();
        } else if (currentAttack == AttackType.CLAIM_REWARDS) {
            // Try to reenter during reward claim
            _attemptClaimRewardsReentrancy();
        } else if (currentAttack == AttackType.WITHDRAW_STAKE) {
            // Try to reenter during stake withdrawal
            _attemptWithdrawStakeReentrancy();
        }
    }
    
    /**
     * @dev Attempt to reenter during stake operation
     */
    function _attemptStakeReentrancy() internal {
        // Call stake again during token transfer callback
        (bool success, ) = targetContract.call(
            abi.encodeWithSignature("stake(uint256)", 1 ether)
        );
        
        if (!success) {
            emit AttackFailed("Stake reentrancy blocked");
        }
    }
    
    /**
     * @dev Attempt to reenter during unstake operation
     */
    function _attemptUnstakeReentrancy() internal {
        // Call unstake again during token transfer callback
        (bool success, ) = targetContract.call(
            abi.encodeWithSignature("unstake(uint256)", 1 ether)
        );
        
        if (!success) {
            emit AttackFailed("Unstake reentrancy blocked");
        }
    }
    
    /**
     * @dev Attempt to reenter during claim rewards
     */
    function _attemptClaimRewardsReentrancy() internal {
        // Call claimSettlementRewards again during token transfer
        (bool success, ) = targetContract.call(
            abi.encodeWithSignature("claimSettlementRewards(uint256)", 0)
        );
        
        if (!success) {
            emit AttackFailed("Claim rewards reentrancy blocked");
        }
    }
    
    /**
     * @dev Attempt to reenter during withdraw stake
     */
    function _attemptWithdrawStakeReentrancy() internal {
        // Call withdrawSettledStake again during token transfer
        (bool success, ) = targetContract.call(
            abi.encodeWithSignature("withdrawSettledStake(uint256)", 0)
        );
        
        if (!success) {
            emit AttackFailed("Withdraw stake reentrancy blocked");
        }
    }
    
    /**
     * @notice Standard ERC20 receive for tracking
     */
    receive() external payable {
        emit FundsReceived(msg.value);
    }
    
    /**
     * @notice Fallback for receiving ETH
     */
    fallback() external payable {
        emit FundsReceived(msg.value);
    }
    
    // ==================== Attack Initiators ====================
    
    /**
     * @notice Initiate stake attack - must approve tokens first
     */
    function initiateStakeAttack(uint256 amount) external {
        token.approve(targetContract, amount);
        (bool success, ) = targetContract.call(
            abi.encodeWithSignature("stake(uint256)", amount)
        );
        require(success, "Stake attack failed");
    }
    
    /**
     * @notice Initiate unstake attack
     */
    function initiateUnstakeAttack(uint256 amount) external {
        (bool success, ) = targetContract.call(
            abi.encodeWithSignature("unstake(uint256)", amount)
        );
        require(success, "Unstake attack failed");
    }
    
    /**
     * @notice Initiate claim rewards attack
     */
    function initiateClaimRewardsAttack(uint256 claimId) external {
        (bool success, ) = targetContract.call(
            abi.encodeWithSignature("claimSettlementRewards(uint256)", claimId)
        );
        require(success, "Claim rewards attack failed");
    }
    
    /**
     * @notice Initiate withdraw stake attack
     */
    function initiateWithdrawStakeAttack(uint256 claimId) external {
        (bool success, ) = targetContract.call(
            abi.encodeWithSignature("withdrawSettledStake(uint256)", claimId)
        );
        require(success, "Withdraw stake attack failed");
    }
    
    /**
     * @notice Get attack statistics
     */
    function getAttackStats() external view returns (
        uint256 totalAttempts,
        uint256 maxAllowed,
        bool isAttacking,
        AttackType attackType
    ) {
        return (attackCount, maxAttacks, attacking, currentAttack);
    }
    
    /**
     * @notice Reset attack state
     */
    function resetAttack() external {
        attackCount = 0;
        attacking = false;
    }
}

/**
 * @title MaliciousERC20
 * @notice ERC20 token that attempts reentrancy on transfer
 * @dev Used to test reentrancy through ERC20 callbacks
 */
contract MaliciousERC20 is IERC20 {
    
    string public name = "MaliciousToken";
    string public symbol = "MAL";
    uint8 public decimals = 18;
    
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    
    uint256 public totalSupply;
    address public attacker;
    bool public attackEnabled;
    
    event AttackAttempted(address target, uint256 amount);
    
    constructor(uint256 initialSupply) {
        balanceOf[msg.sender] = initialSupply;
        totalSupply = initialSupply;
    }
    
    function setAttacker(address _attacker) external {
        attacker = _attacker;
    }
    
    function enableAttack(bool enabled) external {
        attackEnabled = enabled;
    }
    
    function transfer(address to, uint256 amount) external returns (bool) {
        return _transfer(msg.sender, to, amount);
    }
    
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        allowance[from][msg.sender] -= amount;
        return _transfer(from, to, amount);
    }
    
    function _transfer(address from, address to, uint256 amount) internal returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        
        emit Transfer(from, to, amount);
        
        // Attempt reentrancy if attack is enabled and this is a transfer to target
        if (attackEnabled && to == attacker) {
            emit AttackAttempted(to, amount);
            // Call attacker callback
            (bool success, ) = attacker.call(
                abi.encodeWithSignature("onERC20Received(address,uint256)", from, amount)
            );
            // Ignore success - we're testing if target contract blocks reentrancy
        }
        
        return true;
    }
    
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
    
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }
    
    // Note: Transfer and Approval events are inherited from IERC20
}

/**
 * @title ReentrancyAttackerV2
 * @notice Advanced attacker with cross-function reentrancy capabilities
 */
contract ReentrancyAttackerV2 {
    
    address public target;
    IERC20 public token;
    uint256 public reentrancyCount;
    uint256 public constant MAX_REENTRANCY = 10;
    
    // Cross-function attack: unstake during stake, etc.
    bool public crossFunctionMode;
    
    event CrossFunctionAttack(string from, string to);
    
    constructor(address _target, address _token) {
        target = _target;
        token = IERC20(_token);
    }
    
    /**
     * @notice Callback that triggers cross-function reentrancy
     */
    function onTokenTransfer(address, uint256, bytes calldata) external returns (bool) {
        if (reentrancyCount >= MAX_REENTRANCY) {
            return true;
        }
        
        reentrancyCount++;
        
        if (crossFunctionMode) {
            // Try different cross-function attacks
            _attemptCrossFunctionAttack();
        }
        
        return true;
    }
    
    function _attemptCrossFunctionAttack() internal {
        // Attempt 1: Unstake during stake
        (bool success1, ) = target.call(
            abi.encodeWithSignature("unstake(uint256)", 1)
        );
        if (!success1) {
            emit CrossFunctionAttack("stake", "unstake");
        }
        
        // Attempt 2: Claim during withdraw
        (bool success2, ) = target.call(
            abi.encodeWithSignature("claimSettlementRewards(uint256)", 0)
        );
        if (!success2) {
            emit CrossFunctionAttack("withdraw", "claim");
        }
        
        // Attempt 3: Stake during claim
        token.approve(target, 1);
        (bool success3, ) = target.call(
            abi.encodeWithSignature("stake(uint256)", 1)
        );
        if (!success3) {
            emit CrossFunctionAttack("claim", "stake");
        }
    }
    
    function setCrossFunctionMode(bool enabled) external {
        crossFunctionMode = enabled;
    }
    
    function reset() external {
        reentrancyCount = 0;
    }
    
    receive() external payable {}
}
