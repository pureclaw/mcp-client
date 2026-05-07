{-# LANGUAGE ScopedTypeVariables #-}

module MCP.Client.Session (
  ClientSession,
  withClientSession,
  initialize,
  sessionServerCapabilities,
  sessionServerInfo,
  sendRequest,
  sendNotification,
) where

import Control.Concurrent (forkIO, killThread)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, bracket, throwIO, try)
import Data.Aeson (FromJSON, ToJSON, Value, toJSON)
import Data.Aeson qualified as Aeson
import Data.IORef (
  IORef,
  atomicModifyIORef',
  newIORef,
  readIORef,
  writeIORef,
 )
import Data.IntMap.Strict (IntMap)
import Data.IntMap.Strict qualified as IM
import Data.Text (Text)
import Data.Text qualified as T
import JSONRPC hiding (id, method, params, result)
import MCP.Client.Config (ClientConfig (..))
import MCP.Client.Error (MCPClientError (..))
import MCP.Client.Transport (Transport (..))
import MCP.Protocol
  ( InitializeParams(..)
  , InitializeResult(..)
  , pROTOCOL_VERSION
  )
import MCP.Types
import System.Timeout (timeout)

-- | An active MCP client session over a 'Transport'.
data ClientSession = ClientSession
  { session_transport :: Transport
  , session_config :: ClientConfig
  , session_next_id :: IORef Int
  , session_pending :: IORef (IntMap (MVar (Either JSONRPCErrorInfo Value)))
  , session_server_caps :: IORef (Maybe ServerCapabilities)
  , session_server_info :: IORef (Maybe Implementation)
  , session_initialized :: IORef Bool
  , session_closed :: IORef Bool
  }

-- | Run an action with a client session.
--
-- Starts a background receive loop that dispatches server responses,
-- requests, and notifications.  On exit the receive thread is killed and
-- all pending requests are failed with 'SessionClosed'.
withClientSession :: Transport -> ClientConfig -> (ClientSession -> IO a) -> IO a
withClientSession transport cfg action = do
  session <- newSession transport cfg
  bracket
    (forkIO $ receiveLoop session)
    ( \tid -> do
        killThread tid
        writeIORef (session_closed session) True
        failAllPending session
    )
    (const $ action session)

-- | Perform the MCP initialization handshake.
--
-- Sends @initialize@, validates the server's protocol version, stores
-- the server capabilities, and sends @notifications\/initialized@.
initialize :: ClientSession -> IO InitializeResult
initialize session = do
  let cfg = session_config session
      params =
        InitializeParams
          { protocolVersion = pROTOCOL_VERSION
          , capabilities = config_capabilities cfg
          , clientInfo = config_client_info cfg
          }
  result <- sendRequest session "initialize" (toJSON params)
  case Aeson.fromJSON result of
    Aeson.Error err -> throwIO $ DecodeError (T.pack err)
    Aeson.Success (ir :: InitializeResult) -> do
      let InitializeResult{protocolVersion = sv} = ir
      if sv /= pROTOCOL_VERSION
        then throwIO $ ProtocolVersionMismatch pROTOCOL_VERSION sv
        else do
          let InitializeResult
                { capabilities = caps
                , serverInfo = info
                } = ir
          writeIORef (session_server_caps session) (Just caps)
          writeIORef (session_server_info session) (Just info)
          writeIORef (session_initialized session) True
          -- Send initialized notification
          sendNotification session $
            NotificationMessage $
              JSONRPCNotification rPC_VERSION "notifications/initialized" Aeson.Null
          return ir

-- | Server capabilities received during initialization, if any.
sessionServerCapabilities :: ClientSession -> IO (Maybe ServerCapabilities)
sessionServerCapabilities = readIORef . session_server_caps

-- | Server info received during initialization, if any.
sessionServerInfo :: ClientSession -> IO (Maybe Implementation)
sessionServerInfo = readIORef . session_server_info

-- * Internal

newSession :: Transport -> ClientConfig -> IO ClientSession
newSession transport cfg = do
  next_id <- newIORef 1
  pending <- newIORef IM.empty
  caps <- newIORef Nothing
  info <- newIORef Nothing
  inited <- newIORef False
  closed <- newIORef False
  return
    ClientSession
      { session_transport = transport
      , session_config = cfg
      , session_next_id = next_id
      , session_pending = pending
      , session_server_caps = caps
      , session_server_info = info
      , session_initialized = inited
      , session_closed = closed
      }

-- | Send a JSON-RPC request and block until the response arrives.
sendRequest :: ClientSession -> Text -> Value -> IO Value
sendRequest session method params = do
  closed <- readIORef (session_closed session)
  if closed
    then throwIO SessionClosed
    else do
      (req_id_int, mvar) <- registerPending session
      let req_id = RequestId (toJSON req_id_int)
          msg =
            RequestMessage $
              JSONRPCRequest rPC_VERSION req_id method params
      transport_send (session_transport session) msg
      let timeout_us = config_request_timeout_us (session_config session)
      result <-
        if timeout_us <= 0
          then Just <$> takeMVar mvar
          else timeout timeout_us (takeMVar mvar)
      -- Clean up pending entry
      atomicModifyIORef' (session_pending session) $ \m ->
        (IM.delete req_id_int m, ())
      case result of
        Nothing -> throwIO $ RequestTimeout req_id
        Just (Left (JSONRPCErrorInfo err_code err_msg err_data)) ->
          throwIO $ RPCError err_code err_msg err_data
        Just (Right val) -> return val

-- | Send a notification (fire-and-forget, no response expected).
sendNotification :: ClientSession -> JSONRPCMessage -> IO ()
sendNotification session msg =
  transport_send (session_transport session) msg

-- | Allocate a fresh request ID and MVar for the response.
registerPending :: ClientSession -> IO (Int, MVar (Either JSONRPCErrorInfo Value))
registerPending session = do
  mvar <- newEmptyMVar
  req_id <- atomicModifyIORef' (session_next_id session) $ \n -> (n + 1, n)
  atomicModifyIORef' (session_pending session) $ \m ->
    (IM.insert req_id mvar m, ())
  return (req_id, mvar)

-- | Fill all pending MVars with a 'SessionClosed' error so no thread hangs.
failAllPending :: ClientSession -> IO ()
failAllPending session = do
  pending <- atomicModifyIORef' (session_pending session) $ \m -> (IM.empty, m)
  let err = JSONRPCErrorInfo iNTERNAL_ERROR "Session closed" Nothing
  mapM_ (\mvar -> putMVar mvar (Left err)) pending

-- | Background loop reading from the transport and dispatching messages.
receiveLoop :: ClientSession -> IO ()
receiveLoop session = do
  mb_msg <- try $ transport_receive (session_transport session)
  case mb_msg of
    Left (_ :: SomeException) -> return ()
    Right Nothing -> return ()
    Right (Just msg) -> do
      dispatchMessage session msg
      receiveLoop session

-- | Route an incoming message to the appropriate handler.
dispatchMessage :: ClientSession -> JSONRPCMessage -> IO ()
dispatchMessage session = \case
  ResponseMessage (JSONRPCResponse _ req_id result_val) ->
    deliverResponse session req_id (Right result_val)
  ErrorMessage (JSONRPCError _ req_id err_info) ->
    deliverResponse session req_id (Left err_info)
  RequestMessage (JSONRPCRequest _ req_id method params) ->
    handleServerRequest session req_id method params
  NotificationMessage (JSONRPCNotification _ method params) ->
    handleServerNotification session method params

-- | Deliver a response to the waiting caller.
deliverResponse :: ClientSession -> RequestId -> Either JSONRPCErrorInfo Value -> IO ()
deliverResponse session (RequestId req_id_val) result = do
  let mb_int = case req_id_val of
        Aeson.Number n -> Just (round n :: Int)
        _ -> Nothing
  case mb_int of
    Nothing -> return ()
    Just req_id_int -> do
      mb_mvar <- atomicModifyIORef' (session_pending session) $ \m ->
        case IM.lookup req_id_int m of
          Nothing -> (m, Nothing)
          Just mvar -> (IM.delete req_id_int m, Just mvar)
      case mb_mvar of
        Nothing -> return ()
        Just mvar -> putMVar mvar result

-- | Handle a request from the server (ping, sampling, roots, elicitation).
handleServerRequest :: ClientSession -> RequestId -> Text -> Value -> IO ()
handleServerRequest session req_id method params = do
  let cfg = session_config session
      send_response val =
        sendNotificationRaw session $
          ResponseMessage $ JSONRPCResponse rPC_VERSION req_id val
      send_error err_code err_msg =
        sendNotificationRaw session $
          ErrorMessage $
            JSONRPCError rPC_VERSION req_id (JSONRPCErrorInfo err_code err_msg Nothing)
      dispatch :: (FromJSON a, ToJSON b) => Maybe (a -> IO b) -> IO ()
      dispatch Nothing = send_error mETHOD_NOT_FOUND ("Method not found: " <> method)
      dispatch (Just handler) =
        case Aeson.fromJSON params of
          Aeson.Error err -> send_error iNVALID_PARAMS (T.pack err)
          Aeson.Success p -> do
            result <- handler p
            send_response (toJSON result)
  case method of
    "ping" -> send_response (Aeson.Object mempty)
    "sampling/createMessage" -> dispatch (config_on_create_message cfg)
    "roots/list" -> dispatch (config_on_list_roots cfg)
    "elicitation/create" -> dispatch (config_on_elicit cfg)
    _ -> send_error mETHOD_NOT_FOUND ("Method not found: " <> method)

-- | Handle a notification from the server.
handleServerNotification :: ClientSession -> Text -> Value -> IO ()
handleServerNotification session method params = do
  let cfg = session_config session
      tryCall :: (FromJSON a) => Maybe (a -> IO ()) -> IO ()
      tryCall Nothing = callFallback
      tryCall (Just handler) =
        case Aeson.fromJSON params of
          Aeson.Error _ -> callFallback
          Aeson.Success p -> handler p
      callFallback =
        case config_on_fallback cfg of
          Nothing -> return ()
          Just fb -> fb $ NotificationMessage $ JSONRPCNotification rPC_VERSION method params
  case method of
    "notifications/progress" -> tryCall (config_on_progress cfg)
    "notifications/message" -> tryCall (config_on_logging_message cfg)
    "notifications/resources/updated" -> tryCall (config_on_resource_updated cfg)
    "notifications/resources/list_changed" ->
      maybe callFallback id (config_on_resource_list_changed cfg)
    "notifications/tools/list_changed" ->
      maybe callFallback id (config_on_tool_list_changed cfg)
    "notifications/prompts/list_changed" ->
      maybe callFallback id (config_on_prompt_list_changed cfg)
    "notifications/cancelled" -> tryCall (config_on_cancelled cfg)
    _ -> callFallback

-- | Raw send — used internally for responses to server requests.
sendNotificationRaw :: ClientSession -> JSONRPCMessage -> IO ()
sendNotificationRaw session msg =
  transport_send (session_transport session) msg
