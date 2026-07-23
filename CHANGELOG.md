# Changelog

## [0.1.0] - 2026-07-23

### Added

- Initial release of `ask-app-server` — JSON-RPC/stdio app-server for ask-rb agents.
- **Protocol handler** — implements the ZCode/Codex app-server JSON-RPC protocol over stdio.
- **Agent adapter** — wraps `Ask::Agent::Session` behind the app-server protocol.
- **Event translator** — converts ask-agent event types to app-server protocol event types.
- **Session manager** — create, list, resume, subscribe, and poll sessions.
- **CLI binary** — `ask-app-server` command (stdio mode).
- **Mid-execution injection** — abort running turns and send new messages.
- **Subscription streaming** — push `session/event` notifications to subscribed clients.
- **Event polling** — retrieve events by sequence number via `session/events`.
