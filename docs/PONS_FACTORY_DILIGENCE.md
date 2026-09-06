# Pons Factory diligence

Snapshot: 2026-09-06. Read-only Robinhood Chain RPC, exact-match Sourcify source, receipts and
public product bundles.

## Verdict

`0xE1aD3F2C507c2d4128c166d5Fa78Cc86CC94913c` is an active third-party `PonsFactory`, not an
official Pons V1 or V2 deployment. It is nevertheless a useful direct-pool reference: each launch
creates a fixed-supply token, immediately initializes a one-sided Uniswap V3 token/quote pool,
mints the LP NFT to a locker, and can perform an atomic native dev buy.

The verified contract is not a proxy. Its source and metadata are available through
[Sourcify](https://sourcify.dev/server/v2/contract/4663/0xE1aD3F2C507c2d4128c166d5Fa78Cc86CC94913c?fields=all).
The official Pons deployment list is maintained separately in the
[Pons documentation](https://docs.ponsfamily.com/).

## Confirmed activity

- 80 launches from 53 creators using 11 quote assets.
- 40 launches included a native dev buy.
- All 80 position NFTs were minted to the configured locker; representative ownership reads were
  revalidated at the snapshot.
- 185 fee collections occurred across 63 positions.
- No bonding curve, graduation, native staking, holder rewards or buyback exists in this factory.
- The pool fee is 1%; collected LP fees are split 50/50 between creator and platform treasury.

The historical frontend is disabled, while read-only simulation indicates that the contract launch
entry point remains callable. Product availability and contract availability are different facts.

## Patterns QUOTE keeps

- Single atomic flow: token deployment, pool initialization, one-sided mint, permanent lock and
  optional dev buy.
- Native dev buy route `BNB -> WBNB -> quote -> launch token`, skipping the first swap for WBNB.
- Quote-centric discovery and filtering.
- Preview, simulation, signature, pending receipt and canonical confirmation as distinct states.
- Permissionless fee collection with pull-based recipient claims.

## Patterns QUOTE rejects

- Caller-supplied initial tick without an onchain 7,000 USD FDV bound.
- Caller-selected route fee with `minOut=0` permitted.
- Owner whitelist as sufficient proof of quote liquidity or compatibility.
- Mutable locker factory pointer or a `register` path capable of overwriting creator rights.
- Sequential CREATE addresses whose token ordering changes when another launch lands first.
- Treating a Pons graduation flag as permanent quote quality.

QUOTE instead uses CREATE2, binds the complete launch request into a fresh quote-liquidity
attestation, fixes the Pancake V3 fee tier, derives orientation/range from the predicted token
address, and verifies the position after mint before recording the launch.

## Indexer evidence

The relevant event families are equivalent to:

- market finalized;
- optional dev buy executed;
- position locked;
- LP fees collected;
- recipient claims.

A predicted token address is never indexed as launched. Confirmation requires a successful receipt,
the QUOTE factory event, code at token/pool/locker, the canonical Pancake factory mapping, exact
position tuple, nonzero NFT liquidity and locker ownership.
