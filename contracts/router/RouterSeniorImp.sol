// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.17;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import "../libraries/LibConfigSet.sol";
import "../libraries/LibUniswap.sol";
import "../mux/MuxAdapter.sol";

import "./RouterUtilImp.sol";
import "./RouterStatesImp.sol";
import "./RouterRebalanceImp.sol";
import "./RouterRewardImp.sol";
import "./Type.sol";

library RouterSeniorImp {
    using RouterUtilImp for RouterStateStore;
    using RouterRewardImp for RouterStateStore;
    using RouterStatesImp for RouterStateStore;
    using RouterRebalanceImp for RouterStateStore;
    using MuxAdapter for ConfigSet;
    using LibConfigSet for ConfigSet;
    using LibTypeCast for bytes32;
    using SafeERC20Upgradeable for IERC20Upgradeable;

    event DepositSenior(address indexed account, uint256 seniorAssetsToDeposit);

    event WithdrawSenior(address indexed account, uint256 seniorSharesToWithdraw);
    event WithdrawSeniorDelayed(
        address indexed account,
        uint256 seniorSharesToWithdraw,
        uint256 seniorAssetsToWithdraw,
        uint256 seniorAssetsWithdrawable
    );
    event HandleWithdrawSenior(
        address indexed account,
        uint256 seniorSharesToWithdraw,
        uint256 seniorAssetsToWithdraw,
        uint256 juniorAssetsToRemove,
        uint256 seniorAssetsWithdrawable
    );
    event WithdrawSeniorSuccess(
        address indexed account,
        uint256 seniorSharesToWithdraw,
        uint256 seniorAssetsToWithdraw,
        uint256 juniorAssetsToRemove,
        uint256 seniorAssetsWithdrawable,
        uint256 seniorAssetsToRepay,
        uint256 seniorAssetsOverflow
    );
    event WithdrawSeniorFailed(
        address indexed account,
        uint256 seniorSharesToWithdraw,
        uint256 seniorAssetsToWithdraw,
        uint256 juniorAssetsToRemove,
        uint256 seniorAssetsWithdrawable
    );

    // =============================================== Deposit Senior ===============================================
    function depositSenior(
        RouterStateStore storage store,
        address account,
        uint256 seniorAssetsToDeposit
    ) public {
        require(seniorAssetsToDeposit > 0, "RouterSeniorImp::ZERO_AMOUNT");
        IERC20Upgradeable(store.seniorVault.depositToken()).safeTransferFrom(
            account,
            address(store.seniorVault),
            seniorAssetsToDeposit
        );
        store.seniorVault.deposit(seniorAssetsToDeposit, account);
        emit DepositSenior(account, seniorAssetsToDeposit);
    }

    // =============================================== Withdraw Senior ===============================================
    function checkTimelock(
        RouterStateStore storage store,
        address account,
        bool acceptPenalty
    ) internal view {
        bool isLocked = store.seniorVault.timelock(account) >= block.timestamp;
        require(!isLocked || (isLocked && acceptPenalty), "RouterSeniorImp::LOCKED");
    }

    function withdrawSenior(
        RouterStateStore storage store,
        address account,
        uint256 seniorSharesToWithdraw, // assets
        bool acceptPenalty
    ) public {
        checkTimelock(store, account, acceptPenalty);
        require(
            seniorSharesToWithdraw <= store.seniorVault.balanceOf(account),
            "RouterSeniorImp::EXCEEDS_BALANCE"
        );
        // withdraw
        uint256 seniorAssetsToWithdraw = store.seniorVault.convertToAssets(seniorSharesToWithdraw);
        uint256 seniorAssetsWithdrawable = store.seniorVault.totalAssets() >
            store.pendingSeniorAssets
            ? store.seniorVault.totalAssets() - store.pendingSeniorAssets
            : 0;

        if (seniorAssetsToWithdraw <= seniorAssetsWithdrawable) {
            store.seniorVault.withdraw(msg.sender, account, seniorSharesToWithdraw, account);
            emit WithdrawSenior(account, seniorSharesToWithdraw);
        } else {
            uint256 juniorAssetsToRemove = store.toJuniorUnit(
                store.config.estimateMaxIn(seniorAssetsToWithdraw - seniorAssetsWithdrawable)
            );
            store.juniorVault.transferOut(juniorAssetsToRemove);
            uint64 orderId = store.config.placeRemoveOrder(
                store.juniorVault.depositToken(),
                store.seniorVault.depositToken(),
                juniorAssetsToRemove
            );
            store.setOrderId(account, orderId);
            store.setWithdrawSeniorStatus(
                account,
                seniorSharesToWithdraw,
                seniorAssetsToWithdraw,
                juniorAssetsToRemove,
                seniorAssetsWithdrawable
            );
            emit WithdrawSeniorDelayed(
                account,
                seniorSharesToWithdraw,
                seniorAssetsToWithdraw,
                seniorAssetsWithdrawable
            );
        }
    }

    function onWithdrawSeniorSuccess(
        RouterStateStore storage store,
        MuxOrderContext memory,
        address account,
        uint256 seniorAssetsBought
    ) public {
        (
            uint256 seniorSharesToWithdraw,
            uint256 seniorAssetsToWithdraw,
            uint256 juniorAssetsToRemove,
            uint256 seniorAssetsWithdrawable
        ) = store.getWithdrawSeniorStatus(account);
        require(
            seniorAssetsBought + seniorAssetsWithdrawable >= seniorAssetsToWithdraw,
            "RouterSeniorImp::INSUFFICIENT_REPAYMENT"
        );
        uint256 seniorAssetsBorrrowed = store.seniorBorrows();
        uint256 seniorAssetsToRepay = MathUpgradeable.min(
            seniorAssetsBought,
            seniorAssetsBorrrowed
        );
        IERC20Upgradeable(store.seniorVault.depositToken()).safeTransfer(
            address(store.seniorVault),
            seniorAssetsToRepay
        );
        store.seniorVault.repay(seniorAssetsToRepay);
        store.seniorVault.withdraw(account, account, seniorSharesToWithdraw, account);
        store.cleanWithdrawSeniorStatus(account);
        uint256 seniorAssetsOverflow = seniorAssetsBought - seniorAssetsToRepay;
        if (seniorAssetsOverflow > 0) {
            store.pendingRefundAssets += seniorAssetsOverflow;
        }

        emit WithdrawSeniorSuccess(
            account,
            seniorSharesToWithdraw,
            seniorAssetsToWithdraw,
            juniorAssetsToRemove,
            seniorAssetsWithdrawable,
            seniorAssetsToRepay,
            seniorAssetsOverflow
        );
    }

    function onWithdrawSeniorFailed(RouterStateStore storage store, address account) public {
        (
            uint256 seniorSharesToWithdraw,
            uint256 seniorAssetsToWithdraw,
            uint256 juniorAssetsToRemove,
            uint256 seniorAssetsWithdrawable
        ) = store.getWithdrawSeniorStatus(account);
        IERC20Upgradeable(store.juniorVault.depositToken()).safeTransfer(
            address(store.juniorVault),
            juniorAssetsToRemove
        );
        store.juniorVault.transferIn(juniorAssetsToRemove);
        store.cleanWithdrawSeniorStatus(account);
        emit WithdrawSeniorFailed(
            account,
            seniorSharesToWithdraw,
            seniorAssetsToWithdraw,
            juniorAssetsToRemove,
            seniorAssetsWithdrawable
        );
    }
}
