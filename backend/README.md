# QUOTE backend foundation

This directory starts the VPS-side source of truth for the QUOTE market feed and token media cache.

- BSC WSS is the low-latency discovery lane; canonical blocks and logs are re-read over HTTP RPC before the confirmed commit.
- `QUOTEMarketLaunched` from the configured QUOTE launchpad is the only launch source. Pancake pool events are enrichment, never proof of a QUOTE launch.
- Direct Pancake V3 valuation facts come from configured `DirectMarketLaunched` and `QuotePriceAttestationConsumed` events. If the direct engine or quote verifier ABI is not in the registry, those USD fields stay null instead of being guessed.
- PostgreSQL owns cursors, canonical/orphaned blocks, decoded markets, the replayable outbox and the persistent media cache.
- Token media is keyed by `(chain_id, token_address)`. Concurrent requests claim one leased row with a monotonic generation; stale workers cannot overwrite a newer result. Positive entries live 24 hours, negative entries 5 minutes, and retries are bounded.
- `GET /v1/media/token/56/:address` only reads cached objects and enqueues a bounded refresh for tokens already present in indexed markets. Provider fetches and Sharp decoding run only in the media worker.
- The production media worker must reconstruct approved JPEG/PNG/static-WebP input inside an isolated decoder before storing a content-addressed PNG/WebP. Raw provider or creator bytes are never served.
- Provider order is first-party creator media, DexScreener, optional GMGN OpenAPI, optional Codex API (the data layer used by Defined), then a deterministic UI placeholder. Paid providers stay disabled unless server-only credentials and redistribution permission are configured.
- Every indexed market automatically queues both its token and quote-token media. Public lookups for unknown addresses are not inserted into the queue.
- Canonical Pancake V3 swaps and LP-fee collection/claim events are journaled with exact EVM ordering and rational prices. One-minute candles and live totals are projections that can be dirtied and rebuilt after a reorg. QUOTE has no bonding or graduation phase.

This foundation deliberately contains no default RPC URL, launchpad address, database password or signing key. Runtime services must fail closed until explicit production configuration is supplied.

## API and realtime limits

The API process serves `/v1/markets`, `/v1/stream`, `/v1/ws`, `/v1/media/...` and
`/v1/quote-token/eligibility`. Browser origins must be listed in `QUOTE_WEB_ORIGINS`.
WebSocket upgrades reject a missing `Origin` header unless `QUOTE_WS_ALLOW_MISSING_ORIGIN=true`
is set for local/dev tooling. Do not enable that exception on the public API host.

Runtime caps:

- `QUOTE_HTTP_MAX_BODY_BYTES` defaults to `32768`.
- `QUOTE_WS_MAX_CLIENTS` defaults to `2000`.
- `QUOTE_WS_MAX_REPLAY_LAG` defaults to `50000` outbox events; older clients receive a resync signal.
- `QUOTE_WS_MAX_BUFFERED_BYTES` defaults to `1000000`.
- `QUOTE_SSE_ENABLED` defaults to `true`; set it to `false` only when WebSocket support is confirmed.
- `QUOTE_SSE_MAX_CLIENTS` defaults to `500`.
- `QUOTE_SSE_REPLAY_LIMIT`, `QUOTE_SSE_POLL_MS` and `QUOTE_SSE_HEARTBEAT_MS` default to `500`, `750` and `15000`.

All Node processes use the same bounded PostgreSQL client settings: `QUOTE_PG_POOL_MAX`,
`QUOTE_PG_CONNECT_TIMEOUT_MS`, `QUOTE_PG_IDLE_TIMEOUT_MS`, `QUOTE_PG_QUERY_TIMEOUT_MS`,
`QUOTE_PG_STATEMENT_TIMEOUT_MS` and `QUOTE_PG_IDLE_IN_TRANSACTION_TIMEOUT_MS`. The defaults are
sized for the single VPS compose file, not for running many replicas behind a load balancer.

Run:

```sh
npm install
npm test
npm run typecheck
```

## BSC indexer runtime

Run `npm run migrate`, then run `npm run start:indexer`. The process refuses to
start without all of these server-only variables:

- `DATABASE_URL`
- `BSC_HTTP_RPC_URL` (canonical block/log reads)
- `BSC_WSS_RPC_URL` (wake-ups only)
- `QUOTE_INDEXER_REGISTRY_JSON`

The registry is explicit and limited to chain 56. It contains no built-in contract address:

```jsonc
{
  "chainId": 56,
  "contracts": [
    {
      "address": "0x...",
      "startBlock": "12345678",
      "abiVersionHash": "0x...64 lowercase hex characters...",
      "runtimeCodeHash": "0x...64 lowercase hex characters...",
      "abi": [/* exact, unabridged event fragments from the verified deployment artifact */]
    },
    {
      "kind": "erc1967-uups",
      "address": "0x...proxy",
      "startBlock": "12345678",
      "abiVersionHash": "0x...64 lowercase hex characters...",
      "proxyRuntimeCodeHash": "0x...64 lowercase hex characters...",
      "implementationAddress": "0x...implementation",
      "implementationRuntimeCodeHash": "0x...64 lowercase hex characters...",
      "abi": [/* event fragments emitted through the proxy */]
    }
  ]
}
```

`abiVersionHash` is SHA-256 over the ABI encoded as canonical JSON (object keys sorted
recursively). `canonicalAbiVersionHash` in `src/indexer/registry.ts` is the authoritative helper.
An address can appear again at a later `startBlock` with a new ABI fingerprint; the newest active
entry wins. Anonymous events, hash mismatches, wrong chains and empty registries fail closed.
`kind` defaults to `plain`. For `erc1967-uups`, the indexer validates the proxy runtime hash, the
ERC-1967 implementation slot and the implementation runtime hash at a single latest validation
block on every sync. Legacy registry rows with a NULL runtime pin are fatal; re-run migration `011`
and install a complete registry instead of relying on implicit backfills.
Adding a registry entry whose `startBlock` is already behind the durable cursor also fails closed;
that change requires an explicit historical reset/backfill instead of silently skipping logs.

For direct launches, include event-only registry entries for the launchpad, the direct engine and
the quote-price verifier. `/v1/markets` recalculates direct market cap from the latest canonical
Pancake V3 `Swap` deltas when a swap exists, and recalculates displayed 24h volume from canonical
trades inside the selected API page. Quote USD values are labelled with the consumed attestation
timestamp/deadline; they are launch-time observations, not live oracle prices.

Optional tuning variables are `QUOTE_INDEXER_CONFIRMATION_DEPTH` (default `15`),
`QUOTE_INDEXER_CHUNK_SIZE` (`250`), `QUOTE_INDEXER_MAX_REORG_DEPTH` (`256`) and
`QUOTE_INDEXER_POLL_MS` (`15000`). WSS `newHeads` and exact-address log subscriptions only trigger
a sync. HTTP `eth_getBlockByNumber` and bounded `eth_getLogs` responses remain the proof path.

The runtime stores every traversed block so parent continuity is checked even when a block contains
no QUOTE event. A reorg increments the cursor generation, marks replaced blocks/logs non-canonical,
rolls back affected markets, emits ordered compensating events, and replays from the common
ancestor. Outbox producer keys are unique within a generation, so reconnects and repeated RPC logs
do not duplicate emissions while a later re-canonicalization can still be emitted.

DIRECT Pancake V3 pools are discovered from indexed `markets.market` rows. Each pool has its own
durable Swap cursor starting at the market launch block; WSS remains only a wake-up path and HTTP
`eth_getLogs` against the canonical Swap topic remains the proof path.

Run `npm run start:media-worker` separately to process the media queue. Optional tuning variables
are `MEDIA_WORKER_CONCURRENCY` (default `2`, max `4`), `MEDIA_WORKER_LEASE_SECONDS` (default `120`),
`MEDIA_WORKER_IDLE_MS` and `MEDIA_WORKER_ERROR_MS`.

## Quote-token eligibility API

`POST /v1/quote-token/eligibility` verifies one proposed quote/reference pool before the launch UI
allows a custom quote token. The request body is capped and accepts only:

```json
{
  "quoteToken": "0x...",
  "referenceToken": "0x...",
  "referencePool": "0x..."
}
```

The service never fetches arbitrary URLs, signs attestations, broadcasts transactions or guesses USD
prices. It checks chain 56 over direct JSON-RPC, token code and decimals, the requested Pancake V3
pool against the configured factory, pool fee and factory tick spacing, slot0, active liquidity, the
actual quote-token balance held by the pool and a bounded TWAP observation window. Reference USD
pricing must come from either an explicit `$1` stable allowlist or an explicit Chainlink feed
mapping. Any missing source, stale feed, wrong chain, bad pair, empty liquidity or low conservative
depth returns `eligible: false`.

Required to enable the endpoint:

- `BSC_HTTP_RPC_URL`
- `QUOTE_ELIGIBILITY_FACTORY_ADDRESS`
- `QUOTE_ELIGIBILITY_STABLE_USD_TOKENS` and/or `QUOTE_ELIGIBILITY_CHAINLINK_FEEDS_JSON`

Useful defaults and tuning:

- `QUOTE_ELIGIBILITY_ALLOWED_POOL_FEES` defaults to `10000` (Pancake V3 1%).
- `QUOTE_ELIGIBILITY_MIN_QUOTE_DEPTH_USD` defaults to `10000`.
- `QUOTE_ELIGIBILITY_TWAP_WINDOW_SECONDS` defaults to `900`.
- `QUOTE_ELIGIBILITY_MAX_BODY_BYTES` defaults to `1024`.
- `QUOTE_ELIGIBILITY_RATE_LIMIT_PER_MINUTE` defaults to `30`.
- `QUOTE_ELIGIBILITY_RPC_TIMEOUT_MS` defaults to `5000`.
- `QUOTE_ELIGIBILITY_RPC_MAX_ATTEMPTS` defaults to `2`.

`QUOTE_ELIGIBILITY_CHAINLINK_FEEDS_JSON` is an object keyed by reference token address:

```json
{
  "0xReferenceToken": {
    "feed": "0xChainlinkFeed",
    "maxAgeSeconds": 3600
  }
}
```
