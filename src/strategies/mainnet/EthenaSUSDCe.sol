// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MYTStrategy} from "../../MYTStrategy.sol";
import {IERC4626} from "../../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {IERC20} from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract EthenaSUSDCeStrategy is MYTStrategy {
    IERC4626 public immutable SUSDCE;
    IERC20 public immutable USDCE;

    constructor(address _myt, StrategyParams memory _params, address _sUsdcE, address _usdcE) MYTStrategy(_myt, _params) {
        SUSDCE = IERC4626(_sUsdcE);
        USDCE = IERC20(_usdcE);
        USDCE.approve(_sUsdcE, type(uint256).max);
    }

    function _allocate(uint256 amount) internal override returns (uint256 depositReturn) {
        USDCE.transferFrom(msg.sender, address(this), amount);
        depositReturn = SUSDCE.deposit(amount, address(MYT));
    }

    function _deallocate(uint256 amount) internal override returns (uint256 withdrawReturn) {
        withdrawReturn = SUSDCE.redeem(amount, address(this), address(MYT));
        USDCE.transfer(address(MYT), withdrawReturn);
    }

    function _computeBaseRatePerSecond() internal override returns (uint256 ratePerSec, uint256 newIndex) {
        uint256 dt = lastSnapshotTime == 0 ? 0 : block.timestamp - lastSnapshotTime;
        uint256 currentPPS = SUSDCE.convertToAssets(1e18);
        newIndex = currentPPS;
        if (lastIndex == 0 || dt == 0 || currentPPS <= lastIndex) return (0, newIndex);
        uint256 growth = (currentPPS - lastIndex) * FIXED_POINT_SCALAR / lastIndex;
        ratePerSec = growth / dt;
        return (ratePerSec, newIndex);
    }

    // TODO Points are difficult to really put a price on
    // Perhaps think of a way to do this if we care enough
    // function _computeRewardsRatePerSecond() internal override returns (uint256) {
    // }
}