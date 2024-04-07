// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.17;

import "@openzeppelin/contracts-upgradeable/utils/structs/EnumerableSetUpgradeable.sol";
import "../interfaces/ISeniorVault.sol";
import "../interfaces/IJuniorVault.sol";
import "../interfaces/IRewardController.sol";

import "../libraries/LibConfigSet.sol";
import "../libraries/LibDefines.sol";

uint256 constant STATE_VALUES_COUNT = 5;

enum UserStatus {
    Idle,
    DepositJunior,
    WithdrawJunior,
    WithdrawSenior,
    BuyJunior,
    SellJunior,
    RefundJunior,
    Liquidate
}

struct UserState {
    UserStatus status;
    uint64 orderId;
    uint256[STATE_VALUES_COUNT] stateValues;
}

struct RouterStateStore {
    bytes32[50] __offsets;
    // config;
    ConfigSet config;
    // components
    ISeniorVault seniorVault;
    IJuniorVault juniorVault;
    IRewardController rewardController;
    // properties
    bool isLiquidated;
    uint256 pendingJuniorShares;
    uint256 pendingJuniorAssets;
    uint256 pendingSeniorShares;
    uint256 pendingSeniorAssets;
    uint256 pendingRefundAssets;
    uint256 pendingBorrowAssets;
    mapping(address => UserState) users;
    mapping(uint64 => address) pendingOrders;
    EnumerableSetUpgradeable.AddressSet pendingUsers;
    uint256 pendingJuniorDeposits;
    bytes32[19] __reserves;
}

struct MuxOrderContext {
    uint64 orderId;
    uint8 seniorAssetId;
    uint96 seniorPrice;
    uint96 juniorPrice;
    uint96 currentSeniorValue;
    uint96 targetSeniorValue;
}
