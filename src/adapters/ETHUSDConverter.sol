// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AggregatorV3Interface} from "../../lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

library ETHUSDConverter {
    // Error for chainlink malfunction
    error ChainlinkMalfunction(address priceFeed, int256 price);
    // Error for incomplete round
    error IncompleteRound(address priceFeed, uint256 updateTime);

    // Address of the mainnet ETH/USD price feed
    uint256 private constant USDC_DECIMALS = 6;

    /**
     * @notice Convert ETH amount to USD value
     * @param ethAmount Amount of ETH/WETH to convert
     * @return usdAmount Equivalent amount in USD (6 decimals)
     * @param expectedUpdateTime Expected update time of the price feed
     */
    function ethToUSD(uint256 ethAmount, address usdPriceFeed, uint256 expectedUpdateTime) internal view returns (uint256 usdAmount) {
        // Get the latest ETH/USD price
        AggregatorV3Interface priceFeed = AggregatorV3Interface(usdPriceFeed);
        (, int256 price,, uint256 updateTime,) = priceFeed.latestRoundData();

        if (price <= 0) {
            revert ChainlinkMalfunction(usdPriceFeed, price);
        }

        if (updateTime == 0) {
            revert IncompleteRound(usdPriceFeed, updateTime);
        }

        if (updateTime < block.timestamp - expectedUpdateTime) {
            revert IncompleteRound(usdPriceFeed, updateTime);
        }
        // ETH has 18 decimals, USD representation has 6 decimals, Chainlink has 8 decimals
        // ethAmount * price / 10^20 = usdAmount (convert to 6 decimals)
        return (ethAmount * uint256(price)) / 1e20;
    }

    /**
     * @notice Convert USD value to ETH amount
     * @param usdAmount Amount in USD (6 decimals)
     * @return ethAmount Equivalent amount in ETH/WETH (18 decimals)
     * @param expectedUpdateTime Expected update time of the price feed
     */
    function usdToETH(uint256 usdAmount, address usdPriceFeed, uint256 expectedUpdateTime) internal view returns (uint256 ethAmount) {
        // Get the latest ETH/USD price
        AggregatorV3Interface priceFeed = AggregatorV3Interface(usdPriceFeed);
        (, int256 price,, uint256 updateTime,) = priceFeed.latestRoundData();

        if (price <= 0) {
            revert ChainlinkMalfunction(usdPriceFeed, price);
        }

        if (updateTime == 0) {
            revert IncompleteRound(usdPriceFeed, updateTime);
        }

        if (updateTime < block.timestamp - expectedUpdateTime) {
            revert IncompleteRound(usdPriceFeed, updateTime);
        }

        // USD representation has 6 decimals, ETH has 18 decimals, Chainlink has 8 decimals
        // usdAmount * 10^20 / price = ethAmount (convert to 18 decimals)
        return (usdAmount * 1e20) / uint256(price);
    }

    /**
     * @notice Convert underlying token amount to USD value
     * @param underlyingTokenAmount Amount of underlying token to convert
     * @return usdAmount Equivalent amount in USD (6 decimals)
     */
    function underlyingTokenToUSD(uint256 underlyingTokenAmount, uint256 underlyingTokenDecimals) internal pure returns (uint256 usdAmount) {
        uint256 usdConversionFactor = 10 ** (underlyingTokenDecimals - USDC_DECIMALS);
        return underlyingTokenAmount / usdConversionFactor;
    }
}
