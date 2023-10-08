// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.17;

import "../libraries/LibConfigSet.sol";
import "../libraries/LibDefines.sol";

struct SeniorStateStore {
    bytes32[50] __offsets;
    // config
    ConfigSet config;
    // balance properties
    address asset;
    uint8 assetDecimals;
    uint256 totalAssets;
    uint256 totalSupply;
    uint256 previousBalance;
    uint256 totalBorrows;
    // assets borrowed to junior vaults
    mapping(address => uint256) borrows;
    mapping(address => uint256) balances;
    mapping(address => uint256) timelocks;
    bytes32[20] __reserves;
}
