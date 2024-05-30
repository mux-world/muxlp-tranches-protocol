// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.17;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

import "../interfaces/mux/IMuxLiquidityPool.sol";
import "../interfaces/mux/IMuxLiquidityCallback.sol";
import "./libraries/LibMath.sol";

contract MockMuxOrderBook {
    using LibMath for uint256;

    address public mlp;
    address public pool;

    uint64 public nextOrderId;
    mapping(uint64 => IMuxLiquidityCallback.LiquidityOrder) orders;
    uint32 blockTime;
    mapping(address => bool) callbackWhitelist;

    constructor(address mlp_, address pool_) {
        mlp = mlp_;
        pool = pool_;
        nextOrderId = 1;
    }

    function liquidityLockPeriod() public pure returns (uint32) {
        return 15 * 60;
    }

    function _callbackGasLimit() internal view returns (uint256) {
        return gasleft();
    }

    function setBlockTime(uint32 t) external {
        blockTime = t;
    }

    function _blockTimestamp() internal view returns (uint32) {
        return blockTime;
    }

    function _getLiquidityFeeRate() internal pure returns (uint32) {
        return 70; // 0.07%
    }

    function setCallbackWhitelist(address caller, bool enable) external {
        callbackWhitelist[caller] = enable;
    }

    function placeLiquidityOrder(
        uint8 assetId,
        uint96 rawAmount, // erc20.decimals
        bool isAdding
    ) external payable {
        if (isAdding) {
            address token = IMuxLiquidityPool(pool).getAssetInfo(assetId).tokenAddress;
            require(token != address(0), "assetId not found");
            IERC20Upgradeable(token).transferFrom(msg.sender, address(this), rawAmount);
        } else {
            IERC20Upgradeable(mlp).transferFrom(msg.sender, address(this), rawAmount);
        }
        orders[nextOrderId] = IMuxLiquidityCallback.LiquidityOrder(
            nextOrderId,
            msg.sender,
            rawAmount,
            assetId,
            isAdding,
            _blockTimestamp()
        );
        nextOrderId += 1;
    }

    function fillLiquidityOrder(
        uint64 orderId,
        uint96 assetPrice,
        uint96 mlpPrice,
        uint96 currentAssetValue,
        uint96 targetAssetValue
    ) external {
        IMuxLiquidityCallback.LiquidityOrder memory order = orders[orderId];
        delete orders[orderId];
        require(order.account != address(0), "order not found");
        // callback
        if (callbackWhitelist[order.account]) {
            bool isValid;
            try
                IMuxLiquidityCallback(order.account).beforeFillLiquidityOrder{
                    gas: _callbackGasLimit()
                }(order, assetPrice, mlpPrice, currentAssetValue, targetAssetValue)
            returns (bool _isValid) {
                isValid = _isValid;
            } catch {
                isValid = false;
            }
            if (!isValid) {
                _cancelLiquidityOrder(order);
                return;
            }
        }
        uint256 outAmount;
        // LibOrderBook: fillLiquidityOrder
        require(_blockTimestamp() >= order.placeOrderTime + liquidityLockPeriod(), "LCK"); // mlp token is LoCKed
        if (order.isAdding) {
            // usdc => mlp
            uint32 mlpFeeRate = _getLiquidityFeeRate();
            uint96 wadAmount = (uint256(order.rawAmount) * 1e12).safeUint96();
            uint96 feeCollateral = uint256(wadAmount).rmul(mlpFeeRate).safeUint96();
            wadAmount -= feeCollateral;
            outAmount = ((uint256(wadAmount) * uint256(assetPrice)) / uint256(mlpPrice))
                .safeUint96();
            IERC20Upgradeable(mlp).transfer(order.account, outAmount);
        } else {
            // mlp => usdc
            uint96 mlpAmount = order.rawAmount;
            uint96 wadAmount = ((uint256(mlpAmount) * uint256(mlpPrice)) / uint256(assetPrice))
                .safeUint96();
            uint32 mlpFeeRate = _getLiquidityFeeRate();
            uint96 feeCollateral = uint256(wadAmount).rmul(mlpFeeRate).safeUint96();
            wadAmount -= feeCollateral;
            outAmount = uint256(wadAmount) / 1e12;
            address token = IMuxLiquidityPool(pool).getAssetInfo(order.assetId).tokenAddress;
            require(token != address(0), "assetId not found");
            IERC20Upgradeable(token).transfer(order.account, outAmount);
        }

        if (callbackWhitelist[order.account]) {
            IMuxLiquidityCallback(order.account).afterFillLiquidityOrder{gas: _callbackGasLimit()}(
                order,
                outAmount,
                assetPrice,
                mlpPrice,
                currentAssetValue,
                targetAssetValue
            );
        }
    }

    function cancelOrder(uint64 orderId) external {
        IMuxLiquidityCallback.LiquidityOrder memory order = orders[orderId];
        delete orders[orderId];
        require(order.account != address(0), "order not found");
        _cancelLiquidityOrder(order);
    }

    function _cancelLiquidityOrder(IMuxLiquidityCallback.LiquidityOrder memory order) internal {
        if (order.isAdding) {
            address token = IMuxLiquidityPool(pool).getAssetInfo(order.assetId).tokenAddress;
            require(token != address(0), "assetId not found");
            require(
                IERC20Upgradeable(token).balanceOf(address(this)) >= order.rawAmount,
                "insufficient balance when cancel"
            );
            IERC20Upgradeable(token).transfer(order.account, order.rawAmount);
        } else {
            require(
                IERC20Upgradeable(mlp).balanceOf(address(this)) >= order.rawAmount,
                "insufficient balance when cancel"
            );
            IERC20Upgradeable(mlp).transfer(order.account, order.rawAmount);
        }
        if (callbackWhitelist[order.account]) {
            IMuxLiquidityCallback(order.account).afterCancelLiquidityOrder{
                gas: _callbackGasLimit()
            }(order);
        }
    }
}
