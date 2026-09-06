# QUOTE protocol V2

## Product contract

V2 exposes one versioned market engine behind the launch interface:

- `DIRECT_V3`: a fixed-supply token opens directly in a one-sided PancakeSwap V3 position whose NFT
  is permanently locked.

There is no hidden presale. A creator may optionally buy the newly launched token in the same
transaction while paying in native BNB. The market engine is fixed at launch and cannot be switched
later. There is no custom bonding curve and no graduation transaction.

`Any quote` means that every launch may select one compatible BEP-20 quote. It does not mean that a
live market can replace its quote token.

```text
creator BNB
    |
    +--> WBNB
           |
           +--> quote token (skipped when quote == WBNB)
                    |
                    +--> newly launched token --> beneficiary

fixed launch supply --> one-sided Pancake V3 market --> permanent position locker
```

The complete launch and optional developer buy are atomic. If quote conversion, the market buy,
either minimum output, or the deadline fails, the token and pool creation revert with the rest of
the transaction.

## Launch modes and fees

The launchpad type system supports two token modes:

- `STANDARD`: a normal fixed-supply ERC-20 with exact wallet-to-wallet transfers;
- `REWARD`: the same transfer behavior, plus quote-token rewards funded from collected LP fees.

The current direct Pancake V3 product path accepts `STANDARD` only. `PancakeV3DirectEngine` rejects
`REWARD`, creator swap fees and reward fees; the launch UI keeps Reward disabled until the reward
hook path has a separate audit.

PancakeSwap V3 cannot enforce extra QUOTE, creator or reward taxes on every swap without making the
token itself taxed or forcing a bypassable router. The direct pool therefore charges only its
immutable Pancake fee tier, fixed at `10000` (1%). Collected LP fees use the immutable
creator/platform split recorded for the market:

```text
trader pays: Pancake V3 1% pool fee
LP fees go to: creatorLpShareBps + remaining platform share
```

Reward accounting contracts are pull-based, but they are not active in the direct launch path.
Explorer records derive their `REWARD` marker from the on-chain launch record; direct launches
currently emit standard records only.

## Quote eligibility

A custom quote is launchable only with a fresh EIP-712 attestation proving all of the following:

- the quote address and chain;
- the direct reference pool used for the observation;
- a reference asset that is either canonical WBNB or an allowlisted stablecoin;
- at least `10_000e18` USD of observed reference-pool liquidity;
- a positive quote price in USD;
- the observation time, deadline and a unique attestation id.

The attestation is bound to the verifier contract and chain id, consumed once, and expires quickly.
The signer may be rotated with a two-step administrative process, but a rotation changes only
future launches. It cannot change the quote, price, liquidity position or economics of an existing
market.

The signed liquidity value is a launch-safety gate, not a promise that liquidity will still exist in
the next block. The web service must simulate the selected route immediately before wallet signing
and clearly show its observation time.

The public backend endpoint `/v1/quote-token/eligibility` is read-only and unsigned. It returns
evidence for the UI and policy layer; it does not sign attestations, broadcast transactions or fetch
arbitrary creator URLs.

## Native developer buy

The optional developer buy accepts exactly `nativeAmount` BNB. There is no creation fee in the
current V2 launch request. Excess value reverts instead of creating a refund callback.

The native-buy coordinator is intentionally unable to execute arbitrary calldata:

- BNB is wrapped only by the immutable WBNB contract;
- the first swap is either a direct `WBNB -> quote` route or a two-hop
  `WBNB -> allowlisted stable -> quote` route;
- the second swap is the direct launch pool `quote -> launched token`;
- every hop uses an immutable Pancake router, an enabled fee tier, a deadline and an explicit
  minimum output;
- adapters are callable only by the coordinator and the coordinator only by the factory;
- balance deltas are measured, approvals are reset to zero and no token dust may remain.

The quote-liquidity attestation and the BNB route are separate checks. Passing the USD-liquidity
gate does not bypass route simulation or slippage protection.

## Immutable launch state

Every launch records at least:

- creator and developer-buy beneficiary;
- token, quote, reference asset and reference pool;
- attested quote price and observed USD liquidity;
- pool, position id and permanent locker;
- requested supply, deposited/final supply, start price, range, fixed fee tier and creation
  timestamp;
- target USD FDV, attested quote price, effective tick-aligned initial FDV and their bounded drift;
- content hashes for the immutable launch metadata and economic parameters.

Launch tokens have no owner mint, pause, blacklist or mutable transfer tax. The position locker has
no NFT approval, transfer or liquidity-decrease path. It accepts exactly the expected position NFT
and rejects all other ERC-721 receipts.

## Deployment boundary

V2 is a new versioned deployment. The existing V1 contracts remain unchanged. No mainnet address
may be placed in the frontend until bytecode, constructor immutables, source verification and the
deployment receipt have been independently checked. Contract implementation and fork tests do not
authorize signing or broadcasting a deployment.

## Upgrade boundary

QUOTE keeps one stable ERC-1967/UUPS launchpad address. The proxy owns only launch orchestration,
the versioned engine registry and immutable launch records. Engines are external implementation
contracts called normally, never by `delegatecall`; every launch records the exact engine version
that created it.

An upgrade can add validation or register a new engine for future launches. It cannot replace a
market's token, quote, pool, hook, vault, locker or fee configuration. Those per-launch contracts
are non-upgradeable. Disabling or pausing an engine stops only new launches and never pauses an
existing market.

Production administration uses one explicit upgrade-admin address, with no multisig or timelock as
requested. It must be a dedicated hardware-backed EOA whose powers are published. That admin may
upgrade the launchpad implementation and manage future engine versions immediately. Changing the
admin remains a two-step propose/accept operation, without a time delay, to avoid transferring
control to an unintended address.
