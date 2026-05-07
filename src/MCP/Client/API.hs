{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE ScopedTypeVariables #-}

module MCP.Client.API (
  -- * Client-to-server requests
  ping,
  listTools,
  callTool,
  listResources,
  readResource,
  subscribeResource,
  unsubscribeResource,
  listResourceTemplates,
  listPrompts,
  getPrompt,
  complete,
  setLoggingLevel,

  -- * Client-to-server notifications
  sendCancelled,
  sendProgress,
  sendRootsListChanged,
) where

import Control.Exception (throwIO)
import Data.Aeson (FromJSON, Value, toJSON)
import Data.Aeson qualified as Aeson
import Data.Map (Map)
import Data.Text (Text)
import Data.Text qualified as T
import JSONRPC hiding (id, method, params, result)
import MCP.Client.Error (MCPClientError (..))
import MCP.Client.Session (ClientSession)
import MCP.Client.Session qualified as Session
import MCP.Protocol
  ( CancelledParams(CancelledParams)
  , CompleteParams
  , CompleteResult
  , GetPromptParams(GetPromptParams)
  , GetPromptResult
  , ListPromptsParams(ListPromptsParams)
  , ListPromptsResult
  , ListResourceTemplatesParams(ListResourceTemplatesParams)
  , ListResourceTemplatesResult
  , ListResourcesParams(ListResourcesParams)
  , ListResourcesResult
  , ListToolsParams(ListToolsParams)
  , ListToolsResult
  , PingParams(PingParams)
  , ProgressParams
  , ReadResourceParams(ReadResourceParams)
  , ReadResourceResult
  , SetLevelParams(SetLevelParams)
  , SubscribeParams(SubscribeParams)
  , UnsubscribeParams(UnsubscribeParams)
  , CallToolParams(CallToolParams)
  , CallToolResult
  )
import MCP.Types (Cursor, LoggingLevel)

-- * Client-to-server requests

-- | Send a @ping@ request.
ping :: ClientSession -> IO ()
ping session = do
  (_ :: Value) <- sendRequestTyped session "ping" (toJSON (PingParams Nothing))
  return ()

-- | List available tools.  Pass 'Nothing' for the first page.
listTools :: ClientSession -> Maybe Cursor -> IO ListToolsResult
listTools session cursor =
  sendRequestTyped session "tools/list" (toJSON (ListToolsParams cursor))

-- | Call a tool by name with optional arguments.
callTool :: ClientSession -> Text -> Maybe (Map Text Value) -> IO CallToolResult
callTool session name args =
  sendRequestTyped session "tools/call" (toJSON (CallToolParams name args))

-- | List available resources.  Pass 'Nothing' for the first page.
listResources :: ClientSession -> Maybe Cursor -> IO ListResourcesResult
listResources session cursor =
  sendRequestTyped session "resources/list" (toJSON (ListResourcesParams cursor))

-- | Read a resource by URI.
readResource :: ClientSession -> Text -> IO ReadResourceResult
readResource session uri =
  sendRequestTyped session "resources/read" (toJSON (ReadResourceParams uri))

-- | Subscribe to updates for a resource URI.
subscribeResource :: ClientSession -> Text -> IO Value
subscribeResource session uri =
  sendRequestTyped session "resources/subscribe" (toJSON (SubscribeParams uri))

-- | Unsubscribe from updates for a resource URI.
unsubscribeResource :: ClientSession -> Text -> IO Value
unsubscribeResource session uri =
  sendRequestTyped session "resources/unsubscribe" (toJSON (UnsubscribeParams uri))

-- | List available resource templates.  Pass 'Nothing' for the first page.
listResourceTemplates :: ClientSession -> Maybe Cursor -> IO ListResourceTemplatesResult
listResourceTemplates session cursor =
  sendRequestTyped session "resources/templates/list" (toJSON (ListResourceTemplatesParams cursor))

-- | List available prompts.  Pass 'Nothing' for the first page.
listPrompts :: ClientSession -> Maybe Cursor -> IO ListPromptsResult
listPrompts session cursor =
  sendRequestTyped session "prompts/list" (toJSON (ListPromptsParams cursor))

-- | Get a prompt by name with optional arguments.
getPrompt :: ClientSession -> Text -> Maybe (Map Text Text) -> IO GetPromptResult
getPrompt session name args =
  sendRequestTyped session "prompts/get" (toJSON (GetPromptParams name args))

-- | Request autocompletion.
complete :: ClientSession -> CompleteParams -> IO CompleteResult
complete session params =
  sendRequestTyped session "completion/complete" (toJSON params)

-- | Set the server's logging level.
setLoggingLevel :: ClientSession -> LoggingLevel -> IO ()
setLoggingLevel session level = do
  _ <- Session.sendRequest session "logging/setLevel" (toJSON (SetLevelParams level))
  return ()

-- * Client-to-server notifications

-- | Notify the server that a request has been cancelled.
sendCancelled :: ClientSession -> RequestId -> Maybe Text -> IO ()
sendCancelled session req_id reason =
  Session.sendNotification session $
    NotificationMessage $
      JSONRPCNotification rPC_VERSION "notifications/cancelled" $
        toJSON (CancelledParams req_id reason)

-- | Send a progress notification to the server.
sendProgress :: ClientSession -> ProgressParams -> IO ()
sendProgress session params =
  Session.sendNotification session $
    NotificationMessage $
      JSONRPCNotification rPC_VERSION "notifications/progress" $
        toJSON params

-- | Notify the server that the client's root list has changed.
sendRootsListChanged :: ClientSession -> IO ()
sendRootsListChanged session =
  Session.sendNotification session $
    NotificationMessage $
      JSONRPCNotification rPC_VERSION "notifications/roots/list_changed" Aeson.Null

-- * Internal

sendRequestTyped :: (FromJSON a) => ClientSession -> Text -> Value -> IO a
sendRequestTyped session method params = do
  val <- Session.sendRequest session method params
  case Aeson.fromJSON val of
    Aeson.Error err -> throwIO $ DecodeError (T.pack err)
    Aeson.Success a -> return a
