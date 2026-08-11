# Changelog

## [0.4.0] - 2026-08-11

### Added

- **Herdr citizenship** — `HerdrReporter` keeps a herdr sidebar accurate
  with first-party state when the host runs inside a herdr pane. Reads
  `HERDR_SOCKET_PATH`/`HERDR_PANE_ID` (injected into every pane), reports
  the aggregate pane state (`working` | `blocked` | `idle`) via
  `pane.report_agent` on change, the ask session id via
  `pane.report_agent_session` (for future resume), and model/session
  tokens via `pane.report_metadata`. `HerdrReporter.attach(session_manager)`
  returns nil outside herdr; the CLI attaches automatically.
- **Session event observers** — `SessionManager#on_session_event` receives
  every canonical event across all sessions as it happens; the observer
  chain hooks the single emission point (`EventTranslator#on_event` →
  `AgentAdapter#on_event`). Observers attach after store registration so
  the store is settled, and the buffered `session.created` is replayed.

## [0.3.0] - 2026-08-11

### Added

- **Unix-socket transport for multi-client attach** — `SocketServer`
  (`ask-app-server --socket PATH` or `ASK_APP_SERVER_SOCKET`). Any number
  of clients (terminal TUI, web console, bots) connect to the same host
  and share sessions; each connection has its own reader thread, and
  responses are routed back to the requesting connection. The stdio
  transport runs alongside.
- **Per-connection event delivery cursors** — the host no longer drains a
  shared buffer. Each `Connection` tracks the last delivered seq per
  subscribed session; `session/subscribe` with `afterSeq` replays exactly
  what the client hasn't seen, and each client receives each event
  exactly once (dedup by seq). `session/event` notifications fan out to
  every subscribed connection.
- **Host-side contract enforcement** — incoming requests on the canonical
  surface are validated against `Ask::SessionProtocol::Methods` before
  dispatch (invalid params → `-32602 invalid_params`). Params are
  normalized to string keys so Ruby clients may send symbols.
- **`Connection` class** — per-client I/O plus subscription cursors;
  `EventTranslator` retains a capped event log (2000) for replay/polling.

### Changed

- `Server` is now the transport-agnostic protocol engine: `dispatch(msg,
  connection)` processes one message and writes responses back to the
  sending connection; `push_pending` delivers events to subscribed
  connections. `Server#start` is the stdio transport (one connection).
- `session/subscribe` now registers the *connection's* cursor (replay
  default) instead of a global store flag.

### Removed

- `SessionManager#pending_notifications` (superseded by cursor-based
  delivery).

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
