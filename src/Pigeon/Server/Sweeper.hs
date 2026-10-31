-- | Expiry sweeping and startup reconciliation.
module Pigeon.Server.Sweeper (
  startSweeper,
  sweepOnce,
  reconcile,
  cleanupOrphans,
  cleanupTempFiles,
) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (Async, async)
import Control.Exception.Safe (SomeException, catch)
import Control.Monad (forM_, forever)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ask)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (UTCTime, diffUTCTime, getCurrentTime)
import System.Directory (getModificationTime)

import Pigeon.Server.App (App, MonadLogger (..), runApp)
import Pigeon.Server.Config (ServerConfig (..))
import Pigeon.Server.Db (
  allIds,
  deleteFileRows,
  deleteRowsMissingBlob,
  expiredIds,
 )
import Pigeon.Server.Env (AppEnv (..))
import Pigeon.Server.Log (logInfo, logWarn)
import Pigeon.Server.Storage (
  blobExists,
  blobPath,
  deleteBlob,
  listBlobIds,
  listTempFiles,
  removeIfExists,
 )
import Pigeon.Types (FileId (..))

{- | Start the background sweeper. The caller must cancel it before closing
the database.
-}
startSweeper :: App (Async ())
startSweeper = do
  env <- ask
  liftIO $ async $ forever $ do
    let seconds = max 1 (scSweepInterval (aeConfig env))
    threadDelay (fromIntegral (seconds * 1000000))
    result <- runApp env (sweepOnce `catch` logSweepFailure)
    case result of
      Left serverError -> logWarn (aeLogger env) ("sweep error: " <> T.pack (show serverError))
      Right () -> pure ()
 where
  logSweepFailure :: SomeException -> App ()
  logSweepFailure (err :: SomeException) = do
    logger <- askLogger
    liftIO (logWarn logger ("sweep failed: " <> T.pack (show err)))

{- | One expiry sweep: commit row deletions, then unlink blobs outside the DB
lock, then clean orphans and stale temp files.
-}
sweepOnce :: App ()
sweepOnce = do
  env <- ask
  now <- liftIO getCurrentTime
  ids <- liftIO (expiredIds (aeDb env) now)
  deleted <- liftIO (deleteFileRows (aeDb env) ids)
  liftIO $ forM_ deleted (deleteBlob (aeStorage env))
  orphans <- cleanupOrphans now
  temps <- cleanupTempFiles now
  logger <- askLogger
  liftIO
    $ logInfo logger
    $ "sweep expired_rows="
      <> T.pack (show (length deleted))
      <> " expired_blobs="
      <> T.pack (show (length deleted))
      <> " orphan_blobs="
      <> T.pack (show orphans)
      <> " temp_files="
      <> T.pack (show temps)
      <> " errors=0"

{- | Startup reconciliation. Removes stale temp files, old orphan blobs, and
rows whose blob is missing.
-}
reconcile :: App ()
reconcile = do
  env <- ask
  now <- liftIO getCurrentTime
  removedTemps <- cleanupTempFiles now
  removedOrphans <- cleanupOrphans now
  missing <- liftIO (deleteRowsMissingBlob (aeDb env) (blobExists (aeStorage env)))
  logger <- askLogger
  liftIO $
    forM_ missing $ \fileId ->
      logWarn logger ("removed row with missing blob id=" <> unFileId fileId)
  liftIO
    $ logInfo logger
    $ "reconcile temp_files="
      <> T.pack (show removedTemps)
      <> " orphan_blobs="
      <> T.pack (show removedOrphans)
      <> " missing_blobs="
      <> T.pack (show (length missing))

-- | Remove blobs with no metadata row whose mtime is older than one hour.
cleanupOrphans :: UTCTime -> App Int
cleanupOrphans now = do
  env <- ask
  known <- liftIO (allIds (aeDb env))
  candidates <- liftIO (listBlobIds (aeStorage env))
  removable <- liftIO $ fmap concat . mapM (check env known) $ candidates
  liftIO $ forM_ removable (deleteBlob (aeStorage env))
  pure (length removable)
 where
  check :: AppEnv -> Set.Set FileId -> FileId -> IO [FileId]
  check env known fileId
    | Set.member fileId known = pure []
    | otherwise = do
        let path = blobPath (aeStorage env) fileId
        old <- isOlderThan now (60 * 60) path
        pure [fileId | old]

-- | Remove temp files older than 24 hours.
cleanupTempFiles :: UTCTime -> App Int
cleanupTempFiles now = do
  env <- ask
  files <- liftIO (listTempFiles (aeStorage env))
  old <- liftIO $ fmap concat . mapM check $ files
  liftIO $ forM_ old removeIfExists
  pure (length old)
 where
  check :: FilePath -> IO [FilePath]
  check path = do
    stale <- isOlderThan now (24 * 60 * 60) path
    pure [path | stale]

isOlderThan :: UTCTime -> Integer -> FilePath -> IO Bool
isOlderThan now seconds path = do
  result <- (Just <$> getModificationTime path) `catch` \(_ :: SomeException) -> pure Nothing
  pure $ case result of
    Nothing -> False
    Just mtime -> diffUTCTime now mtime > fromIntegral seconds
