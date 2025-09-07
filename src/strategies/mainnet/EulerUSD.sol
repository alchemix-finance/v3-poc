// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MYTStrategy} from "../../MYTStrategy.sol";
import {IERC4626} from "../../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {IERC20} from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
// import {OracleLibrary} from "../../lib/v3-periphery/contracts/libraries/OracleLibrary.sol";

interface REUL is IERC20 {
    function underlying() external view returns (IERC20);
    function getLockedAmountsLockTimestamps(address account) external view returns (uint256[] memory);
    function getWithdrawAmountsByLockTimestamp(address account, uint256 lockTimestamp) external view returns (uint256 accountAmount, uint256 remainderAmount);
    function withdrawToByLockTimestamps(address account, uint256[] calldata lockTimestamps, bool allowRemainderLoss) external returns (bool);
}

interface IMultiMerkleDistributor {
    struct ClaimParams {
        uint256 questID;
        uint256 period;
        uint256 index;
        uint256 amount;
        bytes32[] merkleProof;
    }
    function multiClaim(address account, ClaimParams[] calldata claims) external;
}

contract EulerUSDStrategy is MYTStrategy {
    IERC4626 public immutable eulerVault;
    IERC20 public immutable underlying;
    IERC20 public immutable rewardUnderlying;
    REUL public immutable rEUL;

    uint256 private _lastEulBal;
    uint256 private _eulClaimed;
    uint256 private _lastRewardTime;
    uint256 private _lastRewardsCum6; 

    constructor(address _myt, StrategyParams memory _params, address _eulerVault, address _underlying, address _rewardToken) MYTStrategy(_myt, _params) {
        eulerVault = IERC4626(_eulerVault);
        underlying = IERC20(_underlying);
        rEUL = REUL(_rewardToken);
        rewardUnderlying = rEUL.underlying();
    }

    function _allocate(uint256 amount) internal override returns (uint256 depositReturn) {
        underlying.transferFrom(msg.sender, address(this), amount);
        underlying.approve(address(eulerVault), amount);
        depositReturn = eulerVault.deposit(amount, address(MYT));
    }

    function _deallocate(uint256 amount) internal override returns (uint256 withdrawReturn) {
        withdrawReturn = eulerVault.redeem(amount, address(this), address(MYT));
        underlying.transfer(address(MYT), withdrawReturn);
    }

    function _claimRewards() internal override returns (uint256 claimed) {
        uint256[] memory locks = rEUL.getLockedAmountsLockTimestamps(address(this));
        if (locks.length == 0) return 0;

        uint256 claimable;
        for (uint256 i = 0; i < locks.length; ++i) {
            (uint256 acctAmt, ) = rEUL.getWithdrawAmountsByLockTimestamp(address(this), locks[i]);
            claimable += acctAmt;
        }

        if (claimable == 0) return 0;

        uint256 before = rewardUnderlying.balanceOf(address(MYT));
        rEUL.withdrawToByLockTimestamps(address(MYT), locks, true);
        uint256 afterBal = rewardUnderlying.balanceOf(address(MYT));
        claimed = afterBal - before;
        if (claimed != 0) _eulClaimed += claimed;
    }

    // TODO Access control
    function claimFromMerkl(IMultiMerkleDistributor distro, IMultiMerkleDistributor.ClaimParams[] calldata claims) external returns (uint256 claimed) {
        uint256 beforeBal = rEUL.balanceOf(address(this));
        distro.multiClaim(address(this), claims);
        claimed = rEUL.balanceOf(address(this)) - beforeBal;
        if (claimed != 0) _eulClaimed += claimed;
    }

    function _computeBaseRatePerSecond() internal override returns (uint256 ratePerSec, uint256 newIndex) {
        uint256 dt = lastSnapshotTime == 0 ? 0 : block.timestamp - lastSnapshotTime;
        uint256 currentPPS = eulerVault.convertToAssets(1e18);
        newIndex = currentPPS;
        if (lastIndex == 0 || dt == 0 || currentPPS <= lastIndex) return (0, newIndex);
        uint256 growth = (currentPPS - lastIndex) * 1e18 / lastIndex;
        ratePerSec = growth / dt;
    }

    function _computeRewardsRatePerSecond() internal override returns (uint256) {
        uint256 eulPerSec18 = _realizedEulPerSecWad();
        if (eulPerSec18 == 0) return 0;

        uint256 pxUsdcPerEul18 = eulUsdc.usdcPerEulWad(); 
        if (pxUsdcPerEul18 == 0) return 0;

        uint256 shares = IERC20(address(eulerVault)).balanceOf(address(MYT));
        if (shares == 0) return 0;
        uint256 pps6 = eulerVault.convertToAssets(1e18);
        if (pps6 == 0) return 0;
        uint256 tvlUsdc18 = (shares * pps6 * 1e12) / 1e18;
        if (tvlUsdc18 == 0) return 0;

        uint256 usdcPerSec18 = (eulPerSec18 * pxUsdcPerEul18) / 1e18;

        return (usdcPerSec18 * 1e18) / tvlUsdc18;
    }

    function _realizedEulPerSecWad() internal returns (uint256 eulPerSec18) {
        uint256 currentTime = block.timestamp;
        if (_lastRewardTime == 0) { _lastRewardTime = currentTime; _lastEulBal = _eulClaimed; return 0; }

        uint256 dt = currentTime - _lastRewardTime;
        if (dt == 0) return 0;

        uint256 delta = _eulClaimed - _lastEulBal;
        _lastEulBal = _eulClaimed;
        _lastRewardTime = currentTime;

        if (delta == 0) return 0;
        return delta / dt;
    }

    function _eulUsdcTwapWad(
        address eulWethPool,
        address usdcWethPool,
        uint32  windowSeconds
    ) internal view returns (uint256 price1e18) {
        // 1) EUL/ETH 
        (int24 tickEulEth,) = OracleLibrary.consult(eulWethPool, windowSeconds);
        uint256 eulPerEth = OracleLibrary.getQuoteAtTick(tickEulEth, 1e18, address(EUL), address(WETH));

        // 2) ETH/USDC 
        (int24 tickEthUsdc,) = OracleLibrary.consult(usdcWethPool, windowSeconds);
        uint256 ethPerUsdc6 = OracleLibrary.getQuoteAtTick(tickEthUsdc, 1e18, address(WETH), address(USDC));

        // 3) EUL/USDC
        return (eulPerEth * ethPerUsdc6) / 1e6;
    }
}