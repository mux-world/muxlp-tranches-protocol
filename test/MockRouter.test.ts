import {ethers, network} from "hardhat";
import {expect} from "chai";
import {toWei, toUnit, fromUnit, fromWei, createContract} from "../scripts/deployUtils";
import {deployDep, setMockersBlockTime} from "./mockers";

describe("Mock-Router", async () => {
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
  });

  it("deposit senior, withdraw senior", async () => {
    // deposit senior
    await dep.usdc.mint(alice.address, toUnit("1000000", 6));
    await dep.usdc.connect(alice).approve(router.address, toUnit("1000000", 6));
    await router.connect(alice).depositSenior(toUnit("1000000", 6));
    expect(await senior.balanceOf(alice.address)).to.equal(toWei("1000000"));
    expect(await dep.ausdc.balanceOf(senior.address)).to.equal(toUnit("1000000", 6));

    // deposit senior again
    await dep.usdc.mint(alice.address, toUnit("1000000", 6));
    await dep.usdc.connect(alice).approve(router.address, toUnit("1000000", 6));
    await router.connect(alice).depositSenior(toUnit("1000000", 6));
    expect(await senior.balanceOf(alice.address)).to.equal(toWei("2000000"));
    expect(await dep.ausdc.balanceOf(senior.address)).to.equal(toUnit("2000000", 6));

    // withdraw senior
    await router.connect(alice).withdrawSenior(toWei("1000000"), true);
    expect(await dep.usdc.balanceOf(alice.address)).to.equal(toUnit("1000000", 6));
    expect(await senior.balanceOf(alice.address)).to.equal(toWei("1000000"));
    expect(await dep.ausdc.balanceOf(senior.address)).to.equal(toUnit("1000000", 6));

    // withdraw senior again
    await setMockersBlockTime(dep, 86400 + 86400 * 365);
    await router.connect(alice).withdrawSenior(toWei("1000000"), true);
    expect(await dep.usdc.balanceOf(alice.address)).to.equal(toUnit("2000000", 6));
    expect(await senior.balanceOf(alice.address)).to.equal(toWei("0"));
    expect(await dep.ausdc.balanceOf(senior.address)).to.equal(toUnit("0", 6));

    // senior reward
    // * junior borrow reward = 0
    // * ausdc reward = 1000000 * 0.05 = 50000, so new ausdc = 1050000
    // * usdc arb reward = 1050000 * 0.000000000317097920 * 86400 * 365 = 10500
    await router.connect(alice).claimSeniorRewards();
    expect(await dep.usdc.balanceOf(alice.address)).to.equal(toUnit("2060500", 6));
  });

  it("deposit senior, deposit junior, rebalance (borrow), withdraw junior", async () => {
    const sPrice = toWei("1");
    let jPrice = toWei("1");

    // deposit senior
    await dep.usdc.mint(alice.address, toUnit("1000000", 6));
    await dep.usdc.connect(alice).approve(router.address, toUnit("1000000", 6));
    await router.connect(alice).depositSenior(toUnit("1000000", 6));
    expect(await senior.balanceOf(alice.address)).to.equal(toWei("1000000"));
    {
      expect(await senior.callStatic.borrows(router.address)).to.equal(toUnit("0", 6));
      expect(await junior.callStatic.totalSupply()).to.equal(toWei("0"));
      expect(await junior.callStatic.totalAssets()).to.equal(toWei("0"));
    }
    expect(await dep.ausdc.balanceOf(senior.address)).to.equal(toUnit("1000000", 6));
    expect(await router.callStatic.claimableSeniorRewards(alice.address)).to.equal(toUnit("0", 6));

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
    // acc junior = 0
    // acc senior = 0
    // aUSDC = 1000000 * 0.05 / 365 / 86400 * 60 * 30 * 1 = 2.853881
    // arb = (1000000 + 2.853881) * 0.01 / 365 / 86400 * 60 * 30 * 1 = 0.570777
    // acc senior = 2.853881 + 0.570777 = 3.424658 => 3.0
    expect(await dep.ausdc.balanceOf(senior.address)).to.equal(toUnit("1000002.853881", 6));
    expect(await router.callStatic.claimableSeniorRewards(alice.address)).to.equal(
      toUnit("3.0", 6)
    );

    // alice buy mlp
    await dep.usdc.mint(alice.address, toUnit("500000", 6));
    await dep.usdc.connect(alice).approve(dep.orderBook.address, toUnit("500000", 6));
    await dep.orderBook.connect(alice).placeLiquidityOrder(0, toUnit("500000", 6), true);
    await setMockersBlockTime(dep, 86400 + 60 * 30 * 2);
    await dep.orderBook
      .connect(keeper)
      .fillLiquidityOrder(2, toWei("1"), toWei("1"), toWei("0"), toWei("0"));
    expect(await dep.mlp.balanceOf(alice.address)).to.equal(toWei("499650")); // 500000 * (1 - 0.0007)
    // acc junior = 0  ignore, because you did not call tranche
    // acc senior = 0  ignore, because you did not call tranche
    // aUSDC = 1000000 * 0.05 / 365 / 86400 * 60 * 30 * 2 = 5.707762
    // arb = (1000000 + 5.707762) * 0.01 / 365 / 86400 * 60 * 30 * 2 = 1.141559
    // acc senior = 5.707762 + 1.141559 = 6.849321 => 6.0
    expect(await dep.ausdc.balanceOf(senior.address)).to.equal(toUnit("1000005.707762", 6));
    expect(await router.callStatic.claimableSeniorRewards(alice.address)).to.equal(
      toUnit("6.0", 6)
    );

    // alice deposit junior
    expect(await router.callStatic.claimableJuniorRewards(alice.address)).to.equal(toUnit("0", 6));
    await dep.mlp.connect(alice).approve(router.address, toWei("499650"));
    await router.connect(alice).depositJunior(toWei("499650"));
    expect(await dep.ausdc.balanceOf(senior.address)).to.equal(toUnit("1000000", 6));
    expect(await dep.mlp.balanceOf(alice.address)).to.equal(toWei("0"));
    expect(await junior.balanceOf(alice.address)).to.equal(toWei("0"));
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
    // junior = 0
    expect(await router.callStatic.claimableJuniorRewards(alice.address)).to.equal(toUnit("0", 6));
    // acc junior = 0
    // acc senior = 6.849321
    // aUSDC = 1000000 * 0.05 / 365 / 86400 * 60 * 30 * 1 = 2.853881
    // arb = (1000000 + 2.853881) * 0.01 / 365 / 86400 * 60 * 30 * 1 = 0.570778
    // acc senior = 6.849321 + 2.853881 + 0.570778 = 10.273979 => 9
    expect(await dep.ausdc.balanceOf(senior.address)).to.equal(toUnit("1000002.853881", 6));
    expect(await router.callStatic.claimableSeniorRewards(alice.address)).to.equal(
      toUnit("9.0", 6)
    );

    // rebalance (junior borrows)
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
    {
      expect(await senior.callStatic.borrows(router.address)).to.equal(toUnit("749475.15", 6)); // 499650.1 * 1.0 * 1.5
      expect(await junior.callStatic.totalSupply()).to.equal(toWei("499650.1"));
      expect(await junior.callStatic.totalAssets()).to.equal(toWei("499650.1"));
    }
    // acc junior = 0
    expect(await router.callStatic.claimableJuniorRewards(alice.address)).to.equal(toUnit("0", 6));
    // acc senior = 10.273979
    expect(await dep.ausdc.balanceOf(senior.address)).to.equal(toUnit("250524.85", 6)); // 1000000 - 749475.15
    expect(await router.callStatic.claimableSeniorRewards(alice.address)).to.equal(
      toUnit("9", 6) // unchanged
    );
    await setMockersBlockTime(dep, 86400 + 60 * 30 * 4);
    await dep.orderBook
      .connect(keeper)
      .fillLiquidityOrder(4, toWei("1"), toWei("1"), toWei("0"), toWei("0"));
    {
      const [isBalanced, isBalancing] = await router.callStatic.isJuniorBalanced(sPrice, jPrice);
      expect(isBalanced).to.be.true;
      expect(isBalancing).to.be.false;
    }
    {
      expect(await senior.callStatic.borrows(router.address)).to.equal(toUnit("749475.15", 6));
      expect(await junior.callStatic.totalSupply()).to.equal(toWei("499650.1"));
      expect(await junior.callStatic.totalAssets()).to.equal(toWei("1248600.617395")); // 499650.1 + 749475.15 * 1 / 1 * (1 - 0.0007)
      expect(await router.callStatic.juniorNavPerShare(sPrice, jPrice)).to.equal(toWei("0.99895")); // (1248600.617395 * 1 - 749475.15) / 499650.1
    }
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
    expect(await dep.ausdc.balanceOf(senior.address)).to.equal(toUnit("250525.564968", 6));
    expect(await router.callStatic.claimableSeniorRewards(alice.address)).to.equal(
      toUnit("11.0", 6)
    );

    ///////////////////////////////////////////////
    // 1 year later

    // acc junior = 5.995800
    // mlp reward = 1248600.617395 * (0.000000000002113986 * 3000 + 0.000000001109842719 * 2) * (86400 * 365)  // rebalance <-> 365d
    //            = 337122.151040
    // alice = 337122.151040 * 0.80 * 499650 / 499650.1 = 269697.666854
    // acc junior = 5.995800 + 269697.666854 = 269703.662654 => 269703.575250
    await setMockersBlockTime(dep, 86400 + 60 * 30 * 4 + 86400 * 365);
    expect(await router.callStatic.claimableJuniorRewards(alice.address)).to.equal(
      toUnit("269703.575250", 6)
    );
    // acc senior = 12.672
    // alice = 337122.151040 * 0.20 * 100% = 67424.430208
    // aUSDC = 250524.85 * 0.05 / 365 / 86400 * (60 * 30 * 1 + 86400 * 365) = 12526.957468
    // arb = (250524.85 + 12526.957468) * 0.01 / 365 / 86400 * (60 * 30 * 1 + 86400 * 365) = 2630.668218405723744292
    // acc senior = 67424.430208 + 12.672 + 12526.957468 + 2630.668218405723744292 = 82594.727894 => 82592.0
    expect(await dep.ausdc.balanceOf(senior.address)).to.equal(toUnit("263051.807468", 6));
    expect(await router.callStatic.claimableSeniorRewards(alice.address)).to.equal(
      toUnit("82592.0", 6)
    );

    // alice withdraw junior, repay 749475.15 * 499650 / 499650.1 = 749475
    // requires 749475 / 0.9 / (1 - 0.00093) = 833525.178415926811935099 MUXLP
    // sell this MUXLP will get 833525.178415926811935099 * 1 / 1 * (1 - 0.0007) = 832941.710791
    await expect(router.connect(alice).withdrawJunior(toWei("499651"))).to.be.revertedWith(
      "RouterJuniorImp::EXCEEDS_REDEEMABLE"
    );
    await router.connect(alice).withdrawJunior(toWei("499650"));
    {
      expect(await junior.balanceOf(alice.address)).to.equal(toWei("0"));
    }
    await setMockersBlockTime(dep, 86400 + 60 * 30 * 4 + 86400 * 365 + 60 * 30 * 1);
    await dep.orderBook
      .connect(keeper)
      .fillLiquidityOrder(5, toWei("1"), toWei("1"), toWei("0"), toWei("0"));
    {
      expect(await dep.usdc.balanceOf(alice.address)).to.equal(toUnit("83466.710791", 6)); // 832941.710791 - 749475
      expect(await dep.mlp.balanceOf(alice.address)).to.equal(toWei("415075.189084073188064899")); // 1248600.617395 * 499650 / 499650.1 - 833525.178415926811935099
    }
    {
      expect(await senior.callStatic.borrows(router.address)).to.equal(toUnit("0.15", 6)); // 749475.15 - 749475
      expect(await junior.callStatic.totalSupply()).to.equal(toWei("0.1"));
      expect(await junior.callStatic.totalAssets()).to.equal(toWei("0.249895000000000002")); // 1248600.617395 * (1 - 499650 / 499650.1)
      expect(await router.callStatic.juniorNavPerShare(sPrice, jPrice)).to.equal(
        toWei("0.998950000000000020")
      ); // (0.249895 * 1 - 0.15) / 0.1
    }
  });

  it("deposit senior, deposit junior, rebalance (borrow), withdraw senior (repay exceed borrow)", async () => {
    const sPrice = toWei("1");
    let jPrice = toWei("1");

    // deposit senior
    await dep.usdc.mint(alice.address, toUnit("1000000", 6));
    await dep.usdc.connect(alice).approve(router.address, toUnit("1000000", 6));
    await router.connect(alice).depositSenior(toUnit("1000000", 6));

    // bob save a little junior and never withdraw
    await dep.mlp.mint(bob.address, toWei("0.1"));
    await dep.mlp.connect(bob).approve(router.address, toWei("0.1"));
    await router.connect(bob).depositJunior(toWei("0.1"));
    await setMockersBlockTime(dep, 86400 + 60 * 30 * 1);
    await dep.orderBook
      .connect(keeper)
      .fillLiquidityOrder(1, toWei("1"), toWei("1"), toWei("0"), toWei("0"));

    // alice buy mlp
    await dep.usdc.mint(alice.address, toUnit("500000", 6));
    await dep.usdc.connect(alice).approve(dep.orderBook.address, toUnit("500000", 6));
    await dep.orderBook.connect(alice).placeLiquidityOrder(0, toUnit("500000", 6), true);
    await setMockersBlockTime(dep, 86400 + 60 * 30 * 2);
    await dep.orderBook
      .connect(keeper)
      .fillLiquidityOrder(2, toWei("1"), toWei("1"), toWei("0"), toWei("0"));

    // alice deposit junior
    await dep.mlp.connect(alice).approve(router.address, toWei("499650"));
    await router.connect(alice).depositJunior(toWei("499650"));
    await setMockersBlockTime(dep, 86400 + 60 * 30 * 3);
    await dep.orderBook
      .connect(keeper)
      .fillLiquidityOrder(3, toWei("1"), toWei("1"), toWei("0"), toWei("0"));

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

    ///////////////////////////////////////////////
    // until here, the same as the previous test //
    ///////////////////////////////////////////////

    // withdraw senior, repay 749475.15 requires 749475.15 / 0.9 / (1 - 0.00093) = 833525.345237737762786057 MUXLP
    // sell this MUXLP will get 833525.345237737762786057 * (1 - 0.0007) = 832941.877496
    await expect(router.connect(alice).withdrawSenior(toWei("1000001"), true)).to.be.revertedWith(
      "RouterSeniorImp::EXCEEDS_BALANCE"
    );
    await router.connect(alice).withdrawSenior(toWei("1000000"), true);
    await setMockersBlockTime(dep, 86400 + 60 * 30 * 5);
    await dep.orderBook
      .connect(keeper)
      .fillLiquidityOrder(5, toWei("1"), toWei("1"), toWei("0"), toWei("0"));
    {
      expect(await senior.callStatic.borrows(router.address)).to.equal(toUnit("0", 6));
      expect(await junior.callStatic.totalSupply()).to.equal(toWei("499650.1"));
      expect(await junior.callStatic.totalAssets()).to.equal(toWei("415075.272157262237213943")); // 1248600.617395 - 833525.345237737762786057
      expect(await router.callStatic.juniorNavPerShare(sPrice, jPrice)).to.equal(
        toWei("0.830731890491490419")
      );
      console.log("WARN!!! 0.99895 is better");
    }
    {
      expect(await dep.usdc.balanceOf(alice.address)).to.equal(toUnit("1000000", 6)); // 1000000
      expect(await senior.totalAssets()).to.equal(toUnit("0", 6));
      expect(await senior.totalSupply()).to.equal(toUnit("0", 6));
      expect(await senior.balanceOf(alice.address)).to.equal(toWei("0"));
    }

    // repay exceed borrow. deposit again
    // deposit 832941.877496 - 749475.15 = 83466.727496 will get 83466.727496 * 1 / 1 * (1 - 0.0007) = 83408.3007867528 MUXLP
    await router.connect(keeper).refundJunior();
    await setMockersBlockTime(dep, 86400 + 60 * 30 * 6);
    await dep.orderBook
      .connect(keeper)
      .fillLiquidityOrder(6, toWei("1"), toWei("1"), toWei("0"), toWei("0"));

    {
      expect(await senior.callStatic.borrows(router.address)).to.equal(toUnit("0", 6));
      expect(await junior.callStatic.totalSupply()).to.equal(toWei("499650.1"));
      expect(await junior.callStatic.totalAssets()).to.equal(toWei("498483.572944015037213943")); // 415075.272157262237213943 + 83408.3007867528
      expect(await router.callStatic.juniorNavPerShare(sPrice, jPrice)).to.equal(
        toWei("0.997665312073419053")
      );
    }
  });
});
