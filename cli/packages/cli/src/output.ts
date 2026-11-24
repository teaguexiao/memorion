import { ApiError, AuthError } from '@memorion/core';
import type { Conversation, TranscriptSegment } from '@memorion/core';

// Exit codes per CLI_SPEC §4.2
export const EXIT = { OK: 0, ERROR: 1, USAGE: 2, AUTH: 3, NOT_FOUND: 4, RATE_LIMIT: 5 } as const;

export interface OutputOpts {
  json?: boolean;
}

export function printResult(data: unknown, opts: OutputOpts, humanize: (d: any) => string): void {
  if (opts.json) {
    process.stdout.write(JSON.stringify(data, null, 2) + '\n');
  } else {
    process.stdout.write(humanize(data) + '\n');
  }
}

export function fail(err: unknown, opts: OutputOpts): never {
  let code: number = EXIT.ERROR;
  let message = err instanceof Error ? err.message : String(err);

  if (err instanceof AuthError) {
    code = EXIT.AUTH;
  } else if (err instanceof ApiError) {
    if (err.status === 401 || err.status === 403) {
      code = EXIT.AUTH;
      message = `Authentication failed (${err.status}): ${message}. Run \`memorion login\` to reconfigure.`;
    } else if (err.status === 404) {
      code = EXIT.NOT_FOUND;
    } else if (err.status === 429) {
      code = EXIT.RATE_LIMIT;
      message = `Rate limited (429): ${message}`;
    }
  }

  if (opts.json) {
    process.stderr.write(JSON.stringify({ error: { code, message } }) + '\n');
  } else {
    process.stderr.write(`Error: ${message}\n`);
  }
  process.exit(code);
}

// --- Formatting helpers ---

export function formatDuration(c: Conversation): string {
  if (!c.started_at || !c.finished_at) return '-';
  const secs = Math.round((new Date(c.finished_at).getTime() - new Date(c.started_at).getTime()) / 1000);
  if (secs < 0) return '-';
  const m = Math.floor(secs / 60);
  const s = secs % 60;
  return m > 0 ? `${m}m${s.toString().padStart(2, '0')}s` : `${s}s`;
}

export function formatConversationRow(c: Conversation): string {
  const time = c.started_at ? new Date(c.started_at).toISOString().slice(0, 16).replace('T', ' ') : '-';
  const title = `${c.structured?.emoji ?? ''} ${c.structured?.title ?? '(untitled)'}`.trim();
  return [c.id, time, formatDuration(c), title, c.structured?.category ?? '-', c.status ?? '-'].join('  ');
}

export function formatTimestamp(seconds: number | undefined): string {
  if (seconds === undefined) return '[--:--]';
  const m = Math.floor(seconds / 60);
  const s = Math.floor(seconds % 60);
  return `[${m.toString().padStart(2, '0')}:${s.toString().padStart(2, '0')}]`;
}

export function speakerLabel(seg: TranscriptSegment): string {
  if (seg.is_user) return 'You';
  const id = seg.speaker_id ?? 0;
  // Production returns string ids like "SPEAKER_01"; avoid "Speaker SPEAKER_01"
  if (typeof id === 'string') {
    const m = id.match(/^speaker[_\s]?(\d+)$/i);
    return m ? `Speaker ${parseInt(m[1], 10)}` : id;
  }
  return `Speaker ${id}`;
}
