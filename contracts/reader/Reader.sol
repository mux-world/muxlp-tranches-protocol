// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.17;

import "../interfaces/IJuniorVault.sol";
import "../interfaces/ISeniorVault.sol";
import "../interfaces/IRouterV1.sol";

struct TracheInfo {
    uint256 juniorTotalAssets;
    uint256 juniorTotalSupply;
    uint256 borrowedAssets;
    uint256 pendingBorrowAssets;
    uint256 pendingJuniorAssets;
    uint256 pendingJuniorShares;
    uint256 pendingJuniorDeposits;
    uint256[] pendingOrderIds;
}

contract TrancheReader {
    function getTrancheInfo(
        address routerAddress,
        address juniorAddress,
        address seniorAddress
    ) external view returns (TracheInfo memory info) {
        IRouterV1 router = IRouterV1(routerAddress);
        IJuniorVault junior = IJuniorVault(juniorAddress);
        ISeniorVault senior = ISeniorVault(seniorAddress);

        info.juniorTotalAssets = junior.totalAssets() + router.pendingJuniorAssets();
        info.juniorTotalSupply = junior.totalSupply() + router.pendingJuniorShares();
        info.borrowedAssets = senior.borrows(routerAddress);
        info.pendingBorrowAssets = router.pendingBorrowAssets();
        info.pendingJuniorAssets = router.pendingJuniorAssets();
        info.pendingJuniorShares = router.pendingJuniorShares();
        info.pendingJuniorDeposits = router.pendingJuniorDeposits();

        UserState memory keeperState = router.getUserStates(address(0));
        uint256 n = router.getPendingUsersCount();
        if (keeperState.orderId != 0) {
            n += 1;
        }
        if (n > 0) {
            info.pendingOrderIds = new uint256[](n);
            address[] memory pendingUsers = router.getPendingUsers(0, n);
            for (uint256 i = 0; i < n; i++) {
                UserState memory state = router.getUserStates(pendingUsers[i]);
                info.pendingOrderIds[i] = state.orderId;
            }
            if (keeperState.orderId != 0) {
                info.pendingOrderIds[n - 1] = keeperState.orderId;
            }
        }
    }
}
