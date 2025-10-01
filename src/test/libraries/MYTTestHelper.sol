// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MockMYTStrategy} from "../mocks/MockMYTStrategy.sol";
import {TokenUtils} from "../../libraries/TokenUtils.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IMYTStrategy} from "../../interfaces/IMYTStrategy.sol";
import {MockMYTVault} from "../mocks/MockMYTVault.sol";

library MYTTestHelper {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function _setupVault(address collateral, address admin, address curator) internal returns (MockMYTVault) {
        // create vault with collateral
        MockMYTVault vault = new MockMYTVault(admin, collateral);
        // set curator
        vault.setCurator(curator);

        return vault;
    }

    function _setupStrategy(address myt, address yieldToken, address owner, string memory name, string memory protocol, IMYTStrategy.RiskClass riskClass)
        external
        returns (MockMYTStrategy)
    {
        IMYTStrategy.StrategyParams memory params = IMYTStrategy.StrategyParams({
            owner: owner,
            name: name,
            protocol: protocol,
            riskClass: riskClass,
            cap: 100 ether,
            globalCap: 100 ether,
            estimatedYield: 100 ether,
            additionalIncentives: false
        });
        return new MockMYTStrategy(myt, yieldToken, params);
    }
}
