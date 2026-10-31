-- | @pigeon-server@ executable: parse the configuration, then run the server.
module Main (main) where

import Pigeon.Server (runServer)
import Pigeon.Server.Config (parseServerConfig)

main :: IO ()
main = parseServerConfig >>= runServer
