pragma solidity 0.8.26;

import {SafeCast} from "./SafeCast.sol";

library StakingGraph {
    using SafeCast for int256;

    // TODO: Add block params to make queries and upates less costly and remove hardcoded loop value from _update
    function updateStakingGraph(mapping(uint256 => int256) storage graph, int256 amount, uint256 blocks) public {
        uint256 currentBlock = block.number;
        uint256 expirationBlock = currentBlock + blocks;

        _update(graph, currentBlock, amount);
        _update(graph, expirationBlock, -amount);
    }

    function currentStaked(mapping(uint256 => int256) storage graph, uint256 blockNumber) public view returns (uint256) {
        return _query(graph, blockNumber).toUint256();
    }

    function rangeQuery(mapping(uint256 => int256) storage graph, uint256 l, uint256 r) public view returns (uint256) {
        return (_query(graph, r) - _query(graph, l - 1)).toUint256();
    }

    function _update(mapping(uint256 => int256) storage graph, uint256 index, int256 delta) internal {
        index += 1;        
        // TODO: Update this to reflect total size we want to update over. 
        // Using max size here will run out of gas
        // For now we use 20 years
        while (index <= 630720000) {
            graph[index] += delta;

            assembly {
                index := add(index, and(index, sub(0, index)))
            }
        }
    }

    function _query(mapping(uint256 => int256) storage graph, uint256 index) internal view returns (int256 sum) {
        index += 1;
        while (index > 0) {
            sum += graph[index];

            assembly {
                index := sub(index, and(index, sub(0, index)))
            }        
        }
    }
}