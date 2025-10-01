// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TokenUtils} from "../../libraries/TokenUtils.sol";
import {IMockYieldToken} from "./MockYieldToken.sol";
import {MYTStrategy} from "../../MYTStrategy.sol";
import {IMYTStrategy} from "../../interfaces/IMYTStrategy.sol";

contract MockMYTStrategy is MYTStrategy {
    IMockYieldToken public immutable token;

    constructor(address _myt, address _token, IMYTStrategy.StrategyParams memory _params) MYTStrategy(_myt, _params) {
        token = IMockYieldToken(_token);
    }

    function _allocate(uint256 amount) internal override returns (uint256 depositReturn) {
        // if native eth used, most strats will have their own function to wrap eth to weth
        // so will assume that all token deposits are done with weth
        TokenUtils.safeApprove(token.underlyingToken(), address(token), 2 * amount);
        depositReturn = token.deposit(amount);
        require(depositReturn == amount);
    }

    function _deallocate(uint256 amount) internal override returns (uint256 amountRequested) {
        amountRequested = token.requestWithdraw(address(this), amount);
        TokenUtils.safeApprove(token.underlyingToken(), msg.sender, amount);
        require(amountRequested != 0);
    }

    function realAssets() external view override returns (uint256) {
        return (token.balanceOf(address(this)) * token.price()) / 10 ** token.decimals();
    }

    function _computeBaseRatePerSecond() internal override returns (uint256 ratePerSec, uint256 newIndex) {
        return (0, 0);
    }

    function mockUpdateWhitelistedAllocators(address allocator, bool value) public {}
}
