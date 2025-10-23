// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import "../src/Transmuter.sol";
import "../src/interfaces/ITransmuter.sol";
// Nota: NO importamos IAlchemistV3 para el mock, pero sí respetamos las firmas que Transmuter invoca.

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
/// MockAlchemist: NO hereda la interfaz completa,
/// pero define exactamente las funciones que Transmuter usa.
/// ─────────────────────────────────────────────
contract MockAlchemist {
    MockERC20 public yieldToken;
    MockERC20 public underlying;
    uint256 public syntheticsIssued;

    constructor(MockERC20 _yield, MockERC20 _underlying) {
        yieldToken = _yield;
        underlying = _underlying;
        syntheticsIssued = 1e30;
    }

    // === Firmas que Transmuter invoca (deben coincidir con IAlchemistV3) ===
    function totalSyntheticsIssued() external view returns (uint256) {
        return syntheticsIssued;
    }

    function myt() external view returns (address) {
        return address(yieldToken);
    }

    function getTotalUnderlyingValue() external view returns (uint256) {
        return 1e30;
    }

    function convertYieldTokensToUnderlying(uint256 amount) external view returns (uint256) {
        return amount; // 1:1 para simplificar
    }

    function convertYieldTokensToDebt(uint256 /*amount*/) external view returns (uint256) {
        return 0; // sin deuda
    }

    function convertDebtTokensToYield(uint256 amount) external view returns (uint256) {
        return amount; // 1:1
    }

    function redeem(uint256 amount) external {
        // simular redeem minteando yield al caller
        yieldToken.mint(msg.sender, amount);
    }

    function reduceSyntheticsIssued(uint256 amount) external {
        if (syntheticsIssued >= amount) syntheticsIssued -= amount;
        else syntheticsIssued = 0;
    }

    function setTransmuterTokenBalance(uint256 /*bal*/) external {
        // no-op
    }

    function underlyingToken() external view returns (address) {
        return address(underlying);
    }

    // fallback/receive por si el contrato bajo test llama algo extra
    fallback() external payable {}
    receive() external payable {}
}

/// ─────────────────────────────────────────────
/// Test: demuestra el DoS / griefing por depositCap
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

        // ⚠️ Inicializamos el struct campo a campo (no literal),
        // así si tu ITransmuter.TransmuterInitializationParams tiene 6+ campos,
        // los extra quedan en cero y compila igual.
        ITransmuter.TransmuterInitializationParams memory params;
        params.syntheticToken = address(synthetic);
        params.timeToTransmute = 100;
        params.transmutationFee = 50; // 0.5% (BPS=10000)
        params.exitFee = 10;          // 0.1%
        params.feeReceiver = feeReceiver;
        // Si tu struct tuviera otros campos, se quedan en 0/defecto y el constructor no los usa.

        transmuter = new Transmuter(params);
        transmuter.setAlchemist(address(alchemist));
        transmuter.setDepositCap(10e18); // cupo chico para el test

        // fondos
        synthetic.mint(attacker, 20e18);
        synthetic.mint(victim, 1e18);

        // approvals
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

        // claim no puede ser en el mismo bloque que la creación
        vm.roll(block.number + 1);

        vm.prank(attacker);
        // primer NFT id = 1 (nonce arranca en 0 y se ++ en create)
        transmuter.claimRedemption(1);

        assertEq(transmuter.totalLocked(), 0);

        vm.prank(victim);
        transmuter.createRedemption(1e18);

        assertEq(transmuter.totalLocked(), 1e18);
    }
}
