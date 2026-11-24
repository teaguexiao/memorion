/**
 * Streamable HTTP transport tests.
 *
 * Run with `npm test -w @memorion/mcp` — requires `npm run build` first, since
 * these drive the built `dist/index.js` as a real subprocess rather than
 * importing the module. That is deliberate: the things worth testing here
 * (per-request credential isolation, DNS rebinding rejection) only exist once
 * the process is actually serving HTTP.
 *
 * ⚠️ **Why the isolation test matters.** On stdio one process serves one user,
 * so reading the API key from the environment is sound. Over HTTP that
 * assumption breaks, and a module-level "current credentials" variable would
 * silently hand concurrent callers each other's data — a cross-tenant leak that
 * passes every single-request test and every code review. This asserts the
 * AsyncLocalStorage scoping actually holds under concurrency.
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import http from 'node:http';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const PKG_DIR = join(dirname(fileURLToPath(import.meta.url)), '..');
const ENTRY = join(PKG_DIR, 'dist', 'index.js');

/** Fake Memorion API that echoes back the credentials it was called with. */
async function startFakeApi() {
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, 'http://x');
    const key = req.headers.authorization ?? '';
    const user = url.searchParams.get('external_user_id') ?? '';
    // Jitter so concurrent requests genuinely interleave; without this they can
    // complete in arrival order and a broken implementation still passes.
    setTimeout(() => {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify([{ id: 'c1', structured: { title: `${key}|${user}` } }]));
    }, 40 + Math.floor(Math.random() * 200));
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  return { server, port: server.address().port };
}

async function startMcp(port, env = {}) {
  const proc = spawn('node', [ENTRY, '--http', `--port=${port}`], {
    env: { ...process.env, ...env },
    stdio: ['ignore', 'ignore', 'pipe'],
  });
  // Wait for the listening banner rather than a fixed sleep.
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('MCP server did not start in time')), 15000);
    proc.stderr.on('data', (d) => {
      if (String(d).includes('Streamable HTTP')) {
        clearTimeout(timer);
        resolve();
      }
    });
    proc.once('exit', (code) => {
      clearTimeout(timer);
      reject(new Error(`MCP server exited early with code ${code}`));
    });
  });
  return proc;
}

function freePort() {
  // Ephemeral ports: the tests run concurrently with whatever else is on the box.
  return 20000 + Math.floor(Math.random() * 20000);
}

async function callTool(mcpPort, { name, args = {}, id = 1, headers = {} }) {
  const res = await fetch(`http://127.0.0.1:${mcpPort}/mcp`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Accept: 'application/json, text/event-stream',
      ...headers,
    },
    body: JSON.stringify({ jsonrpc: '2.0', id, method: 'tools/call', params: { name, arguments: args } }),
  });
  const text = await res.text();
  const line = text.split('\n').find((l) => l.startsWith('data:'));
  assert.ok(line, `expected an SSE data line, got: ${text.slice(0, 200)}`);
  return JSON.parse(line.slice(5).trim());
}

test('concurrent requests never see each other\'s credentials', async (t) => {
  const api = await startFakeApi();
  const mcpPort = freePort();
  const mcp = await startMcp(mcpPort, {
    // If any of these leak into a response, the scoping is broken.
    MEMORION_API_KEY: 'ENV_KEY_MUST_NOT_LEAK',
    MEMORION_USER_ID: 'ENV_USER_MUST_NOT_LEAK',
    MEMORION_BASE_URL: `http://127.0.0.1:${api.port}`,
  });
  t.after(() => {
    mcp.kill();
    api.server.close();
  });

  const N = 8;
  const results = await Promise.all(
    Array.from({ length: N }, async (_, i) => {
      const payload = await callTool(mcpPort, {
        name: 'list_recordings',
        id: i,
        headers: {
          Authorization: `key${i}`,
          'X-Memorion-User-Id': `user${i}`,
          'X-Memorion-Base-Url': 'http://127.0.0.1:0',
        },
      });
      const inner = JSON.parse(payload.result.content[0].text);
      const [sawKey, sawUser] = inner.items[0].title.split('|');
      return { i, sawKey, sawUser };
    }),
  );

  for (const r of results) {
    assert.equal(r.sawKey, `key${r.i}`, `request ${r.i} used the wrong API key`);
    assert.equal(r.sawUser, `user${r.i}`, `request ${r.i} used the wrong external_user_id`);
  }
});

test('HTTP requires both credential headers even with configured process credentials', async (t) => {
  const api = await startFakeApi();
  const mcpPort = freePort();
  const mcp = await startMcp(mcpPort, {
    MEMORION_API_KEY: 'envkey',
    MEMORION_USER_ID: 'envuser',
    MEMORION_BASE_URL: `http://127.0.0.1:${api.port}`,
  });
  t.after(() => {
    mcp.kill();
    api.server.close();
  });

  for (const headers of [
    {},
    { Authorization: 'request-key' },
    { 'X-Memorion-User-Id': 'request-user' },
  ]) {
    const response = await fetch(`http://127.0.0.1:${mcpPort}/mcp`, {
      method: 'POST',
      headers,
    });
    assert.equal(response.status, 401);
    assert.match((await response.json()).error, /headers are required/);
  }
});

test('DNS rebinding protection rejects foreign Host and Origin headers', async (t) => {
  const mcpPort = freePort();
  const mcp = await startMcp(mcpPort, { MEMORION_API_KEY: 'k', MEMORION_USER_ID: 'u' });
  t.after(() => mcp.kill());

  // Raw http.request, not fetch: undici silently drops a manually-set Host, so
  // a fetch-based version of this test would pass no matter what.
  const raw = (headers) =>
    new Promise((resolve) => {
      const body = JSON.stringify({
        jsonrpc: '2.0',
        id: 1,
        method: 'initialize',
        params: { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 't', version: '1' } },
      });
      const req = http.request(
        {
          host: '127.0.0.1',
          port: mcpPort,
          path: '/mcp',
          method: 'POST',
          setHost: false,
          headers: {
            'Content-Type': 'application/json',
            Accept: 'application/json, text/event-stream',
            'Content-Length': Buffer.byteLength(body),
            Authorization: 'request-key',
            'X-Memorion-User-Id': 'request-user',
            ...headers,
          },
        },
        (res) => {
          res.resume();
          res.on('end', () => resolve(res.statusCode));
        },
      );
      req.on('error', () => resolve(0));
      req.end(body);
    });

  assert.equal(await raw({ Host: `127.0.0.1:${mcpPort}` }), 200, 'loopback Host should be accepted');
  assert.equal(await raw({ Host: 'evil.example.com' }), 403, 'foreign Host should be rejected');
  // A browser page on another origin sends the *correct* Host, so the Origin
  // allowlist is what actually stops it.
  assert.equal(
    await raw({ Host: `127.0.0.1:${mcpPort}`, Origin: 'http://evil.example.com' }),
    403,
    'foreign Origin should be rejected',
  );
  assert.equal(
    await raw({ Host: `127.0.0.1:${mcpPort}`, Origin: `http://127.0.0.1:${mcpPort}` }),
    200,
    'own Origin should be accepted',
  );
});

test('non-MCP paths: /health responds, anything else 404s', async (t) => {
  const mcpPort = freePort();
  const mcp = await startMcp(mcpPort, { MEMORION_API_KEY: 'k', MEMORION_USER_ID: 'u' });
  t.after(() => mcp.kill());

  const health = await fetch(`http://127.0.0.1:${mcpPort}/health`);
  assert.equal(health.status, 200);
  assert.deepEqual(await health.json(), { status: 'ok' });

  const missing = await fetch(`http://127.0.0.1:${mcpPort}/nope`);
  assert.equal(missing.status, 404);
});

test('a second request on the same process still works', async (t) => {
  // Regression guard: an McpServer holds exactly one transport, so a singleton
  // server would throw "Already connected to a transport" on request #2.
  const api = await startFakeApi();
  const mcpPort = freePort();
  const mcp = await startMcp(mcpPort, {
    MEMORION_API_KEY: 'k',
    MEMORION_USER_ID: 'u',
    MEMORION_BASE_URL: `http://127.0.0.1:${api.port}`,
  });
  t.after(() => {
    mcp.kill();
    api.server.close();
  });

  for (const id of [1, 2, 3]) {
    const payload = await callTool(mcpPort, {
      name: 'list_recordings',
      id,
      headers: { Authorization: 'Bearer request-key', 'X-Memorion-User-Id': 'request-user' },
    });
    assert.ok(payload.result, `request ${id} failed: ${JSON.stringify(payload).slice(0, 200)}`);
  }
});
