// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title GCOREToken
 * @notice BEP-20 Genesis Core Token — 700'000'000 GCORE max supply.
 *         Presale portion (610M) is Mint-as-Sold via PresaleContract.
 *         Fixed allocations are minted at deployment to respective contracts.
 *
 * Deployment order:
 *   1. Deploy LiquidityLock, TeamVesting, CommunityWallet first
 *   2. Deploy GCOREToken (mints fixed allocations in constructor)
 *   3. Call setPresaleContract(presaleAddress) — one-time, grants MINTER_ROLE
 */
contract GCOREToken is ERC20, ERC20Burnable, ERC20Permit, AccessControl, Pausable {
    bytes32 public constant ADMIN_ROLE  = keccak256("ADMIN_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    uint256 public constant MAX_SUPPLY = 700_000_000 * 1e18;

    // Fixed allocations (Spec 2.2)
    uint256 public constant LIQUIDITY_ALLOCATION =  28_000_000 * 1e18; // 4.00%
    uint256 public constant TEAM_ALLOCATION      =  52_000_000 * 1e18; // 7.43%
    uint256 public constant COMMUNITY_ALLOCATION =  10_000_000 * 1e18; // 1.43%
    // Remaining 610_000_000 (87.14%) = Mint-as-Sold via PresaleContract
    uint256 private constant INITIAL_MINT =
        LIQUIDITY_ALLOCATION + TEAM_ALLOCATION + COMMUNITY_ALLOCATION; // 90_000_000

    // ─── Presale contract link (set once) ────────────────────────────────────
    address public presaleContract;

    // ─── Custom errors ────────────────────────────────────────────────────────
    error ZeroAddress();
    error ExceedsMaxSupply();
    error PresaleContractAlreadySet();

    event TokensMinted(address indexed to, uint256 amount);

    constructor(
        address liquidityLock,
        address teamVesting,
        address communityWallet,
        address admin
    ) ERC20("Genesis Core Token", "GCORE") ERC20Permit("Genesis Core Token") {
        if (liquidityLock   == address(0)) revert ZeroAddress();
        if (teamVesting     == address(0)) revert ZeroAddress();
        if (communityWallet == address(0)) revert ZeroAddress();
        if (admin           == address(0)) revert ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);

        _mintAlloc(liquidityLock,   LIQUIDITY_ALLOCATION);
        _mintAlloc(teamVesting,     TEAM_ALLOCATION);
        _mintAlloc(communityWallet, COMMUNITY_ALLOCATION);

        assert(totalSupply() == INITIAL_MINT);
    }

    /**
     * @notice Links the PresaleContract and grants it MINTER_ROLE. Can only be called once.
     * @param _presale Address of the deployed PresaleContract
     */
    function setPresaleContract(address _presale) external onlyRole(ADMIN_ROLE) {
        if (presaleContract != address(0)) revert PresaleContractAlreadySet();
        if (_presale == address(0)) revert ZeroAddress();
        presaleContract = _presale;
        _grantRole(MINTER_ROLE, _presale);
    }

    function _mintAlloc(address to, uint256 amount) private {
        _mint(to, amount);
        emit TokensMinted(to, amount);
    }

    /// @notice Mint-as-Sold: called by PresaleContract on each purchase.
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        if (totalSupply() + amount > MAX_SUPPLY) revert ExceedsMaxSupply();
        _mint(to, amount);
        emit TokensMinted(to, amount);
    }

    function pause()   external onlyRole(ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(ADMIN_ROLE) { _unpause(); }

    /// @dev Blocks all transfers (including mint/burn) when paused.
    function _update(address from, address to, uint256 value)
        internal override(ERC20) whenNotPaused
    {
        super._update(from, to, value);
    }
}
