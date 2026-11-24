# Memorion CLI

Command-line client for [Memorion](https://memorion.me) — access recordings, transcripts, AI summaries and audio captured by your Memorion device, from your terminal or your AI agent.

## Install

```bash
# From the repository's cli/ directory
npm ci
npm run build
npm link -w @memorion/cli
```

Requires Node.js ≥ 20.

## Quick start

```bash
# 1. Log in with a key from your instance. Credentials are saved to ~/.memorion/.
memorion login --with-key

# 2. Browse your recordings
memorion recent                  # last 7 days
memorion today                   # today's recordings
memorion list --from 2026-07-01 --query "project meeting"

# 3. Read the content
memorion get <id>                # metadata + summary + audio availability
memorion transcript <id>         # full transcript with speaker labels
memorion transcript <id> --raw   # plain text, cheapest to feed to an LLM
memorion summary <id>            # AI summary + action items

# 4. Download the audio
memorion audio <id> -o meeting.wav
```

The source build defaults to `http://127.0.0.1:8000`. Use `--base-url`, `MEMORION_BASE_URL`, or `memorion config set base-url <url>` to select another API. To log in through a browser, set `MEMORION_AUTH_URL` or pass `memorion login --auth-url <url>` for a compatible consent page.

To log in non-interactively:

```bash
memorion login --api-key memorion_dev_prod_xxx --user <external_user_id>
```

## Agent integration

Every command supports `--json` for machine-readable output:

```bash
memorion list --from 24h --json
memorion transcript <id> --json
```

Exit codes: `0` success · `2` usage error · `3` auth failed · `4` not found · `5` rate limited.

Credentials can also be provided via environment variables — useful in CI and agent sandboxes:

```bash
export MEMORION_API_KEY=memorion_dev_prod_xxx
export MEMORION_USER_ID=<external_user_id>
```

## Commands

| Command | Description |
|---|---|
| `login` / `logout` / `whoami` | Manage credentials |
| `list [--from --to --query --category --limit]` | List or search recordings |
| `recent` / `today` | Time-window shortcuts |
| `get <id>` | Recording details |
| `transcript <id> [--timestamps --raw]` | Full transcript |
| `summary <id>` | AI summary and action items |
| `audio <id> [-o path \| --url-only]` | Download recording audio (WAV) |
| `config set/get/list` | Local defaults (user, base-url) |

Time filters accept ISO 8601 (`2026-07-01`), `today`, `yesterday`, or relative values like `7d` / `24h`.

## MCP server

Prefer a native integration for Claude Desktop, Cursor or ChatGPT? Use [`@memorion/mcp`](https://www.npmjs.com/package/@memorion/mcp) — same data, exposed as MCP tools.

## License

MIT
