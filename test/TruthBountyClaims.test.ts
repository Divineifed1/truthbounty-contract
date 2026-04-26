import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { expect } from "chai";
import hre from "hardhat";

describe("TruthBountyClaims", function () {
  async function deployFixture() {
    const [owner, otherAccount, beneficiary1, beneficiary2, beneficiary3] =
      await hre.ethers.getSigners();

    // Deploy Token
    const Token = await hre.ethers.getContractFactory("TruthBountyToken");
    const token = await Token.deploy(owner.address);

    // Deploy Mock Failing ERC20
    const MockFailing = await hre.ethers.getContractFactory("MockFailingERC20");
    const failingToken = await MockFailing.deploy();

    // Deploy Claims Contract
    const Claims = await hre.ethers.getContractFactory("TruthBountyClaims");
    const claims = await Claims.deploy(token.target, owner.address);

    // Fund the Claims contract with regular tokens
    const fundAmount = hre.ethers.parseUnits("1000", 18);
    await token.transfer(claims.target, fundAmount);

    // Fund the Claims contract with failing tokens
    await failingToken.transfer(claims.target, fundAmount);

    return {
      token,
      failingToken,
      claims,
      owner,
      otherAccount,
      beneficiary1,
      beneficiary2,
      beneficiary3,
    };
  }

  describe("Settlement", function () {
    it("Should settle a single claim", async function () {
      const { token, claims, beneficiary1 } = await loadFixture(deployFixture);

      const amount = hre.ethers.parseUnits("10", 18);

      await expect(claims.settleClaim(beneficiary1.address, amount))
        .to.emit(claims, "ClaimSettled")
        .withArgs(beneficiary1.address, amount);

      expect(await token.balanceOf(beneficiary1.address)).to.equal(amount);
    });

    it("Should settle a batch of claims", async function () {
      const { token, claims, beneficiary1, beneficiary2, beneficiary3 } =
        await loadFixture(deployFixture);

      const amounts = [
        hre.ethers.parseUnits("10", 18),
        hre.ethers.parseUnits("20", 18),
        hre.ethers.parseUnits("30", 18),
      ];

      const beneficiaries = [
        beneficiary1.address,
        beneficiary2.address,
        beneficiary3.address,
      ];

      await expect(claims.settleClaimsBatch(beneficiaries, amounts))
        .to.emit(claims, "BatchSettlementCompleted")
        .withArgs(3);

      expect(await token.balanceOf(beneficiary1.address)).to.equal(amounts[0]);
      expect(await token.balanceOf(beneficiary2.address)).to.equal(amounts[1]);
      expect(await token.balanceOf(beneficiary3.address)).to.equal(amounts[2]);
    });

    it("Should revert on array mismatch", async function () {
      const { claims, beneficiary1 } = await loadFixture(deployFixture);

      await expect(
        claims.settleClaimsBatch([beneficiary1.address], []),
      ).to.be.revertedWith("Arrays length mismatch");
    });

    it("Should revert if caller is not owner", async function () {
      const { claims, otherAccount, beneficiary1 } =
        await loadFixture(deployFixture);
      await expect(
        claims.connect(otherAccount).settleClaim(beneficiary1.address, 100),
      )
        .to.be.revertedWithCustomError(claims, "AccessControlUnauthorizedAccount");
    });

    it("Gas comparison (Log only)", async function () {
      const { claims, beneficiary1, beneficiary2 } =
        await loadFixture(deployFixture);
      const amount = hre.ethers.parseUnits("10", 18);

      // Estimate gas for single claim
      const gasSingle = await claims.settleClaim.estimateGas(
        beneficiary1.address,
        amount,
      );
      console.log(`Gas for single claim: ${gasSingle.toString()}`);

      // Estimate gas for batch of 2 claims
      const gasBatch = await claims.settleClaimsBatch.estimateGas(
        [beneficiary1.address, beneficiary2.address],
        [amount, amount],
      );
      console.log(`Gas for batch of 2 claims: ${gasBatch.toString()}`);
      console.log(`Average gas per claim in batch: ${Number(gasBatch) / 2}`);

    });
  });

  describe("Rescue Tokens", function () {
    it("Should rescue tokens successfully with normal ERC20", async function () {
      const { token, claims, owner } = await loadFixture(deployFixture);

      const amount = hre.ethers.parseUnits("10", 18);
      const initialBalance = await token.balanceOf(owner.address);

      await expect(claims.rescueTokens(token.target, owner.address, amount))
        .to.not.be.reverted;

      expect(await token.balanceOf(owner.address)).to.equal(initialBalance + amount);
    });

    it("Should revert when rescuing tokens from failing ERC20", async function () {
      const { failingToken, claims, owner } = await loadFixture(deployFixture);

      const amount = hre.ethers.parseUnits("10", 18);

      await expect(claims.rescueTokens(failingToken.target, owner.address, amount))
        .to.be.revertedWith("SafeERC20: ERC20 operation did not succeed");
    });

    it("Should revert if caller does not have TREASURY_ROLE", async function () {
      const { token, claims, otherAccount, owner } = await loadFixture(deployFixture);

      const amount = hre.ethers.parseUnits("10", 18);

      await expect(claims.connect(otherAccount).rescueTokens(token.target, owner.address, amount))
        .to.be.revertedWithCustomError(claims, "AccessControlUnauthorizedAccount");
    });
  });
});
