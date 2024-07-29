// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.5.0;

/// @title  IAlchemistV3Errors
/// @author Alchemix Finance
///
/// @notice Specifies errors.
interface IAlchemistV3Errors {
    /// @notice An error which is used to indicate that an operation failed because an account became undercollateralized.
    error Undercollateralized();
}
