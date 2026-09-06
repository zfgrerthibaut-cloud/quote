import type { Pool, PoolClient } from 'pg';
import type { WebSocket } from 'ws';

import { readOutboxAfter } from '../infra/postgres-markets.ts';

type ClientState = {
  socket: WebSocket;
  lastEventId: bigint;
  alive: boolean;
};

const MAX_REPLAY = 500;
const MAX_BUFFERED_BYTES = 1_000_000;
const MAX_PG_BIGINT = 9_223_372_036_854_775_807n;

export type MarketRealtimeHubOptions = Readonly<{
  maxClients?: number;
  maxReplayLag?: bigint;
  maxBufferedBytes?: number;
}>;

export class MarketRealtimeHub {
  private readonly pool: Pool;
  private readonly maxClients: number;
  private readonly maxReplayLag: bigint;
  private readonly maxBufferedBytes: number;
  private readonly clients = new Set<ClientState>();
  private listener: PoolClient | null = null;
  private latestBroadcastId = 0n;
  private flushing = false;
  private heartbeat: NodeJS.Timeout | null = null;
  private safetyPoll: NodeJS.Timeout | null = null;

  constructor(pool: Pool, options: MarketRealtimeHubOptions = {}) {
    this.pool = pool;
    this.maxClients = options.maxClients ?? 2_000;
    this.maxReplayLag = options.maxReplayLag ?? 50_000n;
    this.maxBufferedBytes = options.maxBufferedBytes ?? MAX_BUFFERED_BYTES;
  }

  async start() {
    const latest = await this.pool.query("SELECT COALESCE(max(id), 0)::text AS id FROM outbox");
    this.latestBroadcastId = BigInt(String(latest.rows[0]?.id ?? '0'));
    this.listener = await this.pool.connect();
    this.listener.on('notification', () => void this.flush());
    this.listener.on('error', () => void this.reconnectListener());
    await this.listener.query('LISTEN quote_outbox');
    this.heartbeat = setInterval(() => this.heartbeatClients(), 25_000);
    this.safetyPoll = setInterval(() => void this.flush(), 1_000);
  }

  async stop() {
    if (this.heartbeat) clearInterval(this.heartbeat);
    if (this.safetyPoll) clearInterval(this.safetyPoll);
    for (const client of this.clients) client.socket.close(1001, 'server_shutdown');
    this.clients.clear();
    if (this.listener) {
      await this.listener.query('UNLISTEN quote_outbox').catch(() => undefined);
      this.listener.release();
      this.listener = null;
    }
  }

  clientCount() {
    return this.clients.size;
  }

  canAcceptClient() {
    return this.clients.size < this.maxClients;
  }

  latestEventId() {
    return this.latestBroadcastId;
  }

  add(socket: WebSocket, after = 0n) {
    if (!this.canAcceptClient()) {
      socket.close(1013, 'capacity');
      return;
    }
    const state: ClientState = { socket, lastEventId: after, alive: true };
    this.clients.add(state);
    socket.on('pong', () => { state.alive = true; });
    socket.on('close', () => this.clients.delete(state));
    socket.on('error', () => this.clients.delete(state));
    socket.on('message', (raw) => this.handleClientMessage(state, raw.toString()));
    this.send(state, { schemaVersion: 1, type: 'connected', latestEventId: this.latestBroadcastId.toString() });
    void this.replay(state);
  }

  private async replay(client: ClientState) {
    if (this.isReplayTooOld(client.lastEventId)) {
      this.send(client, { schemaVersion: 1, type: 'resync_required', latestEventId: this.latestBroadcastId.toString() });
      return;
    }
    const events = await readOutboxAfter(this.pool, client.lastEventId, MAX_REPLAY + 1);
    if (events.length > MAX_REPLAY) {
      this.send(client, { schemaVersion: 1, type: 'resync_required', latestEventId: this.latestBroadcastId.toString() });
      return;
    }
    for (const event of events) {
      if (!this.send(client, event)) return;
      client.lastEventId = BigInt(event.id);
    }
  }

  private handleClientMessage(client: ClientState, raw: string) {
    if (raw.length > 2_048) {
      client.socket.close(1009, 'message_too_large');
      return;
    }
    try {
      const message = JSON.parse(raw) as Record<string, unknown>;
      if (message.type === 'ping') {
        this.send(client, { type: 'pong', at: Date.now() });
        return;
      }
      if (message.type !== 'subscribe' || message.channel !== 'markets') return;
      if (typeof message.after === 'string') {
        const after = parseReplayAfter(message.after);
        if (after === null) {
          client.socket.close(1008, 'invalid_after');
          return;
        }
        client.lastEventId = after;
        void this.replay(client);
      }
    } catch {
      client.socket.close(1007, 'invalid_json');
    }
  }

  private async flush() {
    if (this.flushing) return;
    this.flushing = true;
    try {
      while (true) {
        const events = await readOutboxAfter(this.pool, this.latestBroadcastId, MAX_REPLAY);
        if (events.length === 0) break;
        for (const event of events) {
          const id = BigInt(event.id);
          for (const client of this.clients) {
            if (id <= client.lastEventId) continue;
            if (this.send(client, event)) client.lastEventId = id;
          }
          this.latestBroadcastId = id;
        }
        if (events.length < MAX_REPLAY) break;
      }
    } finally {
      this.flushing = false;
    }
  }

  private send(client: ClientState, payload: unknown) {
    if (client.socket.readyState !== client.socket.OPEN) return false;
    if (client.socket.bufferedAmount > this.maxBufferedBytes) {
      client.socket.close(1013, 'slow_consumer');
      return false;
    }
    client.socket.send(JSON.stringify(payload));
    return true;
  }

  private heartbeatClients() {
    for (const client of this.clients) {
      if (!client.alive) {
        client.socket.terminate();
        this.clients.delete(client);
        continue;
      }
      client.alive = false;
      client.socket.ping();
    }
  }

  private async reconnectListener() {
    if (this.listener) {
      this.listener.release(true);
      this.listener = null;
    }
    try {
      this.listener = await this.pool.connect();
      this.listener.on('notification', () => void this.flush());
      this.listener.on('error', () => void this.reconnectListener());
      await this.listener.query('LISTEN quote_outbox');
      await this.flush();
    } catch {
      setTimeout(() => void this.reconnectListener(), 1_000);
    }
  }

  private isReplayTooOld(after: bigint) {
    return this.latestBroadcastId > after && this.latestBroadcastId - after > this.maxReplayLag;
  }
}

export function parseReplayAfter(raw: string | null): bigint | null {
  if (raw === null || raw === '') return 0n;
  if (!/^\d{1,19}$/.test(raw)) return null;
  const value = BigInt(raw);
  return value <= MAX_PG_BIGINT ? value : null;
}
