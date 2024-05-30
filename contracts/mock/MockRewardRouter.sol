// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.17;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "./MockVester.sol";

contract MockRewardRouter {
    address public mlp;
    address public mcb;
    address public mux;
    address public weth;
    address public smlp;
    uint256 public wethPerMlpPerSecond; // 1e18
    uint256 public mcbPerMlpPerSecond; // 1e18
    uint32 private blockTime;
    MockVester public mlpVester;
    MockVester public muxVester;
    mapping(address => Unclaimed) private unclaimed;

    struct Unclaimed {
        uint32 lastTime;
        uint256 weth;
        uint256 mcb;
    }

    constructor(
        address mlp_,
        address mcb_,
        address mux_,
        address weth_,
        address smlp_,
        MockVester mlpVester_,
        MockVester muxVester_
    ) {
        mlp = mlp_;
        mcb = mcb_;
        mux = mux_;
        weth = weth_;
        smlp = smlp_;
        mlpVester = mlpVester_;
        muxVester = muxVester_;
    }

    function setBlockTime(uint32 blockTime_) external {
        blockTime = blockTime_;
    }

    function setRewardRate(uint256 wethPerMlpPerSecond_, uint256 mcbPerMlpPerSecond_) external {
        wethPerMlpPerSecond = wethPerMlpPerSecond_;
        mcbPerMlpPerSecond = mcbPerMlpPerSecond_;
    }

    function mlpMuxTracker() external view returns (address) {
        return smlp;
    }

    function mlpFeeTracker() external view returns (address) {
        // fmlp is not very important in this test. the user should approve mlp to fmlp. so we return this MockRewardRouter
        return address(this);
    }

    function claimableRewards(
        address account
    )
        external
        returns (
            uint256 mlpFeeAmount,
            uint256 mlpMuxAmount,
            uint256 veFeeAmount,
            uint256 veMuxAmount,
            uint256 mcbAmount
        )
    {
        _payInterest(msg.sender);
        Unclaimed storage u = unclaimed[account];
        mlpFeeAmount = u.weth;
        mlpMuxAmount = 0;
        veFeeAmount = 0;
        veMuxAmount = 0;
        mcbAmount = u.mcb;
    }

    function claimAll() external {
        _payInterest(msg.sender);
        Unclaimed storage u = unclaimed[msg.sender];
        IERC20Upgradeable(weth).transfer(msg.sender, u.weth);
        IERC20Upgradeable(mcb).transfer(msg.sender, u.mcb);
        u.weth = 0;
        u.mcb = 0;
    }

    function stakeMlp(uint256 amount_) external returns (uint256) {
        _payInterest(msg.sender);
        IERC20Upgradeable(mlp).transferFrom(msg.sender, address(this), amount_);
        IERC20Upgradeable(smlp).transfer(msg.sender, amount_);
        return amount_;
    }

    function unstakeMlp(uint256 amount_) external returns (uint256) {
        _payInterest(msg.sender);
        IERC20Upgradeable(smlp).transferFrom(msg.sender, address(this), amount_);
        IERC20Upgradeable(mlp).transfer(msg.sender, amount_);

        return amount_;
    }

    function reservedMlpAmount(address account) external pure returns (uint256) {
        account;
        return 0;
    }

    function withdrawFromMlpVester(uint256 amount) external pure {
        amount;
        return;
    }

    function _payInterest(address account) internal {
        uint256 balance = IERC20Upgradeable(smlp).balanceOf(account);
        Unclaimed storage u = unclaimed[account];
        u.weth += ((blockTime - u.lastTime) * wethPerMlpPerSecond * balance) / 1e18;
        u.mcb += ((blockTime - u.lastTime) * mcbPerMlpPerSecond * balance) / 1e18;
        require(blockTime >= u.lastTime, "blockTime < u.lastTime");
        u.lastTime = blockTime;
    }
}
