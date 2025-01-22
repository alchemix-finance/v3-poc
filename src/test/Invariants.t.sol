// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "../../../lib/forge-std/src/Test.sol";

import "../../lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {AlEth} from "../external/AlETH.sol";
import {AlchemistV3} from "../AlchemistV3.sol";
import {AlchemicTokenV3} from "../AlchemicTokenV3.sol";
import {AlchemistHandler} from "./handlers/AlchemistHandler.sol";
import {Transmuter} from "../Transmuter.sol";
import {TransmuterBuffer} from "../TransmuterBuffer.sol";
import {TransmuterHandler} from "./handlers/Transmuterhandler.sol";
import {Whitelist} from "../utils/Whitelist.sol";
import {IAlchemistV3, IAlchemistV3State} from "../interfaces/IAlchemistV3.sol";
import {ITransmuter} from "../interfaces/ITransmuter.sol";
import {SafeERC20} from "../libraries/SafeERC20.sol";
import {ITransmuter} from "../interfaces/ITransmuter.sol";

import "../interfaces/IYearnVaultV2.sol";
import "../interfaces/ITokenAdapter.sol";
import "../adapters/YearnTokenAdapter.sol";

contract InvariantTests is Test {
    AlchemistHandler public alchemistHandler;
    TransmuterHandler public transmuterHandler;

    // Callable contract variables
    AlchemistV3 alchemist;
    Transmuter transmuter;
    TransmuterBuffer transmuterBuffer;

    // // Proxy variables
    TransparentUpgradeableProxy proxyAlchemist;
    TransparentUpgradeableProxy proxyTransmuter;
    TransparentUpgradeableProxy proxyTransmuterBuffer;

    // // Contract variables
    // CheatCodes cheats = CheatCodes(HEVM_ADDRESS);
    AlchemistV3 alchemistLogic;
    Transmuter transmuterLogic;
    TransmuterBuffer transmuterBufferLogic;
    AlchemicTokenV3 alToken;
    Whitelist whitelist;

    // Token addresses
    address fakeUnderlyingToken;
    address fakeYieldToken;
    IERC20 constant dai = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    IERC20 constant yvDai = IERC20(0xdA816459F1AB5631232FE5e97a05BBBb94970c95);

    // Total minted debt
    uint256 public minted;

    // Total debt burned
    uint256 public burned;

    // Token adapter
    ITokenAdapter tokenAdapter;

    // Total tokens sent to transmuter
    uint256 public sentToTransmuter;

    // Parameters for AlchemicTokenV2
    string public _name;
    string public _symbol;
    uint256 public _flashFee;
    address public alOwner;

    mapping(address => bool) users;

    // minimumCollateralization
    uint256 public minimumCollateralization = 9 * 1e17; // .9

    uint256 public constant FIXED_POINT_SCALAR = 1e18;

    // ----- Variables for deposits & withdrawals -----

    // account funds to make deposits/test with
    uint256 accountFunds = 2_000_000_000e18;

    // amount of yield/underlying token to deposit
    uint256 depositAmount = 100_000e18;

    // minimum amount of yield/underlying token to deposit
    uint256 minimumDeposit = 1000e18;

    // minimum amount of yield/underlying token to deposit
    uint256 minimumDepositOrWithdrawalLoss = 1e18;

    // random EOA for testing
    address externalUser = address(0x69E8cE9bFc01AA33cD2d02Ed91c72224481Fa420);

    // another random EOA for testing
    address anotherExternalUser = address(0x420Ab24368E5bA8b727E9B8aB967073Ff9316969);

    // TODO: extend this
    address[] userList = [address(0x123), address(0x234)];

    function setUp() public {
        // TODO: Multi alchemist set up

        address caller = address(0xdead);
        address proxyOwner = address(this);

        fakeUnderlyingToken = address(dai);
        fakeYieldToken = address(yvDai);

        // Contracts and logic contracts
        alOwner = caller;
        alToken = new AlchemicTokenV3(_name, _symbol, _flashFee);
        transmuterBufferLogic = new TransmuterBuffer();
        // transmuterLogic = new Transmuter();
        alchemistLogic = new AlchemistV3();
        whitelist = new Whitelist();

        alchemist = new AlchemistV3();
        alchemistHandler = new AlchemistHandler(alchemist);
        transmuterHandler = new TransmuterHandler(transmuter);

        // place holder
        tokenAdapter = new YearnTokenAdapter(fakeYieldToken, fakeUnderlyingToken);

        // TODO make intitializeable transmuter
        // TransmuterV3 proxy
        // bytes memory transParams = abi.encodeWithSelector(Transmuter.initialize.selector, address(alToken), fakeUnderlyingToken);

        // proxyTransmuter = new TransparentUpgradeableProxy(address(transmuterLogic), proxyOwner, transParams);
        transmuter = new Transmuter(ITransmuter.InitializationParams(address(alToken), 30 days, 0, 0));

        // AlchemistV3 proxy
        IAlchemistV3State.InitializationParams memory params = IAlchemistV3State.InitializationParams({
            admin: alOwner,
            yieldToken: fakeYieldToken,
            debtToken: address(alToken),
            underlyingToken: address(fakeUnderlyingToken),
            adapter: address(tokenAdapter),
            transmuter: address(transmuter),
            LTV: 9e17,
            minimumCollateralization: minimumCollateralization,
            protocolFee: 1000,
            protocolFeeReceiver: address(10),
            liquidatorFee: 1000, // in bps?
            mintingLimitMinimum: 1,
            mintingLimitMaximum: uint256(type(uint160).max),
            mintingLimitBlocks: 300
        });

        bytes memory alchemParams = abi.encodeWithSelector(AlchemistV3.initialize.selector, params);
        proxyAlchemist = new TransparentUpgradeableProxy(address(alchemistLogic), proxyOwner, alchemParams);
        alchemist = AlchemistV3(address(proxyAlchemist));

        // Whitelist alchemist proxy for minting tokens
        alToken.setWhitelist(address(proxyAlchemist), true);

        whitelist.add(address(0xbeef));
        whitelist.add(externalUser);
        whitelist.add(anotherExternalUser);

        vm.stopPrank();

        // Add funds to test accounts
        deal(address(fakeYieldToken), address(0xbeef), accountFunds);
        deal(address(fakeYieldToken), externalUser, accountFunds);
        deal(address(fakeUnderlyingToken), anotherExternalUser, accountFunds);
        deal(address(fakeUnderlyingToken), address(0xbeef), accountFunds);

        vm.startPrank(anotherExternalUser);

        SafeERC20.safeApprove(address(fakeUnderlyingToken), address(fakeYieldToken), accountFunds);

        // faking initial token vault supply
        // ITestYieldToken(address(fakeYieldToken)).mint(15_000_000e18, anotherExternalUser);

        vm.stopPrank();

        // TODO: Deal tokens to this contract which will be used by the handlers to create positions
        // Give max_int allowance for AlEth and other colateral assets to the handlers so they can create and manage positions

        // Set up for contract handlers

        targetContract(address(transmuterHandler));
        targetContract(address(alchemist));

        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = TransmuterHandler.claimRedemption.selector;
        selectors[1] = TransmuterHandler.createRedemption.selector;

        targetSelector(FuzzSelector({addr: address(transmuterHandler), selectors: selectors}));

        selectors = new bytes4[](6);
        selectors[0] = AlchemistHandler.deposit.selector;
        selectors[1] = AlchemistHandler.withdraw.selector;
        selectors[2] = AlchemistHandler.mint.selector;
        selectors[3] = AlchemistHandler.repay.selector;
        selectors[4] = AlchemistHandler.liquidate.selector;
        selectors[5] = AlchemistHandler.repay.selector;

        targetSelector(FuzzSelector({addr: address(alchemistHandler), selectors: selectors}));
    }

    // The system cannot take more from the user than they earn
    // Therefore the redemption fee cannot exceed yield rate for all Alchemists
    function invariant_redemption_fee() public {
        // This is pending a concrete way to determine yield rate
        // Are we using a specific yield token per alchemist
        // Are we creating an external vault where we manage yield and give our own yield token to deposit into the alchemist
    }

    // The balance of synthetics staked into the transmuter cannot exceed the total debt minted
    // This is equal to the total minted alAssets
    function invariant_transmuter_synthetic_balance() public {
        assertLe(alToken.balanceOf(address(transmuter)), IERC20(address(alToken)).totalSupply());
    }

    // The total number of shares must be equal to the sum of all shares in user CDPs
    function invariant_consistent_shares() public {
        uint256 totalBalance;
        uint256 balance;
        uint256 userShares;

        // Once alchemist getCDP function is complete we can uncomment this
        for (uint256 i = 0; i < userList.length; i++) {
            // (balance, ) = alchemist.getCDP(userList[i], address(fakeYieldToken));
            // userShares += balance;
        }

        totalBalance = alchemist.getTotalDeposited();

        assertEq(userShares, totalBalance);
    }

    // // Every alchemist CDP must be updated properly when redeem is called
    // // Redeem will cause the users debts to update based on redemption rate
    // // TODO: update this once redemption system is coded fully
    // function invariant_redeem_user_cdp () public {
    //     uint256 totalDebtBefore;
    //     uint256 balance;
    //     uint256 debt;
    //     uint256 userShares;

    //     // Once alchemist getCDP function is complete we can uncomment this
    //     for (uint256 i = 0; i < userList.length; i++) {
    // 		// (balance, debt) = alchemist.getCDP(userList[i], address(fakeYieldToken));
    // 		// totalDebtBefore += debt;
    // 	}

    //     vm.roll(block.number + 3000);

    //     // alchemist.redeem();

    //     uint256 totalDebtAfter;

    //     for (uint256 i = 0; i < userList.length; i++) {
    // 		// (balance, debt) = alchemist.getCDP(userList[i], address(fakeYieldToken));
    // 		// totalDebtAfter += debt;
    // 	}

    //     // Sum of debt before with redemption rate applied over time compared to current sum of user debt
    //     assertEq(totalDebtBefore - (totalDebtBefore * (transmuter.redemptionRate() * 3000)), totalDebtAfter);
    // }
}
