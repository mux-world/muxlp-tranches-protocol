import {ethers, network} from "hardhat";
import {expect} from "chai";
import {toWei, toUnit, fromUnit, fromWei, createContract} from "../scripts/deployUtils";
import {BigNumber} from "ethers";
import {impersonateAccount, setBalance, time} from "@nomicfoundation/hardhat-network-helpers";

const U = ethers.utils;
const B = ethers.BigNumber;
const toUsd = (v) => toUnit(v, 6);

describe("Liquidation", async () => {
  let user0;
  let user1;
  let alice;
  let bob;
  let keeper;
  let placeholder;

  let weth;
  let usdc;
  let mlp;
  let mux;
  let mcb;

  let senior;
  let seniorConfig;
  let junior;
  let juniorConfig;
  let router;
  let routerConfig;
  let rewardController;
  let seniorReward;
  let juniorReward;

  let orderBook;
  let liquidityPool;

  let rewardRouter;
  let fmlp;
  let smlp;
  let feeDistributor;

  beforeEach(async () => {
    const accounts = await ethers.getSigners();
    user0 = accounts[0];
    user1 = accounts[1];
    alice = accounts[2];
    bob = accounts[3];
    keeper = accounts[4];
    placeholder = accounts[5];

    await network.provider.request({
      method: "hardhat_reset",
      params: [
        {
          forking: {
            jsonRpcUrl: "https://arb1.arbitrum.io/rpc",
            enabled: true,
            ignoreUnknownTxType: true, // added in our hardhat patch. see README.md
            blockNumber: 107393108, // modify me if ./cache/hardhat-network-fork was cleared
          },
        },
      ],
    });

    usdc = await ethers.getContractAt("SimpleERC20", "0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8");
    weth = await ethers.getContractAt("SimpleERC20", "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1");
    mcb = await ethers.getContractAt("SimpleERC20", "0x4e352cF164E64ADCBad318C3a1e222E9EBa4Ce42");
    mux = await ethers.getContractAt("SimpleERC20", "0x8BB2Ac0DCF1E86550534cEE5E9C8DED4269b679B");
    feeDistributor = await ethers.getContractAt(
      "FeeDistributor",
      "0x6256dc556EE340952b8d8778f22608fd45592859"
    );
    rewardRouter = await ethers.getContractAt(
      "MockRewardRouter",
      "0xaf9C4F6A0ceB02d4217Ff73f3C95BbC8c7320ceE"
    );
    mlp = await ethers.getContractAt("SimpleERC20", "0x7CbaF5a14D953fF896E5B3312031515c858737C8");
    fmlp = await ethers.getContractAt("SimpleERC20", "0x290450cDea757c68E4Fe6032ff3886D204292914");
    smlp = await ethers.getContractAt("SimpleERC20", "0x0a9bbf8299FEd2441009a7Bb44874EE453de8e5D");

    liquidityPool = await ethers.getContractAt(
      "IMuxLiquidityPool",
      "0x3e0199792Ce69DC29A0a36146bFa68bd7C8D6633"
    );
    orderBook = await ethers.getContractAt(
      "IMuxOrderBook",
      "0xa19fD5aB6C8DCffa2A295F78a5Bb4aC543AAF5e3"
    );
    orderBook = await ethers.getContractAt(
      "IMuxOrderBook",
      "0xa19fD5aB6C8DCffa2A295F78a5Bb4aC543AAF5e3"
    );

    // patch
    {
      // const admin = await ethers.getImpersonatedSigner(
      //   "0xc2d28778447b1b0b2ae3ad17dc6616b546fbbebb"
      // );
      // await setBalance(admin.address, toWei("1000000"));
      // const upgradeAdmin = await ethers.getContractAt(
      //   "ProxyAdmin",
      //   "0xE52d9a3CBA458832A65cfa9FC8a74bacAbdeB32A"
      // );
      // const orderBookImp = await createContract("OrderBook", [], {
      //   LibOrderBook: await createContract("LibOrderBook"),
      // });
      // await upgradeAdmin.connect(admin).upgrade(orderBook.address, orderBookImp.address);
    }

    senior = await createContract("SeniorVault");
    seniorConfig = await createContract("SeniorConfig", [senior.address]);
    junior = await createContract("JuniorVault");
    juniorConfig = await createContract("JuniorConfig", [junior.address]);
    router = await createContract("RouterV1", [], {
      RouterImp: await createContract("RouterImp", [], {
        RouterJuniorImp: await createContract("RouterJuniorImp"),
        RouterSeniorImp: await createContract("RouterSeniorImp"),
      }),
    });
    routerConfig = await createContract("RouterConfig", [router.address]);

    rewardController = await createContract("RewardController");
    seniorReward = await createContract("RewardDistributor");
    juniorReward = await createContract("RewardDistributor");

    await senior.initialize("SENIOR", "SEN", usdc.address);
    await senior.grantRole(ethers.utils.id("HANDLER_ROLE"), router.address);
    await senior.grantRole(ethers.utils.id("CONFIG_ROLE"), seniorConfig.address);

    await junior.initialize("JUNIOR", "JUN", smlp.address, mlp.address);
    await junior.grantRole(ethers.utils.id("HANDLER_ROLE"), router.address);
    await junior.grantRole(ethers.utils.id("CONFIG_ROLE"), juniorConfig.address);

    await router.initialize(senior.address, junior.address, rewardController.address);
    await router.grantRole(ethers.utils.id("CONFIG_ROLE"), routerConfig.address);
    await router.grantRole(ethers.utils.id("KEEPER_ROLE"), keeper.address);

    await seniorReward.initialize("S", "S", usdc.address, senior.address);
    await juniorReward.initialize("J", "J", usdc.address, junior.address);

    await rewardController.initialize(
      usdc.address,
      seniorReward.address,
      juniorReward.address,
      toWei("0.5"),
      toWei("0.05")
    );
    await rewardController.setHandler(router.address, true);
    const pathHelper = await createContract("PathHelper");
    await rewardController.setUniswapContracts(
      "0xE592427A0AEce92De3Edee1F18E0157C05861564",
      "0xb27308f9F90D607463bb33eA1BeBb41C27CE5AB6"
    );
    await rewardController.setSwapPaths(weth.address, [
      await pathHelper.buildPath2(weth.address, 3000, usdc.address),
    ]);
    await rewardController.setSwapPaths(mcb.address, [
      "0x4e352cf164e64adcbad318c3a1e222e9eba4ce42000bb882af49447d8a07e3bd95bd0d56f35241523fbab10001f4ff970a61a04b1ca14834a43f5de4533ebddb5cc8",
    ]);

    await seniorConfig.setLockPeriod(86400);
    await seniorConfig.setMaxBorrows(toWei("1000"));

    await juniorConfig.setMuxRewardRouter(rewardRouter.address);
    await juniorConfig.setMuxLiquidityPool(liquidityPool.address);

    await routerConfig.setMuxRewardRouter(rewardRouter.address);
    await routerConfig.setMuxOrderBook(orderBook.address);
    await routerConfig.setMuxLiquidityPool(liquidityPool.address);
    await routerConfig.setRebalanceThresholdRate(toWei("0.05"));
    await routerConfig.setLiquidationLeverage(toWei("10"));
  });

  it("(junior) +deposit +rebalance +withdraw", async () => {
    /// init accounts
    const broker = await ethers.getImpersonatedSigner("0x988aa44e12c7bce07e449a4156b4a269d6642b3a");
    const usdcHolder = await ethers.getImpersonatedSigner(
      "0x489ee077994b6658eafa855c308275ead8097c4a"
    ); // some huge whale found on etherscan
    await setBalance(usdcHolder.address, toWei("1000000"));
    const admin = await ethers.getImpersonatedSigner("0xc2d28778447b1b0b2ae3ad17dc6616b546fbbebb");
    await setBalance(admin.address, toWei("1000000"));
    await orderBook.connect(admin).setCallbackWhitelist(router.address, true);

    console.log((await liquidityPool.getLiquidityPoolStorage()).u96s);
    // =========================== alice get mlp ===========================
    await usdc.connect(usdcHolder).transfer(alice.address, toUsd("1000"));
    expect(await usdc.balanceOf(alice.address)).to.equal(toUsd("1000"));
    var orderId = await orderBook.nextOrderId();
    await usdc.connect(alice).approve(orderBook.address, toUsd("200"));
    await orderBook.connect(alice).placeLiquidityOrder(0, toUsd("200"), true);
    await time.increase(60 * 15);
    await orderBook
      .connect(broker)
      .fillLiquidityOrder(orderId, toWei("1"), toWei("1.05"), toWei("50"), toWei("100"));
    var mlpForAlice = await mlp.balanceOf(alice.address);
    // =========================== deposits ===========================
    // junior +0
    // senior +1000
    await usdc.connect(usdcHolder).transfer(bob.address, toUsd("1000"));
    expect(await usdc.balanceOf(bob.address)).to.equal(toUsd("1000"));

    await usdc.connect(bob).approve(router.address, toUsd("1000"));
    await router.connect(bob).depositSenior(toUsd("1000"));
    expect(await senior.balanceOf(bob.address)).to.equal(toWei("1000"));
    expect(await senior.totalSupply()).to.equal(toWei("1000"));

    // junior +0    +100
    // senior +1000 -421
    await mlp.connect(alice).approve(router.address, toWei("100"));
    await router.connect(alice).depositJunior(toWei("100"));
    expect(await junior.balanceOf(alice.address)).to.equal(toWei("100"));
    expect(await junior.totalSupply()).to.equal(toWei("100"));

    await routerConfig.setTargetLeverage(toWei("5"));
    // assume price is 2:1, leverage == 1x, not balanced
    expect(await router.juniorLeverage(toWei("1"), toWei("0.9"))).to.equal(toWei("1"));

    var orderId = await orderBook.nextOrderId();
    await router.connect(keeper).rebalance(toWei("1"), toWei("0.9"));
    await time.increase(60 * 15);
    await orderBook
      .connect(broker)
      .fillLiquidityOrder(orderId, toWei("1"), toWei("0.9"), toWei("10000"), toWei("20000"));

    await expect(router.connect(keeper).liquidate(toWei("1"), toWei("0.9"))).to.be.revertedWith(
      "NOT_LIQUIDATABLE"
    );

    await router.isJuniorBalanced(toWei("2"), toWei("0.9"));

    var orderId = await orderBook.nextOrderId();
    await router.connect(keeper).liquidate(toWei("2"), toWei("0.9"));
    await time.increase(60 * 15);
    await orderBook
      .connect(broker)
      .fillLiquidityOrder(orderId, toWei("2"), toWei("0.9"), toWei("10000"), toWei("20000"));
    await router.isJuniorBalanced(toWei("2"), toWei("0.9"));

    var orderId = await orderBook.nextOrderId();
    await router.connect(keeper).handlePendingRequest(3);
    await time.increase(60 * 15);
    await orderBook
      .connect(broker)
      .fillLiquidityOrder(orderId, toWei("2"), toWei("0.9"), toWei("10000"), toWei("20000"));

    await router.isJuniorBalanced(toWei("2"), toWei("0.9"));
  });
});
