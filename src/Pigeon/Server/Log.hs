-- | Redacting logging built on fast-logger.
module Pigeon.Server.Log (
  Logger,
  LogLevel (..),
  mkLogger,
  closeLogger,
  logMessage,
  logInfo,
  logWarn,
  logError,
  logDebug,
  requestLogger,
) where

import Data.ByteString.Char8 qualified as B8
import Data.Text (Text)
import Data.Text qualified as T
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

logMessage :: Logger -> LogLevel -> Text -> IO ()
logMessage logger level message =
  whenLevel level $ do
    timestamp <- currentTimestamp
    let line = timestamp <> " " <> T.pack (show level) <> " " <> message <> "\n"
    Log.pushLogStr (lgSet logger) (Log.toLogStr line)
 where
  whenLevel :: LogLevel -> IO () -> IO ()
  whenLevel lvl action
    | lvl >= lgMinLevel logger = action
    | otherwise = pure ()

logInfo, logWarn, logError, logDebug :: Logger -> Text -> IO ()
logInfo logger = logMessage logger Info
logWarn logger = logMessage logger Warn
logError logger = logMessage logger Error
logDebug logger = logMessage logger Debug

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
                <> T.pack (B8.unpack (requestMethod request))
                <> " path="
                <> path
                <> " status="
                <> T.pack (show (statusCode status))
                <> " duration_ms="
                <> T.pack (show (elapsedMs :: Int))
        logInfo logger message
        respond response
