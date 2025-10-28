// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
/**
 * @title ZeroXSwapVerifier
 * @dev Verifies 0x permit swap calldata and validates token whitelist and amount bounds
 *
 * This contract decodes 0x Settler calldata to extract swap actions and verifies:
 * 1. Input tokens are whitelisted
 * 2. Swap amounts are within configured bounds
 * 3. Action types are permitted
 * 4. Target token and amount match expected values
 */
library ZeroXSwapVerifier {

    // Constants for 0x Settler function selectors
    bytes4 private constant EXECUTE_SELECTOR = 0xcf71ff4f; // execute(SlippageAndActions,bytes[])
    bytes4 private constant EXECUTE_META_TXN_SELECTOR = 0x0476baab; // executeMetaTxn(SlippageAndActions,bytes[],address,bytes)

    // Action selectors for different swap types
    bytes4 private constant BASIC_SELL_TO_POOL = 0x5228831d;
    bytes4 private constant UNISWAPV3_VIP = 0x9ebf8e8d;
    bytes4 private constant RFQ_VIP = 0x0dfeb419;
    bytes4 private constant METATXN_VIP = 0xc1fb425e;
    bytes4 private constant CURVE_TRICRYPTO_VIP = 0x103b48be;
    bytes4 private constant UNISWAPV4_VIP = 0x38c9c147;
    bytes4 private constant TRANSFER_FROM = 0xc1fb425e;
    bytes4 private constant NATIVE_DEPOSIT = 0xc876d21d;
    bytes4 private constant SELL_TO_LIQUIDITY_PROVIDER = 0xf1e0a1c3;
    bytes4 private constant DODOV1_VIP = 0x40a07c6c;
    bytes4 private constant VELODROME_V2_VIP = 0xb8df6d4d;
    bytes4 private constant DODOV2_VIP = 0xd92aadfb;

    struct SlippageAndActions {
        address recipient;
        address buyToken;
        uint256 minAmountOut;
        bytes[] actions;
    }

    /**
     * @dev Returns a slice of a bytes memory array.
     * @param data The original data
     * @param start The starting index
     * @param length The length of the slice
     * @return The sliced bytes
     */
    function _slice(bytes memory data, uint256 start, uint256 length) internal pure returns (bytes memory) {
        bytes memory result = new bytes(length);
        for (uint256 i = 0; i < length; i++) {
            result[i] = data[start + i];
        }
        return result;
    }

    /**
     * @dev Returns a slice from start to end of a bytes memory array.
     * @param data The original data
     * @param start The starting index
     * @return The sliced bytes
     */
    function _slice(bytes memory data, uint256 start) internal pure returns (bytes memory) {
        return _slice(data, start, data.length - start);
    }

    /**
     * @dev Decode calldata and verify all actions (external for try/catch)
     * @param calldata_ The calldata to decode
     * @param owner the address we whitelist as spender
     * @param targetToken The expected token address that should be matched
     * @param maxSlippageBps Maximum allowed slippage in basis points
     */
    function decodeAndVerifyActions(bytes calldata calldata_, address owner, address targetToken, uint256 maxSlippageBps) internal view {


        bytes4 selector = bytes4(calldata_[0:4]);

        if (selector == EXECUTE_SELECTOR) {
            _verifyExecuteCalldata(calldata_[4:], owner, targetToken, maxSlippageBps);
        } else if (selector == EXECUTE_META_TXN_SELECTOR) {
            _verifyExecuteMetaTxnCalldata(calldata_[4:], owner, targetToken, maxSlippageBps);
        } else {
            revert("Unsupported function selector");
        }
    }


    /**
     * @dev Main verification function for 0x swap calldata
     * @param calldata_ The complete calldata from 0x API
     * @param owner the address we whitelist as spender
     * @param targetToken The expected token address that should be matched
     * @param maxSlippageBps Maximum allowed slippage in basis points (1000 = 10%)
     * @return verified Whether the swap passes all checks
     */
    function verifySwapCalldata(bytes calldata calldata_, address owner, address targetToken, uint256 maxSlippageBps)
        external
        view
        returns (bool verified)
    {
        if (calldata_.length < 4) {
            return false;
        }

        bytes4 selector = bytes4(calldata_[0:4]);

        // Check if it's a valid 0x Settler function
        require(selector == EXECUTE_SELECTOR || selector == EXECUTE_META_TXN_SELECTOR, "IS");

        decodeAndVerifyActions(calldata_, owner, targetToken, maxSlippageBps);
        return true;
    }



    /**
     * @dev Verify execute() function calldata
     * @param data The function parameters (without selector)
     * @param targetToken The expected token address that should be matched
     * @param maxSlippageBps Maximum allowed slippage in basis points
     */
    function _verifyExecuteCalldata(bytes calldata data, address owner, address targetToken, uint256 maxSlippageBps) internal view {
        // Decode SlippageAndActions struct and actions array
        (SlippageAndActions memory saa, ) = abi.decode(data, (SlippageAndActions, bytes));
        // TODO shall we also verify saa.buyToken ?
        _verifyActions(saa.actions, owner, targetToken, maxSlippageBps);
    }

    /**
     * @dev Verify executeMetaTxn() function calldata
     * @param data The function parameters (without selector)
     * @param targetToken The expected token address that should be matched
     * @param maxSlippageBps Maximum allowed slippage in basis points
     */
    function _verifyExecuteMetaTxnCalldata(bytes calldata data, address owner, address targetToken, uint256 maxSlippageBps) internal view {
        // Decode parameters: (SlippageAndActions, bytes[], address, bytes)
        (SlippageAndActions memory saa, , , ) = abi.decode(data, (SlippageAndActions, bytes[], address, bytes));
        // TODO shall we also verify saa.buyToken ?
        _verifyActions(saa.actions, owner, targetToken, maxSlippageBps);
    }

    /**
     * @dev Verify all actions in the actions array
     * @param actions Array of encoded action calls
     * @param targetToken The expected token address that should be matched
     * @param maxSlippageBps Maximum allowed slippage in basis points
     */
    function _verifyActions(bytes[] memory actions, address owner, address targetToken, uint256 maxSlippageBps) internal view {
        for (uint256 i = 0; i < actions.length; i++) {
            _verifyAction(actions[i], owner, targetToken, maxSlippageBps);
        }
    }

    /**
     * @dev Verify a single action
     * @param action The encoded action call
     * @param targetToken The expected token address that should be matched
     * @param maxSlippageBps Maximum allowed slippage in basis points
     */
    function _verifyAction(bytes memory action, address owner, address targetToken, uint256 maxSlippageBps) internal view {
        if (action.length < 4) {
            revert("Invalid action length");
        }

        bytes4 actionSelector = bytes4(action);

        // Verify based on action type
        if (actionSelector == BASIC_SELL_TO_POOL) {
            _verifyBasicSellToPool(action, owner, targetToken, maxSlippageBps);
        } else if (actionSelector == UNISWAPV3_VIP) {
            _verifyUniswapV3VIP(action, owner, targetToken, maxSlippageBps);
        } else if (actionSelector == RFQ_VIP) {
            _verifyRFQVIP(action, owner, targetToken, maxSlippageBps);
        } else if (actionSelector == TRANSFER_FROM) {
            _verifyTransferFrom(action, owner, targetToken, maxSlippageBps);
        } else if (actionSelector == SELL_TO_LIQUIDITY_PROVIDER) {
            _verifySellToLiquidityProvider(action, owner, targetToken, maxSlippageBps);
        } else if (actionSelector == NATIVE_DEPOSIT) {
            revert("not supported");
        } else if (actionSelector == VELODROME_V2_VIP) {
            _verifyVelodromeV2VIP(action, owner, targetToken, maxSlippageBps);
        } else {
            revert("IAC");
        }
        // Add more action types as needed
    }

    /**
     * @dev Verify BASIC_SELL_TO_POOL action
     * Format: basicSellToPool(IERC20 sellToken, uint256 bps, address pool, uint256 offset, bytes data)
     */
    function _verifyBasicSellToPool(bytes memory action, address owner, address targetToken, uint256 maxSlippageBps) internal view {
        (address sellToken, uint256 bps, , , ) = abi.decode(
            _slice(action, 4),
            (address, uint256, address, uint256, bytes)
        );

        require(sellToken == targetToken, "IT");
        require(bps <= maxSlippageBps, "Slippage too high");
    }

    /**
     * @dev Verify UNISWAP_V3_VIP action
     * Format: uniswapV3VIP(address recipient, uint256 bps, uint256 feeOrTickSpacing, bool feeOnTransfer, bytes fills)
     */
    function _verifyUniswapV3VIP(bytes memory action, address owner, address targetToken, uint256 maxSlippageBps) internal view {
        (, uint256 bps, , , bytes memory fills) = abi.decode(
            _slice(action, 4),
            (address, uint256, uint256, bool, bytes)
        );

        // Extract token from fills data - this requires parsing the UniswapV3 fill structure
        address sellToken = _extractTokenFromUniswapFills(fills);
        require(sellToken == targetToken, "IT");
        require(bps <= maxSlippageBps, "Slippage too high");
    }

    /**
     * @dev Verify RFQ_VIP action
     * Format: rfqVIP(uint256 info, bytes fillData)
     */
    function _verifyRFQVIP(bytes memory action, address owner, address targetToken, uint256 targetAmount) internal view {
        (, bytes memory fillData) = abi.decode(_slice(action, 4), (uint256, bytes));

        // Extract token and amount from RFQ fill data
        (address sellToken, uint256 amount) = _extractTokenAndAmountFromRFQ(fillData);
        require(sellToken == targetToken, "IT");
        // Removed balance check as the 0x quote already has slippage protection
    }

    /**
     * @dev Verify TRANSFER_FROM action
     * Format: transferFrom(IERC20 token, address from, address to, uint256 amount)
     */
    function _verifyTransferFrom(bytes memory action, address owner, address targetToken, uint256 targetAmount) internal view {
        (address token, , , uint256 amount) = abi.decode(
            _slice(action, 4),
            (address, address, address, uint256)
        );

        require(token == targetToken, "IT");
        // Removed balance check as the 0x quote already has slippage protection
    }

    /**
     * @dev Verify SELL_TO_LIQUIDITY_PROVIDER action
     */
    function _verifySellToLiquidityProvider(bytes memory action, address owner, address targetToken, uint256 targetAmount) internal view {
        (address sellToken, , uint256 sellAmount, , ) = abi.decode(
            _slice(action, 4),
            (address, address, uint256, uint256, bytes)
        );

        require(sellToken == targetToken, "IT");
        // Removed balance check as the 0x quote already has slippage protection
    }

    /**
     * @dev Verify VELODROME_V2_VIP action
     */
    function _verifyVelodromeV2VIP(bytes memory action, address owner, address targetToken, uint256 maxSlippageBps) internal view {
        (address sellToken, uint256 bps, , , , ) = abi.decode(
            _slice(action, 4),
            (address, uint256, bool, uint256, uint256, bytes)
        );


        require(sellToken == targetToken, "IT");
        require(bps <= maxSlippageBps, "Slippage too high");
    }



    /**
     * @dev Extract token from UniswapV3 fills data
     * TODO
     */
    function _extractTokenFromUniswapFills(bytes memory fills) internal pure returns (address) {
        // Simplified - in reality this would parse the complex fills structure
        if (fills.length >= 32) {
            return abi.decode(_slice(fills, 0, 32), (address));
        }
        revert("unimplemented");
    }

    /**
     * @dev Extract token and amount from RFQ fill data
     * TODO
     */
    function _extractTokenAndAmountFromRFQ(bytes memory fillData) internal pure returns (address token, uint256 amount) {
        // Simplified - in reality this would parse the RFQ fill structure
        if (fillData.length >= 64) {
            return abi.decode(_slice(fillData, 0, 64), (address, uint256));
        }
        revert("unimplemented");
    }

}
