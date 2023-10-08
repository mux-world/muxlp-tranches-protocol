// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.17;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import "../interfaces/mux/IMuxRewardRouter.sol";
import "./Type.sol";
import "./RouterUtilImp.sol";

library RouterRewardImp {
    using RouterUtilImp for RouterStateStore;
    using LibConfigSet for ConfigSet;
    using SafeERC20Upgradeable for IERC20Upgradeable;

    event UpdateRewards(address[] rewardTokens, uint256[] rewardAmounts, uint256 utilized);

    function updateRewards(RouterStateStore storage store, address account) internal {
        //  function updateRewards(RouterStateStore storage states) internal {
        IMuxRewardRouter muxRewardRouter = IMuxRewardRouter(
            store.config.mustGetAddress(MUX_REWARD_ROUTER)
        );
        store.juniorVault.collectMuxRewards(address(this));
        address[] memory rewardTokens = new address[](2);
        rewardTokens[0] = muxRewardRouter.weth();
        rewardTokens[1] = muxRewardRouter.mcb();
        uint256[] memory rewardAmounts = new uint256[](rewardTokens.length);
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            rewardAmounts[i] = IERC20Upgradeable(rewardTokens[i]).balanceOf(address(this));
            IERC20Upgradeable(rewardTokens[i]).safeTransfer(
                address(store.rewardController),
                rewardAmounts[i]
            );
        }
        uint256 utilized = store.seniorVault.borrows(address(this));
        store.rewardController.notifyRewards(rewardTokens, rewardAmounts, utilized);
        store.rewardController.updateRewards(account);

        emit UpdateRewards(rewardTokens, rewardAmounts, utilized);
    }
}
