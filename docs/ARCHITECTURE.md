# QUOTE architecture

## Product decision

The production path is `NEW_TOKEN + DIRECT_V3 + permanent Pancake V3 locker`.

```text
Launch form
   |
   v
read-only quote eligibility -> wallet simulation -> signed quote attestation
                                                     |
                                                     v
UUPS QuoteLaunchpad proxy -> fixed-supply token -> Pancake V3 1% pool
                                                  -> one-sided position NFT
                                                  -> PermanentPancakeV3Locker
                                                       | creatorLpShareBps
                                                       +--> creator fee recipient
                                                       | remainder
                                                       +--> protocol treasury
```

There is no internal bonding curve, no graduation transaction and no custom swap tax. Pancake V3's
one-sided range is the sale curve and the final market.

## Core contracts

- `QuoteLaunchpad` is the ERC-1967/UUPS entry point. It owns launch orchestration, the engine
  registry, pause state and immutable launch records.
- `PancakeV3DirectEngine` is the only enabled engine for new launches. It creates the token,
  initializes the canonical Pancake V3 pool, mints the one-sided NFT, locks it and optionally runs a
  BNB-funded developer buy.
- `PermanentPancakeV3Locker` permanently holds the V3 NFT. It can collect fees and expose
  pull-based claims only; it has no transfer, approval, liquidity decrease, burn or arbitrary-call
  path.
- `V2QuoteUsdPriceVerifier` consumes one fresh EIP-712 attestation per launch. It enforces the hard
  minimum quote-liquidity floor and rejects replayed or stale attestations.

Reward contracts remain in source for future work, but the active direct engine rejects reward mode,
creator swap fees and reward fees. The UI keeps Reward disabled.

## Launch safety

- Initial FDV targets `7,000e18` USD from requested supply and the attested quote USD price.
- Launch pool fee is fixed at Pancake V3 `10000` (1%); creators cannot configure the Pancake fee.
- Creator/platform LP-fee split is configurable per launch through `creatorLpShareBps`.
- New tokens have no owner mint, pause, blacklist, mutable tax or holder burn. The direct engine can
  burn only bounded launch dust inside the same atomic launch.
- Requested supply is bounded from `1e12` raw units to `uint128.max`; dust must stay at or below one
  trillionth of requested supply.
- The engine scans up to 32 execution-time CREATE2 candidates and skips initialized canonical pools.
  This removes ordinary public mempool preinitialization, but the current block proposer can still
  observe or influence block entropy within consensus limits.
- Any initialized canonical pool is rejected even if current in-range `liquidity()` is zero. An
  uninitialized canonical pool may be initialized by the launch.

`Permissionless quote` is a compatibility boundary, not an endorsement. Arbitrary quote tokens may
tax, rebase, blacklist, selectively revert, upgrade or lie through metadata. The platform can
isolate many failures; it cannot prove an arbitrary token is safe.

## Backend path

The backend is the source of truth for Explorer and token media:

```text
BSC WSS heads/log hints
       |
       v
confirmed HTTP RPC block/log proof -> decoder -> Postgres canonical journal
                                             |
                                             +--> markets, trades, candles, live stats
                                             +--> SSE/WebSocket/API read model
                                             +--> bounded media queue/cache
```

WSS is only a wake-up lane. HTTP RPC re-reads canonical blocks/logs behind a confirmation buffer.
The indexer stores block hashes, handles reorg rollback/replay, and uses a registry that pins ABI
hashes plus runtime bytecode. Plain contracts pin their own runtime hash. UUPS entries pin proxy
runtime, implementation slot/address and implementation runtime; the indexer revalidates active
pins on every sync and halts on drift.

`/v1/quote-token/eligibility` is read-only and unsigned. It verifies chain 56, token code/decimals,
canonical Pancake V3 pool/factory/tick spacing, TWAP, explicit stable or Chainlink USD source, and a
conservative quote-depth floor. It uses the lesser of active V3 virtual depth and the actual quote
token balance held by the pool, so narrow concentrated liquidity cannot pass purely through
overstated virtual reserve math.

Token images are fetched only by the media worker, sanitized through Sharp, stored by content hash
and served from cache. Public media requests for unknown tokens do not trigger arbitrary provider
fetches.

## Deployment boundary

No contract has been broadcast from this repository. The current public Site is a read-only product
preview until a receipt-backed BSC deployment is configured.

Before enabling writes, record the admin/treasury/signer addresses, simulate deployment without
`--broadcast`, verify proxy and implementation runtime hashes, pin the exact registry entries, set
the frontend launchpad address, rebuild, republish and re-run wallet simulation.
