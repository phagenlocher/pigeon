-- | Redacting logging built on fast-logger.
module Pigeon.Server.Log (
  Logger,
  LogLevel (..),
  MonadLogger (..),
  mkLogger,
  closeLogger,
  logMessage,
  logInfo,
  logWarn,
  logError,
  logDebug,
  writeLog,
  requestLogger,
) where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8With)
import Data.Text.Encoding.Error (lenientDecode)
import Data.Time (diffUTCTime, getCurrentTime)
import Data.Time.Format qualified as Time
import Network.HTTP.Types.Status (statusCode)
import Network.Wai (
  Middleware,
  pathInfo,
  requestMethod,
  responseStatus,
 )
import System.Log.FastLogger qualified as Log

import Pigeon.Server.Config (ServerConfig (..))

-- | Log severity.
data LogLevel = Debug | Info | Warn | Error
  deriving (Eq, Ord, Show)

-- | A logger with a minimum level.
data Logger = Logger
  { lgSet :: Log.LoggerSet,
    lgMinLevel :: LogLevel,
    lgQuiet :: Bool
  }

-- | Ambient access to a logger.
class (MonadIO m) => MonadLogger m where
  -- | Obtain the logger from the surrounding environment.
  askLogger :: m Logger

{- | Create a stderr logger. @--quiet@ hides request logs but not errors and
warnings; @--verbose@ lowers the minimum level to 'Debug'.
-}
mkLogger :: ServerConfig -> IO Logger
mkLogger cfg = do
  set <- Log.newStderrLoggerSet Log.defaultBufSize
  let minLevel :: LogLevel
      minLevel
        | scVerbose cfg = Debug
        | otherwise = Info
  pure Logger{lgSet = set, lgMinLevel = minLevel, lgQuiet = scQuiet cfg}

closeLogger :: Logger -> IO ()
closeLogger = Log.rmLoggerSet . lgSet

-- | Write a message at a specific level using the ambient logger.
logMessage :: (MonadLogger m) => LogLevel -> Text -> m ()
logMessage level message = do
  logger <- askLogger
  liftIO (writeLog logger level message)

-- | Write an informational message using the ambient logger.
logInfo :: (MonadLogger m) => Text -> m ()
logInfo = logMessage Info

-- | Write a warning using the ambient logger.
logWarn :: (MonadLogger m) => Text -> m ()
logWarn = logMessage Warn

-- | Write an error using the ambient logger.
logError :: (MonadLogger m) => Text -> m ()
logError = logMessage Error

-- | Write a debug message using the ambient logger.
logDebug :: (MonadLogger m) => Text -> m ()
logDebug = logMessage Debug

-- | Write a message to an explicit logger.
writeLog :: Logger -> LogLevel -> Text -> IO ()
writeLog logger level message =
  whenLevel level $ do
    timestamp <- currentTimestamp
    let line = timestamp <> " " <> T.pack (show level) <> " " <> message <> "\n"
    Log.pushLogStr (lgSet logger) (Log.toLogStr line)
 where
  whenLevel :: LogLevel -> IO () -> IO ()
  whenLevel lvl action
    | lvl >= lgMinLevel logger = action
    | otherwise = pure ()

currentTimestamp :: IO Text
currentTimestamp =
  T.pack
    . Time.formatTime Time.defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ"
    <$> getCurrentTime

{- | Redacting request-log middleware. It logs the path without the query
string, the method, status, and duration. It never logs headers or bodies.
-}
requestLogger :: Logger -> Middleware
requestLogger logger app request respond
  | lgQuiet logger = app request respond
  | otherwise = do
      start <- getCurrentTime
      app request $ \response -> do
        end <- getCurrentTime
        let elapsedMs = round (realToFrac (diffUTCTime end start) * (1000 :: Double)) :: Int
            path = "/" <> T.intercalate "/" (pathInfo request)
            status = responseStatus response
            message =
              "request method="
                <> decodeUtf8With lenientDecode (requestMethod request)
                <> " path="
                <> path
                <> " status="
                <> T.pack (show (statusCode status))
                <> " duration_ms="
                <> T.pack (show (elapsedMs :: Int))
        writeLog logger Info message
        respond response
