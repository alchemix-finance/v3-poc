// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.26;
pragma experimental ABIEncoderV2;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FixedPointMath} from "./FixedPointMathOld.sol";

interface IDetailedERC20 is IERC20 {
  function name() external returns (string memory);
  function symbol() external returns (string memory);
  function decimals() external returns (uint8);
}

/// @title Pool
///
/// @dev A library which provides the Pool data struct and associated functions.
library Pool {
  using FixedPointMath for FixedPointMath.FixedDecimal;
  using Pool for Pool.Data;
  using Pool for Pool.List;
  using Math for uint256;

  struct Context {
    uint256 rewardRate;
    uint256 totalRewardWeight;
  }

  struct Data {
    IERC20 token;
    uint256 totalDeposited;
    uint256 rewardWeight;
    FixedPointMath.FixedDecimal accumulatedRewardWeight;
    uint256 lastUpdatedBlock;
  }

  struct List {
    Data[] elements;
  }

  /// @dev Updates the pool.
  ///
  /// @param _ctx the pool context.
  function update(Data storage _data, Context storage _ctx) internal {
    uint256 _elapsedTime = block.number - (_data.lastUpdatedBlock);
    uint256 _distributeAmount;
    if (block.number - (_data.lastUpdatedBlock) != 0) {
      uint256 _rewardRate = _data.getRewardRate(_ctx);
      _distributeAmount = _rewardRate * (_elapsedTime);
    }

    _data.accumulatedRewardWeight = _data.getUpdatedAccumulatedRewardWeight(_ctx);

    _data.lastUpdatedBlock = block.number;
    _data.totalDeposited -= _distributeAmount;
  }

  /// @dev Gets the rate at which the pool will distribute rewards to stakers.
  ///
  /// @param _ctx the pool context.
  ///
  /// @return the reward rate of the pool in tokens per block.
  function getRewardRate(Data storage _data, Context storage _ctx)
    internal view
    returns (uint256)
  {
    return _ctx.rewardRate * (_data.rewardWeight) / (_ctx.totalRewardWeight);
  }

  /// @dev Gets the accumulated reward weight of a pool.
  ///
  /// @param _ctx the pool context.
  ///
  /// @return the accumulated reward weight.
  function getUpdatedAccumulatedRewardWeight(Data storage _data, Context storage _ctx)
    internal view
    returns (FixedPointMath.FixedDecimal memory)
  {
    if (_data.totalDeposited == 0) {
      return _data.accumulatedRewardWeight;
    }

    uint256 _elapsedTime = block.number - (_data.lastUpdatedBlock);
    if (_elapsedTime == 0) {
      return _data.accumulatedRewardWeight;
    }

    uint256 _rewardRate = _data.getRewardRate(_ctx);
    uint256 _distributeAmount = _rewardRate * (_elapsedTime);

    if (_distributeAmount == 0) {
      return _data.accumulatedRewardWeight;
    }

    FixedPointMath.FixedDecimal memory _rewardWeight = FixedPointMath.fromU256(_distributeAmount).div(_data.totalDeposited);
    return _data.accumulatedRewardWeight.add(_rewardWeight);
  }

  /// @dev Adds an element to the list.
  ///
  /// @param _element the element to add.
  function push(List storage _self, Data memory _element) internal {
    _self.elements.push(_element);
  }

  /// @dev Gets an element from the list.
  ///
  /// @param _index the index in the list.
  ///
  /// @return the element at the specified index.
  function get(List storage _self, uint256 _index) internal view returns (Data storage) {
    return _self.elements[_index];
  }

  /// @dev Gets the last element in the list.
  ///
  /// This function will revert if there are no elements in the list.
  ///ck
  /// @return the last element in the list.
  function last(List storage _self) internal view returns (Data storage) {
    return _self.elements[_self.lastIndex()];
  }

  /// @dev Gets the index of the last element in the list.
  ///
  /// This function will revert if there are no elements in the list.
  ///
  /// @return the index of the last element.
  function lastIndex(List storage _self) internal view returns (uint256) {
    uint256 _length = _self.length();
    return _length - 1;
  }

  /// @dev Gets the number of elements in the list.
  ///
  /// @return the number of elements.
  function length(List storage _self) internal view returns (uint256) {
    return _self.elements.length;
  }
}