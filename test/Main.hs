module Main where

import MCP.Client.StdioIntegration (stdioClientIntegrationSpec)
import Test.Hspec (hspec)

main :: IO ()
main = hspec stdioClientIntegrationSpec
