// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.17;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/MathUpgradeable.sol";

import "../mux/MuxAdapter.sol";
import "./Type.sol";

library JuniorVaultImp {
    using MathUpgradeable for uint256;
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using LibConfigSet for ConfigSet;
    using MuxAdapter for ConfigSet;

    event Deposit(address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(
        address indexed caller,
        address indexed owner,
        uint256 shares,
        uint256 assets,
        address receiver
    );
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event TransferIn(uint256 assets);
    event TransferOut(uint256 assets, address receiver);

    function initialize(JuniorStateStore storage store, address asset) internal {
        require(asset != address(0), "ERC4626Store::INVALID_ASSET");
        store.assetDecimals = retrieveDecimals(asset);
        store.asset = asset;
    }

    function deposit(
        JuniorStateStore storage store,
        uint256 assets,
        uint256 shares,
        address receiver
    ) internal returns (uint256) {
        update(store, address(0), receiver, shares);
        transferIn(store, assets);

        emit Deposit(receiver, assets, shares);
        return shares;
    }

    function withdraw(
        JuniorStateStore storage store,
        address caller,
        address owner,
        uint256 shares,
        address receiver
    ) internal returns (uint256 assets) {
        require(shares <= store.balances[owner], "JuniorVaultImp::EXCEEDS_BALANCE");
        assets = convertToAssets(store, shares);
        update(store, owner, address(0), shares);
        transferOut(store, assets, receiver);

        emit Withdraw(caller, owner, shares, assets, receiver);
    }

    function transferIn(JuniorStateStore storage store, uint256 assets) internal {
        uint256 balance = IERC20Upgradeable(store.depositToken).balanceOf(address(this));
        require(balance >= assets, "JuniorVaultImp::INSUFFICIENT_ASSETS");
        store.totalAssets += assets;
        store.config.stake(assets);
        store.config.adjustVesting();

        emit TransferIn(assets);
    }

    function transferOut(
        JuniorStateStore storage store,
        uint256 assets,
        address receiver
    ) internal {
        require(assets <= store.totalAssets, "JuniorVaultImp::INSUFFICIENT_ASSETS");
        store.config.unstake(assets);
        IERC20Upgradeable(store.depositToken).safeTransfer(receiver, assets);
        store.totalAssets -= assets;
        store.config.adjustVesting();

        emit TransferOut(assets, receiver);
    }

    function collectMuxRewards(JuniorStateStore storage store, address receiver) internal {
        store.config.collectMuxRewards(receiver);
    }

    function retrieveDecimals(address asset) internal view returns (uint8) {
        (bool success, bytes memory data) = address(asset).staticcall(
            abi.encodeWithSignature("decimals()")
        );
        require(success, "SeniorVaultImp::FAILED_TO_GET_DECIMALS");
        return abi.decode(data, (uint8));
    }

    function update(
        JuniorStateStore storage store,
        address from,
        address to,
        uint256 amount
    ) internal {
        if (from == address(0)) {
            store.totalSupply += amount;
        } else {
            uint256 fromBalance = store.balances[from];
            require(amount <= fromBalance, "ERC4626::EXCEEDED_BALANCE");
            store.balances[from] = fromBalance - amount;
        }
        if (to == address(0)) {
            store.totalSupply -= amount;
        } else {
            store.balances[to] += amount;
        }

        emit Transfer(from, to, amount);
    }

    function convertToAssets(
        JuniorStateStore storage store,
        uint256 shares
    ) internal view returns (uint256) {
        return
            shares.mulDiv(
                store.totalAssets + 1,
                store.totalSupply + 1,
                MathUpgradeable.Rounding.Down
            );
    }
}
