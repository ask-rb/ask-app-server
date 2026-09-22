# Changelog

## [Unreleased]

## [0.4.21] - 2026-09-22

### Added

- **Durable ask-session integration — `Ask::Session::Host` is the event
  source of truth for replay.** `SessionManager` owns one Host
  (injectable via `SessionManager.new(host:)`, default in-process);
  every session creates its ask-session record at create time, each
  canonical protocol event is appended to it at the `EventTranslator`
  boundary, and `session/events`, subscribe snapshots, and cursor push
  all read back from the Host — replay no longer depends on the
  in-memory translator buffer (events survive the buffer cap). Session
  close closes the durable record (`Host#close`); the wire seq is the
  Host seq, contiguous from 1. Requires the new runtime dependency
  `ask-session >= 0.1.0` (the single session store; no second store
  added). Protocol translation is unchanged and stays in app-server;
  the JSON-RPC surface, approvals, plans, subscriptions, and
  `ask-session-protocol` wire behavior are untouched.
- **Durable restart resume.** `SessionManager.new(state_adapter:)` and
  `AgentAdapter.new(state_adapter:)` accept any ask-state-providers
  adapter; it is wrapped in `Ask::Session::ProviderStore` and handed to
  the Host, so records, events, and snapshots survive restarts. No
  adapter means the default in-memory Host — nothing changes for
  callers that do not opt in, and no concrete backend is forced.
- **`session/resume` now falls back to the durable Host.** When the live
  registry does not know the session, the manager rebuilds a fresh
  compatible `Ask::Agent::Session` under the same id (configured from
  the manager's defaults — model/tools/prompt are not serialized), and
  when the Host holds an `agent.snapshot` restores the conversation
  through `Ask::Agent::SessionAdapter.resume`. In-process resume (the
  live adapter) still wins and is unchanged; a terminal (closed)
  durable record refuses resume with the existing `SessionNotFound`
  (-32004) error. The restored SessionAdapter's own event handler is
  detached after restore — the `EventTranslator` remains the single
  protocol writer, so the wire vocabulary never double-writes.
- **Successful runs append an `agent.snapshot`** (messages +
  turn_count — the payload `SessionAdapter.resume` expects) to the
  Host after a clean turn; failed/aborted turns write none. The
  snapshot is Host-internal and stays off the wire.

### Fixed

- **Failure events always wake watchers.** Model stream drops, run
  failures, and disconnects now reliably emit `turn.failed` with turn
  identity: `EventTranslator#turn_failed` always carries a `turnId`
  (the active turn's, or a fresh one when the run died before
  `turn.started`) — previously a run that failed without an announced
  turn raised a protocol validation error inside the run thread, the
  event was swallowed, and every watcher waited forever on a ghost
  turn. The adapter settles `running` before emitting, so observers
  woken by `turn.failed` (the herdr pane reporter, session observers)
  see the run as finished rather than a ghost "working" that no later
  event corrects, and emission itself is guarded so a translation
  error can never take down the run thread after the fact. Aborted
  turns remain client-requested, not failures.
- **A disconnected watcher cannot starve the others.** `push_pending`
  isolates delivery per connection: a socket that dies mid-write
  (EPIPE/ECONNRESET) no longer aborts the whole pass — the remaining
  subscribed connections still receive their events (including the
  terminal `turn.failed`), and the dead connection's cursor holds
  until its reader reaps it.
- **Durable replay over `ProviderStore`** no longer drops events:
  rehydrated Host events carry symbolized payload keys, which failed
  protocol payload validation and were silently dropped from
  `session/events` — the adapter now normalizes payload keys to the
  string-keyed wire shape at the boundary.

### Boundaries (unchanged this slice)

- **`Ask::Agent::SessionAdapter` is not attached.** Its `run` lacks the
  steer/queue/staleness semantics `session/send` depends on, and its
  event vocabulary (`message.added`, `agent.snapshot`, no
  `turn.completed`/approval events, non-wire payloads) would double-write
  and diverge from the canonical contract. The app-server keeps driving
  runs itself and appends protocol events to the Host directly; its
  lifecycle surface maps 1:1 (`SessionAdapter#create`/`#close` ≡
  `Host#create`/`Host#close`).
- **`Host#send_message` is unused:** the protocol has no `message.added`
  event; user input enters through `session/send`.
- **`Host#subscribe` is unused:** delivery stays per-connection cursor
  polling over `Host#events` (any number of clients per session).
- **`session/resume` prefers the live adapter** (in-process, unchanged);
  only when the registry lacks the session does it fall back to the
  durable Host snapshot described above.
- **`SessionStore`'s state-backed event helpers** were never on the wire
  path and are not the replay source; the Host is.

## [0.4.17] - 2026-09-18

### Changed

- Requires `ask-core >= 0.12.0` for the decision vocabulary
  (`Ask::Decision`, `Ask::DecisionProvider`, `Ask::DecisionResult`).
  Nothing else changed.

## [0.4.13] - 2026-09-10

### Fixed

- **A stopped host no longer deletes its successor's socket.** The
  socket path is a fixed, shared name and hosts overlap: `#start`
  unlinks a stale path, so a successor launched over a live host takes
  the name, and the predecessor's later exit (idle timeout, crash,
  manual kill) ran an unconditional `rm_f` that deleted the path the
  successor was listening on. Every client after that got ENOENT while
  the successor stayed alive and looked healthy. The server now records
  the (device, inode) it bound and removes the file only if it is still
  that one. Seen in the wild: a host orphaned two weeks earlier was
  killed during a routine cleanup and silently broke the host that had
  replaced it.

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
