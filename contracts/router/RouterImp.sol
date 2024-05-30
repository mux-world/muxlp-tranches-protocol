// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.17;

import "@openzeppelin/contracts-upgradeable/utils/structs/EnumerableSetUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import "../libraries/LibConfigSet.sol";
import "../libraries/LibUniswap.sol";
import "../mux/MuxAdapter.sol";

import "./RouterUtilImp.sol";
import "./Type.sol";
import "./RouterJuniorImp.sol";
import "./RouterSeniorImp.sol";
import "./RouterRebalanceImp.sol";
import "./RouterRewardImp.sol";
import "./RouterStatesImp.sol";

library RouterImp {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.AddressSet;
    using LibConfigSet for ConfigSet;
    using LibTypeCast for bytes32;

    using MuxAdapter for ConfigSet;
    using RouterUtilImp for RouterStateStore;
    using RouterJuniorImp for RouterStateStore;
    using RouterSeniorImp for RouterStateStore;
    using RouterRewardImp for RouterStateStore;
    using RouterStatesImp for RouterStateStore;
    using RouterRebalanceImp for RouterStateStore;

    event Liquidate(uint256 balance);
    event LiquidateInterrupted();

    function initialize(
        RouterStateStore storage store,
        address seniorVault,
        address juniorVault,
        address rewardController
    ) public {
        require(seniorVault != address(0), "RouterImp::INVALID_ADDRESS");
        require(juniorVault != address(0), "RouterImp::INVALID_ADDRESS");
        require(rewardController != address(0), "RouterImp::INVALID_ADDRESS");
        // skip 0
        store.seniorVault = ISeniorVault(seniorVault);
        store.juniorVault = IJuniorVault(juniorVault);
        store.rewardController = IRewardController(rewardController);
    }

    function depositJunior(RouterStateStore storage store, address account, uint256 assets) public {
        store.depositJunior(account, assets);
    }

    function withdrawJunior(
        RouterStateStore storage store,
        address account,
        uint256 shares
    ) public {
        store.withdrawJunior(account, shares);
    }

    function depositSenior(RouterStateStore storage store, address account, uint256 assets) public {
        store.depositSenior(account, assets);
    }

    function withdrawSenior(
        RouterStateStore storage store,
        address account,
        uint256 shares,
        bool acceptPenalty
    ) public {
        store.withdrawSenior(account, shares, acceptPenalty);
    }

    function refundJunior(RouterStateStore storage store) public {
        store.refundJunior(store.pendingRefundAssets);
    }

    // =============================================== Rebalance ===============================================
    function juniorNavPerShare(
        RouterStateStore storage store,
        uint256 seniorPrice,
        uint256 juniorPrice
    ) internal view returns (uint256) {
        uint256 juniorTotalShares = store.juniorTotalSupply();
        uint256 juniorTotalValues = store.juniorTotalAssets() * juniorPrice;
        uint256 juniorTotalBorrows = store.toJuniorUnit(store.seniorBorrows()) * seniorPrice;
        if (juniorTotalShares != 0 && juniorTotalValues > juniorTotalBorrows) {
            return (juniorTotalValues - juniorTotalBorrows) / juniorTotalShares;
        } else {
            return 0;
        }
    }

    function juniorLeverage(
        RouterStateStore storage store,
        uint256 seniorPrice,
        uint256 juniorPrice
    ) internal view returns (uint256 leverage) {
        require(juniorPrice != 0, "RouterImp::INVALID_PRICE");
        require(seniorPrice != 0, "RouterImp::INVALID_PRICE");
        uint256 juniorTotalBorrows = store.toJuniorUnit(store.seniorBorrows()) * seniorPrice;
        if (juniorTotalBorrows == 0) {
            return ONE;
        }
        uint256 juniorTotalValue = store.juniorTotalAssets() * juniorPrice;
        if (juniorTotalValue <= juniorTotalBorrows) {
            return type(uint256).max; // should be liquidated
        }
        uint256 principle = juniorTotalValue - juniorTotalBorrows;
        return juniorTotalValue / (principle / ONE);
    }

    function isRebalancing(RouterStateStore storage store) internal view returns (bool) {
        return store.isRebalancing();
    }

    function isJuniorBalanced(
        RouterStateStore storage store,
        uint256 seniorPrice,
        uint256 juniorPrice
    ) public view returns (bool isBalanced, bool isBorrow, uint256 delta) {
        uint256 targetLeverage = store.config.getUint256(TARGET_LEVERAGE);
        require(targetLeverage > ONE, "RouterImp::INVALID_LEVERAGE");
        uint256 assetUsd = (store.juniorTotalAssets() * juniorPrice) / ONE;
        uint256 borrowUsd = (store.toJuniorUnit(store.seniorBorrows()) * seniorPrice) / ONE;
        if (assetUsd > borrowUsd) {
            uint256 threshold = store.config.getUint256(REBALANCE_THRESHOLD);
            uint256 thresholdUsd = store.config.getUint256(REBALANCE_THRESHOLD_USD);
            uint256 principleUsd = assetUsd - borrowUsd;
            uint256 targetBorrowUsd = (principleUsd * (targetLeverage - ONE)) / ONE;
            isBorrow = targetBorrowUsd >= borrowUsd;
            uint256 deltaUsd = isBorrow ? targetBorrowUsd - borrowUsd : borrowUsd - targetBorrowUsd;
            delta = store.toSeniorUnit((deltaUsd * ONE) / seniorPrice);
            if (delta >= thresholdUsd && ((deltaUsd * ONE) / principleUsd) >= threshold) {
                isBalanced = false;
            } else {
                isBalanced = true;
            }
        } else {
            // wait for liquidation, not rebalanced
            isBalanced = true;
            isBorrow = false;
            delta = 0;
        }
    }

    function updateRewards(RouterStateStore storage store) public {
        updateRewards(store, address(0));
    }

    function updateRewards(RouterStateStore storage store, address account) public {
        address token0 = store.seniorVault.depositToken();
        uint256 reward0 = store.seniorVault.claimAaveRewards(address(store.rewardController));
        if (reward0 > 0) {
            store.rewardController.notifySeniorExtraReward(token0, reward0);
        }
        (address token1, uint256 reward1) = store.seniorVault.claimAaveExtraRewards(
            address(store.rewardController)
        );
        if (reward1 > 0) {
            store.rewardController.notifySeniorExtraReward(token1, reward1);
        }
        store.updateRewards(account);
    }

    function rebalance(
        RouterStateStore storage store,
        uint256 seniorPrice,
        uint256 juniorPrice
    ) public {
        require(!store.isRebalancing(), "RouterImp::INPROGRESS");
        (bool isBalanced, bool isBorrow, uint256 delta) = isJuniorBalanced(
            store,
            seniorPrice,
            juniorPrice
        );
        require(!isBalanced, "RouterImp::BALANCED");
        require(store.config.checkMlpPriceBound(juniorPrice), "RouterImp::PRICE_OUT_OF_BOUNDS");
        // decimal 18 => decimals of senior asset
        if (isBorrow) {
            uint256 borrowable = store.seniorVault.borrowable(address(this));
            if (borrowable > store.pendingSeniorAssets) {
                borrowable -= store.pendingSeniorAssets;
            } else {
                borrowable = 0;
            }
            uint256 toBorrow = MathUpgradeable.min(borrowable, delta);
            // add a threshold to toBorrow
            // avoid to buy too small amount juniors
            store.buyJunior(toBorrow);
        } else {
            // to wad
            uint256 assets = store.config.estimateMaxIn(store.toJuniorUnit(delta));
            store.sellJunior(assets);
        }
    }

    function liquidate(
        RouterStateStore storage store,
        uint256 seniorPrice,
        uint256 juniorPrice
    ) public {
        require(store.config.checkMlpPriceBound(juniorPrice), "RouterImp::PRICE_OUT_OF_BOUNDS");
        uint256 leverage = juniorLeverage(store, seniorPrice, juniorPrice);
        uint256 maxLeverage = store.config.getUint256(LIQUIDATION_LEVERAGE);
        require(leverage > maxLeverage, "RouterImp::NOT_LIQUIDATABLE");
        cancelAllPendingOperations(store);
        store.isLiquidated = true;
        uint256 totalBalance = store.juniorVault.totalAssets();
        store.sellJunior(totalBalance);
        emit Liquidate(totalBalance);
    }

    // =============================================== Callbacks ===============================================
    function onOrderFilled(
        RouterStateStore storage store,
        MuxOrderContext memory context,
        uint256 amountOut
    ) public {
        address account = store.pendingOrders[context.orderId];
        UserState storage state = store.users[account];
        if (state.status == UserStatus.DepositJunior) {
            store.onDepositJuniorSuccess(context, account, amountOut);
        } else if (state.status == UserStatus.WithdrawJunior) {
            store.onWithdrawJuniorSuccess(context, account, amountOut);
        } else if (state.status == UserStatus.WithdrawSenior) {
            store.onWithdrawSeniorSuccess(context, account, amountOut);
        } else if (state.status == UserStatus.BuyJunior) {
            store.onBuyJuniorSuccess(context, amountOut);
        } else if (state.status == UserStatus.SellJunior) {
            store.onSellJuniorSuccess(context, amountOut);
        } else if (state.status == UserStatus.RefundJunior) {
            store.onRefundJuniorSuccess(context, amountOut);
        } else {
            revert("ImpRouter::INVALID_STATUS");
        }
    }

    function onOrderCancelled(RouterStateStore storage store, uint64 orderId) public {
        address account = store.pendingOrders[orderId];
        cancelPendingStates(store, account);
    }

    function getPendingUserCount(RouterStateStore storage store) internal view returns (uint256) {
        return store.pendingUsers.length();
    }

    function getPendingUsers(
        RouterStateStore storage store,
        uint256 begin,
        uint256 count
    ) internal view returns (address[] memory users) {
        count = MathUpgradeable.min(count, store.pendingUsers.length() - begin);
        users = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            users[i] = store.pendingUsers.at(i + begin);
        }
    }

    function getUserOrderTime(
        RouterStateStore storage store,
        uint64 orderId
    ) external view returns (uint32 placeOrderTime) {
        return store.config.getPlaceOrderTime(orderId);
    }

    function cancelAllPendingOperations(RouterStateStore storage store) internal {
        uint256 count = getPendingUserCount(store);
        uint64[] memory orderIds = new uint64[](count);
        for (uint256 i = 0; i < count; i++) {
            orderIds[i] = store.users[store.pendingUsers.at(i)].orderId;
        }
        for (uint256 i = 0; i < orderIds.length; i++) {
            if (orderIds[i] != 0) {
                store.config.cancelOrder(orderIds[i]);
            }
        }
    }

    function cancelPendingOperation(RouterStateStore storage store, address account) internal {
        UserState memory userState = store.users[account];
        require(userState.status != UserStatus.Idle, "RouterV1::INPROPER_STATUS");
        if (userState.orderId != 0) {
            store.config.cancelOrder(userState.orderId);
        } else {
            cancelPendingStates(store, account);
        }
    }

    function cancelPendingStates(RouterStateStore storage store, address account) internal {
        UserState storage state = store.users[account];
        if (state.status == UserStatus.DepositJunior) {
            store.onDepositJuniorFailed(account);
        } else if (state.status == UserStatus.WithdrawJunior) {
            store.onWithdrawJuniorFailed(account);
        } else if (state.status == UserStatus.WithdrawSenior) {
            store.onWithdrawSeniorFailed(account);
        } else if (state.status == UserStatus.BuyJunior) {
            store.onBuyJuniorFailed();
        } else if (state.status == UserStatus.SellJunior) {
            store.onSellJuniorFailed();
        } else if (state.status == UserStatus.RefundJunior) {
            store.onRefundJuniorFailed();
        } else {
            revert("ImpRouter::INVALID_STATUS");
        }
    }
}
