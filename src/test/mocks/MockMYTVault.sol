// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultV2} from "../../../lib/vault-v2/src/VaultV2.sol";

contract MockMYTVault is VaultV2 {
    constructor(address admin, address collateral) VaultV2(admin, collateral) {}
}
