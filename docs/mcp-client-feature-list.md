# MCP Client Library Feature List

Comprehensive feature inventory derived from the three most widely used MCP client
implementations: the official **TypeScript SDK**, the official **Python SDK**, and the
official **Rust SDK (rmcp)**.

---

## 1. Transport Layer

### 1.1 Supported Transports

| Transport | TypeScript | Python | Rust |
|-----------|-----------|--------|------|
| **Stdio** (spawn child process) | `StdioClientTransport` | `stdio_client()` ctx mgr | `TokioChildProcess::new(Command)` |
| **Streamable HTTP** (POST + SSE) | `StreamableHTTPClientTransport` | `streamable_http_client()` ctx mgr | `StreamableHttpClientTransport` |
| **SSE (legacy HTTP+SSE)** | `SSEClientTransport` (deprecated) | `sse_client()` ctx mgr | Via Streamable HTTP |
| **WebSocket** | Removed | `websocket_client()` ctx mgr | Via `SinkStreamTransport` adapter |
| **Custom / generic** | `Transport` interface | `(ReadStream, WriteStream)` pair | `IntoTransport` trait (auto-converts from AsyncRead/Write, Sink/Stream, etc.) |

### 1.2 Transport Abstraction

All three SDKs define a transport abstraction that decouples session logic from the
wire protocol:

- **TypeScript**: `Transport` interface with `start()`, `send(message, options?)`,
  `close()`, plus `onmessage`/`onerror`/`onclose` callbacks. `TransportSendOptions`
  carries `relatedRequestId`, `resumptionToken`, and `onresumptiontoken`.
- **Python**: Async context managers yielding `(ReadStream[SessionMessage | Exception],
  WriteStream[SessionMessage])` tuples. Session operates on streams, fully decoupled
  from transport.
- **Rust**: `Transport<R>` trait with `send()`, `receive()`, `close()` parameterized by
  `ServiceRole`. `IntoTransport` trait provides implicit conversions from duplex types
  (AsyncRead+AsyncWrite, Sink+Stream, Worker).

### 1.3 Connection Lifecycle

| Feature | TypeScript | Python | Rust |
|---------|-----------|--------|------|
| Graceful shutdown sequence | Close stdin → 2s → SIGTERM → 2s → SIGKILL | Close stdin → 2s → SIGTERM/SIGKILL | `close()` with 5s drain, `cancel()` with 2s drain |
| Windows-specific handling | Process hiding, Job Object cleanup | Safe env-var allowlists, Job Object termination | N/A |
| Session ID tracking | Via `sessionId` on transport | Via `mcp-session-id` response header | Transport-dependent |
| Session termination | `terminateSession()` sends HTTP DELETE | `terminate_session()` sends DELETE | Transport close |
| Quit/shutdown reason | N/A | N/A | `quit_reason` on `RunningService` |

### 1.4 Reconnection & Resumability

| Feature | TypeScript | Python | Rust |
|---------|-----------|--------|------|
| Auto-reconnect | Exponential backoff (1s initial, 1.5x, max 30s, max 2 retries) | Max 2 attempts, 1s default delay | Transport-level concern |
| Server `retry` field override | Yes (from SSE) | Yes (from SSE) | Transport-dependent |
| Last-Event-ID resumption | Yes (`resumeStream(lastEventId)`) | Yes (Last-Event-ID tracking) | Transport-dependent |
| Resumption tokens | Yes (`onresumptiontoken` callback) | No | No |
| Skip re-init on reconnect | Yes (preserves `sessionId` + negotiated version) | No | No |
| Custom reconnection scheduler | Yes (for serverless/mobile) | No | No |

---

## 2. Session / Client Layer

### 2.1 Initialization Handshake

All three SDKs implement the same protocol handshake:

1. Client sends `initialize` request with `protocolVersion`, `clientInfo`
   (`Implementation`), and `ClientCapabilities`.
2. Server responds with `InitializeResult` containing `protocolVersion`,
   `serverInfo`, `ServerCapabilities`, and optional `instructions`.
3. Client sends `notifications/initialized` notification.
4. Session is now active.

| Feature | TypeScript | Python | Rust |
|---------|-----------|--------|------|
| Entry point | `client.connect(transport)` | `await session.initialize()` | `handler.serve(transport).await` |
| Version negotiation | Client proposes, server accepts or counters | Validates compatibility | Validates compatibility |
| Auto-capability detection | Manual registration | From constructor callbacks (sampling, elicitation, roots) | From `ClientHandler` trait impl |
| Init error variants | Generic `McpError` | `RuntimeError` on version mismatch | `ClientInitializeError` with 7 variants |
| Handle pings during init | N/A | N/A | Yes (auto-responds) |

### 2.2 Request/Response Correlation

| Feature | TypeScript | Python | Rust |
|---------|-----------|--------|------|
| ID generation | Incrementing `_requestMessageId` counter | Incrementing `_request_id` integer | `AtomicU32` (backed by `AtomicU64`) |
| Pending request tracking | `Map<number, handler>` | `dict[RequestId, ResponseStream]` | `HashMap<RequestId, Responder>` |
| ID normalization | N/A | `_normalize_request_id()` (string→int) | N/A |
| Concurrent dispatch | Per-request Promise | Per-request `MemoryObjectStream` | Per-request `Responder` + `JoinSet` |

### 2.3 Timeout Handling

| Feature | TypeScript | Python | Rust |
|---------|-----------|--------|------|
| Per-request timeout | Yes (default 60s) | Yes (`read_timeout_seconds`) | Yes (`PeerRequestOptions.timeout`) |
| Session-level default | Yes (constructor option) | Yes (constructor arg) | No (per-request only) |
| Max total timeout | Yes (optional ceiling) | No | No |
| Timeout reset on progress | Yes (configurable) | No | No |
| Auto-cancel on timeout | Yes (`notifications/cancelled`) | No | Yes (`CancelledNotification` with "request timeout" reason) |

---

## 3. Protocol Operations (Client → Server)

### 3.1 Core Requests

| Operation | Method | TypeScript | Python | Rust |
|-----------|--------|-----------|--------|------|
| `initialize` | Automatic | `connect()` | `initialize()` | `serve().await` |
| `ping` | `ping` | `ping()` | `send_ping()` | `peer.send_ping()` |
| `tools/list` | Paginated | `listTools(params?, opts?)` | `list_tools(params?)` | `list_tools(params?)` |
| `tools/call` | With args | `callTool(params, opts?)` | `call_tool(name, args)` | `call_tool(params)` |
| `resources/list` | Paginated | `listResources(params?, opts?)` | `list_resources(params?)` | `list_resources(params?)` |
| `resources/read` | By URI | `readResource(params, opts?)` | `read_resource(uri)` | `read_resource(params)` |
| `resources/subscribe` | By URI | `subscribeResource(params, opts?)` | `subscribe_resource(params)` | `subscribe(params)` |
| `resources/unsubscribe` | By URI | `unsubscribeResource(params, opts?)` | `unsubscribe_resource(params)` | `unsubscribe(params)` |
| `resources/templates/list` | Paginated | `listResourceTemplates(params?, opts?)` | `list_resource_templates(params?)` | `list_resource_templates(params?)` |
| `prompts/list` | Paginated | `listPrompts(params?, opts?)` | `list_prompts(params?)` | `list_prompts(params?)` |
| `prompts/get` | By name | `getPrompt(params, opts?)` | `get_prompt(name, args)` | `get_prompt(params)` |
| `completion/complete` | Ref + arg | `complete(params, opts?)` | `complete(ref, arg, ctx)` | `complete(params)` |
| `logging/setLevel` | Level enum | `setLoggingLevel(level, opts?)` | `set_logging_level(level)` | `set_level(params)` |

### 3.2 Pagination

| Feature | TypeScript | Python | Rust |
|---------|-----------|--------|------|
| Cursor-based pagination | Yes (all list ops) | Yes (all list ops) | Yes (all list ops) |
| Auto-paginate helpers | No | No | `list_all_tools()`, `list_all_resources()`, `list_all_resource_templates()`, `list_all_prompts()` |

### 3.3 Completion Helpers

| Feature | TypeScript | Python | Rust |
|---------|-----------|--------|------|
| Basic complete | Yes | Yes | Yes |
| Prompt completion helper | No | No | `complete_prompt_argument()`, `complete_prompt_simple()` |
| Resource completion helper | No | No | `complete_resource_argument()`, `complete_resource_simple()` |

---

## 4. Server → Client Requests

The MCP protocol defines several requests that flow from server to client. The client
must handle these if it advertises the corresponding capability.

### 4.1 Sampling (`sampling/createMessage`)

| Feature | TypeScript | Python | Rust |
|---------|-----------|--------|------|
| Registration | `setRequestHandler('sampling/createMessage', handler)` | `sampling_callback` constructor arg | `ClientHandler::create_message()` trait method |
| Capability auto-advertised | When handler registered | When callback provided | When trait method overridden |
| Default behavior | Not registered | Not registered | Returns `METHOD_NOT_FOUND` |

### 4.2 Roots (`roots/list`)

| Feature | TypeScript | Python | Rust |
|---------|-----------|--------|------|
| Registration | `setRequestHandler('roots/list', handler)` | `list_roots_callback` constructor arg | `ClientHandler::list_roots()` trait method |
| Default behavior | Not registered | Not registered | Returns empty list |
| Change notification | `sendRootsListChanged()` | `send_roots_list_changed()` | `notify_roots_list_changed()` |

### 4.3 Elicitation (`elicitation/create`)

| Feature | TypeScript | Python | Rust |
|---------|-----------|--------|------|
| Registration | `setRequestHandler('elicitation/create', handler)` | `elicitation_callback` constructor arg | `ClientHandler::create_elicitation()` trait method |
| Form mode | Yes | Yes | Yes |
| URL mode | Yes | Yes | Yes |
| Default behavior | Not registered | Not registered | Declines (action = "decline") |

---

## 5. Notifications

### 5.1 Client → Server Notifications

| Notification | TypeScript | Python | Rust |
|-------------|-----------|--------|------|
| `notifications/initialized` | Automatic (during `connect()`) | Automatic (during `initialize()`) | Automatic (during `serve()`) |
| `notifications/cancelled` | Automatic (on abort/timeout) | On `CancelScope` cancel | `notify_cancelled(params)` / automatic on timeout |
| `notifications/progress` | Via progress token | `send_progress_notification()` | `notify_progress(params)` |
| `notifications/roots/list_changed` | `sendRootsListChanged()` | `send_roots_list_changed()` | `notify_roots_list_changed()` |

### 5.2 Server → Client Notification Handlers

| Notification | TypeScript | Python | Rust |
|-------------|-----------|--------|------|
| `notifications/cancelled` | Built-in handler | Built-in handler | `on_cancelled()` trait method |
| `notifications/progress` | `_progressHandlers` map | `_progress_callbacks` dict | `on_progress()` trait method |
| `notifications/message` (logging) | Via `setNotificationHandler` | `logging_callback` constructor arg | `on_logging_message()` trait method |
| `notifications/resources/updated` | Via `setNotificationHandler` | Via `message_handler` | `on_resource_updated()` trait method |
| `notifications/resources/list_changed` | Auto-refresh (debounced) | Via `message_handler` | `on_resource_list_changed()` trait method |
| `notifications/tools/list_changed` | Auto-refresh (debounced) | Via `message_handler` | `on_tool_list_changed()` trait method |
| `notifications/prompts/list_changed` | Auto-refresh (debounced) | Via `message_handler` | `on_prompt_list_changed()` trait method |
| Custom/unknown notifications | `fallbackNotificationHandler` | `message_handler` catch-all | `on_custom_notification()` trait method |

### 5.3 List-Change Auto-Refresh

| Feature | TypeScript | Python | Rust |
|---------|-----------|--------|------|
| Auto-refetch on list_changed | Yes (`_setupListChangedHandlers`) | No | No |
| Debouncing | Yes (within event loop tick) | N/A | N/A |
| Callback on refresh | Yes (`(error, items)` callbacks) | N/A | N/A |

---

## 6. Progress Reporting

| Feature | TypeScript | Python | Rust |
|---------|-----------|--------|------|
| Progress token generation | Uses message ID | Uses request ID | `AtomicU32ProgressTokenProvider` |
| Attach token to request | Via `_meta.progressToken` | Via `_meta.progressToken` | `set_progress_token()` on request |
| Progress callback registration | `_progressHandlers` map | `progress_callback` on `call_tool()` | `on_progress()` trait method |
| Progress fields | `progressToken`, `progress`, `total`, `message` | Same | Same |
| Timeout reset on progress | Yes (configurable) | No | No |

---

## 7. Cancellation

| Feature | TypeScript | Python | Rust |
|---------|-----------|--------|------|
| Mechanism | `AbortSignal` / `AbortController` | `anyio.CancelScope` | `CancellationToken` per-request |
| Cancel notification | `notifications/cancelled` with requestId + reason | `CancelledNotification` | `CancelledNotification` with reason |
| Request handle | Per-request `AbortController` | `RequestResponder` with cancel scope | `RequestHandle` with `cancel(reason?)` |
| Cancellable send | Via `options.signal` | Via scope cancellation | `send_cancellable_request()` returns `RequestHandle` |
| Auto-cancel on timeout | Yes | No | Yes |

---

## 8. Error Handling

### 8.1 Error Types

| Error Category | TypeScript | Python | Rust |
|---------------|-----------|--------|------|
| Protocol errors | `ProtocolError` (JSON-RPC codes) | JSON-RPC error with standard codes | `ServiceError::McpError` |
| SDK-level errors | `SdkError` (timeout, connection closed) | `MCPError` (timeout, connection closed) | `ServiceError` enum (7 variants) |
| Transport errors | Via `onerror` callback | Exception in read stream | `ServiceError::TransportSend/TransportClosed` |
| Tool errors (non-exception) | `CallToolResult.isError` flag | `CallToolResult.isError` flag | `CallToolResult.is_error` field |
| Init errors | Generic `McpError` | `RuntimeError` | `ClientInitializeError` (7 variants) |
| Unexpected response | Via handler rejection | N/A | `ServiceError::UnexpectedResponse` |
| Cancelled | Via AbortError | Via scope cancel | `ServiceError::Cancelled` |

### 8.2 JSON-RPC Error Codes

Standard codes used across all SDKs: `PARSE_ERROR` (-32700), `INVALID_REQUEST` (-32600),
`METHOD_NOT_FOUND` (-32601), `INVALID_PARAMS` (-32602), `INTERNAL_ERROR` (-32603).
Custom MCP code: `SERVER_NOT_INITIALIZED` (-32002), `REQUEST_TIMEOUT` (-32001, TS only).

---

## 9. Concurrency

| Feature | TypeScript | Python | Rust |
|---------|-----------|--------|------|
| Async model | Promises / async-await | anyio task groups | Tokio tasks / JoinSet |
| Independent request IDs | Yes | Yes | Yes (atomic) |
| Per-request state tracking | AbortController + timeout | CancelScope + response stream | Responder + CancellationToken |
| Receive loop | Event-driven (transport callbacks) | `anyio` task group background loop | Spawned Tokio task |

---

## 10. Type Safety & Schema Validation

| Feature | TypeScript | Python | Rust |
|---------|-----------|--------|------|
| Protocol message types | TypeScript interfaces | Pydantic models | Rust structs + serde |
| Tool input schema | Standard Schema (Zod v4, Valibot, ArkType) | JSON Schema via Pydantic | JSON Schema via `schemars` |
| Tool output validation | Yes (cached compiled validators) | Schema mismatch → RuntimeError | Compile-time via derive macros |
| JSON Schema generation | Via Standard Schema | Via Pydantic | Via `schemars` (2020-12 draft) |
| Capability enforcement | Optional strict mode | No | Via capability builder |
| Graceful degradation | Returns empty lists when capability missing | N/A | Capabilities gate operations |

---

## 11. Authentication & OAuth

### 11.1 OAuth 2.0

| Feature | TypeScript | Python | Rust |
|---------|-----------|--------|------|
| Authorization Code + PKCE | Yes | Yes | Yes (SHA256) |
| Client Credentials flow | Via `prepareTokenRequest` | Not explicit | Yes (SEP-1046: `ClientSecret`, `PrivateKeyJwt`) |
| RFC 9728 Protected Resource Metadata | Yes | Yes | Yes (via RFC 8414 patterns) |
| RFC 8414 AS metadata discovery | Yes | Yes | Yes (multi-pattern fallback) |
| OpenID Connect discovery | Yes | N/A | N/A |
| RFC 7591 Dynamic Client Registration | Yes | Yes | Yes |
| URL-based Client IDs | Yes (SEP-991) | Yes (fallback) | Yes (fallback) |
| Token refresh | Yes (automatic) | Yes (automatic) | Yes (automatic, 30s buffer) |
| 401 retry | Yes (single retry after refresh) | Yes | Yes |
| 403 upscope | Yes (via `auth()`) | Yes (re-authorization) | Yes (configurable retry limits) |
| Client auth methods | `client_secret_basic`, `client_secret_post`, `none` | Basic, POST, none | Basic, POST, none, PrivateKeyJwt |
| Token/credential storage | `OAuthClientProvider` interface | `TokenStorage` protocol | `CredentialStore` trait |
| State parameter CSRF | N/A | Yes | Yes (TTL-based expiration) |

### 11.2 Other Auth

| Feature | TypeScript | Python | Rust |
|---------|-----------|--------|------|
| Simple Bearer token | `AuthProvider.token()` | N/A | `AuthorizedHttpClient` wrapper |
| Middleware composition | `withOAuth(provider)` HOF | N/A | N/A |

---

## 12. Middleware & Extensibility

| Feature | TypeScript | Python | Rust |
|---------|-----------|--------|------|
| Middleware pattern | HOF: `(next: FetchLike) => FetchLike` | No formal middleware | No formal middleware |
| Built-in middleware | `withOAuth`, `withLogging` | N/A | N/A |
| Composability | `applyMiddlewares(...middleware)` | N/A | N/A |
| Custom request handler | `fallbackRequestHandler` | `message_handler` catch-all | `on_custom_request()` trait |
| Custom notification handler | `fallbackNotificationHandler` | `message_handler` catch-all | `on_custom_notification()` trait |

---

## 13. Experimental / Advanced Features

| Feature | TypeScript | Python | Rust |
|---------|-----------|--------|------|
| Task-based execution | `experimental.tasks` | `experimental_task_handlers` | Not explicit |
| Direct serve (skip init) | N/A | N/A | `serve_directly()` / `serve_directly_with_ct()` |
| Local-only mode (no Send) | N/A | N/A | `local` feature flag (non-Send futures) |
| Notification debouncing | Yes (list-change notifications) | No | No |

---

## 14. Complete Feature Checklist

This is the canonical checklist for evaluating MCP client completeness:

### Transport
- [ ] Stdio transport (spawn child process, manage lifecycle)
- [ ] Streamable HTTP transport (POST JSON-RPC, receive SSE responses)
- [ ] Legacy SSE transport (optional, deprecated)
- [ ] WebSocket transport (optional)
- [ ] Transport abstraction interface/trait
- [ ] Graceful shutdown (signal cascade: close stdin → SIGTERM → SIGKILL)
- [ ] Session ID tracking
- [ ] Reconnection with backoff
- [ ] Stream resumability (Last-Event-ID)

### Session
- [ ] Initialize handshake (send initialize, receive result, send initialized)
- [ ] Protocol version negotiation
- [ ] Capability exchange (advertise client caps, receive server caps)
- [ ] JSON-RPC request ID generation and correlation
- [ ] Per-request timeout with configurable default
- [ ] Concurrent request support (multiple in-flight requests)

### Client → Server Requests
- [ ] `ping`
- [ ] `tools/list` (with pagination)
- [ ] `tools/call` (with arguments)
- [ ] `resources/list` (with pagination)
- [ ] `resources/read`
- [ ] `resources/subscribe`
- [ ] `resources/unsubscribe`
- [ ] `resources/templates/list` (with pagination)
- [ ] `prompts/list` (with pagination)
- [ ] `prompts/get` (with arguments)
- [ ] `completion/complete`
- [ ] `logging/setLevel`

### Server → Client Request Handlers
- [ ] `sampling/createMessage` handler
- [ ] `roots/list` handler
- [ ] `elicitation/create` handler (form + URL modes)

### Client → Server Notifications
- [ ] `notifications/initialized` (automatic)
- [ ] `notifications/cancelled`
- [ ] `notifications/progress`
- [ ] `notifications/roots/list_changed`

### Server → Client Notification Handlers
- [ ] `notifications/cancelled` handler
- [ ] `notifications/progress` handler
- [ ] `notifications/message` (logging) handler
- [ ] `notifications/resources/updated` handler
- [ ] `notifications/resources/list_changed` handler
- [ ] `notifications/tools/list_changed` handler
- [ ] `notifications/prompts/list_changed` handler
- [ ] Catch-all / fallback notification handler

### Progress & Cancellation
- [ ] Progress token generation and attachment
- [ ] Progress callback/handler registration
- [ ] Request cancellation with notification
- [ ] Cancellation token per request

### Error Handling
- [ ] JSON-RPC error response parsing
- [ ] Transport error propagation
- [ ] Timeout errors
- [ ] Connection closed errors
- [ ] Tool error flag (`isError`) distinct from exceptions

### Pagination Helpers
- [ ] Cursor-based pagination on all list operations
- [ ] Auto-paginate helpers (fetch all pages)

### Authentication
- [ ] OAuth 2.0 Authorization Code + PKCE
- [ ] Token refresh
- [ ] RFC 8414/9728 metadata discovery
- [ ] RFC 7591 Dynamic Client Registration
- [ ] Bearer token injection
- [ ] Credential/token storage abstraction

### Type Safety
- [ ] Typed protocol messages (all requests, responses, notifications)
- [ ] JSON Schema for tool input/output
- [ ] Capability-aware operation gating
