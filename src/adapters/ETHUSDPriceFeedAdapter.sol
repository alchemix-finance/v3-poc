// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AggregatorV3Interface} from "../../lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {ETHUSDConverter} from "./ETHUSDConverter.sol";
// Address of the mainnet ETH/USD price feed

interface IPriceFeedAdapter {
    /**
     * @notice Convert USD amount to ETH value
     * @param usdAmount Amount in USD (6 decimals)
     */
    function usdToETH(uint256 usdAmount) external view returns (uint256);
    /**
     * @notice Convert ETH amount to USD value
     * @param ethAmount Amount of ETH/WETH to convert
     */
    function ethToUSD(uint256 ethAmount) external view returns (uint256);
    /**
     * @notice Convert alchemist underlying token amount to USD value
     * @param underlyingTokenAmount Amount of underlying token to convert
     */
    function underlyingTokenToUSD(uint256 underlyingTokenAmount) external view returns (uint256);
}

// Price feed adapter for ETH/USD price feed per chain
contract ETHUSDPriceFeedAdapter is IPriceFeedAdapter {
    address immutable priceFeed;
    uint256 immutable updateTimeInSeconds;
    uint256 immutable underlyingTokenDecimals;

    /**
     * @notice Constructor for the ETHUSDPriceFeedAdapter
     * @param _priceFeed The address of the ETH/USD price feed
     * @param _updateTimeInSeconds The expected update time of the price feed in seconds
     */
    constructor(address _priceFeed, uint256 _updateTimeInSeconds, uint256 _underlyingTokenDecimals) {
        priceFeed = _priceFeed;
        updateTimeInSeconds = _updateTimeInSeconds;
        underlyingTokenDecimals = _underlyingTokenDecimals;
    }

    // @inheritdoc IPriceFeedAdapter
    function usdToETH(uint256 usdAmount) external view returns (uint256 ethAmount) {
        return ETHUSDConverter.usdToETH(usdAmount, priceFeed, updateTimeInSeconds);
    }

    // @inheritdoc IPriceFeedAdapter
    function ethToUSD(uint256 ethAmount) external view returns (uint256 usdAmount) {
        return ETHUSDConverter.ethToUSD(ethAmount, priceFeed, updateTimeInSeconds);
    }

    // @inheritdoc IPriceFeedAdapter
    function underlyingTokenToUSD(uint256 underlyingTokenAmount) external view returns (uint256 usdAmount) {
        return ETHUSDConverter.underlyingTokenToUSD(underlyingTokenAmount, underlyingTokenDecimals);
    }
}
