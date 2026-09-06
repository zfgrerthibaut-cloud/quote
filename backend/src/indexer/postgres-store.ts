import type { Pool, PoolClient } from 'pg';

import { projectPancakeV3Swap, type QuoteDirectMarket } from './pancake-v3-trades.ts';
import type {
  Address,
  DecodedQuoteLog,
  Hex,
  IndexerCursor,
  IndexerStore,
  OutboxEmission,
  PancakeV3PoolCursor,
  RegistryInstallEntry,
  RpcBlock,
} from './types.ts';

export class PostgresIndexerStore implements IndexerStore {
  private readonly pool: Pool;

  constructor(pool: Pool) {
    this.pool = pool;
  }

  async installRegistry(entries: readonly RegistryInstallEntry[]) {
    await this.transaction(entries[0]?.chainId ?? 56, async (client) => {
      for (const entry of entries) {
        const result = await client.query(
          `INSERT INTO indexer_contract_registry(
             chain_id, address, start_block, abi_version_hash, kind, runtime_code_hash,
             proxy_runtime_code_hash, implementation_address, implementation_runtime_code_hash
           ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
           ON CONFLICT (chain_id, address, start_block) DO NOTHING
           RETURNING abi_version_hash, kind, runtime_code_hash, proxy_runtime_code_hash,
                     implementation_address, implementation_runtime_code_hash`,
          [
            entry.chainId,
            bytes(entry.address, 20),
            entry.startBlock.toString(),
            bytes(entry.abiVersionHash, 32),
            entry.kind,
            bytes(entry.runtimeCodeHash, 32),
            nullableBytes(entry.proxyRuntimeCodeHash, 32),
            nullableBytes(entry.implementationAddress, 20),
            nullableBytes(entry.implementationRuntimeCodeHash, 32),
          ],
        );
        if (result.rowCount === 1) {
          const cursor = await client.query(
            'SELECT canonical_number::text FROM chain_cursors WHERE chain_id = $1',
            [entry.chainId],
          );
          if (cursor.rowCount === 1 && BigInt(cursor.rows[0].canonical_number) >= entry.startBlock) {
            throw new Error('registry_historical_backfill_required');
          }
          continue;
        }
        const existing = await client.query(
          `SELECT abi_version_hash, kind, runtime_code_hash, proxy_runtime_code_hash,
                  implementation_address, implementation_runtime_code_hash
             FROM indexer_contract_registry
           WHERE chain_id = $1 AND address = $2 AND start_block = $3`,
          [entry.chainId, bytes(entry.address, 20), entry.startBlock.toString()],
        );
        const stored = hex(existing.rows[0]?.abi_version_hash);
        if (stored !== entry.abiVersionHash.toLowerCase()) throw new Error('registry_version_conflict');
        if (registrySnapshot(existing.rows[0]) !== configuredRegistrySnapshot(entry)) throw new Error('registry_runtime_pin_conflict');
      }

      const installed = await client.query(
        `SELECT address, start_block::text, abi_version_hash, kind, runtime_code_hash,
                proxy_runtime_code_hash, implementation_address, implementation_runtime_code_hash
         FROM indexer_contract_registry WHERE chain_id = $1`,
        [entries[0]?.chainId ?? 56],
      );
      const configured = new Set(entries.map(configuredRegistrySnapshot));
      if (installed.rows.some((row) => !configured.has(
        registrySnapshot(row),
      ))) throw new Error('registry_snapshot_cannot_remove_entries');
    });
  }

  async loadCursor(chainId: number): Promise<IndexerCursor | null> {
    const result = await this.pool.query(
      `SELECT chain_id, canonical_number::text, canonical_hash, observed_number::text,
              finalized_number::text, generation::text
       FROM chain_cursors WHERE chain_id = $1`,
      [chainId],
    );
    return result.rowCount === 0 ? null : rowToCursor(result.rows[0]);
  }

  async initializeCursor(chainId: number, baseline: RpcBlock, observedNumber: bigint) {
    return this.transaction(chainId, async (client) => {
      await insertCanonicalBlock(client, chainId, baseline);
      const result = await client.query(
        `INSERT INTO chain_cursors(
           chain_id, canonical_number, canonical_hash, observed_number,
           finalized_number, generation, status
         ) VALUES ($1, $2, $3, $4, $2, 0, 'syncing')
         ON CONFLICT (chain_id) DO UPDATE
         SET observed_number = GREATEST(chain_cursors.observed_number, EXCLUDED.observed_number),
             updated_at = now()
         RETURNING chain_id, canonical_number::text, canonical_hash, observed_number::text,
                   finalized_number::text, generation::text`,
        [chainId, baseline.number.toString(), bytes(baseline.hash, 32), maximum(observedNumber, baseline.number).toString()],
      );
      return rowToCursor(result.rows[0]);
    });
  }

  async updateObservedHead(chainId: number, observedNumber: bigint) {
    await this.pool.query(
      `UPDATE chain_cursors
       SET observed_number = GREATEST(observed_number, $2), updated_at = now()
       WHERE chain_id = $1`,
      [chainId, observedNumber.toString()],
    );
  }

  async setStatus(chainId: number, status: 'syncing' | 'live' | 'stale' | 'halted') {
    await this.pool.query(
      'UPDATE chain_cursors SET status = $2, updated_at = now() WHERE chain_id = $1',
      [chainId, status],
    );
  }

  async getCanonicalBlock(chainId: number, number: bigint): Promise<RpcBlock | null> {
    const result = await this.pool.query(
      `SELECT number::text, hash, parent_hash, extract(epoch FROM block_time)::text AS timestamp
       FROM chain_blocks WHERE chain_id = $1 AND number = $2 AND canonical`,
      [chainId, number.toString()],
    );
    return result.rowCount === 0 ? null : rowToBlock(result.rows[0]);
  }

  async loadPancakeV3PoolCursors(chainId: number, throughBlock: bigint) {
    return this.transaction(chainId, async (client) => {
      await client.query(
        `INSERT INTO indexer_pancake_v3_pool_cursors(
           chain_id, market, launchpad, launch_id, start_block, indexed_through
         )
         SELECT chain_id, market, launchpad, launch_id, launch_block, launch_block - 1
         FROM markets
         WHERE chain_id = $1 AND engine_kind = 1 AND launch_block <= $2
         ON CONFLICT (chain_id, market) DO NOTHING`,
        [chainId, throughBlock.toString()],
      );
      const result = await client.query(
        `SELECT
           '0x' || encode(market, 'hex') AS market,
           '0x' || encode(launchpad, 'hex') AS launchpad,
           launch_id::text,
           start_block::text,
           indexed_through::text
         FROM indexer_pancake_v3_pool_cursors
         WHERE chain_id = $1 AND start_block <= $2 AND indexed_through < $2
         ORDER BY indexed_through ASC, start_block ASC, launch_id ASC
         LIMIT 1`,
        [chainId, throughBlock.toString()],
      );
      return result.rows.map(rowToPancakeV3PoolCursor);
    });
  }

  async commitBlock(
    chainId: number,
    block: RpcBlock,
    logs: readonly DecodedQuoteLog[],
    emissions: readonly OutboxEmission[],
    observedNumber: bigint,
  ) {
    if (logs.length !== emissions.length) throw new Error('log_emission_count_mismatch');
    await this.transaction(chainId, async (client) => {
      const cursorResult = await client.query(
        `SELECT canonical_number::text, canonical_hash, generation::text
         FROM chain_cursors WHERE chain_id = $1 FOR UPDATE`,
        [chainId],
      );
      if (cursorResult.rowCount !== 1) throw new Error('cursor_missing');
      const currentNumber = BigInt(cursorResult.rows[0].canonical_number);
      const currentHash = hex(cursorResult.rows[0].canonical_hash);
      const generation = BigInt(cursorResult.rows[0].generation);
      if (block.number !== currentNumber + 1n) throw new Error('cursor_height_mismatch');
      if (block.parentHash.toLowerCase() !== currentHash) throw new Error('cursor_parent_mismatch');

      await insertCanonicalBlock(client, chainId, block);
      for (let index = 0; index < logs.length; index += 1) {
        const log = logs[index];
        await insertRawLog(client, chainId, log);
        if (log.eventName === 'QuotePriceAttestationConsumed') {
          await insertQuotePriceAttestationFact(client, chainId, log);
        }
        if (log.eventName === 'DirectMarketLaunched') {
          await insertDirectMarketLaunchFact(client, chainId, log);
        }
        if (log.eventName === 'QUOTEMarketLaunched') await insertMarket(client, chainId, block, log);
        const emission = emissions[index];
        await client.query(
          `INSERT INTO outbox(topic, aggregate_id, dedupe_key, payload)
           VALUES ($1, $2, $3, $4::jsonb)
           ON CONFLICT (dedupe_key) DO NOTHING`,
          [
            emission.topic,
            emission.aggregateId,
            `${emission.dedupeKey}:g${generation}`,
            JSON.stringify({ ...emission.payload, generation: generation.toString() }),
          ],
        );
      }

      await client.query(
        `UPDATE chain_cursors
         SET canonical_number = $2, canonical_hash = $3,
             observed_number = GREATEST(observed_number, $4), finalized_number = $2,
             status = 'live', updated_at = now()
         WHERE chain_id = $1`,
        [chainId, block.number.toString(), bytes(block.hash, 32), maximum(observedNumber, block.number).toString()],
      );
    });
  }

  async commitPancakeV3PoolBackfill(
    chainId: number,
    logs: readonly DecodedQuoteLog[],
    poolCursors: readonly PancakeV3PoolCursor[],
    indexedThrough: bigint,
  ) {
    await this.transaction(chainId, async (client) => {
      for (const log of logs) {
        await insertRawLog(client, chainId, log);
        await insertDirectPancakeV3Trade(client, chainId, log);
      }
      for (const poolCursor of poolCursors) {
        await client.query(
          `UPDATE indexer_pancake_v3_pool_cursors
           SET indexed_through = GREATEST(indexed_through, $3), updated_at = now()
           WHERE chain_id = $1 AND market = $2`,
          [chainId, bytes(poolCursor.market, 20), indexedThrough.toString()],
        );
      }
    });
  }

  async rollback(chainId: number, ancestor: RpcBlock, oldTip: RpcBlock) {
    await this.transaction(chainId, async (client) => {
      const cursorResult = await client.query(
        `SELECT canonical_number::text, canonical_hash, observed_number::text, generation::text
         FROM chain_cursors WHERE chain_id = $1 FOR UPDATE`,
        [chainId],
      );
      if (cursorResult.rowCount !== 1) throw new Error('cursor_missing');
      if (
        BigInt(cursorResult.rows[0].canonical_number) !== oldTip.number
        || hex(cursorResult.rows[0].canonical_hash) !== oldTip.hash.toLowerCase()
      ) throw new Error('cursor_changed_before_rollback');
      const nextGeneration = BigInt(cursorResult.rows[0].generation) + 1n;

      const removedMarkets = await client.query(
        `SELECT launchpad, launch_id::text, token, launch_block::text, launch_log_index
         FROM markets
         WHERE chain_id = $1 AND launch_block > $2
         ORDER BY launch_block, launch_log_index, launch_id`,
        [chainId, ancestor.number.toString()],
      );
      const retainedAffected = await client.query(
        `SELECT DISTINCT trade.launchpad, trade.launch_id::text
         FROM market_trade_events AS trade
         JOIN markets AS market
           ON market.chain_id = trade.chain_id
          AND market.launchpad = trade.launchpad
          AND market.launch_id = trade.launch_id
         WHERE trade.chain_id = $1 AND trade.block_number > $2
           AND trade.canonical AND market.launch_block <= $2`,
        [chainId, ancestor.number.toString()],
      );

      await insertOutbox(client, {
        topic: 'chain.reorg',
        aggregateId: String(chainId),
        dedupeKey: `reorg:${chainId}:${oldTip.hash}:${ancestor.hash}:g${nextGeneration}`,
        payload: {
          schemaVersion: 1,
          type: 'chain.reorg',
          chainId,
          previousBlockNumber: oldTip.number.toString(),
          previousBlockHash: oldTip.hash,
          ancestorBlockNumber: ancestor.number.toString(),
          ancestorBlockHash: ancestor.hash,
          generation: nextGeneration.toString(),
        },
      });

      await client.query(
        `UPDATE quote_price_attestation_facts
         SET canonical = false, orphaned_at = now(), orphan_reason = 'chain_reorg'
         WHERE chain_id = $1 AND block_number > $2 AND canonical`,
        [chainId, ancestor.number.toString()],
      );
      await client.query(
        `UPDATE direct_market_launch_facts
         SET canonical = false, orphaned_at = now(), orphan_reason = 'chain_reorg'
         WHERE chain_id = $1 AND block_number > $2 AND canonical`,
        [chainId, ancestor.number.toString()],
      );
      await client.query(
        `UPDATE market_trade_events
         SET canonical = false, orphaned_at = now(), orphan_reason = 'chain_reorg'
         WHERE chain_id = $1 AND block_number > $2 AND canonical`,
        [chainId, ancestor.number.toString()],
      );
      await client.query(
        `UPDATE indexer_pancake_v3_pool_cursors
         SET indexed_through = GREATEST(start_block - 1, $2), updated_at = now()
         WHERE chain_id = $1 AND indexed_through > $2`,
        [chainId, ancestor.number.toString()],
      );
      for (const row of retainedAffected.rows) {
        await client.query(
          'SELECT rebuild_market_trade_projection($1, $2, $3::numeric)',
          [chainId, row.launchpad, row.launch_id],
        );
      }

      for (const row of removedMarkets.rows) {
        await client.query(
          'DELETE FROM market_candles_1m WHERE chain_id = $1 AND launchpad = $2 AND launch_id = $3::numeric',
          [chainId, row.launchpad, row.launch_id],
        );
        await client.query(
          'DELETE FROM market_live_stats WHERE chain_id = $1 AND launchpad = $2 AND launch_id = $3::numeric',
          [chainId, row.launchpad, row.launch_id],
        );
        await client.query(
          'DELETE FROM market_trade_events WHERE chain_id = $1 AND launchpad = $2 AND launch_id = $3::numeric',
          [chainId, row.launchpad, row.launch_id],
        );
        await client.query(
          'DELETE FROM markets WHERE chain_id = $1 AND launchpad = $2 AND launch_id = $3::numeric',
          [chainId, row.launchpad, row.launch_id],
        );
      }

      await client.query(
        'UPDATE raw_logs SET canonical = false WHERE chain_id = $1 AND block_number > $2 AND canonical',
        [chainId, ancestor.number.toString()],
      );
      await client.query(
        'UPDATE chain_blocks SET canonical = false WHERE chain_id = $1 AND number > $2 AND canonical',
        [chainId, ancestor.number.toString()],
      );
      await client.query(
        `UPDATE chain_cursors
         SET canonical_number = $2, canonical_hash = $3, finalized_number = $2,
             generation = $4, status = 'syncing', updated_at = now()
         WHERE chain_id = $1`,
        [chainId, ancestor.number.toString(), bytes(ancestor.hash, 32), nextGeneration.toString()],
      );

      for (const row of removedMarkets.rows) {
        const launchpad = hex(row.launchpad);
        await insertOutbox(client, {
          topic: 'market.removed',
          aggregateId: `${chainId}:${launchpad}:${row.launch_id}`,
          dedupeKey: `market-removed:${chainId}:${launchpad}:${row.launch_id}:g${nextGeneration}`,
          payload: {
            schemaVersion: 1,
            type: 'market.removed',
            chainId,
            launchpad,
            launchId: String(row.launch_id),
            tokenAddress: hex(row.token),
            blockNumber: String(row.launch_block),
            logIndex: Number(row.launch_log_index),
            generation: nextGeneration.toString(),
          },
        });
      }
    });
  }

  private async transaction<T>(chainId: number, operation: (client: PoolClient) => Promise<T>): Promise<T> {
    const client = await this.pool.connect();
    try {
      await client.query('BEGIN');
      await client.query('SELECT pg_advisory_xact_lock($1)', [chainId]);
      const value = await operation(client);
      await client.query('COMMIT');
      return value;
    } catch (error) {
      await client.query('ROLLBACK').catch(() => undefined);
      throw error;
    } finally {
      client.release();
    }
  }
}

async function insertCanonicalBlock(client: PoolClient, chainId: number, block: RpcBlock) {
  await client.query(
    `INSERT INTO chain_blocks(chain_id, number, hash, parent_hash, block_time, canonical)
     VALUES ($1, $2, $3, $4, $5, true)
     ON CONFLICT (chain_id, hash) DO UPDATE
     SET canonical = true, number = EXCLUDED.number, parent_hash = EXCLUDED.parent_hash,
         block_time = EXCLUDED.block_time, observed_at = now()`,
    [
      chainId,
      block.number.toString(),
      bytes(block.hash, 32),
      bytes(block.parentHash, 32),
      blockDate(block.timestamp),
    ],
  );
}

async function insertRawLog(client: PoolClient, chainId: number, log: DecodedQuoteLog) {
  await client.query(
    `INSERT INTO raw_logs(
       chain_id, block_hash, block_number, tx_hash, tx_index, log_index,
       address, topics, data, decoded, canonical
     ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8::jsonb,$9,$10::jsonb,true)
     ON CONFLICT (chain_id, block_hash, tx_hash, log_index) DO UPDATE
     SET canonical = true, decoded = EXCLUDED.decoded`,
    [
      chainId,
      bytes(log.blockHash, 32),
      log.blockNumber.toString(),
      bytes(log.transactionHash, 32),
      log.transactionIndex,
      log.logIndex,
      bytes(log.address, 20),
      JSON.stringify(log.topics),
      bytes(log.data),
      JSON.stringify(decodedPayload(log)),
    ],
  );
}

async function insertMarket(client: PoolClient, chainId: number, block: RpcBlock, log: DecodedQuoteLog) {
  const launchId = uintArg(log, 'launchId');
  const engineKind = boundedNumber(uintArg(log, 'engineKind'), 1, 2, `${log.eventName}_engineKind`);
  const supply = positiveUintArg(log, 'supply');
  const engine = addressArg(log, 'engine');
  await client.query(
    `INSERT INTO markets(
       chain_id, launchpad, launch_id, engine_kind, engine_version, creator, token,
       quote_token, market, hook, vault, locker, pool_id, engine_record_id, engine, supply,
       requested_supply, pool_fee,
       creator_fee_bps, reward_fee_bps, creator_lp_share_bps, launch_block,
       launch_tx_hash, launch_log_index, launched_at
     ) VALUES (
       $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22,$23,$24,$25
     ) ON CONFLICT (chain_id, launchpad, launch_id) DO NOTHING`,
    [
      chainId,
      bytes(log.address, 20),
      launchId,
      engineKind,
      bytes(hashArg(log, 'engineVersion'), 32),
      bytes(addressArg(log, 'creator'), 20),
      bytes(addressArg(log, 'token'), 20),
      bytes(addressArg(log, 'quoteToken'), 20),
      bytes(addressArg(log, 'market'), 20),
      bytes(addressArg(log, 'hook'), 20),
      bytes(addressArg(log, 'vault'), 20),
      bytes(addressArg(log, 'locker'), 20),
      bytes(hashArg(log, 'poolId'), 32),
      bytes(hashArg(log, 'engineRecordId'), 32),
      bytes(engine, 20),
      supply,
      supply,
      engineKind === 1 ? 10_000 : null,
      boundedNumber(uintArg(log, 'creatorSwapFeeBps'), 0, 100, `${log.eventName}_creatorSwapFeeBps`),
      boundedNumber(uintArg(log, 'rewardFeeBps'), 0, 300, `${log.eventName}_rewardFeeBps`),
      boundedNumber(uintArg(log, 'creatorLpShareBps'), 0, 10_000, `${log.eventName}_creatorLpShareBps`),
      block.number.toString(),
      bytes(log.transactionHash, 32),
      log.logIndex,
      blockDate(block.timestamp),
    ],
  );
  if (engineKind === 1) {
    await client.query(
      'SELECT apply_direct_market_valuation($1, $2, $3::numeric)',
      [chainId, bytes(engine, 20), launchId],
    );
  }
}

async function insertQuotePriceAttestationFact(client: PoolClient, chainId: number, log: DecodedQuoteLog) {
  const digest = hashArg(log, 'digest');
  await client.query(
    `INSERT INTO quote_price_attestation_facts(
       chain_id,
       verifier,
       digest,
       consumer,
       creator,
       launch_request_hash,
       quote_token,
       reference_token,
       reference_pool,
       price_usd_wad,
       liquidity_usd_wad,
       observation_timestamp,
       attestation_deadline,
       nonce,
       block_hash,
       block_number,
       tx_hash,
       tx_index,
       log_index
     ) VALUES (
       $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19
     ) ON CONFLICT (chain_id, block_hash, tx_hash, log_index) DO UPDATE
     SET canonical = true, orphaned_at = NULL, orphan_reason = NULL`,
    [
      chainId,
      bytes(log.address, 20),
      bytes(digest, 32),
      bytes(addressArg(log, 'consumer'), 20),
      bytes(addressArg(log, 'creator'), 20),
      bytes(hashArg(log, 'launchRequestHash'), 32),
      bytes(addressArg(log, 'quoteToken'), 20),
      bytes(addressArg(log, 'referenceToken'), 20),
      bytes(addressArg(log, 'referencePool'), 20),
      positiveUintArg(log, 'priceUsdWad'),
      uintArg(log, 'liquidityUsdWad'),
      unixTimestampDate(uintArg(log, 'observationTimestamp')),
      unixTimestampDate(uintArg(log, 'deadline')),
      bytes(hashArg(log, 'nonce'), 32),
      bytes(log.blockHash, 32),
      log.blockNumber.toString(),
      bytes(log.transactionHash, 32),
      log.transactionIndex,
      log.logIndex,
    ],
  );
  await client.query('SELECT apply_quote_attestation_valuation($1, $2)', [chainId, bytes(digest, 32)]);
}

async function insertDirectMarketLaunchFact(client: PoolClient, chainId: number, log: DecodedQuoteLog) {
  const launchId = uintArg(log, 'launchId');
  await client.query(
    `INSERT INTO direct_market_launch_facts(
       chain_id,
       engine,
       launch_id,
       creator,
       token,
       quote_token,
       pool,
       locker,
       position_token_id,
       deposited_supply,
       target_fdv_usd_wad,
       quote_price_usd_wad,
       sqrt_price_x96,
       tick_lower,
       tick_upper,
       fee_tier,
       quote_decimals,
       attestation_digest,
       block_hash,
       block_number,
       tx_hash,
       tx_index,
       log_index
     ) VALUES (
       $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22,$23
     ) ON CONFLICT (chain_id, block_hash, tx_hash, log_index) DO UPDATE
     SET canonical = true, orphaned_at = NULL, orphan_reason = NULL`,
    [
      chainId,
      bytes(log.address, 20),
      launchId,
      bytes(addressArg(log, 'creator'), 20),
      bytes(addressArg(log, 'token'), 20),
      bytes(addressArg(log, 'quoteToken'), 20),
      bytes(addressArg(log, 'pool'), 20),
      bytes(addressArg(log, 'locker'), 20),
      positiveUintArg(log, 'positionTokenId'),
      positiveUintArg(log, 'depositedSupply'),
      positiveUintArg(log, 'targetFdvUsdWad'),
      positiveUintArg(log, 'quotePriceUsdWad'),
      positiveUintArg(log, 'sqrtPriceX96'),
      intArg(log, 'tickLower'),
      intArg(log, 'tickUpper'),
      boundedNumber(uintArg(log, 'feeTier'), 1, 1_000_000, `${log.eventName}_feeTier`),
      optionalBoundedNumber(log, 'quoteDecimals', 0, 36),
      bytes(hashArg(log, 'attestationDigest'), 32),
      bytes(log.blockHash, 32),
      log.blockNumber.toString(),
      bytes(log.transactionHash, 32),
      log.transactionIndex,
      log.logIndex,
    ],
  );
  await client.query(
    'SELECT apply_direct_market_valuation($1, $2, $3::numeric)',
    [chainId, bytes(log.address, 20), launchId],
  );
}

async function insertDirectPancakeV3Trade(client: PoolClient, chainId: number, log: DecodedQuoteLog) {
  const result = await client.query(
    `SELECT
       market.chain_id,
       '0x' || encode(market.launchpad, 'hex') AS launchpad,
       market.launch_id::text,
       '0x' || encode(market.token, 'hex') AS token,
       '0x' || encode(market.quote_token, 'hex') AS quote_token,
       '0x' || encode(market.market, 'hex') AS market,
       block.block_time
     FROM markets AS market
     JOIN chain_blocks AS block
       ON block.chain_id = market.chain_id
      AND block.hash = $3
      AND block.number = $4
      AND block.canonical
     WHERE market.chain_id = $1
       AND market.market = $2
       AND market.engine_kind = 1`,
    [chainId, bytes(log.address, 20), bytes(log.blockHash, 32), log.blockNumber.toString()],
  );
  if (result.rowCount !== 1) throw new Error('pancake_v3_direct_market_missing');
  const row = result.rows[0] as Record<string, unknown>;
  const trade = projectPancakeV3Swap(log, rowToDirectMarket(row));
  await client.query(
    `INSERT INTO market_trade_events(
       chain_id,
       launchpad,
       launch_id,
       phase,
       trade_type,
       venue,
       trader,
       recipient,
       token_in,
       token_out,
       amount_in_raw,
       amount_out_raw,
       token_amount_raw,
       quote_amount_raw,
       token_amount_signed_raw,
       quote_amount_signed_raw,
       price_numerator_raw,
       price_denominator_raw,
       block_hash,
       block_number,
       tx_hash,
       tx_index,
       log_index,
       event_ordinal,
       trade_time
     ) VALUES (
       $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22,$23,0,$24
     )
     ON CONFLICT (chain_id, block_hash, tx_hash, log_index, event_ordinal) DO NOTHING`,
    [
      trade.chainId,
      bytes(trade.launchpad, 20),
      trade.launchId,
      trade.phase,
      trade.tradeType,
      bytes(trade.venue, 20),
      bytes(trade.trader, 20),
      bytes(trade.recipient, 20),
      bytes(trade.tokenIn, 20),
      bytes(trade.tokenOut, 20),
      trade.amountInRaw,
      trade.amountOutRaw,
      trade.tokenAmountRaw,
      trade.quoteAmountRaw,
      trade.tokenAmountSignedRaw,
      trade.quoteAmountSignedRaw,
      trade.priceNumeratorRaw,
      trade.priceDenominatorRaw,
      bytes(log.blockHash, 32),
      log.blockNumber.toString(),
      bytes(log.transactionHash, 32),
      log.transactionIndex,
      log.logIndex,
      row.block_time,
    ],
  );
}

async function insertOutbox(client: PoolClient, emission: OutboxEmission) {
  await client.query(
    `INSERT INTO outbox(topic, aggregate_id, dedupe_key, payload)
     VALUES ($1, $2, $3, $4::jsonb) ON CONFLICT (dedupe_key) DO NOTHING`,
    [emission.topic, emission.aggregateId, emission.dedupeKey, JSON.stringify(emission.payload)],
  );
}

function decodedPayload(log: DecodedQuoteLog) {
  return {
    schemaVersion: 1,
    eventName: log.eventName,
    eventSignature: log.eventSignature,
    abiVersionHash: log.abiVersionHash,
    args: log.args,
  };
}

function rowToCursor(row: Record<string, unknown>): IndexerCursor {
  return {
    chainId: Number(row.chain_id),
    canonicalNumber: BigInt(String(row.canonical_number)),
    canonicalHash: hex(row.canonical_hash),
    observedNumber: BigInt(String(row.observed_number)),
    finalizedNumber: BigInt(String(row.finalized_number)),
    generation: BigInt(String(row.generation)),
  };
}

function rowToPancakeV3PoolCursor(row: Record<string, unknown>): PancakeV3PoolCursor {
  return {
    market: rowAddress(row, 'market'),
    launchpad: rowAddress(row, 'launchpad'),
    launchId: String(row.launch_id),
    startBlock: BigInt(String(row.start_block)),
    indexedThrough: BigInt(String(row.indexed_through)),
  };
}

function rowToDirectMarket(row: Record<string, unknown>): QuoteDirectMarket {
  return {
    chainId: Number(row.chain_id),
    launchpad: rowAddress(row, 'launchpad'),
    launchId: String(row.launch_id),
    token: rowAddress(row, 'token'),
    quoteToken: rowAddress(row, 'quote_token'),
    market: rowAddress(row, 'market'),
  };
}

function rowToBlock(row: Record<string, unknown>): RpcBlock {
  return {
    number: BigInt(String(row.number)),
    hash: hex(row.hash),
    parentHash: hex(row.parent_hash),
    timestamp: BigInt(String(row.timestamp).split('.')[0]),
  };
}

function uintArg(log: DecodedQuoteLog, name: string) {
  const value = log.args[name];
  if (typeof value !== 'string' || !/^\d+$/.test(value)) throw new Error(`invalid_${log.eventName}_${name}`);
  return value;
}

function intArg(log: DecodedQuoteLog, name: string) {
  const value = log.args[name];
  if (typeof value !== 'string' || !/^-?\d+$/.test(value)) throw new Error(`invalid_${log.eventName}_${name}`);
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed)) throw new Error(`invalid_${log.eventName}_${name}`);
  return parsed;
}

function positiveUintArg(log: DecodedQuoteLog, name: string) {
  const value = uintArg(log, name);
  if (BigInt(value) === 0n) throw new Error(`invalid_${log.eventName}_${name}`);
  return value;
}

function addressArg(log: DecodedQuoteLog, name: string): Address {
  const value = log.args[name];
  if (typeof value !== 'string' || !/^0x[0-9a-fA-F]{40}$/.test(value)) throw new Error(`invalid_${log.eventName}_${name}`);
  return value.toLowerCase() as Address;
}

function rowAddress(row: Record<string, unknown>, name: string): Address {
  const value = row[name];
  if (typeof value !== 'string' || !/^0x[0-9a-fA-F]{40}$/.test(value)) throw new Error(`invalid_database_${name}`);
  return value.toLowerCase() as Address;
}

function hashArg(log: DecodedQuoteLog, name: string): Hex {
  const value = log.args[name];
  if (typeof value !== 'string' || !/^0x[0-9a-fA-F]{64}$/.test(value)) throw new Error(`invalid_${log.eventName}_${name}`);
  return value.toLowerCase() as Hex;
}

function boundedNumber(value: string, minimum: number, maximum: number, field: string) {
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < minimum || parsed > maximum) throw new Error(`invalid_${field}`);
  return parsed;
}

function optionalBoundedNumber(log: DecodedQuoteLog, name: string, minimum: number, maximum: number) {
  const value = log.args[name];
  if (value === undefined || value === null) return null;
  if (typeof value !== 'string' || !/^\d+$/.test(value)) throw new Error(`invalid_${log.eventName}_${name}`);
  return boundedNumber(value, minimum, maximum, `${log.eventName}_${name}`);
}

function blockDate(timestamp: bigint) {
  const milliseconds = Number(timestamp) * 1_000;
  if (!Number.isSafeInteger(milliseconds)) throw new Error('block_timestamp_out_of_range');
  const date = new Date(milliseconds);
  if (Number.isNaN(date.getTime())) throw new Error('block_timestamp_invalid');
  return date;
}

function unixTimestampDate(value: string) {
  const timestamp = BigInt(value);
  if (timestamp > BigInt(Math.floor(Number.MAX_SAFE_INTEGER / 1_000))) throw new Error('timestamp_out_of_range');
  const date = new Date(Number(timestamp) * 1_000);
  if (Number.isNaN(date.getTime())) throw new Error('timestamp_invalid');
  return date;
}

function bytes(value: Hex, length?: number) {
  if (!/^0x(?:[0-9a-fA-F]{2})*$/.test(value)) throw new Error('invalid_hex');
  const buffer = Buffer.from(value.slice(2), 'hex');
  if (length !== undefined && buffer.length !== length) throw new Error('invalid_hex_length');
  return buffer;
}

function nullableBytes(value: Hex | null, length: number) {
  return value === null ? null : bytes(value, length);
}

function hex(value: unknown): Hex {
  if (!(value instanceof Uint8Array)) throw new Error('invalid_database_bytes');
  return `0x${Buffer.from(value).toString('hex')}`;
}

function nullableHex(value: unknown): Hex | null {
  return value === null || value === undefined ? null : hex(value);
}

function maximum(left: bigint, right: bigint) {
  return left > right ? left : right;
}

function registrySnapshot(row: Record<string, unknown>) {
  const runtimeCodeHash = nullableHex(row.runtime_code_hash);
  if (runtimeCodeHash === null) throw new Error('registry_runtime_codehash_legacy_null');
  const kind = row.kind;
  if (kind !== 'plain' && kind !== 'erc1967-uups') throw new Error('registry_kind_invalid');
  return [
    hex(row.address),
    String(row.start_block),
    hex(row.abi_version_hash),
    kind,
    runtimeCodeHash,
    nullableHex(row.proxy_runtime_code_hash) ?? '',
    nullableHex(row.implementation_address) ?? '',
    nullableHex(row.implementation_runtime_code_hash) ?? '',
  ].join(':');
}

function configuredRegistrySnapshot(entry: RegistryInstallEntry) {
  return [
    entry.address.toLowerCase(),
    entry.startBlock.toString(),
    entry.abiVersionHash.toLowerCase(),
    entry.kind,
    entry.runtimeCodeHash.toLowerCase(),
    entry.proxyRuntimeCodeHash?.toLowerCase() ?? '',
    entry.implementationAddress?.toLowerCase() ?? '',
    entry.implementationRuntimeCodeHash?.toLowerCase() ?? '',
  ].join(':');
}
