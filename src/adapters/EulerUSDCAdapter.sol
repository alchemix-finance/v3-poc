// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "../libraries/TokenUtils.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import '../interfaces/ITokenAdapter.sol';
import "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title Euler Adapter
contract EulerUSDCAdapter is ITokenAdapter {
    string public constant version = "1.0.0";

    address public immutable token;
    
    address public immutable underlyingToken;

    constructor(address _token, address _underlyingToken) {
        token = _token;
        underlyingToken = _underlyingToken;
    }

    function price() external view returns (uint256) {
        return IERC4626(token).convertToAssets(10**TokenUtils.expectDecimals(token));
    }
}