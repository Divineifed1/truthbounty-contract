// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title TruthBountyClaims
 * @dev Handles batched claim settlements for TruthBounty protocols.
 *      Focuses on gas efficiency and loop safety.
 */
contract TruthBountyClaims is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Roles ============

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");
    IERC20 public immutable bountyToken;

    event ClaimSettled(address indexed beneficiary, uint256 amount);
    event BatchSettlementCompleted(uint256 count);

    // Max batch size to prevent out-of-gas errors
    uint256 public constant MAX_BATCH_SIZE = 200;

    constructor(address _tokenAddress, address initialAdmin) {
        require(_tokenAddress != address(0), "Invalid token address");
        require(initialAdmin != address(0), "Invalid admin address");
        
        bountyToken = IERC20(_tokenAddress);
        
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(ADMIN_ROLE, initialAdmin);
        _grantRole(TREASURY_ROLE, initialAdmin); // Default admin also gets treasury role
        
        _setRoleAdmin(TREASURY_ROLE, ADMIN_ROLE);
    }

    /**
     * @notice Settles a single claim.
     * @param beneficiary The address receiving the bounty.
     * @param amount The amount of tokens to transfer.
     */
    function settleClaim(address beneficiary, uint256 amount) external onlyRole(TREASURY_ROLE) nonReentrant {
        _settle(beneficiary, amount);
    }

    /**
     * @notice Settles multiple claims in a single transaction for gas efficiency.
     * @param beneficiaries Array of addresses receiving bounties.
     * @param amounts Array of amounts to transfer.
     */
    function settleClaimsBatch(address[] calldata beneficiaries, uint256[] calldata amounts) external onlyRole(TREASURY_ROLE) nonReentrant {
        uint256 length = beneficiaries.length;
        require(length == amounts.length, "Arrays length mismatch");
        require(length > 0, "No claims to settle");
        require(length <= MAX_BATCH_SIZE, "Batch size too large");

        for (uint256 i = 0; i < length; ) {
            // Processing logic
            _settle(beneficiaries[i], amounts[i]);

            // Gas optimization: Unchecked increment
            unchecked {
                ++i;
            }
        }

        emit BatchSettlementCompleted(length);
    }

    /**
     * @dev Internal function to handle the transfer logic.
     */
    function _settle(address beneficiary, uint256 amount) internal {
        require(beneficiary != address(0), "Invalid beneficiary");
        require(amount > 0, "Amount must be > 0");

        // The contract must hold enough tokens to cover the transfer
        bountyToken.safeTransfer(beneficiary, amount);

        emit ClaimSettled(beneficiary, amount);
    }

    /**
     * @notice Allows the owner to recover accidental ERC20 transfers (other than the bounty token, or even the bounty token).
     * @param token The token contract address.
     * @param to The recipient address.
     * @param amount The amount to transfer.
     */
    function rescueTokens(address token, address to, uint256 amount) external onlyRole(TREASURY_ROLE) {
        IERC20(token).safeTransfer(to, amount);
    }
}
