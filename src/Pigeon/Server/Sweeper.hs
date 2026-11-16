-- | Expiry sweeping and startup reconciliation.
module Pigeon.Server.Sweeper (
  SweepCounts (..),
  sweepShouldLog,
  startSweeper,
  sweepOnce,
  reconcile,
  cleanupOrphans,
  cleanupTempFiles,
) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (Async, async)
import Control.Exception.Safe (SomeException, catch)
import Control.Monad (forM, forM_, forever, when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ask)
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (UTCTime, diffUTCTime, getCurrentTime)
import System.Directory (getModificationTime, removeDirectory)

import Pigeon.Server.App (App, runApp)
import Pigeon.Server.Config (ServerConfig (..))
import Pigeon.Server.Db (
  allIds,
  deleteFileRows,
  deleteRowsMissingBlob,
  deleteTokenAndFiles,
  expiredIds,
  expiredUserTokens,
 )
import Pigeon.Server.Env (AppEnv (..))
import Pigeon.Server.Log (LogLevel (..), logInfo, logWarn, writeLog)
import Pigeon.Server.Storage (
  Storage,
  blobExists,
  blobPath,
  deleteBlob,
  listBlobIds,
  listTempFiles,
  ownerDir,
  removeIfExists,
 )
import Pigeon.Types (FileId (..), OwnerId (..))

-- | Counts reported by one sweep pass.
data SweepCounts = SweepCounts
  { sweepExpiredRows :: !Int,
    sweepExpiredTokens :: !Int,
    sweepOrphanBlobs :: !Int,
    sweepTempFiles :: !Int
  }
  deriving (Eq, Show)

{- | Whether a sweep summary should be logged. An idle sweep stays silent
unless verbose logging is enabled.
-}
sweepShouldLog :: Bool -> SweepCounts -> Bool
sweepShouldLog verbose counts =
  verbose
    || sweepExpiredRows counts > 0
    || sweepExpiredTokens counts > 0
    || sweepOrphanBlobs counts > 0
    || sweepTempFiles counts > 0

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
      Left serverError -> writeLog (aeLogger env) Warn ("sweep error: " <> T.pack (show serverError))
      Right () -> pure ()
 where
  logSweepFailure :: SomeException -> App ()
  logSweepFailure (err :: SomeException) =
    logWarn ("sweep failed: " <> T.pack (show err))

{- | One expiry sweep: commit row deletions, then unlink blobs outside the DB
lock, then clean orphans and stale temp files.
-}
sweepOnce :: App ()
sweepOnce = do
  env <- ask
  now <- liftIO getCurrentTime
  ids <- liftIO (expiredIds (aeDb env) now)
  deleted <- liftIO (deleteFileRows (aeDb env) ids)
  liftIO $ forM_ deleted (uncurry (deleteBlob (aeStorage env)))
  expiredTokens <- liftIO (expiredUserTokens (aeDb env) now)
  tokenFiles <-
    liftIO $
      forM expiredTokens $ \owner -> do
        deletedFiles <- deleteTokenAndFiles (aeDb env) owner
        let fileIds = fromMaybe [] deletedFiles
        mapM_ (deleteBlob (aeStorage env) owner) fileIds
        removeOwnerDirIfEmpty (aeStorage env) owner
        pure (length fileIds)
  orphans <- cleanupOrphans now
  temps <- cleanupTempFiles now
  let counts :: SweepCounts
      counts =
        SweepCounts
          { sweepExpiredRows = length deleted,
            sweepExpiredTokens = length tokenFiles,
            sweepOrphanBlobs = orphans,
            sweepTempFiles = temps
          }
  when (sweepShouldLog (scVerbose (aeConfig env)) counts)
    $ logInfo
    $ "sweep expired_rows="
      <> T.pack (show (sweepExpiredRows counts))
      <> " expired_tokens="
      <> T.pack (show (sweepExpiredTokens counts))
      <> " expired_token_files="
      <> T.pack (show (sum tokenFiles))
      <> " expired_blobs="
      <> T.pack (show (sweepExpiredRows counts))
      <> " orphan_blobs="
      <> T.pack (show (sweepOrphanBlobs counts))
      <> " temp_files="
      <> T.pack (show (sweepTempFiles counts))
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
  missing <-
    liftIO
      ( deleteRowsMissingBlob
          (aeDb env)
          (uncurry (blobExists (aeStorage env)))
      )
  forM_ missing $ \(_, fileId) ->
    logWarn ("removed row with missing blob id=" <> unFileId fileId)
  logInfo $
    "reconcile temp_files="
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
  liftIO $ forM_ removable (uncurry (deleteBlob (aeStorage env)))
  pure (length removable)
 where
  check :: AppEnv -> Set.Set (OwnerId, FileId) -> (OwnerId, FileId) -> IO [(OwnerId, FileId)]
  check env known pair@(owner, fileId)
    | Set.member pair known = pure []
    | otherwise = do
        let path = blobPath (aeStorage env) owner fileId
        old <- isOlderThan now (60 * 60) path
        pure [pair | old]

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

-- | Remove an owner directory when no blobs remain. Best effort.
removeOwnerDirIfEmpty :: Storage -> OwnerId -> IO ()
removeOwnerDirIfEmpty storage owner =
  removeDirectory (ownerDir storage owner)
    `catch` \(_ :: SomeException) -> pure ()
