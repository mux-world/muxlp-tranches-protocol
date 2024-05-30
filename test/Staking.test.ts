import {ethers, network} from "hardhat";
import {expect} from "chai";
import {toWei, toUnit, fromWei, createContract} from "../scripts/deployUtils";
import {BigNumber} from "ethers";
import {impersonateAccount, setBalance, time} from "@nomicfoundation/hardhat-network-helpers";

const U = ethers.utils;
const B = ethers.BigNumber;
const toUsd = (x) => toUnit(x, 6);

describe("Staking", async () => {
  let user0;
  let user1;
  let alice;
  let bob;
  let keeper;

  let weth;
  let usdc;
  let mlp;
  let mux;
  let mcb;

  let junior;
  let juniorConfig;
  let rewardController;
  let seniorReward;
  let juniorReward;

  let liquidityPool;
  let rewardRouter;
  let feeDist;
  let muxDist;
  let fmlp;
  let smlp;
  let vester;

  const a2b = (a) => {
    return a + "000000000000000000000000";
  };
  const u2b = (u) => {
    return ethers.utils.hexZeroPad(u.toHexString(), 32);
  };

  async function deployTestSuite() {
    const accounts = await ethers.getSigners();

    const pol = accounts[8];

    weth = await createContract("SimpleERC20", ["WETH", "WETH", 18]);
    usdc = await createContract("SimpleERC20", ["USD", "USD", 6]);
    mux = await createContract("SimpleERC20", ["MUX", "MUX", 18]);
    mcb = await createContract("SimpleERC20", ["MCB", "MCB", 18]);
    mlp = await createContract("SimpleERC20", ["MLP", "MLP", 18]);

    const placeholder = await createContract("PlaceHolder", [mux.address]);

    rewardRouter = await createContract("RewardRouter");
    feeDist = await createContract("FeeDistributor");
    muxDist = await createContract("MuxDistributor");
    fmlp = await createContract("MlpRewardTracker");
    smlp = await createContract("MlpRewardTracker");
    vester = await createContract("Vester");
    await rewardRouter.initialize(
      [weth.address, mcb.address, mux.address, mlp.address, placeholder.address],
      [fmlp.address, smlp.address, placeholder.address, placeholder.address],
      [vester.address, placeholder.address],
      [feeDist.address, muxDist.address]
    );
    await rewardRouter.setProtocolLiquidityOwner(pol.address);
    await rewardRouter.setVault(pol.address);
    await feeDist.initialize(
      weth.address,
      rewardRouter.address,
      fmlp.address,
      placeholder.address,
      toWei("0.7") // por feeRate
    );
    await muxDist.initialize(
      mux.address,
      rewardRouter.address,
      smlp.address,
      placeholder.address,
      1688601600 // start time 6.15
    );
    await vester.initialize(
      "Vested MLP",
      "vMLP",
      86400 * 365, // vesting period 1 year
      mux.address,
      smlp.address, // pair token
      mcb.address,
      smlp.address, // tracker
      false
    );
    await fmlp.initialize("Fee MLP", "fMLP", [mlp.address], feeDist.address);
    await smlp.initialize("Staked MLP", "sMLP", [fmlp.address], muxDist.address);

    await fmlp.setHandler(rewardRouter.address, true);
    await smlp.setHandler(rewardRouter.address, true);
    await vester.setHandler(rewardRouter.address, true);
    await fmlp.setHandler(smlp.address, true);
    await smlp.setHandler(vester.address, true);

    await mux.grantRole(ethers.utils.id("MINTER_ROLE"), muxDist.address);
    await mux.grantRole(ethers.utils.id("MINTER_ROLE"), vester.address);
    // await mux.setHandler(smlp.address, true);
    // await mux.setHandler(vester.address, true);
    await mcb.mint(vester.address, toWei("1000000"));

    liquidityPool = await createContract("MockMuxLiquidityPool");
    await liquidityPool.addAsset(weth.address);
    await liquidityPool.addAsset(usdc.address);
  }

  beforeEach(async () => {
    const accounts = await ethers.getSigners();
    user0 = accounts[0];
    user1 = accounts[1];
    alice = accounts[2];
    bob = accounts[3];
    keeper = accounts[4];

    await deployTestSuite();

    junior = await createContract("JuniorVault");
    juniorConfig = await createContract("JuniorConfig", [junior.address]);

    await junior.initialize("JUNIOR", "JUN", smlp.address, mlp.address);
    await junior.grantRole(ethers.utils.id("HANDLER_ROLE"), user0.address);
    await junior.grantRole(ethers.utils.id("CONFIG_ROLE"), juniorConfig.address);
    rewardController = await createContract("RewardController");
    seniorReward = await createContract("RewardDistributor");
    juniorReward = await createContract("RewardDistributor");
    await juniorReward.initialize("J", "J", usdc.address, junior.address);

    await juniorConfig.setMuxRewardRouter(rewardRouter.address);
    await juniorConfig.setMuxLiquidityPool(liquidityPool.address);
  });

  it("senior deposit / withdraw", async () => {
    await mlp.mint(junior.address, toWei("100"));
    await junior.collectRewards(user1.address);
    await junior.deposit(toWei("100"), alice.address);
    // await junior.withdraw(toWei("1000"));
    await time.setNextBlockTimestamp(1688601600);

    await weth.mint(user0.address, toWei("100"));
    await weth.approve(feeDist.address, toWei("100"));
    await feeDist.notifyReward(toWei("100"));
    console.log("-------------------------------------------------------------");

    await time.setNextBlockTimestamp(1688601600 + 86400 * 7);
    await junior.collectRewards(user1.address);
    console.log("-------------------------------------------------------------");

    await time.setNextBlockTimestamp(1688601600 + 86400 * 7 + 86400);
    await junior.collectRewards(user1.address);
    console.log("-------------------------------------------------------------");

    await time.setNextBlockTimestamp(1688601600 + 86400 * 7 + 86400 * 2);
    await junior.collectRewards(user1.address);
    await junior.withdraw(alice.address, alice.address, toWei("50"), user1.address);

    await time.setNextBlockTimestamp(1688601600 + 86400 * 7 + 86400 * 7);
    console.log("-------------------------------------------------------------");
    await junior.collectRewards(user1.address);
  });
});
