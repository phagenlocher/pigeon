{- | @pigeon-client@ executable: parse the configuration, run the selected
command, and exit with its status.
-}
module Main (main) where

import System.Exit (exitWith)

import Pigeon.Client (parseClientConfig, runClient)

main :: IO ()
main = parseClientConfig >>= runClient >>= exitWith
