import {ethers, network} from "hardhat";
import {expect} from "chai";
import {toWei, toUnit, fromUnit, fromWei, createContract} from "../scripts/deployUtils";
import {deployDep, setMockersBlockTime} from "./mockers";

describe("Mock-Cancel", async () => {
  let admin;
  let alice;
  let bob;
  let keeper;

  let dep;

  let senior;
  let seniorConfig;
  let junior;
  let juniorConfig;
  let router;
  let routerConfig;
  let rewardController;
  let seniorReward;
  let juniorReward;

  beforeEach(async () => {
    const accounts = await ethers.getSigners();
    admin = accounts[0];
    alice = accounts[1];
    bob = accounts[2];
    keeper = accounts[3];

    dep = await deployDep();
    await setMockersBlockTime(dep, 86400 + 0);

    senior = await createContract("SeniorVault");
    seniorConfig = await createContract("SeniorConfig", [senior.address]);
    junior = await createContract("JuniorVault");
    juniorConfig = await createContract("JuniorConfig", [junior.address]);
    router = await createContract("RouterV1", [], {
      RouterImp: await createContract("RouterImp", [], {
        RouterJuniorImp: await createContract("RouterJuniorImp"),
        RouterSeniorImp: await createContract("RouterSeniorImp"),
        RouterRebalanceImp: await createContract("RouterRebalanceImp"),
      }),
      RouterJuniorImp: await createContract("RouterJuniorImp"),
      RouterSeniorImp: await createContract("RouterSeniorImp"),
      RouterRebalanceImp: await createContract("RouterRebalanceImp"),
    });
    routerConfig = await createContract("RouterConfig", [router.address]);
    rewardController = await createContract("RewardController");
    seniorReward = await createContract("RewardDistributor");
    juniorReward = await createContract("RewardDistributor");

    await dep.orderBook.setCallbackWhitelist(router.address, true);

    await senior.initialize("SENIOR", "SEN", dep.usdc.address);
    await senior.grantRole(ethers.utils.id("HANDLER_ROLE"), router.address);
    await senior.grantRole(ethers.utils.id("CONFIG_ROLE"), seniorConfig.address);

    await junior.initialize("JUNIOR", "JUN", dep.smlp.address, dep.mlp.address);
    await junior.grantRole(ethers.utils.id("HANDLER_ROLE"), router.address);
    await junior.grantRole(ethers.utils.id("CONFIG_ROLE"), juniorConfig.address);

    await router.initialize(senior.address, junior.address, rewardController.address);
    await router.grantRole(ethers.utils.id("CONFIG_ROLE"), routerConfig.address);
    await router.grantRole(ethers.utils.id("KEEPER_ROLE"), keeper.address);

    await seniorReward.initialize("S", "S", dep.usdc.address, senior.address);
    await juniorReward.initialize("J", "J", dep.usdc.address, junior.address);
    await rewardController.initialize(
      dep.usdc.address,
      seniorReward.address,
      juniorReward.address,
      toWei("0.5"),
      toWei("0.05")
    );
    await rewardController.setHandler(router.address, true);
    const pathHelper = await createContract("PathHelper");
    await rewardController.setUniswapContracts(dep.uniswap.address, dep.quoter.address);
    await rewardController.setSwapPaths(dep.weth.address, [
      await pathHelper.buildPath2(dep.weth.address, 3000, dep.usdc.address),
    ]);
    await rewardController.setSwapPaths(dep.mcb.address, [
      await pathHelper.buildPath2(dep.mcb.address, 3000, dep.usdc.address),
    ]);
    await rewardController.setSwapPaths(dep.arb.address, [
      await pathHelper.buildPath2(dep.arb.address, 3000, dep.usdc.address),
    ]);

    await seniorConfig.setLockPeriod(86400);
    await seniorConfig.setMaxBorrows(toWei("1000"));
    await seniorConfig.setAaveToken(dep.ausdc.address);
    await seniorConfig.setAavePool(dep.aavePool.address);
    await seniorConfig.setAaveRewardsController(dep.aaveRewardsController.address);
    await seniorConfig.setAaveExtraRewardToken(dep.arb.address);
    await seniorConfig.setAssetSupplyCap(toUnit("15000000", 6));

    await juniorConfig.setMuxRewardRouter(dep.rewardRouter.address);
    await juniorConfig.setMuxLiquidityPool(dep.liquidityPool.address);
    await juniorConfig.setAssetSupplyCap(toUnit("10000000", 18));

    await routerConfig.setMuxRewardRouter(dep.rewardRouter.address);
    await routerConfig.setMuxOrderBook(dep.orderBook.address);
    await routerConfig.setMuxLiquidityPool(dep.liquidityPool.address);
    await routerConfig.setRebalanceThresholdRate(toWei("0.05"));
    await routerConfig.setLiquidationLeverage(toWei("10"));
    await routerConfig.setTargetLeverage(toWei("2.5"));
    await routerConfig.setLiquidationLeverage(toWei("5.0"));

    await rewardController.setMinStableApy(toWei("0.05"));
    await rewardController.setSeniorRewardRate(toWei("0.2"));
    await rewardController.setHandler(router.address, true);
    await seniorReward.setHandler(rewardController.address, true);
    await juniorReward.setHandler(rewardController.address, true);

    await router.setWhitelist(alice.address, true);
    await router.setWhitelist(bob.address, true);

    //////////////////////////////////////////////////////////////////
    // basic setup: deposit senior, deposit junior, rebalance (borrow)

    const sPrice = toWei("1");
    let jPrice = toWei("1");

    // deposit senior
    await dep.usdc.mint(alice.address, toUnit("1000000", 6));
    await dep.usdc.connect(alice).approve(router.address, toUnit("1000000", 6));
    await router.connect(alice).depositSenior(toUnit("1000000", 6));
    expect(await senior.balanceOf(alice.address)).to.equal(toWei("1000000"));

    // bob save a little junior and never withdraw
    await dep.mlp.mint(bob.address, toWei("0.1"));
    await dep.mlp.connect(bob).approve(router.address, toWei("0.1"));
    await router.connect(bob).depositJunior(toWei("0.1"));
    await setMockersBlockTime(dep, 86400 + 60 * 30 * 1);
    await dep.orderBook
      .connect(keeper)
      .fillLiquidityOrder(1, toWei("1"), toWei("1"), toWei("0"), toWei("0"));
    expect(await junior.balanceOf(bob.address)).to.equal(toWei("0.1"));
    {
      expect(await senior.callStatic.borrows(router.address)).to.equal(toUnit("0", 6));
      expect(await junior.callStatic.totalSupply()).to.equal(toWei("0.1"));
      expect(await junior.callStatic.totalAssets()).to.equal(toWei("0.1"));
      expect(await router.callStatic.juniorNavPerShare(sPrice, jPrice)).to.equal(toWei("1")); // (0.1 - 0) / 0.1
    }

    // alice buy mlp
    await dep.usdc.mint(alice.address, toUnit("500000", 6));
    await dep.usdc.connect(alice).approve(dep.orderBook.address, toUnit("500000", 6));
    await dep.orderBook.connect(alice).placeLiquidityOrder(0, toUnit("500000", 6), true);
    await setMockersBlockTime(dep, 86400 + 60 * 30 * 2);
    await dep.orderBook
      .connect(keeper)
      .fillLiquidityOrder(2, toWei("1"), toWei("1"), toWei("0"), toWei("0"));
    expect(await dep.mlp.balanceOf(alice.address)).to.equal(toWei("499650")); // 500000 * (1 - 0.0007)

    // alice deposit junior
    await dep.mlp.connect(alice).approve(router.address, toWei("499650"));
    await router.connect(alice).depositJunior(toWei("499650"));
    await setMockersBlockTime(dep, 86400 + 60 * 30 * 3);
    await dep.orderBook
      .connect(keeper)
      .fillLiquidityOrder(3, toWei("1"), toWei("1"), toWei("0"), toWei("0"));
    expect(await junior.balanceOf(alice.address)).to.equal(toWei("499650"));
    {
      expect(await senior.callStatic.borrows(router.address)).to.equal(toUnit("0", 6));
      expect(await junior.callStatic.totalSupply()).to.equal(toWei("499650.1"));
      expect(await junior.callStatic.totalAssets()).to.equal(toWei("499650.1"));
      expect(await router.callStatic.juniorNavPerShare(sPrice, jPrice)).to.equal(toWei("1")); // (499650.1 - 0) / 499650.1
    }

    // rebalance (junior borrows)
    await router.connect(keeper).rebalance(sPrice, jPrice);
    await setMockersBlockTime(dep, 86400 + 60 * 30 * 4);
    await dep.orderBook
      .connect(keeper)
      .fillLiquidityOrder(4, toWei("1"), toWei("1"), toWei("0"), toWei("0"));
    {
      expect(await senior.callStatic.borrows(router.address)).to.equal(toUnit("749475.15", 6));
      expect(await junior.callStatic.totalSupply()).to.equal(toWei("499650.1"));
      expect(await junior.callStatic.totalAssets()).to.equal(toWei("1248600.617395")); // 499650.1 + 749475.15 * 1 / 1 * (1 - 0.0007)
      expect(await router.callStatic.juniorNavPerShare(sPrice, jPrice)).to.equal(toWei("0.99895")); // (1248600.617395 * 1 - 749475.15) / 499650.1
    }
    // see MockRouter.test.ts
    // acc junior = 0
    // mlp reward = 499650.1 * (0.000000000002113986 * 3000 + 0.000000001109842719 * 2) * (60 * 30)  // deposit <-> rebalance
    //            = 7.700086
    // alice = 7.700086 * 0.80 * 499650 / 499650.1 = 6.16007
    // acc junior = 6.16007 => 5.995800
    expect(await router.callStatic.claimableJuniorRewards(alice.address)).to.equal(
      toUnit("5.995800", 6)
    );
    // acc senior = 10.273979
    // alice = 7.700086 * 0.20 * 100% = 1.54002
    // aUSDC = 250524.85 * 0.05 / 365 / 86400 * 60 * 30 * 1 = 0.714968
    // arb = (250524.85 + 0.714968) * 0.01 / 365 / 86400 * 60 * 30 * 1 = 0.142994043931506849
    // acc senior = 10.273979 + 1.54002 + 0.714968 + 0.142994043931506849 = 12.672 => 11
    expect(await dep.ausdc.balanceOf(senior.address)).to.be.closeTo(toUnit("250525.564969", 6), 1);
    expect(await router.callStatic.claimableSeniorRewards(alice.address)).to.equal(
      toUnit("11.0", 6)
    );
  });

  it("deposit junior, cancel", async () => {
    const sPrice = toWei("1");
    let jPrice = toWei("1");

    // deposit junior
    await dep.mlp.mint(alice.address, toWei("100000"));
    await dep.mlp.connect(alice).approve(router.address, toWei("100000"));
    await router.connect(alice).depositJunior(toWei("100000"));
    {
      expect(await senior.callStatic.borrows(router.address)).to.equal(toUnit("749475.15", 6));
      expect(await junior.callStatic.totalSupply()).to.equal(toWei("499650.1"));
      expect(await junior.callStatic.totalAssets()).to.equal(toWei("1248600.617395")); // 499650.1 + 749475.15 * 1 / 1 * (1 - 0.0007)
      expect(await router.callStatic.juniorNavPerShare(sPrice, jPrice)).to.equal(toWei("0.99895")); // (1248600.617395 * 1 - 749475.15) / 499650.1
    }

    // cancel
    await router.connect(alice).cancelPendingOperation();
    {
      expect(await senior.callStatic.borrows(router.address)).to.equal(toUnit("749475.15", 6));
      expect(await junior.callStatic.totalSupply()).to.equal(toWei("499650.1"));
      expect(await junior.callStatic.totalAssets()).to.equal(toWei("1248600.617395")); // 499650.1 + 749475.15 * 1 / 1 * (1 - 0.0007)
      expect(await router.callStatic.juniorNavPerShare(sPrice, jPrice)).to.equal(toWei("0.99895")); // (1248600.617395 * 1 - 749475.15) / 499650.1
    }
  });

  it("withdraw junior, cancel", async () => {
    const sPrice = toWei("1");
    let jPrice = toWei("1");

    // alice withdraw junior, repay 749475.15 * 499650 / 499650.1 = 749475
    // requires 749475 / 0.9 / (1 - 0.00093) = 833525.178415926811935099 MUXLP
    // sell this MUXLP will get 833525.178415926811935099 * 1 / 1 * (1 - 0.0007) = 832941.710791
    await router.connect(alice).withdrawJunior(toWei("499650"));
    {
      expect(await junior.balanceOf(alice.address)).to.equal(toWei("0"));
    }
    await setMockersBlockTime(dep, 86400 + 60 * 30 * 4 + 86400 * 365 + 60 * 30 * 1);
    await router.connect(alice).cancelPendingOperation();
    {
      expect(await junior.balanceOf(alice.address)).to.equal(toWei("499650"));
    }
    {
      expect(await senior.callStatic.borrows(router.address)).to.equal(toUnit("749475.15", 6));
      expect(await junior.callStatic.totalSupply()).to.equal(toWei("499650.1"));
      expect(await junior.callStatic.totalAssets()).to.equal(toWei("1248600.617395")); // 499650.1 + 749475.15 * 1 / 1 * (1 - 0.0007)
      expect(await router.callStatic.juniorNavPerShare(sPrice, jPrice)).to.equal(toWei("0.99895")); // (1248600.617395 * 1 - 749475.15) / 499650.1
    }
  });

  it("withdraw senior, cancel", async () => {
    const sPrice = toWei("1");
    let jPrice = toWei("1");

    // withdraw senior, repay 749475.15 requires 749475.15 / 0.9 / (1 - 0.00093) = 833525.345237737762786057 MUXLP
    // sell this MUXLP will get 833525.345237737762786057 * (1 - 0.0007) = 832941.877496
    await router.connect(alice).withdrawSenior(toWei("1000000"), true);
    {
      expect(await senior.balanceOf(alice.address)).to.equal(toWei("1000000"));
    }
    await setMockersBlockTime(dep, 86400 + 60 * 30 * 5);
    await router.connect(alice).cancelPendingOperation();
    {
      expect(await senior.balanceOf(alice.address)).to.equal(toWei("1000000"));
    }
    {
      expect(await senior.callStatic.borrows(router.address)).to.equal(toUnit("749475.15", 6));
      expect(await junior.callStatic.totalSupply()).to.equal(toWei("499650.1"));
      expect(await junior.callStatic.totalAssets()).to.equal(toWei("1248600.617395")); // 499650.1 + 749475.15 * 1 / 1 * (1 - 0.0007)
      expect(await router.callStatic.juniorNavPerShare(sPrice, jPrice)).to.equal(toWei("0.99895")); // (1248600.617395 * 1 - 749475.15) / 499650.1
    }
  });

  it("rebalance (borrow), cancel", async () => {
    const sPrice = toWei("1");
    let jPrice = toWei("1");

    // junior deposit
    await dep.mlp.mint(alice.address, toWei("100000"));
    await dep.mlp.connect(alice).approve(router.address, toWei("100000"));
    await router.connect(alice).depositJunior(toWei("100000"));
    await setMockersBlockTime(dep, 86400 + 60 * 30 * 5);
    await dep.orderBook
      .connect(keeper)
      .fillLiquidityOrder(5, toWei("1"), toWei("1"), toWei("0"), toWei("0"));
    expect(await junior.balanceOf(alice.address)).to.equal(toWei("599755.110365884178387306")); // 499650 + 100000 * 1 / 0.99895
    {
      expect(await senior.callStatic.borrows(router.address)).to.equal(toUnit("749475.15", 6));
      expect(await junior.callStatic.totalSupply()).to.equal(toWei("599755.210365884178387306")); // 499650.1 + 100000 * 1 / 0.99895
      expect(await junior.callStatic.totalAssets()).to.equal(toWei("1348600.617395")); // 1248600.617395 + 100000
      expect(await router.callStatic.juniorNavPerShare(toWei("1"), toWei("1"))).to.equal(
        toWei("0.99895")
      );
    }

    // acc junior = 6.160072
    // mlp reward = 1248600.617395 * (0.000000000002113986 * 3000 + 0.000000001109842719 * 2) * (60 * 30) // rebalance <-> deposit2
    //            = 19.242131
    // alice = 19.242131 * 0.80 * 599755.110365884178387306 / 599755.210365884178387306 = 15.393702
    // acc junior = 6.160072 + 15.393702 = 21.553774 => 20.989677
    expect(await router.callStatic.claimableJuniorRewards(alice.address)).to.equal(
      toUnit("20.989677", 6)
    );
    // acc senior = 10.273979
    // alice = 19.242131 * 0.20 * 100% = 3.8484262
    // aUSDC = 250524.85 * 0.05 / 365 / 86400 * 60 * 30 * 1 = 0.714968
    // arb = (250524.85 + 0.714968) * 0.01 / 365 / 86400 * 60 * 30 * 1 = 0.142994043931506849
    // acc senior = 10.273979 + 3.8484262 + 0.714968 + 0.142994043931506849 = 14.980367 =>
    // = 16.5204 => 15
    expect(await dep.ausdc.balanceOf(senior.address)).to.be.closeTo(toUnit("250525.564969", 6), 1);
    expect(await router.callStatic.claimableSeniorRewards(alice.address)).to.equal(
      toUnit("15.0", 6)
    );

    // rebalance (borrow)
    // principle = 1348600.617395 * 1 - 749475.15 = 599125.467395
    // should borrow 599125.467395 * 1.5 = 898688.2010925
    // borrow 898688.2010925 - 749475.15 = 149213.0510925
    {
      const [isBalanced, isBalancing] = await router.callStatic.isJuniorBalanced(sPrice, jPrice);
      expect(isBalanced).to.be.false;
      expect(isBalancing).to.be.false;
    }
    await router.connect(keeper).rebalance(sPrice, jPrice);
    {
      const [isBalanced, isBalancing] = await router.callStatic.isJuniorBalanced(sPrice, jPrice);
      expect(isBalanced).to.be.false;
      expect(isBalancing).to.be.true;
    }
    // aUSDC = 250524.85 - 149213.051092
    expect(await dep.ausdc.balanceOf(senior.address)).to.be.closeTo(toUnit("101311.798909", 6), 1);

    // cancel
    await router.connect(keeper).cancelRebalancePendingOperation();
    {
      expect(await senior.callStatic.borrows(router.address)).to.equal(toUnit("749475.15", 6));
      expect(await junior.callStatic.totalSupply()).to.equal(toWei("599755.210365884178387306")); // 499650.1 + 100000 * 1 / 0.99895
      expect(await junior.callStatic.totalAssets()).to.equal(toWei("1348600.617395")); // 1248600.617395 + 100000
      expect(await router.callStatic.juniorNavPerShare(toWei("1"), toWei("1"))).to.equal(
        toWei("0.99895")
      );
    }
    {
      const [isBalanced, isBalancing] = await router.callStatic.isJuniorBalanced(sPrice, jPrice);
      expect(isBalanced).to.be.false;
      expect(isBalancing).to.be.false;
    }
    expect(await dep.ausdc.balanceOf(senior.address)).to.equal(toUnit("250524.85", 6));
  });
});
