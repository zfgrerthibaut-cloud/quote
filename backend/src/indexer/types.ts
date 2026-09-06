export type Hex = `0x${string}`;
export type Address = `0x${string}`;
export type RpcBlockTag = bigint | 'latest';

export type RpcBlock = Readonly<{
  number: bigint;
  hash: Hex;
  parentHash: Hex;
  timestamp: bigint;
}>;

export type RpcLog = Readonly<{
  address: Address;
  blockHash: Hex;
  blockNumber: bigint;
  transactionHash: Hex;
  transactionIndex: number;
  logIndex: number;
  topics: readonly Hex[];
  data: Hex;
  removed: boolean;
}>;

export type DecodedQuoteLog = RpcLog & Readonly<{
  eventName: string;
  eventSignature: string;
  abiVersionHash: Hex;
  args: Readonly<Record<string, unknown>>;
}>;

export type IndexerCursor = Readonly<{
  chainId: number;
  canonicalNumber: bigint;
  canonicalHash: Hex;
  observedNumber: bigint;
  finalizedNumber: bigint;
  generation: bigint;
}>;

export type PancakeV3PoolCursor = Readonly<{
  market: Address;
  launchpad: Address;
  launchId: string;
  startBlock: bigint;
  indexedThrough: bigint;
}>;

export type OutboxEmission = Readonly<{
  topic: string;
  aggregateId: string;
  dedupeKey: string;
  payload: Readonly<Record<string, unknown>>;
}>;

export interface CanonicalRpc {
  getChainId(): Promise<number>;
  getCode(address: Address, blockTag?: RpcBlockTag): Promise<Hex>;
  getStorageAt(address: Address, slot: Hex, blockTag?: RpcBlockTag): Promise<Hex>;
  getBlockNumber(): Promise<bigint>;
  getBlockByNumber(number: bigint): Promise<RpcBlock>;
  getLogs(filter: Readonly<{
    fromBlock: bigint;
    toBlock: bigint;
    addresses: readonly Address[];
    topic0: readonly Hex[];
  }>): Promise<readonly RpcLog[]>;
}

export interface IndexerStore {
  installRegistry(entries: readonly RegistryInstallEntry[]): Promise<void>;
  loadCursor(chainId: number): Promise<IndexerCursor | null>;
  initializeCursor(chainId: number, baseline: RpcBlock, observedNumber: bigint): Promise<IndexerCursor>;
  updateObservedHead(chainId: number, observedNumber: bigint): Promise<void>;
  setStatus(chainId: number, status: 'syncing' | 'live' | 'stale' | 'halted'): Promise<void>;
  getCanonicalBlock(chainId: number, number: bigint): Promise<RpcBlock | null>;
  loadPancakeV3PoolCursors(chainId: number, throughBlock: bigint): Promise<readonly PancakeV3PoolCursor[]>;
  commitBlock(
    chainId: number,
    block: RpcBlock,
    logs: readonly DecodedQuoteLog[],
    emissions: readonly OutboxEmission[],
    observedNumber: bigint,
  ): Promise<void>;
  commitPancakeV3PoolBackfill(
    chainId: number,
    logs: readonly DecodedQuoteLog[],
    poolCursors: readonly PancakeV3PoolCursor[],
    indexedThrough: bigint,
  ): Promise<void>;
  rollback(chainId: number, ancestor: RpcBlock, oldTip: RpcBlock): Promise<void>;
}

export type RegistryInstallEntry = Readonly<{
  chainId: number;
  address: Address;
  startBlock: bigint;
  abiVersionHash: Hex;
  kind: 'plain' | 'erc1967-uups';
  runtimeCodeHash: Hex;
  proxyRuntimeCodeHash: Hex | null;
  implementationAddress: Address | null;
  implementationRuntimeCodeHash: Hex | null;
}>;
