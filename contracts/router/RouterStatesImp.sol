// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.17;

import "@openzeppelin/contracts-upgradeable/utils/structs/EnumerableSetUpgradeable.sol";

import "./Type.sol";

library RouterStatesImp {
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.AddressSet;

    // UserStatus.DepositJunior
    // store.users[account].stateValues[0] // The amount of mlp (1e18) that user want to depost (*)
    // eg: A wants to deposit 10 mlp. then
    //     store.users[account].stateValues[0] will be 10 mlp.

    // UserStatus.WithdrawJunior
    // store.users[account].stateValues[0] // The amount of junior share that user want to withdraw (*)
    // store.users[account].stateValues[1] // The amount of junior asset (mlp) to withdraw
    // store.users[account].stateValues[2] // The amount of usdc to repay to seniorVault
    // store.users[account].stateValues[3] // The amount of mlp to sell to repay to seniorVault
    // eg: B wants to withdraw 10 junior shares, totalAsset = 20, totalSupply = 20, totalDebt = 5, mlpPrice = $1 then
    //     store.users[account].stateValues[0] = 10 shares
    //     store.users[account].stateValues[1] = totalAsset * share / totalSupply = 20 * 10 / 20 = 10 mlp
    //     store.users[account].stateValues[2] = totalDebt * share / totalSupply = 5 * 10 / 20 = 2.5 usdc
    //     store.users[account].stateValues[3] = 2.5 / mlpPrice = 2.5 mlp (need to sell 2.5 mlp for 2.5 usdc to repay debts)

    // UserStatus.WithdrawSenior
    // store.users[account].stateValues[0] // The amount of senior share that user want to withdraw (*)
    // store.users[account].stateValues[1] // The amount of senior asset (usdc) to withdraw
    // store.users[account].stateValues[2] // The amount of junior asset (mlp) to sell to repay seniorVault
    // store.users[account].stateValues[3] // The amount of senior asset (usdc) reservs for withdraw
    // eg: C wants to withdraw 10 senior shares, totalAsset = 5, totalSupply = 20, mlpPrice = $1 then
    //     store.users[account].stateValues[0] = 10 shares
    //     store.users[account].stateValues[1] = 10 usdc
    //     store.users[account].stateValues[2] = 5 usdc (now we have 5 usdc and we need another 5 usdc for C to withdraw)
    //     store.users[account].stateValues[3] = 5 usdc (5 usdc is reserved, if next user want to withdraw 5 usdc, he has to wait)

    function juniorTotalSupply(RouterStateStore storage store) internal view returns (uint256) {
        // withdrawJunior +pending
        return store.juniorVault.totalSupply() + store.pendingJuniorShares;
    }

    function juniorTotalAssets(RouterStateStore storage store) internal view returns (uint256) {
        // withdrawJunior +pending
        // withdrawSenior +pending
        return store.juniorVault.totalAssets() + store.pendingJuniorAssets;
    }

    function seniorTotalAssets(RouterStateStore storage store) internal view returns (uint256) {
        return store.seniorVault.totalAssets() - store.pendingSeniorAssets;
    }

    function seniorTotalSupply(RouterStateStore storage store) internal view returns (uint256) {
        return store.seniorVault.totalSupply();
    }

    function setOrderId(RouterStateStore storage store, address account, uint64 orderId) internal {
        store.users[account].orderId = orderId;
        store.pendingOrders[orderId] = account;
        require(store.pendingUsers.add(account), "RouterStatesImp::FAILED_TO_ADD_USER");
    }

    function cleanOrderId(RouterStateStore storage store, address account) internal {
        delete store.pendingOrders[store.users[account].orderId];
        store.users[account].orderId = 0;
        require(store.pendingUsers.remove(account), "RouterStatesImp::FAILED_TO_REMOVE_USER");
    }

    function cleanStates(RouterStateStore storage store, address account) internal {
        store.users[account].status = UserStatus.Idle;
        store.users[account].stateValues[0] = 0;
        for (uint256 i = 0; i < STATE_VALUES_COUNT; i++) {
            store.users[account].stateValues[i] = 0;
        }
    }

    // Idle => DepositJunior
    function getDepositJuniorStatus(
        RouterStateStore storage store,
        address account
    ) internal view returns (uint256 juniorAssets) {
        juniorAssets = store.users[account].stateValues[0];
    }

    function setDepositJuniorStatus(
        RouterStateStore storage store,
        address account,
        uint256 juniorAssets
    ) internal {
        store.users[account].status = UserStatus.DepositJunior;
        store.users[account].stateValues[0] = juniorAssets;
        store.pendingJuniorDeposits += juniorAssets;
    }

    function cleanDepositJuniorStatus(RouterStateStore storage store, address account) internal {
        uint256 juniorAssets = getDepositJuniorStatus(store, account);
        store.pendingJuniorDeposits -= juniorAssets;
        cleanStates(store, account);
        cleanOrderId(store, account);
    }

    // Idle => withdrawJunior
    function getWithdrawJuniorStatus(
        RouterStateStore storage store,
        address account
    )
        internal
        view
        returns (
            uint256 juniorShares,
            uint256 juniorAssets,
            uint256 seniorRepays,
            uint256 juniorRemovals
        )
    {
        juniorShares = store.users[account].stateValues[0];
        juniorAssets = store.users[account].stateValues[1];
        seniorRepays = store.users[account].stateValues[2];
        juniorRemovals = store.users[account].stateValues[3];
    }

    function setWithdrawJuniorStatus(
        RouterStateStore storage store,
        address account,
        uint256 shares,
        uint256 assets,
        uint256 repays,
        uint256 removals
    ) internal {
        if (store.users[account].stateValues[0] != shares) {
            store.pendingJuniorShares += (shares - store.users[account].stateValues[0]);
            store.users[account].stateValues[0] = shares;
        }
        if (store.users[account].stateValues[1] != assets) {
            store.pendingJuniorAssets += (assets - store.users[account].stateValues[1]);
            store.users[account].stateValues[1] = assets;
        }
        store.users[account].stateValues[2] = repays;
        store.users[account].stateValues[3] = removals;
        store.users[account].status = UserStatus.WithdrawJunior;
    }

    function cleanWithdrawJuniorStatus(RouterStateStore storage store, address account) internal {
        (uint256 shares, uint256 assets, , ) = getWithdrawJuniorStatus(store, account);
        store.pendingJuniorShares -= shares;
        store.pendingJuniorAssets -= assets;
        cleanStates(store, account);
        cleanOrderId(store, account);
    }

    // Idle => withdrawJunior
    function getWithdrawSeniorStatus(
        RouterStateStore storage store,
        address account
    ) internal view returns (uint256 shares, uint256 assets, uint256 removals, uint256 reserves) {
        shares = store.users[account].stateValues[0];
        assets = store.users[account].stateValues[1];
        removals = store.users[account].stateValues[2];
        reserves = store.users[account].stateValues[3];
    }

    function setWithdrawSeniorStatus(
        RouterStateStore storage store,
        address account,
        uint256 shares,
        uint256 assets,
        uint256 removals,
        uint256 reserves
    ) internal {
        if (store.users[account].stateValues[0] != shares) {
            store.pendingSeniorShares += (shares - store.users[account].stateValues[0]);
            store.users[account].stateValues[0] = shares;
        }
        store.users[account].stateValues[1] = assets;
        if (store.users[account].stateValues[2] != removals) {
            store.pendingJuniorAssets += (removals - store.users[account].stateValues[2]);
            store.users[account].stateValues[2] = removals;
        }
        if (store.users[account].stateValues[3] != reserves) {
            store.pendingSeniorAssets += (reserves - store.users[account].stateValues[3]);
            store.users[account].stateValues[3] = reserves;
        }
        store.users[account].status = UserStatus.WithdrawSenior;
    }

    function cleanWithdrawSeniorStatus(RouterStateStore storage store, address account) internal {
        (uint256 shares, , uint256 removals, uint256 reserves) = getWithdrawSeniorStatus(
            store,
            account
        );
        store.pendingSeniorShares -= shares;
        store.pendingJuniorAssets -= removals;
        store.pendingSeniorAssets -= reserves;
        cleanStates(store, account);
        cleanOrderId(store, account);
    }

    // rebalance - buy
    function getBuyJuniorStatus(
        RouterStateStore storage store
    ) internal view returns (uint256 depositAssets) {
        depositAssets = store.users[address(0)].stateValues[0];
    }

    function setBuyJuniorStatus(RouterStateStore storage store, uint256 assets) internal {
        store.users[address(0)].status = UserStatus.BuyJunior;
        store.users[address(0)].stateValues[0] = assets;
        store.pendingBorrowAssets += assets;
    }

    function cleanBuyJuniorStatus(RouterStateStore storage store) internal {
        require(
            store.users[address(0)].status == UserStatus.BuyJunior,
            "RouterAccountImp::INVALID_STATUS"
        );
        uint256 assets = getBuyJuniorStatus(store);
        store.pendingBorrowAssets -= assets;
        cleanStates(store, address(0));
        cleanOrderId(store, address(0));
    }

    // rebalance - sell
    function getSellJuniorStatus(
        RouterStateStore storage store
    ) internal view returns (uint256 assets) {
        assets = store.users[address(0)].stateValues[0];
    }

    function setSellJuniorStatus(RouterStateStore storage store, uint256 assets) internal {
        store.users[address(0)].status = UserStatus.SellJunior;
        store.users[address(0)].stateValues[0] = assets;
    }

    function cleanSellJuniorStatus(RouterStateStore storage store) internal {
        require(
            store.users[address(0)].status == UserStatus.SellJunior,
            "RouterAccountImp::INVALID_STATUS"
        );
        cleanStates(store, address(0));
        cleanOrderId(store, address(0));
    }

    function isRebalancing(RouterStateStore storage store) internal view returns (bool) {
        return
            store.users[address(0)].status == UserStatus.SellJunior ||
            store.users[address(0)].status == UserStatus.BuyJunior;
    }

    // rebalance - refund
    function getRefundJuniorStatus(
        RouterStateStore storage store
    ) internal view returns (uint256 assets) {
        assets = store.users[address(0)].stateValues[0];
    }

    function setRefundJuniorStatus(RouterStateStore storage store, uint256 assets) internal {
        store.users[address(0)].status = UserStatus.RefundJunior;
        store.users[address(0)].stateValues[0] = assets;
    }

    function cleanRefundJuniorStatus(RouterStateStore storage store) internal {
        require(
            store.users[address(0)].status == UserStatus.RefundJunior,
            "RouterAccountImp::INVALID_STATUS"
        );
        uint256 assets = getRefundJuniorStatus(store);
        store.pendingRefundAssets -= assets;
        cleanStates(store, address(0));
        cleanOrderId(store, address(0));
    }
}
