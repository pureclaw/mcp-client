{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wno-name-shadowing #-}

module MCP.Client.StdioIntegration where

import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Exception (SomeException, bracket, catch, try)
import Data.Aeson (Value (..), toJSON, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Char8 qualified as BS
import Data.ByteString.Lazy qualified as BSL
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
  pingSpec
  toolSpec
  resourceSpec
  resourceTemplateSpec
  promptSpec
  completionSpec
  loggingSpec

-- * Mock Server

-- | A minimal mock MCP server that reads JSON-RPC from a handle and writes
-- responses back, implementing just enough to exercise the client library.
mockServer :: Handle -> Handle -> IO ()
mockServer readEnd writeEnd = go
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
                handleRequest method params respond respondError
              NotificationMessage _ -> return () -- ignore notifications
              _ -> return ()
            go

handleRequest :: Text -> Value -> (Value -> IO ()) -> (Int -> Text -> IO ()) -> IO ()
handleRequest method params respond respondError = case method of
  "initialize" ->
    respond $ toJSON $ Aeson.object
      [ "protocolVersion" .= pROTOCOL_VERSION
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

  "ping" -> respond (Aeson.object [])

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

-- * Test Infrastructure

-- | Bracket that creates pipes, starts a mock server, and yields a Transport.
withTestServer :: (Transport -> IO a) -> IO a
withTestServer f = do
  (clientToServerRead, clientToServerWrite) <- createPipe
  (serverToClientRead, serverToClientWrite) <- createPipe

  hSetBuffering clientToServerWrite LineBuffering
  hSetBuffering serverToClientRead LineBuffering
  hSetBuffering clientToServerRead LineBuffering
  hSetBuffering serverToClientWrite LineBuffering

  bracket
    ( do
        tid <- forkIO $ mockServer clientToServerRead serverToClientWrite
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
withInitializedClient action =
  withTestServer $ \transport ->
    withClientSession transport testConfig $ \session -> do
      _ <- initialize session
      action session
 where
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

  it "calls the add tool" $ do
    withInitializedClient $ \session -> do
      CallToolResult{structuredContent = sc} <-
        callTool session "add" (Just $ Map.fromList [("a", toJSON (3 :: Int)), ("b", toJSON (4 :: Int))])
      case sc of
        Just m -> Map.lookup "result" m `shouldBe` Just (toJSON (7 :: Int))
        Nothing -> expectationFailure "Expected structured content"

  it "returns error for non-existent tool" $ do
    withInitializedClient $ \session -> do
      result <- try @MCPClientError $ callTool session "nope" Nothing
      case result of
        Left (RPCError err_code _ _) -> err_code `shouldBe` 404
        _ -> expectationFailure "Expected RPCError"

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
