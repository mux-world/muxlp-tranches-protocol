import {ethers, network} from "hardhat";
import {expect} from "chai";
import {toWei, toUnit, fromUnit, fromWei, createContract} from "../scripts/deployUtils";
import {BigNumber} from "ethers";
import {impersonateAccount, setBalance, time} from "@nomicfoundation/hardhat-network-helpers";

const U = ethers.utils;
const B = ethers.BigNumber;
const toUsd = (v) => toUnit(v, 6);

describe("Simulate2", async () => {
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
  let junior;
  let router;
  let rewardController;
  let seniorReward;
  let juniorReward;

  beforeEach(async () => {
    const accounts = await ethers.getSigners();
    user0 = accounts[0];
    user1 = accounts[1];

    await network.provider.request({
      method: "hardhat_reset",
      params: [
        {
          forking: {
            jsonRpcUrl: "https://arb1.arbitrum.io/rpc",
            enabled: true,
            ignoreUnknownTxType: true, // added in our hardhat patch. see README.md
            // blockNumber: 209078940, // modify me if ./cache/hardhat-network-fork was cleared
            blockNumber: 211814720, // modify me if ./cache/hardhat-network-fork was cleared
          },
        },
      ],
    });

    usdc = await ethers.getContractAt("SimpleERC20", "0xaf88d065e77c8cC2239327C5EDb3A432268e5831");
    weth = await ethers.getContractAt("SimpleERC20", "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1");
    router = await ethers.getContractAt("RouterV1", "0x9B637AeE65106B1d55CEA5d560Fd0C67Ce1F18C5");
    junior = await ethers.getContractAt(
      "JuniorVault",
      "0x883774d2c63a3D7a461a27aF620aB23B8796b50e"
    );
    senior = await ethers.getContractAt(
      "SeniorVault",
      "0x99615f5480B716690e6Fb2875bcf4a87a61CE198"
    );

    rewardController = await ethers.getContractAt(
      "RewardController",
      "0xb68Ac7D3E3833DeB35fc5D63c16E3B5da12a9A41"
    );

    seniorReward = await ethers.getContractAt(
      "contracts/interfaces/IRewardDistributor.sol:IRewardDistributor",
      "0x809e14CE17E03eFe7cdbD7eb674B2dC18619f41C"
    );
    juniorReward = await ethers.getContractAt(
      "contracts/interfaces/IRewardDistributor.sol:IRewardDistributor",
      "0x623CCA95790bF7C07FAd104ed1c4334DB30a5299"
    );
  });

  it("migrate", async () => {
    const owner = await ethers.getImpersonatedSigner("0x73c5955dbB7a667e05da5fE7b8798c0fd4cE8E16");
    const proxyAdmin = await ethers.getContractAt(
      "ProxyAdmin",
      "0x2d18225B9A3F8C8C6f6f5C51Dc9C5bae5179Ac8B"
    );

    // senior
    {
      const imp = await createContract("SeniorVault", []);
      await proxyAdmin.connect(owner).upgrade(senior.address, imp.address);
    }
    // junior
    {
      const imp = await createContract("JuniorVault", []);
      await proxyAdmin.connect(owner).upgrade(junior.address, imp.address);
    }
    // reward
    {
      const imp = await createContract("RewardDistributor", []);
      await proxyAdmin.connect(owner).upgrade(seniorReward.address, imp.address);
      await proxyAdmin.connect(owner).upgrade(juniorReward.address, imp.address);
    }
    // reward
    {
      const imp = await createContract("RewardController", []);
      await proxyAdmin.connect(owner).upgrade(rewardController.address, imp.address);
    }
    // router
    {
      const imp = await createContract("RouterV1", [], {
        RouterImp: await createContract("RouterImp", [], {
          RouterJuniorImp: await createContract("RouterJuniorImp", []),
          RouterRebalanceImp: await createContract("RouterRebalanceImp", []),
          RouterSeniorImp: await createContract("RouterSeniorImp", []),
        }),
        RouterJuniorImp: await createContract("RouterJuniorImp", []),
        RouterRebalanceImp: await createContract("RouterRebalanceImp", []),
        RouterSeniorImp: await createContract("RouterSeniorImp", []),
      });
      await proxyAdmin.connect(owner).upgrade(router.address, imp.address);
    }

    const usdc = await ethers.getContractAt("IERC20", "0xaf88d065e77c8cC2239327C5EDb3A432268e5831");
    const ausdc = await ethers.getContractAt(
      "IERC20",
      "0x724dc807b04555b71ed48a6896b6F41593b8C637"
    );
    const arb = await ethers.getContractAt("IERC20", "0x912CE59144191C1204E64559FE8253a0e49E6548");

    // setup ========================================
    const seniorConfig = await createContract("SeniorConfig", [senior.address]);
    await senior.connect(owner).grantRole(U.id("CONFIG_ROLE"), seniorConfig.address);
    await seniorConfig.connect(owner).setAavePool("0x794a61358D6845594F94dc1DB02A252b5b4814aD");
    await seniorConfig.connect(owner).setAaveToken("0x724dc807b04555b71ed48a6896b6F41593b8C637");
    await seniorConfig
      .connect(owner)
      .setAaveRewardsController("0x929EC64c34a17401F460460D4B9390518E5B473e");
    await seniorConfig
      .connect(owner)
      .setAaveExtraRewardToken("0x912CE59144191C1204E64559FE8253a0e49E6548");
    await rewardController
      .connect(owner)
      .setSwapPaths(arb.address, [
        "0x912CE59144191C1204E64559FE8253a0e49E65480001f4" + usdc.address.slice(2),
      ]);

    // ========================================

    expect(await ausdc.balanceOf(senior.address)).to.equal(0);
    expect(await arb.balanceOf(senior.address)).to.equal(0);

    const balance0 = await usdc.balanceOf(senior.address);
    console.log(balance0);

    const user = await ethers.getImpersonatedSigner("0x2df1c51e09aecf9cacb7bc98cb1742757f163df7");
    await setBalance(user.address, toWei("1"));
    await router.connect(owner).setWhitelist(user.address, true);

    await usdc.connect(user).approve(router.address, toUnit("1000", 6));
    await router.connect(user).depositSenior(toUnit("1000", 6));

    expect(await ausdc.balanceOf(senior.address)).to.equal(balance0.add(toUnit("1000", 6)));
    expect(await arb.balanceOf(senior.address)).to.equal(0);
    console.log(await ausdc.balanceOf(senior.address));

    await time.increase(3600);

    console.log("ausdc", await ausdc.balanceOf(senior.address));
    console.log("rusdc", await usdc.balanceOf(seniorReward.address));
    console.log("supply", await senior.aaveTotalSupplied());
    console.log("aave rewards", await senior.claimableAaveRewards());
    console.log("arb rewards", await senior.claimableAaveExtraRewards());

    await router.connect(owner).grantRole(U.id("KEEPER_ROLE"), user.address);
    await router.connect(user).updateRewards();

    console.log("ausdc", await ausdc.balanceOf(senior.address));
    console.log("rusdc", await usdc.balanceOf(seniorReward.address));
    console.log("supply", await senior.aaveTotalSupplied());
    console.log("aave rewards", await senior.claimableAaveRewards());
    console.log("arb rewards", await senior.claimableAaveExtraRewards());
  });
});
