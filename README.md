# mux-leverage-protocol

## Overview

Mux Leverage Protocol is a protocol for creating tranche tokens to boost rewards from MUX staking protocols.

The core principle of Mux Leverage Protocol revolves around two distinct user groups: providers of stablecoins and borrowers who utilize these stablecoins to acquire MLP tokens. Through this process, users can maximize their potential returns.

The protocol is designed to be used with the MUX protocol, but can be used with any ERC20 token.

## Architecture

![Alt text](misc/architecture.png?raw=true "Architecture")

The Mux Leverage Protocol consists of four main components: SeniorVault, JuniorVault, RewardDistributor and Router.

SeniorVault is primarily designed for users who do not wish to take on high risks. Users deposit stablecoins to provide liquidity for JuniorVault users to borrow and use for purchasing MLP tokens, thereby earning additional rewards. Meanwhile, SeniorVault users will receive a portion of the proceeds based on the utilization rate.

JuniorVault users, on the other hand, bear the primary risk of MLP price fluctuations but also stand to gain higher returns.

SeniorVault serves as a single entity to enhance the utilization of funds, while JuniorVaults can exist in multiple instances, each implementing its own strategy (eg, different leverage or different reward distibution).

RewardDistributor is primarily responsible for the distribution of rewards.

The Router serves as a connection between SeniorVault and JuniorVault, providing a unified interface for user access, Additionally, the Router component includes essential functionalities like rebalancing and liquidation, which help maintain the overall system stability.

### StableVault

StableVault includes standard Deposit/Withdraw interfaces. It is important to note that the Withdraw method includes an optional time lock feature.

The time lock can have three possible values: None, Hard Lock, and Soft Lock.

When the administrator opens the time lock, whether it is a Hard Lock or Soft Lock, the user's unlock time is updated every time they make a deposit. The formula for calculating the new unlock time is NewUnlockTime = CurrentTime + unlockPeriod.

For a Hard Lock, users are unable to retrieve their collateral before the time lock expires. However, for a Soft Lock, users have the option to force the retrieval of their collateral under the condition that a certain penalty ratio is applied.

Once the time lock expires, there are no restrictions on user withdrawals.

### JuniorVault

JuniorVault operates similar to a fund and encompasses the concepts of net asset value (NAV) and overall debt. The value of assets held by users may experience fluctuations over time.

During the withdrawal process, users are required to first repay their portion of debt before being able to retrieve their assets.

### Router

The primary role of the Router is to connect actions such as borrowing, purchasing MLP, and withdrawals. It serves as a bridge that links these activities together within the system.

In the Router system, there is a role called Keeper. Keepers are responsible for calling the rebalance method at appropriate times to help adjust the asset-to-primary ratio of SeniorVault towards the target leverage ratio.

### RewardDistributor

The RewardDistributor distributes rewards to the shareholders of JuniorVault and SeniorVault based on earnings and utilization rate.

The distribution strategy currently employed involves proportionally allocating rewards to both JuniorVault and SeniorVault. However, there is a priority placed on safeguarding the minimum annualized yield for SeniorVault based on its utilization rate. If the yield falls below this threshold, SeniorVault receives all rewards until the minimum yield is met.

## Compile && Test

```
npx hardhat compile
npx hardhat test
```
