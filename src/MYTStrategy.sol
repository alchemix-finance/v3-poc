// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IVaultV2} from "../lib/vault-v2/src/interfaces/IVaultV2.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import {IMYTStrategy} from "./interfaces/IMYTStrategy.sol";
import "forge-std/console.sol";
import {ISettlerActions} from "./external/interfaces/ISettlerActions.sol";
import {IVelodromePair} from "./external/interfaces/IVelodromePair.sol";
import {ISignatureTransfer} from "../lib/permit2/src/interfaces/ISignatureTransfer.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ZeroXSwapVerifier} from "./utils/ZeroXSwapVerifier.sol";

interface IERC721Tiny {
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface IDeployerTiny is IERC721Tiny {
    function prev(uint128 featureId) external view returns (address);
}

// Interface for Permit2 to support ERC-1271 signature verification
interface IPermit2 {
    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4);
}

contract MYTStrategy is IMYTStrategy, Ownable {
    IVaultV2 public immutable MYT;
    address public immutable receiptToken;
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant FIXED_POINT_SCALAR = 1e18;
    uint256 public constant MIN_SNAPSHOT_INTERVAL = 1 days;

    IMYTStrategy.StrategyParams public params;
    bytes32 public immutable adapterId;
    uint256 public lastSnapshotTime;
    uint256 public lastIndex;
    uint256 public estApr;
    uint256 public estApy;

    /// @notice This value is true when the underlying protocol is known to
    /// experience issues or security incidents. In this case the allocation step is simply
    /// bypassed without reverts (to keep external allocators from reverting).
    bool public killSwitch;

    mapping(address => bool) public whitelistedAllocators;
    
    // Permit2 configuration
    address public permit2Address;

    IDeployerTiny constant ZERO_EX_DEPLOYER = IDeployerTiny(0x00000000000004533Fe15556B1E086BB1A72cEae);

    error CounterfeitSettler(address);

    event MYTLog(string message, uint256 value);

    /// @notice Modifier to restrict access to the vault **managed** by the MYT contract
    modifier onlyVault() {
        require(msg.sender == address(MYT), "PD");
        _;
    }

    constructor(address _myt, StrategyParams memory _params, address _permit2Address, address _receiptToken) Ownable(_params.owner) {
        require(_params.owner != address(0));
        require(_myt != address(0));
        require(_permit2Address != address(0), "Zero Permit2 address");
        require(_receiptToken != address(0), "Zero receipt token address");
        MYT = IVaultV2(_myt);
        receiptToken = _receiptToken;
        params = _params;
        adapterId = keccak256(abi.encode(_params.protocol));
        

        permit2Address = _permit2Address;
        

        // IERC20 vaultAsset = IERC20(address(MYT.asset()));
        // vaultAsset.approve(permit2Address, type(uint256).max);
        IERC20 receiptTokenContract = IERC20(receiptToken);
        receiptTokenContract.approve(permit2Address, type(uint256).max);
        
        // TODO add the strategy to the perpetual gauge in an authenticated manner
        // TODO perhap take initial snapshot now to set up start block
    }

    function allocate(bytes memory data, uint256 assets, bytes4 selector, address sender)
        external
        onlyVault
        returns (bytes32[] memory strategyIds, int256 change)
    {
        if (killSwitch) {
            return (ids(), int256(0));
        }
        uint256 oldAllocation = abi.decode(data, (uint256));
        uint256 amountAllocated = _allocate(assets);
        uint256 newAllocation = oldAllocation + amountAllocated;
        emit Allocate(amountAllocated, address(this));
        return (ids(), int256(newAllocation) - int256(oldAllocation));
    }

    function deallocate(bytes memory data, uint256 assets, bytes4 selector, address sender)
        external
        onlyVault
        returns (bytes32[] memory strategyIds, int256 change)
    {
        if (killSwitch) {
            return (ids(), int256(0));
        }
        uint256 oldAllocation = abi.decode(data, (uint256));
        emit MYTLog("oldAllocation", oldAllocation);
        uint256 amountDeallocated = _deallocate(assets);
        emit MYTLog("amountDeallocated", amountDeallocated);
        uint256 newAllocation = oldAllocation - amountDeallocated;
        emit MYTLog("newAllocation", newAllocation);
        emit Deallocate(amountDeallocated, address(this));
        return (ids(), int256(newAllocation) - int256(oldAllocation));
    }

    /// @notice call this function to handle unwrapping/deallocation/moving funds from
    /// the respective protocol of this strategy in case we want to bypass
    /// a withdrawal queue or similar mechanism and directly go to a DEX
    function deallocateDex(bytes calldata quote, bool prevSettler) external returns (uint256 ret) {
        require(!killSwitch, "emergency");
        IERC20 asset = IERC20(receiptToken);
        // TODO additional access control needed?
        require(whitelistedAllocators[msg.sender], "PD");
        address currentSettler = prevSettler ? ZERO_EX_DEPLOYER.prev(2) : ZERO_EX_DEPLOYER.ownerOf(2);
        uint256 balanceBefore = asset.balanceOf(address(this));
        
        // Set maximum allowed slippage to 10% (1000 bps)
        uint256 maxSlippageBps = 1000;
        require(ZeroXSwapVerifier.verifySwapCalldata(quote, address(this), receiptToken, maxSlippageBps));

        (bool success,) = currentSettler.call(quote);
        require(success, "SF"); // settler failed
        uint256 balanceAfter = asset.balanceOf(address(this));
        ret = balanceBefore - balanceAfter;
        emit DeallocateDex(ret);
    }

    /// @notice call this function to handle strategies with withdrawal queue NFT
    function claimWithdrawalQueue(uint256 positionId) public virtual returns (uint256 ret) {
        require(whitelistedAllocators[msg.sender], "PD");
        require(!killSwitch, "emergency");
        _claimWithdrawalQueue(positionId);
    }

    /// @notice call this function to claim all available rewards from the respective
    /// protocol of this strategy
    function claimRewards() public virtual returns (uint256) {
        require(!killSwitch, "emergency");
        _claimRewards();
    }

    /// @dev override this function to handle wrapping/allocation/moving funds to
    /// the respective protocol of this strategy
    function _allocate(uint256 amount) internal virtual returns (uint256) {}

    /// @dev override this function to handle unwrapping/deallocation/moving funds from
    /// the respective protocol of this strategy
    function _deallocate(uint256 amount) internal virtual returns (uint256) {}

    /// @dev override this function to handle strategies with withdrawal queue NFT
    function _claimWithdrawalQueue(uint256 positionId) internal virtual returns (uint256) {}

    /// @dev override this function to claim all available rewards from the respective
    /// protocol of this strategy
    function _claimRewards() internal virtual returns (uint256) {}

    /// @notice can be called by anyone to recalculate the
    /// estimated yields of this strategy based on external price
    /// oracles and protocol heuristics.
    function snapshotYield() public virtual returns (uint256) {
        uint256 currentTime = block.timestamp;


        if (lastSnapshotTime != 0 && currentTime - lastSnapshotTime < MIN_SNAPSHOT_INTERVAL) {
             return estApy;
        }

        // Base rate of strategy
        (uint256 baseRatePerSec, uint256 newIndex) = _computeBaseRatePerSecond();

        // Add incentives to calculation if applicable
        uint256 rewardsRatePerSec;
        if (params.additionalIncentives == true) rewardsRatePerSec = _computeRewardsRatePerSecond();

        // Combine rates
        uint256 totalRatePerSec = baseRatePerSec + rewardsRatePerSec;
        uint256 apr = totalRatePerSec * SECONDS_PER_YEAR; // simple annualization (APR)
        uint256 apy = _approxAPY(totalRatePerSec);

        // Smoothing factor
        // TODO need to figure out how to ramp this up
        // Since first call is 0 the second call will be skewed
        // perhaps no smoothing on second pass
        uint256 alpha = 7e17; // 0.7
        estApr = _lerp(estApr, apr, alpha);
        estApy = _lerp(estApy, apy, alpha);

        lastSnapshotTime = uint64(currentTime);
        lastIndex = newIndex;

        emit YieldUpdated(estApy);

        return estApy;
    }

    /// @dev override this function to handle strategy specific base rate calculation
    // TODO this one is only different by how we get the asset price
    // may be good to move this logic here and host only the price in the adapter
    function _computeBaseRatePerSecond() internal virtual returns (uint256 ratePerSec, uint256 newIndex) {}

    /// @dev override this function to handle strategy specific reward rate calculation
    function _computeRewardsRatePerSecond() internal virtual returns (uint256) {}

    // Helper for yield snapshot calculation
    function _approxAPY(uint256 ratePerSecWad) internal pure returns (uint256) {
        uint256 apr = ratePerSecWad * SECONDS_PER_YEAR;
        uint256 aprSq = apr * apr / FIXED_POINT_SCALAR;
        return apr + aprSq / (2 * SECONDS_PER_YEAR);
    }

    // Helper for yield snapshot calculation
    function _lerp(uint256 oldVal, uint256 newVal, uint256 alpha) internal pure returns (uint256) {
        return alpha * oldVal / FIXED_POINT_SCALAR + (FIXED_POINT_SCALAR - alpha) * newVal / FIXED_POINT_SCALAR;
    }

    /// @notice recategorize this strategy to a different risk class
    function setRiskClass(RiskClass newClass) public onlyOwner {
        params.riskClass = newClass;
        emit RiskClassUpdated(newClass);
    }

    /// @dev some protocols may pay yield in baby tokens
    /// so we need to manually collect them
    function setAdditionalIncentives(bool newValue) public onlyOwner {
        params.additionalIncentives = newValue;
        emit IncentivesUpdated(newValue);
    }

    function setWhitelistedAllocator(address to, bool val) public onlyOwner {
        require(to != address(0));
        whitelistedAllocators[to] = val;
    }

    /// @notice enter/exit emergency mode for this strategy
    function setKillSwitch(bool val) public onlyOwner {
        killSwitch = val;
        emit Emergency(val);
    }

    /// @notice update Permit2 address and approvals
    function setPermit2Address(address newAddress) public onlyOwner {
        require(newAddress != address(0), "Zero address");
        
        // Revoke old approvals
        // IERC20 vaultAsset = IERC20(address(MYT.asset()));
        // vaultAsset.approve(permit2Address, 0);
        IERC20 receiptTokenContract = IERC20(receiptToken);
        receiptTokenContract.approve(permit2Address, 0);
        
        // Set new approvals
        //vaultAsset.approve(newAddress, type(uint256).max);
        receiptTokenContract.approve(newAddress, type(uint256).max);
        permit2Address = newAddress;
    }

    /// @notice get the current snapshotted estimated yield for this strategy.
    /// This call does not guarantee the latest up-to-date yield and there might
    /// be discrepancies from the respective protocols numbers.
    function getEstimatedYield() public view returns (uint256) {
        return params.estimatedYield;
    }

    function getCap() external view returns (uint256) {
        return params.cap;
    }

    function getGlobalCap() external view returns (uint256) {
        return params.globalCap;
    }

    function ids() public view returns (bytes32[] memory) {
        bytes32[] memory ids_ = new bytes32[](1);
        ids_[0] = adapterId;
        return ids_;
    }

    function getIdData() external view returns (bytes memory) {
        return abi.encode(params.protocol, address(this));
    }

    function realAssets() external view virtual returns (uint256) {}
    
    /// @notice ERC-1271 interface for Permit2 signature verification
    function isValidSignature(bytes32 _hash, bytes memory _signature) public view returns (bytes4) {
        return IPermit2(permit2Address).isValidSignature(_hash, _signature);
    }
}
