// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.26;

import {Initializable} from "../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "../lib/openzeppelin-contracts-upgradeable/contracts/access/AccessControlUpgradeable.sol";
import "./libraries/SafeCast.sol";
import "./libraries/TokenUtils.sol";

/// @title TransmuterV3 (A Partial Version for Testing)
///
/// @notice A contract which facilitates the exchange of synthetic assets for their underlying
//          asset. This contract guarantees that synthetic assets are exchanged exactly 1:1
//          for the underlying asset.
contract TransmuterV3 is Initializable, AccessControlUpgradeable {
    address public constant ZERO_ADDRESS = address(0);

    /// @dev The identifier of the role which maintains other roles.
    bytes32 public constant ADMIN = keccak256("ADMIN");

    /// @dev The identifier of the sentinel role
    bytes32 public constant SENTINEL = keccak256("SENTINEL");

    string public constant version = "3.0.0";

    /// @dev the synthetic token to be transmuted
    address public syntheticToken;

    /// @dev the underlying token to be received
    address public underlyingToken;

    /// @dev the source of the exchanged collateral
    address public buffer;

    /// @dev The amount of decimal places needed to normalize collateral to debtToken
    uint256 public conversionFactor;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}

    function initialize(address _syntheticToken, address _underlyingToken, address _buffer) external initializer {
        _grantRole(ADMIN, msg.sender);
        _setRoleAdmin(ADMIN, ADMIN);
        _setRoleAdmin(SENTINEL, ADMIN);

        syntheticToken = _syntheticToken;
        underlyingToken = _underlyingToken;
        uint8 debtTokenDecimals = TokenUtils.expectDecimals(syntheticToken);
        uint8 underlyingTokenDecimals = TokenUtils.expectDecimals(underlyingToken);
        conversionFactor = 10 ** (debtTokenDecimals - underlyingTokenDecimals);
        buffer = _buffer;
    }
}
