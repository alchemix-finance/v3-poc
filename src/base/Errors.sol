pragma solidity ^0.8.23;

/// @notice An error used to indicate that an action could not be completed because either the `msg.sender` or
///         `msg.origin` is not authorized.
error Unauthorized();

/// @notice An error used to indicate that an action could not be completed because the contract either already existed
///         or entered an illegal condition which is not recoverable from.
error IllegalState();

/// @notice An error used to indicate that an action could not be completed because of an illegal argument was passed
///         to the function.
error IllegalArgument();

/// @notice An error used to indicate that an action could not be completed because the required amount of allowance has not
///         been approved.
error InsufficientAllowance();

/// @notice An error used to indicate that the function input data is missing
error MissingInputData();

/// @notice An error used to indicate that the function input data is missing
error ZeroAmount();

/// @notice An error used to indicate that the function input data is missing
error ZeroAddress();
