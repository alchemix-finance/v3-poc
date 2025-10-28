// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {ZeroXSwapVerifier} from "../utils/ZeroXSwapVerifier.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TestERC20} from "./mocks/TestERC20.sol";
import "forge-std/console.sol";

interface Settler {
    struct Slippage {
        address payable recipient;
        address buyToken;
        uint256 minOut;
    }
    function execute(Slippage calldata slippage, bytes[] calldata actions, bytes32) external payable returns (bool);
}

contract ZeroXSwapVerifierTest is Test {
    TestERC20 internal token;
    address constant owner = address(1);
    address constant spender = address(2);

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


    function setUp() public {
        token = new TestERC20(1000e18, 18);
        deal(address(token), owner, 100e18);
        deal(address(token), spender, 100e18);
    }
    
    // Test basic sell to pool with valid slippage
    function testVerifyBasicSellToPool() public {
        bytes memory _calldata = _buildBasicSellToPoolCalldata(token, spender, 500); // 500 bps = 5% slippage
        bool verified = ZeroXSwapVerifier.verifySwapCalldata(
            _calldata,
            owner, 
            address(token), 
            1000 // 1000 bps = 10% max slippage
        );
        assertTrue(verified);
    }
    
    // Test Uniswap V3 VIP with valid slippage
    function testVerifyUniswapV3VIP() public {
        bytes memory _calldata = _buildUniswapV3VIPCalldata(token, spender, 300); // 300 bps = 3% slippage
        bool verified = ZeroXSwapVerifier.verifySwapCalldata(
            _calldata,
            owner, 
            address(token), 
            1000 // 1000 bps = 10% max slippage
        );
        assertTrue(verified);
    }
    
    // Test RFQ VIP
    function testVerifyRFQVIP() public {
        bytes memory _calldata = _buildRFQVIPCalldata(token, spender);
        bool verified = ZeroXSwapVerifier.verifySwapCalldata(
            _calldata,
            owner, 
            address(token), 
            1000 // 1000 bps = 10% max slippage
        );
        assertTrue(verified);
    }
    
    // Test transfer from
    function testVerifyTransferFrom() public {
        bytes memory _calldata = _buildTransferFromCalldata(token, spender);
        bool verified = ZeroXSwapVerifier.verifySwapCalldata(
            _calldata,
            owner, 
            address(token), 
            1000 // 1000 bps = 10% max slippage
        );
        assertTrue(verified);
    }
    
    // Test sell to liquidity provider
    function testVerifySellToLiquidityProvider() public {
        bytes memory _calldata = _buildSellToLiquidityProviderCalldata(token, spender);
        bool verified = ZeroXSwapVerifier.verifySwapCalldata(
            _calldata,
            owner, 
            address(token), 
            1000 // 1000 bps = 10% max slippage
        );
        assertTrue(verified);
    }
    
    // Test Velodrome V2 VIP with valid slippage
    function testVerifyVelodromeV2VIP() public {
        bytes memory _calldata = _buildVelodromeV2VIPCalldata(token, spender, 200); // 200 bps = 2% slippage
        bool verified = ZeroXSwapVerifier.verifySwapCalldata(
            _calldata,
            owner, 
            address(token), 
            1000 // 1000 bps = 10% max slippage
        );
        assertTrue(verified);
    }
    
    // Test unsupported action
    function testVerifyUnsupportedAction() public {
        bytes memory _calldata = _buildUnsupportedActionCalldata();
        vm.expectRevert(bytes("IAC"));
        bool verified = ZeroXSwapVerifier.verifySwapCalldata(
            _calldata,
            owner, 
            address(token), 
            1000 // 1000 bps = 10% max slippage
        );
    }
    
    // Test invalid selector
    function testVerifyInvalidSelector() public {
        bytes memory _calldata = _buildInvalidSelectorCalldata();
        vm.expectRevert(bytes("IS"));
        bool verified = ZeroXSwapVerifier.verifySwapCalldata(
            _calldata,
            owner, 
            address(token), 
            1000 // 1000 bps = 10% max slippage
        );
    }
    
    // Test token mismatch
    function testVerifyTokenMismatch() public {
        TestERC20 anotherToken = new TestERC20(1000e18, 18);
        bytes memory _calldata = _buildBasicSellToPoolCalldata(token, spender, 500);
        vm.expectRevert(bytes("IT"));
        bool verified = ZeroXSwapVerifier.verifySwapCalldata(
            _calldata,
            owner, 
            address(anotherToken), 
            1000 // 1000 bps = 10% max slippage
        );
    }
    
    // Test slippage too high
    function testVerifySlippageTooHigh() public {
        bytes memory _calldata = _buildBasicSellToPoolCalldata(token, spender, 1500); // 1500 bps = 15% slippage
        vm.expectRevert(bytes("Slippage too high"));
        bool verified = ZeroXSwapVerifier.verifySwapCalldata(
            _calldata,
            owner, 
            address(token), 
            1000 // 1000 bps = 10% max slippage
        );
    }
    
    // Test empty calldata
    function testVerifyEmptyCalldata() public {
        bytes memory _calldata = new bytes(0);
        bool verified = ZeroXSwapVerifier.verifySwapCalldata(
            _calldata,
            owner, 
            address(token), 
            1000 // 1000 bps = 10% max slippage
        );
        assertFalse(verified);
    }
    
    // Test calldata too short
    function testVerifyCalldataTooShort() public {
        bytes memory _calldata = new bytes(3);
        bool verified = ZeroXSwapVerifier.verifySwapCalldata(
            _calldata,
            owner, 
            address(token), 
            1000 // 1000 bps = 10% max slippage
        );
        assertFalse(verified);
    }
    
    // Test executeMetaTxn selector
    function testVerifyExecuteMetaTxn() public {
        bytes memory _calldata = _buildExecuteMetaTxnCalldata(token, spender, 500); // 500 bps = 5% slippage
        bool verified = ZeroXSwapVerifier.verifySwapCalldata(
            _calldata,
            owner, 
            address(token), 
            1000 // 1000 bps = 10% max slippage
        );
        assertTrue(verified);
    }
    
    // Helper functions to build calldata
    
    function _buildBasicSellToPoolCalldata(TestERC20 _token, address recipient, uint256 bps) internal pure returns (bytes memory) {
        bytes memory action = abi.encodeWithSelector(
            BASIC_SELL_TO_POOL,
            address(_token),
            bps, // bps
            recipient,
            0,
            ""
        );
        
        ZeroXSwapVerifier.SlippageAndActions memory saa = ZeroXSwapVerifier.SlippageAndActions({
            recipient: recipient,
            buyToken: address(0), // Not used in this test
            minAmountOut: 0,
            actions: new bytes[](1)
        });
        saa.actions[0] = action;
        
        return abi.encodeWithSelector(EXECUTE_SELECTOR, saa, new bytes[](0));
    }
    
    function _buildUniswapV3VIPCalldata(TestERC20 _token, address recipient, uint256 bps) internal pure returns (bytes memory) {
        bytes memory fills = abi.encode(address(_token), 100e18);
        bytes memory action = abi.encodeWithSelector(
            UNISWAPV3_VIP,
            recipient,
            bps, // bps
            3000, // feeOrTickSpacing
            false, // feeOnTransfer
            fills
        );
        
        ZeroXSwapVerifier.SlippageAndActions memory saa = ZeroXSwapVerifier.SlippageAndActions({
            recipient: recipient,
            buyToken: address(0),
            minAmountOut: 0,
            actions: new bytes[](1)
        });
        saa.actions[0] = action;
        
        return abi.encodeWithSelector(EXECUTE_SELECTOR, saa, new bytes[](0));
    }
    
    function _buildRFQVIPCalldata(TestERC20 _token, address recipient) internal pure returns (bytes memory) {
        bytes memory fillData = abi.encode(address(_token), 100e18);
        bytes memory action = abi.encodeWithSelector(
            RFQ_VIP,
            0, // info
            fillData
        );
        
        ZeroXSwapVerifier.SlippageAndActions memory saa = ZeroXSwapVerifier.SlippageAndActions({
            recipient: recipient,
            buyToken: address(0),
            minAmountOut: 0,
            actions: new bytes[](1)
        });
        saa.actions[0] = action;
        
        return abi.encodeWithSelector(EXECUTE_SELECTOR, saa, new bytes[](0));
    }
    
    function _buildTransferFromCalldata(TestERC20 _token, address recipient) internal pure returns (bytes memory) {
        bytes memory action = abi.encodeWithSelector(
            TRANSFER_FROM,
            address(_token),
            owner,
            recipient,
            100e18
        );
        
        ZeroXSwapVerifier.SlippageAndActions memory saa = ZeroXSwapVerifier.SlippageAndActions({
            recipient: recipient,
            buyToken: address(0),
            minAmountOut: 0,
            actions: new bytes[](1)
        });
        saa.actions[0] = action;
        
        return abi.encodeWithSelector(EXECUTE_SELECTOR, saa, new bytes[](0));
    }
    
    function _buildSellToLiquidityProviderCalldata(TestERC20 _token, address recipient) internal pure returns (bytes memory) {
        bytes memory action = abi.encodeWithSelector(
            SELL_TO_LIQUIDITY_PROVIDER,
            address(_token),
            recipient,
            100e18,
            0,
            ""
        );
        
        ZeroXSwapVerifier.SlippageAndActions memory saa = ZeroXSwapVerifier.SlippageAndActions({
            recipient: recipient,
            buyToken: address(0),
            minAmountOut: 0,
            actions: new bytes[](1)
        });
        saa.actions[0] = action;
        
        return abi.encodeWithSelector(EXECUTE_SELECTOR, saa, new bytes[](0));
    }
    
    function _buildVelodromeV2VIPCalldata(TestERC20 _token, address recipient, uint256 bps) internal pure returns (bytes memory) {
        bytes memory action = abi.encodeWithSelector(
            VELODROME_V2_VIP,
            address(_token),
            bps, // bps
            false, // useEth
            0, // minAmountOut
            0, // deadline
            ""
        );
        
        ZeroXSwapVerifier.SlippageAndActions memory saa = ZeroXSwapVerifier.SlippageAndActions({
            recipient: recipient,
            buyToken: address(0),
            minAmountOut: 0,
            actions: new bytes[](1)
        });
        saa.actions[0] = action;
        
        return abi.encodeWithSelector(EXECUTE_SELECTOR, saa, new bytes[](0));
    }
    
    function _buildUnsupportedActionCalldata() internal pure returns (bytes memory) {
        bytes memory action = abi.encodeWithSelector(0x12345678, address(0), 0);
        
        ZeroXSwapVerifier.SlippageAndActions memory saa = ZeroXSwapVerifier.SlippageAndActions({
            recipient: address(0),
            buyToken: address(0),
            minAmountOut: 0,
            actions: new bytes[](1)
        });
        saa.actions[0] = action;
        
        return abi.encodeWithSelector(EXECUTE_SELECTOR, saa, new bytes[](0));
    }
    
    function _buildInvalidSelectorCalldata() internal pure returns (bytes memory) {
        return abi.encodePacked(bytes4(0xffffffff));
    }
    
    function _buildExecuteMetaTxnCalldata(TestERC20 _token, address recipient, uint256 bps) internal pure returns (bytes memory) {
        bytes memory action = abi.encodeWithSelector(
            BASIC_SELL_TO_POOL,
            address(_token),
            bps, // bps
            recipient,
            0,
            ""
        );
        
        ZeroXSwapVerifier.SlippageAndActions memory saa = ZeroXSwapVerifier.SlippageAndActions({
            recipient: recipient,
            buyToken: address(0),
            minAmountOut: 0,
            actions: new bytes[](1)
        });
        saa.actions[0] = action;
        
        return abi.encodeWithSelector(
            EXECUTE_META_TXN_SELECTOR,
            saa, 
            new bytes[](0), 
            address(0), 
            ""
        );
    }

    function testCannotInjectRecipient() public {
        address victim = makeAddr("victim");
        address attacker = makeAddr("attacker");

        vm.prank(victim);
        token.approve(spender, 100e18);

        bytes memory action = abi.encodeWithSelector(
            TRANSFER_FROM,
            address(token),
            victim,
            attacker,
            100e18
        );
    
        ZeroXSwapVerifier.SlippageAndActions memory saa = ZeroXSwapVerifier.SlippageAndActions({
            recipient: address(this),
            buyToken: address(0),
            minAmountOut: 0,
            actions: new bytes[](1)
        });

        saa.actions[0] = action;
    
        bytes memory _calldata = abi.encodeWithSelector(EXECUTE_SELECTOR, saa, new bytes[](0));

        bool verified = ZeroXSwapVerifier.verifySwapCalldata(
            _calldata,
            address(this),
            address(token),
            1000
        );

        // this is a problem but only low severity if the settler rejects below
        assertEq(verified, true);

        Settler.Slippage memory slippage = Settler.Slippage(payable(address(this)), address(token), 0);

        // the settler reverts but because the action is actually ill-defined
        // we don't know wether this exploit would have went trough or not.
        Settler(0x207e1074858A7e78f17002075739eD2745dbaEce).execute{gas: 999999999999999999}(slippage, saa.actions, bytes32(0));


        assertEq(token.balanceOf(attacker), 100e18);

    }
}
