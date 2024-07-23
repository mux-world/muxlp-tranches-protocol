// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetMinterPauser.sol";

// caution: this is a mock, we only implement necessary functions. do not use this in production
library MockRayMath {
    uint256 internal constant RAY = 1e27;
    uint256 internal constant HALF_RAY = 0.5e27;

    // see https://twitter.com/transmissions11/status/1451131036377571328
    function rayMul(uint256 a, uint256 b) internal pure returns (uint256 c) {
        assembly {
            if iszero(or(iszero(b), iszero(gt(a, div(sub(not(0), HALF_RAY), b))))) {
                revert(0, 0)
            }

            c := div(add(mul(a, b), HALF_RAY), RAY)
        }
    }

    // see https://twitter.com/transmissions11/status/1451131036377571328
    function rayDiv(uint256 a, uint256 b) internal pure returns (uint256 c) {
        assembly {
            if or(iszero(b), iszero(iszero(gt(a, div(sub(not(0), div(b, 2)), RAY))))) {
                revert(0, 0)
            }

            c := div(add(mul(a, RAY), div(b, 2)), b)
        }
    }
}

contract MockAToken is ERC20 {
    using MockRayMath for uint256;

    uint32 _lastUpdateTime;
    uint256 _navRay; // 1e27
    uint256 _apyRay; // 1e18
    uint32 public blockTime;

    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _navRay = MockRayMath.RAY;
    }

    function setApy(uint256 apy_ /* 1e18 */) external {
        _apyRay = apy_ * 1e9;
    }

    function setBlockTime(uint32 blockTime_) external {
        blockTime = blockTime_;
    }

    function _blockTimestamp() internal view returns (uint32) {
        return blockTime;
    }

    function balanceOf(address user) public view virtual override(ERC20) returns (uint256) {
        uint256 navRay = _nextNavRay();

        // AToken
        return super.balanceOf(user).rayMul(navRay);
    }

    function mint(address account, uint256 amount) public {
        _payInterest();
        // AToken: _mintScaled(account, amount, _navRay);
        uint256 index = _navRay;
        // ScaledBalanceTokenBase:
        uint256 amountScaled = amount.rayDiv(index);
        require(amountScaled != 0, "INVALID_MINT_AMOUNT");
        _mint(account, amountScaled);
    }

    function burn(address account, uint256 amount) public {
        _payInterest();
        // AToken: _burnScaled(account, amount, _navRay);
        uint256 index = _navRay;
        // ScaledBalanceTokenBase:
        uint256 amountScaled = amount.rayDiv(index);
        require(amountScaled != 0, "INVALID_BURN_AMOUNT");
        _burn(account, amountScaled);
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        uint256 index = _navRay;
        uint256 amountScaled = amount.rayDiv(index);
        ERC20._transfer(from, to, amountScaled);
    }

    function _payInterest() internal {
        _navRay = _nextNavRay();
        _lastUpdateTime = _blockTimestamp();
    }

    function _nextNavRay() internal view returns (uint256) {
        uint256 timePassed = _blockTimestamp() - _lastUpdateTime;
        // index_a_n = index_a_n-1 * (1 + r * t)
        uint256 ret = (_apyRay * timePassed) / (365 days); // 27 + 0 - 0
        ret += MockRayMath.RAY;
        ret = _navRay.rayMul(ret);
        return ret;
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
