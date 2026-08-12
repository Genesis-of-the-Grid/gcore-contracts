// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IPancakeRouter {
    function addLiquidity(
        address tokenA, address tokenB,
        uint256 amountADesired, uint256 amountBDesired,
        uint256 amountAMin, uint256 amountBMin,
        address to, uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    function factory() external pure returns (address);
}

interface IPancakeFactory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

/**
 * @title LiquidityLock
 * @notice DEX Liquidity Time-Lock for PancakeSwap launch (Spec 2.4).
 *
 *  Holdings: 28'000'000 GCORE + USD 2'800'000 USDT
 *  Lock: 24 months (immutable, enforced by the contract)
 *  DEX: PancakeSwap V2 (BNB Chain)
 *  DEX launch: November 2027 (max. 1 week after presale end)
 *  DEX launch price: USD 0.10 per GCORE
 *
 *  Flow:
 *   1. GCORE minted here at deployment (28M)
 *   2. USDT transferred from PresaleContract at finalize (2.8M)
 *   3. Admin calls addLiquidityToPancakeSwap() → LP tokens received
 *   4. LP tokens locked for 24 months
 *   5. After lock: admin can withdraw LP tokens
 */
contract LiquidityLock is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    IERC20          public gcore;
    IERC20          public immutable usdt;
    IPancakeRouter  public immutable pancakeRouter;

    bool    public tokenSet;

    // ─── Lock state ───────────────────────────────────────────────────────────
    uint256 public constant LOCK_DURATION = 730 days; // 24 months
    uint256 public lockStartTime;
    uint256 public lockEndTime;
    bool    public liquidityAdded;

    IERC20  public lpToken;

    // ─── Custom errors ────────────────────────────────────────────────────────
    error ZeroAddress();
    error AlreadySet();
    error LiquidityAlreadyAdded();
    error TokenNotSet();
    error ZeroAmounts();
    error InsufficientGCORE();
    error InsufficientUSDT();
    error SlippageTooHigh();
    error NoLPReceived();
    error LiquidityNotAdded();
    error StillLocked();
    error NoLPTokens();

    // ─── Events ───────────────────────────────────────────────────────────────
    event TokenSet(address gcore);
    event USDTReceived(uint256 amount);
    event LiquidityAdded(uint256 gcoreAmount, uint256 usdtAmount, uint256 lpAmount);
    event LiquidityWithdrawn(address recipient, uint256 lpAmount);

    constructor(
        address _usdt,
        address _pancakeRouter,
        address admin
    ) {
        if (_usdt          == address(0)) revert ZeroAddress();
        if (_pancakeRouter == address(0)) revert ZeroAddress();
        if (admin          == address(0)) revert ZeroAddress();

        usdt          = IERC20(_usdt);
        pancakeRouter = IPancakeRouter(_pancakeRouter);

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
    }

    function setToken(address _gcore) external onlyRole(ADMIN_ROLE) {
        if (tokenSet)              revert AlreadySet();
        if (_gcore == address(0))  revert ZeroAddress();
        gcore    = IERC20(_gcore);
        tokenSet = true;
        emit TokenSet(_gcore);
    }

    // ─── Add liquidity to PancakeSwap ─────────────────────────────────────────
    /// @notice Admin calls this to add liquidity and lock LP tokens.
    ///         Must be called within 1 week of presale end (Nov 2027).
    /// @param gcoreAmount  GCORE to add (≤ balance, typically 28M)
    /// @param usdtAmount   USDT to add (≤ balance, typically 2.8M)
    /// @param slippageBps  Slippage tolerance in basis points (e.g. 100 = 1%)
    function addLiquidityToPancakeSwap(
        uint256 gcoreAmount,
        uint256 usdtAmount,
        uint256 slippageBps
    ) external onlyRole(ADMIN_ROLE) nonReentrant {
        if (liquidityAdded)  revert LiquidityAlreadyAdded();
        if (!tokenSet)       revert TokenNotSet();
        if (gcoreAmount == 0 || usdtAmount == 0) revert ZeroAmounts();
        if (gcore.balanceOf(address(this)) < gcoreAmount) revert InsufficientGCORE();
        if (usdt.balanceOf(address(this))  < usdtAmount)  revert InsufficientUSDT();
        if (slippageBps > 500) revert SlippageTooHigh();

        uint256 minGcore = gcoreAmount - (gcoreAmount * slippageBps) / 10_000;
        uint256 minUSDT  = usdtAmount  - (usdtAmount  * slippageBps) / 10_000;

        gcore.forceApprove(address(pancakeRouter), gcoreAmount);
        usdt.forceApprove(address(pancakeRouter), usdtAmount);

        (, , uint256 lpAmount) = pancakeRouter.addLiquidity(
            address(gcore),
            address(usdt),
            gcoreAmount,
            usdtAmount,
            minGcore,
            minUSDT,
            address(this),
            block.timestamp + 15 minutes
        );
        if (lpAmount == 0) revert NoLPReceived();

        // Identify and store LP token contract
        address factory = pancakeRouter.factory();
        address lpAddr  = IPancakeFactory(factory).getPair(address(gcore), address(usdt));
        lpToken = IERC20(lpAddr);

        liquidityAdded = true;
        lockStartTime  = block.timestamp;
        lockEndTime    = block.timestamp + LOCK_DURATION;

        emit LiquidityAdded(gcoreAmount, usdtAmount, lpAmount);
    }

    // ─── Withdraw LP tokens after 24-month lock ────────────────────────────────
    function withdrawLP(address recipient) external onlyRole(ADMIN_ROLE) nonReentrant {
        if (!liquidityAdded)                    revert LiquidityNotAdded();
        if (block.timestamp < lockEndTime)       revert StillLocked();
        if (recipient == address(0))             revert ZeroAddress();

        uint256 lpBal = lpToken.balanceOf(address(this));
        if (lpBal == 0) revert NoLPTokens();

        emit LiquidityWithdrawn(recipient, lpBal);
        lpToken.safeTransfer(recipient, lpBal);
    }

    // ─── View ──────────────────────────────────────────────────────────────────
    function remainingLockTime() external view returns (uint256) {
        if (!liquidityAdded || block.timestamp >= lockEndTime) return 0;
        return lockEndTime - block.timestamp;
    }

    function gcoreBalance()  external view returns (uint256) { return gcore.balanceOf(address(this)); }
    function usdtBalance()   external view returns (uint256) { return usdt.balanceOf(address(this)); }
    function lpBalance()     external view returns (uint256) {
        if (address(lpToken) == address(0)) return 0;
        return lpToken.balanceOf(address(this));
    }
}
