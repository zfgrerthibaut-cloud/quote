import { createHash } from 'node:crypto';
import { EventFragment, Interface, type InterfaceAbi } from 'ethers';

import type { Address, DecodedQuoteLog, Hex, RpcLog } from './types.ts';

const ADDRESS = /^0x[0-9a-fA-F]{40}$/;
const HASH = /^0x[0-9a-fA-F]{64}$/;

export type RegistryEntry = Readonly<{
  chainId: 56;
  address: Address;
  startBlock: bigint;
  abiVersionHash: Hex;
  kind: 'plain' | 'erc1967-uups';
  runtimeCodeHash: Hex;
  proxyRuntimeCodeHash: Hex | null;
  implementationAddress: Address | null;
  implementationRuntimeCodeHash: Hex | null;
  abi: readonly unknown[];
  interface: Interface;
  topic0: readonly Hex[];
}>;

type RawRegistry = Readonly<{
  chainId?: unknown;
  contracts?: unknown;
}>;

export class QuoteRegistry {
  readonly chainId = 56 as const;
  readonly entries: readonly RegistryEntry[];
  readonly addresses: readonly Address[];
  readonly topic0: readonly Hex[];

  constructor(entries: readonly RegistryEntry[]) {
    if (entries.length === 0) throw new Error('QUOTE_INDEXER_REGISTRY_empty');
    this.entries = [...entries].sort((left, right) => {
      const addressOrder = left.address.localeCompare(right.address);
      if (addressOrder !== 0) return addressOrder;
      return left.startBlock < right.startBlock ? -1 : left.startBlock > right.startBlock ? 1 : 0;
    });
    this.addresses = [...new Set(this.entries.map((entry) => entry.address))];
    this.topic0 = [...new Set(this.entries.flatMap((entry) => entry.topic0))];

    const keys = new Set<string>();
    for (const entry of this.entries) {
      const key = `${entry.address}:${entry.startBlock}`;
      if (keys.has(key)) throw new Error(`QUOTE_INDEXER_REGISTRY_duplicate:${key}`);
      keys.add(key);
    }
  }

  static fromEnv(raw = process.env.QUOTE_INDEXER_REGISTRY_JSON): QuoteRegistry {
    if (!raw) throw new Error('QUOTE_INDEXER_REGISTRY_JSON_required');
    let parsed: RawRegistry;
    try {
      parsed = JSON.parse(raw) as RawRegistry;
    } catch {
      throw new Error('QUOTE_INDEXER_REGISTRY_JSON_invalid');
    }
    if (parsed.chainId !== 56) throw new Error('QUOTE_INDEXER_REGISTRY_chain_must_be_56');
    if (!Array.isArray(parsed.contracts)) throw new Error('QUOTE_INDEXER_REGISTRY_contracts_required');
    return new QuoteRegistry(parsed.contracts.map(parseEntry));
  }

  firstStartBlock() {
    return this.entries.reduce((minimum, entry) => entry.startBlock < minimum ? entry.startBlock : minimum, this.entries[0].startBlock);
  }

  activeEntry(address: Address, blockNumber: bigint) {
    const normalized = address.toLowerCase();
    let selected: RegistryEntry | undefined;
    for (const entry of this.entries) {
      if (entry.address !== normalized || entry.startBlock > blockNumber) continue;
      if (!selected || entry.startBlock > selected.startBlock) selected = entry;
    }
    return selected;
  }

  activeEntries(blockNumber: bigint) {
    const selected = new Map<Address, RegistryEntry>();
    for (const entry of this.entries) {
      if (entry.startBlock > blockNumber) continue;
      const previous = selected.get(entry.address);
      if (!previous || entry.startBlock > previous.startBlock) selected.set(entry.address, entry);
    }
    return [...selected.values()];
  }

  decode(log: RpcLog): DecodedQuoteLog {
    const entry = this.activeEntry(log.address, log.blockNumber);
    if (!entry) throw new Error('unregistered_quote_log');
    const topic = log.topics[0]?.toLowerCase() as Hex | undefined;
    if (!topic || !entry.topic0.includes(topic)) throw new Error('unregistered_quote_topic');
    const parsed = entry.interface.parseLog({ topics: [...log.topics], data: log.data });
    if (!parsed) throw new Error('quote_log_decode_failed');
    const args: Record<string, unknown> = {};
    parsed.fragment.inputs.forEach((input, index) => {
      args[input.name || String(index)] = jsonSafe(parsed.args[index]);
    });
    return {
      ...log,
      address: entry.address,
      eventName: parsed.name,
      eventSignature: parsed.signature,
      abiVersionHash: entry.abiVersionHash,
      args,
    };
  }
}

export function canonicalAbiVersionHash(abi: readonly unknown[]): Hex {
  return `0x${createHash('sha256').update(canonicalJson(abi)).digest('hex')}`;
}

function parseEntry(value: unknown): RegistryEntry {
  if (!isRecord(value)) throw new Error('QUOTE_INDEXER_REGISTRY_entry_invalid');
  const address = typeof value.address === 'string' && ADDRESS.test(value.address)
    ? value.address.toLowerCase() as Address
    : null;
  if (!address || address === '0x0000000000000000000000000000000000000000') {
    throw new Error('QUOTE_INDEXER_REGISTRY_address_invalid');
  }
  const startBlock = parseDecimalBigInt(value.startBlock, 'QUOTE_INDEXER_REGISTRY_startBlock_invalid');
  if (startBlock < 1n) throw new Error('QUOTE_INDEXER_REGISTRY_startBlock_must_be_positive');
  if (!Array.isArray(value.abi) || value.abi.length === 0) throw new Error('QUOTE_INDEXER_REGISTRY_abi_required');
  const suppliedHash = typeof value.abiVersionHash === 'string' && HASH.test(value.abiVersionHash)
    ? value.abiVersionHash.toLowerCase() as Hex
    : null;
  if (!suppliedHash) throw new Error('QUOTE_INDEXER_REGISTRY_abiVersionHash_invalid');
  const computedHash = canonicalAbiVersionHash(value.abi);
  if (suppliedHash !== computedHash) throw new Error('QUOTE_INDEXER_REGISTRY_abiVersionHash_mismatch');
  const kind = value.kind === undefined || value.kind === 'plain' || value.kind === 'erc1967-uups'
    ? (value.kind ?? 'plain') as 'plain' | 'erc1967-uups'
    : null;
  if (!kind) throw new Error('QUOTE_INDEXER_REGISTRY_kind_invalid');
  const runtimePin = parseRuntimePin(value, kind);

  let contractInterface: Interface;
  try {
    contractInterface = new Interface(value.abi as InterfaceAbi);
  } catch {
    throw new Error('QUOTE_INDEXER_REGISTRY_abi_invalid');
  }
  const topic0 = contractInterface.fragments
    .filter((fragment): fragment is EventFragment => fragment.type === 'event')
    .map((fragment) => fragment.topicHash.toLowerCase() as Hex);
  if (topic0.length === 0) throw new Error('QUOTE_INDEXER_REGISTRY_events_required');
  if (contractInterface.fragments
    .filter((fragment): fragment is EventFragment => fragment.type === 'event')
    .some((fragment) => fragment.anonymous)) {
    throw new Error('QUOTE_INDEXER_REGISTRY_anonymous_event_unsupported');
  }
  return {
    chainId: 56,
    address,
    startBlock,
    abiVersionHash: suppliedHash,
    kind,
    ...runtimePin,
    abi: value.abi,
    interface: contractInterface,
    topic0: [...new Set(topic0)],
  };
}

function parseRuntimePin(
  value: Record<string, unknown>,
  kind: 'plain' | 'erc1967-uups',
): Pick<RegistryEntry, 'runtimeCodeHash' | 'proxyRuntimeCodeHash' | 'implementationAddress' | 'implementationRuntimeCodeHash'> {
  if (kind === 'plain') {
    const runtimeCodeHash = parseHashField(value.runtimeCodeHash, 'QUOTE_INDEXER_REGISTRY_runtimeCodeHash_invalid');
    if (value.proxyRuntimeCodeHash !== undefined
      || value.implementationAddress !== undefined
      || value.implementationRuntimeCodeHash !== undefined) {
      throw new Error('QUOTE_INDEXER_REGISTRY_plain_proxy_fields_invalid');
    }
    return {
      runtimeCodeHash,
      proxyRuntimeCodeHash: null,
      implementationAddress: null,
      implementationRuntimeCodeHash: null,
    };
  }

  const proxyRuntimeCodeHash = parseHashField(
    value.proxyRuntimeCodeHash,
    'QUOTE_INDEXER_REGISTRY_proxyRuntimeCodeHash_invalid',
  );
  const implementationAddress = typeof value.implementationAddress === 'string' && ADDRESS.test(value.implementationAddress)
    ? value.implementationAddress.toLowerCase() as Address
    : null;
  if (!implementationAddress || implementationAddress === '0x0000000000000000000000000000000000000000') {
    throw new Error('QUOTE_INDEXER_REGISTRY_implementationAddress_invalid');
  }
  const implementationRuntimeCodeHash = parseHashField(
    value.implementationRuntimeCodeHash,
    'QUOTE_INDEXER_REGISTRY_implementationRuntimeCodeHash_invalid',
  );
  if (value.runtimeCodeHash !== undefined) {
    const runtimeCodeHash = parseHashField(value.runtimeCodeHash, 'QUOTE_INDEXER_REGISTRY_runtimeCodeHash_invalid');
    if (runtimeCodeHash !== proxyRuntimeCodeHash) throw new Error('QUOTE_INDEXER_REGISTRY_runtimeCodeHash_proxy_mismatch');
  }
  return {
    runtimeCodeHash: proxyRuntimeCodeHash,
    proxyRuntimeCodeHash,
    implementationAddress,
    implementationRuntimeCodeHash,
  };
}

function parseHashField(value: unknown, error: string): Hex {
  const hash = typeof value === 'string' && HASH.test(value) ? value.toLowerCase() as Hex : null;
  if (!hash) throw new Error(error);
  return hash;
}

function parseDecimalBigInt(value: unknown, error: string) {
  if ((typeof value !== 'string' && typeof value !== 'number') || !/^\d+$/.test(String(value))) throw new Error(error);
  return BigInt(value);
}

function canonicalJson(value: unknown): string {
  if (value === null || typeof value === 'string' || typeof value === 'boolean') return JSON.stringify(value);
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) throw new Error('QUOTE_INDEXER_REGISTRY_abi_invalid');
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`;
  if (isRecord(value)) {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(',')}}`;
  }
  throw new Error('QUOTE_INDEXER_REGISTRY_abi_invalid');
}

function jsonSafe(value: unknown): unknown {
  if (typeof value === 'bigint') return value.toString();
  if (Array.isArray(value)) return value.map(jsonSafe);
  if (value instanceof Uint8Array) return `0x${Buffer.from(value).toString('hex')}`;
  if (isRecord(value)) return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, jsonSafe(item)]));
  return value;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}
