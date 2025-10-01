// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TestYieldToken} from "./TestYieldToken.sol";
import {TokenUtils} from "../../libraries/TokenUtils.sol";

interface IMockYieldToken {
    function deposit(uint256 amount) external returns (uint256);
    function requestWithdraw(address recipient, uint256 amount) external returns (uint256);
    function mockedSupply() external view returns (uint256);
    function underlyingToken() external view returns (address);
    function mint(uint256 amount, address recipient) external returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function price() external view returns (uint256);
    function decimals() external view returns (uint8);
    function updateMockTokenSupply(uint256 value) external;
    function siphon(uint256 amount) external;
}

contract MockYieldToken is TestYieldToken {
    uint256 private constant BPS = 10_000;

    constructor(address _underlyingToken) TestYieldToken(_underlyingToken) {}

    // for non eth based depositdeposits
    function deposit(uint256 amount) external returns (uint256) {
        require(amount > 0);
        uint256 shares = _issueSharesForAmount(msg.sender, amount);
        TokenUtils.safeTransferFrom(underlyingToken, msg.sender, address(this), amount);
        return shares;
    }

    function requestWithdraw(address recipient, uint256 amount) external returns (uint256) {
        assert(amount > 0);

        uint256 value = _shareValue(amount);
        value = (value * (BPS - slippage)) / BPS;
        _burn(msg.sender, amount);
        TokenUtils.safeTransfer(underlyingToken, recipient, value);
        return value;
    }
}
