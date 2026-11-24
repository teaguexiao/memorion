/**
 * Parse human-friendly time inputs (CLI_SPEC §4.3) into ISO 8601 UTC strings.
 * Accepts: ISO 8601 dates/datetimes, "today", "yesterday", "7d", "24h".
 */
export function parseTimeArg(input: string, now: Date = new Date()): string {
  const s = input.trim().toLowerCase();

  if (s === 'today') {
    const d = new Date(now);
    d.setHours(0, 0, 0, 0);
    return d.toISOString();
  }
  if (s === 'yesterday') {
    const d = new Date(now);
    d.setDate(d.getDate() - 1);
    d.setHours(0, 0, 0, 0);
    return d.toISOString();
  }

  const rel = s.match(/^(\d+)([dhm])$/);
  if (rel) {
    const n = parseInt(rel[1], 10);
    const ms = { d: 86400_000, h: 3600_000, m: 60_000 }[rel[2] as 'd' | 'h' | 'm'];
    return new Date(now.getTime() - n * ms).toISOString();
  }

  const parsed = new Date(input);
  if (!isNaN(parsed.getTime())) return parsed.toISOString();

  throw new Error(`Invalid time value: "${input}" (expected ISO 8601, "today", "yesterday", or e.g. "7d")`);
}
