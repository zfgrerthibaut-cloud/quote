# Public benchmark notes

Snapshot: 2026-09-05. Public pages, client bundles and read-only chain calls only.

## PareStocks

PareStocks is not a generic token launchpad. Its live product on Robinhood Chain 4663 wraps a
tokenized stock into two claims for a fixed series:

- PT represents the principal/baseline stock position.
- YT represents the ERC-8056 multiplier growth classified as dividends.
- PT + YT can merge back to the underlying.
- Public copy states a 10 bps split fee, zero merge fee and a 5% share of the drip.
- Its terminal exposes series lifecycle, split/merge/trade/earn actions, positions, multiplier
  facts and a classified event ledger.

The useful reference is the product discipline: one dominant action surface, sourced contract
facts, exact lifecycle language and a dense market terminal. QUOTE does not copy the stock
yield-splitting mechanism, visual assets, source, ABI, brand or contract addresses.

Public pages inspected:

- `https://parestocks.com/`
- `https://parestocks.com/app.html`
- `https://parestocks.com/docs.html`
- `https://parestocks.com/oracle.html`
- `https://parestocks.com/lend.html`

The public implementation was a collection of static HTML documents with inline application code
and ethers 6.13.4 loaded from a CDN at the snapshot. That is evidence about the visible client, not
proof of the source or safety of the deployed contracts.

## UniLaunch paired launches

UniLaunch is the closer functional benchmark for the requested product. Its current paired-launch
form on Robinhood Chain publicly advertises:

- a fixed 100 million token supply;
- all supply placed into single-sided Uniswap V3 liquidity;
- no creator allocation or later mint/burn function;
- a 1% pool;
- 70% of pool fees to the creator and 30% to the protocol;
- permanent liquidity locking;
- a short initial buy-rate limit.

At this snapshot, its network picker showed BNB Chain as **Coming soon** and disabled it. Therefore
the visible site is a design and product benchmark, not a live BSC implementation to reuse.

Public pages inspected:

- `https://unilaunch.fun/`
- `https://unilaunch.fun/paired/create?chain=robinhood`

## QUOTE boundary

QUOTE combines neither codebase. Its direct-launch protocol uses PancakeSwap V3 on BSC:

1. Deploy a capped-supply token with no owner authority or later mint; burn only tightly bounded
   Pancake rounding dust during the atomic launch.
2. Let the creator select an arbitrary contract address as quote token.
3. Create and initialize the canonical Pancake V3 pool atomically.
4. Mint the entire final supply into a correctly oriented one-sided range.
5. Mint the position NFT directly to a locker with no principal withdrawal path.
6. Split collected trading fees 70/30 through immutable destinations.

The frontend never labels arbitrary quote tokens safe or verified merely because their contract code
and metadata respond.
