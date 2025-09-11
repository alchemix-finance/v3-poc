// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;
import {MYTStrategy} from "../../MYTStrategy.sol";

interface MTokenInterface {
    function mint(uint mintAmount) virtual external returns (uint);
    function redeem(uint redeemTokens) virtual external returns (uint);
    function exchangeRateStored() virtual external view returns (uint);
}

interface WETH {
    function deposit() external payable;
    function withdraw(uint256) external;
}

contract MoonwellETHStrategy is MYTStrategy {
    MTokenInterface public immutable mToken;
    WETH public immutable weth;

    constructor(address _myt, StrategyParams memory _params, address _mToken, address _weth) MYTStrategy(_myt, _params) {
        mToken = MTokenInterface(_mToken);
        weth = WETH(_weth);
    }

    function _allocate(uint256 amount) internal override returns (uint256 depositReturn) {
        require(msg.value == amount);
        weth.deposit{value: msg.value}();                   
        depositReturn = mToken.mint(amount);
    }

    function _deallocate(uint256 amount) internal override returns (uint256 withdrawReturn) {
        withdrawReturn = mToken.redeem(amount);
        _unwrapWETH(withdrawReturn, address(MYT));
    }

    function _unwrapWETH(uint256 amount, address to) internal {
        weth.withdraw(amount);
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "ETH send failed");
    }

    function _computeBaseRatePerSecond() internal override returns (uint256 ratePerSec, uint256 newIndex) {
        uint256 dt = lastSnapshotTime == 0 ? 0 : block.timestamp - lastSnapshotTime;

        // Moonwell tokens have 8 decimals and price is scaled up but 1e18
        uint256 currentPPS = mToken.exchangeRateStored() / 1e8;
        newIndex = currentPPS;
         
        if (lastIndex == 0 || dt == 0 || currentPPS <= lastIndex) return (0, newIndex);
        uint256 growth = (currentPPS - lastIndex) * FIXED_POINT_SCALAR / lastIndex;
        ratePerSec = growth / dt;
        return (ratePerSec, newIndex);
    }

    receive() external payable {
        require(msg.sender == address(weth), "Only WETH unwrap");
    }
}