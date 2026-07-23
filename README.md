# ask-app-server

[![Gem Version](https://badge.fury.io/rb/ask-app-server.svg)](https://badge.fury.io/rb/ask-app-server)

**JSON-RPC/stdio app-server for ask-rb agents.** Exposes `Ask::Agent::Session` behind the standard app-server protocol — the same protocol spoken by ZCode and Codex app-servers.

## What is this?

`ask-app-server` turns an ask-rb agent into a **programmable service** that speaks JSON-RPC over stdio. Any client that can speak the app-server protocol can drive your agent:

- **Telegram bots** — the `zcode-telegram-bot` connects to ask-app-server instead of ZCode
- **AI SDK providers** — the Vercel AI SDK provider works with ask-app-server unchanged
- **IDE extensions** — VS Code, Cursor, and JetBrains extensions connect over stdio/socket
- **Headless automation** — CI/CD pipelines, batch processing, scriptable agent tasks

## Installation

```bash
gem install ask-app-server
```

Or add to your Gemfile:

```ruby
gem "ask-app-server"
```

## Quick Start

```bash
# Start the server (reads JSON-RPC from stdin, writes to stdout)
ask-app-server
```

From another process, send JSON-RPC requests:

```json
{"id":1, "method":"session/create", "params":{"workspace":{"workspacePath":"."}}}
{"id":2, "method":"session/send",  "params":{"sessionId":"...", "content":"List files in this directory"}}
```

## Protocol

### Methods

| Method | Description |
|---|---|
| `initialize` | Handshake, returns server capabilities |
| `session/create` | Create a new agent session |
| `session/list` | List active sessions |
| `session/resume` | Resume an existing session |
| `session/subscribe` | Subscribe to streaming events |
| `session/send` | Send a message to a session |
| `session/events` | Poll for events after a sequence number |
| `session/abort` | Abort the current turn |
| `workspace/readState` | Read model and workspace settings |

### Events (server → client notifications)

| Event | When |
|---|---|
| `turn.started` | A new turn begins processing |
| `model.streaming` | Text delta from the model |
| `tool.updated` | Tool execution started/updated/completed/failed |
| `turn.completed` | Turn finished successfully |
| `turn.failed` | Turn ended with an error |

## Clients

This server is a drop-in replacement for `zcode app-server`. The following clients work without changes:

- [ask-coding-providers](https://github.com/ask-rb/ask-coding-providers) — ZCode adapter (set `ZCODE_CLI_PATH` to the `ask-app-server` binary)
- [zcode-telegram-bot](https://github.com/ask-rb/zcode-telegram-bot) — Python Telegram bot
- [ai-sdk-provider-codex-app-server](https://github.com/pablof7z/ai-sdk-provider-codex-app-server) — Vercel AI SDK provider

## Configuration

Environment variables:

| Variable | Default | Description |
|---|---|---|
| `ASK_APP_SERVER_MODEL` | `gpt-4o` | Model identifier (e.g., `claude-sonnet-4`, `gpt-4o`) |
| `DEBUG` | — | Set to `1` for debug logging |

## Development

```bash
git clone https://github.com/ask-rb/ask-app-server.git
cd ask-app-server
bundle install
bundle exec rake test
```

## License

MIT
