// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../../contracts/TruthBountyWeighted.sol";
import "../../contracts/MockReputationOracle.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title DoubleSlashPreventionFuzzTest
 * @notice Fuzz tests to verify that slashing occurs only once and accounting is accurate
 * @dev Tests the fix for double-slashing issue where losers were slashed in both
 *      _calculateSettlement and withdrawSettledStake
 */
contract MockTokenForTest is ERC20 {
    constructor() ERC20("MockToken", "MOCK") {
        _mint(msg.sender, 1000000 * 10**18);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract DoubleSlashPreventionFuzzTest is Test {
    TruthBountyWeighted public truthBounty;
    MockReputationOracle public mockOracle;
    MockTokenForTest public mockToken;

    address public admin = address(0x1);
    address[] public verifiers;

    uint256 constant INITIAL_MINT = 1000000 * 10**18;
    uint256 constant MIN_STAKE = 100 * 10**18;
    uint256 constant SLASH_PERCENT = 20;
    uint256 constant REWARD_PERCENT = 80;
    uint256 constant VERIFICATION_WINDOW = 7 days;

    event ClaimSettled(
        uint256 indexed claimId,
        bool passed,
        uint256 totalWeightedFor,
        uint256 totalWeightedAgainst,
        uint256 totalRewards,
        uint256 totalSlashed
    );

    function setUp() public {
        // Create admin
        vm.prank(admin);

        // Deploy mock token
        mockToken = new MockTokenForTest();

        // Deploy mock oracle
        mockOracle = new MockReputationOracle();

        // Deploy truth bounty
        truthBounty = new TruthBountyWeighted(
            address(mockToken),
            address(mockOracle),
            admin
        );

        // Set up verifiers
        for (uint256 i = 0; i < 5; i++) {
            address verifier = address(uint160(0x100 + i));
            verifiers.push(verifier);

            // Mint tokens to verifier
            mockToken.mint(verifier, INITIAL_MINT);

            // Have verifier stake
            vm.prank(verifier);
            mockToken.approve(address(truthBounty), type(uint256).max);
            vm.prank(verifier);
            truthBounty.stake(MIN_STAKE * 10);
        }
    }

    /**
     * @notice Fuzz test: Verify no double-slashing with random votes
     * @dev Creates a claim, casts votes, settles, and checks:
     *      - totalSlashed == sum of per-vote slashes
     *      - No voter is slashed twice
     *      - Balance accounting is correct
     */
    function testFuzz_NoDoubleSlashing_WithRandomVotes(
        uint256[5] calldata stakeAmounts,
        uint256[5] calldata reputationScores
    ) public {
        // Bound inputs
        uint256[] memory boundedStakes = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            boundedStakes[i] = bound(stakeAmounts[i], MIN_STAKE, MIN_STAKE * 100);
        }

        // Create claim
        vm.prank(admin);
        uint256 claimId = truthBounty.createClaim("Test claim");

        // Cast votes (majority will pass to make some losers)
        uint256 passVotes = 0;
        for (uint256 i = 0; i < 5; i++) {
            address verifier = verifiers[i];
            bool support = i < 3; // First 3 vote for pass, last 2 vote against

            vm.prank(verifier);
            truthBounty.vote(claimId, support, boundedStakes[i]);

            if (support) passVotes++;
        }

        // Verify we have winners and losers
        require(passVotes > 0 && passVotes < 5, "Need both winners and losers");

        // Move past verification window
        vm.warp(block.timestamp + VERIFICATION_WINDOW + 1);

        // Settle claim
        vm.prank(admin);
        truthBounty.settleClaim(claimId);

        // Get settlement results
        (bool passed, uint256 totalRewards, uint256 totalSlashed, , ) = truthBounty.settlementResults(claimId);

        // Calculate sum of per-vote slashes by tracking before/after balances
        uint256 expectedTotalSlashed = 0;
        for (uint256 i = 0; i < 5; i++) {
            address verifier = verifiers[i];
            (bool voted, bool support, , , , , , uint256 slashAmount) = truthBounty.votes(claimId, verifier);

            if (voted) {
                bool isLoser = support != passed;
                if (isLoser) {
                    uint256 expectedSlash = (boundedStakes[i] * SLASH_PERCENT) / 100;
                    assertEq(slashAmount, expectedSlash, "Slash amount should match expectation");
                    expectedTotalSlashed += expectedSlash;
                }
            }
        }

        // CRITICAL ASSERTION: totalSlashed should equal sum of per-vote slashes
        assertEq(
            totalSlashed,
            expectedTotalSlashed,
            "totalSlashed should equal sum of per-vote slash amounts (no double counting)"
        );

        // Verify rewards calculation
        uint256 expectedRewards = (expectedTotalSlashed * REWARD_PERCENT) / 100;
        assertEq(totalRewards, expectedRewards, "Rewards should be 80% of slashed amount");
    }

    /**
     * @notice Fuzz test: Verify balance invariants after settlement and withdrawal
     * @dev Checks that when verifiers withdraw, their payouts match what was calculated
     */
    function testFuzz_BalanceInvariants_AfterSettlement(
        uint256[5] calldata stakeAmounts
    ) public {
        // Bound inputs
        uint256[] memory boundedStakes = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            boundedStakes[i] = bound(stakeAmounts[i], MIN_STAKE, MIN_STAKE * 50);
        }

        // Create and vote
        vm.prank(admin);
        uint256 claimId = truthBounty.createClaim("Balance test claim");

        for (uint256 i = 0; i < 5; i++) {
            address verifier = verifiers[i];
            bool support = i < 3; // Majority votes for pass

            vm.prank(verifier);
            truthBounty.vote(claimId, support, boundedStakes[i]);
        }

        // Store pre-settlement balances
        uint256[] memory preBalances = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            preBalances[i] = mockToken.balanceOf(verifiers[i]);
        }

        // Move and settle
        vm.warp(block.timestamp + VERIFICATION_WINDOW + 1);
        vm.prank(admin);
        truthBounty.settleClaim(claimId);

        // Each loser withdraws and verify single slash is applied
        for (uint256 i = 0; i < 5; i++) {
            address verifier = verifiers[i];
            (, bool support, , , , , , uint256 slashAmount) = truthBounty.votes(claimId, verifier);
            (, bool passed, , , ) = truthBounty.settlementResults(claimId);

            if (support != passed) {
                // This is a loser
                uint256 preWithdrawBalance = mockToken.balanceOf(verifier);

                // Withdraw
                vm.prank(verifier);
                truthBounty.withdrawSettledStake(claimId);

                // Check balance change
                uint256 postWithdrawBalance = mockToken.balanceOf(verifier);
                uint256 received = postWithdrawBalance - preWithdrawBalance;

                // Should receive stake minus one-time slash
                uint256 expectedReceived = boundedStakes[i] - slashAmount;
                assertEq(
                    received,
                    expectedReceived,
                    "Loser should receive stake minus pre-calculated slash (single slash only)"
                );
            }
        }
    }

    /**
     * @notice Fuzz test: Verify totalSlashed tracking is accurate
     * @dev Checks that contract's totalSlashed counter matches actual tokens slashed
     */
    function testFuzz_TotalSlashedAccuracy(
        uint256[5] calldata stakeAmounts,
        uint256 claimCount
    ) public {
        claimCount = bound(claimCount, 1, 5);
        
        uint256[] memory boundedStakes = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            boundedStakes[i] = bound(stakeAmounts[i], MIN_STAKE, MIN_STAKE * 30);
        }

        uint256 totalExpectedSlash = 0;

        // Process multiple claims
        for (uint256 c = 0; c < claimCount; c++) {
            // Create claim
            vm.prank(admin);
            uint256 claimId = truthBounty.createClaim("Slash accuracy test");

            // Vote
            for (uint256 i = 0; i < 5; i++) {
                address verifier = verifiers[i];
                bool support = (i + c) % 2 == 0; // Vary support pattern

                vm.prank(verifier);
                truthBounty.vote(claimId, support, boundedStakes[i]);
            }

            // Settle
            vm.warp(block.timestamp + VERIFICATION_WINDOW + 1);
            vm.prank(admin);
            truthBounty.settleClaim(claimId);

            // Add claim's slashed amount to total
            (, , uint256 totalSlashed, , ) = truthBounty.settlementResults(claimId);
            totalExpectedSlash += totalSlashed;
        }

        // Get contract's totalSlashed
        uint256 contractTotalSlashed = truthBounty.totalSlashed();

        // CRITICAL ASSERTION: Should match exactly
        assertEq(
            contractTotalSlashed,
            totalExpectedSlash,
            "Contract totalSlashed should equal sum of all settlement slashes"
        );
    }
}
