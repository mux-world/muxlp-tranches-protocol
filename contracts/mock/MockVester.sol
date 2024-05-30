// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.17;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

contract MockVester {
    mapping(address => uint256) public balances;
    mapping(address => uint256) public pairAmounts;
}
