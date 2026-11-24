// Stdio uses process credentials. HTTP scopes credentials to each request
// so concurrent callers use their own identity.
import { AsyncLocalStorage } from 'node:async_hooks';
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { randomUUID } from 'node:crypto';
import type { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
import { DEFAULT_BASE_URL, type ResolvedAuth } from '@memorion/core';

const authStore = new AsyncLocalStorage<ResolvedAuth>();

/** Credentials carried by the in-flight HTTP request, if any. */
export function requestAuth(): ResolvedAuth | undefined {
  return authStore.getStore();
}

function parseArgs(argv: string[]): { http: boolean; port: number; host: string } {
  const envTransport = (process.env.MEMORION_MCP_TRANSPORT ?? '').toLowerCase();
  let http = envTransport === 'http' || argv.includes('--http');
  if (argv.includes('--stdio')) http = false;

  const portArg = argv.find((a) => a.startsWith('--port='))?.slice('--port='.length);
  const port = Number.parseInt(portArg ?? process.env.MEMORION_MCP_PORT ?? '3579', 10);

  const hostArg = argv.find((a) => a.startsWith('--host='))?.slice('--host='.length);
  // Bind to loopback by default so credentials travel only over a local connection.
  const host = hostArg ?? process.env.MEMORION_MCP_HOST ?? '127.0.0.1';

  return { http, port: Number.isFinite(port) ? port : 3579, host };
}

function headerValue(req: IncomingMessage, name: string): string | undefined {
  const raw = req.headers[name.toLowerCase()];
  const value = Array.isArray(raw) ? raw[0] : raw;
  return value?.trim() || undefined;
}

function authFromRequest(req: IncomingMessage): ResolvedAuth | undefined {
  let apiKey = headerValue(req, 'authorization');
  // Tolerate clients that insist on a Bearer prefix even though the Memorion
  // REST API takes the raw key; strip it rather than sending it upstream.
  if (apiKey?.toLowerCase().startsWith('bearer ')) apiKey = apiKey.slice(7).trim();
  const userId = headerValue(req, 'x-memorion-user-id');
  if (!apiKey || !userId) return undefined;

  return { apiKey, userId, baseUrl: process.env.MEMORION_BASE_URL ?? DEFAULT_BASE_URL };
}

async function readBody(req: IncomingMessage): Promise<unknown> {
  const chunks: Buffer[] = [];
  for await (const chunk of req) chunks.push(chunk as Buffer);
  if (chunks.length === 0) return undefined;
  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf-8'));
  } catch {
    // Let the transport reject it — it emits a spec-shaped JSON-RPC error.
    return undefined;
  }
}

async function startHttp(
  createServerInstance: () => McpServer,
  port: number,
  host: string,
): Promise<void> {
  // Stateless: a fresh server + transport per request, no session state kept.
  // A fresh *server* too, not just a transport — an McpServer holds exactly one
  // transport (Protocol.connect throws on the second), so reusing a singleton
  // here would fail on request #2.
  //
  // Stateless is the right default because every request carries its own
  // credentials: there is nothing user-specific worth pinning to a session, and
  // the process can be restarted or replicated without stranding clients.
  const httpServer = createServer((req: IncomingMessage, res: ServerResponse) => {
    void (async () => {
      const url = new URL(req.url ?? '/', `http://${req.headers.host ?? 'localhost'}`);
      if (url.pathname === '/health') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ status: 'ok' }));
        return;
      }
      if (url.pathname !== '/mcp') {
        res.writeHead(404, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'Not found. The MCP endpoint is /mcp.' }));
        return;
      }

      const auth = authFromRequest(req);
      if (!auth) {
        res.writeHead(401, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'Authorization and X-Memorion-User-Id headers are required.' }));
        return;
      }

      const body = req.method === 'POST' ? await readBody(req) : undefined;
      const transport = new StreamableHTTPServerTransport({
        sessionIdGenerator: undefined,
        // DNS rebinding protection: without it a page in the user's browser
        // could POST to this loopback port and read their recordings.
        //
        // The Host allowlist alone is not enough for the browser case — a page
        // on evil.example.com fetching http://127.0.0.1:PORT sends the *correct*
        // Host. The Origin allowlist is what stops that, and it only kicks in
        // when an Origin header is present, so ordinary (non-browser) MCP
        // clients, which send none, are unaffected.
        enableDnsRebindingProtection: true,
        allowedHosts: [`${host}:${port}`, `127.0.0.1:${port}`, `localhost:${port}`],
        allowedOrigins: [
          `http://${host}:${port}`,
          `http://127.0.0.1:${port}`,
          `http://localhost:${port}`,
        ],
      });
      const mcpServer = createServerInstance();
      res.on('close', () => {
        void transport.close();
        void mcpServer.close();
      });

      try {
        await mcpServer.connect(transport);
        await authStore.run(auth, () => transport.handleRequest(req, res, body));
      } catch (err) {
        process.stderr.write(`[memorion-mcp] request failed: ${err}\n`);
        if (!res.headersSent) {
          res.writeHead(500, { 'Content-Type': 'application/json' });
          res.end(
            JSON.stringify({
              jsonrpc: '2.0',
              error: { code: -32603, message: 'Internal server error' },
              id: null,
            }),
          );
        }
      }
    })();
  });

  await new Promise<void>((resolve) => httpServer.listen(port, host, resolve));
  process.stderr.write(
    `Memorion MCP server running on http://${host}:${port}/mcp (Streamable HTTP, stateless)\n`,
  );
}

/**
 * Connects on whichever transport the invocation asked for.
 *
 * Takes a factory, not an instance: HTTP mode builds one server per request.
 */
export async function startServer(createServerInstance: () => McpServer): Promise<void> {
  const { http, port, host } = parseArgs(process.argv.slice(2));
  if (http) {
    await startHttp(createServerInstance, port, host);
    return;
  }
  await createServerInstance().connect(new StdioServerTransport());
  process.stderr.write('Memorion MCP server running on stdio\n');
}
