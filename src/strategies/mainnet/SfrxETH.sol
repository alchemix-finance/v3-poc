// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;
import {MYTStrategy} from "../../MYTStrategy.sol";

interface FraxMinter {
    function submitAndDeposit(address recipient) external payable returns (uint256);
}

interface FraxRedemptionQueue {
    function enterRedemptionQueueViaSfrxEth(address _recipient, uint120 _sfrxEthAmount) external returns (uint256 _nftId);
    function burnRedemptionTicketNft(uint256 nftId, address payable recipient) external;
}

interface StakedFraxEth {
    function convertToAssets(uint256 shares) external view returns (uint256);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

contract SfrxETHStrategy is MYTStrategy {
    FraxMinter public immutable minter;
    FraxRedemptionQueue public immutable redemptionQueue;
    StakedFraxEth public immutable sfrxEth;

    constructor(
        address _myt,
        StrategyParams memory _params,
        address _sfrxEth,
        address _fraxMinter,
        address _redemptionQueue
    ) MYTStrategy(_myt, _params) {
        minter = FraxMinter(_fraxMinter);
        redemptionQueue = FraxRedemptionQueue(_redemptionQueue);
        sfrxEth = StakedFraxEth(_sfrxEth);
    }

    function _allocate(uint256 amount) internal override returns (uint256 depositReturn) {
        require(msg.value == amount);
        depositReturn = minter.submitAndDeposit{value: amount}(address(MYT));
    }

    function _deallocate(uint256 amount) internal override returns (uint256 positionId) {
        // protection for uint120 requirement
        require(amount <= type(uint120).max);
        require(sfrxEth.transferFrom(msg.sender, address(this), amount), "pull shares fail");

        sfrxEth.approve(address(redemptionQueue), amount);
        positionId = redemptionQueue.enterRedemptionQueueViaSfrxEth(address(MYT), uint120(amount));
        require(positionId != 0);
    }

    function _claimWithdrawalQueue(uint256 positionId) internal override returns(uint256 ethOut) {
        redemptionQueue.burnRedemptionTicketNft(positionId, payable(address(MYT)));
    }

    function _computeBaseRatePerSecond() internal override returns (uint256 ratePerSec, uint256 newIndex) {
        uint256 dt = lastSnapshotTime == 0 ? 0 : block.timestamp - lastSnapshotTime;

        uint256 currentPPS = sfrxEth.convertToAssets(1e18);

        newIndex = currentPPS;
        if (lastIndex == 0 || dt == 0 || currentPPS <= lastIndex) return (0, newIndex);
        uint256 growth = (currentPPS - lastIndex) * FIXED_POINT_SCALAR / lastIndex;
        ratePerSec = growth / dt;
        return (ratePerSec, newIndex);
    }
}