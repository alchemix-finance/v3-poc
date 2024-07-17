// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.5.0;

/// @title  IAlchemistV3Immutables
/// @author Alchemix Finance
interface IAlchemistV3Immutables {
    /// @notice Returns the version of the alchemist.
    ///
    /// @return The version.
    function version() external view returns (string memory);

    /// @notice Returns the address of the debt token used by the system.
    ///
    /// @return The address of the debt token.
    function debtToken() external view returns (address);

    /// @notice Returns the address of the yield token used by the system.
    ///
    /// @return The address of the yield token.
    function yieldToken() external view returns (address);
}
