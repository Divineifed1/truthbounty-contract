import { expect } from "chai";
import { ethers } from "hardhat";
import { TruthBounty, TruthBountyToken } from "../typechain-types";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";

describe("Claim Existence Fix", function () {
    let truthBounty: TruthBounty;
    let bountyToken: TruthBountyToken;
    let owner: SignerWithAddress;
    let verifier: SignerWithAddress;

    beforeEach(async function () {
        [owner, verifier] = await ethers.getSigners();

        // Deploy token contract
        const TokenFactory = await ethers.getContractFactory("TruthBountyToken");
        bountyToken = await TokenFactory.deploy(owner.address);

        // Deploy main TruthBounty contract
        const TruthBountyFactory = await ethers.getContractFactory("TruthBounty");
        truthBounty = await TruthBountyFactory.deploy(
            await bountyToken.getAddress(),
            owner.address,
            owner.address
        );

        // Setup roles
        await bountyToken.grantRole(await bountyToken.RESOLVER_ROLE(), await truthBounty.getAddress());
    });

    describe("Claim Existence Check Fix", function () {
        it("Should prevent voting on non-existent claim 0", async function () {
            const stakeAmount = ethers.parseEther("100");
            
            // Mint and stake tokens for verifier
            await bountyToken.mint(verifier.address, stakeAmount * 2);
            await bountyToken.connect(verifier).approve(await truthBounty.getAddress(), stakeAmount * 2);
            await truthBounty.connect(verifier).stake(stakeAmount);

            // Attempt to vote on claim 0 (which doesn't exist)
            await expect(
                truthBounty.connect(verifier).vote(0, true, stakeAmount)
            ).to.be.revertedWith("Claim does not exist");
        });

        it("Should prevent settling non-existent claim 0", async function () {
            // Attempt to settle claim 0 (which doesn't exist)
            await expect(
                truthBounty.settleClaim(0)
            ).to.be.revertedWith("Claim does not exist");
        });

        it("Should allow voting on existing claim", async function () {
            const stakeAmount = ethers.parseEther("100");
            
            // Mint and stake tokens for verifier
            await bountyToken.mint(verifier.address, stakeAmount * 2);
            await bountyToken.connect(verifier).approve(await truthBounty.getAddress(), stakeAmount * 2);
            await truthBounty.connect(verifier).stake(stakeAmount);

            // Create a claim
            const claimId = await truthBounty.createClaim("QmTest123");

            // Should be able to vote on the created claim
            await expect(
                truthBounty.connect(verifier).vote(claimId, true, stakeAmount)
            ).to.not.be.reverted;
        });

        it("Should allow settling existing claim after verification window", async function () {
            const stakeAmount = ethers.parseEther("100");
            
            // Mint and stake tokens for verifier
            await bountyToken.mint(verifier.address, stakeAmount * 2);
            await bountyToken.connect(verifier).approve(await truthBounty.getAddress(), stakeAmount * 2);
            await truthBounty.connect(verifier).stake(stakeAmount);

            // Create a claim
            const claimId = await truthBounty.createClaim("QmTest123");

            // Vote on the claim
            await truthBounty.connect(verifier).vote(claimId, true, stakeAmount);

            // Fast forward past verification window (7 days)
            await ethers.provider.send("evm_increaseTime", [7 * 24 * 60 * 60 + 1]);
            await ethers.provider.send("evm_mine", []);

            // Should be able to settle the claim
            await expect(
                truthBounty.settleClaim(claimId)
            ).to.not.be.reverted;
        });
    });
});
