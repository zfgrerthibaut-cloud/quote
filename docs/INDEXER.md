# QUOTE BSC market indexer

## Boundary

The browser never scans historical BSC logs and never treats a public RPC as a database. A
dedicated indexer follows finalized blocks, derives market state and price candles, and publishes a
small read model to the Site database. Wallet simulation and transaction submission still read the
current chain state directly.

```text
BSC WebSocket heads
       |
       v
confirmation buffer --> HTTP block/log proof reader --> decoder --> PostgreSQL reducer
                                                            |              |
                                                            |              +--> /v1/markets
                                                            |              +--> /v1/stream + /v1/ws
                                                            +----------------> raw event journal
```

## Chain correctness

- Persist a cursor per chain with the next block, last finalized block and hash.
- Process only blocks behind a configurable confirmation depth.
- Store recent block hashes and parent hashes. A mismatch rewinds to the common ancestor and
  replays the deterministic reducer.
- Uniquely identify every event by `(chain_id, tx_hash, log_index)`.
- Keep raw decoded events append-only inside a canonical block; derived rows are rebuildable.
- Never use a transaction hash alone as an event id because one transaction may emit many swaps.
- Pin contract addresses, deployment blocks, bytecode hashes and ABI version in a deployment
  registry. Unknown factory versions are quarantined instead of decoded heuristically.

## Indexed entities

The read model stores:

- launch record and immutable mode flags (`DIRECT_V3`, `STANDARD`/`REWARD`);
- token, quote, reference pool, canonical market pool, locker and reward vault;
- quote-price/liquidity attestation values and their observation time;
- pool initialization, position mint, lock-finalization and optional developer-buy receipts;
- swaps, quote volume, USD volume, trade count and unique trader estimates;
- current quote and USD price with source block and `as_of` timestamp;
- 1m, 5m, 1h and 1d OHLCV buckets;
- creator/platform fee accrual and claims;
- reward funding and holder claims.

All token amounts are stored as decimal strings or raw integer text. JavaScript floating point is
never authoritative for prices, volume or fees.

## Price derivation

The reducer applies canonical Pancake V3 swap events in log order and stores the resulting pool
price. USD price is `launch token / quote` multiplied by the fresh quote USD source used by the
pricing service. There is no bonding-market phase and no graduation transition.

Every response includes `block_number`, `block_hash` and `as_of`. Stale prices remain readable but
are marked stale; they are never silently presented as current. Market ordering uses materialized
statistics rather than live RPC fan-out.

### Quote eligibility and signer boundary

The current backend exposes a read-only, unsigned `POST /v1/quote-token/eligibility` endpoint. It:

1. reads the proposed Pancake V3 reference pool and token bytecode through BSC RPC;
2. checks the requested pool against the configured Pancake V3 factory and allowed fee tier;
3. reads token decimals, `slot0`, active liquidity, tick spacing and a bounded TWAP window;
4. requires the reference token to have an explicit `$1` allowlist entry or Chainlink USD feed;
5. requires at least `$10,000` conservative quote-side virtual depth by default.

That endpoint is a compatibility/liquidity gate, not a signature service. A production signer
service still has to issue short-lived EIP-712 attestations binding the final creator request hash,
quote, pool, reference token, USD price, USD liquidity, observation time, deadline, consumer and
nonce. Before signing real launches, extend it to use redundant RPC providers, executable-depth
simulation and adversarial quote-token checks.

The signing key belongs in a dedicated secrets/KMS boundary. It is never exposed to browser code,
the indexer database, build artifacts or logs. Signer rotation is two-step on-chain.

## High-load serving

- Cursor pagination only; no unbounded offsets.
- Composite indexes follow the actual Explorer sorts: newest, volume, liquidity and reward mode.
- Cache public list/detail responses briefly at the edge and use ETags from the latest indexed
  block plus query cursor.
- Batch indexer writes and use conflict-safe upserts.
- Limit ingest batches by rows and bytes; authenticate them with a rotating secret and reject
  out-of-order cursor transitions.
- Backpressure pauses ingestion before it corrupts order. The durable event journal is replayed
  after recovery.
- RPC calls use bounded block ranges, retry budgets and provider health scoring. WebSocket heads
  are only wake-up signals; HTTP block/log reads are the proof path.

## Operational gates

Before production traffic:

1. Replay from deployment to head twice and compare table checksums.
2. Inject synthetic one-, two- and twenty-block reorgs in tests.
3. Load-test list/detail APIs, ingest batches and cache-miss paths at the intended peak rate.
4. Verify rate limits on browser RPC, ingest, quote-attestation and image endpoints.
5. Alert on index lag, head divergence, reducer errors, stale price sources and failed Site ingests.
6. Keep a second RPC provider for proof reads; never rotate or spoof around provider controls.
7. Publish the indexer's latest finalized block and pricing timestamp in the UI.
