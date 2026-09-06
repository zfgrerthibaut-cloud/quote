# PareStocks diligence

Snapshot: 2026-09-05. Public frontend, APIs, explorer source and read-only RPC only.

## Verdict

PareStocks has real contracts and markets on Robinhood Chain: four active yield-stripping vaults,
their PT/YT tokens and eight Uniswap V3 pools were observed. Each checked vault held raw stock-token
collateral equal to both PT and YT supply.

It is also very early and operationally centralized. The accountant roles are controlled by two
EOAs, verified source is only a partial match, seed V3 positions remain withdrawable by EOAs,
lending is explicitly unaudited and thin, and no current buyback/burn flow supported the homepage's
present-tense `$PARE` claims.

## Actual mechanism

Each `asset × maturity` series has a vault, principal token and yield token.

- `split(amount)` takes 10 bps in the stock token and mints equal PT and YT for the remainder.
- `merge(amount)` burns equal PT and YT and returns the underlying stock token for no fee.
- `settle()` is permissionless after maturity, syncs the accountant and freezes the terminal
  dividend index.
- PT redeems the baseline exposure; YT redeems multiplier growth attributed to dividends, less a
  5% treasury share.
- PT/stock pools use 0.05% fees and YT/stock pools use 1% fees.

The oracle/accountant classifies ERC-8056 `uiMultiplier` changes. Simple positive changes up to 3%
fit the dividend band; clean integer-like ratios at least 20% away from 1 fit the split band. A
guardian can resolve composite/out-of-band events after a two-day delay, and that classification
changes the PT/YT economic split.

## Live scale observed

- Active series: AAPL-MAR27, SPY-MAR27, QQQ-MAR27 and PFE-MAR28.
- A fifth SCHD series existed with zero supply and no pools.
- Accountant coverage: 9 of 149 Robinhood stock tokens; 54 were labelled dividend-paying.
- Each accountant had only its initial checkpoint, so classification accuracy had no meaningful
  production history yet.
- The pSPY/USDG Morpho market showed 100 USDG supplied, 100 borrowed and zero available liquidity;
  the treasury EOA held all supply and borrow shares.

## Centralization and marketing boundaries

- Admin, guardian and one classifier role resolved to `0x854D…7022`; a second classifier was
  `0xA3c3…daF`. Both were EOAs at the snapshot.
- The same main EOA controlled 18 liquidity-position NFTs; the treasury controlled two.
- `$PARE` supply was fixed at one billion and had burn functions, but the public API reported zero
  burned supply and no zero-address transfer supported the advertised buyback/burn loop.
- The developer allocation was held by a lock contract, but its unlock date was 2026-12-01 rather
  than an unspecified permanent lock.
- Governance, holder fee discounts and priority capacity were roadmap claims, not active mechanics.

## Frontend finding not to reproduce

The terminal accepts transaction-critical URL overrides including RPC, chain ID, stock, vault,
accountant, router, position manager, wrapped native address, fee tiers and ranges. A crafted link
can retain the official domain and visual shell while redirecting approvals or writes to arbitrary
contracts. QUOTE must use a canonical deployment registry and reject production query-string
overrides.

Other frontend boundaries:

- injected wallets only;
- ethers loaded from a CDN;
- no visible CSP;
- some public data rendered with `innerHTML`;
- hard-coded fair-value assumptions could diverge materially from pool prices;
- LP creation used 90% amount minimums and underexplained out-of-range risk.

## What QUOTE reuses conceptually

- one unmistakable action surface;
- lifecycle and synchronization states in plain language;
- exact route, impact, minimum received, fee and freshness before a signature;
- contract facts and hypotheses displayed separately;
- a public cached read model carrying an explicit `asOf` timestamp;
- no claim of success before a canonical receipt.

QUOTE does not reuse PareStocks contracts, PT/YT economics, source, ABI, addresses, brand or
front-end layout.

## Public sources

- https://parestocks.com/
- https://parestocks.com/app
- https://parestocks.com/docs
- https://parestocks.com/oracle
- https://parestocks.com/lend
- https://parestocks.com/api/oracle
- https://parestocks.com/api/rh-tokens
- https://parestocks.com/api/market
- https://robinhoodchain.blockscout.com/address/0x4C3B4CDd55b2E9e60eefcD93234A77D4AD53e365
