// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.17;

import "../router/Type.sol";

interface IRouterV1 {
    // =============================================== Configs ===============================================

    function getConfig(bytes32 configKey) external view returns (bytes32);

    // =============================================== Views ===============================================

    function getUserStates(address account) external view returns (UserState memory userState);

    function getPendingUsersCount() external view returns (uint256);

    function getUserOrderTime(address account) external view returns (uint32 placeOrderTime);

    function getLastPendingUserOrderTime() external view returns (uint32 placeOrderTime);

    function getPendingUsers(uint256 begin, uint256 count) external view returns (address[] memory);

    function juniorLeverage(
        uint256 seniorPrice,
        uint256 juniorPrice
    ) external view returns (uint256 leverage);

    function pendingJuniorShares() external view returns (uint256);

    function pendingJuniorAssets() external view returns (uint256);

    function pendingSeniorShares() external view returns (uint256);

    function pendingBorrowAssets() external view returns (uint256);

    function pendingSeniorAssets() external view returns (uint256);

    function pendingRefundAssets() external view returns (uint256);

    function pendingJuniorDeposits() external view returns (uint256);

    function juniorNavPerShare(
        uint256 seniorPrice,
        uint256 juniorPrice
    ) external view returns (uint256);

    function isJuniorBalanced(
        uint256 seniorPrice,
        uint256 juniorPrice
    ) external view returns (bool isBalanced, bool isRebalancing);

    function claimableJuniorRewards(address account) external returns (uint256);

    function claimableSeniorRewards(address account) external returns (uint256);

    // =============================================== Actions ===============================================

    // Idle => DepositJunior => Idle
    function depositJunior(uint256 assets) external;

    // Idle => WithdrawJunior => Idle
    function withdrawJunior(uint256 shares) external;

    function depositSenior(uint256 amount) external;

    // Idle => WithdrawSenior => RefundJunior => Idle
    function withdrawSenior(uint256 amount, bool acceptPenalty) external;

    // Idle => BuyJunior / SellJunior => Idle
    function rebalance(uint256 seniorPrice, uint256 juniorPrice) external;

    // Idle => SellJunior => Idle
    function liquidate(uint256 seniorPrice, uint256 juniorPrice) external;

    // Idle => BuyJunior => Idle
    function refundJunior() external;

    function updateRewards() external;

    function cancelPendingOperation() external;

    function claimJuniorRewards() external returns (uint256);

    function claimSeniorRewards() external returns (uint256);

    function isLiquidated() external view returns (bool);
}
