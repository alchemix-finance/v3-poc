pragma solidity 0.8.26;

import {SafeCast} from "./SafeCast.sol";

library StakingGraph {
    function update(mapping(uint256 => int256) storage graph, uint256 index, uint256 n, int256 delta) internal {
        index += 1;
        while (index <= n) {
            graph[index] += delta;

            assembly {
                index := add(index, and(index, sub(0, index)))
            }
        }
    }

    function query(mapping(uint256 => int256) storage graph, uint256 index) internal view returns (int256 sum) {
        index += 1;
        while (index > 0) {
            sum += graph[index];

            assembly {
                index := sub(index, and(index, sub(0, index)))
            }
        }
    }
}
