// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title OpsWalletRelease
 * @notice One-time Ops-Wallet release of USD 550'000 after Softcap (Spec 6).
 *
 *  Amount: USD 550'000 (fixed, one-time — Spec 6.1)
 *  Trigger: Softcap confirmed on-chain
 *  Mechanism: single release, authorised by the owner Safe
 *
 *  Purpose-restricted to (Spec 6.2):
 *   1. Legal documentation / full legal opinion
 *   2. Didit KYC/KYB runtime costs during presale
 *   3. External smart contract audit
 *
 *  Remaining funds: locked until the custody-bank transfer is complete.
 *  No extension, no second release — even at Hardcap.
 *
 * @dev Owner is the project Safe. The M-of-N approval lives in the Safe, so this
 *      contract enforces only the release preconditions and the one-time limit.
 *      Ownable2Step: ownership transfer requires the new owner to accept, which
 *      makes it impossible to hand control to an unusable address by mistake.
 */
contract OpsWalletRelease is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdt;

    address public presaleContract;

    // ─── State ────────────────────────────────────────────────────────────────
    bool    public releaseEnabled;
    bool    public fundsReleased;

    // ─── Custom errors ────────────────────────────────────────────────────────
    error ZeroAddress();
    error AlreadySet();
    error NotPresale();
    error AlreadyEnabled();
    error ReleaseNotEnabled();
    error AlreadyReleased();
    error InsufficientBalance();
    error InvalidAmount();

    // ─── Events ───────────────────────────────────────────────────────────────
    event ReleaseEnabled(uint256 usdtReceived);
    event FundsReleased(address indexed recipient, uint256 amount);

    constructor(address _usdt, address _owner) Ownable(_owner) {
        if (_usdt == address(0)) revert ZeroAddress();
        usdt = IERC20(_usdt);
    }

    // ─── Setup (one-time, after deploy) ───────────────────────────────────────
    function setPresaleContract(address _presale) external onlyOwner {
        if (presaleContract != address(0)) revert AlreadySet();
        if (_presale == address(0))        revert ZeroAddress();
        presaleContract = _presale;
    }

    // ─── Called by PresaleContract on Softcap success ─────────────────────────
    function enableRelease() external {
        if (msg.sender != presaleContract) revert NotPresale();
        if (releaseEnabled)                revert AlreadyEnabled();
        releaseEnabled = true;
        emit ReleaseEnabled(usdt.balanceOf(address(this)));
    }

    // ─── Release (one-time, Safe-authorised) ──────────────────────────────────
    /// @notice Pays out the operational budget once. After this call no further
    ///         release is possible — any remaining balance stays locked, by design.
    function release(address recipient, uint256 usdtAmount)
        external onlyOwner nonReentrant
    {
        if (!releaseEnabled)         revert ReleaseNotEnabled();
        if (fundsReleased)           revert AlreadyReleased();
        if (recipient == address(0)) revert ZeroAddress();
        if (usdtAmount == 0)         revert InvalidAmount();

        uint256 available = usdt.balanceOf(address(this));
        if (usdtAmount > available) revert InsufficientBalance();

        fundsReleased = true;

        emit FundsReleased(recipient, usdtAmount);
        usdt.safeTransfer(recipient, usdtAmount);
    }

    function usdtBalance() external view returns (uint256) {
        return usdt.balanceOf(address(this));
    }
}
