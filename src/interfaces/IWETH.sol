// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IWETH
 * @dev Interface for Wrapped Ether
 */
interface IWETH is IERC20 {
    /**
     * @notice Deposit ETH and get WETH
     */
    function deposit() external payable;

    /**
     * @notice Withdraw ETH by unwrapping WETH
     * @param amount Amount of WETH to unwrap
     */
    function withdraw(uint256 amount) external;
}
