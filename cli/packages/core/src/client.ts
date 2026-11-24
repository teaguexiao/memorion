import type { ResolvedAuth } from './config.js';

export class ApiError extends Error {
  constructor(
    public status: number,
    public body: unknown,
    message?: string,
  ) {
    super(message ?? `API request failed with status ${status}`);
  }
}

const RETRYABLE_STATUS = new Set([429, 502, 503, 504]);

export class MemorionClient {
  constructor(private auth: ResolvedAuth) {}

  private async request<T>(
    method: string,
    path: string,
    opts: { query?: Record<string, string | number | undefined>; body?: unknown } = {},
  ): Promise<T> {
    const url = new URL(path, this.auth.baseUrl);
    for (const [k, v] of Object.entries(opts.query ?? {})) {
      if (v !== undefined) url.searchParams.set(k, String(v));
    }

    let lastError: unknown;
    for (let attempt = 0; attempt <= 2; attempt++) {
      if (attempt > 0) await new Promise((r) => setTimeout(r, 500 * 2 ** attempt));
      let res: Response;
      try {
        res = await fetch(url, {
          method,
          // API_DOC.md: raw key in Authorization header, no Bearer prefix
          headers: {
            Authorization: this.auth.apiKey,
            ...(opts.body !== undefined ? { 'Content-Type': 'application/json' } : {}),
          },
          body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined,
        });
      } catch (err) {
        lastError = err;
        continue;
      }
      if (RETRYABLE_STATUS.has(res.status) && method === 'GET' && attempt < 2) {
        lastError = new ApiError(res.status, await res.text());
        continue;
      }
      if (!res.ok) {
        let body: unknown;
        const text = await res.text();
        try {
          body = JSON.parse(text);
        } catch {
          body = text;
        }
        const detail =
          typeof body === 'object' && body !== null && 'detail' in body
            ? String((body as { detail: unknown }).detail)
            : undefined;
        throw new ApiError(res.status, body, detail);
      }
      if (res.status === 204) return undefined as T;
      return (await res.json()) as T;
    }
    if (lastError instanceof ApiError) throw lastError;
    throw new Error(`Network error after retries: ${lastError}`);
  }

  // --- Developer profile ---

  getMe(): Promise<DeveloperProfile> {
    return this.request('GET', '/v1/developers/me');
  }

  /**
   * Cheapest key check that works for BOTH unbound developer keys and
   * user-bound CLI keys (which get 403 on developer-scoped endpoints
   * like /v1/developers/me).
   */
  async validateKey(userId: string): Promise<void> {
    await this.request('GET', '/v1/conversations', {
      query: { external_user_id: userId, limit: 1 },
    });
  }

  // --- Conversations ---

  listConversations(
    userId: string,
    opts: { limit?: number; offset?: number; startDate?: string; endDate?: string; categories?: string } = {},
  ): Promise<Conversation[]> {
    return this.request('GET', '/v1/conversations', {
      query: {
        external_user_id: userId,
        limit: opts.limit,
        offset: opts.offset,
        start_date: opts.startDate,
        end_date: opts.endDate,
        categories: opts.categories,
      },
    });
  }

  searchConversations(
    userId: string,
    query: string,
    opts: { page?: number; perPage?: number; startDate?: string; endDate?: string } = {},
  ): Promise<SearchResult> {
    return this.request('POST', '/v1/conversations/search', {
      body: {
        external_user_id: userId,
        query,
        page: opts.page,
        per_page: opts.perPage,
        start_date: opts.startDate,
        end_date: opts.endDate,
      },
    });
  }

  getConversation(userId: string, id: string): Promise<Conversation> {
    return this.request('GET', `/v1/conversations/${id}`, {
      query: { external_user_id: userId },
    });
  }

  hasRecording(userId: string, id: string): Promise<{ has_recording: boolean }> {
    return this.request('GET', `/v1/conversations/${id}/recording`, {
      query: { external_user_id: userId },
    });
  }

  getAudioUrl(userId: string, id: string): Promise<{ audio_url: string | null }> {
    return this.request('GET', `/v1/conversations/${id}/audio-url`, {
      query: { external_user_id: userId },
    });
  }

  // --- Memories ---

  searchMemories(userId: string, query: string, limit = 10): Promise<Memory[]> {
    return this.request('POST', '/v1/memories/search', {
      body: { external_user_id: userId, query, limit },
    });
  }

  // --- Time ---

  /**
   * Resolves a relative expression ("last Wednesday") into an absolute range,
   * using the timezone stored server-side. Never guess the timezone locally:
   * the machine running the CLI is not necessarily where the user records.
   */
  resolveTimeRange(userId: string, expr: string, timezone?: string): Promise<TimeRange> {
    return this.request('POST', '/v1/user/resolve-time-range', {
      query: { external_user_id: userId },
      body: { expr, timezone },
    });
  }

  // --- To-dos ---

  /**
   * Cross-conversation to-do list. Items live inside each conversation's
   * `structured.action_items[]`, so they are addressed by the composite handle
   * `{conversation_id}:{item_idx}` — there is no standalone to-do id.
   */
  listTodos(
    userId: string,
    opts: { status?: TodoStatusFilter; limit?: number; offset?: number } = {},
  ): Promise<TodoListResponse> {
    return this.request('GET', '/v1/discover/action-items', {
      query: {
        external_user_id: userId,
        status: opts.status,
        limit: opts.limit,
        offset: opts.offset,
      },
    });
  }

  /**
   * Adds a to-do to a conversation. The backend stamps `confirmed=true`: an
   * item the user explicitly asked for needs no second confirmation tap.
   */
  addTodo(
    userId: string,
    conversationId: string,
    body: { description: string; due_date?: string; due_hint?: string },
  ): Promise<TodoItem> {
    return this.request('POST', `/v1/conversations/${conversationId}/action-items`, {
      query: { external_user_id: userId },
      body: { ...body, completed: false },
    });
  }

  updateTodo(
    userId: string,
    conversationId: string,
    itemIdx: number,
    body: { description?: string; completed?: boolean; due_date?: string; due_hint?: string },
  ): Promise<TodoItem> {
    return this.request('PATCH', `/v1/conversations/${conversationId}/action-items/${itemIdx}`, {
      query: { external_user_id: userId },
      body,
    });
  }

  deleteTodo(userId: string, conversationId: string, itemIdx: number): Promise<void> {
    return this.request('DELETE', `/v1/conversations/${conversationId}/action-items/${itemIdx}`, {
      query: { external_user_id: userId },
    });
  }

  /** The most recent conversation id, used as the default owner of a new to-do. */
  async latestConversationId(userId: string): Promise<string | undefined> {
    const list = await this.listConversations(userId, { limit: 1 });
    return list[0]?.id;
  }
}

// --- Types (subset of API_DOC.md responses used by the CLI) ---

export interface DeveloperProfile {
  id: string;
  email: string;
  name?: string;
  company_name?: string;
  tier: string;
  is_active: boolean;
  credits_balance?: number;
  created_at?: string;
}

export interface TranscriptSegment {
  id?: string;
  text: string;
  // API_DOC.md documents integer, but production returns strings like "SPEAKER_01"
  speaker_id?: number | string;
  start?: number;
  end?: number;
  is_user?: boolean;
  person_id?: string | null;
}

export interface Structured {
  title?: string;
  overview?: string;
  emoji?: string;
  category?: string;
  action_items?: Array<{ description?: string; completed?: boolean } | string>;
}

export interface Conversation {
  id: string;
  created_at?: string;
  started_at?: string;
  finished_at?: string;
  language?: string;
  source?: string;
  status?: string;
  transcript_segments?: TranscriptSegment[];
  structured?: Structured;
}

export interface SearchResult {
  items: Conversation[];
  total_pages?: number;
  current_page?: number;
  per_page?: number;
}

export interface Memory {
  id: string;
  content?: string;
  category?: string;
  tags?: string[];
  created_at?: string;
}

export interface TimeRange {
  /** null when the expression carried no resolvable date — a normal answer. */
  start: string | null;
  end: string | null;
  timezone: string;
  resolved_as: string;
}

export type TodoStatusFilter = 'all' | 'pending' | 'completed' | 'unconfirmed';

export interface TodoEntry {
  description: string;
  completed: boolean;
  conversation_id: string;
  conversation_title?: string;
  item_idx: number;
  created_at?: string | null;
  confirmed?: boolean;
  due_date?: string | null;
  due_hint?: string | null;
}

export interface TodoListResponse {
  items: TodoEntry[];
  total_count: number;
  completed_count: number;
  has_more: boolean;
}

/** Single action item as returned by the per-conversation write endpoints. */
export interface TodoItem {
  description: string;
  completed: boolean;
  confirmed?: boolean;
  due_date?: string | null;
  due_hint?: string | null;
}
