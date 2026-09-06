import type { Address, CanonicalRpc, Hex, RpcBlock, RpcBlockTag, RpcLog } from './types.ts';

type FetchLike = typeof fetch;

type JsonRpcResponse = Readonly<{
  jsonrpc?: unknown;
  id?: unknown;
  result?: unknown;
  error?: Readonly<{ code?: unknown; message?: unknown }>;
}>;

export class HttpJsonRpcClient implements CanonicalRpc {
  private nextId = 1;
  private readonly url: string;
  private readonly fetchImpl: FetchLike;
  private readonly timeoutMs: number;
  private readonly maxAttempts: number;

  constructor(
    url: string,
    fetchImpl: FetchLike = fetch,
    timeoutMs = 12_000,
    maxAttempts = 4,
  ) {
    const parsed = new URL(url);
    if (parsed.protocol !== 'https:' && parsed.protocol !== 'http:') throw new Error('BSC_HTTP_RPC_URL_invalid');
    this.url = url;
    this.fetchImpl = fetchImpl;
    this.timeoutMs = timeoutMs;
    this.maxAttempts = maxAttempts;
  }

  async getChainId() {
    return Number(parseQuantity(await this.request('eth_chainId', []), 'eth_chainId'));
  }

  async getCode(address: Address, blockTag: RpcBlockTag = 'latest'): Promise<Hex> {
    return parseData(await this.request('eth_getCode', [address, toBlockTag(blockTag)]), 'eth_getCode');
  }

  async getStorageAt(address: Address, slot: Hex, blockTag: RpcBlockTag = 'latest'): Promise<Hex> {
    return parseStorageWord(await this.request('eth_getStorageAt', [address, slot, toBlockTag(blockTag)]), 'eth_getStorageAt');
  }

  async getBlockNumber() {
    return parseQuantity(await this.request('eth_blockNumber', []), 'eth_blockNumber');
  }

  async getBlockByNumber(number: bigint): Promise<RpcBlock> {
    const raw = await this.request('eth_getBlockByNumber', [toQuantity(number), false]);
    if (!isRecord(raw)) throw new Error(`rpc_block_unavailable:${number}`);
    const parsedNumber = parseQuantity(raw.number, 'block.number');
    if (parsedNumber !== number) throw new Error(`rpc_block_number_mismatch:${number}`);
    return {
      number: parsedNumber,
      hash: parseHash(raw.hash, 'block.hash'),
      parentHash: parseHash(raw.parentHash, 'block.parentHash'),
      timestamp: parseQuantity(raw.timestamp, 'block.timestamp'),
    };
  }

  async getLogs(filter: Readonly<{
    fromBlock: bigint;
    toBlock: bigint;
    addresses: readonly Address[];
    topic0: readonly Hex[];
  }>): Promise<readonly RpcLog[]> {
    const raw = await this.request('eth_getLogs', [{
      fromBlock: toQuantity(filter.fromBlock),
      toBlock: toQuantity(filter.toBlock),
      address: [...filter.addresses],
      topics: [[...filter.topic0]],
    }]);
    if (!Array.isArray(raw)) throw new Error('rpc_logs_invalid');
    return raw.map(parseLog);
  }

  private async request(method: string, params: readonly unknown[]): Promise<unknown> {
    const id = this.nextId++;
    let lastError: unknown;
    for (let attempt = 0; attempt < this.maxAttempts; attempt += 1) {
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), this.timeoutMs);
      try {
        const response = await this.fetchImpl(this.url, {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ jsonrpc: '2.0', id, method, params }),
          signal: controller.signal,
        });
        if (!response.ok) throw new Error(`rpc_http_${response.status}`);
        const payload = await response.json() as JsonRpcResponse;
        if (payload.id !== id || payload.jsonrpc !== '2.0') throw new Error('rpc_response_mismatch');
        if (payload.error) {
          const code = typeof payload.error.code === 'number' ? payload.error.code : 'unknown';
          throw new Error(`rpc_error_${code}`);
        }
        return payload.result;
      } catch (error) {
        lastError = error;
        if (attempt + 1 >= this.maxAttempts) break;
        await wait(Math.min(4_000, 250 * (2 ** attempt)));
      } finally {
        clearTimeout(timeout);
      }
    }
    throw lastError instanceof Error ? lastError : new Error('rpc_request_failed');
  }
}

function parseLog(value: unknown): RpcLog {
  if (!isRecord(value) || !Array.isArray(value.topics)) throw new Error('rpc_log_invalid');
  const transactionIndex = toSafeNumber(parseQuantity(value.transactionIndex, 'log.transactionIndex'), 'log.transactionIndex');
  const logIndex = toSafeNumber(parseQuantity(value.logIndex, 'log.logIndex'), 'log.logIndex');
  return {
    address: parseAddress(value.address, 'log.address'),
    blockHash: parseHash(value.blockHash, 'log.blockHash'),
    blockNumber: parseQuantity(value.blockNumber, 'log.blockNumber'),
    transactionHash: parseHash(value.transactionHash, 'log.transactionHash'),
    transactionIndex,
    logIndex,
    topics: value.topics.map((topic) => parseHash(topic, 'log.topic')),
    data: parseData(value.data, 'log.data'),
    removed: value.removed === true,
  };
}

function toQuantity(value: bigint) {
  if (value < 0n) throw new Error('negative_rpc_quantity');
  return `0x${value.toString(16)}`;
}

function toBlockTag(value: RpcBlockTag) {
  return value === 'latest' ? value : toQuantity(value);
}

function parseQuantity(value: unknown, field: string) {
  if (typeof value !== 'string' || !/^0x(?:0|[1-9a-fA-F][0-9a-fA-F]*)$/.test(value)) throw new Error(`invalid_${field}`);
  return BigInt(value);
}

function parseHash(value: unknown, field: string): Hex {
  if (typeof value !== 'string' || !/^0x[0-9a-fA-F]{64}$/.test(value)) throw new Error(`invalid_${field}`);
  return value.toLowerCase() as Hex;
}

function parseAddress(value: unknown, field: string): Address {
  if (typeof value !== 'string' || !/^0x[0-9a-fA-F]{40}$/.test(value)) throw new Error(`invalid_${field}`);
  return value.toLowerCase() as Address;
}

function parseData(value: unknown, field: string): Hex {
  if (typeof value !== 'string' || !/^0x(?:[0-9a-fA-F]{2})*$/.test(value)) throw new Error(`invalid_${field}`);
  return value.toLowerCase() as Hex;
}

function parseStorageWord(value: unknown, field: string): Hex {
  if (typeof value !== 'string' || !/^0x[0-9a-fA-F]{64}$/.test(value)) throw new Error(`invalid_${field}`);
  return value.toLowerCase() as Hex;
}

function toSafeNumber(value: bigint, field: string) {
  const number = Number(value);
  if (!Number.isSafeInteger(number) || number < 0) throw new Error(`invalid_${field}`);
  return number;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function wait(milliseconds: number) {
  return new Promise<void>((resolve) => setTimeout(resolve, milliseconds));
}
