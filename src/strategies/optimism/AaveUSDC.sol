// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;
import {MYTStrategy} from "../../MYTStrategy.sol";
import {IERC20} from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

interface MTokenInterface {
    function mint(uint mintAmount) virtual external returns (uint);
    function redeem(uint redeemTokens) virtual external returns (uint);
    function exchangeRateStored() virtual external view returns (uint);
    function transfer(address dst, uint amount) virtual external returns (bool);
}

interface IStaticAToken is IERC20{
    function deposit(
        address recipient,
        uint256 amount,
        uint16 referralCode,
        bool fromUnderlying
    ) external returns (uint256);

    function withdraw(
        address recipient,
        uint256 amount,
        bool toUnderlying
    ) external returns (uint256, uint256);

    function staticToDynamicAmount(uint256 amount) external view returns (uint256 dynamicAmount);
}

contract MoonwellETHStrategy is MYTStrategy {
    IStaticAToken public immutable aToken;
    IERC20 public immutable usdc;

    constructor(address _myt, StrategyParams memory _params, address _aToken, address _underlying) MYTStrategy(_myt, _params) {
        aToken = IStaticAToken(_aToken);
        usdc = IERC20(_underlying);
    }

    function _allocate(uint256 amount) internal override returns (uint256 depositReturn) {
        usdc.transferFrom(msg.sender, address(this), amount);
        usdc.approve(address(aToken), amount);
        depositReturn = aToken.deposit(address(MYT), amount, 0, true);
    }

    function _deallocate(uint256 amount) internal override returns (uint256) {
        aToken.transferFrom(address(MYT), address(this), amount);
        (uint256 burned, uint256 withdrawReturn) = aToken.withdraw(address(MYT), amount, true);
        return withdrawReturn;
    }

    function _computeBaseRatePerSecond() internal override returns (uint256 ratePerSec, uint256 newIndex) {
        uint256 dt = lastSnapshotTime == 0 ? 0 : block.timestamp - lastSnapshotTime;

        uint256 currentPPS = aToken.staticToDynamicAmount(1e6);
        newIndex = currentPPS;
         
        if (lastIndex == 0 || dt == 0 || currentPPS <= lastIndex) return (0, newIndex);
        uint256 growth = (currentPPS - lastIndex) * FIXED_POINT_SCALAR / lastIndex;
        ratePerSec = growth / dt;
        return (ratePerSec, newIndex);
    }
}