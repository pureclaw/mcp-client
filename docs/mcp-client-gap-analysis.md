# Haskell MCP Client — Gap Analysis

Gap analysis comparing the existing `mcp-types` and `mcp` (server) packages in this
repository against the feature set required for a complete MCP client implementation,
as defined by the TypeScript, Python, and Rust reference SDKs.

---

## What Already Exists

The repository provides a strong foundation. The `mcp-types` package already defines
all protocol types needed by both clients and servers:

### Fully Reusable from `mcp-types`

| Component | Module | Notes |
|-----------|--------|-------|
| All MCP data types | `MCP.Types` | `Content`, `Resource`, `Tool`, `Prompt`, `Capability`, `Role`, `LoggingLevel`, `Implementation`, `Root`, etc. |
| All request/response types | `MCP.Protocol` | `InitializeRequest/Result`, `ListToolsRequest/Result`, `CallToolRequest/Result`, `CreateMessageRequest/Result`, `ElicitRequest/Result`, etc. |
| All notification types | `MCP.Protocol` | `CancelledNotification`, `ProgressNotification`, `InitializedNotification`, all list-changed notifications, `LoggingMessageNotification`, `ResourceUpdatedNotification` |
| Client & server request unions | `MCP.Protocol` | `ClientRequest` (13 constructors), `ServerRequest` (4 constructors), `ClientNotification` (4), `ServerNotification` (7) |
| Capability types | `MCP.Types` | `ClientCapabilities`, `ServerCapabilities` and all sub-capability types |
| Pagination types | `MCP.Protocol` | `Cursor`, `nextCursor` fields on all list results |
| Progress types | `MCP.Types`/`MCP.Protocol` | `ProgressToken`, `ProgressNotification`/`ProgressParams` |
| Elicitation schema types | `MCP.Protocol` | `PrimitiveSchemaDefinition` variants, `ElicitRequest/Result` |
| Protocol version constant | `MCP.Protocol` | `pROTOCOL_VERSION = "2025-06-18"` |
| JSON-RPC error codes | `MCP.Protocol` | `sERVER_NOT_INITIALIZED`, standard codes via `jsonrpc` dependency |
| Aeson serialization | `MCP.Aeson` | `mcpParseOpts` with `omitNothingFields`, field label normalization |
| JSON-RPC 2.0 layer | `jsonrpc` dep | `RequestId`, message framing |

### Partially Reusable Patterns from `mcp` (Server)

| Component | Module | Reusability |
|-----------|--------|-------------|
| `ProcessResult` GADT | `MCP.Server.Common` | Pattern (success/error/client-input) is useful for client-side response handling, but the concrete type is server-specific |
| `processMethod` routing | `MCP.Server.Common` | Server-side only; client needs inverse (dispatch incoming server requests) |
| Stdio line protocol | `MCP.Server.Stdio` | Read/write loop pattern is reusable, but current impl is server-oriented |
| SSE framing | `MCP.Server.HTTP.Internal` | `JSONRPCFrame`/`JSONRPCEvent` types could be reused for parsing SSE responses on the client side |
| MVar-based synchronization | `MCP.Server.HTTP.Internal` | Pattern for `ProcessClientInput` (blocking on MVar for response) maps to client-side request/response correlation |

---

## Gaps — What Needs to Be Built

### Gap 1: Transport Abstraction

**Priority: Critical**

No transport abstraction exists. The server hardcodes Servant (HTTP) and direct
Handle I/O (stdio). A client needs a transport interface that decouples session
logic from the wire protocol.

**What to build:**

```haskell
-- A transport abstraction (typeclass or record-of-functions)
data Transport = Transport
  { transportSend    :: JSONRPCMessage -> IO ()
  , transportReceive :: IO (Maybe JSONRPCMessage)  -- Nothing on EOF/close
  , transportClose   :: IO ()
  }
```

Or as a typeclass:

```haskell
class MCPTransport t where
  send    :: t -> JSONRPCMessage -> IO ()
  receive :: t -> IO (Maybe JSONRPCMessage)
  close   :: t -> IO ()
```

**Transport implementations needed (in priority order):**

1. **Stdio transport** — Spawn a child process, communicate via stdin/stdout with
   newline-delimited JSON. Must handle graceful shutdown (close stdin → SIGTERM →
   SIGKILL). This is the most commonly used client transport.

2. **Streamable HTTP transport** — POST JSON-RPC requests, receive SSE response
   streams. Must handle session ID tracking (`mcp-session-id` header), and
   optionally reconnection with Last-Event-ID.

3. **Custom transport** — The abstraction itself enables this.

**Reference:** TypeScript `Transport` interface, Python `(ReadStream, WriteStream)`
pair, Rust `Transport<R>` trait + `IntoTransport`.

---

### Gap 2: Client Session Manager

**Priority: Critical**

No client session type exists. The server has `MCPServerState` and `MCPServerT`,
but nothing equivalent for the client side.

**What to build:**

```haskell
data ClientSession = ClientSession
  { csTransport          :: Transport
  , csServerCapabilities :: IORef (Maybe ServerCapabilities)
  , csServerInfo         :: IORef (Maybe Implementation)
  , csInstructions       :: IORef (Maybe Text)
  , csNextRequestId      :: IORef Int
  , csPendingRequests    :: IORef (IntMap (MVar (Either JSONRPCError Value)))
  , csInitialized        :: IORef Bool
  , csRequestHandlers    :: ClientRequestHandlers  -- for server→client requests
  , csNotificationHandlers :: ClientNotificationHandlers
  }
```

**Key behaviors:**
- `initialize :: ClientSession -> ClientInfo -> ClientCapabilities -> IO InitializeResult`
  — Sends `initialize`, validates response, sends `initialized` notification
- Protocol version negotiation (compare `pROTOCOL_VERSION` with server response)
- Capability storage for later gating of operations
- Receive loop running in a background thread, dispatching responses by request ID
  and routing incoming server requests/notifications to handlers

**Reference:** TypeScript `Client` class, Python `ClientSession`, Rust
`Peer<RoleClient>` + `RunningService`.

---

### Gap 3: Request/Response Correlation

**Priority: Critical**

The server uses `mcp_pending_responses :: IntMap (MVar Value)` for
`ProcessClientInput` — this exact pattern is needed for general client request
tracking, but inverted (client sends request, blocks on MVar until server responds).

**What to build:**
- Atomic request ID counter (`IORef Int` or `TVar Int`)
- `IntMap (MVar (Either JSONRPCError Value))` for pending requests
- Background receive loop that:
  - Matches response IDs to pending MVars
  - Routes incoming `ServerRequest` messages to handlers
  - Routes incoming `ServerNotification` messages to notification handlers
- Timeout support per request (e.g., `System.Timeout.timeout`)

**Reference:** All three SDKs use this pattern with language-appropriate concurrency
primitives.

---

### Gap 4: Client API Functions

**Priority: Critical**

No client-side API functions exist. Need typed wrapper functions for every
client→server operation.

**What to build:**

```haskell
-- Core operations
ping              :: ClientSession -> IO Result
listTools         :: ClientSession -> Maybe Cursor -> IO ListToolsResult
callTool          :: ClientSession -> Text -> Maybe (Map Text Value) -> IO CallToolResult
listResources     :: ClientSession -> Maybe Cursor -> IO ListResourcesResult
readResource      :: ClientSession -> Text -> IO ReadResourceResult
subscribeResource :: ClientSession -> Text -> IO Result
unsubscribeResource :: ClientSession -> Text -> IO Result
listResourceTemplates :: ClientSession -> Maybe Cursor -> IO ListResourceTemplatesResult
listPrompts       :: ClientSession -> Maybe Cursor -> IO ListPromptsResult
getPrompt         :: ClientSession -> Text -> Maybe (Map Text Value) -> IO GetPromptResult
complete          :: ClientSession -> Reference -> CompletionArgument -> IO CompleteResult
setLoggingLevel   :: ClientSession -> LoggingLevel -> IO Result

-- Notification sending
sendRootsListChanged :: ClientSession -> IO ()
sendCancelled        :: ClientSession -> RequestId -> Maybe Text -> IO ()
sendProgress         :: ClientSession -> ProgressToken -> Double -> Maybe Double -> Maybe Text -> IO ()
```

All protocol types (`ListToolsResult`, `CallToolResult`, etc.) already exist in
`MCP.Protocol`. This gap is about the client-side send-request-and-await-response
plumbing.

**Reference:** TypeScript `Client` methods, Python `ClientSession` methods, Rust
`Peer<RoleClient>` methods.

---

### Gap 5: Server → Client Request Handling

**Priority: High**

The server can send requests to clients (sampling, roots, elicitation). A client
must be able to register handlers for these.

**What to build:**

```haskell
data ClientRequestHandlers = ClientRequestHandlers
  { onCreateMessage :: Maybe (CreateMessageParams -> IO CreateMessageResult)
  , onListRoots     :: Maybe (ListRootsParams -> IO ListRootsResult)
  , onElicit        :: Maybe (ElicitParams -> IO ElicitResult)
  , onPing          :: PingParams -> IO Result  -- default: return empty Result
  }
```

These handlers are invoked by the background receive loop when it encounters an
incoming `ServerRequest`. The client must:
- Parse the request
- Dispatch to the registered handler (or return METHOD_NOT_FOUND)
- Send the response back over the transport

The protocol types for all of these already exist in `MCP.Protocol`.

**Reference:** TypeScript `setRequestHandler()`, Python constructor callbacks, Rust
`ClientHandler` trait.

---

### Gap 6: Notification Dispatch

**Priority: High**

Server sends notifications to the client (progress, logging, resource updates,
list changes). The client needs a dispatch mechanism.

**What to build:**

```haskell
data ClientNotificationHandlers = ClientNotificationHandlers
  { onProgress          :: Maybe (ProgressParams -> IO ())
  , onLoggingMessage    :: Maybe (LoggingMessageParams -> IO ())
  , onResourceUpdated   :: Maybe (ResourceUpdatedParams -> IO ())
  , onResourceListChanged :: Maybe (IO ())
  , onToolListChanged     :: Maybe (IO ())
  , onPromptListChanged   :: Maybe (IO ())
  , onCancelled           :: Maybe (CancelledParams -> IO ())
  , onFallback            :: Maybe (Text -> Value -> IO ())  -- method + params
  }
```

All notification param types already exist in `MCP.Protocol`.

**Reference:** TypeScript `setNotificationHandler()` + `fallbackNotificationHandler`,
Python callbacks, Rust `ClientHandler` trait notification methods.

---

### Gap 7: Progress Reporting

**Priority: Medium**

**What to build:**
- Progress token generation (counter or use request ID)
- Attaching `_meta.progressToken` to outbound requests
- Routing incoming `ProgressNotification` to per-request callbacks
- Optional: timeout reset on progress receipt

The `ProgressToken` and `ProgressNotification`/`ProgressParams` types already exist.

**Reference:** All three SDKs support this. Rust's `AtomicU32ProgressTokenProvider`
is a good model.

---

### Gap 8: Request Cancellation

**Priority: Medium**

**What to build:**
- Per-request cancellation mechanism (e.g., `Async.cancel` or a `TMVar` flag)
- Sending `CancelledNotification` with request ID and reason when cancelling
- Handling incoming `CancelledNotification` from server (cancel pending response)
- Auto-cancel on timeout (send notification before raising timeout error)

The `CancelledNotification`/`CancelledParams` types already exist.

**Reference:** TypeScript `AbortSignal`, Python `CancelScope`, Rust
`CancellationToken` + `RequestHandle`.

---

### Gap 9: Timeout Handling

**Priority: Medium**

**What to build:**
- Per-request timeout (wrapping `System.Timeout.timeout` around the MVar wait)
- Session-level default timeout
- Optional: timeout reset on progress notification
- Proper cleanup on timeout: remove from pending map, send cancellation notification

**Reference:** TypeScript (60s default, progress resets), Python (`anyio.fail_after`),
Rust (`PeerRequestOptions.timeout`).

---

### Gap 10: Auto-Pagination Helpers

**Priority: Low**

**What to build:**

```haskell
listAllTools     :: ClientSession -> IO [Tool]
listAllResources :: ClientSession -> IO [Resource]
listAllPrompts   :: ClientSession -> IO [Prompt]
listAllResourceTemplates :: ClientSession -> IO [ResourceTemplate]
```

Each iterates with the cursor until `nextCursor` is `Nothing`.

**Reference:** Rust's `list_all_tools()`, `list_all_resources()`, etc. Neither
TypeScript nor Python provides these, but they're very ergonomic.

---

### Gap 11: Completion Helpers

**Priority: Low**

**What to build:**

```haskell
completePromptArgument   :: ClientSession -> Text -> Text -> Text -> IO CompletionResult
completeResourceArgument :: ClientSession -> Text -> Text -> Text -> IO CompletionResult
```

Convenience wrappers that construct the `Reference` and `CompletionArgument` for
common completion scenarios.

**Reference:** Rust's `complete_prompt_argument()`, `complete_resource_argument()`,
`complete_prompt_simple()`, `complete_resource_simple()`.

---

### Gap 12: Authentication / OAuth

**Priority: Low (for initial release)**

**What to build (eventually):**
- OAuth 2.0 Authorization Code + PKCE flow
- RFC 8414/9728 metadata discovery
- RFC 7591 Dynamic Client Registration
- Token refresh
- Bearer token injection into HTTP transport
- Credential storage abstraction

The README already references `oauth2-server` on Hackage for server-side OAuth.
Client-side OAuth is a separate concern.

**Not needed for initial release** — stdio transport (the most common client
transport) doesn't use auth. HTTP auth can be added later or delegated to the
user (pass headers to the HTTP transport constructor).

**Reference:** All three SDKs have comprehensive OAuth support.

---

### Gap 13: Error Types

**Priority: Medium**

**What to build:**

```haskell
data MCPClientError
  = TransportError Text
  | TimeoutError RequestId
  | ConnectionClosed
  | ProtocolError Int Text          -- JSON-RPC error code + message
  | VersionMismatch Text Text       -- expected, got
  | NotInitialized
  | CapabilityNotSupported Text     -- method name
  | CancelledError RequestId (Maybe Text)
  deriving (Show, Eq)

instance Exception MCPClientError
```

**Reference:** TypeScript `ProtocolError`/`SdkError`, Python `MCPError`, Rust
`ServiceError` (7 variants) + `ClientInitializeError` (7 variants).

---

## Proposed Package Structure

```
mcp-client/
├── mcp-client.cabal
├── src/MCP/
│   ├── Client.hs              -- Re-exports; main entry point
│   ├── Client/
│   │   ├── Session.hs         -- ClientSession, initialize, request correlation
│   │   ├── Types.hs           -- MCPClientError, ClientRequestHandlers,
│   │   │                         ClientNotificationHandlers, ClientConfig
│   │   ├── Transport.hs       -- Transport abstraction (typeclass or record)
│   │   ├── Transport/
│   │   │   ├── Stdio.hs       -- Stdio transport (spawn process)
│   │   │   └── HTTP.hs        -- Streamable HTTP transport (POST + SSE)
│   │   └── Pagination.hs      -- Auto-pagination helpers (listAll*)
└── test/
    └── ...
```

**Dependencies** (beyond `mcp-types`):
- `aeson` — JSON (already a dep)
- `async` — concurrent receive loop, cancellation
- `process` — stdio transport (spawn child process)
- `http-client` / `http-client-tls` — HTTP transport
- `stm` — `TVar`/`TMVar` for concurrent state (or `IORef` with `MVar`)
- `text`, `bytestring`, `containers` — (already deps)

---

## Implementation Priority

### Phase 1 — Minimum Viable Client
1. Transport abstraction (Gap 1)
2. Stdio transport (Gap 1)
3. Client session with init handshake (Gap 2)
4. Request/response correlation (Gap 3)
5. Client API functions (Gap 4)
6. Error types (Gap 13)
7. Basic timeout support (Gap 9)

This gives a working client that can connect to any MCP server over stdio, perform
all standard operations, and handle errors.

### Phase 2 — Full Protocol Support
8. Server→client request handlers (Gap 5)
9. Notification dispatch (Gap 6)
10. Progress reporting (Gap 7)
11. Cancellation (Gap 8)

### Phase 3 — Ergonomics & HTTP
12. Auto-pagination helpers (Gap 10)
13. Completion helpers (Gap 11)
14. Streamable HTTP transport (Gap 1)

### Phase 4 — Production Features
15. Authentication / OAuth (Gap 12)
16. Reconnection with backoff
17. Stream resumability (Last-Event-ID)

---

## Summary

| Category | Gaps | Already Have |
|----------|------|-------------|
| **Protocol types** | 0 | All types in `mcp-types` |
| **Transport** | 3 (abstraction, stdio, HTTP) | SSE framing types (partial) |
| **Session management** | 4 (session, correlation, init, receive loop) | MVar pattern from server |
| **Client API** | 1 (all operations) | All request/response types |
| **Server→client handling** | 2 (requests, notifications) | All message types |
| **Progress/cancel** | 2 | Token and notification types |
| **Error handling** | 1 (client error type) | JSON-RPC error codes |
| **Helpers** | 2 (pagination, completion) | Cursor types |
| **Auth** | 1 (OAuth) | `oauth2-server` reference |
| **Total** | **13 gaps** | Strong type foundation |

The `mcp-types` package provides an excellent foundation — roughly 2,400 lines of
protocol types that are fully reusable. The primary work is building the client
session layer, transport implementations, and the API surface that ties them
together.
