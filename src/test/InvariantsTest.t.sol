// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../libraries/TokenUtils.sol";
import "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "../../lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "../libraries/SafeCast.sol";
import "../../lib/forge-std/src/Test.sol";
import {SafeERC20} from "../libraries/SafeERC20.sol";
import {console} from "../../lib/forge-std/src/console.sol";
import {AlchemistV3} from "../AlchemistV3.sol";
import {AlchemicTokenV3} from "../test/mocks/AlchemicTokenV3.sol";
import {Transmuter} from "../Transmuter.sol";
import {Whitelist} from "../utils/Whitelist.sol";
import {TestERC20} from "./mocks/TestERC20.sol";
import {TestYieldToken} from "./mocks/TestYieldToken.sol";
import {TokenAdapterMock} from "./mocks/TokenAdapterMock.sol";
import {IAlchemistV3, IAlchemistV3Errors, AlchemistInitializationParams} from "../interfaces/IAlchemistV3.sol";
import {ITransmuter} from "../interfaces/ITransmuter.sol";
import {ITestYieldToken} from "../interfaces/test/ITestYieldToken.sol";
import {InsufficientAllowance} from "../base/Errors.sol";
import {Unauthorized, IllegalArgument, IllegalState, MissingInputData} from "../base/Errors.sol";
import {AlchemistNFTHelper} from "./libraries/AlchemistNFTHelper.sol";
import {AlchemistV3Position} from "../AlchemistV3Position.sol";
import {AlchemistETHVault} from "../AlchemistETHVault.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";

contract InvariantsTest is Test {
    bytes4[] internal selectors;

    // Callable contract variables
    AlchemistV3 alchemist;
    Transmuter transmuter;
    AlchemistV3Position alchemistNFT;
    AlchemistETHVault ethVault;

    // // Proxy variables
    TransparentUpgradeableProxy proxyAlchemist;
    TransparentUpgradeableProxy proxyTransmuter;

    // // Contract variables
    // CheatCodes cheats = CheatCodes(HEVM_ADDRESS);
    AlchemistV3 alchemistLogic;
    Transmuter transmuterLogic;
    AlchemicTokenV3 alToken;
    Whitelist whitelist;

    // Token addresses
    TestERC20 fakeUnderlyingToken;
    TestYieldToken fakeYieldToken;

    // Total minted debt
    uint256 public minted;

    // Total debt burned
    uint256 public burned;

    // Total tokens sent to transmuter
    uint256 public sentToTransmuter;

    // Parameters for AlchemicTokenV2
    string public _name;
    string public _symbol;
    uint256 public _flashFee;
    address public alOwner;

    /*     mapping(address => bool) users;
    */
    uint256 public constant FIXED_POINT_SCALAR = 1e18;
    address ETH_USD_PRICE_FEED_MAINNET = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    uint256 ETH_USD_UPDATE_TIME_MAINNET = 3600 seconds;

    uint256 public minimumCollateralization = uint256(FIXED_POINT_SCALAR * FIXED_POINT_SCALAR) / 9e17;

    // ----- Variables for deposits & withdrawals -----

    // account funds to make deposits/test with
    uint256 accountFunds = 2_000_000_000e18;

    // large amount to test with
    uint256 whaleSupply = 20_000_000_000e18;

    // amount of yield/underlying token to deposit
    uint256 depositAmount = 100_000e18;

    // minimum amount of yield/underlying token to deposit
    uint256 minimumDeposit = 1000e18;

    // minimum amount of yield/underlying token to deposit
    uint256 minimumDepositOrWithdrawalLoss = FIXED_POINT_SCALAR;

    // random EOA for testing
    address externalUser = address(0x69E8cE9bFc01AA33cD2d02Ed91c72224481Fa420);

    // another random EOA for testing
    address anotherExternalUser = address(0x420Ab24368E5bA8b727E9B8aB967073Ff9316969);

    // another random EOA for testing
    address yetAnotherExternalUser = address(0x520aB24368e5Ba8B727E9b8aB967073Ff9316961);

    // another random EOA for testing
    address someWhale = address(0x521aB24368E5Ba8b727e9b8AB967073fF9316961);

    function setUp() public virtual {
        // test maniplulation for convenience
        address caller = address(0xdead);
        address proxyOwner = address(this);
        vm.assume(caller != address(0));
        vm.assume(proxyOwner != address(0));
        vm.assume(caller != proxyOwner);
        vm.startPrank(caller);

        // Fake tokens

        fakeUnderlyingToken = new TestERC20(100e18, uint8(18));
        fakeYieldToken = new TestYieldToken(address(fakeUnderlyingToken));
        alToken = new AlchemicTokenV3(_name, _symbol, _flashFee);

        ITransmuter.TransmuterInitializationParams memory transParams = ITransmuter.TransmuterInitializationParams({
            syntheticToken: address(alToken),
            feeReceiver: address(this),
            timeToTransmute: 5_256_000,
            transmutationFee: 10,
            exitFee: 20,
            graphSize: 52_560_000
        });

        // Contracts and logic contracts
        alOwner = caller;
        transmuterLogic = new Transmuter(transParams);
        alchemistLogic = new AlchemistV3();
        whitelist = new Whitelist();

        // // Proxy contracts
        // // TransmuterBuffer proxy
        // bytes memory transBufParams = abi.encodeWithSelector(TransmuterBuffer.initialize.selector, alOwner, address(alToken));

        // proxyTransmuterBuffer = new TransparentUpgradeableProxy(address(transmuterBufferLogic), proxyOwner, transBufParams);

        // transmuterBuffer = TransmuterBuffer(address(proxyTransmuterBuffer));

        // TransmuterV3 proxy
        // bytes memory transParams = abi.encodeWithSelector(TransmuterV3.initialize.selector, address(alToken), fakeUnderlyingToken, address(transmuterBuffer));

        // proxyTransmuter = new TransparentUpgradeableProxy(address(transmuterLogic), proxyOwner, transParams);
        // transmuter = TransmuterV3(address(proxyTransmuter));

        // AlchemistV3 proxy
        AlchemistInitializationParams memory params = AlchemistInitializationParams({
            admin: alOwner,
            debtToken: address(alToken),
            underlyingToken: address(fakeUnderlyingToken),
            yieldToken: address(fakeYieldToken),
            depositCap: type(uint256).max,
            blocksPerYear: 2_600_000,
            minimumCollateralization: minimumCollateralization,
            collateralizationLowerBound: 1_052_631_578_950_000_000, // 1.05 collateralization
            globalMinimumCollateralization: 1_111_111_111_111_111_111, // 1.1
            tokenAdapter: address(fakeYieldToken),
            transmuter: address(transmuterLogic),
            protocolFee: 0,
            protocolFeeReceiver: address(10),
            liquidatorFee: 300 // in bps? 3%
        });

        bytes memory alchemParams = abi.encodeWithSelector(AlchemistV3.initialize.selector, params);
        proxyAlchemist = new TransparentUpgradeableProxy(address(alchemistLogic), proxyOwner, alchemParams);
        alchemist = AlchemistV3(address(proxyAlchemist));

        // Whitelist alchemist proxy for minting tokens
        alToken.setWhitelist(address(proxyAlchemist), true);

        whitelist.add(address(0xbeef));
        whitelist.add(externalUser);
        whitelist.add(anotherExternalUser);

        transmuterLogic.setAlchemist(address(alchemist));
        transmuterLogic.setDepositCap(uint256(type(int256).max));
        alchemistNFT = new AlchemistV3Position(address(alchemist));
        alchemist.setAlchemistPositionNFT(address(alchemistNFT));

        vm.stopPrank();

        _targetSenders();

        targetContract(address(this));
        targetSelector(FuzzSelector({addr: address(this), selectors: selectors}));
    }

    modifier logCall(string memory name) {
        console2.log(msg.sender, "->", name);

        _;
    }

    function _targetSenders() internal virtual {
        _targetSender(makeAddr("Sender1"));
        _targetSender(makeAddr("Sender2"));
        _targetSender(makeAddr("Sender3"));
        _targetSender(makeAddr("Sender4"));
        _targetSender(makeAddr("Sender5"));
        _targetSender(makeAddr("Sender6"));
        _targetSender(makeAddr("Sender7"));
        _targetSender(makeAddr("Sender8"));
    }

    function _targetSender(address sender) internal {
        targetSender(sender);

        vm.prank(address(0xdead));
        alToken.setWhitelist(sender, true);

        vm.startPrank(sender);
        TokenUtils.safeApprove(address(alToken), address(alchemist), type(uint256).max);
        TokenUtils.safeApprove(address(fakeYieldToken), address(alchemist), type(uint256).max);
        vm.stopPrank();
    }

    /* HANDLERS */

    function mine(uint256 blocks) external {
        blocks = bound(blocks, 1, 72_000);

        console2.log("block number ->", block.number + blocks);

        vm.roll(block.number + blocks);
    }

    /* UTILS */

    function _randomDepositor(address[] memory users, uint256 seed) internal pure returns (address) {
        return _randomNonZero(users, seed);
    }

    function _randomWithdrawer(address[] memory users, uint256 seed) internal view returns (address) {
        address[] memory candidates = new address[](users.length);

        for (uint256 i; i < users.length; ++i) {
            address user = users[i];

            // a single position nft would have been minted to address(0xbeef)
            uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(user, address(alchemistNFT));

            uint256 borrowable;

            if (tokenId != 0) borrowable = alchemist.getMaxBorrowable(tokenId);

            if (borrowable > 0) {
                candidates[i] = user;
            }
        }

        return _randomNonZero(users, seed);
    }

    function _randomMinter(address[] memory users, uint256 seed) internal view returns (address) {
        address[] memory candidates = new address[](users.length);

        for (uint256 i; i < users.length; ++i) {
            address user = users[i];
            // a single position nft would have been minted to address(0xbeef)
            uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(user, address(alchemistNFT));

            uint256 borrowable;

            if (tokenId != 0) alchemist.getMaxBorrowable(tokenId);

            if (borrowable > 0) {
                candidates[i] = user;
            }
        }

        return _randomNonZero(candidates, seed);
    }

    function _randomRepayer(address[] memory users, uint256 seed) internal view returns (address) {
        address[] memory candidates = new address[](users.length);

        for (uint256 i; i < users.length; ++i) {
            address user = users[i];
            // a single position nft would have been minted to address(0xbeef)
            uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(user, address(alchemistNFT));
            uint256 collateral;
            uint256 debt;

            if (tokenId != 0) (collateral, debt,) = alchemist.getCDP(tokenId);

            if (debt > 0) {
                candidates[i] = user;
            }
        }

        return _randomNonZero(candidates, seed);
    }

    function _randomBurner(address[] memory users, uint256 seed) internal view returns (address) {
        address[] memory candidates = new address[](users.length);

        for (uint256 i; i < users.length; ++i) {
            address user = users[i];
            // a single position nft would have been minted to address(0xbeef)
            uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(user, address(alchemistNFT));

            uint256 collateral;
            uint256 debt;
            uint256 earmarked;

            if (tokenId != 0) (collateral, debt, earmarked) = alchemist.getCDP(tokenId);

            if (debt > 0 && debt > earmarked) {
                candidates[i] = user;
            }
        }

        return _randomNonZero(candidates, seed);
    }

    function _randomStaker(address[] memory users, uint256 seed) internal pure returns (address) {
        return _randomNonZero(users, seed);
    }

    function _randomNonZero(address[] memory users, uint256 seed) internal pure returns (address) {
        users = _removeAll(users, address(0));

        return _randomCandidate(users, seed);
    }

    function _randomCandidate(address[] memory candidates, uint256 seed) internal pure returns (address) {
        if (candidates.length == 0) return address(0);

        return candidates[seed % candidates.length];
    }

    function _removeAll(address[] memory inputs, address removed) internal pure returns (address[] memory result) {
        result = new address[](inputs.length);

        uint256 nbAddresses;
        for (uint256 i; i < inputs.length; ++i) {
            address input = inputs[i];

            if (input != removed) {
                result[nbAddresses] = input;
                ++nbAddresses;
            }
        }

        assembly {
            mstore(result, nbAddresses)
        }
    }
}
