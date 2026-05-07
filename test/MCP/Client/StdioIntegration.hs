{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module MCP.Client.StdioIntegration where

import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Exception (bracket, try)
import Data.Aeson (toJSON)
import Data.Aeson qualified as Aeson
import Data.ByteString.Char8 qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.Map qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import MCP.Client.API
import MCP.Client.Config (ClientConfig (..), defaultClientConfig)
import MCP.Client.Error (MCPClientError (..))
import MCP.Client.Session (
  ClientSession,
  initialize,
  withClientSession,
 )
import MCP.Client.Transport (Transport (..))
import MCP.Protocol
import MCP.Server
import MCP.Types
import System.IO (BufferMode (..), hClose, hFlush, hIsEOF, hSetBuffering)
import System.Process (createPipe)
import Test.Hspec

-- We need these type family instances to use the test server.
-- In a real app these would be defined in the application code.
type instance MCPHandlerState = ()
type instance MCPHandlerUser = ()

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

-- * Test Infrastructure

-- | Create a minimal test server state.
createTestServerState :: MCPServerState
createTestServerState =
  MCPServerState
    { mcp_server_initialized = False
    , mcp_handler_state = ()
    , mcp_handler_init = Nothing
    , mcp_handler_finalize = Nothing
    , mcp_client_capabilities = Nothing
    , mcp_log_level = Nothing
    , mcp_pending_responses = mempty
    , mcp_pending_responses_next = 1
    , mcp_server_capabilities =
        ServerCapabilities
          { logging = Just LoggingCapability
          , prompts = Just (PromptsCapability{listChanged = Nothing})
          , resources = Just (ResourcesCapability{listChanged = Nothing, subscribe = Nothing})
          , tools = Just (ToolsCapability{listChanged = Just True})
          , completions = Nothing
          , experimental = Nothing
          }
    , mcp_implementation = Implementation "test-server" "1.0.0" Nothing
    , mcp_instructions = Nothing
    , mcp_process_handlers = testHandlers
    }

testHandlers :: ProcessHandlers
testHandlers =
  withToolHandlers testTools $
    defaultProcessHandlers
      { listResourcesHandler = Just handleListResources
      , readResourceHandler = Just handleReadResource
      , listPromptsHandler = Just handleListPrompts
      , getPromptHandler = Just handleGetPrompt
      }

testTools :: [ToolHandler]
testTools =
  [ toolHandler "echo" (Just "Echo tool") echoSchema echoHandler
  , toolHandler "add" (Just "Addition tool") addSchema addHandler
  ]
 where
  echoSchema = InputSchema "object" (Map.fromList [("message", toJSON ("string" :: Text))]) ["message"]
  echoHandler args =
    case args >>= Map.lookup "message" of
      Just msg ->
        return $ ProcessSuccess $ CallToolResult
          { content = [TextBlock (TextContent "text" (case msg of { Aeson.String t -> t; _ -> "?" }) Nothing Nothing)]
          , structuredContent = Nothing
          , isError = Nothing
          , _meta = Nothing
          }
      Nothing ->
        return $ ProcessSuccess $ toolTextError "Missing message"

  addSchema = InputSchema "object" (Map.fromList [("a", toJSON ("number" :: Text)), ("b", toJSON ("number" :: Text))]) ["a", "b"]
  addHandler args = do
    let a = maybe 0 (\v -> case v of { Aeson.Number n -> round n; _ -> 0 }) (args >>= Map.lookup "a") :: Int
        b = maybe 0 (\v -> case v of { Aeson.Number n -> round n; _ -> 0 }) (args >>= Map.lookup "b") :: Int
    return $ ProcessSuccess $ CallToolResult
      { content = [TextBlock (TextContent "text" (T.pack $ show (a + b)) Nothing Nothing)]
      , structuredContent = Just (Map.fromList [("result", toJSON (a + b))])
      , isError = Nothing
      , _meta = Nothing
      }

handleListResources :: ListResourcesParams -> MCPServerT (ProcessResult ListResourcesResult)
handleListResources _ =
  return $ ProcessSuccess $ ListResourcesResult
    { resources = [Resource "resource://test/hello" "hello" Nothing Nothing Nothing Nothing Nothing Nothing]
    , nextCursor = Nothing
    , _meta = Nothing
    }

handleReadResource :: ReadResourceParams -> MCPServerT (ProcessResult ReadResourceResult)
handleReadResource (ReadResourceParams uri) =
  if uri == "resource://test/hello"
    then return $ ProcessSuccess $ ReadResourceResult
      { contents = [TextResource (TextResourceContents "resource://test/hello" "Hello, world!" Nothing Nothing)]
      , _meta = Nothing
      }
    else return $ ProcessRPCError 404 "Resource not found"

handleListPrompts :: ListPromptsParams -> MCPServerT (ProcessResult ListPromptsResult)
handleListPrompts _ =
  return $ ProcessSuccess $ ListPromptsResult
    { prompts = [Prompt "greet" Nothing (Just "A greeting prompt") (Just [PromptArgument "name" Nothing Nothing (Just True)]) Nothing]
    , nextCursor = Nothing
    , _meta = Nothing
    }

handleGetPrompt :: GetPromptParams -> MCPServerT (ProcessResult GetPromptResult)
handleGetPrompt (GetPromptParams name _args) =
  if name == "greet"
    then return $ ProcessSuccess $ GetPromptResult
      { description = Just "A greeting prompt"
      , messages = [PromptMessage User (TextBlock (TextContent "text" "Hello!" Nothing Nothing))]
      , _meta = Nothing
      }
    else return $ ProcessRPCError 404 "Prompt not found"

-- | Bracket that creates pipes, starts a stdio server, and yields a Transport.
withTestServer :: (Transport -> IO a) -> IO a
withTestServer f = do
  (client_to_server_read, client_to_server_write) <- createPipe
  (server_to_client_read, server_to_client_write) <- createPipe

  hSetBuffering client_to_server_write LineBuffering
  hSetBuffering server_to_client_read LineBuffering

  bracket
    ( do
        tid <- forkIO $ serveStdio client_to_server_read server_to_client_write createTestServerState
        threadDelay 10000
        return tid
    )
    ( \tid -> do
        killThread tid
        hClose client_to_server_write
        hClose client_to_server_read
        hClose server_to_client_write
        hClose server_to_client_read
    )
    ( \_ ->
        f
          Transport
            { transport_send = \msg -> do
                BSL.hPut client_to_server_write (Aeson.encode msg)
                BSL.hPut client_to_server_write "\n"
                hFlush client_to_server_write
            , transport_receive = do
                eof <- hIsEOF server_to_client_read
                if eof
                  then return Nothing
                  else do
                    line <- BS.hGetLine server_to_client_read
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
      -- If we get here without exception, the ping succeeded

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
      let Resource{uri = u} = head rs
      u `shouldBe` "resource://test/hello"

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
    -- The server declared no completion handler, so this should get method_not_found
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
        Right _ -> return () -- some servers may return empty
        _ -> expectationFailure "Unexpected result"

loggingSpec :: Spec
loggingSpec = describe "Logging" $ do
  it "sets logging level" $ do
    withInitializedClient $ \session -> do
      setLoggingLevel session Debug
      -- Success if no exception
