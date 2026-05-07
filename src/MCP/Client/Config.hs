module MCP.Client.Config (
  ClientConfig (..),
  defaultClientConfig,
) where

import MCP.Protocol
import MCP.Types

-- | Configuration for a client session.
data ClientConfig = ClientConfig
  { config_client_info :: Implementation
  -- ^ Client name and version sent during initialization.
  , config_capabilities :: ClientCapabilities
  -- ^ Client capabilities to advertise to the server.
  , config_request_timeout_us :: Int
  -- ^ Default per-request timeout in microseconds (0 = no timeout).
  , config_on_create_message :: Maybe (CreateMessageParams -> IO CreateMessageResult)
  -- ^ Handler for server-initiated @sampling\/createMessage@ requests.
  , config_on_list_roots :: Maybe (ListRootsParams -> IO ListRootsResult)
  -- ^ Handler for server-initiated @roots\/list@ requests.
  , config_on_elicit :: Maybe (ElicitParams -> IO ElicitResult)
  -- ^ Handler for server-initiated @elicitation\/create@ requests.
  , config_on_progress :: Maybe (ProgressParams -> IO ())
  -- ^ Handler for @notifications\/progress@ from the server.
  , config_on_logging_message :: Maybe (LoggingMessageParams -> IO ())
  -- ^ Handler for @notifications\/message@ (logging) from the server.
  , config_on_resource_updated :: Maybe (ResourceUpdatedParams -> IO ())
  -- ^ Handler for @notifications\/resources\/updated@ from the server.
  , config_on_resource_list_changed :: Maybe (IO ())
  -- ^ Handler for @notifications\/resources\/list_changed@ from the server.
  , config_on_tool_list_changed :: Maybe (IO ())
  -- ^ Handler for @notifications\/tools\/list_changed@ from the server.
  , config_on_prompt_list_changed :: Maybe (IO ())
  -- ^ Handler for @notifications\/prompts\/list_changed@ from the server.
  , config_on_cancelled :: Maybe (CancelledParams -> IO ())
  -- ^ Handler for @notifications\/cancelled@ from the server.
  , config_on_fallback :: Maybe (JSONRPCMessage -> IO ())
  -- ^ Catch-all handler for unrecognized messages.
  }

-- | Sensible defaults: no handlers, 30-second timeout.
defaultClientConfig :: ClientConfig
defaultClientConfig =
  ClientConfig
    { config_client_info = Implementation "mcp-client-hs" "0.1.0" Nothing
    , config_capabilities = ClientCapabilities Nothing Nothing Nothing Nothing
    , config_request_timeout_us = 30_000_000
    , config_on_create_message = Nothing
    , config_on_list_roots = Nothing
    , config_on_elicit = Nothing
    , config_on_progress = Nothing
    , config_on_logging_message = Nothing
    , config_on_resource_updated = Nothing
    , config_on_resource_list_changed = Nothing
    , config_on_tool_list_changed = Nothing
    , config_on_prompt_list_changed = Nothing
    , config_on_cancelled = Nothing
    , config_on_fallback = Nothing
    }
