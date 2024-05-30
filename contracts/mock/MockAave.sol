// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetMinterPauser.sol";

contract MockAToken is ERC20 {
    mapping(address => uint) _lastUpdateTime;
    uint256 public apy; // 1e18
    uint32 public blockTime;

    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function setApy(uint256 apy_) external {
        apy = apy_;
    }

    function setBlockTime(uint32 blockTime_) external {
        blockTime = blockTime_;
    }

    function _blockTimestamp() internal view returns (uint32) {
        return blockTime;
    }

    function balanceOf(address account) public view override returns (uint256) {
        return ERC20.balanceOf(account) + _earned(account);
    }

    function mint(address account, uint256 amount) public {
        _payInterest(account);
        _mint(account, amount);
    }

    function burn(address account, uint256 amount) public {
        _payInterest(account);
        _burn(account, amount);
    }

    function _payInterest(address account) internal {
        uint256 e = _earned(account);
        _mint(account, e);
        _lastUpdateTime[account] = _blockTimestamp();
    }

    function _earned(address account) internal view returns (uint256) {
        uint256 balance = ERC20.balanceOf(account);
        uint256 lastUpdate = _lastUpdateTime[account];
        uint256 timePassed = _blockTimestamp() - lastUpdate;
        return (balance * apy * timePassed) / (365 days) / 1e18; // 6 + 18 + 0 - 18
    }
}

contract MockAavePool {
    IERC20 public usdc;
    MockAToken public aToken;
    IERC20 public arb;

    constructor(address usdc_, address aToken_, address arb_) {
        usdc = IERC20(usdc_);
        aToken = MockAToken(aToken_);
        arb = IERC20(arb_);
    }

    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode
    ) external {
        referralCode;
        _payInterest(msg.sender);
        require(asset == address(usdc), "Invalid asset");
        usdc.transferFrom(msg.sender, address(this), amount);
        aToken.mint(onBehalfOf, amount);
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        require(asset == address(usdc), "Invalid asset");
        _payInterest(msg.sender);
        aToken.burn(msg.sender, amount);
        usdc.transfer(to, amount);
        return amount;
    }

    struct Unclaimed {
        uint32 lastTime;
        uint256 arb;
    }
    uint32 private blockTime;
    mapping(address => Unclaimed) private unclaimed;
    uint256 public arbPerUsdcPerSecond; // 1e18

    function setBlockTime(uint32 blockTime_) external {
        blockTime = blockTime_;
    }

    function setRewardRate(uint256 arbPerUsdcPerSecond_) external {
        arbPerUsdcPerSecond = arbPerUsdcPerSecond_;
    }

    function getUserRewards(
        address[] calldata assets,
        address user,
        address reward
    ) external view returns (uint256) {
        require(assets.length > 0, "unsupported assets");
        require(assets[0] == address(aToken), "unsupported asset");
        require(reward == address(arb), "unsupported reward token");
        Unclaimed storage u = unclaimed[user];
        return u.arb + _earned(user);
    }

    function claimRewards(
        address[] calldata assets,
        uint256 amount,
        address to,
        address reward
    ) external returns (uint256) {
        require(assets.length > 0, "unsupported assets");
        require(assets[0] == address(aToken), "unsupported asset");
        require(reward == address(arb), "unsupported reward token");
        _payInterest(msg.sender);
        Unclaimed storage u = unclaimed[msg.sender];

        uint256 claimable = u.arb;
        if (amount > 0 && amount < claimable) {
            claimable = amount;
        }
        u.arb -= claimable;
        require(arb.transfer(to, claimable), "Reward transfer failed");
        return claimable;
    }

    function _payInterest(address account) internal {
        Unclaimed storage u = unclaimed[account];
        uint256 e = _earned(account);
        u.arb += e;
        u.lastTime = blockTime;
    }

    function _earned(address account) internal view returns (uint256) {
        Unclaimed storage u = unclaimed[account];
        uint256 balance = aToken.balanceOf(account);
        return ((blockTime - u.lastTime) * arbPerUsdcPerSecond * balance) / 1e6; // 0 + 18 + 6 - 6
    }
}
