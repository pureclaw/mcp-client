module MCP.Client.Transport (
  Transport (..),
) where

import JSONRPC (JSONRPCMessage)

-- | Abstract transport for sending and receiving JSON-RPC messages.
--
-- A record-of-functions rather than a typeclass, keeping 'ClientSession'
-- monomorphic and making it easy to build transports from any I/O backend.
data Transport = Transport
  { transport_send :: JSONRPCMessage -> IO ()
  -- ^ Send a JSON-RPC message to the server.
  , transport_receive :: IO (Maybe JSONRPCMessage)
  -- ^ Receive the next message from the server.
  -- Returns 'Nothing' on EOF or when the transport is closed.
  , transport_close :: IO ()
  -- ^ Close the transport and release associated resources.
  }
