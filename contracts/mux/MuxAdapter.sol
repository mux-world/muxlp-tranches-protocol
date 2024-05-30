// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.17;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/MathUpgradeable.sol";

import "../interfaces/mux/IMuxRewardRouter.sol";
import "../interfaces/mux/IMuxLiquidityPool.sol";
import "../interfaces/mux/IMuxOrderBook.sol";
import "../interfaces/mux/IMuxVester.sol";

import "../libraries/LibDefines.sol";
import "../libraries/LibAsset.sol";
import "../libraries/LibConfigSet.sol";
import "../libraries/LibTypeCast.sol";
import "../libraries/LibReferenceOracle.sol";

library MuxAdapter {
    using LibAsset for IMuxLiquidityPool.Asset;
    using LibTypeCast for uint256;
    using LibConfigSet for ConfigSet;
    using SafeERC20Upgradeable for IERC20Upgradeable;

    struct LiquidityPoolConfig {
        uint32 strictStableDeviation;
        uint32 liquidityBaseFeeRate;
        uint32 liquidityDynamicFeeRate;
    }

    event CollectRewards(uint256 wethAmount, uint256 mcbAmount);
    event AdjustVesting(
        uint256 vestedMlpAmount,
        uint256 vestedMuxAmount,
        uint256 requiredMlpAmount,
        uint256 totalMlpAmount,
        uint256 toVestMuxAmount
    );

    function pendingRewards(
        ConfigSet storage set
    ) internal returns (uint256 wethAmount, uint256 mcbAmount) {
        IMuxRewardRouter muxRewardRouter = IMuxRewardRouter(set.mustGetAddress(MUX_REWARD_ROUTER));
        (wethAmount, , , , mcbAmount) = muxRewardRouter.claimableRewards(address(this));
    }

    function collectMuxRewards(ConfigSet storage set, address receiver) internal {
        require(receiver != address(0), "MuxAdapter::INVALID_RECEIVER");
        IMuxRewardRouter muxRewardRouter = IMuxRewardRouter(set.mustGetAddress(MUX_REWARD_ROUTER));
        IERC20Upgradeable mcbToken = IERC20Upgradeable(set.mustGetAddress(MCB_TOKEN));
        IERC20Upgradeable wethToken = IERC20Upgradeable(set.mustGetAddress(WETH_TOKEN));
        address vester = muxRewardRouter.mlpVester();
        require(vester != address(0), "MuxAdapter::INVALID_VESTER");
        (uint256 wethAmount, , , , uint256 mcbAmount) = muxRewardRouter.claimableRewards(
            address(this)
        );
        muxRewardRouter.claimAll();
        if (wethAmount > 0) {
            wethToken.safeTransfer(receiver, wethAmount);
        }
        if (mcbAmount > 0) {
            mcbToken.safeTransfer(receiver, mcbAmount);
        }
        emit CollectRewards(wethAmount, mcbAmount);
    }

    function stake(ConfigSet storage set, uint256 amount) internal {
        // stake
        if (amount > 0) {
            IMuxRewardRouter muxRewardRouter = IMuxRewardRouter(
                set.mustGetAddress(MUX_REWARD_ROUTER)
            );
            IERC20Upgradeable mlpToken = IERC20Upgradeable(set.mustGetAddress(MLP_TOKEN));
            address mlpFeeTracker = muxRewardRouter.mlpFeeTracker();
            mlpToken.approve(address(mlpFeeTracker), amount);
            muxRewardRouter.stakeMlp(amount);
        }
    }

    function unstake(ConfigSet storage set, uint256 amount) internal {
        if (amount > 0) {
            IMuxRewardRouter muxRewardRouter = IMuxRewardRouter(
                set.mustGetAddress(MUX_REWARD_ROUTER)
            );
            IERC20Upgradeable sMlpToken = IERC20Upgradeable(set.mustGetAddress(SMLP_TOKEN));
            // vest => smlp
            if (muxRewardRouter.reservedMlpAmount(address(this)) > 0) {
                muxRewardRouter.withdrawFromMlpVester();
            }
            // smlp => mlp
            sMlpToken.approve(muxRewardRouter.mlpFeeTracker(), amount);
            muxRewardRouter.unstakeMlp(amount);
        }
    }

    function adjustVesting(ConfigSet storage set) internal {
        IMuxRewardRouter muxRewardRouter = IMuxRewardRouter(set.mustGetAddress(MUX_REWARD_ROUTER));
        IERC20Upgradeable muxToken = IERC20Upgradeable(set.mustGetAddress(MUX_TOKEN));
        IERC20Upgradeable sMlpToken = IERC20Upgradeable(set.mustGetAddress(SMLP_TOKEN));
        IMuxVester vester = IMuxVester(muxRewardRouter.mlpVester());
        require(address(vester) != address(0), "MuxAdapter::INVALID_VESTER");
        uint256 muxAmount = muxToken.balanceOf(address(this));
        if (muxAmount == 0) {
            return;
        }
        uint256 vestedMlpAmount = vester.pairAmounts(address(this));
        uint256 vestedMuxAmount = vester.balanceOf(address(this));
        uint256 requiredMlpAmount = vester.getPairAmount(
            address(this),
            muxAmount + vestedMuxAmount
        );
        uint256 mlpAmount = sMlpToken.balanceOf(address(this)) + vestedMlpAmount;
        uint256 toVestMuxAmount;
        if (mlpAmount >= requiredMlpAmount) {
            toVestMuxAmount = muxAmount;
        } else {
            uint256 rate = (mlpAmount * ONE) / requiredMlpAmount;
            toVestMuxAmount = (muxAmount * rate) / ONE;
            if (toVestMuxAmount > vestedMuxAmount) {
                toVestMuxAmount = toVestMuxAmount - vestedMuxAmount;
            } else {
                toVestMuxAmount = 0;
            }
        }
        if (toVestMuxAmount > 0) {
            muxToken.approve(address(vester), toVestMuxAmount);
            muxRewardRouter.depositToMlpVester(toVestMuxAmount);
        }
        emit AdjustVesting(
            vestedMlpAmount,
            vestedMuxAmount,
            requiredMlpAmount,
            mlpAmount,
            toVestMuxAmount
        );
    }

    function retrieveMuxAssetId(
        ConfigSet storage set,
        address token
    ) internal view returns (uint8) {
        require(token != address(0), "AdapterImp::INVALID_TOKEN");
        IMuxLiquidityPool liquidityPool = IMuxLiquidityPool(set.mustGetAddress(MUX_LIQUIDITY_POOL));
        IMuxLiquidityPool.Asset[] memory assets = liquidityPool.getAllAssetInfo();
        for (uint256 i = 0; i < assets.length; i++) {
            if (assets[i].tokenAddress == token) {
                return assets[i].id;
            }
        }
        revert("MuxAdapter::UNSUPPORTED_ASSET");
    }

    function getPlaceOrderTime(
        ConfigSet storage set,
        uint64 orderId
    ) internal view returns (uint32 placeOrderTime) {
        IMuxOrderBook muxOrderBook = IMuxOrderBook(set.mustGetAddress(MUX_ORDER_BOOK));
        (bytes32[3] memory orderData, bool exists) = muxOrderBook.getOrder(orderId);
        if (exists) {
            placeOrderTime = uint32(bytes4(orderData[1] << 160));
        }
    }

    function cancelOrder(ConfigSet storage set, uint64 orderId) internal {
        IMuxOrderBook muxOrderBook = IMuxOrderBook(set.mustGetAddress(MUX_ORDER_BOOK));
        muxOrderBook.cancelOrder(orderId);
    }

    function placeAddOrder(
        ConfigSet storage set,
        address seniorToken,
        uint256 usdAmount
    ) internal returns (uint64 orderId) {
        IMuxOrderBook muxOrderBook = IMuxOrderBook(set.mustGetAddress(MUX_ORDER_BOOK));
        orderId = muxOrderBook.nextOrderId();
        IERC20Upgradeable(seniorToken).approve(address(muxOrderBook), usdAmount);
        muxOrderBook.placeLiquidityOrder(
            retrieveMuxAssetId(set, seniorToken),
            uint96(usdAmount),
            true
        );
    }

    function placeRemoveOrder(
        ConfigSet storage set,
        address juniorToken,
        address seniorToken,
        uint256 amount
    ) internal returns (uint64 orderId) {
        IMuxOrderBook muxOrderBook = IMuxOrderBook(set.mustGetAddress(MUX_ORDER_BOOK));
        orderId = muxOrderBook.nextOrderId();
        IERC20Upgradeable(juniorToken).approve(address(muxOrderBook), amount);
        muxOrderBook.placeLiquidityOrder(
            retrieveMuxAssetId(set, seniorToken),
            uint96(amount),
            false
        );
    }

    function checkMlpPriceBound(
        ConfigSet storage set,
        uint256 mlpPrice
    ) internal view returns (bool isValid) {
        IMuxLiquidityPool muxLiquidityPool = IMuxLiquidityPool(
            set.mustGetAddress(MUX_LIQUIDITY_POOL)
        );
        (, uint96[2] memory bounds) = muxLiquidityPool.getLiquidityPoolStorage();
        uint256 minPrice = bounds[0];
        uint256 maxPrice = bounds[1];
        isValid = mlpPrice >= minPrice && mlpPrice <= maxPrice;
    }

    // mlp => usd, calc mlp
    function estimateMaxIn(
        ConfigSet storage set,
        uint256 minAmountOut
    ) internal view returns (uint256 maxJuniorIn) {
        // estimated mlp = out * tokenPrice / mlpPrice / (1 - feeRate)
        // feeRate = dynamic + base
        IMuxLiquidityPool muxLiquidityPool = IMuxLiquidityPool(
            set.mustGetAddress(MUX_LIQUIDITY_POOL)
        );
        (uint32[8] memory u32s, uint96[2] memory bounds) = muxLiquidityPool
            .getLiquidityPoolStorage();
        uint256 maxFeeRate = u32s[4] + u32s[5];
        uint256 minPrice = bounds[0];
        maxJuniorIn = (((minAmountOut * ONE) / minPrice) * 1e5) / (1e5 - maxFeeRate);
    }

    function estimateAssetMaxValue(
        ConfigSet storage set,
        uint256 asset
    ) internal view returns (uint256 maxAssetValue) {
        IMuxLiquidityPool muxLiquidityPool = IMuxLiquidityPool(
            set.mustGetAddress(MUX_LIQUIDITY_POOL)
        );
        (, uint96[2] memory bounds) = muxLiquidityPool.getLiquidityPoolStorage();
        uint256 maxPrice = bounds[1];
        maxAssetValue = (asset * maxPrice) / ONE;
    }

    function estimateExactOut(
        ConfigSet storage set,
        uint8 seniorAssetId,
        uint256 juniorAmount,
        uint96 seniorPrice,
        uint96 juniorPrice,
        uint96 currentSeniorValue,
        uint96 targetSeniorValue
    ) internal view returns (uint256 outAmount) {
        IMuxLiquidityPool muxLiquidityPool = IMuxLiquidityPool(
            set.mustGetAddress(MUX_LIQUIDITY_POOL)
        );
        IMuxLiquidityPool.Asset memory seniorAsset = muxLiquidityPool.getAssetInfo(seniorAssetId);
        LiquidityPoolConfig memory config = getLiquidityPoolConfig(muxLiquidityPool);
        require(seniorAsset.isEnabled(), "AdapterImp::DISABLED_ASSET"); // the token is temporarily not ENAbled
        require(seniorAsset.canAddRemoveLiquidity(), "AdapterImp::FORBIDDEN_ASSET"); // the Token cannot be Used to add Liquidity
        seniorPrice = LibReferenceOracle.checkPriceWithSpread(
            seniorAsset,
            seniorPrice,
            config.strictStableDeviation,
            SpreadType.Ask
        );
        // token amount
        uint96 wadAmount = ((uint256(juniorAmount) * uint256(juniorPrice)) / uint256(seniorPrice))
            .toUint96();
        // fee
        uint32 mlpFeeRate = liquidityFeeRate(
            currentSeniorValue,
            targetSeniorValue,
            true,
            ((uint256(wadAmount) * seniorPrice) / 1e18).toUint96(),
            config.liquidityBaseFeeRate,
            config.liquidityDynamicFeeRate
        );
        wadAmount -= ((uint256(wadAmount) * mlpFeeRate) / 1e5).toUint96(); // -fee
        outAmount = seniorAsset.toRaw(wadAmount);
    }

    function estimateMlpExactOut(
        ConfigSet storage set,
        uint8 seniorAssetId,
        uint256 seniorAmount,
        uint96 seniorPrice,
        uint96 juniorPrice,
        uint96 currentSeniorValue,
        uint96 targetSeniorValue
    ) internal view returns (uint256 outAmount) {
        IMuxLiquidityPool muxLiquidityPool = IMuxLiquidityPool(
            set.mustGetAddress(MUX_LIQUIDITY_POOL)
        );
        IMuxLiquidityPool.Asset memory seniorAsset = muxLiquidityPool.getAssetInfo(seniorAssetId);
        LiquidityPoolConfig memory config = getLiquidityPoolConfig(muxLiquidityPool);
        require(seniorAsset.isEnabled(), "AdapterImp::DISABLED_ASSET"); // the token is temporarily not ENAbled
        require(seniorAsset.canAddRemoveLiquidity(), "AdapterImp::FORBIDDEN_ASSET"); // the Token cannot be Used to add Liquidity
        seniorPrice = LibReferenceOracle.checkPriceWithSpread(
            seniorAsset,
            seniorPrice,
            config.strictStableDeviation,
            SpreadType.Bid
        );
        // token amount
        uint96 wadAmount = seniorAsset.toWad(seniorAmount).toUint96();
        // fee
        uint32 mlpFeeRate = liquidityFeeRate(
            currentSeniorValue,
            targetSeniorValue,
            true,
            ((uint256(wadAmount) * seniorPrice) / 1e18).toUint96(),
            config.liquidityBaseFeeRate,
            config.liquidityDynamicFeeRate
        );
        wadAmount -= ((uint256(wadAmount) * mlpFeeRate) / 1e5).toUint96(); // -fee
        outAmount = ((uint256(wadAmount) * uint256(seniorPrice)) / uint256(juniorPrice)).toUint96();
    }

    function getLiquidityPoolConfig(
        IMuxLiquidityPool muxLiquidityPool
    ) internal view returns (LiquidityPoolConfig memory config) {
        (uint32[8] memory u32s, ) = muxLiquidityPool.getLiquidityPoolStorage();
        config.strictStableDeviation = u32s[7];
        config.liquidityBaseFeeRate = u32s[4];
        config.liquidityDynamicFeeRate = u32s[5];
    }

    function liquidityFeeRate(
        uint96 currentAssetValue,
        uint96 targetAssetValue,
        bool isAdd,
        uint96 deltaValue,
        uint32 baseFeeRate, // 1e5
        uint32 dynamicFeeRate // 1e5
    ) internal pure returns (uint32) {
        uint96 newAssetValue;
        if (isAdd) {
            newAssetValue = currentAssetValue + deltaValue;
        } else {
            require(currentAssetValue >= deltaValue, "AdapterImp::INSUFFICIENT_LIQUIDITY");
            newAssetValue = currentAssetValue - deltaValue;
        }
        // | x - target |
        uint96 oldDiff = currentAssetValue > targetAssetValue
            ? currentAssetValue - targetAssetValue
            : targetAssetValue - currentAssetValue;
        uint96 newDiff = newAssetValue > targetAssetValue
            ? newAssetValue - targetAssetValue
            : targetAssetValue - newAssetValue;
        if (targetAssetValue == 0) {
            // avoid division by 0
            return baseFeeRate;
        } else if (newDiff < oldDiff) {
            // improves
            uint32 rebate = ((uint256(dynamicFeeRate) * uint256(oldDiff)) /
                uint256(targetAssetValue)).toUint32();
            return baseFeeRate > rebate ? baseFeeRate - rebate : 0;
        } else {
            // worsen
            uint96 avgDiff = (oldDiff + newDiff) / 2;
            avgDiff = uint96(MathUpgradeable.min(avgDiff, targetAssetValue));
            uint32 dynamic = ((uint256(dynamicFeeRate) * uint256(avgDiff)) /
                uint256(targetAssetValue)).toUint32();
            return baseFeeRate + dynamic;
        }
    }
}
