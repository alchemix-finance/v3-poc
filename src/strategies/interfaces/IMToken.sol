// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.28;

interface MTokenInterface {
    function mint(uint mintAmount) virtual external returns (uint);
    function redeem(uint redeemTokens) virtual external returns (uint);
    function exchangeRateStored() virtual external view returns (uint);
}