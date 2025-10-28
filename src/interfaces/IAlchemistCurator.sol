// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IAlchemistCurator {
    function increaseAbsoluteCap(address adapter, uint256 amount) external;
    function increaseRelativeCap(address adapter, uint256 amount) external;
    function submitIncreaseAbsoluteCap(address adapter, uint256 amount) external;
    function submitIncreaseRelativeCap(address adapter, uint256 amount) external;

    event IncreaseAbsoluteCap(address indexed strategy, uint256 amount, bytes indexed id);
    event SubmitIncreaseAbsoluteCap(address indexed strategy, uint256 amount, bytes indexed id);
    event IncreaseRelativeCap(address indexed strategy, uint256 amount, bytes indexed id);
    event SubmitIncreaseRelativeCap(address indexed strategy, uint256 amount, bytes indexed id);
    event OperatorChanged(address indexed operator);
    event AdminChanged(address indexed admin);

    function decreaseAbsoluteCap(address adapter, uint256 amount) external;
    function submitDecreaseAbsoluteCap(address adapter, uint256 amount) external;

    event DecreaseAbsoluteCap(address indexed strategy, uint256 amount, bytes indexed id);
    event SubmitDecreaseAbsoluteCap(address indexed strategy, uint256 amount, bytes indexed id);

    function decreaseRelativeCap(address adapter, uint256 amount) external;
    function submitDecreaseRelativeCap(address adapter, uint256 amount) external;

    event DecreaseRelativeCap(address indexed strategy, uint256 amount, bytes indexed id);
    event SubmitDecreaseRelativeCap(address indexed strategy, uint256 amount, bytes indexed id);
    event StrategySet(address indexed strategy, address indexed myt);
    event SubmitSetStrategy(address indexed strategy, address indexed myt);
    event SubmitSetAllocator(address indexed allocator, bool indexed value);
}
