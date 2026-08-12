// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Minimal view into the investor VestingContract to read the shared TGE.
interface IVestingTGE {
    function tgeTimestamp() external view returns (uint256);
}

/**
 * @title TeamVesting
 * @notice Team allocation vesting — 12-month cliff + 24-month linear, anchored
 *         to the same TGE as the investor VestingContract, with every withdrawal
 *         authorised by the owner Safe (Spec 3.3).
 *
 *  Total: 52'000'000 GCORE
 *
 *  The TGE anchor is read live from the investor VestingContract (set once via
 *  setVestingContract at deploy). Team and investor TGE are therefore identical
 *  by construction — no manual setTGE, and the team clock only starts once the
 *  presale finalizes successfully (which is when the investor TGE is set).
 *
 *  Timeline (relative to tgeTimestamp = investor VestingContract TGE):
 *    TGE .............................. 0 %    (start of 12-month cliff)
 *    TGE + 12 months .................. 34 %   (cliff ends, lump unlock)
 *    TGE + 12..36 months .............. 34 % → 100 % linear per second (remaining 66 %)
 *    TGE + 36 months .................. 100 %
 *
 *  1 month = exactly 30 days (project invariant). Cliff = 360 days,
 *  linear duration of the remaining 66 % = 720 days.
 *
 *  RATIONALE: Investors vest linearly from TGE with no cliff. The team gets its
 *  first tokens once investors have reached meaningful liquidity (the 12-month
 *  mark, where Tier-1 investors are fully unlocked) — never before, and always
 *  staggered behind them.
 *
 *  INVARIANT: No access before the cliff. The owner can only ever withdraw what
 *             has already vested — the schedule itself is immutable and cannot be
 *             shortened, accelerated or bypassed by anyone, owner included.
 *
 * @dev Owner is the project Safe; the M-of-N approval lives in the Safe.
 *      Ownable2Step guards against handing ownership to an unusable address.
 */
contract TeamVesting is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20  public gcore;
    bool    public tokenSet;

    // ─── Allocation & vesting schedule ────────────────────────────────────────
    uint256 public constant TOTAL_ALLOCATION = 52_000_000 * 1e18;

    // 1 month = exactly 30 days (invariant). Cliff 12 mo, then linear 24 mo.
    uint256 public constant CLIFF_DURATION   = 12 * 30 days; // 360 days
    uint256 public constant VESTING_DURATION = 24 * 30 days; // 720 days

    // Lump unlock at cliff end (34 %); remaining 66 % vests linearly.
    uint256 public constant CLIFF_UNLOCK_BPS = 3400; // 34.00 %

    /// @notice Investor VestingContract — source of the shared TGE (one-time set).
    address public vestingContract;
    bool    public vestingContractSet;

    /// @notice Cumulative GCORE already released to the team.
    uint256 public released;

    // ─── Custom errors ────────────────────────────────────────────────────────
    error ZeroAddress();
    error AlreadySet();
    error NothingToRelease();

    // ─── Events ───────────────────────────────────────────────────────────────
    event VestingContractSet(address indexed vestingContract);
    event TokensReleased(address indexed recipient, uint256 amount);

    constructor(address _owner) Ownable(_owner) {}

    function setToken(address _gcore) external onlyOwner {
        if (tokenSet)              revert AlreadySet();
        if (_gcore == address(0))  revert ZeroAddress();
        gcore    = IERC20(_gcore);
        tokenSet = true;
    }

    /// @notice Link the investor VestingContract (one-time). The team TGE is then
    ///         read live from it, so both contracts always share the exact same
    ///         TGE and the team clock starts automatically at successful finalize.
    function setVestingContract(address _vesting) external onlyOwner {
        if (vestingContractSet)     revert AlreadySet();
        if (_vesting == address(0)) revert ZeroAddress();
        vestingContract    = _vesting;
        vestingContractSet = true;
        emit VestingContractSet(_vesting);
    }

    /// @notice Shared TGE, read live from the investor VestingContract.
    ///         Returns 0 until linked and until the presale finalizes successfully.
    function tgeTimestamp() public view returns (uint256) {
        if (!vestingContractSet) return 0;
        return IVestingTGE(vestingContract).tgeTimestamp();
    }

    // ─── Withdraw vested tokens (Safe-authorised) ─────────────────────────────
    /// @notice Pays out the currently claimable (vested − released) amount. Can be
    ///         called repeatedly — each call withdraws only the slice that has
    ///         vested since the previous one.
    function release(address recipient) external onlyOwner nonReentrant {
        if (recipient == address(0)) revert ZeroAddress();

        uint256 amount = claimable();
        if (amount == 0) revert NothingToRelease();

        released += amount;   // State first (CEI)

        emit TokensReleased(recipient, amount);
        gcore.safeTransfer(recipient, amount);
    }

    // ─── Views ────────────────────────────────────────────────────────────────
    /// @notice Total GCORE vested so far (cumulative, ignoring what was released).
    ///         34 % unlocks as a lump at cliff end; the remaining 66 % vests
    ///         linearly per second over VESTING_DURATION.
    function vestedAmount() public view returns (uint256) {
        uint256 tge = tgeTimestamp();
        if (tge == 0) return 0;

        uint256 cliffEnd = tge + CLIFF_DURATION;
        if (block.timestamp < cliffEnd) return 0;

        uint256 cliffUnlock = (TOTAL_ALLOCATION * CLIFF_UNLOCK_BPS) / 10_000;

        uint256 elapsed = block.timestamp - cliffEnd;
        if (elapsed >= VESTING_DURATION) return TOTAL_ALLOCATION;

        uint256 linearPortion = TOTAL_ALLOCATION - cliffUnlock;
        uint256 linearVested  = (linearPortion * elapsed) / VESTING_DURATION;
        return cliffUnlock + linearVested;
    }

    /// @notice Currently withdrawable amount (vested minus already released).
    function claimable() public view returns (uint256) {
        uint256 vested = vestedAmount();
        if (vested <= released) return 0;
        return vested - released;
    }

    /// @notice Full schedule for off-chain (dashboard) recompute.
    function vestingSchedule() external view returns (
        uint256 total,
        uint256 tge,
        uint256 cliffEnd,
        uint256 fullyVestedAt,
        uint256 vested,
        uint256 releasedSoFar,
        uint256 withdrawable
    ) {
        total          = TOTAL_ALLOCATION;
        tge            = tgeTimestamp();
        cliffEnd       = tge == 0 ? 0 : tge + CLIFF_DURATION;
        fullyVestedAt  = tge == 0 ? 0 : tge + CLIFF_DURATION + VESTING_DURATION;
        vested         = vestedAmount();
        releasedSoFar  = released;
        withdrawable   = claimable();
    }

    function gcoreBalance() external view returns (uint256) {
        return gcore.balanceOf(address(this));
    }
}
