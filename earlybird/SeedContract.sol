// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title  SeedContract — Genesis Early Bird (Phase 0) Sale
 * @notice Investors send USDT, receive a GCORE allocation on-chain.
 *         Actual GCORE tokens are distributed post-TGE if the public
 *         presale reaches its softcap. No refunds, no on-chain claim.
 *
 * Price:    0.02 USDT per GCORE  (50 GCORE per 1 USDT)
 * Min buy:  100 USDT
 * Hardcap:  10,000,000 GCORE — the final buy sweeps sub-minimum dust, see buy()
 * Payment:  USDT BEP-20 only
 * Chain:    BNB Smart Chain (BSC)
 *
 * BSC USDT: 0x55d398326f99059fF775485246999027B3197955 (18 decimals)
 *
 * @dev Ownership uses a two-step transfer (Ownable2Step) to prevent
 *      accidental loss of control. The owner is intended to be a multisig.
 *      USDT transfers use SafeERC20 to tolerate non-standard ERC20 returns.
 *
 *      Role separation: the KYC gate (setKYCApproved / setKYCApprovedBatch) is
 *      callable by the owner OR a dedicated `operator` hot wallet. This lets the
 *      KYC backend (Didit) whitelist investors automatically with a low-privilege key
 *      while ownership (sale control, treasury, operator management) stays on a
 *      multisig. The operator can do nothing but flip the KYC flag — no fund
 *      access, no sale/treasury control.
 */
contract SeedContract is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /// @dev 10 million GCORE (18 decimals)
    uint256 public constant HARDCAP = 10_000_000e18;

    /// @dev Price per GCORE in USDT raw units: 0.02 * 1e18 = 2e16
    uint256 public constant PRICE_PER_GCORE = 2e16;

    /// @dev Minimum purchase: 100 USDT (18 decimals)
    uint256 public constant MIN_PURCHASE = 100e18;

    /// @dev Minimum purchase expressed in GCORE: 5,000 (= MIN_PURCHASE * 50).
    ///      A remainder below this can never be bought — see dust sweep in buy().
    uint256 public constant MIN_PURCHASE_GCORE = (MIN_PURCHASE * 1e18) / PRICE_PER_GCORE;

    /// @dev Max addresses per setKYCApprovedBatch call (loop bound)
    uint256 public constant MAX_BATCH = 200;

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    IERC20 public immutable usdt;

    /// @dev Destination for all collected USDT
    address public treasury;

    /// @dev Low-privilege hot wallet allowed to set the KYC flag (KYC backend).
    ///      May be address(0) to disable; owner can always call KYC functions.
    address public operator;

    /// @dev KYC approval gate — set by the KYC backend (operator) or owner
    mapping(address => bool) public kycApproved;

    /// @dev GCORE allocation per investor (raw 18-decimal units)
    mapping(address => uint256) public allocation;

    /// @dev Ordered list of all investors — for on-chain iteration by VestingContract
    address[] private _investorList;
    mapping(address => bool) private _isInvestor;

    /// @dev Total GCORE sold so far
    uint256 public totalSold;

    /// @dev Sale must be explicitly activated by owner
    bool public saleActive;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event PurchaseMade(
        address indexed investor,
        uint256 usdtAmount,
        uint256 gcoreAmount,
        uint256 totalSold
    );
    event KYCUpdated(address indexed investor, bool approved);
    event TreasuryUpdated(address indexed newTreasury);
    event OperatorUpdated(address indexed newOperator);
    event SaleStatusUpdated(bool active);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error SaleNotActive();
    error NotKYCApproved();
    error NotAuthorized();
    error BelowMinPurchase(uint256 sent, uint256 minimum);
    error HardcapExceeded(uint256 requested, uint256 remaining);
    error InvalidAddress();
    error BatchTooLarge(uint256 length, uint256 max);

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /**
     * @param _usdt      USDT (BEP-20) token address.
     * @param _treasury  Destination for collected USDT (multisig recommended).
     * @param _operator  KYC hot wallet (KYC backend). Pass address(0) to start
     *                   without an operator (owner-only KYC); set later via setOperator.
     */
    constructor(address _usdt, address _treasury, address _operator) Ownable(msg.sender) {
        if (_usdt == address(0) || _treasury == address(0)) revert InvalidAddress();
        usdt = IERC20(_usdt);
        treasury = _treasury;
        operator = _operator;
        emit OperatorUpdated(_operator);
    }

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    /// @dev Restricts to the owner (multisig) or the operator (KYC hot wallet).
    modifier onlyOwnerOrOperator() {
        if (msg.sender != owner() && msg.sender != operator) revert NotAuthorized();
        _;
    }

    // -------------------------------------------------------------------------
    // Investor-facing
    // -------------------------------------------------------------------------

    /**
     * @notice Buy GCORE with USDT.
     * @dev    Caller must have approved this contract for `usdtAmount` USDT.
     *         Follows Checks-Effects-Interactions.
     *         Dust sweep: if the purchase would leave less than MIN_PURCHASE_GCORE
     *         unsold, the remainder is added to this buyer's allocation at no extra
     *         cost (usdtAmount is unchanged) so the sale closes exactly at HARDCAP.
     *         PurchaseMade reports the swept gcoreAmount.
     * @param  usdtAmount  Raw USDT amount (18 decimals) to spend. Min 100 USDT.
     */
    function buy(uint256 usdtAmount) external nonReentrant {
        if (!saleActive)                    revert SaleNotActive();
        if (!kycApproved[msg.sender])       revert NotKYCApproved();
        if (usdtAmount < MIN_PURCHASE)      revert BelowMinPurchase(usdtAmount, MIN_PURCHASE);

        // 0.02 USDT per GCORE  →  gcoreAmount = usdtAmount * 50
        uint256 gcoreAmount = (usdtAmount * 1e18) / PRICE_PER_GCORE;

        uint256 sold = totalSold;                       // cache (G011)
        uint256 remaining = HARDCAP - sold;
        if (gcoreAmount > remaining) revert HardcapExceeded(gcoreAmount, remaining);

        // Dust sweep: a leftover below MIN_PURCHASE_GCORE could never be bought
        // (buys below the minimum revert) and would strand the hardcap. Assign it
        // to this final buyer for free — the sale closes exactly at HARDCAP.
        unchecked {
            uint256 dust = remaining - gcoreAmount;     // safe: gcoreAmount <= remaining
            if (dust != 0 && dust < MIN_PURCHASE_GCORE) gcoreAmount = remaining;
        }

        // Effects
        uint256 newTotal = sold + gcoreAmount;
        totalSold = newTotal;
        allocation[msg.sender] = allocation[msg.sender] + gcoreAmount;
        if (!_isInvestor[msg.sender]) {
            _isInvestor[msg.sender] = true;
            _investorList.push(msg.sender);
        }

        // Interaction
        usdt.safeTransferFrom(msg.sender, treasury, usdtAmount);

        emit PurchaseMade(msg.sender, usdtAmount, gcoreAmount, newTotal);
    }

    // -------------------------------------------------------------------------
    // View helpers
    // -------------------------------------------------------------------------

    /// @notice GCORE still available until hardcap.
    function remainingAllocation() external view returns (uint256) {
        return HARDCAP - totalSold;
    }

    /// @notice Convert a USDT amount to the GCORE allocation it would buy.
    function usdtToGcore(uint256 usdtAmount) external pure returns (uint256) {
        return (usdtAmount * 1e18) / PRICE_PER_GCORE;
    }

    /// @notice Total number of unique investors — for pagination in VestingContract.
    function investorCount() external view returns (uint256) {
        return _investorList.length;
    }

    /**
     * @notice Returns a slice of the investor list for paginated on-chain reading.
     * @param  offset  Start index (inclusive).
     * @param  limit   Max number of addresses to return.
     * @dev    Used by VestingContract.importFromSeed() to iterate without a full array copy.
     * @return result  Slice of investor addresses [offset, offset+limit).
     */
    function getInvestors(uint256 offset, uint256 limit)
        external view returns (address[] memory result)
    {
        uint256 total = _investorList.length;
        if (offset >= total) return new address[](0);
        uint256 end = offset + limit > total ? total : offset + limit;
        result = new address[](end - offset);
        for (uint256 i = offset; i < end;) {
            result[i - offset] = _investorList[i];
            unchecked { ++i; }
        }
    }

    // -------------------------------------------------------------------------
    // KYC — owner or operator
    // -------------------------------------------------------------------------

    /// @notice Approve or revoke KYC for a single address (called by the KYC backend).
    /// @dev    Callable by owner or operator.
    function setKYCApproved(address investor, bool approved) external onlyOwnerOrOperator {
        if (investor == address(0)) revert InvalidAddress();
        if (kycApproved[investor] != approved) {        // skip redundant write (G001)
            kycApproved[investor] = approved;
            emit KYCUpdated(investor, approved);
        }
    }

    /// @notice Batch KYC update for gas efficiency. Bounded to MAX_BATCH addresses.
    /// @dev    Callable by owner or operator.
    function setKYCApprovedBatch(address[] calldata investors, bool approved) external onlyOwnerOrOperator {
        uint256 len = investors.length;
        if (len > MAX_BATCH) revert BatchTooLarge(len, MAX_BATCH);
        for (uint256 i = 0; i < len;) {
            address inv = investors[i];
            if (kycApproved[inv] != approved) {
                kycApproved[inv] = approved;
                emit KYCUpdated(inv, approved);
            }
            unchecked { ++i; }
        }
    }

    // -------------------------------------------------------------------------
    // Owner — Sale control
    // -------------------------------------------------------------------------

    function setSaleActive(bool active) external onlyOwner {
        if (saleActive != active) {
            saleActive = active;
            emit SaleStatusUpdated(active);
        }
    }

    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert InvalidAddress();
        if (treasury != _treasury) {
            treasury = _treasury;
            emit TreasuryUpdated(_treasury);
        }
    }

    /// @notice Set (or clear) the operator hot wallet allowed to manage the KYC gate.
    /// @dev    address(0) disables the operator; the owner can always call KYC fns.
    function setOperator(address _operator) external onlyOwner {
        if (operator != _operator) {
            operator = _operator;
            emit OperatorUpdated(_operator);
        }
    }

    /**
     * @notice Disabled — ownership can never be renounced.
     * @dev    Ownable.renounceOwnership() would drop the owner to address(0) in a
     *         single step (bypassing the Ownable2Step accept pattern), permanently
     *         freezing setSaleActive / setTreasury / setOperator. The sale needs an
     *         owner for its entire lifetime — the sale must remain stoppable and the
     *         operator key must remain rotatable. Use transferOwnership instead.
     */
    function renounceOwnership() public pure override {
        revert NotAuthorized();
    }
}
