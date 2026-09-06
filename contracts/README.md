# QUOTE contracts

QUOTE V2 launches a new fixed-supply ERC-20 directly into a one-sided PancakeSwap V3
position against a caller-selected BEP-20 quote token on BSC.

## Current product path

- `QuoteLaunchpad` is the ERC-1967/UUPS entry point. It owns launch orchestration, the versioned
  engine registry, pausing of new launches and immutable launch records.
- `PancakeV3DirectEngine` is the only engine kind accepted for new launches. Curve contracts and
  reward contracts remain in source for compatibility and future review, but the current direct
  engine rejects `CURVE`, non-standard token modes, creator swap fees and reward fees.
- One launch transaction creates `QuoteDirectToken`, initializes the canonical Pancake V3 pool,
  mints the one-sided position, transfers the NFT to `PermanentPancakeV3Locker`, optionally runs a
  BNB-funded developer buy, and records the market.
- No mainnet deployment has been broadcast from this repository. Dry-run scripts and tests do not
  authorize signing.

## Direct V3 properties

- The start price is derived onchain from a fixed `7_000e18` USD target FDV, requested supply,
  quote decimals and a fresh `V2QuoteUsdPriceVerifier` attestation.
- The launch pool fee is fixed at `POOL_FEE = 10_000` (Pancake V3 1%). Callers cannot select
  another fee tier for the launch pool.
- The verifier has a hard minimum quote-liquidity floor of `10_000e18` USD. The configured
  deployment value cannot be lower than that hard floor.
- Quote, reference-token and reference-pool addresses must contain runtime code. Quote decimals
  above 36 or unavailable `decimals()` metadata are rejected.
- The token has no owner, later mint, holder burn, pause, blacklist or transfer tax. Only the direct
  engine can burn bounded launch dust during the same atomic launch.
- The entire final token supply must enter the V3 position. Pancake rounding dust is bounded to one
  trillionth of the requested supply; larger under-consumption reverts.
- Requested supply is bounded from `1e12` raw units to `uint128.max`, so the one-trillionth dust
  ceiling remains exact at the lower bound.
- The position locker exposes fee collection and pull-based claims only. It has no NFT approval,
  NFT transfer, liquidity decrease, burn or arbitrary-call path.
- Collected V3 fees are measured by actual token balance deltas. `creatorLpShareBps` is recorded
  per launch; that share is claimable by the creator fee recipient and the remainder is claimable by
  the protocol treasury. Per-token remainder carry prevents systematic rounding loss.
- Claims verify the exact token debit, so a malicious quote token cannot satisfy a claim while
  leaving the locker under-debited.

`permissionless quote` does not mean `safe quote`. The contracts verify code, attestation fields
and compatibility boundaries; they cannot prove that an arbitrary quote token is valuable,
transferable, non-rebasing, non-upgradeable or free of blacklists.

## V2 direct engine

`PancakeV3DirectEngine` computes token ordering from the selected CREATE2 candidate. Aligned
one-sided ticks use the nearest strict boundary and Pancake's 200-tick spacing for the fixed 1%
fee tier.

The engine scans up to `MAX_TOKEN_CANDIDATES = 32` CREATE2 salts. Live salts mix creator input with
execution-time entropy from the parent block hash, `prevrandao`, timestamp and coinbase, then skip
already initialized canonical pools. This prevents ordinary public mempool observers from knowing
the final token address before execution. It is not proposer-censorship resistance: the current
block proposer can still know or influence the entropy within consensus limits. If every candidate
is already initialized or invalid, the launch reverts.

Any already initialized canonical pool is rejected from `slot0.sqrtPriceX96`, including an
exact-price pool whose active `liquidity()` is zero because all liquidity is out of range. A
canonical pool that exists but still has `slot0.sqrtPriceX96 == 0` may be initialized by the launch.

Pool initialization, one-sided mint, bounded dust burn, exact NFT transfer to the permanent locker
and all balance/position postconditions are atomic.

An optional developer buy is a typed BNB-funded step after launch postconditions. BNB is wrapped to
WBNB, then swapped through one explicitly selected, canonical Pancake V3 WBNB/quote pool and the
fixed-fee launch pool. If quote is WBNB, only the launch-pool swap executes. The payload binds
exact native value, quote route/tier, both minimum outputs, price limits, beneficiary and a deadline
no later than the launch deadline. Unspent WBNB is unwrapped and refunded as BNB; unspent non-WBNB
quote is refunded as quote. No arbitrary target or calldata is accepted.

The EIP-712 price attestation binds the engine consumer, creator and a launch-request hash. That
hash covers chain, engine kind/version, creator, quote, supply, native amount, launch deadline,
token mode, full fee configuration, fee recipients, treasury, fixed pool fee, quote decimals,
reference assets, metadata and every developer-buy parameter. The global `launchId` is intentionally
not part of the signed request hash, so another launch cannot invalidate an otherwise valid
attestation by incrementing the launch counter first.

## Canonical BSC dependencies

- PancakeSwap V3 Factory: `0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865`
- PancakeSwap V3 NonfungiblePositionManager: `0x46A15B0b27311cedF172AB29E4f4766fbE7F4364`
- PancakeSwap V3 SwapRouter: `0x1b81D678ffb9C0263b24A97847620C99d213eB14`
- WBNB: `0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c`

These addresses and the `10000 -> 200` Pancake tick-spacing mapping must be re-read before
deployment. The deployment script refuses any chain other than BSC mainnet and checks all
dependencies contain code.

## Local verification

```bash
forge fmt --check
forge build --sizes
forge test --no-match-path 'test/fork/*'
BSC_RPC_URL=https://bsc-dataseed.bnbchain.org forge test --match-path 'test/fork/*.t.sol'
```

A broadcast-free deployment rehearsal against chain 56 uses placeholder admin, signer and treasury
values. It deploys a launchpad implementation, an ERC-1967 proxy, the verifier and the direct
engine inside the fork, then simulates engine registration. Never treat a dry-run address as a
deployed contract.

No contract has been deployed and no transaction is broadcast by the test or build commands.
Deployment requires separate explicit authorization, final admin/guardian/treasury/signer
addresses, verified source artifacts and a signing setup.
