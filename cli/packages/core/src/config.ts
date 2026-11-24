import { readFileSync, writeFileSync, mkdirSync, unlinkSync, existsSync, chmodSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

export const CONFIG_DIR = join(homedir(), '.memorion');
const CREDENTIALS_PATH = join(CONFIG_DIR, 'credentials.json');
const CONFIG_PATH = join(CONFIG_DIR, 'config.json');

export const DEFAULT_BASE_URL = 'http://127.0.0.1:8000';

export interface Credentials {
  api_key: string;
  created_at: string;
}

export interface CliConfig {
  default_user_id?: string;
  base_url?: string;
  /** Account email captured at browser login (bound keys can't query /developers/me). */
  email?: string;
}

function readJson<T>(path: string): T | null {
  try {
    return JSON.parse(readFileSync(path, 'utf-8')) as T;
  } catch {
    return null;
  }
}

export function loadCredentials(): Credentials | null {
  return readJson<Credentials>(CREDENTIALS_PATH);
}

export function saveCredentials(apiKey: string): void {
  mkdirSync(CONFIG_DIR, { recursive: true });
  writeFileSync(
    CREDENTIALS_PATH,
    JSON.stringify({ api_key: apiKey, created_at: new Date().toISOString() }, null, 2) + '\n',
  );
  chmodSync(CREDENTIALS_PATH, 0o600);
}

export function deleteCredentials(): boolean {
  if (existsSync(CREDENTIALS_PATH)) {
    unlinkSync(CREDENTIALS_PATH);
    return true;
  }
  return false;
}

export function loadConfig(): CliConfig {
  return readJson<CliConfig>(CONFIG_PATH) ?? {};
}

export function saveConfig(config: CliConfig): void {
  mkdirSync(CONFIG_DIR, { recursive: true });
  writeFileSync(CONFIG_PATH, JSON.stringify(config, null, 2) + '\n');
}

export interface ResolvedAuth {
  apiKey: string;
  userId?: string;
  baseUrl: string;
}

/**
 * Resolution order (CLI_SPEC §3): CLI flag > env var > config file.
 */
export function resolveAuth(opts: { apiKey?: string; user?: string; baseUrl?: string }): ResolvedAuth {
  const config = loadConfig();
  const apiKey = opts.apiKey ?? process.env.MEMORION_API_KEY ?? loadCredentials()?.api_key;
  if (!apiKey) {
    throw new AuthError(
      'No API key found. Run `memorion login`, or set MEMORION_API_KEY, or pass --api-key.',
    );
  }
  return {
    apiKey,
    userId: opts.user ?? process.env.MEMORION_USER_ID ?? config.default_user_id,
    baseUrl: opts.baseUrl ?? process.env.MEMORION_BASE_URL ?? config.base_url ?? DEFAULT_BASE_URL,
  };
}

export function requireUserId(auth: ResolvedAuth): string {
  if (!auth.userId) {
    throw new AuthError(
      'No external_user_id set. Pass --user <id>, set MEMORION_USER_ID, or run `memorion config set user <id>`.',
    );
  }
  return auth.userId;
}

export class AuthError extends Error {}
