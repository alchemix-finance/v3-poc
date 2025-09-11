// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;
import {MYTStrategy} from "../../MYTStrategy.sol";
import {IERC20} from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

interface MTokenInterface {
    function mint(uint mintAmount) virtual external returns (uint);
    function redeem(uint redeemTokens) virtual external returns (uint);
    function exchangeRateStored() virtual external view returns (uint);
    function transfer(address dst, uint amount) virtual external returns (bool);
    function transferFrom(address src, address dst, uint amount) external virtual returns (bool);
}

contract MoonwellETHStrategy is MYTStrategy {
    MTokenInterface public immutable mToken;
    IERC20 public immutable usdc;

    constructor(address _myt, StrategyParams memory _params, address _mToken, address _underlying) MYTStrategy(_myt, _params) {
        mToken = MTokenInterface(_mToken);
        usdc = IERC20(_underlying);
    }

    function _allocate(uint256 amount) internal override returns (uint256 depositReturn) {
        usdc.transferFrom(msg.sender, address(this), amount);
        depositReturn = mToken.mint(amount);
        require(mToken.transfer(address(MYT), depositReturn), "Tokens were not transferred");
    }

    function _deallocate(uint256 amount) internal override returns (uint256 withdrawReturn) {
        mToken.transferFrom(msg.sender, address(this), amount);
        withdrawReturn = mToken.redeem(amount);
        usdc.transfer(address(MYT), withdrawReturn);
    }

    function _computeBaseRatePerSecond() internal override returns (uint256 ratePerSec, uint256 newIndex) {
        uint256 dt = lastSnapshotTime == 0 ? 0 : block.timestamp - lastSnapshotTime;

        // Moonwell tokens have 8 decimals and price is scaled up but 1e6
        uint256 currentPPS = mToken.exchangeRateStored() / 1e8;
        newIndex = currentPPS;
         
        if (lastIndex == 0 || dt == 0 || currentPPS <= lastIndex) return (0, newIndex);
        uint256 growth = (currentPPS - lastIndex) * FIXED_POINT_SCALAR / lastIndex;
        ratePerSec = growth / dt;
        return (ratePerSec, newIndex);
    }
}