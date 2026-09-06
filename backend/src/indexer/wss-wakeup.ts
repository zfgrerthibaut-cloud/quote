import WebSocket from 'ws';

import type { Address, Hex } from './types.ts';

type SocketLike = Pick<WebSocket, 'on' | 'send' | 'close'>;
type SocketFactory = (url: string) => SocketLike;

export type WakeReason = Readonly<{
  kind: 'head' | 'log';
  blockNumber: bigint | null;
}>;

export class WssWakeSource {
  private socket: SocketLike | null = null;
  private reconnectTimer: NodeJS.Timeout | null = null;
  private generation = 0;
  private attempt = 0;
  private stopped = true;
  private nextId = 1;
  private chainRequestId: number | null = null;
  private readonly url: string;
  private readonly addresses: readonly Address[];
  private readonly topic0: readonly Hex[];
  private readonly onWake: (reason: WakeReason) => void;
  private readonly socketFactory: SocketFactory;
  private readonly reconnectBaseMs: number;

  constructor(
    url: string,
    addresses: readonly Address[],
    topic0: readonly Hex[],
    onWake: (reason: WakeReason) => void,
    socketFactory: SocketFactory = (target) => new WebSocket(target, {
      perMessageDeflate: false,
      handshakeTimeout: 10_000,
      maxPayload: 1_048_576,
    }),
    reconnectBaseMs = 1_000,
  ) {
    const parsed = new URL(url);
    if (parsed.protocol !== 'wss:' && parsed.protocol !== 'ws:') throw new Error('BSC_WSS_RPC_URL_invalid');
    if (addresses.length === 0 || topic0.length === 0) throw new Error('wss_registry_filter_empty');
    this.url = url;
    this.addresses = addresses;
    this.topic0 = topic0;
    this.onWake = onWake;
    this.socketFactory = socketFactory;
    this.reconnectBaseMs = reconnectBaseMs;
  }

  start() {
    if (!this.stopped) return;
    this.stopped = false;
    this.connect();
  }

  stop() {
    this.stopped = true;
    this.generation += 1;
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.reconnectTimer = null;
    const socket = this.socket;
    this.socket = null;
    socket?.close();
  }

  private connect() {
    if (this.stopped) return;
    const generation = ++this.generation;
    let disconnected = false;
    const disconnect = () => {
      if (disconnected || generation !== this.generation) return;
      disconnected = true;
      this.socket = null;
      this.scheduleReconnect();
    };

    let socket: SocketLike;
    try {
      socket = this.socketFactory(this.url);
    } catch {
      disconnect();
      return;
    }
    this.socket = socket;
    socket.on('open', () => {
      if (generation !== this.generation || this.stopped) return;
      this.chainRequestId = this.nextId++;
      socket.send(JSON.stringify({ jsonrpc: '2.0', id: this.chainRequestId, method: 'eth_chainId', params: [] }));
    });
    socket.on('message', (data) => {
      if (generation !== this.generation || this.stopped) return;
      this.handleMessage(socket, String(data));
    });
    socket.on('error', () => socket.close());
    socket.on('close', disconnect);
  }

  private handleMessage(socket: SocketLike, raw: string) {
    let message: Record<string, unknown>;
    try {
      const parsed = JSON.parse(raw) as unknown;
      if (!isRecord(parsed)) return;
      message = parsed;
    } catch {
      return;
    }

    if (message.id === this.chainRequestId) {
      if (message.result !== '0x38') {
        socket.close();
        return;
      }
      this.attempt = 0;
      this.chainRequestId = null;
      socket.send(JSON.stringify({
        jsonrpc: '2.0',
        id: this.nextId++,
        method: 'eth_subscribe',
        params: ['newHeads'],
      }));
      socket.send(JSON.stringify({
        jsonrpc: '2.0',
        id: this.nextId++,
        method: 'eth_subscribe',
        params: ['logs', { address: [...this.addresses], topics: [[...this.topic0]] }],
      }));
      this.onWake({ kind: 'head', blockNumber: null });
      return;
    }

    if (message.method !== 'eth_subscription' || !isRecord(message.params)) return;
    const result = message.params.result;
    if (!isRecord(result)) return;
    if (typeof result.number === 'string') {
      this.onWake({ kind: 'head', blockNumber: parseOptionalQuantity(result.number) });
    } else if (typeof result.blockNumber === 'string') {
      this.onWake({ kind: 'log', blockNumber: parseOptionalQuantity(result.blockNumber) });
    }
  }

  private scheduleReconnect() {
    if (this.stopped || this.reconnectTimer) return;
    const delay = Math.min(60_000, this.reconnectBaseMs * (2 ** Math.min(this.attempt, 6)));
    this.attempt += 1;
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this.connect();
    }, delay);
  }
}

function parseOptionalQuantity(value: string) {
  return /^0x(?:0|[1-9a-fA-F][0-9a-fA-F]*)$/.test(value) ? BigInt(value) : null;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}
