import assert from 'node:assert/strict';
import test from 'node:test';

import { __resetRpcRateLimitForTests, POST } from './route.ts';

const originalFetch = globalThis.fetch;

function rpcRequest(body: unknown, headers?: Record<string, string>) {
  return new Request('http://quote.local/api/rpc', {
    body: typeof body === 'string' ? body : JSON.stringify(body),
    headers: { 'content-type': 'application/json', ...(headers ?? {}) },
    method: 'POST',
  });
}

test.afterEach(() => {
  globalThis.fetch = originalFetch;
  __resetRpcRateLimitForTests();
});

test('rejects eth_getLogs and malformed json-rpc bodies before upstream fetch', async () => {
  let called = false;
  globalThis.fetch = (async () => {
    called = true;
    return Response.json({ result: '0x1' });
  }) as typeof fetch;

  const logs = await POST(rpcRequest({ jsonrpc: '2.0', id: 1, method: 'eth_getLogs', params: [{}] }));
  const malformed = await POST(rpcRequest({ jsonrpc: '2.0', id: 2, method: 'eth_call', params: {} }));

  assert.equal(logs.status, 403);
  assert.equal(malformed.status, 403);
  assert.equal(called, false);
});

test('forwards strict read calls with the original bounded body', async () => {
  let upstreamBody = '';
  globalThis.fetch = (async (_url, init) => {
    upstreamBody = String(init?.body);
    return Response.json({ jsonrpc: '2.0', id: 1, result: '0x38' });
  }) as typeof fetch;

  const body = { jsonrpc: '2.0', id: 1, method: 'eth_chainId', params: [] };
  const response = await POST(rpcRequest(body));

  assert.equal(response.status, 200);
  assert.equal(upstreamBody, JSON.stringify(body));
});

test('enforces a bounded per-client rate limit', async () => {
  globalThis.fetch = (async () => Response.json({ result: '0x1' })) as typeof fetch;

  const batch = Array.from({ length: 20 }, (_, id) => ({ jsonrpc: '2.0', id, method: 'eth_chainId', params: [] }));

  for (let index = 0; index < 4; index += 1) {
    const ok = await POST(rpcRequest(batch, { 'x-forwarded-for': '203.0.113.8' }));
    assert.equal(ok.status, 200);
  }
  const limited = await POST(rpcRequest(batch, { 'x-forwarded-for': '203.0.113.8' }));
  assert.equal(limited.status, 429);
});
