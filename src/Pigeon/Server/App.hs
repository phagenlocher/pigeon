-- | The server application monad.
module Pigeon.Server.App (
  App (..),
  runApp,
  appToHandler,
) where

import Control.Exception.Safe (MonadCatch, MonadMask, MonadThrow)
import Control.Monad.Except (ExceptT (..), MonadError, runExceptT)
import Control.Monad.IO.Class (MonadIO)
import Control.Monad.Reader (MonadReader, ReaderT, asks, runReaderT)
import Servant.Server (Handler (..), ServerError)

import Pigeon.Server.Env (AppEnv (..))
import Pigeon.Server.Log (MonadLogger (..))

{- | Server orchestration runs here. It has the ambient 'AppEnv', can raise
'ServerError' values, and uses the 'safe-exceptions' classes.
-}
newtype App a = App
  { unApp :: ExceptT ServerError (ReaderT AppEnv IO) a
  }
  deriving newtype
    ( Applicative,
      Functor,
      Monad,
      MonadCatch,
      MonadError ServerError,
      MonadIO,
      MonadMask,
      MonadReader AppEnv,
      MonadThrow
    )

instance MonadLogger App where
  askLogger = asks aeLogger

-- | Run an 'App' action, returning either its error or its value.
runApp :: AppEnv -> App a -> IO (Either ServerError a)
runApp env (App action) = runReaderT (runExceptT action) env

-- | Natural transformation used with 'Servant.Server.hoistServer'.
appToHandler :: AppEnv -> App a -> Handler a
appToHandler env action = Handler (ExceptT (runApp env action))
