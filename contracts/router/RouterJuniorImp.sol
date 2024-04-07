// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.17;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/MathUpgradeable.sol";

import "../libraries/LibConfigSet.sol";
import "../libraries/LibUniswap.sol";
import "../mux/MuxAdapter.sol";

import "./RouterUtilImp.sol";
import "./RouterStatesImp.sol";
import "./RouterRewardImp.sol";
import "./Type.sol";

library RouterJuniorImp {
    using MathUpgradeable for uint256;
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using LibConfigSet for ConfigSet;
    using LibTypeCast for bytes32;
    using MuxAdapter for ConfigSet;
    using RouterUtilImp for RouterStateStore;
    using RouterStatesImp for RouterStateStore;
    using RouterRewardImp for RouterStateStore;

    event DepositJunior(address indexed account, uint256 juniorAssetsToDeposit);
    event HandleDepositJunior(address indexed account, uint256 juniorAssetsToDeposit);
    event DepositJuniorSuccess(
        address indexed account,
        uint256 juniorAssetsToDeposit,
        uint256 juniorAssetsBought,
        uint256 juniorSharesToMint
    );
    event DepositJuniorFailed(address indexed account, uint256 juniorAssetsToDeposit);

    event WithdrawJunior(
        address indexed account,
        uint256 juniorSharesToWithdraw,
        uint256 juniorAssetsToWithdraw
    );
    event HandleWithdrawJunior(
        address indexed account,
        uint256 juniorSharesToWithdraw,
        uint256 juniorAssetsToWithdraw,
        uint256 seniorAssetsToRepay,
        uint256 juniorAssetsToRemove
    );
    event WithdrawJuniorSuccess(
        address indexed account,
        uint256 seniorAssetsBought,
        uint256 seniorAssetsToRepay,
        uint256 juniorAssetsRemains,
        uint256 seniorAssetsRemains
    );
    event WithdrawJuniorFailed(
        address indexed account,
        uint256 juniorSharesToWithdraw,
        uint256 juniorAssetsToWithdraw
    );

    function depositJunior(
        RouterStateStore storage store,
        address account,
        uint256 juniorAssetsToDeposit
    ) public {
        require(juniorAssetsToDeposit > 0, "RouterJuniorImp::ZERO_AMOUNT");

        uint256 assetSupplyCap = store.juniorVault.getConfig(ASSET_SUPPLY_CAP).toUint256();
        if (assetSupplyCap > 0) {
            IMuxLiquidityPool muxLiquidityPool = IMuxLiquidityPool(
                store.config.mustGetAddress(MUX_LIQUIDITY_POOL)
            );
            (, uint96[2] memory bounds) = muxLiquidityPool.getLiquidityPoolStorage();
            uint256 maxPrice = bounds[1];
            uint256 juniorNetValue = (store.juniorTotalAssets() * maxPrice) /
                ONE -
                store.toJuniorUnit(store.seniorBorrows());
            uint256 juniorValueToDeposit = (juniorAssetsToDeposit * maxPrice) / ONE; // USD
            require(
                juniorValueToDeposit + juniorNetValue + store.pendingJuniorDeposits <=
                    assetSupplyCap,
                "RouterJuniorImp::EXCEEDS_SUPPLY_CAP"
            );
        }

        IERC20Upgradeable(store.juniorVault.depositToken()).safeTransferFrom(
            account,
            address(this),
            juniorAssetsToDeposit
        );
        store.setDepositJuniorStatus(account, juniorAssetsToDeposit);
        uint64 orderId = store.config.placeAddOrder(store.seniorVault.depositToken(), 0);
        store.setOrderId(account, orderId);
        emit DepositJunior(account, juniorAssetsToDeposit);
    }

    function onDepositJuniorSuccess(
        RouterStateStore storage store,
        MuxOrderContext memory context,
        address account,
        uint256 juniorAssetsBought
    ) public {
        // now the mechinism is retrieving junior price from a 0-amount order
        require(juniorAssetsBought == 0, "RouterJuniorImp::INVALID_AMOUNT_OUT");
        uint256 juniorAssetsToDeposit = store.getDepositJuniorStatus(account);
        // test supply cap
        uint256 seniorValueBorrows = (store.toJuniorUnit(store.seniorBorrows()) *
            context.seniorPrice); // USD
        uint256 juniorNetValue = store.juniorTotalAssets() *
            context.juniorPrice -
            seniorValueBorrows;

        IERC20Upgradeable(store.juniorVault.depositToken()).safeTransfer(
            address(store.juniorVault),
            juniorAssetsToDeposit
        );
        uint256 juniorSharesToMint = convertToShares(
            store.juniorVault.totalSupply(),
            juniorNetValue / context.juniorPrice,
            juniorAssetsToDeposit
        );
        store.juniorVault.deposit(juniorAssetsToDeposit, juniorSharesToMint, account);
        store.cleanDepositJuniorStatus(account);
        emit DepositJuniorSuccess(
            account,
            juniorAssetsToDeposit,
            juniorAssetsBought,
            juniorSharesToMint
        );
    }

    function convertToShares(
        uint256 totalSupply,
        uint256 totalAssets,
        uint256 assets
    ) internal pure returns (uint256) {
        return assets.mulDiv(totalSupply + 1, totalAssets + 1, MathUpgradeable.Rounding.Down);
    }

    // @notice Return the junior assets to user if failed.
    function onDepositJuniorFailed(RouterStateStore storage store, address account) public {
        uint256 juniorAssetsToDeposit = store.getDepositJuniorStatus(account);
        IERC20Upgradeable(store.juniorVault.depositToken()).safeTransfer(
            account,
            juniorAssetsToDeposit
        );
        store.cleanDepositJuniorStatus(account);
        emit DepositJuniorFailed(account, juniorAssetsToDeposit);
    }

    // =============================================== Withdraw Junior ===============================================
    function withdrawJunior(
        RouterStateStore storage store,
        address account,
        uint256 juniorSharesToWithdraw
    ) public {
        require(juniorSharesToWithdraw > 0, "RouterJuniorImp::ZERO_AMOUNT");
        require(
            juniorSharesToWithdraw <= store.juniorVault.balanceOf(account),
            "RouterJuniorImp::EXCEEDS_REDEEMABLE"
        );
        uint256 borrows = store.seniorBorrows();
        uint256 juniorTotalSupply = store.juniorTotalSupply();
        uint256 seniorAssetsToRepay = juniorTotalSupply != 0
            ? ((borrows * juniorSharesToWithdraw) / juniorTotalSupply)
            : borrows;
        uint256 juniorAssetsToRemove = store.config.estimateMaxIn(
            store.toJuniorUnit(seniorAssetsToRepay)
        );
        uint256 juniorAssetsToWithdraw = store.juniorVault.withdraw(
            account,
            account,
            juniorSharesToWithdraw,
            address(this)
        );
        require(juniorAssetsToWithdraw >= seniorAssetsToRepay, "ImpRouter::UNSAFE");

        uint64 orderId = store.config.placeRemoveOrder(
            store.juniorVault.depositToken(),
            store.seniorVault.depositToken(),
            juniorAssetsToRemove
        );
        store.setOrderId(account, orderId);
        store.setWithdrawJuniorStatus(
            account,
            juniorSharesToWithdraw,
            juniorAssetsToWithdraw,
            seniorAssetsToRepay,
            juniorAssetsToRemove
        );

        // console.log("withdrawJunior:");
        // console.log("juniorSharesToWithdraw", juniorSharesToWithdraw);
        // console.log("juniorAssetsToWithdraw", juniorAssetsToWithdraw);
        // console.log("seniorAssetsToRepay", seniorAssetsToRepay);
        // console.log("juniorAssetsToRemove", juniorAssetsToRemove);

        // the status of ticket should be init
        emit WithdrawJunior(account, juniorSharesToWithdraw, juniorAssetsToWithdraw);
    }

    function onWithdrawJuniorSuccess(
        RouterStateStore storage store,
        MuxOrderContext memory context,
        address account,
        uint256 seniorAssetsBought // senior token
    ) public {
        (
            ,
            uint256 juniorAssetsToWithdraw,
            uint256 seniorAssetsToRepay,
            uint256 juniorAssetsToRemove
        ) = store.getWithdrawJuniorStatus(account);

        require(seniorAssetsBought >= seniorAssetsToRepay, "ImpJunior::INSUFFICIENT_REPAYMENT");
        uint256 seniorAssetsBorrowed = store.seniorBorrows();
        uint256 juniorAssetsRemains = juniorAssetsToWithdraw - juniorAssetsToRemove;

        // virtual swap
        if (seniorAssetsBought > seniorAssetsToRepay && seniorAssetsBorrowed > 0) {
            // the junior amount we removed is always more than the expected amount
            // since we have exact junior and senior prices
            // we do a virtual swap, turning the extra output to junior token
            // to avoid the case that junior user receives both junior and senior token after withdrawal
            uint256 swapIn = MathUpgradeable.min(
                seniorAssetsBought - seniorAssetsToRepay,
                seniorAssetsBorrowed
            );
            uint256 swapOut = store.toJuniorUnit(
                (swapIn * context.seniorPrice) / context.juniorPrice
            );
            if (store.juniorVault.totalAssets() > swapOut) {
                store.juniorVault.transferOut(swapOut);
                juniorAssetsRemains += swapOut;
                // combined with repay
                seniorAssetsToRepay += swapIn;
            }
        }

        // repay
        if (seniorAssetsToRepay > 0) {
            IERC20Upgradeable(store.seniorVault.depositToken()).safeTransfer(
                address(store.seniorVault),
                seniorAssetsToRepay
            );
            store.seniorVault.repay(seniorAssetsToRepay);
        }
        // senior => user
        uint256 seniorAssetsRemains = seniorAssetsBought - seniorAssetsToRepay;
        if (seniorAssetsRemains > 0) {
            IERC20Upgradeable(store.seniorVault.depositToken()).safeTransfer(
                account,
                seniorAssetsRemains
            );
        }
        // junior => user
        if (juniorAssetsRemains > 0) {
            IERC20Upgradeable(store.juniorVault.depositToken()).safeTransfer(
                account,
                juniorAssetsRemains
            );
        }
        store.cleanWithdrawJuniorStatus(account);
        emit WithdrawJuniorSuccess(
            account,
            seniorAssetsBought,
            seniorAssetsToRepay,
            juniorAssetsRemains,
            seniorAssetsRemains
        );
    }

    function onWithdrawJuniorFailed(RouterStateStore storage store, address account) public {
        (uint256 juniorSharesToWithdraw, uint256 juniorAssetsToWithdraw, , ) = store
            .getWithdrawJuniorStatus(account);
        IERC20Upgradeable(store.juniorVault.depositToken()).safeTransfer(
            address(store.juniorVault),
            juniorAssetsToWithdraw
        );
        store.juniorVault.transferIn(juniorAssetsToWithdraw);
        store.juniorVault.deposit(juniorAssetsToWithdraw, juniorSharesToWithdraw, account);
        store.cleanWithdrawJuniorStatus(account);
        emit WithdrawJuniorFailed(account, juniorSharesToWithdraw, juniorAssetsToWithdraw);
    }
}
