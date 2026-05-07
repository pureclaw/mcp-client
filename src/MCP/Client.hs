-- | MCP client library.
--
-- Provides a complete client implementation of the Model Context Protocol.
-- Re-exports core protocol types from @mcp-types@ alongside client-specific
-- modules.
--
-- Typical usage:
--
-- @
-- import MCP.Client
--
-- main :: IO ()
-- main =
--   withStdioTransport (proc "my-mcp-server" []) $ \\transport ->
--     withClientSession transport defaultClientConfig $ \\session -> do
--       result <- initialize session
--       tools <- listTools session Nothing
--       print tools
-- @
module MCP.Client (
  -- * Error types
  module MCP.Client.Error,

  -- * Transport
  module MCP.Client.Transport,
  module MCP.Client.Transport.Stdio,

  -- * Session management
  module MCP.Client.Session,

  -- * Configuration
  module MCP.Client.Config,

  -- * API operations
  module MCP.Client.API,
) where

import MCP.Client.API
import MCP.Client.Config
import MCP.Client.Error
import MCP.Client.Session
import MCP.Client.Transport
import MCP.Client.Transport.Stdio
