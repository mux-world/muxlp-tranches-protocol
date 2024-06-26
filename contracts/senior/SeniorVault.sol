// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.17;

import "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

import "../libraries/LibConfigSet.sol";
import "./SeniorVaultStore.sol";
import "./SeniorVaultImp.sol";

contract SeniorVault is
    SeniorVaultStore,
    Initializable,
    AccessControlEnumerableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using LibConfigSet for ConfigSet;
    using SeniorVaultImp for SeniorStateStore;

    function initialize(
        string memory name_,
        string memory symbol_,
        address asset_
    ) external initializer {
        __AccessControlEnumerable_init();

        _store.initialize(asset_);
        _name = name_;
        _symbol = symbol_;
        _grantRole(DEFAULT_ADMIN, msg.sender);
    }

    function name() external view returns (string memory) {
        return _name;
    }

    function symbol() external view returns (string memory) {
        return _symbol;
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function assetDecimals() external view returns (uint8) {
        return _store.assetDecimals;
    }

    // =============================================== Configs ===============================================
    function getConfig(bytes32 configKey) external view returns (bytes32) {
        return _store.config.getBytes32(configKey);
    }

    function setConfig(bytes32 configKey, bytes32 value) external {
        require(
            hasRole(CONFIG_ROLE, msg.sender) || hasRole(DEFAULT_ADMIN, msg.sender),
            "SeniorVault::ONLY_AUTHRIZED_ROLE"
        );
        _store.config.setBytes32(configKey, value);
    }

    /**
     * Get the address of the underlying asset
     */
    function asset() external view returns (address) {
        return _store.asset;
    }

    function depositToken() public view returns (address) {
        return _store.asset;
    }

    function totalAssets() external view returns (uint256 assets) {
        assets = _store.totalAssets;
    }

    function totalSupply() external view returns (uint256 shares) {
        shares = _store.totalSupply;
    }

    /**
     * Return the max amount of assets that can be borrowed by the receiver.
     * The amount is determined by the values of config `MAX_BORROWS` and `keccak256(abi.encode(MAX_BORROWS, receiver))`.
     *
     * @param receiver The address of the receiver.
     */
    function borrowable(address receiver) external view returns (uint256 assets) {
        assets = _store.borrowable(receiver);
    }

    function balanceOf(address account) external view returns (uint256 shares) {
        shares = _store.balances[account];
    }

    function convertToShares(uint256 assets) external view returns (uint256 shares) {
        shares = _store.convertToShares(assets);
    }

    function convertToAssets(uint256 shares) external view returns (uint256 assets) {
        assets = _store.convertToAssets(shares);
    }

    function borrows(address account) external view returns (uint256 assets) {
        assets = _store.borrows[account];
    }

    function totalBorrows() external view returns (uint256 assets) {
        assets = _store.totalBorrows;
    }

    function timelock(address account) external view returns (uint256 unlockTimestamp) {
        unlockTimestamp = _store.timelocks[account];
    }

    function aaveTotalSupplied() external view returns (uint256) {
        return _store.aaveSuppliedBalance;
    }

    function aaveLastUpdateTime() external view returns (uint256) {
        return _store.aaveLastUpdateTime;
    }

    function claimableAaveRewards() external view returns (uint256 assets) {
        assets = _store.increasedBalance();
    }

    function claimableAaveExtraRewards() external view returns (address token, uint256 amount) {
        (token, amount) = _store.claimableAaveExtraRewards();
    }

    /**
     * Deposit assets to the vault.
     * @param assets The amount of assets to deposit.
     * @param receiver The address of the receiver.
     */
    function deposit(
        uint256 assets,
        address receiver
    ) external nonReentrant onlyRole(HANDLER_ROLE) returns (uint256 shares) {
        shares = _store.deposit(assets, receiver);
        _store.supplyAllBalanceToAave();
    }

    /**
     * Withdraw assets from the vault.
     * Depends on the type of timelock, withdrawer may suffer a penalty.
     *
     * @param caller can be owner or someone has been approved by the owner
     * @param owner the owner of the shares
     * @param shares the amount of shares to be withdrawn, in shares decimals (18)
     * @param receiver the receiver of the assets
     */
    function withdraw(
        address caller,
        address owner,
        uint256 shares,
        address receiver
    ) external nonReentrant onlyRole(HANDLER_ROLE) returns (uint256 assets, uint256 penalty) {
        assets = _store.convertToAssets(shares);
        _ensureAssets(assets);
        (assets, penalty) = _store.withdraw(caller, owner, shares, receiver);
    }

    /**
     * @dev Transfers a specified amount of shares from one address to another.
     * Can only be called by an address with the HANDLER_ROLE.
     *
     * @param from The address to transfer shares from.
     * @param to The address to transfer shares to.
     * @param shares The amount of shares to transfer.
     */
    function transferFrom(
        address from,
        address to,
        uint256 shares
    ) external onlyRole(HANDLER_ROLE) {
        require(block.timestamp > _store.timelocks[from], "SeniorVault::FROM_LOCKED");
        require(block.timestamp > _store.timelocks[to], "SeniorVault::TO_LOCKED");
        _store.update(from, to, shares);
        _store.timelocks[to] = _store.timelocks[from];
    }

    /**
     * Borrow assets from the vault.
     * @param assets The amount of assets to borrow.
     */
    function borrow(uint256 assets) external onlyRole(HANDLER_ROLE) {
        _ensureAssets(assets);
        _store.borrow(assets, msg.sender);
    }

    /**
     * Repay assets to the vault.
     * @param assets The amount of assets to repay.
     */
    function repay(uint256 assets) external onlyRole(HANDLER_ROLE) {
        _store.repay(msg.sender, assets);
        _store.supplyAllBalanceToAave();
    }

    function claimAaveRewards(address receiver) external onlyRole(HANDLER_ROLE) returns (uint256) {
        return _store.claimAaveRewards(receiver);
    }

    function claimAaveExtraRewards(
        address receiver
    ) external onlyRole(HANDLER_ROLE) returns (address token, uint256 amount) {
        return _store.claimAaveExtraRewards(receiver);
    }

    function _ensureAssets(uint256 assets) internal {
        uint256 remains = IERC20Upgradeable(_store.asset).balanceOf(address(this));
        if (remains < assets) {
            uint256 withdrawal = assets - remains;
            _store.withdrawSuppliedFromAave(withdrawal);
        }
        require(
            IERC20Upgradeable(_store.asset).balanceOf(address(this)) >= assets,
            "SeniorVault::BORROW_NOT_ENOUGH"
        );
    }
}
