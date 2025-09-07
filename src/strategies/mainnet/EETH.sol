// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;
import {MYTStrategy} from "../../MYTStrategy.sol";

interface EETH {
    function deposit() external payable returns (uint256);
    function requestWithdraw(address recipient, uint256 amount) external returns (uint256);
}

contract EETHMYTStrategy is MYTStrategy {
    EETH public immutable eeth;

    constructor(address _myt, StrategyParams memory _params, address _eeth) MYTStrategy(_myt, _params) {
        eeth = EETH(_eeth);
    }


    function _allocate(uint256 amount) internal override returns (uint256 depositReturn) {
        require(msg.value == amount);
        depositReturn = eeth.deposit{value: amount}();
        require(depositReturn == amount);
    }

    function _deallocate(uint256 amount) internal override returns (uint256 requestId) {
        requestId = eeth.requestWithdraw(msg.sender, amount);
        require(requestId != 0);
    }

    function snapshotYield() public override returns (uint256) {
        // TODO calculate & snapshot yield
    }

}
