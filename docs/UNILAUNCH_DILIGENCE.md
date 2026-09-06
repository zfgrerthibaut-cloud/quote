# UniLaunch diligence

Snapshot: 2026-09-05. Public pages, bundles, verified Base source and read-only RPC only.

## Verdict

UniLaunch is live on several chains, but not on BSC. Its BNB Chain page and bundle mark chain 56 as
`Coming soon`, contain no deployment object and block launch with no factory configured. No BSC
registry, factory, locker, router, quoter or deployment block was published.

Its live paired-launch mechanism on Base is the closest functional benchmark for QUOTE:

1. mine a CREATE2 salt;
2. deploy a fixed 100 million supply token;
3. create and initialize a V3 pool;
4. place all supply into a one-sided concentrated-liquidity position;
5. move the NFT to a permanent locker;
6. register the creator and split collected LP fees 70/30.

There is no proprietary bonding curve and no graduation. The concentrated V3 range is the launch
curve and final market.

## Important boundaries

- The initial three-minute rule limits each pool-to-buyer transfer to 0.5% of supply; it is not a
  per-wallet or cumulative limit and can be fragmented.
- 70% means 70% of LP fees remaining collectable after any underlying AMM protocol share, not 70%
  of every gross swap fee.
- The live registry owner can change creation fee, future price/range, pause status and treasury.
- Metadata is stored offchain in Supabase and accompanied by a creator signature; it is not token
  state or team verification.
- No audit report or security repository was found.
- Adoption was real but early: 24 classic and 26 paired `TokenCreated` events were observed on Base.

## BSC choice

QUOTE uses canonical PancakeSwap V3 rather than pretending UniLaunch has a BSC deployment:

- Factory: `0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865`
- NonfungiblePositionManager: `0x46A15B0b27311cedF172AB29E4f4766fbE7F4364`
- Router V3: `0x1b81D678ffb9C0263b24A97847620C99d213eB14`
- Quoter V2: `0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997`
- WBNB: `0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c`

Read-only RPC confirmed code at the factory and position manager and enabled tick spacings
`1/10/50/200` for fee tiers `100/500/2500/10000` at BSC block 120,162,155.

## Public sources

- https://unilaunch.fun/
- https://unilaunch.fun/paired/create?chain=robinhood
- https://unilaunch.fun/chain/bnb
- https://basescan.org/address/0xcaD4988e3421D5aB1E43403EAf0ad448C9ba09f7#code
- https://developer.pancakeswap.finance/contracts/v3/addresses
- https://developer.pancakeswap.finance/contracts/v3/nonfungiblepositionmanager
