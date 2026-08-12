// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IGCOREToken {
    function mint(address to, uint256 amount) external;
}

interface IVestingContract {
    function addAllocation(address investor, uint256 gcoreAmount) external;
    function setFundingLevel(uint256 totalRaisedUSD) external;
    function markPresaleFailed() external;
    function setTGE(uint256 tgeTimestamp) external;
}

interface IRefundContract {
    function enableRefund() external payable;
    function depositUSDT(uint256 amount) external;
}

interface IOpsWalletRelease {
    function enableRelease() external;
}

interface AggregatorV3Interface {
    function latestRoundData() external view returns (
        uint80 roundId, int256 answer, uint256 startedAt,
        uint256 updatedAt, uint80 answeredInRound
    );
    function decimals() external view returns (uint8);
}

/**
 * @title PresaleContract
 * @notice Manages the 6-phase GCORE presale (Jan 2027 – Oct 2027).
 *
 *  Phases (Spec 4.1):
 *   I   Genesis Awakens    $0.04  01.01–31.01.2027  50M  Rush×1.50
 *   II  Echoes of Bastion  $0.05  01.02–28.02.2027  50M  Rush×1.25
 *   III Architects Arise   $0.06  01.03–31.03.2027  50M  Rush×1.20
 *   IV  Founders Assemble  $0.07  01.04–30.04.2027 125M  Rush×1.20
 *   V   The Last Bastion   $0.08  01.05–31.05.2027 125M  Rush×1.25
 *   VI  The Last Gate      $0.09  01.06–31.10.2027 210M  Rush×1.15 (alternating)
 *
 *  Rush: last 7 days per phase (Phase VI: last 11 days, admin-toggled).
 *  Rush multiplier applies to TOKEN QUANTITY, not price.
 *  Softcap: USD 12'115'000  |  Presale end: 31.10.2027
 */
contract PresaleContract is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    string  public constant VERSION        = "1.0.0";
    bytes32 public constant ADMIN_ROLE    = keccak256("ADMIN_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    // ─── Custom errors ────────────────────────────────────────────────────────
    error ZeroAddress();
    error AlreadySet();
    error AlreadyFinalized();
    error PresaleStillActive();
    error ContractsNotSet();
    error LiquidityLockNotSet();
    error TGEInPast();
    error NotPhaseVI();
    error PresaleClosed();
    error NoBNBSent();
    error NotWhitelisted();
    error NoUSDTSent();
    error NotFinalizedOrSuccess();
    error BNBTransferFailed();
    error AlreadyTriggered();
    error SoftcapNotReached();
    error BelowMinTicket();
    error PhasePoolExhausted();
    error InvalidOraclePrice();
    error StaleOraclePrice();
    error StaleOracleRound();

    // ─── External contracts ───────────────────────────────────────────────────
    IGCOREToken       public immutable gcore;
    IERC20            public immutable usdt;
    IVestingContract  public vestingContract;
    IRefundContract   public refundContract;
    IOpsWalletRelease public opsWallet;
    AggregatorV3Interface public immutable bnbPriceFeed; // Chainlink BNB/USD

    // ─── Constants ────────────────────────────────────────────────────────────
    uint256 public constant SOFTCAP_USD      = 12_115_000 * 1e18; // USD 12.115M (18 dec)
    uint256 public constant OPS_RELEASE_USDT = 550_000 * 1e18;    // USD 550k
    uint256 public constant DEX_LIQUIDITY_USDT = 2_800_000 * 1e18; // USD 2.8M
    uint256 public constant CHAINLINK_STALENESS = 3600;            // 1 hour max age

    // ─── Phase definitions ────────────────────────────────────────────────────
    struct Phase {
        uint256 startTime;
        uint256 endTime;
        uint256 pricePerGcore;  // USD per GCORE, 18 decimals (e.g. 0.04e18)
        uint256 tokenPool;      // GCORE available, 18 decimals
        uint256 tokensSold;     // GCORE sold, 18 decimals
        uint256 minTicketUSD;   // Minimum purchase USD, 18 decimals
        uint256 rushMultiplier; // e.g. 1.5e18 for ×1.50
        uint256 rushStartTime;  // When rush begins
        bool    rushAlternating;// Phase VI: rush toggled by operator
    }

    Phase[6] public phases;
    bool     public phaseVIRushActive; // Operator-controlled rush toggle for Phase VI

    // ─── Investor records ─────────────────────────────────────────────────────
    struct InvestorData {
        uint256 gcoreAllocated; // Total GCORE to receive
        uint256 bnbPaid;        // BNB paid (wei)
        uint256 usdtPaid;       // USDT paid (18 dec)
        uint256 totalUSDPaid;   // USD value at purchase time (18 dec)
        bool    whitelisted;
    }

    mapping(address => InvestorData) public investors;
    address[] public investorList;
    mapping(address => bool) private _inInvestorList;

    // ─── Presale state ────────────────────────────────────────────────────────
    uint256 public totalRaisedUSD;    // Cumulative USD raised, 18 dec
    uint256 public totalBNBCollected; // Total BNB in contract
    uint256 public totalUSDTCollected;// Total USDT in contract
    bool    public finalized;
    bool    public presaleSuccess;
    bool    public softcapTriggered;
    uint256 public tgeTimestamp;

    // ─── Events ───────────────────────────────────────────────────────────────
    event TokensPurchased(
        address indexed buyer,
        uint256 usdAmount,
        uint256 gcoreAmount,
        uint8   phase,
        bool    isRush
    );
    event WhitelistAdded(address indexed investor);
    event WhitelistRemoved(address indexed investor);
    event PresaleFinalized(bool softcapReached, uint256 totalRaisedUSD);
    event SoftcapReleaseTriggered(uint256 totalRaisedUSD, uint256 usdtSentToOps);
    event RushToggled(bool active);
    event PhaseExhausted(uint8 indexed phaseIdx, address indexed closer, bool wasSweep);
    event ContractsLinked(address vesting, address refund, address ops);

    // ─── Constructor ──────────────────────────────────────────────────────────
    constructor(
        address _gcore,
        address _usdt,
        address _bnbPriceFeed,
        address admin
    ) {
        if (_gcore        == address(0)) revert ZeroAddress();
        if (_usdt         == address(0)) revert ZeroAddress();
        if (_bnbPriceFeed == address(0)) revert ZeroAddress();
        if (admin         == address(0)) revert ZeroAddress();

        gcore        = IGCOREToken(_gcore);
        usdt         = IERC20(_usdt);
        bnbPriceFeed = AggregatorV3Interface(_bnbPriceFeed);

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);

        _initPhases();
    }

    /// @notice Link dependent contracts after deployment.
    function setContracts(
        address _vesting,
        address _refund,
        address _ops
    ) external onlyRole(ADMIN_ROLE) {
        if (address(vestingContract) != address(0)) revert AlreadySet();
        if (_vesting == address(0)) revert ZeroAddress();
        if (_refund  == address(0)) revert ZeroAddress();
        if (_ops     == address(0)) revert ZeroAddress();

        vestingContract = IVestingContract(_vesting);
        refundContract  = IRefundContract(_refund);
        opsWallet       = IOpsWalletRelease(_ops);

        emit ContractsLinked(_vesting, _refund, _ops);
    }

    // ─── Whitelist ────────────────────────────────────────────────────────────
    function addToWhitelist(address investor) external onlyRole(OPERATOR_ROLE) {
        if (investor == address(0)) revert ZeroAddress();
        if (!investors[investor].whitelisted) {
            investors[investor].whitelisted = true;
            if (!_inInvestorList[investor]) {
                _inInvestorList[investor] = true;
                investorList.push(investor);
            }
            emit WhitelistAdded(investor);
        }
    }

    function addToWhitelistBatch(address[] calldata addrs) external onlyRole(OPERATOR_ROLE) {
        for (uint256 i = 0; i < addrs.length; i++) {
            if (addrs[i] != address(0) && !investors[addrs[i]].whitelisted) {
                investors[addrs[i]].whitelisted = true;
                if (!_inInvestorList[addrs[i]]) {
                    _inInvestorList[addrs[i]] = true;
                    investorList.push(addrs[i]);
                }
                emit WhitelistAdded(addrs[i]);
            }
        }
    }

    function removeFromWhitelist(address investor) external onlyRole(OPERATOR_ROLE) {
        investors[investor].whitelisted = false;
        emit WhitelistRemoved(investor);
    }

    // ─── Rush toggle (Phase VI only) ──────────────────────────────────────────
    function setPhaseVIRush(bool active) external onlyRole(OPERATOR_ROLE) {
        if (_activePhaseIndex() != 5) revert NotPhaseVI();
        phaseVIRushActive = active;
        emit RushToggled(active);
    }

    // ─── Purchase: BNB ────────────────────────────────────────────────────────
    function buyWithBNB() external payable whenNotPaused nonReentrant {
        if (finalized)          revert PresaleClosed();
        if (msg.value == 0)     revert NoBNBSent();
        if (!investors[msg.sender].whitelisted) revert NotWhitelisted();

        uint256 bnbPriceUSD = _getBNBPriceUSD();
        uint256 usdValue    = (msg.value * bnbPriceUSD) / 1e18;

        uint8 phaseIdx = uint8(_activePhaseIndex());
        bool  isRush   = _isRushPeriod(phaseIdx);

        uint256 gcoreAmount = _processPurchase(msg.sender, usdValue);

        investors[msg.sender].bnbPaid       += msg.value;
        investors[msg.sender].totalUSDPaid  += usdValue;
        totalBNBCollected                   += msg.value;
        totalRaisedUSD                      += usdValue;

        gcore.mint(address(vestingContract), gcoreAmount);
        vestingContract.addAllocation(msg.sender, gcoreAmount);

        emit TokensPurchased(msg.sender, usdValue, gcoreAmount, phaseIdx + 1, isRush);
    }

    // ─── Purchase: USDT ───────────────────────────────────────────────────────
    function buyWithUSDT(uint256 usdtAmount) external whenNotPaused nonReentrant {
        if (finalized)           revert PresaleClosed();
        if (usdtAmount == 0)     revert NoUSDTSent();
        if (!investors[msg.sender].whitelisted) revert NotWhitelisted();

        usdt.safeTransferFrom(msg.sender, address(this), usdtAmount);

        uint8 phaseIdx = uint8(_activePhaseIndex());
        bool  isRush   = _isRushPeriod(phaseIdx);

        uint256 gcoreAmount = _processPurchase(msg.sender, usdtAmount);

        investors[msg.sender].usdtPaid      += usdtAmount;
        investors[msg.sender].totalUSDPaid  += usdtAmount;
        totalUSDTCollected                  += usdtAmount;
        totalRaisedUSD                      += usdtAmount;

        gcore.mint(address(vestingContract), gcoreAmount);
        vestingContract.addAllocation(msg.sender, gcoreAmount);

        emit TokensPurchased(msg.sender, usdtAmount, gcoreAmount, phaseIdx + 1, isRush);
    }

    // ─── Finalize ─────────────────────────────────────────────────────────────
    /// @notice Sets the TGE date (only relevant on presale success). Call before finalize().
    function setTGETimestamp(uint256 ts) external onlyRole(ADMIN_ROLE) {
        if (finalized) revert AlreadyFinalized();
        tgeTimestamp = ts;
    }

    /// @notice Finalizes presale. Callable after 31.10.2027 or if all pools exhausted.
    function finalize() external onlyRole(ADMIN_ROLE) nonReentrant {
        if (finalized) revert AlreadyFinalized();
        if (block.timestamp <= phases[5].endTime && !_allPoolsExhausted()) revert PresaleStillActive();
        if (address(vestingContract) == address(0)) revert ContractsNotSet();

        finalized = true;
        presaleSuccess = totalRaisedUSD >= SOFTCAP_USD;

        if (presaleSuccess) {
            if (liquidityLock == address(0)) revert LiquidityLockNotSet();
            // Default: TGE = now + 30 days. Manual setTGETimestamp() is respected
            // only if it is earlier — it cannot push TGE beyond the 30-day default.
            if (tgeTimestamp == 0 || tgeTimestamp > block.timestamp + 30 days) {
                tgeTimestamp = block.timestamp + 30 days;
            }
            if (tgeTimestamp <= block.timestamp) revert TGEInPast();
        }

        vestingContract.setFundingLevel(totalRaisedUSD);
        emit PresaleFinalized(presaleSuccess, totalRaisedUSD);

        if (presaleSuccess) {
            _distributeOnSuccess(tgeTimestamp);
        } else {
            _transferToRefund();
        }
    }

    // ─── Admin: withdraw raised funds to custody (post-finalize, success) ─────
    function withdrawToCustody(address custodyAddress) external onlyRole(ADMIN_ROLE) nonReentrant {
        if (!finalized || !presaleSuccess) revert NotFinalizedOrSuccess();
        if (custodyAddress == address(0))  revert ZeroAddress();

        uint256 bnbBalance  = address(this).balance;
        uint256 usdtBalance = usdt.balanceOf(address(this));

        if (bnbBalance > 0) {
            (bool ok,) = custodyAddress.call{value: bnbBalance}("");
            if (!ok) revert BNBTransferFailed();
        }
        if (usdtBalance > 0) {
            usdt.safeTransfer(custodyAddress, usdtBalance);
        }
    }

    // ─── View helpers ─────────────────────────────────────────────────────────
    function getCurrentPhase() external view returns (uint8 phase, bool isRush) {
        uint256 idx = _activePhaseIndex();
        return (uint8(idx + 1), _isRushPeriod(uint8(idx)));
    }

    function getInvestorData(address investor) external view returns (InvestorData memory) {
        return investors[investor];
    }

    function getPhase(uint8 idx) external view returns (Phase memory) {
        return phases[idx];
    }

    function investorCount() external view returns (uint256) {
        return investorList.length;
    }

    // ─── Admin: trigger softcap release (mid-presale) ─────────────────────────
    function triggerSoftcapRelease() external onlyRole(ADMIN_ROLE) nonReentrant {
        if (softcapTriggered)           revert AlreadyTriggered();
        if (finalized)                  revert AlreadyFinalized();
        if (totalRaisedUSD < SOFTCAP_USD) revert SoftcapNotReached();
        _executeSoftcapRelease();
    }

    // ─── Pause ────────────────────────────────────────────────────────────────
    function pause()   external onlyRole(ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(ADMIN_ROLE) { _unpause(); }

    // ─── Internal: purchase logic ─────────────────────────────────────────────
    function _processPurchase(address buyer, uint256 usdValue) internal returns (uint256 gcoreAmount) {
        if (!investors[buyer].whitelisted) revert NotWhitelisted();

        uint256 phaseIdx    = _activePhaseIndex();
        Phase storage phase = phases[phaseIdx];

        if (usdValue < phase.minTicketUSD) revert BelowMinTicket();

        gcoreAmount = (usdValue * 1e18) / phase.pricePerGcore;

        if (_isRushPeriod(uint8(phaseIdx))) {
            gcoreAmount = (gcoreAmount * phase.rushMultiplier) / 1e18;
        }

        if (phase.tokensSold + gcoreAmount > phase.tokenPool) revert PhasePoolExhausted();
        phase.tokensSold += gcoreAmount;

        if (phase.tokensSold == phase.tokenPool) {
            emit PhaseExhausted(uint8(phaseIdx), buyer, false);
        } else if (phase.tokenPool > phase.tokensSold) {
            uint256 dust     = phase.tokenPool - phase.tokensSold;
            uint256 minGcore = phase.minTicketUSD > 0
                ? (phase.minTicketUSD * 1e18) / phase.pricePerGcore
                : 0;
            // Always use rush-adjusted effectiveMin so that dust which would
            // become unsellable once rush starts is swept immediately.
            uint256 effectiveMin = minGcore > 0
                ? (minGcore * phase.rushMultiplier) / 1e18
                : 0;
            if (effectiveMin > 0 && dust < effectiveMin) {
                phase.tokensSold  = phase.tokenPool;
                gcoreAmount      += dust;
                emit PhaseExhausted(uint8(phaseIdx), buyer, true);
            }
        }

        investors[buyer].gcoreAllocated += gcoreAmount;
    }

    // ─── Internal: phase detection ────────────────────────────────────────────
    function _activePhaseIndex() internal view returns (uint256) {
        bool prevExhausted = false;
        for (uint256 i = 0; i < 6; i++) {
            bool exhausted = phases[i].tokensSold >= phases[i].tokenPool;
            if (block.timestamp > phases[i].endTime) {
                if (exhausted) prevExhausted = true;
                continue;
            }
            if (exhausted) {
                prevExhausted = true;
                continue;
            }
            if (block.timestamp >= phases[i].startTime || prevExhausted) {
                return i;
            }
            revert("No active phase");
        }
        revert("No active phase");
    }

    function _isRushPeriod(uint8 phaseIdx) internal view returns (bool) {
        Phase storage phase = phases[phaseIdx];
        if (phaseIdx == 5) {
            return phaseVIRushActive &&
                   block.timestamp >= phase.rushStartTime;
        }
        return block.timestamp >= phase.rushStartTime;
    }

    // ─── Internal: Chainlink BNB price ────────────────────────────────────────
    function _getBNBPriceUSD() internal view returns (uint256) {
        (
            uint80  roundId,
            int256  answer,
            ,
            uint256 updatedAt,
            uint80  answeredInRound
        ) = bnbPriceFeed.latestRoundData();

        if (answer <= 0)                                          revert InvalidOraclePrice();
        if (updatedAt < block.timestamp - CHAINLINK_STALENESS)   revert StaleOraclePrice();
        if (answeredInRound < roundId)                            revert StaleOracleRound();

        return uint256(answer) * 1e10;
    }

    // ─── Internal: finalize helpers ───────────────────────────────────────────
    function _executeSoftcapRelease() internal {
        softcapTriggered = true;
        opsWallet.enableRelease();

        uint256 usdtBal = usdt.balanceOf(address(this));
        uint256 toSend  = usdtBal < OPS_RELEASE_USDT ? usdtBal : OPS_RELEASE_USDT;
        if (toSend > 0) usdt.safeTransfer(address(opsWallet), toSend);

        emit SoftcapReleaseTriggered(totalRaisedUSD, toSend);
    }

    function _distributeOnSuccess(uint256 _tgeTimestamp) internal {
        vestingContract.setTGE(_tgeTimestamp);

        if (!softcapTriggered) {
            _executeSoftcapRelease();
        }

        uint256 usdtBal = usdt.balanceOf(address(this));

        if (usdtBal >= DEX_LIQUIDITY_USDT) {
            usdt.safeTransfer(liquidityLock, DEX_LIQUIDITY_USDT);
        }
    }

    function _transferToRefund() internal {
        vestingContract.markPresaleFailed();

        uint256 usdtBalance = usdt.balanceOf(address(this));
        if (usdtBalance > 0) {
            usdt.safeTransfer(address(refundContract), usdtBalance);
            refundContract.depositUSDT(usdtBalance);
        }

        uint256 bnbBalance = address(this).balance;
        refundContract.enableRefund{value: bnbBalance}();
    }

    function _allPoolsExhausted() internal view returns (bool) {
        for (uint256 i = 0; i < 6; i++) {
            if (phases[i].tokensSold < phases[i].tokenPool) return false;
        }
        return true;
    }

    // ─── LiquidityLock address (set separately to break circular dep) ─────────
    address public liquidityLock;

    function setLiquidityLock(address _liqLock) external onlyRole(ADMIN_ROLE) {
        if (liquidityLock != address(0)) revert AlreadySet();
        if (_liqLock == address(0))      revert ZeroAddress();
        liquidityLock = _liqLock;
    }

    // ─── Phase initialization ──────────────────────────────────────────────────
    // Timestamps (UTC):
    //   Jan 1, 2027 = 1798761600   Feb 1 = 1801440000   Mar 1 = 1803859200
    //   Apr 1, 2027 = 1806537600   May 1, 2027 = 1809129600
    //   Jun 1, 2027 = 1811808000   Nov 1, 2027 = 1825027200
    function _initPhases() private {
        // Phase I — Genesis Awakens
        phases[0] = Phase({
            startTime:      1798761600,          // 01.01.2027
            endTime:        1801439999,          // 31.01.2027 23:59:59
            pricePerGcore:  0.04 ether,          // $0.04
            tokenPool:      50_000_000 * 1e18,
            tokensSold:     0,
            minTicketUSD:   10_000 * 1e18,       // $10,000
            rushMultiplier: 1.50 ether,          // ×1.50
            rushStartTime:  1800748800,          // 24.01.2027
            rushAlternating:false
        });

        // Phase II — Echoes of the Bastion
        phases[1] = Phase({
            startTime:      1801440000,          // 01.02.2027
            endTime:        1803859199,          // 28.02.2027 23:59:59
            pricePerGcore:  0.05 ether,          // $0.05
            tokenPool:      50_000_000 * 1e18,
            tokensSold:     0,
            minTicketUSD:   7_000 * 1e18,        // $7,000
            rushMultiplier: 1.25 ether,          // ×1.25
            rushStartTime:  1803168000,          // 21.02.2027
            rushAlternating:false
        });

        // Phase III — Architects Arise
        phases[2] = Phase({
            startTime:      1803859200,          // 01.03.2027
            endTime:        1806537599,          // 31.03.2027 23:59:59
            pricePerGcore:  0.06 ether,          // $0.06
            tokenPool:      50_000_000 * 1e18,
            tokensSold:     0,
            minTicketUSD:   5_000 * 1e18,        // $5,000
            rushMultiplier: 1.20 ether,          // ×1.20
            rushStartTime:  1805846400,          // 24.03.2027
            rushAlternating:false
        });

        // Phase IV — Founders Assemble
        phases[3] = Phase({
            startTime:      1806537600,          // 01.04.2027
            endTime:        1809129599,          // 30.04.2027 23:59:59
            pricePerGcore:  0.07 ether,          // $0.07
            tokenPool:      125_000_000 * 1e18,
            tokensSold:     0,
            minTicketUSD:   5_000 * 1e18,        // $5,000
            rushMultiplier: 1.20 ether,          // ×1.20
            rushStartTime:  1808438400,          // 23.04.2027
            rushAlternating:false
        });

        // Phase V — The Last Bastion
        phases[4] = Phase({
            startTime:      1809129600,          // 01.05.2027
            endTime:        1811807999,          // 31.05.2027 23:59:59
            pricePerGcore:  0.08 ether,          // $0.08
            tokenPool:      125_000_000 * 1e18,
            tokensSold:     0,
            minTicketUSD:   1_000 * 1e18,        // $1,000
            rushMultiplier: 1.25 ether,          // ×1.25
            rushStartTime:  1811116800,          // 24.05.2027
            rushAlternating:false
        });

        // Phase VI — The Last Gate (alternating rush, operator-controlled)
        phases[5] = Phase({
            startTime:      1811808000,          // 01.06.2027
            endTime:        1825027199,          // 31.10.2027 23:59:59
            pricePerGcore:  0.09 ether,          // $0.09
            tokenPool:      210_000_000 * 1e18,
            tokensSold:     0,
            minTicketUSD:   0,                   // Open — no min ticket
            rushMultiplier: 1.15 ether,          // ×1.15
            rushStartTime:  1824076800,          // 21.10.2027 (last 11 days)
            rushAlternating:true
        });
    }

    receive() external payable {}
}
