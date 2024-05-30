import {ethers, network} from "hardhat";
import {expect} from "chai";
import {toWei, toUnit, fromUnit, fromWei, createContract} from "../scripts/deployUtils";
import {BigNumber} from "ethers";
import {impersonateAccount, setBalance, time} from "@nomicfoundation/hardhat-network-helpers";

const U = ethers.utils;
const B = ethers.BigNumber;
const toUsd = (v) => toUnit(v, 6);
const _1 = toWei("1");

describe("Aave", async () => {
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

  const a2b = (a) => {
    return a + "000000000000000000000000";
  };
  const u2b = (u) => {
    return ethers.utils.hexZeroPad(u.toHexString(), 32);
  };

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
            blockNumber: 209741035,
          },
        },
      ],
    });

    usdc = await ethers.getContractAt("SimpleERC20", "0xaf88d065e77c8cC2239327C5EDb3A432268e5831");
    weth = await ethers.getContractAt("SimpleERC20", "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1");
    router = await ethers.getContractAt("IRouterV1", "0x9B637AeE65106B1d55CEA5d560Fd0C67Ce1F18C5");
    junior = await ethers.getContractAt(
      "IJuniorVault",
      "0x883774d2c63a3D7a461a27aF620aB23B8796b50e"
    );
    senior = await ethers.getContractAt(
      "ISeniorVault",
      "0x99615f5480B716690e6Fb2875bcf4a87a61CE198"
    );

    rewardController = await ethers.getContractAt(
      "IRewardController",
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

  it("simuate senior", async () => {
    const senior = await createContract("SeniorVault", []);
    const seniorConfig = await createContract("SeniorConfig", [senior.address]);
    await senior.initialize("S", "S", usdc.address);
    await senior.grantRole(ethers.utils.id("CONFIG_ROLE"), seniorConfig.address);
    await senior.grantRole(ethers.utils.id("HANDLER_ROLE"), user0.address);
    await senior.grantRole(ethers.utils.id("HANDLER_ROLE"), user1.address);

    await seniorConfig.setMaxBorrows(toUnit("15000000", 6));
    await seniorConfig.setAssetSupplyCap(toUnit("15000000", 6));
    await seniorConfig.setLockPeriod(5 * 60);
    await seniorConfig.setLockPenaltyRate(toWei("0.0000"));
    await seniorConfig.setLockPenaltyRecipient("0x623CCA95790bF7C07FAd104ed1c4334DB30a5299");
    await seniorConfig.setAavePool("0x794a61358D6845594F94dc1DB02A252b5b4814aD");
    await seniorConfig.setAaveToken("0x724dc807b04555b71ed48a6896b6F41593b8C637");
    await seniorConfig.setAaveRewardsController("0x929EC64c34a17401F460460D4B9390518E5B473e");
    await seniorConfig.setAaveExtraRewardToken("0x912CE59144191C1204E64559FE8253a0e49E6548");

    const user = await ethers.getImpersonatedSigner("0x2df1c51e09aecf9cacb7bc98cb1742757f163df7");
    await setBalance(user.address, toWei("1"));
    await usdc.connect(user).transfer(user1.address, toUnit("1000000", 6));

    const pool = await ethers.getContractAt("IPool", "0x794a61358D6845594F94dc1DB02A252b5b4814aD");
    const aToken = await ethers.getContractAt(
      "IERC20",
      "0x724dc807b04555b71ed48a6896b6F41593b8C637"
    );

    const arbToken = await ethers.getContractAt(
      "IERC20",
      "0x912CE59144191C1204E64559FE8253a0e49E6548"
    );

    expect(await aToken.balanceOf(user1.address)).to.equal(0);
    expect(await aToken.balanceOf(senior.address)).to.equal(0);
    expect(await usdc.balanceOf(user1.address)).to.equal(toUnit("1000000", 6));

    await usdc.connect(user1).transfer(senior.address, toUnit("500000", 6));
    await senior.connect(user1).deposit(toUnit("500000", 6), user1.address);

    expect(await usdc.balanceOf(user1.address)).to.equal(toUnit("500000", 6));
    expect(await usdc.balanceOf(senior.address)).to.equal(0);
    expect(await aToken.balanceOf(senior.address)).to.equal(toUnit("500000", 6));

    await senior
      .connect(user1)
      .withdraw(user1.address, user1.address, toWei("500000"), user1.address);

    expect(await usdc.balanceOf(senior.address)).to.equal(0);
    expect(await usdc.balanceOf(user1.address)).to.equal(toUnit("1000000", 6));
    expect(await aToken.balanceOf(senior.address)).to.equal(await senior.claimableAaveRewards());

    await usdc.connect(user1).transfer(senior.address, toUnit("250000", 6));
    await senior.connect(user1).deposit(toUnit("250000", 6), user1.address);

    await senior
      .connect(user1)
      .withdraw(user1.address, user1.address, toWei("250000"), user1.address);

    expect(await usdc.balanceOf(senior.address)).to.equal(0);
    expect(await usdc.balanceOf(user1.address)).to.equal(toUnit("1000000", 6));
    expect(await aToken.balanceOf(senior.address)).to.equal(await senior.claimableAaveRewards());

    console.log("claimable", await senior.claimableAaveRewards());
    await senior.connect(user1).claimAaveRewards(user0.address);

    expect(await senior.claimableAaveRewards()).to.equal(0);
    await usdc.connect(user1).transfer(senior.address, toUnit("1000000", 6));
    await senior.connect(user1).deposit(toUnit("1000000", 6), user1.address);

    expect(await usdc.balanceOf(user1.address)).to.equal(toUnit("0", 6));
    expect(await aToken.balanceOf(senior.address)).to.equal(toUnit("1000000", 6));

    expect(await senior.claimableAaveRewards()).to.equal(0);

    var extra = await senior.claimableAaveExtraRewards();
    expect(extra[0]).to.equal("0x912CE59144191C1204E64559FE8253a0e49E6548");
    expect(extra[1].gt(0)).to.be.true;

    expect(await arbToken.balanceOf(user0.address)).to.equal(0);
    await senior.connect(user1).claimAaveExtraRewards(user0.address);
    expect((await arbToken.balanceOf(user0.address)).gt(0)).to.be.true;

    var extra = await senior.claimableAaveExtraRewards();
    expect(extra[0]).to.equal("0x912CE59144191C1204E64559FE8253a0e49E6548");
    expect(extra[1].eq(0)).to.be.true;
  });
});
