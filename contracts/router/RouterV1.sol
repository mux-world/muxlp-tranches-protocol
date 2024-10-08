// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.17;

import "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/structs/EnumerableSetUpgradeable.sol";

import "../interfaces/mux/IMuxLiquidityCallback.sol";
import "../interfaces/IRouterV1.sol";
import "../libraries/LibConfigSet.sol";
import "./RouterStore.sol";
import "./RouterImp.sol";

contract RouterV1 is
    RouterStore,
    Initializable,
    AccessControlEnumerableUpgradeable,
    ReentrancyGuardUpgradeable,
    IRouterV1
{
    using RouterImp for RouterStateStore;
    using LibConfigSet for ConfigSet;
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.AddressSet;

    modifier notPending() {
        require(_store.users[msg.sender].status == UserStatus.Idle, "RouterV1::INPROPER_STATUS");
        require(_store.users[address(0)].status == UserStatus.Idle, "RouterV1::INPROPER_STATUS");
        require(_store.pendingRefundAssets == 0, "RouterV1::HAS_REFUND_ASSETS");
        require(_store.pendingUsers.length() == 0, "RouterV1::PENDING_USERS");
        _;
    }

    modifier notLiquidated() {
        require(!_store.isLiquidated, "RouterV1::LIQUIDATED");
        _;
    }

    function initialize(
        address seniorVault,
        address juniorVault,
        address rewardController
    ) external initializer {
        __AccessControlEnumerable_init();
        _store.initialize(seniorVault, juniorVault, rewardController);
        _grantRole(DEFAULT_ADMIN, msg.sender);
    }

    // =============================================== Whitelist ===============================================

    modifier onlyWhitelisted() {
        require(_store.whitelist[msg.sender], "JuniorVault::ONLY_WHITELISTED");
        _;
    }

    function setWhitelist(address account, bool enable) external {
        require(
            hasRole(CONFIG_ROLE, msg.sender) || hasRole(DEFAULT_ADMIN, msg.sender),
            "JuniorVault::ONLY_AUTHRIZED_ROLE"
        );
        _store.whitelist[account] = enable;
    }

    // =============================================== Configs ===============================================
    function getConfig(bytes32 configKey) external view returns (bytes32) {
        return _store.config.getBytes32(configKey);
    }

    function setConfig(bytes32 configKey, bytes32 value) external {
        require(
            hasRole(CONFIG_ROLE, msg.sender) || hasRole(DEFAULT_ADMIN, msg.sender),
            "JuniorVault::ONLY_AUTHRIZED_ROLE"
        );
        _store.config.setBytes32(configKey, value);
    }

    // =============================================== Views ===============================================
    function getUserStates(address account) external view returns (UserState memory userState) {
        return _store.users[account];
    }

    function getPendingUsersCount() external view returns (uint256) {
        return _store.pendingUsers.length();
    }

    function getUserOrderTime(address account) external view returns (uint32 placeOrderTime) {
        uint64 orderId = _store.users[account].orderId;
        if (_store.users[account].orderId != 0) {
            placeOrderTime = _store.getUserOrderTime(orderId);
        } else {
            placeOrderTime = 0;
        }
    }

    function getLastPendingUserOrderTime() external view returns (uint32 placeOrderTime) {
        uint256 count = _store.pendingUsers.length();
        if (count == 0) {
            placeOrderTime = 0;
        } else {
            address account = _store.pendingUsers.at(count - 1);
            uint64 orderId = _store.users[account].orderId;
            if (_store.users[account].orderId != 0) {
                placeOrderTime = _store.getUserOrderTime(orderId);
            } else {
                placeOrderTime = 0;
            }
        }
    }

    function getPendingUsers(
        uint256 begin,
        uint256 count
    ) external view returns (address[] memory) {
        return _store.getPendingUsers(begin, count);
    }

    function juniorLeverage(
        uint256 seniorPrice,
        uint256 juniorPrice
    ) external view returns (uint256 leverage) {
        leverage = _store.juniorLeverage(seniorPrice, juniorPrice);
    }

    function pendingJuniorShares() external view returns (uint256) {
        return _store.pendingJuniorShares;
    }

    function pendingJuniorAssets() external view returns (uint256) {
        return _store.pendingJuniorAssets;
    }

    function pendingSeniorShares() external view returns (uint256) {
        return _store.pendingSeniorShares;
    }

    function pendingBorrowAssets() external view returns (uint256) {
        return _store.pendingBorrowAssets;
    }

    function pendingSeniorAssets() external view returns (uint256) {
        return _store.pendingSeniorAssets;
    }

    function pendingRefundAssets() external view returns (uint256) {
        return _store.pendingRefundAssets;
    }

    function pendingJuniorDeposits() external view returns (uint256) {
        return _store.pendingJuniorDeposits;
    }

    function juniorNavPerShare(
        uint256 seniorPrice,
        uint256 juniorPrice
    ) external view returns (uint256) {
        return _store.juniorNavPerShare(seniorPrice, juniorPrice);
    }

    function isJuniorBalanced(
        uint256 seniorPrice,
        uint256 juniorPrice
    ) external view returns (bool isBalanced, bool isRebalancing) {
        (isBalanced, , ) = _store.isJuniorBalanced(seniorPrice, juniorPrice);
        isRebalancing = _store.isRebalancing();
    }

    function claimableJuniorRewards(address account) external returns (uint256) {
        _store.updateRewards(account);
        return _store.rewardController.claimableJuniorRewards(account);
    }

    function claimableSeniorRewards(address account) external returns (uint256) {
        _store.updateRewards(account);
        return _store.rewardController.claimableSeniorRewards(account);
    }

    function isLiquidated() external view returns (bool) {
        return _store.isLiquidated;
    }

    // =============================================== Actions ===============================================

    // Idle => DepositJunior => Idle
    function depositJunior(
        uint256 assets
    ) external notPending notLiquidated nonReentrant onlyWhitelisted {
        _store.updateRewards(msg.sender);
        _store.depositJunior(msg.sender, assets);
    }

    // Idle => WithdrawJunior => Idle
    function withdrawJunior(
        uint256 shares
    ) external notPending notLiquidated nonReentrant onlyWhitelisted {
        _store.updateRewards(msg.sender);
        _store.withdrawJunior(msg.sender, shares);
    }

    function depositSenior(uint256 amount) external notLiquidated nonReentrant onlyWhitelisted {
        _store.updateRewards(msg.sender);
        _store.depositSenior(msg.sender, amount);
    }

    // Idle => WithdrawSenior => RefundJunior => Idle
    function withdrawSenior(
        uint256 amount,
        bool acceptPenalty
    ) external notPending notLiquidated nonReentrant onlyWhitelisted {
        _store.updateRewards(msg.sender);
        _store.withdrawSenior(msg.sender, amount, acceptPenalty);
    }

    // Idle => BuyJunior / SellJunior => Idle
    function rebalance(
        uint256 seniorPrice,
        uint256 juniorPrice
    ) external notPending notLiquidated onlyRole(KEEPER_ROLE) {
        _store.updateRewards();
        _store.rebalance(seniorPrice, juniorPrice);
    }

    // Idle => SellJunior => Idle
    function liquidate(uint256 seniorPrice, uint256 juniorPrice) external onlyRole(KEEPER_ROLE) {
        require(!_store.isLiquidated, "RouterV1::LIQUIDATED");
        _store.updateRewards();
        _store.liquidate(seniorPrice, juniorPrice);
    }

    // Idle => BuyJunior => Idle
    function refundJunior() external nonReentrant onlyRole(KEEPER_ROLE) {
        require(_store.pendingRefundAssets != 0, "RouterV1::NO_REFUND_ASSETS");
        require(_store.users[address(0)].status == UserStatus.Idle, "RouterV1::INPROPER_STATUS");
        _store.updateRewards();
        _store.refundJunior();
    }

    function updateRewards() external nonReentrant {
        _store.updateRewards();
    }

    function cancelPendingOperation() external notLiquidated {
        _store.updateRewards(msg.sender);
        _store.cancelPendingOperation(msg.sender);
    }

    function cancelRebalancePendingOperation() external notLiquidated onlyRole(KEEPER_ROLE) {
        _store.updateRewards(address(0));
        _store.cancelPendingOperation(address(0));
    }

    function claimJuniorRewards() external returns (uint256) {
        _store.updateRewards(msg.sender);
        return _store.rewardController.claimJuniorRewardsFor(msg.sender, msg.sender);
    }

    function claimSeniorRewards() external nonReentrant returns (uint256) {
        _store.updateRewards(msg.sender);
        return _store.rewardController.claimSeniorRewardsFor(msg.sender, msg.sender);
    }

    function migrateJunior(address to) external nonReentrant notPending notLiquidated {
        require(_store.juniorVault.balanceOf(to) == 0, "RouterV1::RECEIVER_NOT_EMPTY");
        uint256 balance = _store.juniorVault.balanceOf(msg.sender);
        require(balance != 0, "RouterV1::NO_ASSETS");
        _store.updateRewards(msg.sender);
        _store.rewardController.migrateJuniorRewardFor(msg.sender, to);
        _store.juniorVault.transferFrom(msg.sender, to, balance);
    }

    function migrateSenior(address to) external nonReentrant notPending notLiquidated {
        require(_store.seniorVault.balanceOf(to) == 0, "RouterV1::RECEIVER_NOT_EMPTY");
        uint256 balance = _store.seniorVault.balanceOf(msg.sender);
        require(balance != 0, "RouterV1::NO_ASSETS");
        _store.updateRewards(msg.sender);
        _store.rewardController.migrateSeniorRewardFor(msg.sender, to);
        _store.seniorVault.transferFrom(msg.sender, to, balance);
    }

    function notifyArbRewards(uint256 amount) external nonReentrant {
        uint256 utilized = _store.seniorVault.borrows(address(this));

        address arbToken = address(0x912CE59144191C1204E64559FE8253a0e49E6548);
        uint256 arbBalance = IERC20Upgradeable(arbToken).balanceOf(address(this));
        require(arbBalance >= amount, "Insufficient balance");

        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        tokens[0] = arbToken; // arb
        amounts[0] = amount;

        IERC20Upgradeable(arbToken).safeTransfer(address(_store.rewardController), amount);
        _store.rewardController.notifyRewards(tokens, amounts, utilized);
    }

    // ============================================= Callbacks =============================================
    function beforeFillLiquidityOrder(
        IMuxLiquidityCallback.LiquidityOrder calldata,
        uint96,
        uint96,
        uint96,
        uint96
    ) external nonReentrant returns (bool isValid) {
        isValid = true;
    }

    function afterFillLiquidityOrder(
        IMuxLiquidityCallback.LiquidityOrder calldata order,
        uint256 amountOut,
        uint96 seniorPrice,
        uint96 juniorPrice,
        uint96 currentSeniorValue,
        uint96 targetSeniorValue
    ) external nonReentrant {
        address orderBook = _store.config.mustGetAddress(MUX_ORDER_BOOK);
        require(
            msg.sender == orderBook || hasRole(KEEPER_ROLE, msg.sender),
            "RouterV1::ONLY_ORDERBOOK_OR_KEEPER"
        );
        MuxOrderContext memory context = MuxOrderContext({
            orderId: order.id,
            seniorAssetId: order.assetId,
            seniorPrice: seniorPrice,
            juniorPrice: juniorPrice,
            currentSeniorValue: currentSeniorValue,
            targetSeniorValue: targetSeniorValue
        });
        _store.onOrderFilled(context, amountOut);
    }

    function afterCancelLiquidityOrder(
        IMuxLiquidityCallback.LiquidityOrder calldata order
    ) external nonReentrant {
        address orderBook = _store.config.mustGetAddress(MUX_ORDER_BOOK);
        require(
            msg.sender == orderBook || hasRole(KEEPER_ROLE, msg.sender),
            "RouterV1::ONLY_ORDERBOOK_OR_KEEPER"
        );
        _store.onOrderCancelled(order.id);
    }
}
