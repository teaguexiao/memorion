#!/usr/bin/env node
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { z } from 'zod';
import { MemorionClient, resolveAuth, requireUserId, AuthError, ApiError } from '@memorion/core';
import type { Conversation, ResolvedAuth, TranscriptSegment } from '@memorion/core';
import { requestAuth, startServer } from './transport.js';

const SETUP_HINT =
  'Set MEMORION_API_KEY and MEMORION_USER_ID in your MCP client config (env), or run `memorion login` from the Memorion CLI first.';

function getClient(): { client: MemorionClient; userId: string } {
  // HTTP dispatch always supplies request credentials. Stdio uses local config.
  let auth: ResolvedAuth | undefined = requestAuth();
  if (!auth) {
    try {
      auth = resolveAuth({});
    } catch (err) {
      throw new Error(`${err instanceof Error ? err.message : err} ${SETUP_HINT}`);
    }
  }
  if (!auth.userId) {
    throw new Error(`No external_user_id configured. ${SETUP_HINT}`);
  }
  return { client: new MemorionClient(auth), userId: auth.userId };
}

type ToolResult = { content: Array<{ type: 'text'; text: string }>; isError?: boolean };

function ok(data: unknown): ToolResult {
  return { content: [{ type: 'text', text: JSON.stringify(data, null, 2) }] };
}

function errResult(err: unknown): ToolResult {
  let message = err instanceof Error ? err.message : String(err);
  if (err instanceof ApiError && (err.status === 401 || err.status === 403)) {
    message = `Authentication failed (${err.status}): ${message}. ${SETUP_HINT}`;
  } else if (err instanceof AuthError) {
    message = `${message} ${SETUP_HINT}`;
  }
  return { content: [{ type: 'text', text: `Error: ${message}` }], isError: true };
}

async function run(fn: () => Promise<ToolResult>): Promise<ToolResult> {
  try {
    return await fn();
  } catch (err) {
    return errResult(err);
  }
}

// --- Shared formatting ---

function durationSeconds(c: Conversation): number | null {
  if (!c.started_at || !c.finished_at) return null;
  const secs = Math.round((new Date(c.finished_at).getTime() - new Date(c.started_at).getTime()) / 1000);
  return secs >= 0 ? secs : null;
}

function recordingListItem(c: Conversation) {
  return {
    id: c.id,
    title: c.structured?.title || '(untitled)',
    overview: c.structured?.overview || '',
    emoji: c.structured?.emoji,
    category: c.structured?.category,
    started_at: c.started_at,
    finished_at: c.finished_at,
    duration_seconds: durationSeconds(c),
    status: c.status,
  };
}

function speakerLabel(seg: TranscriptSegment): string {
  if (seg.is_user) return 'You';
  const id = seg.speaker_id ?? 0;
  if (typeof id === 'string') {
    const m = id.match(/^speaker[_\s]?(\d+)$/i);
    return m ? `Speaker ${parseInt(m[1], 10)}` : id;
  }
  return `Speaker ${id}`;
}

/** Merge consecutive same-speaker segments into readable plain text. */
function plainTranscript(segs: TranscriptSegment[]): string {
  const lines: string[] = [];
  let lastSpeaker = '';
  for (const seg of segs) {
    const speaker = speakerLabel(seg);
    const text = seg.text.trim();
    if (!text) continue;
    if (speaker === lastSpeaker && lines.length > 0) {
      lines[lines.length - 1] += ' ' + text;
    } else {
      lines.push(`${speaker}: ${text}`);
      lastSpeaker = speaker;
    }
  }
  return lines.join('\n');
}

// --- Server & tools (MCP_SPEC §4) ---

/**
 * Builds a fully-registered server instance.
 *
 * A factory rather than a singleton because the HTTP transport is stateless:
 * an McpServer can only hold one transport at a time (Protocol.connect throws on
 * the second), so each HTTP request needs its own server + transport pair.
 */
export function createMemorionServer(): McpServer {
  const server = new McpServer({ name: 'memorion', version: '0.1.0' });

  server.registerTool(
    'get_current_user',
    {
      title: 'Get current user',
      description:
        'Get the authenticated Memorion developer account (id, email, tier, credits). Use this to verify the connection is working.',
      annotations: { readOnlyHint: true },
    },
    async () =>
      run(async () => {
        const { client, userId } = getClient();
        try {
          const me = await client.getMe();
          return ok({ id: me.id, email: me.email, name: me.name, tier: me.tier, credits_balance: me.credits_balance });
        } catch (err) {
          // User-bound CLI keys get 403 on developer-scoped endpoints; verify
          // against the user's own data instead.
          if (err instanceof ApiError && err.status === 403) {
            await client.validateKey(userId);
            return ok({ external_user_id: userId, key_type: 'user-bound', status: 'connected' });
          }
          throw err;
        }
      }),
  );

  server.registerTool(
    'list_recordings',
    {
      title: 'List recordings',
      description:
        'List or search the user\'s Memorion recordings (conversations captured by their wearable device). ' +
        'This is the main entry point — call it first to find recording ids, then use get_transcript / get_summary / get_audio_url for details. ' +
        'Returns metadata and short summaries only, never full transcripts. ' +
        'Provide `query` to search by meaning — describe what you are looking for in natural language; ' +
        'it does not have to reuse the user\'s exact words. Omit `query` to list by time.',
      annotations: { readOnlyHint: true },
      inputSchema: {
        query: z
          .string()
          .optional()
          .describe('Semantic search over recordings — a natural-language description of what to find. Omit to list all.'),
        date_from: z.string().optional().describe('ISO 8601 start time filter, e.g. "2026-07-01T00:00:00Z"'),
        date_to: z.string().optional().describe('ISO 8601 end time filter'),
        category: z.string().optional().describe('Comma-separated category filter (list mode only)'),
        page: z.number().int().min(1).optional().describe('Page number, default 1'),
        page_size: z.number().int().min(1).max(100).optional().describe('Results per page, default 20, max 100'),
      },
    },
    async (args) =>
      run(async () => {
        const { client, userId } = getClient();
        const page = args.page ?? 1;
        const pageSize = args.page_size ?? 20;
        let items: Conversation[];
        if (args.query) {
          const res = await client.searchConversations(userId, args.query, {
            page,
            perPage: pageSize,
            startDate: args.date_from,
            endDate: args.date_to,
          });
          items = res.items;
        } else {
          items = await client.listConversations(userId, {
            limit: pageSize,
            offset: (page - 1) * pageSize,
            startDate: args.date_from,
            endDate: args.date_to,
            categories: args.category,
          });
        }
        return ok({
          items: items.map(recordingListItem),
          page,
          page_size: pageSize,
          has_more: items.length === pageSize,
        });
      }),
  );

  server.registerTool(
    'get_recording',
    {
      title: 'Get recording details',
      description:
        'Get full metadata and the structured AI summary of one recording, plus whether it has downloadable audio. ' +
        'Does NOT include the transcript text — use get_transcript for that.',
      annotations: { readOnlyHint: true },
      inputSchema: {
        recording_id: z.string().describe('Recording id from list_recordings'),
      },
    },
    async (args) =>
      run(async () => {
        const { client, userId } = getClient();
        const [conv, rec] = await Promise.all([
          client.getConversation(userId, args.recording_id),
          client.hasRecording(userId, args.recording_id).catch(() => ({ has_recording: false })),
        ]);
        return ok({
          ...recordingListItem(conv),
          language: conv.language,
          source: conv.source,
          segment_count: conv.transcript_segments?.length ?? 0,
          action_items: conv.structured?.action_items ?? [],
          has_audio: rec.has_recording,
        });
      }),
  );

  server.registerTool(
    'get_transcript',
    {
      title: 'Get transcript',
      description:
        'Get the full transcript of a recording with speaker labels. ' +
        'Default format "plain" merges consecutive segments per speaker into readable text (cheapest). ' +
        'Use format "segments" only when you need per-segment timestamps.',
      annotations: { readOnlyHint: true },
      inputSchema: {
        recording_id: z.string().describe('Recording id from list_recordings'),
        format: z.enum(['plain', 'segments']).optional().describe('Output format, default "plain"'),
      },
    },
    async (args) =>
      run(async () => {
        const { client, userId } = getClient();
        const conv = await client.getConversation(userId, args.recording_id);
        const segs = conv.transcript_segments ?? [];
        if (segs.length === 0) return ok({ transcript: '', note: 'This recording has no transcript.' });
        if (args.format === 'segments') {
          return ok(
            segs.map((s) => ({
              text: s.text.trim(),
              speaker: speakerLabel(s),
              start: s.start,
              end: s.end,
              is_user: s.is_user ?? false,
            })),
          );
        }
        return ok({ transcript: plainTranscript(segs) });
      }),
  );

  server.registerTool(
    'get_summary',
    {
      title: 'Get AI summary',
      description:
        'Get the AI-generated summary of a recording: title, overview, category and action items. ' +
        'Prefer this over get_transcript when the user asks "what was discussed" — it is much shorter.',
      annotations: { readOnlyHint: true },
      inputSchema: {
        recording_id: z.string().describe('Recording id from list_recordings'),
      },
    },
    async (args) =>
      run(async () => {
        const { client, userId } = getClient();
        const conv = await client.getConversation(userId, args.recording_id);
        const s = conv.structured ?? {};
        return ok({
          title: s.title || '(untitled)',
          overview: s.overview || '',
          emoji: s.emoji,
          category: s.category,
          action_items: s.action_items ?? [],
        });
      }),
  );

  server.registerTool(
    'get_audio_url',
    {
      title: 'Get audio download URL',
      description:
        'Get a temporary signed URL to download the raw audio (WAV) of a recording. ' +
        'IMPORTANT: the URL expires after 15 minutes — if the audio needs to be kept, download it immediately. ' +
        'Returns audio_url: null when the recording has no stored audio.',
      annotations: { readOnlyHint: true },
      inputSchema: {
        recording_id: z.string().describe('Recording id from list_recordings'),
      },
    },
    async (args) =>
      run(async () => {
        const { client, userId } = getClient();
        const { audio_url } = await client.getAudioUrl(userId, args.recording_id);
        if (!audio_url) {
          return ok({ audio_url: null, note: 'No audio recording stored for this recording.' });
        }
        return ok({ audio_url, expires_in_seconds: 900 });
      }),
  );

  server.registerTool(
    'search_memories',
    {
      title: 'Search memories',
      description:
        'Keyword search over the user\'s long-term memories — facts and preferences distilled from their recordings ' +
        '(e.g. "user prefers morning meetings"). Use this for questions about the user themselves rather than a specific recording. ' +
        'Matching is literal substring, NOT semantic: pass a word you expect to appear in the memory itself, and retry with ' +
        'synonyms if the first attempt is empty. For meaning-based search over what the user actually said, use list_recordings.',
      annotations: { readOnlyHint: true },
      inputSchema: {
        query: z.string().describe('Substring to look for in the memory text (case-insensitive)'),
        limit: z.number().int().min(1).max(50).optional().describe('Max results, default 10'),
      },
    },
    async (args) =>
      run(async () => {
        const { client, userId } = getClient();
        const memories = await client.searchMemories(userId, args.query, args.limit ?? 10);
        return ok({
          items: memories.map((m) => ({
            id: m.id,
            content: m.content,
            category: m.category,
            tags: m.tags,
            created_at: m.created_at,
          })),
        });
      }),
  );

  server.registerTool(
    'resolve_time_range',
    {
      title: 'Resolve a relative time expression',
      description:
        'Convert a relative time expression ("last Wednesday", "this month", "过去三天") into an absolute ISO-8601 range ' +
        'in the user\'s own timezone, then pass start/end into list_recordings as date_from/date_to. ' +
        'Always use this instead of computing dates yourself: the machine running this server is not necessarily in the ' +
        'user\'s timezone, and the resolved range is the same one the Memorion app\'s assistant uses. ' +
        'Returns start: null, end: null when the expression contains no resolvable date — that is a normal answer, not an error.',
      annotations: { readOnlyHint: true },
      inputSchema: {
        expr: z.string().describe('The relative time expression, in the user\'s own words'),
      },
    },
    async (args) =>
      run(async () => {
        const { client, userId } = getClient();
        const range = await client.resolveTimeRange(userId, args.expr);
        if (!range.start || !range.end) {
          return ok({
            ...range,
            note: 'No date range could be resolved from this expression. Do not invent one — ask the user, or list by recency.',
          });
        }
        return ok(range);
      }),
  );

  server.registerTool(
    'list_todos',
    {
      title: 'List to-dos',
      description:
        'List the user\'s to-do items, extracted by AI from their recordings. Each item carries the recording it came from, ' +
        'so you can tell the user where a to-do originated. ' +
        'Items still awaiting the user\'s confirmation in the app are excluded by default and must not be presented as if ' +
        'they were already on the list — pass status "unconfirmed" to see those explicitly. ' +
        'Ids are of the form "{recording_id}:{index}"; pass them verbatim to update_todo — they are positional, so re-read ' +
        'the list after any change rather than reusing a stale id.',
      annotations: { readOnlyHint: true },
      inputSchema: {
        status: z
          .enum(['open', 'completed', 'all', 'unconfirmed'])
          .optional()
          .describe('Which items to return. Default "open" = confirmed but not yet done.'),
        limit: z.number().int().min(1).max(100).optional().describe('Max results, default 50'),
        offset: z.number().int().min(0).optional().describe('Pagination offset, default 0'),
      },
    },
    async (args) =>
      run(async () => {
        const { client, userId } = getClient();
        const status = args.status ?? 'open';
        // The backend speaks all | pending | completed | unconfirmed; "open" is
        // the tool-facing name for "pending" (matching the chat agent's todo_list).
        const res = await client.listTodos(userId, {
          status: status === 'open' ? 'pending' : status,
          limit: args.limit ?? 50,
          offset: args.offset,
        });
        return ok({
          items: res.items.map((i) => ({
            id: `${i.conversation_id}:${i.item_idx}`,
            text: i.description,
            status: i.completed ? 'completed' : 'open',
            due_at: i.due_date ?? null,
            due_hint: i.due_hint || null,
            source_recording_id: i.conversation_id,
            source_recording_title: i.conversation_title || '',
          })),
          total_count: res.total_count,
          has_more: res.has_more,
        });
      }),
  );

  server.registerTool(
    'update_todo',
    {
      title: 'Create, edit, complete or delete a to-do',
      description:
        'Write to the user\'s to-do list. Only act on an explicit request from the user — never tidy up their list on your ' +
        'own initiative — and confirm back what changed. ' +
        'For "create", `id` optionally names the recording the to-do belongs to (from list_recordings); omit it to attach ' +
        'the item to the user\'s most recent recording. For update/complete/delete, `id` is required and must come from a ' +
        'fresh list_todos call: ids are positional within a recording, so a delete shifts the ids after it.',
      // Not read-only: this is the first Memorion MCP tool that writes. Deletes
      // are irreversible, so it is flagged destructive as well.
      annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: false },
      inputSchema: {
        action: z.enum(['create', 'update', 'complete', 'delete']).describe('What to do'),
        id: z
          .string()
          .optional()
          .describe('To-do id "{recording_id}:{index}" from list_todos. Required except for "create".'),
        text: z.string().optional().describe('The to-do text. Required for "create", optional for "update".'),
        due_at: z
          .string()
          .optional()
          .describe(
            'ISO-8601 deadline, only when a specific date is actually known. Never invent one from a vague phrase — ' +
              'put that in due_hint instead, or the user gets a reminder at a made-up time.',
          ),
        due_hint: z
          .string()
          .optional()
          .describe('The timing as the user said it ("this week", "尽快"), when no exact date is determinable.'),
      },
    },
    async (args) =>
      run(async () => {
        const { client, userId } = getClient();

        if (args.action === 'create') {
          if (!args.text) return errResult(new Error('text is required to create a to-do'));
          // Tolerate the model handing back a full item handle instead of a
          // recording id — the part before ":" is the recording.
          const recordingId = (args.id?.split(':')[0] || '') || (await client.latestConversationId(userId));
          if (!recordingId) return errResult(new Error('No recording to attach the to-do to'));
          await client.addTodo(userId, recordingId, {
            description: args.text,
            due_date: args.due_at,
            due_hint: args.due_hint,
          });
          // Re-read to report the id the item actually landed on: index is
          // positional, so deriving it from a stale count would be wrong.
          const after = await client.listTodos(userId, { status: 'all', limit: 100 });
          const created = after.items.find(
            (i) => i.conversation_id === recordingId && i.description === args.text,
          );
          return ok({
            ok: true,
            action: 'create',
            id: created ? `${created.conversation_id}:${created.item_idx}` : null,
            text: args.text,
            source_recording_id: recordingId,
          });
        }

        const handle = args.id ?? '';
        const sep = handle.lastIndexOf(':');
        const recordingId = sep > 0 ? handle.slice(0, sep) : '';
        const itemIdx = sep > 0 ? Number.parseInt(handle.slice(sep + 1), 10) : Number.NaN;
        if (!recordingId || !Number.isInteger(itemIdx) || itemIdx < 0) {
          return errResult(new Error('A valid id of the form "{recording_id}:{index}" from list_todos is required'));
        }

        if (args.action === 'delete') {
          await client.deleteTodo(userId, recordingId, itemIdx);
          return ok({ ok: true, action: 'delete', id: handle });
        }

        const patch: { description?: string; completed?: boolean; due_date?: string; due_hint?: string } = {};
        if (args.action === 'complete') patch.completed = true;
        if (args.text) patch.description = args.text;
        if (args.due_at) patch.due_date = args.due_at;
        if (args.due_hint !== undefined) patch.due_hint = args.due_hint;
        if (Object.keys(patch).length === 0) {
          return errResult(new Error('Nothing to update — pass text, due_at or due_hint'));
        }
        const updated = await client.updateTodo(userId, recordingId, itemIdx, patch);
        return ok({
          ok: true,
          action: args.action,
          id: handle,
          text: updated.description,
          status: updated.completed ? 'completed' : 'open',
        });
      }),
  );

  return server;
}

await startServer(createMemorionServer);
