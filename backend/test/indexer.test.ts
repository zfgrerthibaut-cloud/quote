import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import test from 'node:test';
import { Interface, keccak256 } from 'ethers';

import { ERC1967_IMPLEMENTATION_SLOT, QuoteIndexer } from '../src/indexer/indexer.ts';
import { PANCAKE_V3_SWAP_ABI, projectPancakeV3Swap } from '../src/indexer/pancake-v3-trades.ts';
import { canonicalAbiVersionHash, QuoteRegistry } from '../src/indexer/registry.ts';
import type {
  Address,
  CanonicalRpc,
  DecodedQuoteLog,
  Hex,
  IndexerCursor,
  IndexerStore,
  OutboxEmission,
  PancakeV3PoolCursor,
  RpcBlock,
  RpcBlockTag,
  RpcLog,
} from '../src/indexer/types.ts';
import { WssWakeSource } from '../src/indexer/wss-wakeup.ts';

const ABI = [{
  type: 'event',
  name: 'QUOTEObserved',
  anonymous: false,
  inputs: [
    { name: 'value', type: 'uint256', indexed: true },
    { name: 'account', type: 'address', indexed: false },
  ],
}] as const;
const CONTRACT = '0x1111111111111111111111111111111111111111' as Address;
const CONTRACT_RUNTIME = '0x6001600055' as Hex;
const CONTRACT_RUNTIME_HASH = keccak256(CONTRACT_RUNTIME) as Hex;
const OLD_CONTRACT_RUNTIME = '0x6002600055' as Hex;
const OLD_CONTRACT_RUNTIME_HASH = keccak256(OLD_CONTRACT_RUNTIME) as Hex;
const PROXY_RUNTIME = '0x363d3d373d3d3d363d73' as Hex;
const PROXY_RUNTIME_HASH = keccak256(PROXY_RUNTIME) as Hex;
const IMPLEMENTATION = '0x6666666666666666666666666666666666666666' as Address;
const IMPLEMENTATION_RUNTIME = '0x6080604052600180fd' as Hex;
const IMPLEMENTATION_RUNTIME_HASH = keccak256(IMPLEMENTATION_RUNTIME) as Hex;
const OTHER_IMPLEMENTATION = '0x7777777777777777777777777777777777777777' as Address;
const ACCOUNT = '0x2222222222222222222222222222222222222222' as Address;
const TOKEN = '0x1000000000000000000000000000000000000001' as Address;
const QUOTE = '0x2000000000000000000000000000000000000002' as Address;
const POOL = '0x3000000000000000000000000000000000000003' as Address;
const LOCKER = '0x4000000000000000000000000000000000000004' as Address;
const ENGINE = '0x5000000000000000000000000000000000000005' as Address;
const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000' as Address;
const LAUNCH_ABI = [{
  type: 'event',
  name: 'QUOTEMarketLaunched',
  anonymous: false,
  inputs: [
    { name: 'launchId', type: 'uint256', indexed: true },
    { name: 'creator', type: 'address', indexed: true },
    { name: 'engineVersion', type: 'bytes32', indexed: true },
    { name: 'engineKind', type: 'uint8', indexed: false },
    { name: 'engine', type: 'address', indexed: false },
    { name: 'token', type: 'address', indexed: false },
    { name: 'quoteToken', type: 'address', indexed: false },
    { name: 'market', type: 'address', indexed: false },
    { name: 'hook', type: 'address', indexed: false },
    { name: 'vault', type: 'address', indexed: false },
    { name: 'locker', type: 'address', indexed: false },
    { name: 'supply', type: 'uint256', indexed: false },
    { name: 'creatorSwapFeeBps', type: 'uint16', indexed: false },
    { name: 'rewardFeeBps', type: 'uint16', indexed: false },
    { name: 'creatorLpShareBps', type: 'uint16', indexed: false },
    { name: 'poolId', type: 'bytes32', indexed: false },
    { name: 'engineRecordId', type: 'bytes32', indexed: false },
  ],
}] as const;

test('backfills every confirmed gap in bounded chunks', async () => {
  const rpc = new MockRpc(linearChain(9n, 14n));
  rpc.head = 14n;
  const store = new MemoryStore();
  const indexer = makeIndexer(rpc, store, { confirmationDepth: 2n, chunkSize: 2n, maxReorgDepth: 8n });

  const result = await indexer.sync();

  assert.equal(result.indexedThrough, 12n);
  assert.deepEqual(store.committedNumbers, [10n, 11n, 12n]);
  assert.deepEqual(rpc.logRanges, [[10n, 11n], [12n, 12n]]);
});

test('rolls back to the common parent and deterministically replays a replacement branch', async () => {
  const rpc = new MockRpc(linearChain(9n, 12n));
  rpc.head = 12n;
  const store = new MemoryStore();
  const indexer = makeIndexer(rpc, store, { confirmationDepth: 0n, chunkSize: 10n, maxReorgDepth: 8n });
  await indexer.sync();

  const replacement = replacementChain(rpc.blocks.get(9n)!, 10n, 13n);
  for (const [number, block] of replacement) rpc.blocks.set(number, block);
  rpc.head = 13n;
  const result = await indexer.sync();

  assert.equal(result.reorgs, 1);
  assert.equal(store.rollbackCount, 1);
  assert.equal(store.cursor?.generation, 1n);
  assert.equal(store.cursor?.canonicalNumber, 13n);
  assert.equal(store.blocks.get(10n)?.hash, replacement.get(10n)?.hash);
  assert.deepEqual(store.orphanedNumbers, [10n, 11n, 12n]);
});

test('deduplicates repeated RPC logs while preserving one ordered emission', async () => {
  const rpc = new MockRpc(linearChain(9n, 10n));
  rpc.head = 10n;
  const log = quoteLog(rpc.blocks.get(10n)!, 1, 2, 7n);
  rpc.logs = [log, { ...log }];
  const store = new MemoryStore();
  const indexer = makeIndexer(rpc, store, { confirmationDepth: 0n, chunkSize: 10n, maxReorgDepth: 8n });

  const result = await indexer.sync();

  assert.equal(result.logsCommitted, 1);
  assert.equal(store.logs.length, 1);
  assert.equal(store.emissions.length, 1);
  assert.equal(store.emissions[0]?.payload.args instanceof Object, true);
});

test('discovers a new direct Pancake V3 pool and backfills its Swap without restart', async () => {
  const rpc = new MockRpc(linearChain(9n, 10n));
  rpc.head = 10n;
  const block = rpc.blocks.get(10n)!;
  rpc.logs = [
    pancakeSwapLog(block, POOL, 0, 3, -500n, 100n),
    quoteMarketLaunchedLog(block, 0, 7, 1n),
  ];
  const store = new MemoryStore();
  const indexer = new QuoteIndexer(
    rpc,
    store,
    makeLaunchRegistry(),
    { confirmationDepth: 0n, chunkSize: 10n, maxReorgDepth: 8n },
  );

  const result = await indexer.sync();

  assert.equal(result.logsCommitted, 2);
  assert.equal(store.logs.some((log) => log.eventName === 'Swap' && log.address === POOL), true);
  assert.deepEqual(rpc.logRanges, [[10n, 10n], [10n, 10n]]);
  assert.deepEqual(rpc.logAddresses, [[CONTRACT], [POOL]]);
});

test('projects Pancake V3 signed pool deltas into exact buy and sell amounts', () => {
  const block = linearChain(10n, 10n).get(10n)!;
  const buy = projectPancakeV3Swap(
    decodeSwapForTest(pancakeSwapLog(block, POOL, 0, 1, -500n, 100n)),
    directMarket(),
  );
  assert.equal(buy.tradeType, 'buy');
  assert.equal(buy.tokenIn, QUOTE);
  assert.equal(buy.tokenOut, TOKEN);
  assert.equal(buy.amountInRaw, '100');
  assert.equal(buy.amountOutRaw, '500');
  assert.equal(buy.tokenAmountSignedRaw, '-500');
  assert.equal(buy.quoteAmountSignedRaw, '100');
  assert.equal(buy.priceNumeratorRaw, '1');
  assert.equal(buy.priceDenominatorRaw, '5');

  const sell = projectPancakeV3Swap(
    decodeSwapForTest(pancakeSwapLog(block, POOL, 0, 2, 400n, -96n)),
    directMarket(),
  );
  assert.equal(sell.tradeType, 'sell');
  assert.equal(sell.tokenIn, TOKEN);
  assert.equal(sell.tokenOut, QUOTE);
  assert.equal(sell.amountInRaw, '400');
  assert.equal(sell.amountOutRaw, '96');
  assert.equal(sell.tokenAmountSignedRaw, '400');
  assert.equal(sell.quoteAmountSignedRaw, '-96');
  assert.equal(sell.priceNumeratorRaw, '6');
  assert.equal(sell.priceDenominatorRaw, '25');
});

test('reconnects WSS subscriptions and uses notifications only as wake-ups', async () => {
  const sockets: FakeSocket[] = [];
  const wakes: string[] = [];
  const registry = makeRegistry();
  const source = new WssWakeSource(
    'wss://rpc.example.invalid',
    registry.addresses,
    registry.topic0,
    (reason) => wakes.push(`${reason.kind}:${reason.blockNumber}`),
    () => {
      const socket = new FakeSocket();
      sockets.push(socket);
      return socket as never;
    },
    1,
  );

  source.start();
  sockets[0].emit('open');
  const chainRequest = JSON.parse(sockets[0].sent[0]) as { id: number };
  sockets[0].emit('message', JSON.stringify({ jsonrpc: '2.0', id: chainRequest.id, result: '0x38' }));
  assert.equal(sockets[0].sent.filter((value) => value.includes('eth_subscribe')).length, 2);
  sockets[0].emit('close');
  await wait(10);

  assert.equal(sockets.length, 2);
  sockets[1].emit('open');
  const reconnectChainRequest = JSON.parse(sockets[1].sent[0]) as { id: number };
  sockets[1].emit('message', JSON.stringify({ jsonrpc: '2.0', id: reconnectChainRequest.id, result: '0x38' }));
  sockets[1].emit('message', JSON.stringify({
    jsonrpc: '2.0',
    method: 'eth_subscription',
    params: { subscription: 'heads', result: { number: '0xb' } },
  }));

  assert.ok(wakes.includes('head:11'));
  source.stop();
});

test('registry is fail-closed and verifies the canonical ABI fingerprint', () => {
  assert.throws(() => QuoteRegistry.fromEnv(undefined), /QUOTE_INDEXER_REGISTRY_JSON_required/);
  const invalid = JSON.stringify({
    chainId: 56,
    contracts: [{ address: CONTRACT, startBlock: '10', abiVersionHash: hash(999n), abi: ABI }],
  });
  assert.throws(() => QuoteRegistry.fromEnv(invalid), /abiVersionHash_mismatch/);
});

test('indexer rejects missing or mismatched configured runtime bytecode', async () => {
  const missingRpc = new MockRpc(linearChain(9n, 10n));
  missingRpc.head = 10n;
  missingRpc.contractRuntime = '0x';
  await assert.rejects(makeIndexer(missingRpc, new MemoryStore(), {
    confirmationDepth: 0n,
    chunkSize: 10n,
    maxReorgDepth: 8n,
  }).initialize(), /registry_contract_code_missing/);

  const wrongRpc = new MockRpc(linearChain(9n, 10n));
  wrongRpc.head = 10n;
  wrongRpc.contractRuntime = '0x6000';
  await assert.rejects(makeIndexer(wrongRpc, new MemoryStore(), {
    confirmationDepth: 0n,
    chunkSize: 10n,
    maxReorgDepth: 8n,
  }).initialize(), /registry_runtime_codehash_mismatch/);
});

test('indexer validates an ERC-1967 UUPS proxy and implementation at one latest block', async () => {
  const rpc = new MockRpc(linearChain(9n, 10n));
  rpc.head = 10n;
  installUupsRuntime(rpc);

  await new QuoteIndexer(
    rpc,
    new MemoryStore(),
    makeUupsRegistry(),
    { confirmationDepth: 0n, chunkSize: 10n, maxReorgDepth: 8n },
  ).initialize();

  assert.deepEqual(rpc.codeRequests.map((request) => request.blockTag), [10n, 10n]);
  assert.deepEqual(rpc.storageRequests.map((request) => request.blockTag), [10n]);
});

test('indexer rejects an ERC-1967 proxy implementation slot mismatch', async () => {
  const rpc = new MockRpc(linearChain(9n, 10n));
  rpc.head = 10n;
  installUupsRuntime(rpc);
  rpc.setStorage(CONTRACT, ERC1967_IMPLEMENTATION_SLOT, storageWordForAddress(OTHER_IMPLEMENTATION));

  await assert.rejects(new QuoteIndexer(
    rpc,
    new MemoryStore(),
    makeUupsRegistry(),
    { confirmationDepth: 0n, chunkSize: 10n, maxReorgDepth: 8n },
  ).initialize(), /registry_proxy_implementation_mismatch/);
});

test('indexer rejects missing or mismatched ERC-1967 implementation bytecode', async () => {
  const missingRpc = new MockRpc(linearChain(9n, 10n));
  missingRpc.head = 10n;
  installUupsRuntime(missingRpc);
  missingRpc.setCode(IMPLEMENTATION, '0x');

  await assert.rejects(new QuoteIndexer(
    missingRpc,
    new MemoryStore(),
    makeUupsRegistry(),
    { confirmationDepth: 0n, chunkSize: 10n, maxReorgDepth: 8n },
  ).initialize(), /registry_implementation_code_missing/);

  const wrongRpc = new MockRpc(linearChain(9n, 10n));
  wrongRpc.head = 10n;
  installUupsRuntime(wrongRpc);
  wrongRpc.setCode(IMPLEMENTATION, '0x6000');

  await assert.rejects(new QuoteIndexer(
    wrongRpc,
    new MemoryStore(),
    makeUupsRegistry(),
    { confirmationDepth: 0n, chunkSize: 10n, maxReorgDepth: 8n },
  ).initialize(), /registry_implementation_runtime_codehash_mismatch/);
});

test('indexer revalidates proxy implementation pins after the first sync', async () => {
  const rpc = new MockRpc(linearChain(9n, 11n));
  rpc.head = 10n;
  installUupsRuntime(rpc);
  const indexer = new QuoteIndexer(
    rpc,
    new MemoryStore(),
    makeUupsRegistry(),
    { confirmationDepth: 0n, chunkSize: 10n, maxReorgDepth: 8n },
  );

  await indexer.sync();

  rpc.head = 11n;
  rpc.setCode(IMPLEMENTATION, '0x6000');
  await assert.rejects(indexer.sync(), /registry_implementation_runtime_codehash_mismatch/);
});

test('indexer validates only the latest active registry epoch per address', async () => {
  const rpc = new MockRpc(linearChain(9n, 13n));
  rpc.head = 13n;
  installUupsRuntime(rpc);
  const registry = QuoteRegistry.fromEnv(JSON.stringify({
    chainId: 56,
    contracts: [{
      address: CONTRACT,
      startBlock: '10',
      abiVersionHash: canonicalAbiVersionHash(ABI),
      runtimeCodeHash: OLD_CONTRACT_RUNTIME_HASH,
      abi: ABI,
    }, {
      kind: 'erc1967-uups',
      address: CONTRACT,
      startBlock: '12',
      abiVersionHash: canonicalAbiVersionHash(ABI),
      proxyRuntimeCodeHash: PROXY_RUNTIME_HASH,
      implementationAddress: IMPLEMENTATION,
      implementationRuntimeCodeHash: IMPLEMENTATION_RUNTIME_HASH,
      abi: ABI,
    }],
  }));

  await new QuoteIndexer(
    rpc,
    new MemoryStore(),
    registry,
    { confirmationDepth: 0n, chunkSize: 10n, maxReorgDepth: 8n },
  ).initialize();

  assert.deepEqual(rpc.codeRequests.map((request) => request.address), [CONTRACT, IMPLEMENTATION]);
});

function makeIndexer(rpc: MockRpc, store: MemoryStore, options: {
  confirmationDepth: bigint;
  chunkSize: bigint;
  maxReorgDepth: bigint;
}) {
  return new QuoteIndexer(rpc, store, makeRegistry(), options);
}

function makeRegistry() {
  return QuoteRegistry.fromEnv(JSON.stringify({
    chainId: 56,
    contracts: [{
      address: CONTRACT,
      startBlock: '10',
      abiVersionHash: canonicalAbiVersionHash(ABI),
      runtimeCodeHash: CONTRACT_RUNTIME_HASH,
      abi: ABI,
    }],
  }));
}

function makeUupsRegistry() {
  return QuoteRegistry.fromEnv(JSON.stringify({
    chainId: 56,
    contracts: [{
      kind: 'erc1967-uups',
      address: CONTRACT,
      startBlock: '10',
      abiVersionHash: canonicalAbiVersionHash(ABI),
      proxyRuntimeCodeHash: PROXY_RUNTIME_HASH,
      implementationAddress: IMPLEMENTATION,
      implementationRuntimeCodeHash: IMPLEMENTATION_RUNTIME_HASH,
      abi: ABI,
    }],
  }));
}

function makeLaunchRegistry() {
  return QuoteRegistry.fromEnv(JSON.stringify({
    chainId: 56,
    contracts: [{
      address: CONTRACT,
      startBlock: '10',
      abiVersionHash: canonicalAbiVersionHash(LAUNCH_ABI),
      runtimeCodeHash: CONTRACT_RUNTIME_HASH,
      abi: LAUNCH_ABI,
    }],
  }));
}

function installUupsRuntime(rpc: MockRpc) {
  rpc.setCode(CONTRACT, PROXY_RUNTIME);
  rpc.setCode(IMPLEMENTATION, IMPLEMENTATION_RUNTIME);
  rpc.setStorage(CONTRACT, ERC1967_IMPLEMENTATION_SLOT, storageWordForAddress(IMPLEMENTATION));
}

class MockRpc implements CanonicalRpc {
  head = 0n;
  logs: RpcLog[] = [];
  logRanges: Array<[bigint, bigint]> = [];
  logAddresses: Address[][] = [];
  codeRequests: Array<{ address: Address; blockTag: RpcBlockTag | undefined }> = [];
  storageRequests: Array<{ address: Address; slot: Hex; blockTag: RpcBlockTag | undefined }> = [];
  readonly blocks: Map<bigint, RpcBlock>;
  contractRuntime: Hex = CONTRACT_RUNTIME;
  private readonly code = new Map<Address, Hex>();
  private readonly storage = new Map<string, Hex>();

  constructor(blocks: Map<bigint, RpcBlock>) {
    this.blocks = blocks;
  }

  async getChainId() { return 56; }
  async getCode(address: Address, blockTag?: RpcBlockTag) {
    const normalized = address.toLowerCase() as Address;
    this.codeRequests.push({ address: normalized, blockTag });
    return this.code.get(normalized) ?? this.contractRuntime;
  }
  async getStorageAt(address: Address, slot: Hex, blockTag?: RpcBlockTag) {
    const normalized = address.toLowerCase() as Address;
    const normalizedSlot = slot.toLowerCase() as Hex;
    this.storageRequests.push({ address: normalized, slot: normalizedSlot, blockTag });
    return this.storage.get(`${normalized}:${normalizedSlot}`) ?? hash(0n);
  }
  async getBlockNumber() { return this.head; }
  async getBlockByNumber(number: bigint) {
    const block = this.blocks.get(number);
    if (!block) throw new Error(`missing_mock_block:${number}`);
    return block;
  }
  async getLogs(filter: { fromBlock: bigint; toBlock: bigint; addresses: readonly Address[]; topic0: readonly Hex[] }) {
    this.logRanges.push([filter.fromBlock, filter.toBlock]);
    this.logAddresses.push([...filter.addresses]);
    const addresses = new Set(filter.addresses.map((address) => address.toLowerCase()));
    const topics = new Set(filter.topic0.map((topic) => topic.toLowerCase()));
    return this.logs.filter((log) => (
      log.blockNumber >= filter.fromBlock
      && log.blockNumber <= filter.toBlock
      && addresses.has(log.address.toLowerCase())
      && topics.has(log.topics[0]?.toLowerCase() ?? '')
    ));
  }
  setCode(address: Address, runtime: Hex) {
    this.code.set(address.toLowerCase() as Address, runtime);
  }
  setStorage(address: Address, slot: Hex, value: Hex) {
    this.storage.set(`${address.toLowerCase()}:${slot.toLowerCase()}`, value.toLowerCase() as Hex);
  }
}

class MemoryStore implements IndexerStore {
  cursor: IndexerCursor | null = null;
  blocks = new Map<bigint, RpcBlock>();
  logs: DecodedQuoteLog[] = [];
  emissions: OutboxEmission[] = [];
  poolCursors = new Map<Address, PancakeV3PoolCursor>();
  committedNumbers: bigint[] = [];
  orphanedNumbers: bigint[] = [];
  rollbackCount = 0;

  async installRegistry() {}
  async loadCursor() { return this.cursor; }
  async initializeCursor(chainId: number, baseline: RpcBlock, observedNumber: bigint) {
    if (!this.cursor) {
      this.blocks.set(baseline.number, baseline);
      this.cursor = {
        chainId,
        canonicalNumber: baseline.number,
        canonicalHash: baseline.hash,
        observedNumber,
        finalizedNumber: baseline.number,
        generation: 0n,
      };
    }
    return this.cursor;
  }
  async updateObservedHead(_chainId: number, observedNumber: bigint) {
    if (this.cursor && observedNumber > this.cursor.observedNumber) this.cursor = { ...this.cursor, observedNumber };
  }
  async setStatus() {}
  async getCanonicalBlock(_chainId: number, number: bigint) { return this.blocks.get(number) ?? null; }
  async loadPancakeV3PoolCursors(_chainId: number, throughBlock: bigint) {
    return [...this.poolCursors.values()]
      .filter((cursor) => cursor.startBlock <= throughBlock && cursor.indexedThrough < throughBlock)
      .sort((left, right) => left.indexedThrough < right.indexedThrough ? -1 : 1)
      .slice(0, 1);
  }
  async commitBlock(
    _chainId: number,
    block: RpcBlock,
    logs: readonly DecodedQuoteLog[],
    emissions: readonly OutboxEmission[],
    observedNumber: bigint,
  ) {
    if (!this.cursor || block.number !== this.cursor.canonicalNumber + 1n) throw new Error('cursor_height_mismatch');
    if (block.parentHash !== this.cursor.canonicalHash) throw new Error('cursor_parent_mismatch');
    this.blocks.set(block.number, block);
    this.logs.push(...logs);
    this.emissions.push(...emissions);
    for (const log of logs) {
      if (log.eventName !== 'QUOTEMarketLaunched' || log.args.engineKind !== '1') continue;
      this.poolCursors.set(String(log.args.market).toLowerCase() as Address, {
        market: String(log.args.market).toLowerCase() as Address,
        launchpad: log.address,
        launchId: String(log.args.launchId),
        startBlock: log.blockNumber,
        indexedThrough: log.blockNumber - 1n,
      });
    }
    this.committedNumbers.push(block.number);
    this.cursor = {
      ...this.cursor,
      canonicalNumber: block.number,
      canonicalHash: block.hash,
      observedNumber: observedNumber > this.cursor.observedNumber ? observedNumber : this.cursor.observedNumber,
      finalizedNumber: block.number,
    };
  }
  async commitPancakeV3PoolBackfill(
    _chainId: number,
    logs: readonly DecodedQuoteLog[],
    poolCursors: readonly PancakeV3PoolCursor[],
    indexedThrough: bigint,
  ) {
    this.logs.push(...logs);
    for (const cursor of poolCursors) {
      const current = this.poolCursors.get(cursor.market);
      if (current) this.poolCursors.set(cursor.market, { ...current, indexedThrough });
    }
  }
  async rollback(_chainId: number, ancestor: RpcBlock) {
    if (!this.cursor) throw new Error('cursor_missing');
    for (const number of [...this.blocks.keys()].sort((left, right) => left < right ? -1 : 1)) {
      if (number > ancestor.number) {
        this.blocks.delete(number);
        this.orphanedNumbers.push(number);
      }
    }
    this.rollbackCount += 1;
    for (const [market, poolCursor] of this.poolCursors) {
      if (poolCursor.startBlock > ancestor.number) {
        this.poolCursors.delete(market);
      } else if (poolCursor.indexedThrough > ancestor.number) {
        this.poolCursors.set(market, { ...poolCursor, indexedThrough: ancestor.number });
      }
    }
    this.cursor = {
      ...this.cursor,
      canonicalNumber: ancestor.number,
      canonicalHash: ancestor.hash,
      finalizedNumber: ancestor.number,
      generation: this.cursor.generation + 1n,
    };
  }
}

class FakeSocket extends EventEmitter {
  sent: string[] = [];
  send(value: string) { this.sent.push(value); }
  close() { this.emit('close'); }
}

function linearChain(from: bigint, to: bigint) {
  const blocks = new Map<bigint, RpcBlock>();
  for (let number = from; number <= to; number += 1n) {
    blocks.set(number, {
      number,
      hash: hash(number),
      parentHash: hash(number - 1n),
      timestamp: 1_700_000_000n + number,
    });
  }
  return blocks;
}

function replacementChain(parent: RpcBlock, from: bigint, to: bigint) {
  const blocks = new Map<bigint, RpcBlock>();
  let parentHash = parent.hash;
  for (let number = from; number <= to; number += 1n) {
    const block = {
      number,
      hash: hash(1_000n + number),
      parentHash,
      timestamp: 1_700_100_000n + number,
    } satisfies RpcBlock;
    blocks.set(number, block);
    parentHash = block.hash;
  }
  return blocks;
}

function quoteLog(block: RpcBlock, transactionIndex: number, logIndex: number, value: bigint): RpcLog {
  const contractInterface = new Interface(ABI);
  const encoded = contractInterface.encodeEventLog(contractInterface.getEvent('QUOTEObserved')!, [value, ACCOUNT]);
  return {
    address: CONTRACT,
    blockHash: block.hash,
    blockNumber: block.number,
    transactionHash: hash(10_000n + BigInt(logIndex)),
    transactionIndex,
    logIndex,
    topics: encoded.topics as Hex[],
    data: encoded.data as Hex,
    removed: false,
  };
}

function quoteMarketLaunchedLog(block: RpcBlock, transactionIndex: number, logIndex: number, launchId: bigint): RpcLog {
  const contractInterface = new Interface(LAUNCH_ABI);
  const encoded = contractInterface.encodeEventLog(contractInterface.getEvent('QUOTEMarketLaunched')!, [
    launchId,
    ACCOUNT,
    hash(12_345n),
    1,
    ENGINE,
    TOKEN,
    QUOTE,
    POOL,
    ZERO_ADDRESS,
    ZERO_ADDRESS,
    LOCKER,
    1_000_000n,
    0,
    0,
    2_500,
    hash(22_222n),
    hash(33_333n),
  ]);
  return {
    address: CONTRACT,
    blockHash: block.hash,
    blockNumber: block.number,
    transactionHash: hash(20_000n + BigInt(logIndex)),
    transactionIndex,
    logIndex,
    topics: encoded.topics as Hex[],
    data: encoded.data as Hex,
    removed: false,
  };
}

function pancakeSwapLog(
  block: RpcBlock,
  pool: Address,
  transactionIndex: number,
  logIndex: number,
  amount0: bigint,
  amount1: bigint,
): RpcLog {
  const contractInterface = new Interface(PANCAKE_V3_SWAP_ABI);
  const encoded = contractInterface.encodeEventLog(contractInterface.getEvent('Swap')!, [
    ENGINE,
    ACCOUNT,
    amount0,
    amount1,
    79_228_162_514_264_337_593_543_950_336n,
    1_000_000n,
    0,
  ]);
  return {
    address: pool,
    blockHash: block.hash,
    blockNumber: block.number,
    transactionHash: hash(30_000n + BigInt(logIndex)),
    transactionIndex,
    logIndex,
    topics: encoded.topics as Hex[],
    data: encoded.data as Hex,
    removed: false,
  };
}

function decodeSwapForTest(log: RpcLog): DecodedQuoteLog {
  const contractInterface = new Interface(PANCAKE_V3_SWAP_ABI);
  const parsed = contractInterface.parseLog({ topics: [...log.topics], data: log.data });
  assert.ok(parsed);
  return {
    ...log,
    eventName: parsed.name,
    eventSignature: parsed.signature,
    abiVersionHash: canonicalAbiVersionHash(PANCAKE_V3_SWAP_ABI),
    args: {
      sender: ENGINE,
      recipient: ACCOUNT,
      amount0: String(parsed.args.amount0),
      amount1: String(parsed.args.amount1),
      sqrtPriceX96: String(parsed.args.sqrtPriceX96),
      liquidity: String(parsed.args.liquidity),
      tick: String(parsed.args.tick),
    },
  };
}

function directMarket() {
  return {
    chainId: 56,
    launchpad: CONTRACT,
    launchId: '1',
    token: TOKEN,
    quoteToken: QUOTE,
    market: POOL,
  };
}

function hash(value: bigint): Hex {
  return `0x${value.toString(16).padStart(64, '0')}`;
}

function storageWordForAddress(address: Address): Hex {
  return `0x${address.slice(2).toLowerCase().padStart(64, '0')}` as Hex;
}

function wait(milliseconds: number) {
  return new Promise<void>((resolve) => setTimeout(resolve, milliseconds));
}
