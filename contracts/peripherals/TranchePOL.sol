// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.17;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "../interfaces/IRouterV1.sol";

/**
 * @notice TranchePOL saves Protocol-Owned-Liquidity.
 */
contract TranchePOL is Initializable, OwnableUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using LibTypeCast for bytes32;

    event TransferETH(address indexed to, uint256 amount);
    event TransferERC20Token(address indexed token, address indexed to, uint256 amount);
    event SetMaintainer(address newMaintainer, bool enable);
    event ClaimSeniorReward(address tokenAddress, uint256 rawAmount);

    IRouterV1 public trancheRouter;
    mapping(address => bool) public maintainers;
    IERC20Upgradeable public seniorAssetToken;

    function initialize(
        IRouterV1 trancheRouter_,
        IERC20Upgradeable seniorAssetToken_
    ) external initializer {
        __Ownable_init();
        trancheRouter = trancheRouter_;
        seniorAssetToken = seniorAssetToken_;
    }

    function setMaintainer(address newMaintainer, bool enable) external onlyOwner {
        maintainers[newMaintainer] = enable;
        emit SetMaintainer(newMaintainer, enable);
    }

    /**
     * @notice  A helper method to transfer Ether to somewhere.
     *
     * @param   recipient   The receiver of the sent asset.
     * @param   value       The amount of asset to send.
     */
    function transferETH(address recipient, uint256 value) external onlyOwner {
        require(recipient != address(0), "recipient is zero address");
        require(value != 0, "transfer value is zero");
        AddressUpgradeable.sendValue(payable(recipient), value);
        emit TransferETH(recipient, value);
    }

    /**
     * @notice  A helper method to transfer ERC20 to somewhere.
     *
     * @param   recipient   The receiver of the sent asset.
     * @param   tokens      The address of to be sent ERC20 token.
     * @param   amounts     The amount of asset to send.
     */
    function transferERC20(
        address recipient,
        address[] memory tokens,
        uint256[] memory amounts
    ) external onlyOwner {
        require(recipient != address(0), "recipient is zero address");
        require(tokens.length == amounts.length, "length mismatch");
        for (uint256 i = 0; i < tokens.length; i++) {
            IERC20Upgradeable(tokens[i]).safeTransfer(recipient, amounts[i]);
            emit TransferERC20Token(tokens[i], recipient, amounts[i]);
        }
    }

    /**
     * @notice  A helper method to transfer ERC20 to somewhere.
     *
     * @param   recipient   The receiver of the sent asset.
     * @param   tokens      The address of to be sent ERC20 token.
     */
    function transferAllERC20(address recipient, address[] memory tokens) external onlyOwner {
        require(recipient != address(0), "recipient is zero address");
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 amount = IERC20Upgradeable(tokens[i]).balanceOf(address(this));
            IERC20Upgradeable(tokens[i]).safeTransfer(recipient, amount);
            emit TransferERC20Token(tokens[i], recipient, amount);
        }
    }

    function depositSenior(uint256 amount) external onlyOwner {
        seniorAssetToken.approve(address(trancheRouter), amount);
        trancheRouter.depositSenior(amount);
    }

    function withdrawSenior(uint256 amount, bool acceptPenalty) external onlyOwner {
        trancheRouter.withdrawSenior(amount, acceptPenalty);
    }

    function cancelPendingOperation() external {
        require(msg.sender == owner() || maintainers[msg.sender], "must be maintainer or owner");
        trancheRouter.cancelPendingOperation();
    }

    function claimSeniorRewards() external {
        require(msg.sender == owner() || maintainers[msg.sender], "must be maintainer or owner");
        uint256 amount1 = seniorAssetToken.balanceOf(address(this));
        trancheRouter.claimSeniorRewards();
        uint256 amount2 = seniorAssetToken.balanceOf(address(this));
        if (amount2 > amount1) {
            uint256 amount = amount2 - amount1;
            SafeERC20Upgradeable.safeTransfer(seniorAssetToken, msg.sender, amount);
            emit ClaimSeniorReward(address(seniorAssetToken), amount);
        }
    }

    bytes32[50] private __gap;
}
