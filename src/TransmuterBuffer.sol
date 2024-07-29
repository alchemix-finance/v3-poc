// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.23;

import {AccessControl} from "../lib/openzeppelin-contracts/contracts/access/AccessControl.sol";
import {Initializable} from "../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";

/// @title  ITransmuterBuffer ( A partial version for testing)
/// @author Alchemix Finance
///
/// @notice An interface contract to buffer funds between the Alchemist and the Transmuter
contract TransmuterBuffer is Initializable, AccessControl {
    /// @notice The identifier of the role which maintains other roles.
    bytes32 public constant ADMIN = keccak256("ADMIN");

    /// @notice The identifier of the keeper role.
    bytes32 public constant KEEPER = keccak256("KEEPER");

    string public constant version = "3.0.0";

    /// @notice The debt-token used by the TransmuterBuffer.
    address public debtToken;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}

    /// @dev Initialize the contract
    ///
    /// @param _admin     The governing address of the buffer.
    /// @param _debtToken The debt token minted by the Alchemist and accepted by the Transmuter.
    function initialize(address _admin, address _debtToken) external initializer {
        _grantRole(ADMIN, _admin);
        _setRoleAdmin(ADMIN, ADMIN);
        _setRoleAdmin(KEEPER, ADMIN);
        debtToken = _debtToken;
    }
}
