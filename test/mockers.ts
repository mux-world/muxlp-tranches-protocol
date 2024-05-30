import {toWei, toUnit, fromUnit, fromWei, createContract} from "../scripts/deployUtils";
import {
  SimpleERC20,
  MockMuxOrderBook,
  MockMuxLiquidityPool,
  MockAToken,
  MockAavePool,
  MockUniswapV3,
  MockRewardRouter,
  MockVester,
} from "../typechain";

export async function deployDep() {
  const weth = (await createContract("SimpleERC20", ["weth", "weth", 18])) as SimpleERC20;
  const usdc = (await createContract("SimpleERC20", ["usdc", "usdc", 6])) as SimpleERC20;
  const mcb = (await createContract("SimpleERC20", ["mcb", "mcb", 18])) as SimpleERC20;
  const arb = (await createContract("SimpleERC20", ["arb", "arb", 18])) as SimpleERC20;

  ///////////////////////////////////////////////////////////////////////////////////////////
  //                                         MUX
  const mlp = (await createContract("SimpleERC20", ["mlp", "mlp", 18])) as SimpleERC20;
  const mux = (await createContract("SimpleERC20", ["mux", "mux", 18])) as SimpleERC20;
  const liquidityPool = (await createContract("MockMuxLiquidityPool")) as MockMuxLiquidityPool;
  const orderBook = (await createContract("MockMuxOrderBook", [
    mlp.address,
    liquidityPool.address,
  ])) as MockMuxOrderBook;
  await mlp.mint(orderBook.address, toWei("1000000000")); // enough mlp
  await liquidityPool.addAsset(usdc.address);
  await liquidityPool.setBound(toWei("0.90"), toWei("1.10"));

  ///////////////////////////////////////////////////////////////////////////////////////////
  //                                      MUX stake
  const smlp = (await createContract("SimpleERC20", ["smlp", "smlp", 18])) as SimpleERC20;
  const mlpVester = (await createContract("MockVester")) as MockVester;
  const muxVester = (await createContract("MockVester")) as MockVester;
  const rewardRouter = (await createContract("MockRewardRouter", [
    mlp.address,
    mcb.address,
    mux.address,
    weth.address,
    smlp.address,
    mlpVester.address,
    muxVester.address,
  ])) as MockRewardRouter;
  await smlp.mint(rewardRouter.address, toWei("1000000000")); // enough smlp
  await weth.mint(rewardRouter.address, toWei("1000000000")); // enough interest
  await mcb.mint(rewardRouter.address, toWei("1000000000")); // enough interest
  await rewardRouter.setRewardRate(
    toWei("0.000000000002113986"), // eth apy 20%. 0.20 / 365 / 86400 / 3000
    toWei("0.000000001109842719") // mcb apy 7%. 0.07 / 365 / 86400 / 2.0
  );

  ///////////////////////////////////////////////////////////////////////////////////////////
  //                                        Uniswap

  const uniswap = (await createContract("MockUniswapV3", [
    usdc.address,
    weth.address,
    mcb.address,
    arb.address,
  ])) as MockUniswapV3;
  await usdc.mint(uniswap.address, toUnit("1000000000", 6)); // enough swap
  await weth.mint(uniswap.address, toWei("1000000000")); // enough swap
  await mcb.mint(uniswap.address, toWei("1000000000")); // enough swap
  await arb.mint(uniswap.address, toWei("1000000000")); // enough swap

  ///////////////////////////////////////////////////////////////////////////////////////////
  //                                         AAVE

  const ausdc = (await createContract("MockAToken", ["ausdc", "ausdc"])) as MockAToken;
  const aavePool = (await createContract("MockAavePool", [
    usdc.address,
    ausdc.address,
    arb.address,
  ])) as MockAavePool;
  await usdc.mint(aavePool.address, toWei("1000000000")); // enough interest
  await ausdc.setApy(toWei("0.05")); // ausdc apy 5%
  await arb.mint(aavePool.address, toWei("1000000000")); // enough interest
  await aavePool.setRewardRate(toWei("0.000000000317097920")); // arb apy 1%. 0.01 / 365 / 86400 / 1

  return {
    weth,
    usdc,
    mcb,
    arb,

    // MUX
    mlp,
    mux,
    liquidityPool,
    orderBook,

    // MUX stake
    smlp,
    rewardRouter,

    // uniswap
    uniswap,
    quoter: uniswap, // mock implements quoter

    // AAVE
    ausdc,
    aavePool,
    aaveRewardsController: aavePool, // mock implements rewardsController
  };
}

export async function setMockersBlockTime(dep: any, blockTime: number) {
  await dep.orderBook.setBlockTime(blockTime);
  await dep.rewardRouter.setBlockTime(blockTime);
  await dep.ausdc.setBlockTime(blockTime);
  await dep.aaveRewardsController.setBlockTime(blockTime);
}
