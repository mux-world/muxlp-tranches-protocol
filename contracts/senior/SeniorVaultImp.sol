// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.17;

import "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

import "../libraries/LibConfigSet.sol";
import "./SeniorVaultStore.sol";
import "../interfaces/aave/IPool.sol";
import "../interfaces/aave/IRewardsController.sol";

library SeniorVaultImp {
    using LibConfigSet for ConfigSet;
    using SafeERC20Upgradeable for IERC20Upgradeable;

    event Deposit(address indexed owner, uint256 assets, uint256 shares, uint256 unlockTime);
    event Withdraw(
        address indexed caller,
        address indexed owner,
        uint256 shares,
        uint256 assets,
        address receiver,
        uint256 penalty
    );
    event Borrow(uint256 assets, address receiver);
    event Repay(uint256 assets, address receiver);

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event TransferIn(uint256 assets);
    event TransferOut(uint256 assets, address receiver);
    event SupplyToAave(address pool, address aToken, uint256 amount, uint256 totalSuppliedBalance);
    event WithdrawFromAave(
        address pool,
        address aToken,
        uint256 amount,
        uint256 totalSuppliedBalance
    );

    function initialize(SeniorStateStore storage store, address asset) internal {
        require(asset != address(0), "ERC4626Store::INVALID_ASSET");
        store.assetDecimals = retrieveDecimals(asset);
        store.asset = asset;
    }

    function borrowable(
        SeniorStateStore storage store,
        address receiver
    ) internal view returns (uint256 assets) {
        // max borrows
        uint256 maxBorrow = store.config.getUint256(MAX_BORROWS);
        uint256 available = IERC20Upgradeable(store.asset).balanceOf(address(this)) +
            store.aaveSuppliedBalance;
        if (maxBorrow != 0) {
            uint256 capacity = maxBorrow > store.totalBorrows ? maxBorrow - store.totalBorrows : 0;
            assets = MathUpgradeable.min(capacity, available);
        } else {
            assets = available;
        }
        uint256 borrowLimit = store.config.getUint256(keccak256(abi.encode(MAX_BORROWS, receiver)));
        if (borrowLimit != 0) {
            uint256 capacity = borrowLimit > store.borrows[receiver]
                ? borrowLimit - store.borrows[receiver]
                : 0;
            assets = MathUpgradeable.min(capacity, borrowLimit);
        }
    }

    // deposit stable coin into vault
    function deposit(
        SeniorStateStore storage store,
        uint256 assets,
        address receiver
    ) internal returns (uint256 shares) {
        require(assets > 0, "SeniorVaultImp::INVALID_ASSETS");
        uint256 assetSupplyCap = store.config.getUint256(ASSET_SUPPLY_CAP);
        uint256 assetSupply = convertToAssets(store, store.totalSupply);
        require(
            assetSupplyCap == 0 || assetSupply + assets <= assetSupplyCap,
            "SeniorVaultImp::EXCEEDS_SUPPLY_CAP"
        );
        shares = convertToShares(store, assets);
        update(store, address(0), receiver, shares);
        transferIn(store, assets);
        uint256 unlockTime = updateTimelock(store, receiver);

        emit Deposit(receiver, assets, shares, unlockTime);
    }

    function withdraw(
        SeniorStateStore storage store,
        address caller,
        address owner,
        uint256 shares,
        address receiver
    ) internal returns (uint256 assets, uint256 penalty) {
        require(shares <= store.balances[owner], "SeniorVaultImp::EXCEEDS_MAX_REDEEM");
        assets = convertToAssets(store, shares);
        update(store, owner, address(0), shares);
        (penalty, assets) = collectWithdrawPenalty(store, owner, assets);
        transferOut(store, assets, receiver);

        emit Withdraw(caller, owner, shares, assets, receiver, penalty);
    }

    function collectWithdrawPenalty(
        SeniorStateStore storage store,
        address owner,
        uint256 assets // assetDecimals
    ) internal returns (uint256 penalty, uint256 assetsAfterPenalty) {
        if (block.timestamp > store.timelocks[owner]) {
            penalty = 0;
            assetsAfterPenalty = assets;
        } else {
            uint256 lockPenaltyRate = store.config.getUint256(LOCK_PENALTY_RATE);
            address receiver = store.config.getAddress(LOCK_PENALTY_RECIPIENT);
            if (lockPenaltyRate == 0 || receiver == address(0)) {
                penalty = 0;
                assetsAfterPenalty = assets;
            } else {
                penalty = (assets * lockPenaltyRate) / ONE;
                assetsAfterPenalty = assets - penalty;
                transferOut(store, penalty, receiver);
            }
        }
    }

    function borrow(SeniorStateStore storage store, uint256 assets, address receiver) internal {
        uint256 borrowableAssets = borrowable(store, receiver);
        require(assets <= borrowableAssets, "SeniorVaultImp::EXCEEDS_BORROWABLE");
        store.borrows[receiver] += assets;
        store.totalBorrows += assets;
        transferOut(store, assets, receiver);

        emit Borrow(assets, receiver);
    }

    function repay(SeniorStateStore storage store, address repayer, uint256 assets) internal {
        require(assets <= store.totalBorrows, "SeniorVaultImp::EXCEEDS_TOTAL_BORROWS");
        store.totalBorrows -= assets;
        store.borrows[repayer] -= assets;
        transferIn(store, assets);
        emit Repay(assets, repayer);
    }

    function transferIn(SeniorStateStore storage store, uint256 assets) internal {
        uint256 balance = IERC20Upgradeable(store.asset).balanceOf(address(this));
        uint256 delta = balance - store.previousBalance;
        require(delta >= assets, "SeniorVaultImp::INSUFFICENT_ASSETS");
        store.totalAssets += assets;
        store.previousBalance = balance;
        emit TransferIn(assets);
    }

    function transferOut(
        SeniorStateStore storage store,
        uint256 assets,
        address receiver
    ) internal {
        require(assets <= store.totalAssets, "SeniorVaultImp::INSUFFICENT_ASSETS");
        IERC20Upgradeable(store.asset).safeTransfer(receiver, assets);
        store.totalAssets -= assets;
        store.previousBalance = IERC20Upgradeable(store.asset).balanceOf(address(this));
        emit TransferOut(assets, receiver);
    }

    function updateTimelock(
        SeniorStateStore storage store,
        address receiver
    ) internal returns (uint256 unlockTime) {
        uint256 lockPeriod = store.config.getUint256(LOCK_PERIOD);
        unlockTime = block.timestamp + lockPeriod;
        store.timelocks[receiver] = unlockTime;
    }

    function update(
        SeniorStateStore storage store,
        address from,
        address to,
        uint256 amount
    ) internal {
        if (from == address(0)) {
            store.totalSupply += amount;
        } else {
            uint256 fromBalance = store.balances[from];
            require(amount <= fromBalance, "SeniorVaultImp::EXCEEDED_BALANCE");
            store.balances[from] = fromBalance - amount;
        }
        if (to == address(0)) {
            store.totalSupply -= amount;
        } else {
            store.balances[to] += amount;
        }

        emit Transfer(from, to, amount);
    }

    function retrieveDecimals(address asset) internal view returns (uint8) {
        (bool success, bytes memory data) = address(asset).staticcall(
            abi.encodeWithSignature("decimals()")
        );
        require(success, "SeniorVaultImp::FAILED_TO_GET_DECIMALS");
        return abi.decode(data, (uint8));
    }

    function convertToShares(
        SeniorStateStore storage store,
        uint256 assets // assetDecimals
    ) internal view returns (uint256 shares) {
        shares = assets * (10 ** (18 - store.assetDecimals));
    }

    function convertToAssets(
        SeniorStateStore storage store,
        uint256 shares
    ) internal view returns (uint256 assets) {
        assets = shares / (10 ** (18 - store.assetDecimals));
    }

    function supplyToAave(SeniorStateStore storage store, uint256 amount) internal {
        require(amount > 0, "AaveAdapter::INVALID_AMOUNT");
        address aaveToken = store.config.mustGetAddress(AAVE_TOKEN);
        address aavePool = store.config.mustGetAddress(AAVE_POOL);
        require(amount <= tokenBalance(store.asset), "AaveAdapter::DEPOSIT_AMOUNT_EXCEEDED");
        // approve && supply
        IERC20Upgradeable(store.asset).approve(address(aavePool), amount);
        // check balance of atoken returned from Aave
        uint256 aaveTokenBalance = tokenBalance(aaveToken);
        IPool(aavePool).supply(store.asset, amount, address(this), 0);
        require(
            tokenBalance(aaveToken) - aaveTokenBalance >= ignoreRoundingError(amount),
            "AaveAdapter::UNEXPECTED_RECEIVE_AMOUNT"
        );
        store.aaveSuppliedBalance += amount;
        store.previousBalance = IERC20Upgradeable(store.asset).balanceOf(address(this));

        emit SupplyToAave(aavePool, aaveToken, amount, store.aaveSuppliedBalance);
    }

    function supplyAllBalanceToAave(SeniorStateStore storage store) internal {
        address aavePool = store.config.mustGetAddress(AAVE_POOL);
        uint256 depositTokenBalance = tokenBalance(store.asset);
        if (depositTokenBalance > 0 && aavePool != address(0)) {
            supplyToAave(store, depositTokenBalance);
        }
    }

    function withdrawSuppliedFromAave(SeniorStateStore storage store, uint256 amount) internal {
        require(amount <= store.aaveSuppliedBalance, "AaveAdapter::INVALID_AMOUNT");
        withdrawFromAave(store, amount);
        store.aaveSuppliedBalance -= amount;
    }

    function withdrawFromAave(SeniorStateStore storage store, uint256 amount) internal {
        address aaveToken = store.config.mustGetAddress(AAVE_TOKEN);
        address aavePool = store.config.mustGetAddress(AAVE_POOL);
        require(amount <= tokenBalance(aaveToken), "AaveAdapter::WITHDRAW_AMOUNT_EXCEEDED");
        // check deposit token balance from aave
        uint256 depositTokenBalance = tokenBalance(store.asset);
        IPool(aavePool).withdraw(store.asset, amount, address(this));
        require(
            tokenBalance(store.asset) - depositTokenBalance >= ignoreRoundingError(amount),
            "AaveAdapter::UNEXPECTED_RECEIVE_AMOUNT"
        );
        emit WithdrawFromAave(aavePool, aaveToken, amount, store.aaveSuppliedBalance);
    }

    function claimAaveRewards(
        SeniorStateStore storage store,
        address receiver
    ) internal returns (uint256) {
        require(receiver != address(0), "AaveAdapter::INVALID_RECEIVER");
        address aaveToken = store.config.mustGetAddress(AAVE_TOKEN);
        uint256 amount = increasedBalance(store);
        // to avoid rounding error involved by aave viarant balance
        if (amount > 0) {
            uint256 balanceBefore = tokenBalance(store.asset);
            withdrawFromAave(store, amount);
            require(
                tokenBalance(store.asset) - balanceBefore >= ignoreRoundingError(amount),
                "AaveAdapter::INVALID_INCREASED_BALANCE"
            );
            require(
                tokenBalance(aaveToken) >= ignoreRoundingError(store.aaveSuppliedBalance),
                "AaveAdapter::INVALID_A_BALANCE"
            );
            IERC20Upgradeable(store.asset).safeTransfer(receiver, amount);
        }

        return amount;
    }

    function claimableAaveExtraRewards(
        SeniorStateStore storage store
    ) internal view returns (address token, uint256 amount) {
        address aaveToken = store.config.mustGetAddress(AAVE_TOKEN);
        address aaveRewardController = store.config.mustGetAddress(AAVE_REWARDS_CONTROLLER);
        address aaveExtraRewardToken = store.config.mustGetAddress(AAVE_EXTRA_REWARD_TOKEN);
        address[] memory tokens = new address[](1);
        tokens[0] = aaveToken;
        token = aaveExtraRewardToken;
        amount = IRewardsController(aaveRewardController).getUserRewards(
            tokens,
            address(this),
            aaveExtraRewardToken
        );
    }

    function claimAaveExtraRewards(
        SeniorStateStore storage store,
        address receiver
    ) internal returns (address token, uint256 amount) {
        address aaveToken = store.config.mustGetAddress(AAVE_TOKEN);
        address aaveRewardController = store.config.mustGetAddress(AAVE_REWARDS_CONTROLLER);
        address aaveExtraRewardToken = store.config.mustGetAddress(AAVE_EXTRA_REWARD_TOKEN);
        address[] memory tokens = new address[](1);
        tokens[0] = aaveToken;
        token = aaveExtraRewardToken;
        try
            IRewardsController(aaveRewardController).claimRewards(
                tokens,
                type(uint256).max,
                receiver,
                aaveExtraRewardToken
            )
        returns (uint256 rewardAmount) {
            amount = rewardAmount;
        } catch {
            amount = 0;
        }
    }

    function tokenBalance(address token) internal view returns (uint256) {
        return IERC20Upgradeable(token).balanceOf(address(this));
    }

    function increasedBalance(SeniorStateStore storage store) internal view returns (uint256) {
        address aaveToken = store.config.mustGetAddress(AAVE_TOKEN);
        uint256 balance = tokenBalance(aaveToken);
        if (balance > store.aaveSuppliedBalance) {
            return balance - store.aaveSuppliedBalance;
        } else {
            return 0;
        }
    }

    function ignoreRoundingError(uint256 n) internal pure returns (uint256) {
        return n > 0 ? n - 1 : 0;
    }
}
