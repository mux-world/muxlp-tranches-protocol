// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.17;

import "./Type.sol";

library RouterUtilImp {
    function toJuniorUnit(
        RouterStateStore storage store,
        uint256 seniorUnitAmount
    ) internal view returns (uint256 juniorUnitAmount) {
        juniorUnitAmount =
            seniorUnitAmount *
            (10 ** (store.juniorVault.assetDecimals() - store.seniorVault.assetDecimals()));
    }

    function toSeniorUnit(
        RouterStateStore storage store,
        uint256 juniorUnitAmount
    ) internal view returns (uint256 seniorUnitAmount) {
        seniorUnitAmount =
            juniorUnitAmount /
            (10 ** (store.juniorVault.assetDecimals() - store.seniorVault.assetDecimals()));
    }
}
