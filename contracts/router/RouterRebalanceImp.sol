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
import "./RouterStatesImp.sol";
import "./RouterRewardImp.sol";
import "./Type.sol";

library RouterRebalanceImp {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using LibConfigSet for ConfigSet;
    using LibTypeCast for bytes32;
    using MuxAdapter for ConfigSet;
    using RouterUtilImp for RouterStateStore;
    using RouterStatesImp for RouterStateStore;
    using RouterRewardImp for RouterStateStore;

    event BuyJunior(uint256 seniorAssetToSpend, uint64 orderId);
    event BuyJuniorSuccess(
        uint256 seniorAssetsSpent,
        uint256 juniorAssetsBought,
        uint256 juniorPrice
    );
    event BuyJuniorFailed(uint256 seniorAssetToSpend);

    event SellJunior(uint256 juniorAssetsToSpend, uint256 orderId);
    event SellJuniorSuccess(
        uint256 juniorAssetsSpent,
        uint256 seniorAssetsBought,
        uint256 seniorAssetsOverflow,
        uint256 juniorPrice
    );
    event SellJuniorFailed(uint256 juniorAssetsToSpend);

    event RefundJunior(uint256 seniorAssetToSpend, uint64 orderId);
    event RefundJuniorSuccess(
        uint256 seniorAssetsSpent,
        uint256 juniorAssetsBought,
        uint256 juniorPrice
    );
    event RefundJuniorFailed(uint256 seniorAssetToSpend);

    // ==================================== Buy Junior ============================================
    function buyJunior(RouterStateStore storage store, uint256 seniorAssetToSpend) internal {
        require(seniorAssetToSpend > 0, "RouterJuniorImp::ZERO_AMOUNT");
        store.seniorVault.borrow(seniorAssetToSpend);
        store.setBuyJuniorStatus(seniorAssetToSpend);
        uint64 orderId = store.config.placeAddOrder(
            store.seniorVault.depositToken(),
            seniorAssetToSpend
        );
        store.setOrderId(address(0), orderId);
        emit BuyJunior(seniorAssetToSpend, orderId);
    }

    function onBuyJuniorSuccess(
        RouterStateStore storage store,
        MuxOrderContext memory context,
        uint256 juniorAssetsBought
    ) public {
        uint256 seniorAssetsSpent = store.getBuyJuniorStatus();
        IERC20Upgradeable(store.juniorVault.depositToken()).safeTransfer(
            address(store.juniorVault),
            juniorAssetsBought
        );
        store.juniorVault.transferIn(juniorAssetsBought);
        store.cleanBuyJuniorStatus();

        emit BuyJuniorSuccess(seniorAssetsSpent, juniorAssetsBought, context.juniorPrice);
    }

    function onBuyJuniorFailed(RouterStateStore storage store) public {
        uint256 seniorAssetsSpent = store.getBuyJuniorStatus();
        IERC20Upgradeable(store.seniorVault.depositToken()).safeTransfer(
            address(store.seniorVault),
            seniorAssetsSpent
        );
        store.seniorVault.repay(seniorAssetsSpent);
        store.cleanBuyJuniorStatus();
        emit BuyJuniorFailed(seniorAssetsSpent);
    }

    // ==================================== Sell Junior ============================================
    function sellJunior(RouterStateStore storage store, uint256 juniorAssetsToSpend) public {
        require(juniorAssetsToSpend > 0, "RouterJuniorImp::ZERO_AMOUNT");
        store.juniorVault.transferOut(juniorAssetsToSpend);
        uint64 orderId = store.config.placeRemoveOrder(
            store.juniorVault.depositToken(),
            store.seniorVault.depositToken(),
            juniorAssetsToSpend
        );
        store.setOrderId(address(0), orderId);
        store.setSellJuniorStatus(juniorAssetsToSpend);
        emit SellJunior(juniorAssetsToSpend, orderId);
    }

    function onSellJuniorSuccess(
        RouterStateStore storage store,
        MuxOrderContext memory context,
        uint256 seniorAssetsBought
    ) public {
        uint256 juniorAssetsSpent = store.getSellJuniorStatus();
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
        store.cleanSellJuniorStatus();
        // 3. return the remaining over total debts to junior.
        //    only the last junior or liquidation will have overflows.
        uint256 seniorAssetsOverflow = seniorAssetsBought - seniorAssetsToRepay;
        if (seniorAssetsOverflow > 0) {
            store.pendingRefundAssets += seniorAssetsOverflow;
        }
        if (store.isLiquidated) {
            store.isLiquidated = false;
        }
        emit SellJuniorSuccess(
            juniorAssetsSpent,
            seniorAssetsToRepay,
            seniorAssetsOverflow,
            context.juniorPrice
        );
    }

    function onSellJuniorFailed(RouterStateStore storage store) public {
        uint256 juniorAssetsSpent = store.getSellJuniorStatus();
        IERC20Upgradeable(store.juniorVault.depositToken()).safeTransfer(
            address(store.juniorVault),
            juniorAssetsSpent
        );
        store.juniorVault.transferIn(juniorAssetsSpent);
        store.cleanSellJuniorStatus();
        emit SellJuniorFailed(juniorAssetsSpent);
    }

    // refund
    function refundJunior(RouterStateStore storage store, uint256 seniorAssetToSpend) internal {
        require(seniorAssetToSpend > 0, "RouterJuniorImp::ZERO_AMOUNT");
        store.setRefundJuniorStatus(seniorAssetToSpend);
        uint64 orderId = store.config.placeAddOrder(
            store.seniorVault.depositToken(),
            seniorAssetToSpend
        );
        store.setOrderId(address(0), orderId);
        emit RefundJunior(seniorAssetToSpend, orderId);
    }

    function onRefundJuniorSuccess(
        RouterStateStore storage store,
        MuxOrderContext memory context,
        uint256 juniorAssetsBought
    ) public {
        uint256 seniorAssetsSpent = store.getRefundJuniorStatus();
        IERC20Upgradeable(store.juniorVault.depositToken()).safeTransfer(
            address(store.juniorVault),
            juniorAssetsBought
        );
        store.juniorVault.transferIn(juniorAssetsBought);
        store.cleanRefundJuniorStatus();
        emit RefundJuniorSuccess(seniorAssetsSpent, juniorAssetsBought, context.juniorPrice);
    }

    function onRefundJuniorFailed(RouterStateStore storage) public pure {
        revert("RefundJuniorFailed");
    }
}
