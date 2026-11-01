{- | SQLite metadata storage.

The connection is guarded by an 'MVar'. Every function takes the lock only
for the duration of a short query; callers must never hold it while
streaming a request body, writing a blob, or streaming a response.
-}
module Pigeon.Server.Db (
  Db,
  openDb,
  closeDb,
  migrate,
  withConn,
  pingDb,
  insertFile,
  lookupFile,
  listLiveFiles,
  deleteFileRow,
  deleteFileRows,
  expiredIds,
  allIds,
  allFiles,
  deleteRowsMissingBlob,
  isUniqueViolation,
) where

import Control.Concurrent.MVar
import Control.Exception.Safe (SomeException, bracket, mask, onException, throwIO, try)
import Control.Monad (forM, void)
import Data.Int (Int64)
import Data.Maybe (catMaybes)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import Database.SQLite.Simple
import System.Directory (makeAbsolute)
import System.FilePath (normalise, takeDirectory, takeFileName)
import System.Posix.IO (closeFd)

import Pigeon.Server.PathSafety (
  UnsafePath (..),
  ensureSafeParentDirectory,
  prepareDatabaseFile,
  verifyFileIdentity,
 )
import Pigeon.Types (
  FileId (..),
  StoredFile (..),
  epochToUtc,
  mkFileId,
  utcToEpoch,
 )

-- | A handle to the single SQLite connection.
newtype Db = Db {dbConnection :: MVar Connection}

-- | Open the database, apply pragmas, and return a guarded handle.
openDb :: FilePath -> IO Db
openDb path = do
  dbPath <- normalise <$> makeAbsolute path
  bracket (ensureSafeParentDirectory (takeDirectory dbPath)) closeFd $ \parentFd -> do
    identity <- prepareDatabaseFile parentFd (takeFileName dbPath)
    connection <- open dbPath
    matches <- verifyFileIdentity dbPath identity
    if not matches
      then do
        close connection
        throwIO (UnsafePath ("database path changed while opening: " <> T.pack dbPath))
      else do
        applyPragmas connection `onException` close connection
        Db <$> newMVar connection

applyPragmas :: Connection -> IO ()
applyPragmas connection = do
  void (query_ connection "PRAGMA journal_mode = DELETE" :: IO [Only Text])
  void (query_ connection "PRAGMA synchronous = FULL" :: IO [Only Int])
  execute_ connection "PRAGMA busy_timeout = 5000"
  execute_ connection "PRAGMA foreign_keys = ON"
  execute_ connection "PRAGMA temp_store = MEMORY"

-- | Close the guarded connection.
closeDb :: Db -> IO ()
closeDb (Db lock) = mask $ \restore -> do
  connection <- takeMVar lock
  restore (close connection) `onException` putMVar lock connection

-- | Run a short action with the raw connection while holding the lock.
withConn :: Db -> (Connection -> IO a) -> IO a
withConn db = withMVar (dbConnection db)

-- | @SELECT 1@ health check.
pingDb :: Db -> IO Bool
pingDb db = do
  result <- try (withConn db (\c -> void (query_ c "SELECT 1" :: IO [Only Int])))
  pure $ case result of
    Left (_ :: SomeException) -> False
    Right () -> True

-- | Create or validate the schema.
migrate :: Db -> IO ()
migrate db = withConn db $ \connection -> do
  versions <- query_ connection "PRAGMA user_version" :: IO [Only Int]
  case versions of
    [Only 0] -> do
      mapM_ (execute_ connection) schemaStatements
      execute_ connection "PRAGMA user_version = 1"
    [Only 1] -> pure ()
    _ -> throwIO (userError "unsupported database schema version")

schemaStatements :: [Query]
schemaStatements =
  [ "CREATE TABLE IF NOT EXISTS files (\
    \ id TEXT PRIMARY KEY NOT NULL,\
    \ filename TEXT NOT NULL,\
    \ content_type TEXT NOT NULL,\
    \ size_original INTEGER NOT NULL CHECK (size_original >= 0),\
    \ size_stored INTEGER NOT NULL CHECK (size_stored >= 0),\
    \ password_hash TEXT,\
    \ created_at INTEGER NOT NULL,\
    \ expires_at INTEGER NOT NULL,\
    \ CHECK (expires_at > created_at),\
    \ CHECK (password_hash IS NULL OR length(password_hash) > 0)\
    \ )",
    "CREATE INDEX IF NOT EXISTS idx_files_expires_at ON files (expires_at)",
    "CREATE INDEX IF NOT EXISTS idx_files_created_at ON files (created_at DESC)"
  ]

-- * Queries

insertFile :: Db -> StoredFile -> IO ()
insertFile db StoredFile{..} = withConn db $ \connection ->
  execute
    connection
    "INSERT INTO files \
    \(id, filename, content_type, size_original, size_stored, password_hash, created_at, expires_at) \
    \VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
    ( unFileId sfId,
      sfFilename,
      sfContentType,
      sfSize,
      sfStoredSize,
      sfPasswordHash,
      utcToEpoch sfCreatedAt,
      utcToEpoch sfExpiresAt
    )

lookupFile :: Db -> FileId -> IO (Maybe StoredFile)
lookupFile db fileId = withConn db $ \connection -> do
  rows <-
    query
      connection
      "SELECT id, filename, content_type, size_original, size_stored, password_hash, created_at, expires_at \
      \FROM files WHERE id = ?"
      (Only (unFileId fileId))
  case rows of
    [] -> pure Nothing
    (row : _) -> Just <$> rowToStored row

listLiveFiles :: Db -> UTCTime -> IO [StoredFile]
listLiveFiles db now = withConn db $ \connection -> do
  rows <-
    query
      connection
      "SELECT id, filename, content_type, size_original, size_stored, password_hash, created_at, expires_at \
      \FROM files WHERE expires_at > ? ORDER BY created_at DESC, id ASC"
      (Only (utcToEpoch now))
  mapM rowToStored rows

allFiles :: Db -> IO [StoredFile]
allFiles db = withConn db $ \connection -> do
  rows <-
    query_
      connection
      "SELECT id, filename, content_type, size_original, size_stored, password_hash, created_at, expires_at \
      \FROM files"
  mapM rowToStored rows

allIds :: Db -> IO (Set FileId)
allIds db = withConn db $ \connection -> do
  rows <- query_ connection "SELECT id FROM files" :: IO [Only Text]
  pure (Set.fromList [FileId t | Only t <- rows])

deleteFileRow :: Db -> FileId -> IO Bool
deleteFileRow db fileId = withConn db $ \connection ->
  withImmediate connection $ do
    execute connection "DELETE FROM files WHERE id = ?" (Only (unFileId fileId))
    changed <- changes connection
    pure (changed > 0)

{- | Delete several rows in one immediate transaction. Returns the ids that
existed before deletion.
-}
deleteFileRows :: Db -> [FileId] -> IO [FileId]
deleteFileRows _ [] = pure []
deleteFileRows db ids = withConn db $ \connection ->
  withImmediate connection $ do
    deleted <-
      forM ids $ \fid -> do
        execute connection "DELETE FROM files WHERE id = ?" (Only (unFileId fid))
        changed <- changes connection
        pure (if changed > 0 then Just fid else Nothing)
    pure (catMaybes deleted)

expiredIds :: Db -> UTCTime -> IO [FileId]
expiredIds db now = withConn db $ \connection -> do
  rows <- query connection "SELECT id FROM files WHERE expires_at <= ?" (Only (utcToEpoch now))
  pure [FileId t | Only t <- rows]

{- | Delete rows whose blob is missing. The predicate runs while the lock is
held, so it must only stat a file, never stream it.
-}
deleteRowsMissingBlob :: Db -> (FileId -> IO Bool) -> IO [FileId]
deleteRowsMissingBlob db blobExists = do
  files <- allFiles db
  missing <- fmap catMaybes . mapM check $ files
  if null missing
    then pure []
    else deleteFileRows db (map sfId missing)
 where
  check :: StoredFile -> IO (Maybe StoredFile)
  check stored = do
    exists <- blobExists (sfId stored)
    pure (if exists then Nothing else Just stored)

-- * Helpers

type Row =
  ( Text,
    Text,
    Text,
    Int64,
    Int64,
    Maybe Text,
    Int64,
    Int64
  )

rowToStored :: Row -> IO StoredFile
rowToStored (rawId, filename, contentType, sizeOriginal, sizeStored, passwordHash, createdAt, expiresAt) =
  case mkFileId rawId of
    Left err -> throwIO (userError ("corrupt file id in database: " <> T.unpack err))
    Right fileId ->
      pure
        StoredFile
          { sfId = fileId,
            sfFilename = filename,
            sfContentType = contentType,
            sfSize = sizeOriginal,
            sfStoredSize = sizeStored,
            sfPasswordHash = passwordHash,
            sfCreatedAt = epochToUtc createdAt,
            sfExpiresAt = epochToUtc expiresAt
          }

-- | @BEGIN IMMEDIATE@ so the write lock is taken at transaction start.
withImmediate :: Connection -> IO a -> IO a
withImmediate connection action = mask $ \restore -> do
  execute_ connection "BEGIN IMMEDIATE"
  result <- restore action `onException` rollback
  commitResult <- try (execute_ connection "COMMIT") :: IO (Either SomeException ())
  case commitResult of
    Left err -> do
      rollback
      throwIO err
    Right () -> pure result
 where
  rollback :: IO ()
  rollback = void (try (execute_ connection "ROLLBACK") :: IO (Either SomeException ()))

-- | Detect a SQLite UNIQUE constraint violation.
isUniqueViolation :: SQLError -> Bool
isUniqueViolation sqlError =
  "UNIQUE constraint failed" `T.isInfixOf` sqlErrorDetails sqlError
