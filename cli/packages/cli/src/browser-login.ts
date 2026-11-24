import { createServer } from 'node:http';
import { randomBytes } from 'node:crypto';
import { spawn } from 'node:child_process';
import { hostname, platform } from 'node:os';

export interface BrowserLoginResult {
  apiKey: string;
  externalUserId: string;
  email?: string;
}

const SUCCESS_HTML = `<!doctype html>
<html><head><meta charset="utf-8"><title>Memorion CLI</title></head>
<body style="font-family: -apple-system, sans-serif; display: flex; align-items: center; justify-content: center; height: 100vh; margin: 0; background: #f0f4f8;">
<div style="text-align: center;">
<div style="font-size: 48px;">✅</div>
<h1 style="color: #0f172a;">Logged in to Memorion CLI</h1>
<p style="color: #64748b;">You can close this window and return to your terminal.</p>
</div></body></html>`;

const escapeHtml = (s: string) =>
  s.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);

const failureHtml = (message: string) => `<!doctype html>
<html><head><meta charset="utf-8"><title>Memorion CLI</title></head>
<body style="font-family: -apple-system, sans-serif; display: flex; align-items: center; justify-content: center; height: 100vh; margin: 0; background: #f0f4f8;">
<div style="text-align: center; max-width: 480px; padding: 0 24px;">
<div style="font-size: 48px;">❌</div>
<h1 style="color: #0f172a;">Login failed</h1>
<p style="color: #64748b;">${escapeHtml(message)}</p>
<p style="color: #94a3b8; font-size: 13px;">Return to your terminal and run <code>memorion login</code> to retry.</p>
</div></body></html>`;

function openBrowser(url: string): void {
  const cmd = platform() === 'darwin' ? 'open' : platform() === 'win32' ? 'start' : 'xdg-open';
  spawn(cmd, [url], { stdio: 'ignore', detached: true }).unref();
}

/**
 * Browser login flow (CLI_SPEC §3.1): start a temporary local HTTP server,
 * open the portal's /cli-auth page, and wait for it to redirect back with
 * credentials. The `state` nonce ties the callback to this invocation.
 */
export function browserLogin(
  authUrl: string,
  opts: {
    timeoutMs?: number;
    onUrl?: (url: string) => void;
    /** Runs BEFORE the browser gets its success page; throw to show a failure page instead. */
    validate?: (result: BrowserLoginResult) => Promise<void>;
  } = {},
): Promise<BrowserLoginResult> {
  const state = randomBytes(16).toString('hex');

  return new Promise((resolve, reject) => {
    const server = createServer(async (req, res) => {
      const url = new URL(req.url ?? '/', 'http://127.0.0.1');
      if (url.pathname !== '/callback') {
        res.writeHead(404).end();
        return;
      }
      if (url.searchParams.get('state') !== state) {
        res.writeHead(400, { 'Content-Type': 'text/plain' }).end('State mismatch — please retry `memorion login`.');
        return;
      }
      const apiKey = url.searchParams.get('api_key');
      const externalUserId = url.searchParams.get('external_user_id');
      if (!apiKey || !externalUserId) {
        res.writeHead(400, { 'Content-Type': 'text/plain' }).end('Missing credentials in callback.');
        return;
      }
      const result: BrowserLoginResult = {
        apiKey,
        externalUserId,
        email: url.searchParams.get('email') ?? undefined,
      };
      // Validate before telling the browser it succeeded, so the page and
      // the terminal never disagree about the outcome.
      if (opts.validate) {
        try {
          await opts.validate(result);
        } catch (err) {
          const message = err instanceof Error ? err.message : String(err);
          res.writeHead(200, { 'Content-Type': 'text/html' }).end(failureHtml(message));
          clearTimeout(timer);
          setTimeout(() => server.close(), 100);
          reject(err);
          return;
        }
      }
      res.writeHead(200, { 'Content-Type': 'text/html' }).end(SUCCESS_HTML);
      clearTimeout(timer);
      // Give the response a moment to flush before closing the server.
      setTimeout(() => server.close(), 100);
      resolve(result);
    });

    const timer = setTimeout(() => {
      server.close();
      reject(new Error('Login timed out after 5 minutes. Run `memorion login` to retry.'));
    }, opts.timeoutMs ?? 300_000);

    server.listen(0, '127.0.0.1', () => {
      const address = server.address();
      if (address === null || typeof address === 'string') {
        clearTimeout(timer);
        reject(new Error('Failed to start local callback server.'));
        return;
      }
      const page = new URL(authUrl);
      page.searchParams.set('port', String(address.port));
      page.searchParams.set('state', state);
      page.searchParams.set('device', `Memorion CLI (${hostname()})`);
      opts.onUrl?.(page.toString());
      openBrowser(page.toString());
    });

    server.on('error', (err) => {
      clearTimeout(timer);
      reject(err);
    });
  });
}
