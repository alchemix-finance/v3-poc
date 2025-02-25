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
        return IERC4626(token).convertToAssets(1e6);
    }

    function wrap(uint256 amount, address recipient) external returns (uint256) {
		// Transfer the underlying token from the sender to the adapter
		TokenUtils.safeTransferFrom(underlyingToken, msg.sender, address(this), amount);

        TokenUtils.safeApprove(underlyingToken, token, 0);
        TokenUtils.safeApprove(underlyingToken, token, amount);
		uint256 shares = IERC4626(token).deposit(amount, recipient);

		TokenUtils.safeTransfer(token, recipient, shares);
		return shares;
    }

    function unwrap(uint256 amount, address recipient) external returns (uint256) {
        // Transfer the shares from the Alchemist to the Adapter
		TokenUtils.safeTransferFrom(token, msg.sender, address(this), amount);

		uint256 underlying = IERC4626(token).redeem(amount, recipient, address(this));

		TokenUtils.safeTransfer(underlyingToken, recipient, underlying);
		return underlying;
    }
}