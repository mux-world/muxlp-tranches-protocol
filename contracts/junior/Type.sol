// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.17;

import "../libraries/LibConfigSet.sol";
import "../libraries/LibDefines.sol";

struct JuniorStateStore {
    bytes32[50] __offsets;
    ConfigSet config;
    address depositToken;
    address asset;
    uint8 assetDecimals;
    uint256 totalAssets;
    uint256 totalSupply;
    mapping(address => uint256) balances;
    bytes32[20] __reserves;
}
