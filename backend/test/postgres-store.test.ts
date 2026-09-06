import assert from 'node:assert/strict';
import test from 'node:test';

import { PostgresIndexerStore } from '../src/indexer/postgres-store.ts';
import type { Address, DecodedQuoteLog, Hex, OutboxEmission, RegistryInstallEntry, RpcBlock } from '../src/indexer/types.ts';

const LAUNCHPAD = '0x1111111111111111111111111111111111111111';
const VERIFIER = '0x2222222222222222222222222222222222222222';
const ENGINE = '0x3333333333333333333333333333333333333333';
const CREATOR = '0x4444444444444444444444444444444444444444';
const TOKEN = '0x5555555555555555555555555555555555555555';
const QUOTE = '0x6666666666666666666666666666666666666666';
const POOL = '0x7777777777777777777777777777777777777777';
const LOCKER = '0x8888888888888888888888888888888888888888';
const REFERENCE_TOKEN = '0x9999999999999999999999999999999999999999';
const REFERENCE_POOL = '0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const IMPLEMENTATION = '0xabababababababababababababababababababab';
const ZERO = '0x0000000000000000000000000000000000000000';
const HASH = '0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' as Hex;
const PROXY_HASH = '0xcccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc' as Hex;
const IMPLEMENTATION_HASH = '0xdddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd' as Hex;
const OTHER_HASH = '0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' as Hex;

test('postgres store attaches direct valuation facts even when engine events arrive before the launchpad market event', async () => {
  const client = new FakePgClient();
  const store = new PostgresIndexerStore({ connect: async () => client } as never);
  const block = {
    number: 11n,
    hash: '0x0100000000000000000000000000000000000000000000000000000000000000' as Hex,
    parentHash: '0x0000000000000000000000000000000000000000000000000000000000000000' as Hex,
    timestamp: 1_700_000_011n,
  } satisfies RpcBlock;
  const logs = [
    decodedLog({
      address: VERIFIER,
      block,
      eventName: 'QuotePriceAttestationConsumed',
      logIndex: 1,
      args: {
        digest: HASH,
        consumer: ENGINE,
        creator: CREATOR,
        launchRequestHash: HASH,
        quoteToken: QUOTE,
        referenceToken: REFERENCE_TOKEN,
        referencePool: REFERENCE_POOL,
        priceUsdWad: '1000000000000000000',
        liquidityUsdWad: '10000000000000000000000',
        observationTimestamp: '1700000000',
        deadline: '1700000300',
        nonce: HASH,
      },
    }),
    decodedLog({
      address: ENGINE,
      block,
      eventName: 'DirectMarketLaunched',
      logIndex: 2,
      args: {
        launchId: '7',
        creator: CREATOR,
        token: TOKEN,
        quoteToken: QUOTE,
        pool: POOL,
        locker: LOCKER,
        positionTokenId: '12',
        depositedSupply: '999999999999999999',
        targetFdvUsdWad: '7000000000000000000000',
        quotePriceUsdWad: '1000000000000000000',
        sqrtPriceX96: '79228162514264337593543950336',
        tickLower: '-120',
        tickUpper: '120',
        feeTier: '10000',
        quoteDecimals: '18',
        attestationDigest: HASH,
      },
    }),
    decodedLog({
      address: LAUNCHPAD,
      block,
      eventName: 'QUOTEMarketLaunched',
      logIndex: 3,
      args: {
        launchId: '7',
        creator: CREATOR,
        engineVersion: HASH,
        engineKind: '1',
        engine: ENGINE,
        token: TOKEN,
        quoteToken: QUOTE,
        market: POOL,
        hook: ZERO,
        vault: ZERO,
        locker: LOCKER,
        supply: '1000000000000000000',
        creatorSwapFeeBps: '0',
        rewardFeeBps: '0',
        creatorLpShareBps: '2500',
        poolId: HASH,
        engineRecordId: '0xcccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
      },
    }),
  ];

  await store.commitBlock(56, block, logs, logs.map(emission), 12n);

  const statements = client.statements.join('\n');
  assert.match(statements, /INSERT INTO quote_price_attestation_facts/);
  assert.match(statements, /INSERT INTO direct_market_launch_facts/);
  assert.match(statements, /quote_decimals/);
  assert.match(statements, /INSERT INTO markets\(/);
  assert.match(statements, /SELECT apply_quote_attestation_valuation/);
  assert.equal(countMatches(statements, 'SELECT apply_direct_market_valuation'), 2);
  assert.equal(statements.includes('runtime_code_hash'), false);
});

test('postgres registry rejects legacy NULL runtime pins without backfilling', async () => {
  const entry = registryInstallEntry();
  const client = new FakeRegistryPgClient(registryRow(entry, { runtime_code_hash: null }));
  const store = new PostgresIndexerStore({ connect: async () => client } as never);

  await assert.rejects(store.installRegistry([entry]), /registry_runtime_codehash_legacy_null/);

  const statements = client.statements.join('\n');
  assert.equal(statements.includes('UPDATE indexer_contract_registry SET runtime_code_hash'), false);
  assert.equal(statements.includes('ROLLBACK'), true);
});

test('postgres registry install is idempotent for identical plain runtime pins', async () => {
  const entry = registryInstallEntry();
  const client = new FakeRegistryPgClient(registryRow(entry));
  const store = new PostgresIndexerStore({ connect: async () => client } as never);

  await assert.doesNotReject(store.installRegistry([entry]));

  const statements = client.statements.join('\n');
  assert.match(statements, /SELECT address, start_block::text, abi_version_hash/);
  assert.equal(statements.includes('ROLLBACK'), false);
  assert.equal(statements.includes('COMMIT'), true);
});

test('postgres registry install is idempotent for identical ERC-1967 UUPS runtime pins', async () => {
  const entry = uupsRegistryInstallEntry();
  const client = new FakeRegistryPgClient(registryRow(entry));
  const store = new PostgresIndexerStore({ connect: async () => client } as never);

  await assert.doesNotReject(store.installRegistry([entry]));

  assert.equal(client.statements.includes('COMMIT'), true);
});

test('postgres registry rejects conflicting ERC-1967 UUPS runtime pins cleanly', async () => {
  const entry = uupsRegistryInstallEntry();
  const client = new FakeRegistryPgClient(registryRow(entry, {
    implementation_runtime_code_hash: buffer(OTHER_HASH),
  }));
  const store = new PostgresIndexerStore({ connect: async () => client } as never);

  await assert.rejects(store.installRegistry([entry]), /registry_runtime_pin_conflict/);

  const statements = client.statements.join('\n');
  assert.equal(statements.includes('invalid_database_bytes'), false);
  assert.equal(statements.includes('ROLLBACK'), true);
});

class FakeRegistryPgClient {
  statements: string[] = [];
  private readonly existingRow: Record<string, unknown>;

  constructor(existingRow: Record<string, unknown>) {
    this.existingRow = existingRow;
  }

  async query(sql: string) {
    this.statements.push(sql);
    if (sql.includes('INSERT INTO indexer_contract_registry')) return { rowCount: 0, rows: [] };
    if (sql.includes('AND address = $2 AND start_block = $3')) {
      return { rowCount: 1, rows: [this.existingRow] };
    }
    if (sql.includes('FROM indexer_contract_registry WHERE chain_id = $1')) {
      return { rowCount: 1, rows: [this.existingRow] };
    }
    return { rowCount: 1, rows: [] };
  }

  release() {}
}

class FakePgClient {
  statements: string[] = [];

  async query(sql: string) {
    this.statements.push(sql);
    if (sql.includes('SELECT canonical_number::text, canonical_hash, generation::text')) {
      return {
        rowCount: 1,
        rows: [{
          canonical_number: '10',
          canonical_hash: Buffer.alloc(32),
          generation: '0',
        }],
      };
    }
    return { rowCount: 1, rows: [] };
  }

  release() {}
}

function decodedLog(input: Readonly<{
  address: string;
  block: RpcBlock;
  eventName: string;
  logIndex: number;
  args: Record<string, string>;
}>): DecodedQuoteLog {
  return {
    address: input.address as `0x${string}`,
    blockHash: input.block.hash,
    blockNumber: input.block.number,
    transactionHash: `0x${BigInt(input.logIndex).toString(16).padStart(64, '0')}`,
    transactionIndex: 0,
    logIndex: input.logIndex,
    topics: [HASH],
    data: '0x',
    removed: false,
    eventName: input.eventName,
    eventSignature: `${input.eventName}()`,
    abiVersionHash: HASH,
    args: input.args,
  };
}

function emission(log: DecodedQuoteLog): OutboxEmission {
  return {
    topic: 'quote.event',
    aggregateId: String(log.logIndex),
    dedupeKey: `test:${log.logIndex}`,
    payload: { logIndex: log.logIndex },
  };
}

function countMatches(value: string, needle: string) {
  return value.split(needle).length - 1;
}

function registryInstallEntry(): RegistryInstallEntry {
  return {
    chainId: 56,
    address: LAUNCHPAD as Address,
    startBlock: 10n,
    abiVersionHash: HASH,
    kind: 'plain',
    runtimeCodeHash: HASH,
    proxyRuntimeCodeHash: null,
    implementationAddress: null,
    implementationRuntimeCodeHash: null,
  };
}

function uupsRegistryInstallEntry(): RegistryInstallEntry {
  return {
    ...registryInstallEntry(),
    kind: 'erc1967-uups',
    runtimeCodeHash: PROXY_HASH,
    proxyRuntimeCodeHash: PROXY_HASH,
    implementationAddress: IMPLEMENTATION as Address,
    implementationRuntimeCodeHash: IMPLEMENTATION_HASH,
  };
}

function registryRow(entry: RegistryInstallEntry, overrides: Partial<Record<string, unknown>> = {}) {
  return {
    address: buffer(entry.address),
    start_block: entry.startBlock.toString(),
    abi_version_hash: buffer(entry.abiVersionHash),
    kind: entry.kind,
    runtime_code_hash: buffer(entry.runtimeCodeHash),
    proxy_runtime_code_hash: entry.proxyRuntimeCodeHash === null ? null : buffer(entry.proxyRuntimeCodeHash),
    implementation_address: entry.implementationAddress === null ? null : buffer(entry.implementationAddress),
    implementation_runtime_code_hash: entry.implementationRuntimeCodeHash === null
      ? null
      : buffer(entry.implementationRuntimeCodeHash),
    ...overrides,
  };
}

function buffer(value: Hex | Address) {
  return Buffer.from(value.slice(2), 'hex');
}
