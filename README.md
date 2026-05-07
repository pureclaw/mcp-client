# mcp-client

A Haskell client library for the [Model Context Protocol](https://modelcontextprotocol.io/) (MCP).

MCP is a protocol that enables seamless communication between AI models and external tools, resources, and services. This library provides a typed client implementation supporting MCP protocol version 2025-06-18 with a stdio transport for subprocess-based integrations.

## Quick start

```haskell
import MCP.Client

main :: IO ()
main =
  withStdioTransport (proc "my-mcp-server" []) $ \transport ->
    withClientSession transport defaultClientConfig $ \session -> do
      _ <- initialize session
      tools <- listTools session Nothing
      print tools
```

## Features

- **Session management** — initialize/shutdown lifecycle with automatic cleanup
- **Full MCP API** — tools, resources, prompts, completions, logging, subscriptions
- **Stdio transport** — launch MCP servers as subprocesses and communicate over stdin/stdout
- **Typed requests** — JSON-RPC request/response with automatic (de)serialization
- **Server callbacks** — handle server-initiated requests (sampling, roots, elicitation) and notifications (progress, logging, resource updates)
- **Timeout support** — configurable per-request timeouts

## Modules

| Module | Description |
|--------|-------------|
| `MCP.Client` | Top-level re-export of all client modules |
| `MCP.Client.Session` | Session lifecycle (`withClientSession`, `initialize`) |
| `MCP.Client.API` | MCP operations (`listTools`, `callTool`, `listResources`, etc.) |
| `MCP.Client.Config` | Client configuration and callbacks |
| `MCP.Client.Transport` | Transport abstraction |
| `MCP.Client.Transport.Stdio` | Stdio transport for subprocess servers |
| `MCP.Client.Error` | Error types (`MCPClientError`) |

## Building

Requires [Nix](https://nixos.org/) with flakes enabled.

```bash
# Enter development shell
nix develop

# Build
nix develop --command cabal build

# Run tests
nix develop --command cabal test

# Run tests with coverage
nix develop --command cabal test --enable-coverage
```

A `Makefile` is provided for convenience: `make build`, `make test`, `make coverage`, `make lint`.

## Coverage

Coverage reports are generated on every CI run and published to GitHub Pages:

**[View coverage reports](https://pureclaw.github.io/mcp-client/coverage/)**

Coverage thresholds are enforced via `.coverage-thresholds.json`.

## License

BSD-3-Clause. See [LICENSE](LICENSE) for details.
