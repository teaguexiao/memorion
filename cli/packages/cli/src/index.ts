#!/usr/bin/env node
import { Command } from 'commander';
import { createInterface } from 'node:readline/promises';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { createWriteStream } from 'node:fs';
import {
  MemorionClient,
  resolveAuth,
  requireUserId,
  saveCredentials,
  deleteCredentials,
  loadConfig,
  saveConfig,
  parseTimeArg,
  DEFAULT_BASE_URL,
} from '@memorion/core';
import type { Conversation, ResolvedAuth } from '@memorion/core';
import { ApiError } from '@memorion/core';
import {
  EXIT,
  fail,
  printResult,
  formatConversationRow,
  formatDuration,
  formatTimestamp,
  speakerLabel,
} from './output.js';
import { browserLogin } from './browser-login.js';

const program = new Command();

program
  .name('memorion')
  .description('Memorion CLI — access recordings, transcripts, summaries and audio')
  .version('0.1.0')
  .option('--json', 'machine-readable JSON output')
  .option('--user <id>', 'external_user_id (overrides env/config)')
  .option('--api-key <key>', 'API key (overrides env/config)')
  .option('--base-url <url>', 'API base URL')
  .option('-q, --quiet', 'suppress progress output');

interface GlobalOpts {
  json?: boolean;
  user?: string;
  apiKey?: string;
  baseUrl?: string;
  quiet?: boolean;
}

function globalOpts(): GlobalOpts {
  return program.opts<GlobalOpts>();
}

function getClient(): { client: MemorionClient; auth: ResolvedAuth } {
  const opts = globalOpts();
  const auth = resolveAuth({ apiKey: opts.apiKey, user: opts.user, baseUrl: opts.baseUrl });
  return { client: new MemorionClient(auth), auth };
}

function note(msg: string): void {
  if (!globalOpts().quiet) process.stderr.write(msg + '\n');
}

// --- Auth commands ---

program
  .command('login')
  .description('log in with an API key or a configured browser consent page, and save credentials')
  .option('--with-key', 'prompt for an API key instead of opening the browser')
  .option('--auth-url <url>', 'browser consent page URL (or set MEMORION_AUTH_URL)')
  .action(async (cmdOpts: { withKey?: boolean; authUrl?: string }) => {
    const opts = globalOpts();
    try {
      let apiKey = opts.apiKey ?? process.env.MEMORION_API_KEY;
      let userId = opts.user;
      const authUrl = cmdOpts.withKey ? undefined : cmdOpts.authUrl ?? process.env.MEMORION_AUTH_URL;

      let email: string | undefined;
      if (!apiKey && authUrl) {
        note('Opening your browser to log in ...');
        const result = await browserLogin(authUrl, {
          onUrl: (url) => note(`If the browser did not open, visit:\n  ${url}`),
          // Validate the key before the browser shows success, so the page
          // and the terminal never disagree about the outcome.
          validate: async (r) => {
            const a = resolveAuth({ apiKey: r.apiKey, user: userId ?? r.externalUserId, baseUrl: opts.baseUrl });
            await new MemorionClient(a).validateKey(a.userId!);
          },
        });
        apiKey = result.apiKey;
        userId = userId ?? result.externalUserId;
        email = result.email;
      } else {
        if (!apiKey) {
          if (!process.stdin.isTTY) {
            fail(new Error('Set MEMORION_API_KEY or --api-key for non-interactive login.'), opts);
          }
          const rl = createInterface({ input: process.stdin, output: process.stderr });
          apiKey = (await rl.question('API key (memorion_dev_...): ')).trim();
          rl.close();
          if (!apiKey) fail(new Error('No API key provided.'), opts);
        }

        const a = resolveAuth({ apiKey, user: userId, baseUrl: opts.baseUrl });
        const client = new MemorionClient(a);
        // Bound CLI keys are rejected (403) on developer-scoped endpoints
        // like /developers/me, so prefer a user-scoped check when possible.
        if (a.userId) {
          await client.validateKey(a.userId);
        } else {
          await client.getMe();
        }
      }
      saveCredentials(apiKey);
      if (userId || email) {
        saveConfig({
          ...loadConfig(),
          ...(userId ? { default_user_id: userId } : {}),
          ...(email ? { email } : {}),
        });
      }
      printResult({ email, external_user_id: userId }, opts, () =>
        `Logged in${email ? ` as ${email}` : ''}. Credentials saved.`,
      );
    } catch (err) {
      fail(err, opts);
    }
  });

program
  .command('logout')
  .description('delete saved credentials')
  .action(() => {
    const removed = deleteCredentials();
    printResult({ logged_out: removed }, globalOpts(), () =>
      removed ? 'Credentials deleted.' : 'No saved credentials found.',
    );
  });

program
  .command('whoami')
  .description('show current developer account')
  .action(async () => {
    const opts = globalOpts();
    try {
      const { client, auth } = getClient();
      try {
        const me = await client.getMe();
        printResult(me, opts, (m) =>
          [
            `id:      ${m.id}`,
            `email:   ${m.email ?? '-'}`,
            `name:    ${m.name ?? '-'}`,
            `tier:    ${m.tier}`,
            `credits: ${m.credits_balance ?? '-'}`,
          ].join('\n'),
        );
      } catch (err) {
        // Bound CLI keys can't read /developers/me (403) — validate the key
        // against the user's own data and report from local config instead.
        if (err instanceof ApiError && err.status === 403 && auth.userId) {
          await client.validateKey(auth.userId);
          const config = loadConfig();
          const info = { email: config.email, external_user_id: auth.userId, key_type: 'user-bound' };
          printResult(info, opts, () =>
            [
              `email:   ${config.email ?? '-'}`,
              `user:    ${auth.userId}`,
              `key:     user-bound CLI key`,
            ].join('\n'),
          );
          return;
        }
        throw err;
      }
    } catch (err) {
      fail(err, opts);
    }
  });

// --- Listing commands ---

interface ListOpts {
  from?: string;
  to?: string;
  query?: string;
  category?: string;
  limit: string;
  offset: string;
  page: string;
}

async function runList(cmdOpts: ListOpts): Promise<void> {
  const opts = globalOpts();
  try {
    const { client, auth } = getClient();
    const userId = requireUserId(auth);
    const startDate = cmdOpts.from ? parseTimeArg(cmdOpts.from) : undefined;
    const endDate = cmdOpts.to ? parseTimeArg(cmdOpts.to) : undefined;
    const limit = parseInt(cmdOpts.limit, 10);

    let items: Conversation[];
    if (cmdOpts.query) {
      const res = await client.searchConversations(userId, cmdOpts.query, {
        page: parseInt(cmdOpts.page, 10),
        perPage: limit,
        startDate,
        endDate,
      });
      items = res.items;
    } else {
      items = await client.listConversations(userId, {
        limit,
        offset: parseInt(cmdOpts.offset, 10),
        startDate,
        endDate,
        categories: cmdOpts.category,
      });
    }
    printResult(items, opts, (list: Conversation[]) =>
      list.length === 0 ? '(no recordings found)' : list.map(formatConversationRow).join('\n'),
    );
  } catch (err) {
    fail(err, opts);
  }
}

function addListOptions(cmd: Command): Command {
  return cmd
    .option('--from <time>', 'start time (ISO 8601, "today", "yesterday", "7d")')
    .option('--to <time>', 'end time')
    .option('--query <text>', 'semantic search — describe what to find, in any wording')
    .option('--category <c>', 'comma-separated categories')
    .option('--limit <n>', 'max results', '20')
    .option('--offset <n>', 'skip N results', '0')
    .option('--page <n>', 'page (search mode)', '1');
}

addListOptions(program.command('list').description('list/search recordings')).action(runList);

program
  .command('recent')
  .description('recordings from the last 7 days (alias of list --from 7d)')
  .action(() => runList({ from: '7d', limit: '20', offset: '0', page: '1' }));

program
  .command('today')
  .description("today's recordings (alias of list --from today)")
  .action(() => runList({ from: 'today', limit: '20', offset: '0', page: '1' }));

// --- Single-recording commands ---

program
  .command('get <id>')
  .description('recording details: metadata, summary, audio availability')
  .action(async (id: string) => {
    const opts = globalOpts();
    try {
      const { client, auth } = getClient();
      const userId = requireUserId(auth);
      const [conv, rec] = await Promise.all([
        client.getConversation(userId, id),
        client.hasRecording(userId, id).catch(() => ({ has_recording: false })),
      ]);
      const data = { ...conv, has_audio: rec.has_recording };
      printResult(data, opts, (c) =>
        [
          `id:        ${c.id}`,
          `title:     ${c.structured?.emoji ?? ''} ${c.structured?.title ?? '(untitled)'}`.trim(),
          `started:   ${c.started_at ?? '-'}`,
          `duration:  ${formatDuration(c)}`,
          `category:  ${c.structured?.category ?? '-'}`,
          `status:    ${c.status ?? '-'}`,
          `audio:     ${c.has_audio ? 'yes' : 'no'}`,
          `segments:  ${c.transcript_segments?.length ?? 0}`,
          `actions:   ${c.structured?.action_items?.length ?? 0}`,
          '',
          c.structured?.overview ?? '(no overview)',
        ].join('\n'),
      );
    } catch (err) {
      fail(err, opts);
    }
  });

program
  .command('transcript <id>')
  .description('full transcript with speaker labels')
  .option('--timestamps', 'prefix each segment with [mm:ss]')
  .option('--raw', 'plain text only, no labels (cheapest for LLMs)')
  .action(async (id: string, cmdOpts: { timestamps?: boolean; raw?: boolean }) => {
    const opts = globalOpts();
    try {
      const { client, auth } = getClient();
      const userId = requireUserId(auth);
      const conv = await client.getConversation(userId, id);
      const segs = conv.transcript_segments ?? [];
      printResult(segs, opts, () => {
        if (segs.length === 0) return '(no transcript)';
        if (cmdOpts.raw) return segs.map((s) => s.text.trim()).join('\n');
        return segs
          .map((s) => {
            const ts = cmdOpts.timestamps ? formatTimestamp(s.start) + ' ' : '';
            return `${ts}${speakerLabel(s)}: ${s.text.trim()}`;
          })
          .join('\n');
      });
    } catch (err) {
      fail(err, opts);
    }
  });

program
  .command('summary <id>')
  .description('AI summary: title, overview, action items')
  .action(async (id: string) => {
    const opts = globalOpts();
    try {
      const { client, auth } = getClient();
      const userId = requireUserId(auth);
      const conv = await client.getConversation(userId, id);
      const s = conv.structured ?? {};
      printResult(s, opts, () => {
        const lines = [
          `${s.emoji ?? ''} ${s.title ?? '(untitled)'}`.trim(),
          `category: ${s.category ?? '-'}`,
          '',
          s.overview ?? '(no overview)',
        ];
        const items = s.action_items ?? [];
        if (items.length > 0) {
          lines.push('', 'Action items:');
          for (const item of items) {
            const desc = typeof item === 'string' ? item : (item.description ?? JSON.stringify(item));
            lines.push(`  - ${desc}`);
          }
        }
        return lines.join('\n');
      });
    } catch (err) {
      fail(err, opts);
    }
  });

program
  .command('audio <id>')
  .description('download recording audio (signed URL expires in 15 min)')
  .option('-o, --output <path>', 'output file path (default: <id>.wav)')
  .option('--url-only', 'print the signed URL instead of downloading')
  .action(async (id: string, cmdOpts: { output?: string; urlOnly?: boolean }) => {
    const opts = globalOpts();
    try {
      const { client, auth } = getClient();
      const userId = requireUserId(auth);
      const { audio_url } = await client.getAudioUrl(userId, id);
      if (!audio_url) {
        printResult({ audio_url: null }, opts, () => '');
        process.stderr.write('Error: no audio recording for this conversation\n');
        process.exit(EXIT.NOT_FOUND);
      }
      if (cmdOpts.urlOnly) {
        printResult({ audio_url, expires_in_seconds: 900 }, opts, () => audio_url);
        return;
      }
      const outPath = cmdOpts.output ?? `${id}.wav`;
      note(`Downloading audio to ${outPath} ...`);
      const res = await fetch(audio_url);
      if (!res.ok || !res.body) {
        fail(new Error(`Audio download failed with status ${res.status}`), opts);
      }
      await pipeline(Readable.fromWeb(res.body as any), createWriteStream(outPath));
      printResult({ path: outPath }, opts, () => `Saved: ${outPath}`);
    } catch (err) {
      fail(err, opts);
    }
  });

// --- Config commands ---

const configCmd = program.command('config').description('manage local configuration');

const CONFIG_KEYS: Record<string, 'default_user_id' | 'base_url'> = {
  user: 'default_user_id',
  'base-url': 'base_url',
};

configCmd
  .command('set <key> <value>')
  .description('set a config value (keys: user, base-url)')
  .action((key: string, value: string) => {
    const opts = globalOpts();
    const field = CONFIG_KEYS[key];
    if (!field) {
      fail(new Error(`Unknown config key "${key}". Valid keys: ${Object.keys(CONFIG_KEYS).join(', ')}`), opts);
    }
    saveConfig({ ...loadConfig(), [field]: value });
    printResult({ [field]: value }, opts, () => `Set ${key} = ${value}`);
  });

configCmd
  .command('get <key>')
  .description('read a config value')
  .action((key: string) => {
    const opts = globalOpts();
    const field = CONFIG_KEYS[key];
    if (!field) {
      fail(new Error(`Unknown config key "${key}". Valid keys: ${Object.keys(CONFIG_KEYS).join(', ')}`), opts);
    }
    const value = loadConfig()[field];
    printResult({ [field]: value ?? null }, opts, () => value ?? '(not set)');
  });

configCmd
  .command('list')
  .description('show all config values')
  .action(() => {
    const config = loadConfig();
    printResult(config, globalOpts(), (c) =>
      [
        `user (default_user_id): ${c.default_user_id ?? '(not set)'}`,
        `base-url:               ${c.base_url ?? `(default: ${DEFAULT_BASE_URL})`}`,
      ].join('\n'),
    );
  });

program.parseAsync().catch((err) => fail(err, program.opts()));
