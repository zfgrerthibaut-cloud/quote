import { compareLogs } from '../domain/reorg.ts';
import { keccak256 } from 'ethers';

import { decodePancakeV3SwapLog, isPancakeV3SwapTopic, PANCAKE_V3_SWAP_TOPIC } from './pancake-v3-trades.ts';
import { QuoteRegistry } from './registry.ts';
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
  RpcLog,
} from './types.ts';

export const ERC1967_IMPLEMENTATION_SLOT = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc' as Hex;

export type QuoteIndexerOptions = Readonly<{
  confirmationDepth: bigint;
  chunkSize: bigint;
  maxReorgDepth: bigint;
}>;

export type SyncResult = Readonly<{
  observedHead: bigint;
  confirmedHead: bigint;
  indexedThrough: bigint;
  blocksCommitted: number;
  logsCommitted: number;
  reorgs: number;
}>;

export class QuoteIndexer {
  private readonly rpc: CanonicalRpc;
  private readonly store: IndexerStore;
  readonly registry: QuoteRegistry;
  private readonly options: QuoteIndexerOptions;

  constructor(
    rpc: CanonicalRpc,
    store: IndexerStore,
    registry: QuoteRegistry,
    options: QuoteIndexerOptions,
  ) {
    this.rpc = rpc;
    this.store = store;
    this.registry = registry;
    this.options = options;
    if (options.confirmationDepth < 0n) throw new Error('confirmation_depth_invalid');
    if (options.chunkSize < 1n || options.chunkSize > 10_000n) throw new Error('chunk_size_invalid');
    if (options.maxReorgDepth < 1n) throw new Error('max_reorg_depth_invalid');
  }

  async initialize() {
    await this.validateChain();
    await this.store.installRegistry(this.registry.entries.map((entry) => ({
      chainId: entry.chainId,
      address: entry.address,
      startBlock: entry.startBlock,
      abiVersionHash: entry.abiVersionHash,
      kind: entry.kind,
      runtimeCodeHash: entry.runtimeCodeHash,
      proxyRuntimeCodeHash: entry.proxyRuntimeCodeHash,
      implementationAddress: entry.implementationAddress,
      implementationRuntimeCodeHash: entry.implementationRuntimeCodeHash,
    })));
  }

  async sync(): Promise<SyncResult> {
    try {
      await this.initialize();
      await this.store.setStatus(this.registry.chainId, 'syncing');
      let lastError: unknown;
      for (let attempt = 0; attempt < 3; attempt += 1) {
        try {
          const result = await this.syncAttempt();
          await this.store.setStatus(this.registry.chainId, 'live');
          return result;
        } catch (error) {
          lastError = error;
          if (!isCanonicalRace(error) || attempt === 2) throw error;
        }
      }
      throw lastError;
    } catch (error) {
      await this.store.setStatus(
        this.registry.chainId,
        isFatalIndexerError(error) ? 'halted' : 'stale',
      ).catch(() => undefined);
      throw error;
    }
  }

  private async syncAttempt(): Promise<SyncResult> {
    const observedHead = await this.rpc.getBlockNumber();
    let cursor = await this.store.loadCursor(this.registry.chainId);
    if (!cursor) {
      const baselineNumber = this.registry.firstStartBlock() - 1n;
      const baseline = await this.rpc.getBlockByNumber(baselineNumber);
      cursor = await this.store.initializeCursor(this.registry.chainId, baseline, observedHead);
    } else {
      await this.store.updateObservedHead(this.registry.chainId, observedHead);
    }

    let reorgs = 0;
    const canonicalCursor = await this.ensureCanonicalCursor(cursor);
    if (canonicalCursor.generation !== cursor.generation) reorgs += 1;
    cursor = canonicalCursor;

    const confirmedHead = observedHead > this.options.confirmationDepth
      ? observedHead - this.options.confirmationDepth
      : 0n;
    let blocksCommitted = 0;
    let logsCommitted = 0;
    let nextBlock = cursor.canonicalNumber + 1n;

    while (nextBlock <= confirmedHead) {
      const chunkEnd = minimum(confirmedHead, nextBlock + this.options.chunkSize - 1n);
      const rawLogs = await this.rpc.getLogs({
        fromBlock: nextBlock,
        toBlock: chunkEnd,
        addresses: this.registry.addresses,
        topic0: this.registry.topic0,
      });
      const logs = this.validateAndDecodeLogs(rawLogs, nextBlock, chunkEnd);
      const logsByBlock = groupLogsByBlock(logs);

      let expectedParentHash = cursor.canonicalHash;
      for (let number = nextBlock; number <= chunkEnd; number += 1n) {
        const block = await this.rpc.getBlockByNumber(number);
        if (block.parentHash.toLowerCase() !== expectedParentHash.toLowerCase()) {
          throw new CanonicalRaceError('parent_hash_changed_during_scan');
        }
        const blockLogs = logsByBlock.get(number) ?? [];
        for (const log of blockLogs) {
          if (log.blockHash.toLowerCase() !== block.hash.toLowerCase()) {
            throw new CanonicalRaceError('log_block_hash_changed_during_scan');
          }
        }
        const emissions = blockLogs.map((log) => buildEmission(this.registry.chainId, log));
        try {
          await this.store.commitBlock(this.registry.chainId, block, blockLogs, emissions, observedHead);
        } catch (error) {
          if (isCursorConflict(error)) throw new CanonicalRaceError('cursor_changed_during_commit');
          throw error;
        }
        expectedParentHash = block.hash;
        cursor = {
          ...cursor,
          canonicalNumber: block.number,
          canonicalHash: block.hash,
          finalizedNumber: block.number,
        };
        blocksCommitted += 1;
        logsCommitted += blockLogs.length;
      }
      nextBlock = chunkEnd + 1n;
    }

    logsCommitted += await this.syncPancakeV3PoolBackfills(confirmedHead);

    return {
      observedHead,
      confirmedHead,
      indexedThrough: cursor.canonicalNumber,
      blocksCommitted,
      logsCommitted,
      reorgs,
    };
  }

  private async validateChain() {
    const chainId = await this.rpc.getChainId();
    if (chainId !== this.registry.chainId) throw new Error(`rpc_chain_id_mismatch:${chainId}`);
    const validationBlock = await this.rpc.getBlockNumber();
    for (const entry of this.registry.activeEntries(validationBlock)) {
      if (entry.kind === 'plain') {
        const runtimeCode = await this.rpc.getCode(entry.address, validationBlock);
        if (runtimeCode === '0x') throw new Error(`registry_contract_code_missing:${entry.address}`);
        if (keccak256(runtimeCode).toLowerCase() !== entry.runtimeCodeHash) {
          throw new Error(`registry_runtime_codehash_mismatch:${entry.address}`);
        }
        continue;
      }

      const proxyRuntimeCode = await this.rpc.getCode(entry.address, validationBlock);
      if (proxyRuntimeCode === '0x') throw new Error(`registry_contract_code_missing:${entry.address}`);
      if (keccak256(proxyRuntimeCode).toLowerCase() !== entry.proxyRuntimeCodeHash) {
        throw new Error(`registry_proxy_runtime_codehash_mismatch:${entry.address}`);
      }

      const implementation = parseErc1967Implementation(
        await this.rpc.getStorageAt(entry.address, ERC1967_IMPLEMENTATION_SLOT, validationBlock),
      );
      if (implementation !== entry.implementationAddress) {
        throw new Error(`registry_proxy_implementation_mismatch:${entry.address}`);
      }

      const implementationCode = await this.rpc.getCode(implementation, validationBlock);
      if (implementationCode === '0x') throw new Error(`registry_implementation_code_missing:${implementation}`);
      if (keccak256(implementationCode).toLowerCase() !== entry.implementationRuntimeCodeHash) {
        throw new Error(`registry_implementation_runtime_codehash_mismatch:${implementation}`);
      }
    }
  }

  private async ensureCanonicalCursor(cursor: IndexerCursor): Promise<IndexerCursor> {
    const remoteTip = await this.rpc.getBlockByNumber(cursor.canonicalNumber);
    if (remoteTip.hash.toLowerCase() === cursor.canonicalHash.toLowerCase()) return cursor;

    const oldest = maximum(
      this.registry.firstStartBlock() - 1n,
      cursor.canonicalNumber > this.options.maxReorgDepth
        ? cursor.canonicalNumber - this.options.maxReorgDepth
        : 0n,
    );
    let ancestor: RpcBlock | null = null;
    for (let number = cursor.canonicalNumber; number >= oldest; number -= 1n) {
      const stored = await this.store.getCanonicalBlock(this.registry.chainId, number);
      if (stored) {
        const remote = await this.rpc.getBlockByNumber(number);
        if (remote.hash.toLowerCase() === stored.hash.toLowerCase()) {
          ancestor = remote;
          break;
        }
      }
      if (number === 0n) break;
    }
    if (!ancestor) throw new Error('reorg_beyond_retained_history');

    const oldTip = await this.store.getCanonicalBlock(this.registry.chainId, cursor.canonicalNumber);
    if (!oldTip) throw new Error('cursor_block_missing');
    await this.store.rollback(this.registry.chainId, ancestor, oldTip);
    const rolledBack = await this.store.loadCursor(this.registry.chainId);
    if (!rolledBack) throw new Error('cursor_missing_after_rollback');
    return rolledBack;
  }

  private async syncPancakeV3PoolBackfills(confirmedHead: bigint) {
    let logsCommitted = 0;
    while (true) {
      const pending = await this.store.loadPancakeV3PoolCursors(this.registry.chainId, confirmedHead);
      const pool = pending[0];
      if (!pool) return logsCommitted;

      const fromBlock = maximum(pool.indexedThrough + 1n, pool.startBlock);
      const toBlock = minimum(confirmedHead, fromBlock + this.options.chunkSize - 1n);
      const rawLogs = await this.rpc.getLogs({
        fromBlock,
        toBlock,
        addresses: [pool.market],
        topic0: [PANCAKE_V3_SWAP_TOPIC],
      });
      const logs = this.validateAndDecodeLogs(rawLogs, fromBlock, toBlock, new Set([pool.market]));
      await this.store.commitPancakeV3PoolBackfill(this.registry.chainId, logs, [pool], toBlock);
      logsCommitted += logs.length;
    }
  }

  private validateAndDecodeLogs(
    rawLogs: readonly RpcLog[],
    fromBlock: bigint,
    toBlock: bigint,
    directPancakeV3Pools: ReadonlySet<string> = new Set(),
  ) {
    const unique = new Map<string, RpcLog>();
    for (const log of rawLogs) {
      if (log.blockNumber < fromBlock || log.blockNumber > toBlock) throw new Error('rpc_log_outside_requested_range');
      if (log.removed) throw new CanonicalRaceError('removed_log_from_http_proof');
      const topic0 = log.topics[0]?.toLowerCase() as Hex | undefined;
      if (!topic0 || !this.isTrackedLog(log, topic0, directPancakeV3Pools)) continue;
      const key = `${log.blockNumber}:${log.transactionHash.toLowerCase()}:${log.logIndex}`;
      const previous = unique.get(key);
      if (previous && !sameLog(previous, log)) throw new Error('rpc_log_identity_conflict');
      if (!previous) unique.set(key, log);
    }
    return [...unique.values()]
      .sort(compareLogs)
      .map((log) => {
        const active = this.registry.activeEntry(log.address, log.blockNumber);
        const topic0 = log.topics[0]?.toLowerCase() as Hex | undefined;
        if (active && topic0 && active.topic0.includes(topic0)) return this.registry.decode(log);
        return decodePancakeV3SwapLog(log);
      });
  }

  private isTrackedLog(
    log: RpcLog,
    topic0: Hex,
    directPancakeV3Pools: ReadonlySet<string>,
  ) {
    const active = this.registry.activeEntry(log.address, log.blockNumber);
    if (active?.topic0.includes(topic0)) return true;
    return directPancakeV3Pools.has(log.address.toLowerCase()) && isPancakeV3SwapTopic(topic0);
  }
}

function buildEmission(chainId: number, log: DecodedQuoteLog): OutboxEmission {
  const launchId = log.eventName === 'QUOTEMarketLaunched' ? stringArg(log, 'launchId') : null;
  const topic = launchId === null ? 'quote.event' : 'market.launched';
  const aggregateId = launchId === null
    ? `${chainId}:${log.address}`
    : `${chainId}:${log.address}:${launchId}`;
  return {
    topic,
    aggregateId,
    dedupeKey: `quote:${chainId}:${log.blockHash}:${log.transactionHash}:${log.logIndex}`,
    payload: {
      schemaVersion: 1,
      type: topic,
      chainId,
      contract: log.address,
      abiVersionHash: log.abiVersionHash,
      eventName: log.eventName,
      eventSignature: log.eventSignature,
      args: log.args,
      blockNumber: log.blockNumber.toString(),
      blockHash: log.blockHash,
      transactionHash: log.transactionHash,
      transactionIndex: log.transactionIndex,
      logIndex: log.logIndex,
    },
  };
}

function groupLogsByBlock(logs: readonly DecodedQuoteLog[]) {
  const grouped = new Map<bigint, DecodedQuoteLog[]>();
  for (const log of logs) {
    const entries = grouped.get(log.blockNumber) ?? [];
    entries.push(log);
    grouped.set(log.blockNumber, entries);
  }
  return grouped;
}

function sameLog(left: RpcLog, right: RpcLog) {
  return left.blockHash.toLowerCase() === right.blockHash.toLowerCase()
    && left.address.toLowerCase() === right.address.toLowerCase()
    && left.transactionIndex === right.transactionIndex
    && left.data.toLowerCase() === right.data.toLowerCase()
    && left.topics.length === right.topics.length
    && left.topics.every((topic, index) => topic.toLowerCase() === right.topics[index]?.toLowerCase());
}

function stringArg(log: DecodedQuoteLog, name: string) {
  const value = log.args[name];
  if (typeof value !== 'string' || !/^\d+$/.test(value)) throw new Error(`invalid_${log.eventName}_${name}`);
  return value;
}

function isCursorConflict(error: unknown) {
  return error instanceof Error && (
    error.message.includes('cursor_parent_mismatch')
    || error.message.includes('cursor_height_mismatch')
  );
}

function isCanonicalRace(error: unknown): error is CanonicalRaceError {
  return error instanceof CanonicalRaceError;
}

function isFatalIndexerError(error: unknown) {
  if (!(error instanceof Error)) return false;
  return error.message === 'reorg_beyond_retained_history'
    || error.message === 'registry_version_conflict'
    || error.message === 'registry_runtime_codehash_conflict'
    || error.message === 'registry_runtime_pin_conflict'
    || error.message === 'registry_runtime_codehash_legacy_null'
    || error.message === 'registry_kind_invalid'
    || error.message === 'registry_historical_backfill_required'
    || error.message === 'registry_snapshot_cannot_remove_entries'
    || error.message === 'registry_proxy_implementation_slot_invalid'
    || error.message === 'registry_proxy_implementation_slot_empty'
    || error.message.startsWith('registry_contract_code_missing:')
    || error.message.startsWith('registry_runtime_codehash_mismatch:')
    || error.message.startsWith('registry_proxy_runtime_codehash_mismatch:')
    || error.message.startsWith('registry_proxy_implementation_mismatch:')
    || error.message.startsWith('registry_implementation_code_missing:')
    || error.message.startsWith('registry_implementation_runtime_codehash_mismatch:')
    || error.message.startsWith('rpc_chain_id_mismatch:')
    || error.message.startsWith('invalid_QUOTEMarketLaunched_');
}

class CanonicalRaceError extends Error {}

function minimum(left: bigint, right: bigint) {
  return left < right ? left : right;
}

function maximum(left: bigint, right: bigint) {
  return left > right ? left : right;
}

function parseErc1967Implementation(slotValue: Hex): Address {
  if (!/^0x[0-9a-f]{64}$/.test(slotValue)) throw new Error('registry_proxy_implementation_slot_invalid');
  const address = `0x${slotValue.slice(-40)}` as Address;
  if (address === '0x0000000000000000000000000000000000000000') {
    throw new Error('registry_proxy_implementation_slot_empty');
  }
  return address;
}
