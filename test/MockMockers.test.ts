import {ethers, network} from "hardhat";
import {expect} from "chai";
import {toWei, toUnit, fromUnit, fromWei, createContract} from "../scripts/deployUtils";
import {BigNumber} from "ethers";
import {
  SimpleERC20,
  MockMuxOrderBook,
  MockMuxLiquidityPool,
  MockAToken,
  MockAavePool,
  MockUniswapV3,
  MockRewardRouter,
} from "../typechain";
import {deployDep} from "./mockers";

describe("Mock-mockers", async () => {
  let admin;
  let alice;
  let bob;
  let keeper;

  let dep;

  // let senior;
  // let seniorConfig;
  // let junior;
  // let juniorConfig;
  // let router;
  // let routerConfig;
  // let rewardController;
  // let seniorReward;
  // let juniorReward;

  beforeEach(async () => {
    const accounts = await ethers.getSigners();
    admin = accounts[0];
    alice = accounts[1];
    bob = accounts[2];
    keeper = accounts[3];

    dep = await deployDep();
  });

  it("mock mux orderbook", async () => {
    await dep.orderBook.setBlockTime(86400 + 0);
    await dep.usdc.mint(alice.address, toUnit("200", 6));
    await dep.usdc.connect(alice).approve(dep.orderBook.address, toUnit("200", 6));
    await dep.orderBook.connect(alice).placeLiquidityOrder(0, toUnit("200", 6), true);
    expect(await dep.usdc.balanceOf(alice.address)).to.equal(toUnit("0", 6));
    expect(await dep.mlp.balanceOf(alice.address)).to.equal(toWei("0"));
    await dep.orderBook.setBlockTime(86400 + 15 * 60);
    await dep.orderBook
      .connect(keeper)
      .fillLiquidityOrder(1, toWei("1"), toWei("1.2"), toWei("0"), toWei("0"));
    expect(await dep.mlp.balanceOf(alice.address)).to.equal(toWei("166.55")); // 200 * 1 / 1.2 * (1 - 0.0007)
  });

  it("mock mux: stake, claim, claim", async () => {
    // stake
    await dep.rewardRouter.setBlockTime(86400 + 0);
    await dep.mlp.mint(alice.address, toWei("1000000"));
    await dep.mlp.connect(alice).approve(dep.rewardRouter.address, toWei("1000000"));
    await dep.rewardRouter.connect(alice).stakeMlp(toWei("1000000"));
    expect(await dep.mlp.balanceOf(alice.address)).to.equal(toWei("0"));
    expect(await dep.smlp.balanceOf(alice.address)).to.equal(toWei("1000000"));

    // claim
    await dep.rewardRouter.setBlockTime(86400 + 86400 * 365);
    await dep.rewardRouter.connect(alice).claimAll();
    expect(await dep.weth.balanceOf(alice.address)).to.equal(toWei("66.666662496")); // 0.20*1000000/3000.0
    expect(await dep.mcb.balanceOf(alice.address)).to.equal(toWei("34999.999986384000000000")); // 0.07*1000000/2.0

    // claim2
    await dep.rewardRouter.setBlockTime(86400 + 86400 * 365 * 2);
    await dep.rewardRouter.connect(alice).claimAll();
    expect(await dep.weth.balanceOf(alice.address)).to.equal(toWei("133.333324992")); // 0.20*1000000/3000.0 * 2
    expect(await dep.mcb.balanceOf(alice.address)).to.equal(toWei("69999.999972768")); // 0.07*1000000/2.0 * 2
  });

  it("mock mux: stake, stake, claim", async () => {
    // stake 1000000
    await dep.rewardRouter.setBlockTime(86400 + 0);
    await dep.mlp.mint(alice.address, toWei("1000000"));
    await dep.mlp.connect(alice).approve(dep.rewardRouter.address, toWei("1000000"));
    await dep.rewardRouter.connect(alice).stakeMlp(toWei("1000000"));
    expect(await dep.mlp.balanceOf(alice.address)).to.equal(toWei("0"));
    expect(await dep.smlp.balanceOf(alice.address)).to.equal(toWei("1000000"));

    // stake 1000000
    await dep.rewardRouter.setBlockTime(86400 + 86400 * 365);
    await dep.mlp.mint(alice.address, toWei("1000000"));
    await dep.mlp.connect(alice).approve(dep.rewardRouter.address, toWei("1000000"));
    await dep.rewardRouter.connect(alice).stakeMlp(toWei("1000000"));
    expect(await dep.mlp.balanceOf(alice.address)).to.equal(toWei("0"));
    expect(await dep.smlp.balanceOf(alice.address)).to.equal(toWei("2000000"));

    // claim
    await dep.rewardRouter.setBlockTime(86400 + 86400 * 365 * 2);
    await dep.rewardRouter.connect(alice).claimAll();
    expect(await dep.weth.balanceOf(alice.address)).to.equal(toWei("199.999987488")); // 0.20*1000000/3000.0 + 0.20*2000000/3000.0
    expect(await dep.mcb.balanceOf(alice.address)).to.equal(toWei("104999.999959152")); // 0.07*1000000/2.0 + 0.07*2000000/2.0
  });

  it("mock aave: deposit, withdraw, claim", async () => {
    // deposit
    await dep.ausdc.setBlockTime(86400 + 0);
    await dep.aaveRewardsController.setBlockTime(86400 + 0);
    await dep.usdc.mint(alice.address, toUnit("100", 6));
    await dep.usdc.connect(alice).approve(dep.aavePool.address, toUnit("100", 6));
    await dep.aavePool
      .connect(alice)
      .supply(dep.usdc.address, toUnit("100", 6), alice.address, 0 /* referral */);
    expect(await dep.usdc.balanceOf(alice.address)).to.equal(toUnit("0", 6));
    expect(await dep.ausdc.balanceOf(alice.address)).to.equal(toUnit("100", 6));

    // withdraw
    await dep.ausdc.setBlockTime(86400 + 86400 * 365);
    await dep.aaveRewardsController.setBlockTime(86400 + 86400 * 365);
    expect(await dep.ausdc.balanceOf(alice.address)).to.equal(toUnit("105", 6));
    await dep.aavePool.connect(alice).withdraw(dep.usdc.address, toUnit("105", 6), alice.address);
    expect(await dep.usdc.balanceOf(alice.address)).to.equal(toUnit("105", 6));
    expect(await dep.ausdc.balanceOf(alice.address)).to.equal(toUnit("0", 6));
    expect(
      await dep.aaveRewardsController.callStatic.getUserRewards(
        [dep.ausdc.address],
        alice.address,
        dep.arb.address
      )
    ).to.equal(toWei("1.050000000537600000")); // 105 * 0.01

    // claim
    await dep.aaveRewardsController
      .connect(alice)
      .claimRewards([dep.ausdc.address], toWei("123456"), alice.address, dep.arb.address);
    expect(await dep.arb.balanceOf(alice.address)).to.equal(toWei("1.050000000537600000"));
  });

  it("mock aave: large deposit + deposit", async () => {
    // deposit
    await dep.ausdc.setBlockTime(86400 + 0);
    await dep.aaveRewardsController.setBlockTime(86400 + 0);
    await dep.usdc.mint(alice.address, toUnit("8901234567890.654321", 6));
    await dep.usdc.connect(alice).approve(dep.aavePool.address, toUnit("8901234567890.654321", 6));
    await dep.aavePool
      .connect(alice)
      .supply(dep.usdc.address, toUnit("8901234567890.654321", 6), alice.address, 0 /* referral */);
    expect(await dep.usdc.balanceOf(alice.address)).to.equal(toUnit("0", 6));
    expect(await dep.ausdc.balanceOf(alice.address)).to.equal(toUnit("8901234567890.654321", 6));

    // deposit again
    await dep.ausdc.setBlockTime(86400 + 86400 * 365);
    await dep.aaveRewardsController.setBlockTime(86400 + 86400 * 365);
    expect(await dep.ausdc.balanceOf(alice.address)).to.equal(toUnit("9346296296285.187037", 6)); // 105%
    await dep.usdc.mint(alice.address, toUnit("8901234567890.654321", 6));
    await dep.usdc.connect(alice).approve(dep.aavePool.address, toUnit("8901234567890.654321", 6));
    await dep.aavePool
      .connect(alice)
      .supply(dep.usdc.address, toUnit("8901234567890.654321", 6), alice.address, 0 /* referral */);
    expect(await dep.usdc.balanceOf(alice.address)).to.equal(toUnit("0", 6));
    expect(await dep.ausdc.balanceOf(alice.address)).to.equal(toUnit("18247530864175.841358", 6)); // += 8901234567890.654321
  });

  it("mock aave: partial withdraw", async () => {
    // deposit
    await dep.ausdc.setBlockTime(86400 + 0);
    await dep.aaveRewardsController.setBlockTime(86400 + 0);
    await dep.usdc.mint(alice.address, toUnit("100", 6));
    await dep.usdc.connect(alice).approve(dep.aavePool.address, toUnit("100", 6));
    await dep.aavePool
      .connect(alice)
      .supply(dep.usdc.address, toUnit("100", 6), alice.address, 0 /* referral */);
    expect(await dep.usdc.balanceOf(alice.address)).to.equal(toUnit("0", 6));
    expect(await dep.ausdc.balanceOf(alice.address)).to.equal(toUnit("100", 6));

    // withdraw
    await dep.ausdc.setBlockTime(86400 + 86400 * 365);
    await dep.aaveRewardsController.setBlockTime(86400 + 86400 * 365);
    expect(await dep.ausdc.balanceOf(alice.address)).to.equal(toUnit("105", 6));
    await dep.aavePool.connect(alice).withdraw(dep.usdc.address, toUnit("5", 6), alice.address);
    expect(await dep.usdc.balanceOf(alice.address)).to.equal(toUnit("5", 6));
    expect(await dep.ausdc.balanceOf(alice.address)).to.equal(toUnit("99.999999", 6));
    expect(
      await dep.aaveRewardsController.callStatic.getUserRewards(
        [dep.ausdc.address],
        alice.address,
        dep.arb.address
      )
    ).to.equal(toWei("1.050000000537600000")); // 105 * 0.01
  });

  it("mock aave: large deposit + partial withdraw", async () => {
    // deposit
    await dep.ausdc.setBlockTime(86400 + 0);
    await dep.aaveRewardsController.setBlockTime(86400 + 0);
    await dep.usdc.mint(alice.address, toUnit("8901234567890.654321", 6));
    await dep.usdc.connect(alice).approve(dep.aavePool.address, toUnit("8901234567890.654321", 6));
    await dep.aavePool
      .connect(alice)
      .supply(dep.usdc.address, toUnit("8901234567890.654321", 6), alice.address, 0 /* referral */);
    expect(await dep.usdc.balanceOf(alice.address)).to.equal(toUnit("0", 6));
    expect(await dep.ausdc.balanceOf(alice.address)).to.equal(toUnit("8901234567890.654321", 6));

    // withdraw
    await dep.ausdc.setBlockTime(86400 + 86400 * 365);
    await dep.aaveRewardsController.setBlockTime(86400 + 86400 * 365);
    expect(await dep.ausdc.balanceOf(alice.address)).to.equal(toUnit("9346296296285.187037", 6)); // 105%
    await dep.aavePool
      .connect(alice)
      .withdraw(dep.usdc.address, toUnit("445061728394.532720", 6), alice.address); // withdraw 5%
    expect(await dep.usdc.balanceOf(alice.address)).to.equal(toUnit("445061728394.532720", 6));
    expect(await dep.ausdc.balanceOf(alice.address)).to.equal(toUnit("8901234567890.654317", 6));
  });

  it("mock aave: deposit, claim, claim", async () => {
    // deposit
    await dep.ausdc.setBlockTime(86400 + 0);
    await dep.aaveRewardsController.setBlockTime(86400 + 0);
    await dep.usdc.mint(alice.address, toUnit("100", 6));
    await dep.usdc.connect(alice).approve(dep.aavePool.address, toUnit("100", 6));
    await dep.aavePool
      .connect(alice)
      .supply(dep.usdc.address, toUnit("100", 6), alice.address, 0 /* referral */);
    expect(await dep.usdc.balanceOf(alice.address)).to.equal(toUnit("0", 6));
    expect(await dep.ausdc.balanceOf(alice.address)).to.equal(toUnit("100", 6));

    // claim
    await dep.ausdc.setBlockTime(86400 + 86400 * 365);
    await dep.aaveRewardsController.setBlockTime(86400 + 86400 * 365);
    expect(await dep.ausdc.balanceOf(alice.address)).to.equal(toUnit("105", 6)); // 100 * 0.05
    await dep.aaveRewardsController
      .connect(alice)
      .claimRewards([dep.ausdc.address], toWei("123456"), alice.address, dep.arb.address);
    expect(await dep.arb.balanceOf(alice.address)).to.equal(toWei("1.050000000537600000")); // 105 * 0.01

    // claim 2
    await dep.ausdc.setBlockTime(86400 + 86400 * 365 * 2);
    await dep.aaveRewardsController.setBlockTime(86400 + 86400 * 365 * 2);
    expect(await dep.ausdc.balanceOf(alice.address)).to.equal(toUnit("110", 6)); // 100 * 0.05 * 2
    await dep.aaveRewardsController
      .connect(alice)
      .claimRewards([dep.ausdc.address], toWei("123456"), alice.address, dep.arb.address);
    expect(await dep.arb.balanceOf(alice.address)).to.equal(toWei("2.150000001100800000")); // 105 * 0.01 + 110 * 0.01
  });

  it("mock uniswap", async () => {
    // mcb -> usdc
    expect(
      await dep.uniswap.quoteExactInput(
        dep.mcb.address + "0001f4" + dep.usdc.address.slice(2),
        toWei("1")
      )
    ).to.equal(toUnit("2", 6));
    await dep.mcb.mint(alice.address, toWei("1"));
    await dep.mcb.connect(alice).approve(dep.uniswap.address, toWei("1"));
    await dep.uniswap.connect(alice).exactInput({
      path: dep.mcb.address + "0001f4" + dep.usdc.address.slice(2),
      recipient: alice.address,
      deadline: 0,
      amountIn: toWei("1"),
      amountOutMinimum: toUnit("0", 6),
    });
    expect(await dep.mcb.balanceOf(alice.address)).to.equal(toWei("0"));
    expect(await dep.usdc.balanceOf(alice.address)).to.equal(toUnit("2", 6));

    // weth -> usdc
    await dep.weth.mint(alice.address, toWei("1"));
    await dep.weth.connect(alice).approve(dep.uniswap.address, toWei("1"));
    await dep.uniswap.connect(alice).exactInput({
      path: dep.weth.address + "0001f4" + dep.usdc.address.slice(2),
      recipient: alice.address,
      deadline: 0,
      amountIn: toWei("1"),
      amountOutMinimum: toUnit("0", 6),
    });
    expect(await dep.weth.balanceOf(alice.address)).to.equal(toWei("0"));
    expect(await dep.usdc.balanceOf(alice.address)).to.equal(toUnit("3002", 6));
  });
});
