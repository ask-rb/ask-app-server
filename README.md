# ask-app-server

[![Gem Version](https://badge.fury.io/rb/ask-app-server.svg)](https://badge.fury.io/rb/ask-app-server)

**JSON-RPC/stdio session host for ask-rb agents.** Exposes `Ask::Agent::Session`
behind the canonical [ask-session-protocol](https://github.com/ask-rb/ask-session-protocol)
wire contract: one versioned interface for driving an agent as a service,
with sessions, streamed canonical events, resolvable interactions
(approvals, plans), and turn lifecycle. Any client that speaks the protocol
can drive your agent, and the client never needs to know it's talking to
Ruby. The method surface is app-server compatible — the same shape Codex
and ZCode expose — while the event vocabulary and interaction model are the
ask ecosystem's own canonical contract.

## What is this?

`ask-app-server` turns an ask-rb agent into a **programmable service** that speaks JSON-RPC over stdio. Any client that speaks the canonical session protocol can drive your agent:

- **IDE extensions and editors** — stream model deltas, tool events, and approvals into an editor surface over stdio or a socket
- **Custom chat UIs and desktop apps** — stream canonical events into your own interface
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

# Or expose a unix socket for multi-client attach (runs alongside stdio):
ask-app-server --socket ~/.ask-app-server/app-server.sock
```

Clients connect to the socket and speak the same protocol as NDJSON lines
(`ASK_APP_SERVER_SOCKET` env var works too):

```bash
nc -U ~/.ask-app-server/app-server.sock
{"id":1, "method":"initialize", "params":{}}
```

Any number of clients can attach to the same sessions: each connection
tracks its own event-delivery cursor, so `session/subscribe` replays what
that client hasn't seen and every client receives each event exactly once.

From another process, send JSON-RPC requests:

```json
{"id":1, "method":"session/create", "params":{"workspace":{"workspacePath":"."}}}
{"id":2, "method":"session/send",  "params":{"sessionId":"...", "content":"List files in this directory"}}
```

## Protocol

### Methods

| Method | Description |
|---|---|
| `initialize` | Handshake; negotiates `protocolVersion` and capabilities |
| `session/create` | Create a new agent session |
| `session/list` | List active sessions |
| `session/resume` | Resume an existing session |
| `session/subscribe` | Subscribe to the event stream (with replay snapshot) |
| `session/send` | Prompt an idle session or inject mid-run (`steered`/`queued`/`stale`) |
| `session/events` | Poll for events after a sequence number |
| `session/abort` | Abort the current turn |
| `session/close` | Close the session |
| `session/artifacts` · `session/artifact/get` | List and fetch tool artifacts |
| `interaction/list` | List pending approval interactions |
| `interaction/approve` · `interaction/reject` | Resolve an approval by id |
| `interaction/approve-all` · `interaction/reject-all` | Resolve all approvals |
| `interaction/respond` | Answer user-input elicitation (not yet implemented) |
| `plan/approve` · `plan/reject` | Approve/reject the pending plan proposal |
| `workspace/readState` | Read workspace and approval-mode state |

### Events (server → client notifications)

Every event is a canonical `{type, seq, payload}` envelope, delivered as a
`session/event` notification on subscribed sessions:

| Event | When |
|---|---|
| `session.created` · `session.ended` | Session lifecycle |
| `turn.started` · `turn.completed` · `turn.failed` · `turn.aborted` | Turn lifecycle |
| `model.streaming` · `model.thinking` | Model output deltas |
| `tool.use` · `tool.delta` · `tool.result` | Tool execution |
| `approval.required` · `approval.updated` | Resolvable approval interactions |
| `plan.proposed` · `plan.approved` · `plan.rejected` | Plan mode |
| `todos.updated` | Todo list changes |
| `error` | Non-fatal errors |

The full vocabulary, payload shapes, method specs, and versioning live in
the ask-session-protocol gem (JSON Schema artifact included).

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
| `ASK_APP_SERVER_PERMISSIONS` | `on_request` | Permission mode (`on_request`, `never`, `auto`) |
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
