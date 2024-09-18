import {ethers, network} from "hardhat";
import {expect} from "chai";
import {toWei, toUnit, fromUnit, fromWei, createContract} from "../scripts/deployUtils";
import {BigNumber} from "ethers";
import {impersonateAccount, setBalance, time} from "@nomicfoundation/hardhat-network-helpers";

const U = ethers.utils;
const B = ethers.BigNumber;
const toUsd = (v) => toUnit(v, 6);

describe("Test", async () => {
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
            blockNumber: 126040785, // modify me if ./cache/hardhat-network-fork was cleared
          },
        },
      ],
    });

    usdc = await ethers.getContractAt("SimpleERC20", "0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8");
    weth = await ethers.getContractAt("SimpleERC20", "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1");
    mlp = await ethers.getContractAt("SimpleERC20", "0x7CbaF5a14D953fF896E5B3312031515c858737C8");

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
    router = await ethers.getContractAt("RouterV1", "0xaCF98f9564FB6903104644537624cdc3661F43Cf");

    const newRouter = await createContract("RouterV1", [], {
      RouterImp: await createContract("RouterImp", [], {
        RouterJuniorImp: await createContract("RouterJuniorImp"),
        RouterSeniorImp: await createContract("RouterSeniorImp"),
        RouterRebalanceImp: await createContract("RouterRebalanceImp"),
      }),
      RouterJuniorImp: await createContract("RouterJuniorImp"),
      RouterRebalanceImp: await createContract("RouterRebalanceImp"),
      RouterSeniorImp: await createContract("RouterSeniorImp"),
    });
    const proxyAdmin = await ethers.getContractAt(
      "ProxyAdmin",
      "0x2257dc42b363d611898057354c031a670934ed3f"
    );
    const admin = await ethers.getImpersonatedSigner("0x1426476e4ea1426c56a5b1d2469a62281e8dcfc9");
    await proxyAdmin.connect(admin).upgrade(router.address, newRouter.address);
  });

  it("--", async () => {
    const broker = await ethers.getImpersonatedSigner("0x988aa44e12c7bce07e449a4156b4a269d6642b3a");
    const keeper = await ethers.getImpersonatedSigner("0x68bd922859d59ead65af52919f2761be7fd92987");

    console.log(await router.getTickets(0, 100));

    await keeper.sendTransaction({
      to: router.address,
      data: "0x463cde3a000000000000000000000000000000000000000000000000000000000004b4ed000000000000000000000000acf98f9564fb6903104644537624cdc3661f43cf0000000000000000000000000000000000000000000000003dfecc1ca65c56bc000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000064ed69bf",
    });

    console.log(await mlp.balanceOf(router.address));
  });
});
