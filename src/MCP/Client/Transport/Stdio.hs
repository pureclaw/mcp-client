module MCP.Client.Transport.Stdio (
  withStdioTransport,
) where

import Control.Exception (bracket, catch, SomeException)
import Data.Aeson qualified as Aeson
import Data.ByteString.Char8 qualified as BS
import Data.ByteString.Lazy qualified as BSL
import MCP.Client.Transport (Transport (..))
import System.IO (
  BufferMode (..),
  Handle,
  hClose,
  hFlush,
  hIsEOF,
  hSetBuffering,
 )
import System.Process (
  CreateProcess (..),
  ProcessHandle,
  StdStream (..),
  cleanupProcess,
  createProcess,
  waitForProcess,
 )
import System.Timeout (timeout)

-- | Run an action with a stdio transport connected to a child process.
--
-- The child process is spawned with its stdin and stdout connected to the
-- transport.  On exit (normal or exceptional), the child is shut down
-- gracefully: stdin is closed, then we wait up to 2 seconds for the process
-- to exit before terminating it.
withStdioTransport :: CreateProcess -> (Transport -> IO a) -> IO a
withStdioTransport cp action =
  bracket (startProcess cp) stopProcess $ \(h_in, h_out, ph) ->
    action (mkTransport h_in h_out ph)

-- | Construct a 'Transport' from the child's stdin/stdout handles.
mkTransport :: Handle -> Handle -> ProcessHandle -> Transport
mkTransport h_in h_out ph =
  Transport
    { transport_send = \msg -> do
        BSL.hPut h_in (Aeson.encode msg)
        BSL.hPut h_in "\n"
        hFlush h_in
    , transport_receive = do
        eof <- hIsEOF h_out
        if eof
          then return Nothing
          else do
            line <- BS.hGetLine h_out
            case Aeson.eitherDecodeStrict' line of
              Right msg -> return (Just msg)
              Left err -> do
                -- Skip malformed lines from the server (e.g. debug output)
                -- rather than crashing the client.  In practice MCP servers
                -- should only write valid JSON-RPC to stdout.
                let _ = err
                transport_receive (mkTransport h_in h_out ph)
    , transport_close = stopProcess (h_in, h_out, ph)
    }

startProcess :: CreateProcess -> IO (Handle, Handle, ProcessHandle)
startProcess cp = do
  let cp' = cp{std_in = CreatePipe, std_out = CreatePipe, std_err = Inherit}
  (Just h_in, Just h_out, _h_err, ph) <- createProcess cp'
  hSetBuffering h_in LineBuffering
  hSetBuffering h_out LineBuffering
  return (h_in, h_out, ph)

stopProcess :: (Handle, Handle, ProcessHandle) -> IO ()
stopProcess (h_in, h_out, ph) = do
  -- Close stdin to signal EOF to the child
  hClose h_in `catch` \(_ :: SomeException) -> return ()
  -- Wait up to 2 seconds for graceful exit
  exited <- timeout 2_000_000 (waitForProcess ph)
  case exited of
    Just _ -> hClose h_out `catch` \(_ :: SomeException) -> return ()
    Nothing -> do
      -- Force cleanup: sends SIGTERM then waits, then SIGKILL
      cleanupProcess (Nothing, Just h_out, Nothing, ph)
