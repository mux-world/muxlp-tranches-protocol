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
import {deployDep, setMockersBlockTime} from "./mockers";

describe("Mock-Liquidate", async () => {
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

  it("deposit senior, deposit junior, rebalance (borrow), liquidated", async () => {
    const sPrice = toWei("1");
    let jPrice = toWei("1");

    // deposit senior
    await dep.usdc.mint(alice.address, toUnit("100", 6));
    await dep.usdc.connect(alice).approve(router.address, toUnit("100", 6));
    await router.connect(alice).depositSenior(toUnit("100", 6));
    expect(await senior.balanceOf(alice.address)).to.equal(toWei("100"));
    {
      expect(await senior.callStatic.borrows(router.address)).to.equal(toUnit("0", 6));
      expect(await junior.callStatic.totalSupply()).to.equal(toWei("0"));
      expect(await junior.callStatic.totalAssets()).to.equal(toWei("0"));
    }

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
    await dep.usdc.mint(alice.address, toUnit("50", 6));
    await dep.usdc.connect(alice).approve(dep.orderBook.address, toUnit("50", 6));
    await dep.orderBook.connect(alice).placeLiquidityOrder(0, toUnit("50", 6), true);
    await setMockersBlockTime(dep, 86400 + 60 * 30 * 2);
    await dep.orderBook
      .connect(keeper)
      .fillLiquidityOrder(2, toWei("1"), toWei("1"), toWei("0"), toWei("0"));
    expect(await dep.mlp.balanceOf(alice.address)).to.equal(toWei("49.965")); // 50 * (1 - 0.0007)

    // alice deposit junior
    await dep.mlp.connect(alice).approve(router.address, toWei("49.965"));
    await router.connect(alice).depositJunior(toWei("49.965"));
    expect(await dep.mlp.balanceOf(alice.address)).to.equal(toWei("0"));
    expect(await junior.balanceOf(alice.address)).to.equal(toWei("0"));
    await setMockersBlockTime(dep, 86400 + 60 * 30 * 3);
    await dep.orderBook
      .connect(keeper)
      .fillLiquidityOrder(3, toWei("1"), toWei("1"), toWei("0"), toWei("0"));
    expect(await junior.balanceOf(alice.address)).to.equal(toWei("49.965"));
    {
      expect(await senior.callStatic.borrows(router.address)).to.equal(toUnit("0", 6));
      expect(await junior.callStatic.totalSupply()).to.equal(toWei("50.065"));
      expect(await junior.callStatic.totalAssets()).to.equal(toWei("50.065"));
      expect(await router.callStatic.juniorNavPerShare(sPrice, jPrice)).to.equal(toWei("1")); // (50.065 - 0) / 50.065
    }

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
      expect(await senior.callStatic.borrows(router.address)).to.equal(toUnit("75.0975", 6)); // 50.065 * 1.0 * 1.5 = 75.0975
      expect(await junior.callStatic.totalSupply()).to.equal(toWei("50.065"));
      expect(await junior.callStatic.totalAssets()).to.equal(toWei("50.065"));
    }
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
      expect(await senior.callStatic.borrows(router.address)).to.equal(toUnit("75.0975", 6));
      expect(await junior.callStatic.totalSupply()).to.equal(toWei("50.065"));
      expect(await junior.callStatic.totalAssets()).to.equal(toWei("125.10993175")); // 50.065 + 75.0975 * 1 / 1 * (1 - 0.0007)
      expect(await router.callStatic.juniorNavPerShare(sPrice, jPrice)).to.equal(toWei("0.99895")); // (125.10993175 * 1 - 75.0975) / 50.065
    }

    // liquidate
    await dep.liquidityPool.setBound(toWei("0.4"), toWei("1.0"));
    await router.connect(keeper).liquidate(toWei("1"), toWei("0.7"));
    expect(await router.isLiquidated()).to.be.true;
    {
      const states = await router.callStatic.getUserStates(ethers.constants.AddressZero);
      expect(states.status).to.equal(5);
      expect(states.orderId).to.equal(5);
      expect(states.stateValues[0]).to.equal(toWei("125.10993175")); // all junior assets
    }
    await setMockersBlockTime(dep, 86400 + 60 * 30 * 5);
    await dep.orderBook
      .connect(keeper)
      .fillLiquidityOrder(5, toWei("1"), toWei("0.7"), toWei("0"), toWei("0"));

    {
      expect(await senior.callStatic.borrows(router.address)).to.equal(toUnit("0", 6));
      expect(await junior.callStatic.totalSupply()).to.equal(toWei("50.065"));
      expect(await junior.callStatic.totalAssets()).to.equal(toWei("0"));
      expect(await router.pendingRefundAssets()).to.equal(toUnit("12.418148", 6)); // 125.10993175 * 0.7 * (1 - 0.0007) = 87.515648, debt = 75.0975, refund = 87.515648 - 75.0975 = 12.418148
    }
    await expect(router.connect(alice).withdrawJunior(toWei("50"))).to.be.revertedWith(
      "HAS_REFUND_ASSETS"
    );

    await router.connect(keeper).refundJunior();
    await setMockersBlockTime(dep, 86400 + 60 * 30 * 6);
    await dep.orderBook
      .connect(keeper)
      .fillLiquidityOrder(6, toWei("1"), toWei("0.7"), toWei("0"), toWei("0"));
    {
      expect(await senior.callStatic.borrows(router.address)).to.equal(toUnit("0", 6));
      expect(await junior.callStatic.totalSupply()).to.equal(toWei("50.065"));
      expect(await junior.callStatic.totalAssets()).to.equal(toWei("17.727793280571428571")); // 12.418148 / 0.7 * (1 - 0.0007) = 17.727793280571428571
      expect(await junior.balanceOf(alice.address)).to.equal(toWei("49.965"));
      expect(await junior.balanceOf(bob.address)).to.equal(toWei("0.1"));
    }

    await router.connect(alice).withdrawJunior(toWei("49.965"));
    await setMockersBlockTime(dep, 86400 + 60 * 30 * 7);
    await dep.orderBook
      .connect(keeper)
      .fillLiquidityOrder(7, toWei("1"), toWei("0.7"), toWei("0"), toWei("0"));
    {
      expect(await junior.callStatic.totalSupply()).to.equal(toWei("0.1"));
      expect(await junior.callStatic.totalAssets()).to.equal(toWei("0.035409554140759869")); // 17.727793280571428571 * 49.965 / 50.065 = 17.692383726430668701
      expect(await junior.balanceOf(alice.address)).to.equal(toWei("0"));
      expect(await junior.balanceOf(bob.address)).to.equal(toWei("0.1"));
    }
    await router.connect(bob).withdrawJunior(toWei("0.1"));
    await setMockersBlockTime(dep, 86400 + 60 * 30 * 8);
    await dep.orderBook
      .connect(keeper)
      .fillLiquidityOrder(8, toWei("1"), toWei("0.7"), toWei("0"), toWei("0"));
    {
      expect(await junior.callStatic.totalSupply()).to.equal(toWei("0"));
      expect(await junior.callStatic.totalAssets()).to.equal(toWei("0")); // 17.727793280571428571 * 49.965 / 50.065 = 17.692383726430668701
      expect(await junior.balanceOf(alice.address)).to.equal(toWei("0"));
      expect(await junior.balanceOf(bob.address)).to.equal(toWei("0"));
    }
  });

  it("deposit senior, deposit junior, rebalance (borrow), bankrupt", async () => {
    const sPrice = toWei("1");
    let jPrice = toWei("1");

    // deposit senior
    await dep.usdc.mint(alice.address, toUnit("100", 6));
    await dep.usdc.connect(alice).approve(router.address, toUnit("100", 6));
    await router.connect(alice).depositSenior(toUnit("100", 6));
    expect(await senior.balanceOf(alice.address)).to.equal(toWei("100"));
    {
      expect(await senior.callStatic.borrows(router.address)).to.equal(toUnit("0", 6));
      expect(await junior.callStatic.totalSupply()).to.equal(toWei("0"));
      expect(await junior.callStatic.totalAssets()).to.equal(toWei("0"));
    }

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
    await dep.usdc.mint(alice.address, toUnit("50", 6));
    await dep.usdc.connect(alice).approve(dep.orderBook.address, toUnit("50", 6));
    await dep.orderBook.connect(alice).placeLiquidityOrder(0, toUnit("50", 6), true);
    await setMockersBlockTime(dep, 86400 + 60 * 30 * 2);
    await dep.orderBook
      .connect(keeper)
      .fillLiquidityOrder(2, toWei("1"), toWei("1"), toWei("0"), toWei("0"));
    expect(await dep.mlp.balanceOf(alice.address)).to.equal(toWei("49.965")); // 50 * (1 - 0.0007)

    // alice deposit junior
    await dep.mlp.connect(alice).approve(router.address, toWei("49.965"));
    await router.connect(alice).depositJunior(toWei("49.965"));
    expect(await dep.mlp.balanceOf(alice.address)).to.equal(toWei("0"));
    expect(await junior.balanceOf(alice.address)).to.equal(toWei("0"));
    await setMockersBlockTime(dep, 86400 + 60 * 30 * 3);
    await dep.orderBook
      .connect(keeper)
      .fillLiquidityOrder(3, toWei("1"), toWei("1"), toWei("0"), toWei("0"));
    expect(await junior.balanceOf(alice.address)).to.equal(toWei("49.965"));
    {
      expect(await senior.callStatic.borrows(router.address)).to.equal(toUnit("0", 6));
      expect(await junior.callStatic.totalSupply()).to.equal(toWei("50.065"));
      expect(await junior.callStatic.totalAssets()).to.equal(toWei("50.065"));
      expect(await router.callStatic.juniorNavPerShare(sPrice, jPrice)).to.equal(toWei("1")); // (50.065 - 0) / 50.065
    }

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
      expect(await senior.callStatic.borrows(router.address)).to.equal(toUnit("75.0975", 6)); // 50.065 * 1.0 * 1.5 = 75.0975
      expect(await junior.callStatic.totalSupply()).to.equal(toWei("50.065"));
      expect(await junior.callStatic.totalAssets()).to.equal(toWei("50.065"));
    }
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
      expect(await senior.callStatic.borrows(router.address)).to.equal(toUnit("75.0975", 6));
      expect(await junior.callStatic.totalSupply()).to.equal(toWei("50.065"));
      expect(await junior.callStatic.totalAssets()).to.equal(toWei("125.10993175")); // 50.065 + 75.0975 * 1 / 1 * (1 - 0.0007)
      expect(await router.callStatic.juniorNavPerShare(sPrice, jPrice)).to.equal(toWei("0.99895")); // (125.10993175 * 1 - 75.0975) / 50.065
    }

    // liquidate
    await dep.liquidityPool.setBound(toWei("0.4"), toWei("1.0"));
    await router.connect(keeper).liquidate(toWei("1"), toWei("0.5"));
    expect(await router.isLiquidated()).to.be.true;
    {
      const states = await router.callStatic.getUserStates(ethers.constants.AddressZero);
      expect(states.status).to.equal(5);
      expect(states.orderId).to.equal(5);
      expect(states.stateValues[0]).to.equal(toWei("125.10993175")); // all junior assets
    }
    await setMockersBlockTime(dep, 86400 + 60 * 30 * 5);
    await dep.orderBook
      .connect(keeper)
      .fillLiquidityOrder(5, toWei("1"), toWei("0.5"), toWei("0"), toWei("0"));

    {
      expect(await senior.callStatic.borrows(router.address)).to.equal(toUnit("12.586323", 6)); // // 125.10993175 * 0.5 * (1 - 0.0007) = 62.511177, debt = 75.0975 - 62.511177 = 12.586323
      expect(await junior.callStatic.totalSupply()).to.equal(toWei("50.065"));
      expect(await junior.callStatic.totalAssets()).to.equal(toWei("0"));
      expect(await router.pendingRefundAssets()).to.equal(toUnit("0", 6));
      expect(await senior.callStatic.totalAssets()).to.equal(toUnit("87.413677", 6)); // 100 - 12.586323
    }

    await expect(router.connect(alice).withdrawSenior(toWei("100"), true)).to.be.revertedWith(
      "INSUFFICIENT_ASSETS"
    );
    {
      expect(await dep.usdc.balanceOf(alice.address)).to.equal(0);
    }
    await router.connect(alice).withdrawSenior(toWei("87.413677"), true);
    {
      expect(await dep.usdc.balanceOf(alice.address)).to.equal(toUnit("87.413677", 6));
      expect(await senior.callStatic.totalAssets()).to.equal(toUnit("0", 6)); // 100 - 12.586323
    }
  });
});
