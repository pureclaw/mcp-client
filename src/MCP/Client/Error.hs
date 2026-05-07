module MCP.Client.Error (
  MCPClientError (..),
) where

import Control.Exception (Exception)
import Data.Aeson (Value)
import Data.Text (Text)
import JSONRPC (RequestId)

-- | Errors that can occur during MCP client operations.
data MCPClientError
  = -- | Transport-level I/O failure (broken pipe, EOF during read, etc.)
    TransportError Text
  | -- | Server returned a different protocol version than expected
    ProtocolVersionMismatch Text Text
  | -- | Server returned a JSON-RPC error: code, message, optional data
    RPCError Int Text (Maybe Value)
  | -- | Could not decode server response JSON into the expected type
    DecodeError Text
  | -- | No response received within the configured timeout
    RequestTimeout RequestId
  | -- | Attempted an API call before initialization completed
    NotInitialized
  | -- | Session has been shut down
    SessionClosed
  deriving (Show)

instance Exception MCPClientError
