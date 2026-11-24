# Memorion CLI & MCP

Memorion Developer API 的官方命令行客户端与 MCP server。

**已发布**：[`@memorion/cli`](https://www.npmjs.com/package/@memorion/cli) · [`@memorion/mcp`](https://www.npmjs.com/package/@memorion/mcp) · [`@memorion/core`](https://www.npmjs.com/package/@memorion/core)

- 文档：[CLI](packages/cli/README.md) · [MCP](packages/mcp/README.md) · [Developer API](../docs/api/README.md) · [自建配置](../docs/development.md#cli-and-mcp)
- 用户文档：https://memorion.me/docs
- 结构：npm workspaces monorepo
  - `packages/core` — `@memorion/core`，共享 API client（CLI 与 MCP 共用）
  - `packages/cli` — `@memorion/cli`，`memorion` 命令
  - `packages/mcp` — `@memorion/mcp`，MCP server（stdio 和经认证的 HTTP）

## 快速上手

```bash
npm ci
npm run build
npm link -w @memorion/cli

# 用自建实例的 key 登录。默认 API 地址为 http://127.0.0.1:8000。
memorion login --with-key

# 开发者也可以直接用 API key（非交互，CI/Agent 场景）
memorion login --api-key memorion_dev_prod_xxx --user <external_user_id>

memorion whoami
memorion list --from 7d --limit 20
memorion recent
memorion today
memorion get <id>
memorion transcript <id> [--timestamps] [--raw]
memorion summary <id>
memorion audio <id> [-o out.wav | --url-only]
memorion config set user <id>
```

后端运行在其他地址时，设置 `MEMORION_BASE_URL`，或运行 `memorion config set base-url <url>`。浏览器登录需通过 `--auth-url` 或 `MEMORION_AUTH_URL` 指定授权页。

所有命令支持 `--json`（Agent 集成用）。退出码：0 成功 / 2 参数错误 / 3 认证失败 / 4 不存在 / 5 限流。

## MCP server

MCP 可以查询录音、原文、摘要和记忆，也可以管理待办。完整工具列表和权限说明见 [MCP 文档](packages/mcp/README.md#tools)。

Claude Desktop / Cursor 等客户端配置示例：

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

stdio 模式可以省略 `env`，MCP 会读取 `memorion login` 写入的 `~/.memorion/` 配置。HTTP 模式的请求需要自带 API key 和用户 ID。

## 认证架构

两种 key，同一套 API：

| | 获取方式 | 权限范围 |
|---|---|---|
| 开发者 key | Developer Portal 创建 | 该 developer 下任意 external_user_id |
| 用户绑定 key | `memorion login` 浏览器授权 | 仅本人数据（绑定 Firebase uid，越权 403；不能访问 developer 级端点） |

浏览器登录链路：CLI 起本地回调 server → 打开已配置的授权页→ portal 调后端 `POST /v1/auth/cli-token` 用 Firebase ID token 换绑定 key → 重定向回本地端口交给 CLI（CLI 先校验 key 再让网页显示成功）。

## 开发

```bash
cd cli
npm install
npm run build
node packages/cli/dist/index.js --help
```

## 发布

版本号在三个 `packages/*/package.json` 同步升（cli/mcp 对 core 的依赖号一起改），然后：

```bash
npm run build
npm publish -w @memorion/core --access public
npm publish -w @memorion/cli --access public
npm publish -w @memorion/mcp --access public
```

需要 `~/.npmrc` 里有 bypass-2FA 的 granular token。
