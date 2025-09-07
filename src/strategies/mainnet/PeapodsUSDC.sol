// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MYTStrategy} from "../../MYTStrategy.sol";
import {IERC4626} from "../../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {IERC20} from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract PeapodsUSDCStrategy is MYTStrategy {
    IERC4626 public immutable peapodsUsdc;
    IERC20 public immutable usdc;

    constructor(address _myt, StrategyParams memory _params, address _peapodsUsdc, address _usdc) MYTStrategy(_myt, _params) {
        peapodsUsdc = IERC4626(_peapodsUsdc);
        usdc = IERC20(_usdc);
    }

    function _allocate(uint256 amount) internal override returns (uint256 depositReturn) {
        usdc.transferFrom(msg.sender, address(this), amount);
        usdc.approve(address(peapodsUsdc), amount);
        depositReturn = peapodsUsdc.deposit(amount, address(MYT));
    }

    function _deallocate(uint256 amount) internal override returns (uint256 withdrawReturn) {
        withdrawReturn = peapodsUsdc.redeem(amount, address(this), address(MYT));
        usdc.transfer(address(MYT), withdrawReturn);
    }

    function _computeBaseRatePerSecond() internal override returns (uint256 ratePerSec, uint256 newIndex) {
        uint256 dt = lastSnapshotTime == 0 ? 0 : block.timestamp - lastSnapshotTime;
        uint256 currentPPS = peapodsUsdc.convertToAssets(1e18);
        newIndex = currentPPS;
        if (lastIndex == 0 || dt == 0 || currentPPS <= lastIndex) return (0, newIndex);
        uint256 growth = (currentPPS - lastIndex) * FIXED_POINT_SCALAR / lastIndex;
        ratePerSec = growth / dt;
        return (ratePerSec, newIndex);
    }
}