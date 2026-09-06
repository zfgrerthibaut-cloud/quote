# QUOTE V2 deployment rehearsal

`script/DeployQuoteV2.s.sol` is a broadcast-free BSC mainnet rehearsal script. It never calls
`vm.startBroadcast`, never reads a private key, and is meant to fail early on bad env or bad
Pancake dependencies before any real signing flow is introduced.

Run it against a BSC fork:

```bash
QUOTE_V2_UPGRADE_ADMIN=0x...
QUOTE_V2_PAUSE_GUARDIAN=0x...
QUOTE_V2_TREASURY=0x...
QUOTE_V2_PRICE_SIGNER=0x...
QUOTE_V2_MIN_LIQUIDITY_USD_WAD=10000000000000000000000
QUOTE_V2_MAX_OBSERVATION_AGE=900
QUOTE_V2_REFERENCE_TOKENS=0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c
BSC_RPC_URL=https://bsc-dataseed.bnbchain.org

forge script script/DeployQuoteV2.s.sol:DeployQuoteV2 --fork-url "$BSC_RPC_URL"
```

Required env:

- `QUOTE_V2_UPGRADE_ADMIN`: owner/admin for the proxy and verifier.
- `QUOTE_V2_PAUSE_GUARDIAN`: address allowed to pause new launches.
- `QUOTE_V2_TREASURY`: protocol treasury receiving the platform LP-fee share.
- `QUOTE_V2_PRICE_SIGNER`: backend signer for quote USD/liquidity attestations.
- `QUOTE_V2_MIN_LIQUIDITY_USD_WAD`: verifier threshold, minimum `10000e18`.
- `QUOTE_V2_MAX_OBSERVATION_AGE`: verifier freshness window in seconds, max `3600`.
- `QUOTE_V2_REFERENCE_TOKENS`: comma-separated reference tokens allowed in attestations.

The script deploys a `QuoteLaunchpad` implementation, an `ERC1967Proxy` with atomic
`initialize`, `V2QuoteUsdPriceVerifier`, and `PancakeV3DirectEngine`. It then simulates admin
calls to register, enable and set the direct engine as default.

Hard-coded BSC dependencies checked by preflight:

- PancakeSwap V3 Factory: `0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865`
- PancakeSwap V3 NonfungiblePositionManager: `0x46A15B0b27311cedF172AB29E4f4766fbE7F4364`
- PancakeSwap V3 SwapRouter: `0x1b81D678ffb9C0263b24A97847620C99d213eB14`
- WBNB: `0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c`

It also checks that the position manager and router report the same factory and WBNB, and that
Pancake's `10000` fee tier maps to `200` tick spacing.
