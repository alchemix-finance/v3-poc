// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;
import "forge-std/console.sol";
import {MYTStrategy} from "../MYTStrategy.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";


interface DepositAdapter {
    function depositWETHForWeETH(uint256 amount, address referal) external returns (uint256);
}

interface RedemptionManager {
    function redeemWeEth(uint256 amount, address receiver) external returns (uint256);
    function canRedeem(uint256 amount) external returns (bool);
    function liquidityPool() external returns (address);
}

interface IWETH {
    function approve(address spender, uint256 amount) external;
    function deposit() external payable;
}

interface DEBUG {
    function balanceOf(address owner) external returns (uint256);
}

contract EETHMYTStrategy is MYTStrategy {
    DepositAdapter public immutable depositAdapter;
    RedemptionManager public immutable redemptionManager;
    IWETH public immutable weth;
    address immutable self;
    constructor(
        address _myt,
        StrategyParams memory _params,
        address _weeth, // we explicitly store the receipt token 0x35fA164735182de50811E8e2E824cFb9B6118ac2
        address _weth,
        address _depositAdapter,
        address _redemptionManager,
        address _permit2Address
    ) MYTStrategy(_myt, _params, _permit2Address, _weeth) {
        require(_depositAdapter != address(0));
        require(_redemptionManager != address(0));
        require(_weeth != address(0));
        require(_weth != address(0));
        require(_permit2Address != address(0));
        self = address(this);
        depositAdapter = DepositAdapter(_depositAdapter);
        redemptionManager = RedemptionManager(_redemptionManager);
        weth = IWETH(_weth);
    }

    function _allocate(uint256 amount) internal override returns (uint256 depositReturn) {
        weth.approve(address(depositAdapter), amount);
        depositReturn = depositAdapter.depositWETHForWeETH(amount, address(0));
        //require(depositReturn == amount, "IA");
        //TokenUtils.safeTransfer(address(receiptToken), address(MYT), depositReturn);
        weth.approve(address(depositAdapter), 0);
    }

    function _deallocate(uint256 amount) internal override returns (uint256) {
        address lp = redemptionManager.liquidityPool();

        require(amount <= address(lp).balance, "LIQ");
        require(redemptionManager.canRedeem(amount), "do not redeeeeeem");
        require(amount <= IERC20(receiptToken).balanceOf(self), "Insufficient weETH balance");

        // Approve redemption manager to spend weETH
        TokenUtils.safeApprove(address(receiptToken), address(redemptionManager), amount);
        
        redemptionManager.redeemWeEth(amount, self);
        
        // Convert any received ETH to WETH (enough gas in _deallocate)
        uint256 ethReceived = address(this).balance;
        if (ethReceived > 0) {
            weth.deposit{value: ethReceived}();
        }
        
        // Transfer all WETH to MYT vault
        uint256 wethBalance = IERC20(address(weth)).balanceOf(address(this));
        if (wethBalance > 0) {
            TokenUtils.safeTransfer(address(weth), address(MYT), wethBalance);
        }
        
        // Return the original amount to match vault expectations
        return amount;
    }

    function _computeBaseRatePerSecond() internal override returns (uint256 ratePerSec, uint256 newIndex) {
        uint256 dt = lastSnapshotTime == 0 ? 0 : block.timestamp - lastSnapshotTime;

        uint256 currentPPS = MYT.convertToAssets(1e18);
        newIndex = currentPPS;

        if (lastIndex == 0 || dt == 0 || currentPPS <= lastIndex) return (0, newIndex);
        uint256 growth = (currentPPS - lastIndex) * FIXED_POINT_SCALAR / lastIndex;
        ratePerSec = growth / dt;
        return (ratePerSec, newIndex);
    }

    receive() external payable {
        require(msg.sender == address(redemptionManager), "Only EETH redemption");
        // Don't convert to WETH here - not enough gas. Will be handled in _deallocate
    }
}
