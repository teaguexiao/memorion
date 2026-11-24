# Memorion MCP Server

[Model Context Protocol](https://modelcontextprotocol.io) server for [Memorion](https://memorion.me) — lets Claude, Cursor, ChatGPT and other MCP clients read your Memorion recordings, transcripts and AI summaries.

Ask your AI things like *"what did I talk about today?"*, *"summarize last week's meetings about the roadmap"*, or *"what's on my to-do list?"*.

## Setup

Requires Node.js ≥ 20.

Build the MCP server from the repository's `cli/` directory with `npm ci && npm run build`. The stdio server can reuse credentials and the API URL saved by the CLI. The source build defaults to `http://127.0.0.1:8000`.

Or configure credentials explicitly in your MCP client (e.g. Claude Desktop's `claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "memorion": {
      "command": "node",
      "args": ["/absolute/path/to/memorion/cli/packages/mcp/dist/index.js"],
      "env": {
        "MEMORION_BASE_URL": "http://127.0.0.1:8000",
        "MEMORION_API_KEY": "memorion_dev_prod_xxx",
        "MEMORION_USER_ID": "<external_user_id>"
      }
    }
  }
}
```


## Tools

Everything is read-only except `update_todo`.

| Tool | Description |
|---|---|
| `get_current_user` | Verify the connection; account info |
| `list_recordings` | List/search recordings (keyword, time range, pagination) |
| `get_recording` | Metadata, AI summary and audio availability for one recording |
| `get_transcript` | Full transcript with speaker labels (`plain` or `segments` format) |
| `get_summary` | AI summary: title, overview, category, action items |
| `get_audio_url` | Temporary signed URL for the raw audio (expires in 15 minutes) |
| `search_memories` | Substring search over long-term memories distilled from recordings |
| `resolve_time_range` | Turn "last Wednesday" into an absolute range in *your* timezone |
| `list_todos` | To-dos extracted from your recordings, with the recording each came from |
| `update_todo` | **Writes.** Create, edit, complete or delete a to-do |

`resolve_time_range` exists because the machine running this server is not necessarily in your timezone. It resolves the expression server-side, so a range means the same thing here as it does in the Memorion app's own assistant.

## HTTP mode

By default the server speaks stdio and your MCP client spawns it. To run one long-lived process instead:

```bash
node packages/mcp/dist/index.js --http --port=3579
```

| Flag | Env var | Default |
|---|---|---|
| `--http` / `--stdio` | `MEMORION_MCP_TRANSPORT=http` | stdio |
| `--port=<n>` | `MEMORION_MCP_PORT` | `3579` |
| `--host=<addr>` | `MEMORION_MCP_HOST` | `127.0.0.1` |

Endpoints: `POST`/`GET`/`DELETE /mcp` for the MCP session, plus `GET /health`.

Every request to `/mcp` must include both headers. The upstream Memorion API validates the credentials when a tool accesses data.

| Header | Meaning |
|---|---|
| `Authorization` | Your Memorion API key. A raw key or a `Bearer` token is accepted. |
| `X-Memorion-User-Id` | The `external_user_id` to access |

Set `MEMORION_BASE_URL` on the server process if your API runs at a different address. All HTTP requests use that same upstream. The default is `http://127.0.0.1:8000`.

The server binds to loopback by default and rejects requests carrying a foreign `Host` or `Origin`. Use stdio for clients that cannot send custom headers. Keep HTTP local, or terminate TLS at a trusted proxy when clients connect over a network.

## License

MIT
