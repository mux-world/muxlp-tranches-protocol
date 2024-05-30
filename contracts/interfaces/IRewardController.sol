// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.17;

interface IRewardController {
    function rewardToken() external view returns (address);

    function seniorRewardDistributor() external view returns (address);

    function juniorRewardDistributor() external view returns (address);

    function claimableJuniorRewards(address account) external returns (uint256);

    function claimableSeniorRewards(address account) external returns (uint256);

    function claimSeniorRewardsFor(address account, address receiver) external returns (uint256);

    function claimJuniorRewardsFor(address account, address receiver) external returns (uint256);

    function updateRewards(address account) external;

    function notifyRewards(
        address[] memory rewardTokens,
        uint256[] memory rewardAmounts,
        uint256 utilizedAmount
    ) external;

    function migrateSeniorRewardFor(address from, address to) external;

    function migrateJuniorRewardFor(address from, address to) external;

    function notifySeniorExtraReward(address token, uint256 amount) external;

    function notifyJuniorExtraReward(address token, uint256 amount) external;
}
