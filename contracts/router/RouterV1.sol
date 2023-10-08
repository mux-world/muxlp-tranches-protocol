// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.17;

import "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/structs/EnumerableSetUpgradeable.sol";

import "../interfaces/mux/IMuxLiquidityCallback.sol";
import "../libraries/LibConfigSet.sol";
import "./RouterStore.sol";
import "./RouterImp.sol";

contract RouterV1 is
    RouterStore,
    Initializable,
    AccessControlEnumerableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using RouterImp for RouterStateStore;
    using LibConfigSet for ConfigSet;
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.UintSet;

    modifier checkStatus() {
        require(_store.users[msg.sender].status == UserStatus.Idle, "RouterV1::INPROPER_STATUS");
        require(_store.users[address(0)].status == UserStatus.Idle, "RouterV1::INPROPER_STATUS");
        require(_store.pendingRefundAssets == 0, "RouterV1::HAS_REFUND_ASSETS");
        require(!_store.isLiquidated, "RouterV1::LIQUIDATING");
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

    function getUserOrderTime(address account) external view returns (uint32 placeOrderTime) {
        uint64 orderId = _store.users[account].orderId;
        if (_store.users[account].orderId != 0) {
            placeOrderTime = _store.getUserOrderTime(orderId);
        } else {
            placeOrderTime = 0;
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

    function pendingSeniorAssets() external view returns (uint256) {
        return _store.pendingSeniorAssets;
    }

    function pendingRefundAssets() external view returns (uint256) {
        return _store.pendingRefundAssets;
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
        _store.updateRewards();
        return _store.rewardController.claimableJuniorRewards(account);
    }

    function claimableSeniorRewards(address account) external returns (uint256) {
        _store.updateRewards();
        return _store.rewardController.claimableSeniorRewards(account);
    }

    // =============================================== Actions ===============================================

    // Idle => DepositJunior => Idle
    function depositJunior(uint256 assets) external checkStatus nonReentrant {
        _store.depositJunior(msg.sender, assets);
    }

    // Idle => WithdrawJunior => Idle
    function withdrawJunior(uint256 shares) external checkStatus nonReentrant {
        _store.withdrawJunior(msg.sender, shares);
    }

    function depositSenior(uint256 amount) external checkStatus nonReentrant {
        _store.depositSenior(msg.sender, amount);
    }

    // Idle => WithdrawSenior => RefundJunior => Idle
    function withdrawSenior(uint256 amount, bool acceptPenalty) external checkStatus nonReentrant {
        _store.withdrawSenior(msg.sender, amount, acceptPenalty);
    }

    // Idle => BuyJunior / SellJunior => Idle
    function rebalance(
        uint256 seniorPrice,
        uint256 juniorPrice
    ) external checkStatus onlyRole(KEEPER_ROLE) {
        _store.rebalance(seniorPrice, juniorPrice);
    }

    // Idle => SellJunior => Idle
    function liquidate(uint256 seniorPrice, uint256 juniorPrice) external onlyRole(KEEPER_ROLE) {
        require(!_store.isLiquidated, "RouterV1::LIQUIDATED");
        _store.liquidate(seniorPrice, juniorPrice);
    }

    // Idle => BuyJunior => Idle
    function refundJunior() external nonReentrant {
        require(_store.pendingRefundAssets != 0, "RouterV1::NO_REFUND_ASSETS");
        require(_store.users[address(0)].status == UserStatus.Idle, "RouterV1::INPROPER_STATUS");
        _store.refundJunior();
    }

    function updateRewards() external nonReentrant {
        _store.updateRewards();
    }

    function cancelPendingOperation() external {
        _store.cancelPendingOperation(msg.sender);
    }

    function claimJuniorRewards() external returns (uint256) {
        _store.updateRewards();
        return _store.rewardController.claimJuniorRewardsFor(msg.sender, msg.sender);
    }

    function claimSeniorRewards() external nonReentrant returns (uint256) {
        _store.updateRewards();
        return _store.rewardController.claimSeniorRewardsFor(msg.sender, msg.sender);
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
