# QUOTE

QUOTE is a BNB Chain launchpad where a creator can launch a fixed-supply token directly into a
one-sided PancakeSwap V3 pool against an eligible BEP-20 quote asset.

The production path has no proprietary bonding curve and no graduation step. The launch pool uses
the Pancake V3 1% fee tier. Initial price targets a $7,000 fully diluted valuation from a signed,
fresh quote-price observation. A quote asset must pass the backend's fail-closed liquidity and USD
reference checks before an attestation can be issued. The creator's share of collected LP fees is
configurable; fees remain pull-based in a permanent position locker.

## Workspace

- `app/` - QUOTE web interface and public Sites build.
- `backend/` - BSC indexer, PostgreSQL read model, REST/SSE/WebSocket API and isolated media worker.
- `contracts/` - Foundry sources, tests and broadcast-free BSC deployment rehearsal.
- `docs/` - protocol, security, indexer and VPS runbooks.
- `docker-compose.coolify.yml` - single-VPS service layout for an external BSC HTTP/WSS provider.

The broadcast-gated production sequence is documented in `docs/DEPLOYMENT.md`; it deliberately
contains no key or authenticated RPC endpoint.

## Current safety boundary

No QUOTE contract has been broadcast. The public frontend is a read-only product preview: it does
not sign or submit a launch. Reward mode stays disabled. Before a production launch, the proxy,
implementation, verifier, engine, registry runtime pins, quote-eligibility sources and dev-buy route
must all be configured and independently rechecked.

See `docs/DEPLOYMENT.md` for the no-broadcast preflight and the explicit receipt gate.
