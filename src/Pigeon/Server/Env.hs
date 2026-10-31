{- | The server application environment shared by handlers, web routes, and
the sweeper.
-}
module Pigeon.Server.Env (
  AppEnv (..),
) where

import Data.Time (UTCTime)

import Pigeon.Server.Config (ServerConfig)
import Pigeon.Server.Db (Db)
import Pigeon.Server.Log (Logger)
import Pigeon.Server.Storage (Storage)

data AppEnv = AppEnv
  { aeConfig :: ServerConfig,
    aeDb :: Db,
    aeStorage :: Storage,
    aeLogger :: Logger,
    aeStart :: UTCTime
  }
