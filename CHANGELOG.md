# Changelog

## [0.2.0] - 2026-08-11

### Changed

- **The host now speaks the canonical Ask::SessionProtocol** (ask-session-protocol
  gem). The event vocabulary is the canonical contract — `turn.started`,
  `model.streaming`, `model.thinking`, `tool.use/delta/result`,
  `approval.required/updated`, `plan.proposed/approved/rejected`,
  `todos.updated`, `session.created/ended`, `turn.completed/failed/aborted`,
  `error` — in the validated `{type, seq, payload}` envelope with string-keyed
  payloads. The old app-server vocabulary (`tool.updated`, `message.upserted`,
  symbol-keyed payloads) is gone; `initialize` negotiates
  `Ask::SessionProtocol::PROTOCOL_VERSION` and advertises capabilities.
- **Approvals are canonical resolvable interactions.** The blocking
  PermissionHandler flow is replaced by the ask-agent approval queue: gated
  tools pause the turn, `approval.required` streams to every client, and any
  client resolves by id via `interaction/approve`/`interaction/reject` (or
  approve/reject-all). `interaction/list` reports pending approvals.
- **Steer-based mid-execution injection.** `session/send` returns
  `{accepted, status, turnId}` with `steered | queued | stale` semantics:
  idle sessions run the prompt, running sessions queue it for the next turn
  boundary (no abort), and `expectedTurnId` guards staleness. Queued steers
  drain automatically when the running turn completes.
- **New methods** — `session/close`, `interaction/list|approve|reject|
  approve-all|reject-all`, `plan/approve|reject`. `interaction/respond`
  returns `-32009 not_implemented` until elicitation exists in the runtime.
- `workspace/readState` returns the canonical `{workspace: {path, name,
  gitBranch, mode}}` shape (legacy `settings` retained for compatibility).
- `session/subscribe` returns `{subscription: {sessionId, deliveryKind}}`
  and can include a replay snapshot.

### Added

- `session.created` / `session.ended` lifecycle events, emitted on session
  start and close.
- Approval modes: `mode: "plan"` enables plan mode (read-only until
  `plan/approve`); `"auto"` admits an inspectable queue that never blocks.

### Removed

- `Server#register_permission_handler` and the SessionManager permission
  handler wiring (the PermissionHandler class remains for direct use).
- `AgentAdapter#inject_message` (replaced by steer semantics).

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
