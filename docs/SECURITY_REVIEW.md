# Security review status

Snapshot: 2026-09-06. This is an internal engineering review, not an independent audit.

## Addressed during review

- `QuoteLaunchpad` is now the ERC-1967/UUPS orchestration point; deployment rehearsal creates the
  implementation and proxy without broadcasting.
- The direct engine is the only launch path for new markets. Legacy curve contracts remain in source
  but are not the active product path.
- Pool fee is fixed to Pancake V3 `10000`; creator LP-fee split is per-launch configurable and
  collected through pull-based locker claims.
- CREATE2 pool preinitialization was reduced by scanning up to 32 execution-time token candidates
  and rejecting initialized canonical pools.
- The signed launch request hash now covers token mode, complete fee config, recipients, treasury,
  fixed pool fee, quote decimals, reference assets, metadata and developer-buy parameters. It no
  longer includes global `launchId`, so another launch cannot invalidate an otherwise valid
  attestation by incrementing the counter first.
- Direct launch records and events store the actual final supply after bounded Pancake rounding dust
  instead of trusting only the requested supply.
- The permanent direct locker carries per-token creator remainders across collections and verifies
  exact claim debits.
- `InfinityRewardVault` tolerates donation surplus and rejects only under-delivery, but Reward mode
  remains disabled in the active launch UI and direct engine.
- Verifier ownership transfer clears stale pending signer state.
- The backend indexer stores canonical blocks/logs, supports reorg rollback/replay, indexes direct
  Pancake V3 swaps, exposes REST/SSE/WebSocket market data and pins runtime bytecode in the registry.
- UUPS registry entries now validate proxy runtime hash, ERC-1967 implementation slot/address and
  implementation runtime hash on every sync.
- The quote-token eligibility endpoint is read-only, unsigned, rate-limited, strict-JSON, CORS
  allowlisted, RPC-bounded and fail-closed. It checks actual pool-held quote balance as a cap on V3
  virtual liquidity.

## Remaining blockers

- Independent smart-contract audit is still required before any BSC broadcast. Static tools raised
  mostly expected warnings, but they do not replace manual review.
- Current CREATE2 entropy is not proposer-censorship resistant. A block proposer can observe or
  influence entropy within consensus limits.
- Arbitrary quote tokens can still tax, rebase, blacklist, selectively revert, upgrade or lie about
  balances. Eligibility is a launch policy gate, not a universal safety proof.
- Reward mode needs a separate design/audit before being enabled. The current production path must
  remain Standard/direct only.
- The deployment signer/admin/treasury addresses are not chosen here. No multisig or timelock is in
  the requested design, so the dedicated admin EOA custody and published powers matter more.
- Docker image builds were not proven locally in this environment because the local Docker daemon was
  unavailable earlier. Compose config must be rebuilt on the VPS or a working Docker host.
- SQL migrations have unit coverage through mocked Postgres calls, but should still be applied once
  against a disposable Postgres 16 database before production.

## Gates Before Writes

1. Run `forge fmt --check`, `forge build --sizes`, non-fork Foundry tests and BSC fork tests.
2. Run backend tests, typecheck and a disposable Postgres migration apply.
3. Dry-run `DeployQuoteV2.s.sol` on BSC without `--broadcast` using the final addresses.
4. Verify Pancake dependencies, proxy implementation slot, runtime code hashes and registry ABI
   hashes from direct RPC.
5. Configure `QUOTE_INDEXER_REGISTRY_JSON`, quote eligibility stable/feed policy, API origins and
   frontend launchpad address.
6. Rebuild and republish the frontend only after the receipt-backed address is known.

No mainnet deployment, source verification update or write-enabled frontend should happen before
these gates are closed.
