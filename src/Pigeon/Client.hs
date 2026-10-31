-- | Client entry point used by the executable and tests.
module Pigeon.Client (
  runClient,
  parseClientConfig,
  ClientConfig (..),
  ClientCommand (..),
) where

import Pigeon.Client.Commands (runClient)
import Pigeon.Client.Config (
  ClientCommand (..),
  ClientConfig (..),
  parseClientConfig,
 )
