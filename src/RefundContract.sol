// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IPresaleData {
    struct InvestorData {
        uint256 gcoreAllocated;
        uint256 bnbPaid;
        uint256 usdtPaid;
        uint256 totalUSDPaid;
        bool    whitelisted;
    }
    function getInvestorData(address investor) external view returns (InvestorData memory);
    function investorList(uint256 index) external view returns (address);
    function investorCount() external view returns (uint256);
}

/**
 * @title RefundContract
 * @notice Investor-initiated refund on Softcap failure (Spec 5.2).
 *
 *  Triggered by: Softcap not reached by 31.10.2027.
 *  Claim window: 180 days from presale end (01.11.2027 – 29.04.2028).
 *  Pull-pattern: investor initiates claimRefund() — no automatic refund.
 *  Gas fees: paid by investor.
 *  Refund in original payment currency (BNB + USDT proportional).
 *
 *  INVARIANT: enableRefund() is only reachable via PresaleContract.finalize() on
 *             the failure path, and only once — the success path never funds this
 *             contract.
 */
contract RefundContract is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE   = keccak256("ADMIN_ROLE");
    bytes32 public constant PRESALE_ROLE = keccak256("PRESALE_ROLE");

    IERC20          public immutable usdt;
    IPresaleData    public immutable presale;

    uint256 public constant CLAIM_WINDOW = 180 days;
    uint256 public refundStartTime;
    bool    public refundEnabled;

    mapping(address => bool) public refundClaimed;

    // ─── Custom errors ────────────────────────────────────────────────────────
    error ZeroAddress();
    error AlreadyEnabled();
    error RefundNotActive();
    error ClaimWindowExpired();
    error AlreadyClaimed();
    error NoInvestment();
    error BNBTransferFailed();
    error WindowStillOpen();

    event RefundEnabled(uint256 totalBNB, uint256 totalUSDT);
    event USDTDeposited(uint256 amount);
    event RefundClaimed(address indexed investor, uint256 bnbAmount, uint256 usdtAmount);
    event UnclaimedFundsResolved(address indexed recipient, uint256 bnb, uint256 usdt);

    constructor(address _usdt, address _presale, address admin) {
        if (_usdt    == address(0)) revert ZeroAddress();
        if (_presale == address(0)) revert ZeroAddress();
        if (admin    == address(0)) revert ZeroAddress();

        usdt    = IERC20(_usdt);
        presale = IPresaleData(_presale);

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
    }

    // ─── Called by PresaleContract on finalize (fail) ─────────────────────────
    function enableRefund() external payable onlyRole(PRESALE_ROLE) {
        if (refundEnabled) revert AlreadyEnabled();
        refundEnabled   = true;
        refundStartTime = block.timestamp;
        emit RefundEnabled(address(this).balance, usdt.balanceOf(address(this)));
    }

    function depositUSDT(uint256 amount) external onlyRole(PRESALE_ROLE) {
        emit USDTDeposited(amount);
    }

    // ─── Investor: claim refund ────────────────────────────────────────────────
    function claimRefund() external nonReentrant {
        if (!refundEnabled)                                         revert RefundNotActive();
        if (block.timestamp > refundStartTime + CLAIM_WINDOW)       revert ClaimWindowExpired();
        if (refundClaimed[msg.sender])                              revert AlreadyClaimed();

        IPresaleData.InvestorData memory data = presale.getInvestorData(msg.sender);
        if (data.bnbPaid == 0 && data.usdtPaid == 0)               revert NoInvestment();

        refundClaimed[msg.sender] = true;

        uint256 bnbRefund  = data.bnbPaid;
        uint256 usdtRefund = data.usdtPaid;

        // Cap to available balance (safety)
        if (bnbRefund > address(this).balance) {
            bnbRefund = address(this).balance;
        }
        uint256 usdtBal = usdt.balanceOf(address(this));
        if (usdtRefund > usdtBal) {
            usdtRefund = usdtBal;
        }

        emit RefundClaimed(msg.sender, bnbRefund, usdtRefund);

        if (bnbRefund > 0) {
            (bool ok,) = msg.sender.call{value: bnbRefund}("");
            if (!ok) revert BNBTransferFailed();
        }
        if (usdtRefund > 0) {
            usdt.safeTransfer(msg.sender, usdtRefund);
        }
    }

    // ─── Admin: resolve unclaimed funds after 180-day window ──────────────────
    // Disposition per legal guidance (Spec 5.2).
    function resolveUnclaimed(address recipient) external onlyRole(ADMIN_ROLE) {
        if (!refundEnabled)                                          revert RefundNotActive();
        if (block.timestamp <= refundStartTime + CLAIM_WINDOW)       revert WindowStillOpen();
        if (recipient == address(0))                                 revert ZeroAddress();

        uint256 bnbBal  = address(this).balance;
        uint256 usdtBal = usdt.balanceOf(address(this));

        emit UnclaimedFundsResolved(recipient, bnbBal, usdtBal);

        if (bnbBal > 0) {
            (bool ok,) = recipient.call{value: bnbBal}("");
            if (!ok) revert BNBTransferFailed();
        }
        if (usdtBal > 0) {
            usdt.safeTransfer(recipient, usdtBal);
        }
    }

    function claimWindowExpiry() external view returns (uint256) {
        if (!refundEnabled) return 0;
        return refundStartTime + CLAIM_WINDOW;
    }

    receive() external payable {}
}
