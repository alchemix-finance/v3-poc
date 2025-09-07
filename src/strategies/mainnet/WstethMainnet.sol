// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;
import {MYTStrategy} from "../../MYTStrategy.sol";

interface stETH {
    function sharesOf(address account) external view returns (uint256);
    function getPooledEthByShares(uint256 sharesAmount) external view returns (uint256);
    function submit(address referral) external payable returns (uint256);
}

interface wstETH {
    function getWstETHByStETH(uint256 amount) external view returns (uint256);
    function getStETHByWstETH(uint256 amount) external view returns (uint256);
    function wrap(uint256 amount) external returns (uint256);
    function unwrap(uint256 amount) external returns (uint256);
}

interface unstETH {
    function requestWithdrawalsWstETH(uint256[] calldata amounts, address owner) external returns (uint256[] memory requestIds);
    function claimWithdrawals(uint256[] calldata requestIds, uint256[] calldata hints) external;
}

// THIS IS A WIP THAT WAS STARTED BEFORE REALIZING WE ARENT PRIORITIZING THIS VAULT
contract WstethMainnetStrategy is MYTStrategy {
    stETH public immutable steth;
    wstETH public immutable wsteth;
    unstETH public immutable unsteth;

    constructor(address _myt, StrategyParams memory _params, address _stETH, address _wstETH, address _unstETH, address _referral) MYTStrategy(_myt, _params) {
        steth = stETH(_stETH);
        wsteth = wstETH(_wstETH);
        unsteth = unstETH(_unstETH);
    }

    function _allocate(uint256 amount) internal override returns (uint256 depositReturn) {
        // require(msg.value == amount);
        // depositReturn = wsteth.wrap(steth.submit{value: amount}(_referral));
        // require(depositReturn == amount);
    }

    function _deallocate(uint256 amount) internal override returns (uint256 requestId) {
        
    }

    function snapshotYield() public override returns (uint256) {
        // TODO calculate & snapshot yield
    }
}