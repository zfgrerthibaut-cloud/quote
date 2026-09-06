# QUOTE deployment runbook

No QUOTE contract has been broadcast. A dry-run address is never a deployment address.

## Required decisions

Before any BSC transaction, record all of the following:

1. Treasury/admin address. The requested design uses no multisig and no timelock; use a dedicated
   hardware-backed EOA, never the deployer hot wallet, and publish every authority it retains.
2. Maximum acceptable deployment cost. QUOTE V2 currently has no creation fee; native value sent
   to `launch` is reserved for the optional atomic BNB dev buy.
3. Signing method and broadcaster address. Keep the key outside files, shell history and logs.
4. Explicit authorization for the target chain and broadcast transaction.
5. Independent review disposition for every open item in `SECURITY_REVIEW.md`.

## Reproducible preflight

```bash
forge fmt --check
forge build --sizes
forge test --no-match-path 'test/fork/*'
BSC_RPC_URL=https://bsc-dataseed.bnbchain.org forge test --match-path 'test/fork/*.t.sol'
slither . --exclude-dependencies --filter-paths 'test|script' \
  --detect reentrancy-eth,reentrancy-no-eth,suicidal,controlled-delegatecall,arbitrary-send-erc20
```

Run `script/DeployQuoteV2.s.sol` without `--broadcast` using the chosen admin, guardian, treasury,
attestation signer and reference-token policy. Confirm chain 56, canonical Pancake dependencies,
proxy/implementation addresses, runtime hashes, gas estimate and deployer balance. A
simulation success does not authorize the broadcast.

## Receipt gate

After an explicitly authorized broadcast:

1. Require a successful chain-56 receipt and record transaction hash, block and deployed address.
2. Read proxy admin/guardian state, implementation slot, engine registry/default version, verifier
   signer/policy, Pancake dependencies, protocol treasury and fixed pool fee directly onchain.
3. Match both proxy and implementation runtime code to the exact compiler output and verify the
   sources on BscScan.
4. Pin the proxy runtime, implementation address/runtime and exact ABI epoch in
   `QUOTE_INDEXER_REGISTRY_JSON`.
5. Add the confirmed launchpad proxy to `NEXT_PUBLIC_QUOTE_LAUNCHPAD`, rebuild and republish the site.
6. Re-run the frontend simulation with WBNB. Do not create a market merely to test the deployment
   unless that separate launch transaction is also explicitly authorized.

The frontend must remain read-only whenever the configured address, bytecode or immutable values do
not match the deployment record.

## VPS 90 / Coolify layout

The root `docker-compose.coolify.yml` fits the initial single-server deployment without running a
BSC node locally. It starts PostgreSQL, a one-shot migration job, the API/WebSocket process, the BSC
indexer, the bounded media worker and the frontend as separate containers. The configured hard
limits stay below 9 GB RAM and container logs rotate automatically.

Keep the RPC endpoints external. Expose only the frontend and API through HTTPS; PostgreSQL stays on
the private Docker network. Put all values from `.env.example` in Coolify, never in Git. Deployments
must fail while `DATABASE_URL`, BSC RPC endpoints, the indexer registry or web-origin allowlist are
missing. Plain registry entries pin the canonical ABI and runtime hash. UUPS entries additionally
pin proxy runtime, implementation slot/address and implementation runtime; the indexer revalidates
them on every sync and halts on drift.
