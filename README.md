# ask-app-server

[![Gem Version](https://badge.fury.io/rb/ask-app-server.svg)](https://badge.fury.io/rb/ask-app-server)

**JSON-RPC/stdio app-server for ask-rb agents.** Exposes `Ask::Agent::Session`
behind the standard app-server protocol: a vendor-neutral interface for
driving an agent as a service, with sessions, streamed events, approvals, and
turn lifecycle. Any client that implements the protocol can drive your agent,
and the client never needs to know it's talking to Ruby. The same protocol is
what several coding agents use behind their own app-servers (OpenAI's Codex
app-server is one well-known implementation); ask-app-server isn't an
extension of any of them — it simply speaks the standard.

## What is this?

`ask-app-server` turns an ask-rb agent into a **programmable service** that speaks JSON-RPC over stdio. Any client that can speak the app-server protocol can drive your agent:

- **IDE extensions and editors** — stream model deltas and tool events into an editor surface over stdio or a socket, the same way agent–editor integrations work today
- **Custom chat UIs and desktop apps** — stream model deltas and tool events into your own interface
- **Bots and assistants** — drive sessions programmatically from any runtime that can spawn a subprocess
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

Event payloads are delivered as `session/event` notifications on subscribed sessions. The server also sends `interaction/requestPermission` when a blocked tool needs approval and `interaction/requestUserInput` when it needs input from the user.

## Clients

Any client that speaks the app-server protocol can connect — including
existing app-server SDKs, such as OpenAI's `openai-codex` (Python) and
`@openai/codex-sdk` (TypeScript), which spawn an app-server subprocess and
drive it over stdio. Or write your own client in any language: the protocol
is documented and the wire format is plain JSON-RPC over newline-delimited
JSON.

## Configuration

Flags: `--version`, `--help`, `--config PATH`.

The config file is searched in order: `ASK_APP_SERVER_CONFIG` env var, then `./.ask-app-server.json`, then `~/.ask-app-server/config.json`.

Environment variables:

| Variable | Default | Description |
|---|---|---|
| `ASK_APP_SERVER_CONFIG` | auto-detected | Path to the config file |
| `ASK_APP_SERVER_MODEL` | `opencode_go/deepseek-v4-flash` | Model identifier (overrides config file) |
| `ASK_APP_SERVER_PERMISSIONS` | `on_request` | Permission mode (`on_request`, `never`) |
| `DEBUG` | unset | Set to `1` for debug logging |

## Development

```bash
git clone https://github.com/ask-rb/ask-app-server.git
cd ask-app-server
bundle install
bundle exec rake test
```

## Full documentation

The full ask-rb documentation lives at https://ask-rb.github.io/ask-docs. The [App Server guide](https://ask-rb.github.io/ask-docs/core/app-server) covers the protocol, events, and configuration; the [Gem reference](https://ask-rb.github.io/ask-docs/reference/gems) (Agent Infrastructure section) lists this gem alongside ask-acp and ask-coding-providers.

## License

MIT
