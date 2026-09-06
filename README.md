# GCORE — Genesis Presale Smart Contracts

Smart contracts for the **Genesis Core Token (GCORE)** presale on **BNB Chain**.  **Not yet pushed on mainnet**

This repository contains the full, unmodified Solidity source of the eight production
contracts — the seven presale contracts in [`src/`](src/) plus the standalone Early Bird
sale in [`earlybird/`](earlybird/). It is published for exchange listings, launchpad
reviews and independent audit

| | |
|---|---|
| **Token** | Genesis Core Token (`GCORE`) |
| **Standard** | BEP-20 (ERC-20 + Burnable + Permit) |
| **Chain** | BNB Chain |
| **Max supply** | 700,000,000 GCORE (hard cap, enforced in `mint()`) |
| **Solidity** | `^0.8.24` (presale) · `0.8.35` (Early Bird) |
| **Dependencies** | OpenZeppelin Contracts (only) |
| **License** | MIT |

---

## Contracts

| Contract | Purpose |
|---|---|
| [`GCOREToken.sol`](src/GCOREToken.sol) | The BEP-20 token. Fixed allocations minted at deployment; the presale portion is minted on-demand as tokens are sold. |
| [`PresaleContract.sol`](src/PresaleContract.sol) | The 6-phase presale. Accepts BNB (priced via Chainlink) and USDT, enforces per-phase pools and minimum tickets, and finalizes into either the success or refund path. |
| [`VestingContract.sol`](src/VestingContract.sol) | Holds every investor's GCORE and releases it linearly after TGE. Vesting length is set by how much the presale raised. |
| [`RefundContract.sol`](src/RefundContract.sol) | Investor-initiated refunds if the softcap is missed. Repays in the original currency. |
| [`OpsWalletRelease.sol`](src/OpsWalletRelease.sol) | One-time, purpose-restricted USD 550,000 operational release after softcap, authorised by the project Safe. |
| [`TeamVesting.sol`](src/TeamVesting.sol) | The 52,000,000 GCORE team allocation: 12-month cliff, then 24-month linear, every withdrawal authorised by the project Safe. |
| [`LiquidityLock.sol`](src/LiquidityLock.sol) | Adds the initial PancakeSwap V2 liquidity and locks the resulting LP tokens for 24 months. |
| [`earlybird/SeedContract.sol`](earlybird/SeedContract.sol) | Standalone Early Bird (Phase 0) sale, ahead of the presale. Records USDT-paid allocations on-chain; those allocations are later imported into `VestingContract`. |

---

## Token allocation

Maximum supply is **700,000,000 GCORE**. Only 90,000,000 exist at deployment; the
remaining 610,000,000 are minted one purchase at a time, so **unsold presale tokens are
never created**.

| Allocation | Amount | Share | Minted |
|---|---:|---:|---|
| Presale | 610,000,000 | 87.14 % | Mint-as-sold, per purchase |
| Team | 52,000,000 | 7.43 % | At deployment → `TeamVesting` |
| DEX liquidity | 28,000,000 | 4.00 % | At deployment → `LiquidityLock` |
| Community | 10,000,000 | 1.43 % | At deployment → community wallet |

---

## Early Bird (Phase 0)

[`earlybird/SeedContract.sol`](earlybird/SeedContract.sol) is a **standalone** contract for
the Early Bird round that precedes the presale. It has no dependency on the seven presale
contracts and is deployed on its own.

**Live on BNB Chain:**
[`0x23e2215a2eFF8937B9c8DfDFcD2A4e4EE08D1Ed2`](https://bscscan.com/address/0x23e2215a2eFF8937B9c8DfDFcD2A4e4EE08D1Ed2)

| | |
|---|---|
| **Price** | 0.02 USDT per GCORE (50 GCORE per 1 USDT) |
| **Minimum** | 100 USDT |
| **Hardcap** | 10,000,000 GCORE |
| **Payment** | USDT (BEP-20) only |
| **Access** | KYC approval required per address |

Investors pay USDT and receive an on-chain **allocation record** — no GCORE moves at
purchase time and there is no on-chain claim here. USDT goes straight to the treasury
address; the contract never custodies funds. Allocations are honoured after TGE, and are
pulled into the main `VestingContract` through its permissionless, paginated
`importFromSeed()`, so Early Bird investors vest on the same schedule as presale investors.
Tokens are only distributed if the public presale reaches its softcap.

A remainder below the minimum purchase could never be bought and would strand the hardcap,
so the final buy absorbs it and the sale closes exactly at 10,000,000 GCORE.

**Access control** mirrors the presale contracts: ownership is `Ownable2Step` and held by a multisig, with `renounceOwnership()` overridden to revert so the sale can
never be left unowned — it must stay stoppable and the operator key must stay rotatable. A
separate low-privilege `operator` hot wallet lets the KYC backend approve addresses
automatically; the operator can flip the KYC flag and nothing else — no access to funds, no
control over the sale, the treasury or ownership.

---

## Presale structure

Six sequential phases, January – October 2027. Each phase has its own price, token pool
and minimum ticket. A phase ends when its window closes **or** its pool is sold out —
whichever happens first.

| Phase | Name | Price | Window | Pool | Min. ticket | Rush |
|---|---|---:|---|---:|---:|---:|
| I | Genesis Awakens | $0.04 | 01.01 – 31.01.2027 | 50,000,000 | $10,000 | ×1.50 |
| II | Echoes of the Bastion | $0.05 | 01.02 – 28.02.2027 | 50,000,000 | $7,000 | ×1.25 |
| III | Architects Arise | $0.06 | 01.03 – 31.03.2027 | 50,000,000 | $5,000 | ×1.20 |
| IV | Founders Assemble | $0.07 | 01.04 – 30.04.2027 | 125,000,000 | $5,000 | ×1.20 |
| V | The Last Bastion | $0.08 | 01.05 – 31.05.2027 | 125,000,000 | $1,000 | ×1.25 |
| VI | The Last Gate | $0.09 | 01.06 – 31.10.2027 | 210,000,000 | — | ×1.15 |

**Rush** runs in the final 7 days of each phase (11 days in Phase VI, where it is
operator-toggled). The multiplier increases the **token quantity received**, not the
price paid — the buyer's USD outlay is unchanged.

- **Softcap:** USD 12,115,000
- **Hardcap:** USD 44,000,000
- **Payment:** BNB or USDT. BNB is converted at the Chainlink BNB/USD rate, rejected if
  the feed is stale (>1 h), non-positive, or from a stale round.
- **Access:** purchasing requires KYC whitelisting.

### Outcome at finalization

**Softcap reached** — the vesting tier is locked in, TGE is set, the operational release
is enabled and USD 2,800,000 moves to `LiquidityLock` for the DEX launch.

**Softcap missed** — all BNB and USDT move to `RefundContract` and investors have
**180 days** to call `claimRefund()` and be repaid in their original currency. The
undistributed GCORE held in `VestingContract` can then be burned.

---

## Vesting

### Investors

There is **no TGE unlock**: 0 % at launch, then pure per-second linear release over the
full duration. Every investor gets the same schedule regardless of which phase they
bought in — the duration is set once, at finalization, by the total raised.

| Tier | Total raised | Vesting duration |
|---|---|---:|
| 1 | Softcap ($12.115M) | 12 months |
| 2 | ≥ $20M | 15 months |
| 3 | ≥ $28M | 18 months |
| 4 | ≥ $36M | 21 months |
| 5 | ≥ $44M (Hardcap) | 24 months |

A stronger raise means a **longer** vest, which is deliberate: more capital raised means
more sell pressure to spread out.

### Team

The team allocation is anchored to the **same TGE as investors**, read live from
`VestingContract` — it cannot be set independently, and the team clock only starts if the
presale actually finalizes successfully.

| Milestone | Unlocked |
|---|---:|
| TGE | 0 % |
| TGE + 12 months | 34 % (cliff unlock) |
| TGE + 12 … 36 months | 34 % → 100 %, linear |
| TGE + 36 months | 100 % |

The team's first tokens arrive at the 12-month mark, the point where Tier-1 investors are
already fully unlocked. Every withdrawal is additionally gated by the project Safe, and
can never exceed what has already vested — the schedule itself is immutable and cannot be
shortened, accelerated or bypassed by anyone, the owner included.

Throughout both schedules, **1 month = exactly 30 days**.

---

## Liquidity

`LiquidityLock` holds 28,000,000 GCORE plus the USD 2,800,000 forwarded at finalization,
seeds the PancakeSwap V2 GCORE/USDT pair at a launch price of **USD 0.10**, and locks the
LP tokens it receives for **24 months** (`LOCK_DURATION = 730 days`). `withdrawLP()`
reverts with `StillLocked` until the timestamp passes — there is no admin override, no
early-unlock path and no upgrade proxy.

---

## Security notes for reviewers

- **No proxies, no upgradeability.** Every contract is immutable once deployed.
- **No mint function for the owner.** `GCOREToken.mint()` is `MINTER_ROLE`-only, that role
  is granted exactly once to `PresaleContract` via a one-time `setPresaleContract()`, and
  it still cannot exceed `MAX_SUPPLY`.
- **Reentrancy:** all value-moving functions are `nonReentrant` and follow
  checks-effects-interactions.
- **Token transfers** use OpenZeppelin `SafeERC20`.
- **Oracle:** Chainlink BNB/USD with staleness, round and sign validation.
- **Refunds are pull-based:** investors call `claimRefund()` themselves; there is no
  push loop to grief or run out of gas.
- **Safe-owned treasury contracts:** `OpsWalletRelease` and `TeamVesting` are owned by the
  project Safe (Gnosis Safe), so every withdrawal carries the Safe's M-of-N approval.
  Ownership uses `Ownable2Step` — a transfer only completes once the new owner explicitly
  accepts, so control can never be handed to an unusable address. Neither contract exposes
  a path to move funds that have not vested.
- **Custom errors** throughout instead of revert strings.

### Roles

| Role | Held by | Can do |
|---|---|---|
| `ADMIN_ROLE` | Project Safe | Link contracts, pause/unpause, finalize, set TGE, withdraw raised funds post-success |
| `owner` (`Ownable2Step`) | Project Safe | `TeamVesting` / `OpsWalletRelease`: trigger a withdrawal of already-vested or already-released funds |
| `OPERATOR_ROLE` | KYC backend | Add/remove whitelist entries, toggle Phase VI rush |
| `MINTER_ROLE` | `PresaleContract` only | Mint GCORE within `MAX_SUPPLY`, one purchase at a time |
| `PRESALE_ROLE` | `PresaleContract` only | Record allocations, set funding level and TGE, trigger the refund path |

Admin rights and ownership are transferred to the project Safe after deployment. Admins can
pause and can move **raised funds** (BNB/USDT) to the designated custody address after a
successful presale; they cannot mint GCORE, cannot alter an investor's allocation, and
cannot shorten any lock or vesting schedule.

---

## Build

Dependencies are limited to OpenZeppelin Contracts. With [Foundry](https://book.getfoundry.sh/):

```bash
git clone https://github.com/Genesis-of-the-Grid/gcore-contracts.git
cd gcore-contracts

forge install OpenZeppelin/openzeppelin-contracts@v5.6.1

forge build                              # the seven presale contracts
FOUNDRY_PROFILE=earlybird forge build    # the Early Bird contract
```

The two builds are separate because the Early Bird contract is already deployed and was
compiled with different settings than the presale contracts will be — see the table below.

**Pin the OpenZeppelin tag.** `v5.6.1` is the version the deployed contracts were compiled
against; installing any other version produces different bytecode and verification will not
match. `foundry.toml` in this repository pins the rest of what verification depends on:

| Setting | Presale (`src/`) | Early Bird (`earlybird/`) |
|---|---|---|
| `solc` | `0.8.35` | `0.8.35` |
| `evm_version` | `cancun` | **`paris`** |
| `optimizer` | enabled, `200` runs | enabled, `200` runs |
| `bytecode_hash` | `none` | default (metadata kept) |

Reproducing bytecode requires all of these to match, plus the OpenZeppelin tag.

For the presale contracts, `bytecode_hash = "none"` is deliberate: Solidity otherwise
appends a metadata hash covering each source file's *path*, so the same code compiled from
a different directory layout produces different bytecode. Omitting it makes the build
path-independent, and a clean clone of this repository reproduces the deploy build byte for
byte — verified for all seven.

The Early Bird contract is **already deployed**, so its settings are fixed by what is on
chain: `evm_version = "paris"` and the metadata hash left in place.

Its deployed **runtime code matches this source exactly** — byte for byte, once the two
immutable slots (both the BNB Chain USDT address) are accounted for. The trailing metadata
hash differs, and unavoidably so: that hash covers each source file's path, and the
contract was deployed from a standalone project where it sat at `src/SeedContract.sol`
rather than `earlybird/SeedContract.sol`. To reproduce the metadata hash as well, place the
file at `src/SeedContract.sol` in its own Foundry project using the Early Bird settings
above. The authoritative verified source for the deployed contract is on
[BscScan](https://bscscan.com/address/0x23e2215a2eFF8937B9c8DfDFcD2A4e4EE08D1Ed2#code).

---

## Deployment order

`earlybird/SeedContract.sol` is independent — it is deployed on its own, ahead of and
separately from everything below, and takes no constructor reference to any of these
contracts. The link runs the other way and only later: `VestingContract.setSeedContract()`
followed by `importFromSeed()`.

The seven presale contracts have circular references, so they are wired up in this order:

1. `LiquidityLock`, `TeamVesting`, `VestingContract`
2. `GCOREToken` — mints the three fixed allocations in its constructor
3. `PresaleContract`
4. `GCOREToken.setPresaleContract()` — grants `MINTER_ROLE`, one-time
5. `RefundContract`, `OpsWalletRelease`
6. `PresaleContract.setContracts()` and `setLiquidityLock()`; grant `PRESALE_ROLE` on the
   dependent contracts
7. Hand `TeamVesting` and `OpsWalletRelease` to the Safe: `transferOwnership(safe)`,
   then the Safe calls `acceptOwnership()` on both (`Ownable2Step`)

Each linking function is guarded by an `AlreadySet` check and can only be called once.

---

## License

MIT — see [LICENSE](LICENSE).
