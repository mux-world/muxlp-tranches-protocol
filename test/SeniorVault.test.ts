import {ethers, network} from "hardhat";
import {expect} from "chai";
import {toWei, toUnit, fromWei, createContract} from "../scripts/deployUtils";
import {BigNumber} from "ethers";

const U = ethers.utils;
const B = ethers.BigNumber;
const toUsd = (x) => toUnit(x, 6);

describe("SeniorVault", async () => {
  let user0;
  let user1;
  let alice;
  let bob;
  let keeper;
  let placeholder;

  let weth;
  let usd;
  let mlp;
  let mux;
  let mcb;

  let senior;
  let config;

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
    alice = accounts[2];
    bob = accounts[3];
    keeper = accounts[4];
    placeholder = accounts[5];

    weth = await createContract("SimpleERC20", ["WETH", "WETH", 18]);
    usd = await createContract("SimpleERC20", ["USD", "USD", 6]);
    mux = await createContract("SimpleERC20", ["MUX", "MUX", 18]);
    mcb = await createContract("SimpleERC20", ["MCB", "MCB", 18]);

    senior = await createContract("SeniorVault");
    config = await createContract("SeniorConfig", [senior.address]);

    await senior.initialize("SENIOR", "SEN", usd.address);
    await senior.grantRole(ethers.utils.id("HANDLER_ROLE"), user0.address);
    await senior.grantRole(ethers.utils.id("CONFIG_ROLE"), config.address);

    await config.setLockPeriod(0);
    await config.setMaxBorrows(toWei("1000"));
  });

  it("senior deposit / withdraw", async () => {
    expect(await senior.name()).to.equal("SENIOR");
    expect(await senior.symbol()).to.equal("SEN");
    expect(await senior.decimals()).to.equal(18);
    expect(await senior.asset()).to.equal(usd.address);
    expect(await senior.depositToken()).to.equal(usd.address);

    await expect(senior.deposit(toUsd("100"), alice.address)).to.be.reverted;
    await usd.mint(senior.address, toUsd("100"));
    expect(await senior.convertToShares(toUsd("100"))).to.equal(toWei("100"));
    await senior.deposit(toUsd("100"), alice.address);
    expect(await senior.balanceOf(alice.address)).to.equal(toWei("100"));
    expect(await senior.totalSupply()).to.equal(toWei("100"));

    await usd.mint(senior.address, toUsd("200"));
    await senior.deposit(toUsd("200"), bob.address);
    expect(await senior.balanceOf(bob.address)).to.equal(toWei("200"));
    expect(await senior.totalSupply()).to.equal(toWei("300"));

    expect(await senior.balanceOf(alice.address)).to.equal(toWei("100"));
    await senior.withdraw(alice.address, alice.address, toWei("50"), alice.address);
    expect(await senior.convertToAssets(toWei("50"))).to.equal(toUsd("50"));
    expect(await senior.balanceOf(alice.address)).to.equal(toWei("50"));
    expect(await senior.totalSupply()).to.equal(toWei("250"));
    expect(await usd.balanceOf(alice.address)).to.equal(toUsd("50"));
  });

  it("senior borrow / repay", async () => {
    expect(await senior.name()).to.equal("SENIOR");
    expect(await senior.symbol()).to.equal("SEN");
    expect(await senior.decimals()).to.equal(18);
    expect(await senior.asset()).to.equal(usd.address);
    expect(await senior.depositToken()).to.equal(usd.address);

    await expect(senior.deposit(toUsd("100"), alice.address)).to.be.reverted;
    await usd.mint(senior.address, toUsd("100"));
    expect(await senior.convertToShares(toUsd("100"))).to.equal(toWei("100"));
    await senior.deposit(toUsd("100"), alice.address);
    expect(await senior.balanceOf(alice.address)).to.equal(toWei("100"));
    expect(await senior.totalSupply()).to.equal(toWei("100"));

    await usd.mint(senior.address, toUsd("200"));
    await senior.deposit(toUsd("200"), bob.address);
    expect(await senior.balanceOf(bob.address)).to.equal(toWei("200"));
    expect(await senior.totalSupply()).to.equal(toWei("300"));

    expect(await senior.totalBorrows()).to.equal(toUsd("0"));
    expect(await senior.borrows(user0.address)).to.equal(toUsd("0"));
    await config.setMaxBorrows(toUsd("150"));
    expect(await senior.totalAssets()).to.equal(toUsd("300"));
    await expect(senior.borrow(toUsd("151"))).to.be.revertedWith("EXCEEDS");
    await senior.borrow(toUsd("100"));
    expect(await senior.totalBorrows()).to.equal(toUsd("100"));
    expect(await senior.borrows(user0.address)).to.equal(toUsd("100"));

    await usd.transfer(senior.address, toUsd("50"));
    await senior.repay(toUsd("50"));
    // expect(await senior.totalBorrows()).to.equal(toUsd("50"));
    // expect(await senior.borrows(user0.address)).to.equal(toUsd("50"));
  });

  it("senior deposit cap", async () => {
    expect(await senior.name()).to.equal("SENIOR");
    expect(await senior.symbol()).to.equal("SEN");
    expect(await senior.decimals()).to.equal(18);
    expect(await senior.asset()).to.equal(usd.address);
    expect(await senior.depositToken()).to.equal(usd.address);

    await config.setAssetSupplyCap(toUsd("200"));

    await usd.mint(senior.address, toUsd("200"));
    await senior.deposit(toUsd("200"), bob.address);
    expect(await senior.balanceOf(bob.address)).to.equal(toWei("200"));
    expect(await senior.totalSupply()).to.equal(toWei("200"));

    await usd.mint(senior.address, toUsd("1"));
    await expect(senior.deposit(toUsd("1"), bob.address)).to.be.revertedWith("EXCEEDS_SUPPLY_CAP");
    await config.setAssetSupplyCap(toUsd("100"));

    await usd.mint(senior.address, toUsd("1"));
    await expect(senior.deposit(toUsd("1"), bob.address)).to.be.revertedWith("EXCEEDS_SUPPLY_CAP");
    await senior.withdraw(bob.address, bob.address, toWei("150"), bob.address);
    expect(await senior.balanceOf(bob.address)).to.equal(toWei("50"));
    expect(await senior.totalSupply()).to.equal(toWei("50"));

    await usd.mint(senior.address, toUsd("51"));
    await expect(senior.deposit(toUsd("51"), bob.address)).to.be.revertedWith("EXCEEDS_SUPPLY_CAP");
  });
});
