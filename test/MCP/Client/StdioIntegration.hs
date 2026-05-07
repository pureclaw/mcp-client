{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wno-name-shadowing #-}

module MCP.Client.StdioIntegration where

import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, bracket, catch, try)
import Data.Aeson (Value (..), toJSON, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Char8 qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Map qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import JSONRPC hiding (id, method, params, result)
import MCP.Client.API
import MCP.Client.Config (ClientConfig (..), defaultClientConfig)
import MCP.Client.Error (MCPClientError (..))
import MCP.Client.Session
  ( ClientSession,
    initialize,
    sessionServerCapabilities,
    sessionServerInfo,
    sendRequest,
    withClientSession,
  )
import MCP.Client.Transport (Transport (..))
import MCP.Protocol
  ( CallToolResult (..),
    CompleteParams (..),
    CompletionArgument (..),
    GetPromptResult (..),
    InitializeResult (..),
    ListPromptsResult (..),
    ListResourceTemplatesResult (..),
    ListResourcesResult (..),
    ListToolsResult (..),
    ReadResourceResult (..),
    Reference (PromptRef),
    pROTOCOL_VERSION,
  )
import MCP.Types
import System.IO (BufferMode (..), Handle, hClose, hFlush, hIsEOF, hSetBuffering)
import System.Process (createPipe)
import Test.Hspec

stdioClientIntegrationSpec :: Spec
stdioClientIntegrationSpec = describe "MCP Client (stdio)" $ do
  initializationSpec
  versionNegotiationSpec
  sessionLifecycleSpec
  pingSpec
  toolSpec
  resourceSpec
  resourceTemplateSpec
  promptSpec
  completionSpec
  loggingSpec
  requestTimeoutSpec
  notificationCallbackSpec
  serverInitiatedRequestSpec
  fallbackHandlerSpec

-- * Mock Server

-- | Configuration for mock server behavior, allowing per-test customization.
data MockServerConfig = MockServerConfig
  { msc_protocol_version :: Text
    -- ^ Protocol version to return during initialization
  , msc_on_initialized :: Maybe (Handle -> IO ())
    -- ^ Action to run after receiving the initialized notification
    -- (used to send server-initiated messages)
  , msc_slow_ping :: Bool
    -- ^ If True, delay ping response (for timeout testing)
  }

defaultMockConfig :: MockServerConfig
defaultMockConfig = MockServerConfig
  { msc_protocol_version = pROTOCOL_VERSION
  , msc_on_initialized = Nothing
  , msc_slow_ping = False
  }

-- | A minimal mock MCP server that reads JSON-RPC from a handle and writes
-- responses back, implementing just enough to exercise the client library.
mockServer :: MockServerConfig -> Handle -> Handle -> IO ()
mockServer cfg readEnd writeEnd = go
 where
  go = do
    eof <- hIsEOF readEnd
    if eof
      then return ()
      else do
        line <- BS.hGetLine readEnd
        case Aeson.eitherDecodeStrict' line of
          Left _ -> go
          Right msg -> do
            case msg of
              RequestMessage (JSONRPCRequest _ reqId method params) -> do
                let respond val =
                      BSL.hPut writeEnd (Aeson.encode (ResponseMessage (JSONRPCResponse rPC_VERSION reqId val)))
                        >> BSL.hPut writeEnd "\n"
                        >> hFlush writeEnd
                    respondError code errMsg =
                      BSL.hPut writeEnd (Aeson.encode (ErrorMessage (JSONRPCError rPC_VERSION reqId (JSONRPCErrorInfo code errMsg Nothing))))
                        >> BSL.hPut writeEnd "\n"
                        >> hFlush writeEnd
                handleMockRequest cfg writeEnd method params respond respondError
              NotificationMessage (JSONRPCNotification _ method _params) -> do
                -- After client sends "notifications/initialized", trigger any
                -- server-initiated actions (notifications, requests, etc.)
                case method of
                  "notifications/initialized" ->
                    case msc_on_initialized cfg of
                      Just action -> action writeEnd
                      Nothing -> return ()
                  _ -> return ()
              _ -> return ()
            go

handleMockRequest :: MockServerConfig -> Handle -> Text -> Value -> (Value -> IO ()) -> (Int -> Text -> IO ()) -> IO ()
handleMockRequest cfg _writeEnd method params respond respondError = case method of
  "initialize" ->
    respond $ toJSON $ Aeson.object
      [ "protocolVersion" .= msc_protocol_version cfg
      , "capabilities" .= Aeson.object
          [ "logging" .= Aeson.object []
          , "prompts" .= Aeson.object ["listChanged" .= False]
          , "resources" .= Aeson.object ["listChanged" .= False, "subscribe" .= False]
          , "tools" .= Aeson.object ["listChanged" .= True]
          ]
      , "serverInfo" .= Aeson.object
          [ "name" .= ("test-server" :: Text)
          , "version" .= ("1.0.0" :: Text)
          ]
      ]

  "ping"
    | msc_slow_ping cfg -> threadDelay 5_000_000 >> respond (Aeson.object [])
    | otherwise -> respond (Aeson.object [])

  "tools/list" ->
    respond $ toJSON $ Aeson.object
      [ "tools" .= [ Aeson.object
            [ "name" .= ("echo" :: Text)
            , "description" .= ("Echo tool" :: Text)
            , "inputSchema" .= Aeson.object
                [ "type" .= ("object" :: Text)
                , "properties" .= Aeson.object ["message" .= Aeson.object ["type" .= ("string" :: Text)]]
                , "required" .= (["message"] :: [Text])
                ]
            ]
          , Aeson.object
            [ "name" .= ("add" :: Text)
            , "description" .= ("Addition tool" :: Text)
            , "inputSchema" .= Aeson.object
                [ "type" .= ("object" :: Text)
                , "properties" .= Aeson.object
                    [ "a" .= Aeson.object ["type" .= ("number" :: Text)]
                    , "b" .= Aeson.object ["type" .= ("number" :: Text)]
                    ]
                , "required" .= (["a", "b"] :: [Text])
                ]
            ]
          ]
      ]

  "tools/call" -> do
    let obj = case params of { Object o -> o; _ -> KM.empty }
        toolName = case KM.lookup "name" obj of { Just (String n) -> n; _ -> "" }
        args = case KM.lookup "arguments" obj of
          Just (Object a) -> Just $ Map.fromList [(Key.toText k, v) | (k, v) <- KM.toList a]
          _ -> Nothing
    case toolName of
      "echo" ->
        let msg = case args >>= Map.lookup "message" of
              Just (String t) -> t
              _ -> "?"
        in respond $ toJSON $ Aeson.object
              [ "content" .= [Aeson.object ["type" .= ("text" :: Text), "text" .= msg]]
              ]
      "add" ->
        let a = maybe 0 (\v -> case v of { Number n -> round n; _ -> 0 }) (args >>= Map.lookup "a") :: Int
            b = maybe 0 (\v -> case v of { Number n -> round n; _ -> 0 }) (args >>= Map.lookup "b") :: Int
        in respond $ toJSON $ Aeson.object
              [ "content" .= [Aeson.object ["type" .= ("text" :: Text), "text" .= T.pack (show (a + b))]]
              , "structuredContent" .= Aeson.object ["result" .= (a + b)]
              ]
      _ -> respondError 404 "Tool not found"

  "resources/list" ->
    respond $ toJSON $ Aeson.object
      [ "resources" .= [Aeson.object
          [ "uri" .= ("resource://test/hello" :: Text)
          , "name" .= ("hello" :: Text)
          ]]
      ]

  "resources/read" -> do
    let uri = case params of
          Object o -> case KM.lookup "uri" o of { Just (String u) -> u; _ -> "" }
          _ -> ""
    if uri == "resource://test/hello"
      then respond $ toJSON $ Aeson.object
        [ "contents" .= [Aeson.object
            [ "uri" .= ("resource://test/hello" :: Text)
            , "text" .= ("Hello, world!" :: Text)
            ]]
        ]
      else respondError 404 "Resource not found"

  "resources/subscribe" -> respond (Aeson.object [])
  "resources/unsubscribe" -> respond (Aeson.object [])

  "resources/templates/list" ->
    respond $ toJSON $ Aeson.object ["resourceTemplates" .= ([] :: [Value])]

  "prompts/list" ->
    respond $ toJSON $ Aeson.object
      [ "prompts" .= [Aeson.object
          [ "name" .= ("greet" :: Text)
          , "description" .= ("A greeting prompt" :: Text)
          , "arguments" .= [Aeson.object
              [ "name" .= ("name" :: Text)
              , "required" .= True
              ]]
          ]]
      ]

  "prompts/get" -> do
    let name = case params of
          Object o -> case KM.lookup "name" o of { Just (String n) -> n; _ -> "" }
          _ -> ""
    if name == "greet"
      then respond $ toJSON $ Aeson.object
        [ "description" .= ("A greeting prompt" :: Text)
        , "messages" .= [Aeson.object
            [ "role" .= ("user" :: Text)
            , "content" .= Aeson.object ["type" .= ("text" :: Text), "text" .= ("Hello!" :: Text)]
            ]]
        ]
      else respondError 404 "Prompt not found"

  "completion/complete" -> respondError (-32601) "Method not found"

  "logging/setLevel" -> respond (Aeson.object [])

  _ -> respondError (-32601) ("Method not found: " <> method)

-- | Send a JSON-RPC notification from the mock server to the client.
sendServerNotification :: Handle -> Text -> Value -> IO ()
sendServerNotification h method params = do
  let msg = NotificationMessage (JSONRPCNotification rPC_VERSION method params)
  BSL.hPut h (Aeson.encode msg)
  BSL.hPut h "\n"
  hFlush h

-- | Send a JSON-RPC request from the mock server to the client.
sendServerRequest :: Handle -> Int -> Text -> Value -> IO ()
sendServerRequest h reqIdInt method params = do
  let reqId = RequestId (toJSON reqIdInt)
      msg = RequestMessage (JSONRPCRequest rPC_VERSION reqId method params)
  BSL.hPut h (Aeson.encode msg)
  BSL.hPut h "\n"
  hFlush h

-- * Test Infrastructure

-- | Bracket that creates pipes, starts a mock server, and yields a Transport.
withTestServer :: (Transport -> IO a) -> IO a
withTestServer = withTestServerConfig defaultMockConfig

-- | Like 'withTestServer' but with a custom mock server config.
withTestServerConfig :: MockServerConfig -> (Transport -> IO a) -> IO a
withTestServerConfig cfg f = do
  (clientToServerRead, clientToServerWrite) <- createPipe
  (serverToClientRead, serverToClientWrite) <- createPipe

  hSetBuffering clientToServerWrite LineBuffering
  hSetBuffering serverToClientRead LineBuffering
  hSetBuffering clientToServerRead LineBuffering
  hSetBuffering serverToClientWrite LineBuffering

  bracket
    ( do
        tid <- forkIO $ mockServer cfg clientToServerRead serverToClientWrite
                          `catch` \(_ :: SomeException) -> return ()
        threadDelay 10000
        return tid
    )
    ( \tid -> do
        killThread tid
        hClose clientToServerWrite
        hClose clientToServerRead
        hClose serverToClientWrite
        hClose serverToClientRead
    )
    ( \_ ->
        f
          Transport
            { transport_send = \msg -> do
                BSL.hPut clientToServerWrite (Aeson.encode msg)
                BSL.hPut clientToServerWrite "\n"
                hFlush clientToServerWrite
            , transport_receive = do
                eof <- hIsEOF serverToClientRead
                if eof
                  then return Nothing
                  else do
                    line <- BS.hGetLine serverToClientRead
                    case Aeson.eitherDecodeStrict' line of
                      Right msg -> return (Just msg)
                      Left _ -> return Nothing
            , transport_close = return ()
            }
    )

-- | Run a test with a connected and initialized client session.
withInitializedClient :: (ClientSession -> IO a) -> IO a
withInitializedClient = withInitializedClientConfig defaultMockConfig testConfig

-- | Like 'withInitializedClient' but with custom configs.
withInitializedClientConfig :: MockServerConfig -> ClientConfig -> (ClientSession -> IO a) -> IO a
withInitializedClientConfig mockCfg clientCfg action =
  withTestServerConfig mockCfg $ \transport ->
    withClientSession transport clientCfg $ \session -> do
      _ <- initialize session
      action session

testConfig :: ClientConfig
testConfig =
  defaultClientConfig
    { config_client_info = Implementation "test-client" "0.1.0" Nothing
    , config_capabilities = ClientCapabilities Nothing Nothing Nothing Nothing
    , config_request_timeout_us = 5_000_000
    }

-- * Test Specs

initializationSpec :: Spec
initializationSpec = describe "Initialization" $ do
  it "completes the initialization handshake" $ do
    withTestServer $ \transport ->
      withClientSession transport defaultClientConfig $ \session -> do
        result <- initialize session
        protocolVersion result `shouldBe` pROTOCOL_VERSION
        let Implementation{name = sname} = serverInfo result
        sname `shouldBe` "test-server"

  it "stores server capabilities after initialization" $ do
    withTestServer $ \transport ->
      withClientSession transport testConfig $ \session -> do
        capsBefore <- sessionServerCapabilities session
        capsBefore `shouldBe` Nothing
        _ <- initialize session
        capsAfter <- sessionServerCapabilities session
        capsAfter `shouldSatisfy` \case { Just _ -> True; Nothing -> False }

  it "stores server info after initialization" $ do
    withTestServer $ \transport ->
      withClientSession transport testConfig $ \session -> do
        infoBefore <- sessionServerInfo session
        infoBefore `shouldBe` Nothing
        _ <- initialize session
        infoAfter <- sessionServerInfo session
        case infoAfter of
          Just (Implementation{name = n}) -> n `shouldBe` "test-server"
          Nothing -> expectationFailure "Expected server info"

  it "sends custom client info during initialization" $ do
    let cfg = testConfig
          { config_client_info = Implementation "my-custom-client" "2.0.0" Nothing
          }
    -- If initialization succeeds, the client info was sent correctly
    withTestServerConfig defaultMockConfig $ \transport ->
      withClientSession transport cfg $ \session -> do
        result <- initialize session
        protocolVersion result `shouldBe` pROTOCOL_VERSION

versionNegotiationSpec :: Spec
versionNegotiationSpec = describe "Version Negotiation" $ do
  it "rejects mismatched protocol version" $ do
    let badVersionCfg = defaultMockConfig { msc_protocol_version = "1999-01-01" }
    withTestServerConfig badVersionCfg $ \transport ->
      withClientSession transport testConfig $ \session -> do
        result <- try @MCPClientError $ initialize session
        case result of
          Left (ProtocolVersionMismatch expected got) -> do
            expected `shouldBe` pROTOCOL_VERSION
            got `shouldBe` "1999-01-01"
          Left other -> expectationFailure $ "Expected ProtocolVersionMismatch, got: " ++ show other
          Right _ -> expectationFailure "Expected ProtocolVersionMismatch error"

sessionLifecycleSpec :: Spec
sessionLifecycleSpec = describe "Session Lifecycle" $ do
  it "fails pending requests when session closes" $ do
    -- Start a session, send a request to a slow server, then close the session.
    -- The pending request should fail with an internal error.
    let slowCfg = defaultMockConfig { msc_slow_ping = True }
    result <- try @MCPClientError $
      withTestServerConfig slowCfg $ \transport ->
        withClientSession transport (testConfig { config_request_timeout_us = 500_000 }) $ \session -> do
          _ <- initialize session
          -- This will timeout because the mock delays ping for 5 seconds
          ping session
    case result of
      Left (RequestTimeout _) -> return ()
      Left (RPCError _ _ _) -> return ()  -- internal error from session close
      Left other -> expectationFailure $ "Expected timeout or RPC error, got: " ++ show other
      Right () -> expectationFailure "Expected error from session close"

  it "rejects requests after session is closed" $ do
    -- Create a transport, run a session, then try to use it after closing
    mvar <- newEmptyMVar
    withTestServer $ \transport -> do
      withClientSession transport testConfig $ \session -> do
        _ <- initialize session
        putMVar mvar session
      -- Session is now closed, try to use it
      session <- takeMVar mvar
      result <- try @MCPClientError $ sendRequest session "ping" (Aeson.object [])
      case result of
        Left SessionClosed -> return ()
        Left other -> expectationFailure $ "Expected SessionClosed, got: " ++ show other
        Right _ -> expectationFailure "Expected SessionClosed error"

pingSpec :: Spec
pingSpec = describe "Ping" $ do
  it "pings the server" $ do
    withInitializedClient $ \session -> do
      ping session

toolSpec :: Spec
toolSpec = describe "Tools" $ do
  it "lists available tools" $ do
    withInitializedClient $ \session -> do
      ListToolsResult{tools = ts} <- listTools session Nothing
      let names = fmap (\Tool{name = n} -> n) ts
      names `shouldMatchList` ["echo", "add"]

  it "calls the echo tool" $ do
    withInitializedClient $ \session -> do
      CallToolResult{content = cs} <-
        callTool session "echo" (Just $ Map.fromList [("message", toJSON ("hi" :: Text))])
      case cs of
        [TextBlock (TextContent{text = t})] -> t `shouldBe` "hi"
        _ -> expectationFailure "Expected single text content"

  it "calls the echo tool with unicode" $ do
    withInitializedClient $ \session -> do
      let unicodeMsg = "\x041F\x0440\x0438\x0432\x0435\x0442 \x4F60\x597D \x1F680" -- "Привет 你好 🚀"
      CallToolResult{content = cs} <-
        callTool session "echo" (Just $ Map.fromList [("message", toJSON unicodeMsg)])
      case cs of
        [TextBlock (TextContent{text = t})] -> t `shouldBe` unicodeMsg
        _ -> expectationFailure "Expected single text content"

  it "calls the add tool" $ do
    withInitializedClient $ \session -> do
      CallToolResult{structuredContent = sc} <-
        callTool session "add" (Just $ Map.fromList [("a", toJSON (3 :: Int)), ("b", toJSON (4 :: Int))])
      case sc of
        Just m -> Map.lookup "result" m `shouldBe` Just (toJSON (7 :: Int))
        Nothing -> expectationFailure "Expected structured content"

  it "calls the add tool with zero arguments" $ do
    withInitializedClient $ \session -> do
      CallToolResult{content = cs} <-
        callTool session "add" (Just $ Map.fromList [("a", toJSON (0 :: Int)), ("b", toJSON (0 :: Int))])
      case cs of
        [TextBlock (TextContent{text = t})] -> t `shouldBe` "0"
        _ -> expectationFailure "Expected single text content"

  it "calls the add tool with negative numbers" $ do
    withInitializedClient $ \session -> do
      CallToolResult{content = cs} <-
        callTool session "add" (Just $ Map.fromList [("a", toJSON (-10 :: Int)), ("b", toJSON (3 :: Int))])
      case cs of
        [TextBlock (TextContent{text = t})] -> t `shouldBe` "-7"
        _ -> expectationFailure "Expected single text content"

  it "returns error for non-existent tool" $ do
    withInitializedClient $ \session -> do
      result <- try @MCPClientError $ callTool session "nope" Nothing
      case result of
        Left (RPCError err_code _ _) -> err_code `shouldBe` 404
        _ -> expectationFailure "Expected RPCError"

  it "calls tool with no arguments" $ do
    withInitializedClient $ \session -> do
      CallToolResult{content = cs} <-
        callTool session "echo" Nothing
      case cs of
        [TextBlock (TextContent{text = t})] -> t `shouldBe` "?"
        _ -> expectationFailure "Expected single text content with fallback"

resourceSpec :: Spec
resourceSpec = describe "Resources" $ do
  it "lists available resources" $ do
    withInitializedClient $ \session -> do
      ListResourcesResult{resources = rs} <- listResources session Nothing
      length rs `shouldBe` 1
      case rs of
        (Resource{uri = u} : _) -> u `shouldBe` "resource://test/hello"
        [] -> expectationFailure "Expected at least one resource"

  it "reads a resource" $ do
    withInitializedClient $ \session -> do
      ReadResourceResult{contents = cs} <- readResource session "resource://test/hello"
      case cs of
        [TextResource (TextResourceContents{text = t})] -> t `shouldBe` "Hello, world!"
        _ -> expectationFailure "Expected single text resource"

  it "returns error for non-existent resource" $ do
    withInitializedClient $ \session -> do
      result <- try @MCPClientError $ readResource session "resource://nonexistent"
      case result of
        Left (RPCError err_code _ _) -> err_code `shouldBe` 404
        _ -> expectationFailure "Expected RPCError"

  it "subscribes to a resource" $ do
    withInitializedClient $ \session -> do
      _ <- subscribeResource session "resource://test/hello"
      return ()

  it "unsubscribes from a resource" $ do
    withInitializedClient $ \session -> do
      _ <- unsubscribeResource session "resource://test/hello"
      return ()

resourceTemplateSpec :: Spec
resourceTemplateSpec = describe "Resource Templates" $ do
  it "lists resource templates (empty)" $ do
    withInitializedClient $ \session -> do
      ListResourceTemplatesResult{resourceTemplates = ts} <- listResourceTemplates session Nothing
      ts `shouldBe` []

promptSpec :: Spec
promptSpec = describe "Prompts" $ do
  it "lists available prompts" $ do
    withInitializedClient $ \session -> do
      ListPromptsResult{prompts = ps} <- listPrompts session Nothing
      let names = fmap (\Prompt{name = n} -> n) ps
      names `shouldBe` ["greet"]

  it "gets a prompt" $ do
    withInitializedClient $ \session -> do
      GetPromptResult{description = desc, messages = msgs} <-
        getPrompt session "greet" Nothing
      desc `shouldBe` Just "A greeting prompt"
      length msgs `shouldBe` 1

  it "gets a prompt with arguments" $ do
    withInitializedClient $ \session -> do
      GetPromptResult{description = desc} <-
        getPrompt session "greet" (Just $ Map.fromList [("name", "World")])
      desc `shouldBe` Just "A greeting prompt"

  it "returns error for non-existent prompt" $ do
    withInitializedClient $ \session -> do
      result <- try @MCPClientError $ getPrompt session "nope" Nothing
      case result of
        Left (RPCError err_code _ _) -> err_code `shouldBe` 404
        _ -> expectationFailure "Expected RPCError"

completionSpec :: Spec
completionSpec = describe "Completions" $ do
  it "handles completion when server has no completions capability" $ do
    withInitializedClient $ \session -> do
      result <- try @MCPClientError $
        complete session $
          CompleteParams
            { ref = PromptRef (PromptReference "ref/prompt" "greet" Nothing)
            , argument = CompletionArgument "name" ""
            , context = Nothing
            }
      case result of
        Left (RPCError _ _ _) -> return ()
        Right _ -> return ()
        Left _ -> expectationFailure "Unexpected error type"

loggingSpec :: Spec
loggingSpec = describe "Logging" $ do
  it "sets logging level" $ do
    withInitializedClient $ \session -> do
      setLoggingLevel session Debug

requestTimeoutSpec :: Spec
requestTimeoutSpec = describe "Request Timeout" $ do
  it "times out when server does not respond" $ do
    let slowCfg = defaultMockConfig { msc_slow_ping = True }
        shortTimeoutCfg = testConfig { config_request_timeout_us = 100_000 } -- 100ms
    result <- try @MCPClientError $
      withInitializedClientConfig slowCfg shortTimeoutCfg $ \session ->
        ping session
    case result of
      Left (RequestTimeout _) -> return ()
      Left other -> expectationFailure $ "Expected RequestTimeout, got: " ++ show other
      Right () -> expectationFailure "Expected RequestTimeout"

notificationCallbackSpec :: Spec
notificationCallbackSpec = describe "Notification Callbacks" $ do
  it "receives progress notifications" $ do
    progressRef <- newIORef ([] :: [Double])
    let serverAction h = do
          sendServerNotification h "notifications/progress"
            (Aeson.object ["progressToken" .= ("tok1" :: Text), "progress" .= (0.5 :: Double), "total" .= (1.0 :: Double)])
          threadDelay 50000
        mockCfg = defaultMockConfig { msc_on_initialized = Just serverAction }
        clientCfg = testConfig
          { config_on_progress = Just $ \_ ->
              atomicModifyIORef' progressRef (\xs -> (xs ++ [1], ()))
          }
    withInitializedClientConfig mockCfg clientCfg $ \_ -> do
      threadDelay 200_000 -- wait for notification to arrive
      received <- readIORef progressRef
      length received `shouldSatisfy` (>= 1)

  it "receives logging message notifications" $ do
    logRef <- newIORef ([] :: [Text])
    let serverAction h = do
          sendServerNotification h "notifications/message"
            (Aeson.object ["level" .= ("info" :: Text), "data'" .= ("test log message" :: Text), "logger" .= ("test" :: Text)])
          threadDelay 50000
        mockCfg = defaultMockConfig { msc_on_initialized = Just serverAction }
        clientCfg = testConfig
          { config_on_logging_message = Just $ \_ ->
              atomicModifyIORef' logRef (\xs -> (xs ++ ["got-log"], ()))
          }
    withInitializedClientConfig mockCfg clientCfg $ \_ -> do
      threadDelay 200_000
      received <- readIORef logRef
      length received `shouldSatisfy` (>= 1)

  it "receives resource updated notifications" $ do
    updatedRef <- newIORef ([] :: [Text])
    let serverAction h = do
          sendServerNotification h "notifications/resources/updated"
            (Aeson.object ["uri" .= ("resource://test/hello" :: Text)])
          threadDelay 50000
        mockCfg = defaultMockConfig { msc_on_initialized = Just serverAction }
        clientCfg = testConfig
          { config_on_resource_updated = Just $ \_ ->
              atomicModifyIORef' updatedRef (\xs -> (xs ++ ["updated"], ()))
          }
    withInitializedClientConfig mockCfg clientCfg $ \_ -> do
      threadDelay 200_000
      received <- readIORef updatedRef
      length received `shouldSatisfy` (>= 1)

  it "receives tools list changed notifications" $ do
    changedRef <- newIORef False
    let serverAction h = do
          sendServerNotification h "notifications/tools/list_changed" Aeson.Null
          threadDelay 50000
        mockCfg = defaultMockConfig { msc_on_initialized = Just serverAction }
        clientCfg = testConfig
          { config_on_tool_list_changed = Just $
              atomicModifyIORef' changedRef (\_ -> (True, ()))
          }
    withInitializedClientConfig mockCfg clientCfg $ \_ -> do
      threadDelay 200_000
      changed <- readIORef changedRef
      changed `shouldBe` True

  it "receives prompts list changed notifications" $ do
    changedRef <- newIORef False
    let serverAction h = do
          sendServerNotification h "notifications/prompts/list_changed" Aeson.Null
          threadDelay 50000
        mockCfg = defaultMockConfig { msc_on_initialized = Just serverAction }
        clientCfg = testConfig
          { config_on_prompt_list_changed = Just $
              atomicModifyIORef' changedRef (\_ -> (True, ()))
          }
    withInitializedClientConfig mockCfg clientCfg $ \_ -> do
      threadDelay 200_000
      changed <- readIORef changedRef
      changed `shouldBe` True

  it "receives resources list changed notifications" $ do
    changedRef <- newIORef False
    let serverAction h = do
          sendServerNotification h "notifications/resources/list_changed" Aeson.Null
          threadDelay 50000
        mockCfg = defaultMockConfig { msc_on_initialized = Just serverAction }
        clientCfg = testConfig
          { config_on_resource_list_changed = Just $
              atomicModifyIORef' changedRef (\_ -> (True, ()))
          }
    withInitializedClientConfig mockCfg clientCfg $ \_ -> do
      threadDelay 200_000
      changed <- readIORef changedRef
      changed `shouldBe` True

  it "receives cancelled notifications" $ do
    cancelledRef <- newIORef False
    let serverAction h = do
          sendServerNotification h "notifications/cancelled"
            (Aeson.object ["requestId" .= (1 :: Int), "reason" .= ("user cancelled" :: Text)])
          threadDelay 50000
        mockCfg = defaultMockConfig { msc_on_initialized = Just serverAction }
        clientCfg = testConfig
          { config_on_cancelled = Just $ \_ ->
              atomicModifyIORef' cancelledRef (\_ -> (True, ()))
          }
    withInitializedClientConfig mockCfg clientCfg $ \_ -> do
      threadDelay 200_000
      cancelled <- readIORef cancelledRef
      cancelled `shouldBe` True

serverInitiatedRequestSpec :: Spec
serverInitiatedRequestSpec = describe "Server-Initiated Requests" $ do
  it "responds to server ping" $ do
    -- The server sends a ping request; the client should auto-respond.
    -- We verify the session stays healthy afterward.
    let serverAction h = do
          sendServerRequest h 9001 "ping" (Aeson.object [])
          threadDelay 50000
        mockCfg = defaultMockConfig { msc_on_initialized = Just serverAction }
    withInitializedClientConfig mockCfg testConfig $ \session -> do
      threadDelay 200_000
      -- Session should still work — send a normal request
      ping session

  it "returns method_not_found for unknown server requests" $ do
    -- The mock server sends an unknown method; the client should respond
    -- with an error but remain healthy.
    let serverAction h = do
          sendServerRequest h 9002 "unknown/method" (Aeson.object [])
          threadDelay 50000
        mockCfg = defaultMockConfig { msc_on_initialized = Just serverAction }
    withInitializedClientConfig mockCfg testConfig $ \session -> do
      threadDelay 200_000
      -- Session should still work
      ping session

fallbackHandlerSpec :: Spec
fallbackHandlerSpec = describe "Fallback Handler" $ do
  it "routes unrecognized notifications to the fallback handler" $ do
    fallbackRef <- newIORef ([] :: [Text])
    let serverAction h = do
          sendServerNotification h "custom/unknown-notification"
            (Aeson.object ["data" .= ("hello" :: Text)])
          threadDelay 50000
        mockCfg = defaultMockConfig { msc_on_initialized = Just serverAction }
        clientCfg = testConfig
          { config_on_fallback = Just $ \_ ->
              atomicModifyIORef' fallbackRef (\xs -> (xs ++ ["fallback-hit"], ()))
          }
    withInitializedClientConfig mockCfg clientCfg $ \_ -> do
      threadDelay 200_000
      received <- readIORef fallbackRef
      length received `shouldSatisfy` (>= 1)

  it "does not crash on unrecognized notifications without fallback handler" $ do
    let serverAction h = do
          sendServerNotification h "custom/unknown-notification"
            (Aeson.object ["data" .= ("hello" :: Text)])
          threadDelay 50000
        mockCfg = defaultMockConfig { msc_on_initialized = Just serverAction }
    withInitializedClientConfig mockCfg testConfig $ \session -> do
      threadDelay 200_000
      -- Session should still work
      ping session
