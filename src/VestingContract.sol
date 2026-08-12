// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IBurnable {
    function burn(uint256 amount) external;
}

interface ISeedContract {
    function investorCount() external view returns (uint256);
    function getInvestors(uint256 offset, uint256 limit) external view returns (address[] memory);
    function allocation(address investor) external view returns (uint256);
}

/**
 * @title VestingContract
 * @notice Dynamic vesting for presale investors (Spec 3.1 / 3.2).
 *
 *  All investors receive the SAME vesting tier, regardless of purchase phase.
 *  Tier is determined by total USD raised at presale end (31.10.2027).
 *
 *  NO TGE unlock. 0% at launch, fixed. Pure per-second linear vesting from
 *  tgeTimestamp over the tier duration — no cliff, no monthly steps.
 *
 *  Funding level           Vesting duration
 *  Tier 1  Softcap $12.1M   12 months
 *  Tier 2  ≥$20M            15 months
 *  Tier 3  ≥$28M            18 months
 *  Tier 4  ≥$36M            21 months
 *  Tier 5  ≥$44M (Hardcap)  24 months
 *
 *  GCORE tokens are held here (Mint-as-Sold from PresaleContract).
 *  Investors call claimTokens() to receive vested amounts post-TGE.
 */
contract VestingContract is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE    = keccak256("ADMIN_ROLE");
    bytes32 public constant PRESALE_ROLE  = keccak256("PRESALE_ROLE"); // PresaleContract

    IERC20  public gcore;
    bool    public tokenSet;

    // ─── Vesting tiers (Spec 3.1) ─────────────────────────────────────────────
    struct VestingTier {
        uint256 vestingMonths; // Linear vesting duration in months (no TGE unlock)
    }

    // Thresholds in USD (18 decimals) — highest matching tier wins
    uint256 public constant TIER2_THRESHOLD = 20_000_000 * 1e18;
    uint256 public constant TIER3_THRESHOLD = 28_000_000 * 1e18;
    uint256 public constant TIER4_THRESHOLD = 36_000_000 * 1e18;
    uint256 public constant TIER5_THRESHOLD = 44_000_000 * 1e18;

    VestingTier[5] public tiers;

    // ─── State ────────────────────────────────────────────────────────────────
    mapping(address => uint256) public allocation;    // Total GCORE allocated
    mapping(address => uint256) public claimed;       // Total GCORE claimed
    address[] public investors;
    mapping(address => bool) private _isInvestor;

    uint256 public activeTier;        // 0–4, set at finalize
    uint256 public tgeTimestamp;      // Set by admin at TGE (Nov 2027)
    bool    public vestingActive;     // True after setFundingLevel called
    bool    public presaleFailed;     // True if softcap not reached — enables burnOnFailure

    address public seedContract;
    bool    public seedContractSet;
    mapping(address => bool) public seedAllocationImported;

    // ─── Custom errors ────────────────────────────────────────────────────────
    error ZeroAddress();
    error ZeroAmount();
    error AlreadySet();
    error VestingNotActive();
    error AlreadyMarked();
    error TGEAlreadySet();
    error TGENotInFuture();
    error PresaleNotFailed();
    error NothingToBurn();
    error SeedContractNotSet();
    error VestingAlreadyActive();
    error TGENotReached();
    error NothingToClaim();

    // ─── Events ───────────────────────────────────────────────────────────────
    event AllocationAdded(address indexed investor, uint256 gcoreAmount);
    event PresaleFailedMarked();
    event FundingLevelSet(uint256 totalRaisedUSD, uint256 tierIndex);
    event TGESet(uint256 tgeTimestamp);
    event TokensClaimed(address indexed investor, uint256 amount);
    event TokensBurned(uint256 amount);
    event SeedContractSet(address indexed seedContract);

    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        _initTiers();
    }

    /// @notice Set GCORE token address (called after GCOREToken deployment).
    function setToken(address _gcore) external onlyRole(ADMIN_ROLE) {
        if (tokenSet)              revert AlreadySet();
        if (_gcore == address(0))  revert ZeroAddress();
        gcore    = IERC20(_gcore);
        tokenSet = true;
    }

    // ─── Called by PresaleContract on each purchase ───────────────────────────
    function addAllocation(address investor, uint256 gcoreAmount)
        external onlyRole(PRESALE_ROLE)
    {
        if (investor == address(0)) revert ZeroAddress();
        if (gcoreAmount == 0)       revert ZeroAmount();

        if (!_isInvestor[investor]) {
            _isInvestor[investor] = true;
            investors.push(investor);
        }
        allocation[investor] += gcoreAmount;
        emit AllocationAdded(investor, gcoreAmount);
    }

    // ─── Called by PresaleContract at finalize (failure path) ─────────────────
    function markPresaleFailed() external onlyRole(PRESALE_ROLE) {
        if (!vestingActive)  revert VestingNotActive();
        if (presaleFailed)   revert AlreadyMarked();
        presaleFailed = true;
        emit PresaleFailedMarked();
    }

    // ─── Called by PresaleContract at finalize ────────────────────────────────
    function setFundingLevel(uint256 totalRaisedUSD)
        external onlyRole(PRESALE_ROLE)
    {
        if (vestingActive) revert AlreadySet();
        vestingActive = true;

        if      (totalRaisedUSD >= TIER5_THRESHOLD) activeTier = 4;
        else if (totalRaisedUSD >= TIER4_THRESHOLD) activeTier = 3;
        else if (totalRaisedUSD >= TIER3_THRESHOLD) activeTier = 2;
        else if (totalRaisedUSD >= TIER2_THRESHOLD) activeTier = 1;
        else                                         activeTier = 0;

        emit FundingLevelSet(totalRaisedUSD, activeTier);
    }

    /// @notice Admin sets TGE timestamp after presale end (Nov 2027).
    function setTGE(uint256 _tgeTimestamp) external onlyRole(PRESALE_ROLE) {
        if (!vestingActive)                    revert VestingNotActive();
        if (tgeTimestamp != 0)                 revert TGEAlreadySet();
        if (_tgeTimestamp <= block.timestamp)  revert TGENotInFuture();
        tgeTimestamp = _tgeTimestamp;
        emit TGESet(_tgeTimestamp);
    }

    // ─── Admin: burn stuck tokens after presale failure ───────────────────────
    /// @notice Burns all GCORE held here if presale failed (Softcap not reached).
    function burnOnFailure() external onlyRole(ADMIN_ROLE) {
        if (!presaleFailed) revert PresaleNotFailed();

        uint256 balance = gcore.balanceOf(address(this));
        if (balance == 0) revert NothingToBurn();

        IBurnable(address(gcore)).burn(balance);
        emit TokensBurned(balance);
    }

    // ─── Seed import ──────────────────────────────────────────────────────────
    /// @notice Register the SeedContract address (one-time, admin only).
    function setSeedContract(address _seed) external onlyRole(ADMIN_ROLE) {
        if (seedContractSet)        revert AlreadySet();
        if (_seed == address(0))    revert ZeroAddress();
        seedContract    = _seed;
        seedContractSet = true;
        emit SeedContractSet(_seed);
    }

    /// @notice Permissionless paginated import of seed allocations into VestingContract.
    ///         Must be called before presale finalization (vestingActive == false).
    ///         Guard seedAllocationImported prevents double-import per address.
    function importFromSeed(uint256 offset, uint256 limit) external {
        if (!seedContractSet) revert SeedContractNotSet();
        if (vestingActive)    revert VestingAlreadyActive();

        ISeedContract seed = ISeedContract(seedContract);
        address[] memory addrs = seed.getInvestors(offset, limit);

        for (uint256 i; i < addrs.length; i++) {
            address inv = addrs[i];
            if (seedAllocationImported[inv]) continue;
            uint256 amount = seed.allocation(inv);
            if (amount == 0) continue;

            seedAllocationImported[inv] = true;
            if (!_isInvestor[inv]) {
                _isInvestor[inv] = true;
                investors.push(inv);
            }
            allocation[inv] += amount;
            emit AllocationAdded(inv, amount);
        }
    }

    // ─── Investor: claim vested tokens ────────────────────────────────────────
    function claimTokens() external whenNotPaused nonReentrant {
        if (!vestingActive)                                    revert VestingNotActive();
        if (tgeTimestamp == 0 || block.timestamp < tgeTimestamp) revert TGENotReached();

        uint256 claimable = claimableAmount(msg.sender);
        if (claimable == 0) revert NothingToClaim();

        claimed[msg.sender] += claimable;
        gcore.safeTransfer(msg.sender, claimable);
        emit TokensClaimed(msg.sender, claimable);
    }

    // ─── View: claimable amount ────────────────────────────────────────────────
    function claimableAmount(address investor) public view returns (uint256) {
        if (!vestingActive || tgeTimestamp == 0 || block.timestamp < tgeTimestamp) {
            return 0;
        }

        uint256 total = allocation[investor];
        if (total == 0) return 0;

        // Pure per-second linear vesting — no TGE unlock, no monthly steps.
        // 1 month = exactly 30 days (invariant).
        uint256 duration = tiers[activeTier].vestingMonths * 30 days;

        uint256 elapsed = block.timestamp - tgeTimestamp;
        if (elapsed > duration) elapsed = duration;

        uint256 totalVested    = (total * elapsed) / duration;
        uint256 alreadyClaimed = claimed[investor];

        if (totalVested <= alreadyClaimed) return 0;
        return totalVested - alreadyClaimed;
    }

    /// @notice Full vesting state for an investor, for off-chain (website) recompute.
    ///         No TGE unlock — vesting is pure per-second linear over
    ///         durationSeconds starting at tgeTimestamp.
    function vestingSchedule(address investor) external view returns (
        uint256 totalAllocation,
        uint256 tge,
        uint256 durationSeconds,
        uint256 vestingMonths,
        uint256 alreadyClaimed,
        uint256 claimable
    ) {
        vestingMonths   = tiers[activeTier].vestingMonths;
        totalAllocation = allocation[investor];
        tge             = tgeTimestamp;
        durationSeconds = vestingMonths * 30 days;
        alreadyClaimed  = claimed[investor];
        claimable       = claimableAmount(investor);
    }

    function pause()   external onlyRole(ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(ADMIN_ROLE) { _unpause(); }

    function investorCount() external view returns (uint256) {
        return investors.length;
    }

    // ─── Tier initialization ──────────────────────────────────────────────────
    function _initTiers() private {
        // No TGE unlock in any tier — pure linear over the duration.
        tiers[0] = VestingTier({ vestingMonths: 12 }); // Tier 1: Softcap $12.1M
        tiers[1] = VestingTier({ vestingMonths: 15 }); // Tier 2: ≥$20M
        tiers[2] = VestingTier({ vestingMonths: 18 }); // Tier 3: ≥$28M
        tiers[3] = VestingTier({ vestingMonths: 21 }); // Tier 4: ≥$36M
        tiers[4] = VestingTier({ vestingMonths: 24 }); // Tier 5: ≥$44M Hardcap
    }
}
