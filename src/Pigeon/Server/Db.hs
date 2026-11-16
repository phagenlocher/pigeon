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
  listLiveFilesForOwner,
  deleteFileRow,
  deleteFileRowOwnedBy,
  deleteFileRows,
  expiredIds,
  allIds,
  allFiles,
  deleteRowsMissingBlob,
  insertToken,
  lookupToken,
  listLiveUserTokens,
  deleteTokenAndFiles,
  expiredUserTokens,
  isUniqueViolation,
) where

import Control.Concurrent.MVar
import Control.Exception.Safe (SomeException, bracket, mask, onException, throwIO, try)
import Control.Monad (forM, unless, void)
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
  OwnerId (..),
  StoredFile (..),
  StoredToken (..),
  TokenInfo (..),
  epochToUtc,
  isValidOwnerId,
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

{- | Create or validate the schema.

The schema is still version 1: user tokens and owner-scoped files are part of
the initial schema. There is no migration from an earlier development schema;
such a database is rejected with a clear error instead of being modified.
-}
migrate :: Db -> IO ()
migrate db = withConn db $ \connection -> do
  versions <- query_ connection "PRAGMA user_version" :: IO [Only Int]
  case versions of
    [Only 0] -> do
      mapM_ (execute_ connection) schemaStatements
      execute_ connection "PRAGMA user_version = 1"
    [Only 1] -> validateSchema connection
    _ -> throwIO (userError "unsupported database schema version")

{- | Reject a version-1 database that predates user tokens. The operator must
recreate the development data directory; this function never changes the
database or its @user_version@.
-}
validateSchema :: Connection -> IO ()
validateSchema connection = do
  tokenTable <-
    query
      connection
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?"
      (Only ("tokens" :: Text)) ::
      IO [Only Text]
  ownerColumn <-
    query
      connection
      "SELECT 1 FROM pragma_table_info('files') WHERE name = ?"
      (Only ("owner_id" :: Text)) ::
      IO [Only Int]
  unless (not (null tokenTable) && not (null ownerColumn)) $
    throwIO
      ( userError
          "database schema predates user tokens; recreate the data directory"
      )

schemaStatements :: [Query]
schemaStatements =
  [ "CREATE TABLE IF NOT EXISTS tokens (\
    \ id TEXT PRIMARY KEY NOT NULL,\
    \ kind TEXT NOT NULL CHECK (kind IN ('admin', 'user')),\
    \ token_hash BLOB,\
    \ created_at INTEGER NOT NULL,\
    \ expires_at INTEGER,\
    \ CHECK (\
    \   (kind = 'admin' AND id = 'admin' AND token_hash IS NULL AND expires_at IS NULL)\
    \   OR\
    \   (kind = 'user' AND token_hash IS NOT NULL)\
    \ ),\
    \ CHECK (expires_at IS NULL OR expires_at > created_at)\
    \ )",
    "INSERT OR IGNORE INTO tokens (id, kind, token_hash, created_at, expires_at) \
    \VALUES ('admin', 'admin', NULL, 0, NULL)",
    "CREATE TABLE IF NOT EXISTS files (\
    \ id TEXT PRIMARY KEY NOT NULL,\
    \ owner_id TEXT NOT NULL REFERENCES tokens (id) ON DELETE RESTRICT,\
    \ filename TEXT NOT NULL,\
    \ size_original INTEGER NOT NULL CHECK (size_original >= 0),\
    \ size_stored INTEGER NOT NULL CHECK (size_stored >= 0),\
    \ password_hash TEXT,\
    \ created_at INTEGER NOT NULL,\
    \ expires_at INTEGER NOT NULL,\
    \ CHECK (expires_at > created_at),\
    \ CHECK (password_hash IS NULL OR length(password_hash) > 0)\
    \ )",
    "CREATE INDEX IF NOT EXISTS idx_files_expires_at ON files (expires_at)",
    "CREATE INDEX IF NOT EXISTS idx_files_created_at ON files (created_at DESC)",
    "CREATE INDEX IF NOT EXISTS idx_files_owner_expires ON files (owner_id, expires_at)"
  ]

-- * File queries

insertFile :: Db -> StoredFile -> IO ()
insertFile db StoredFile{..} = withConn db $ \connection ->
  execute
    connection
    "INSERT INTO files \
    \(id, owner_id, filename, size_original, size_stored, password_hash, created_at, expires_at) \
    \VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
    ( unFileId sfId,
      unOwnerId sfOwnerId,
      sfFilename,
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
      "SELECT id, owner_id, filename, size_original, size_stored, password_hash, created_at, expires_at \
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
      "SELECT id, owner_id, filename, size_original, size_stored, password_hash, created_at, expires_at \
      \FROM files WHERE expires_at > ? ORDER BY created_at DESC, id ASC"
      (Only (utcToEpoch now))
  mapM rowToStored rows

-- | List live files belonging to one owner.
listLiveFilesForOwner :: Db -> OwnerId -> UTCTime -> IO [StoredFile]
listLiveFilesForOwner db owner now = withConn db $ \connection -> do
  rows <-
    query
      connection
      "SELECT id, owner_id, filename, size_original, size_stored, password_hash, created_at, expires_at \
      \FROM files WHERE owner_id = ? AND expires_at > ? ORDER BY created_at DESC, id ASC"
      (unOwnerId owner, utcToEpoch now)
  mapM rowToStored rows

allFiles :: Db -> IO [StoredFile]
allFiles db = withConn db $ \connection -> do
  rows <-
    query_
      connection
      "SELECT id, owner_id, filename, size_original, size_stored, password_hash, created_at, expires_at \
      \FROM files"
  mapM rowToStored rows

allIds :: Db -> IO (Set (OwnerId, FileId))
allIds db = withConn db $ \connection -> do
  rows <- query_ connection "SELECT owner_id, id FROM files"
  pure
    ( Set.fromList
        [ (owner, FileId t)
        | (rawOwner, t) <- rows,
          Just owner <- [ownerFromText rawOwner]
        ]
    )

deleteFileRow :: Db -> FileId -> IO Bool
deleteFileRow db fileId = withConn db $ \connection ->
  withImmediate connection $ do
    execute connection "DELETE FROM files WHERE id = ?" (Only (unFileId fileId))
    changed <- changes connection
    pure (changed > 0)

-- | Delete a file only when it belongs to @owner@.
deleteFileRowOwnedBy :: Db -> OwnerId -> FileId -> IO Bool
deleteFileRowOwnedBy db owner fileId = withConn db $ \connection ->
  withImmediate connection $ do
    execute
      connection
      "DELETE FROM files WHERE id = ? AND owner_id = ?"
      (unFileId fileId, unOwnerId owner)
    changed <- changes connection
    pure (changed > 0)

{- | Delete several rows in one immediate transaction. Returns the ids that
existed before deletion.
-}
deleteFileRows :: Db -> [(OwnerId, FileId)] -> IO [(OwnerId, FileId)]
deleteFileRows _ [] = pure []
deleteFileRows db ids = withConn db $ \connection ->
  withImmediate connection $ do
    deleted <-
      forM ids $ \(owner, fid) -> do
        execute
          connection
          "DELETE FROM files WHERE id = ? AND owner_id = ?"
          (unFileId fid, unOwnerId owner)
        changed <- changes connection
        pure (if changed > 0 then Just (owner, fid) else Nothing)
    pure (catMaybes deleted)

expiredIds :: Db -> UTCTime -> IO [(OwnerId, FileId)]
expiredIds db now = withConn db $ \connection -> do
  rows <-
    query
      connection
      "SELECT owner_id, id FROM files WHERE expires_at <= ?"
      (Only (utcToEpoch now)) ::
      IO [(Text, Text)]
  pure
    [ (owner, FileId t)
    | (rawOwner, t) <- rows,
      Just owner <- [ownerFromText rawOwner]
    ]

{- | Delete rows whose blob is missing. The predicate runs while the lock is
held, so it must only stat a file, never stream it.
-}
deleteRowsMissingBlob :: Db -> ((OwnerId, FileId) -> IO Bool) -> IO [(OwnerId, FileId)]
deleteRowsMissingBlob db blobExists = do
  files <- allFiles db
  missing <- fmap catMaybes . mapM check $ files
  if null missing
    then pure []
    else deleteFileRows db (map (\stored -> (sfOwnerId stored, sfId stored)) missing)
 where
  check :: StoredFile -> IO (Maybe StoredFile)
  check stored = do
    exists <- blobExists (sfOwnerId stored, sfId stored)
    pure (if exists then Nothing else Just stored)

-- * Token queries

insertToken :: Db -> StoredToken -> IO ()
insertToken db StoredToken{..} = withConn db $ \connection ->
  execute
    connection
    "INSERT INTO tokens (id, kind, token_hash, created_at, expires_at) \
    \VALUES (?, 'user', ?, ?, ?)"
    ( unOwnerId stId,
      stHash,
      utcToEpoch stCreatedAt,
      fmap utcToEpoch stExpiresAt
    )

lookupToken :: Db -> OwnerId -> IO (Maybe StoredToken)
lookupToken db owner = withConn db $ \connection -> do
  rows <-
    query
      connection
      "SELECT id, token_hash, created_at, expires_at \
      \FROM tokens WHERE id = ? AND kind = 'user'"
      (Only (unOwnerId owner))
  case rows of
    [] -> pure Nothing
    ((rawId, tokenHash, createdAt, expiresAt) : _) ->
      case ownerFromText rawId of
        Nothing -> throwIO (userError "corrupt token id in database")
        Just tokenId ->
          pure
            ( Just
                StoredToken
                  { stId = tokenId,
                    stHash = tokenHash,
                    stCreatedAt = epochToUtc createdAt,
                    stExpiresAt = fmap epochToUtc expiresAt
                  }
            )

listLiveUserTokens :: Db -> UTCTime -> IO [TokenInfo]
listLiveUserTokens db now = withConn db $ \connection -> do
  rows <-
    query
      connection
      "SELECT id, created_at, expires_at FROM tokens \
      \WHERE kind = 'user' AND (expires_at IS NULL OR expires_at > ?) \
      \ORDER BY created_at DESC, id ASC"
      (Only (utcToEpoch now)) ::
      IO [(Text, Int64, Maybe Int64)]
  pure
    [ TokenInfo
        { tiId = owner,
          tiCreatedAt = epochToUtc createdAt,
          tiExpiresAt = fmap epochToUtc expiresAt
        }
    | (rawId, createdAt, expiresAt) <- rows,
      Just owner <- [ownerFromText rawId]
    ]

{- | Delete a user token and all of its file rows in one transaction. Returns
the deleted file ids, or 'Nothing' when the token does not exist (or is the
admin token).
-}
deleteTokenAndFiles :: Db -> OwnerId -> IO (Maybe [FileId])
deleteTokenAndFiles db owner = withConn db $ \connection ->
  withImmediate connection $ do
    tokens <-
      query
        connection
        "SELECT id FROM tokens WHERE id = ? AND kind = 'user'"
        (Only (unOwnerId owner)) ::
        IO [Only Text]
    case tokens of
      [] -> pure Nothing
      _ -> do
        rows <-
          query
            connection
            "SELECT id FROM files WHERE owner_id = ?"
            (Only (unOwnerId owner)) ::
            IO [Only Text]
        execute connection "DELETE FROM files WHERE owner_id = ?" (Only (unOwnerId owner))
        execute
          connection
          "DELETE FROM tokens WHERE id = ? AND kind = 'user'"
          (Only (unOwnerId owner))
        pure (Just [FileId t | Only t <- rows])

expiredUserTokens :: Db -> UTCTime -> IO [OwnerId]
expiredUserTokens db now = withConn db $ \connection -> do
  rows <-
    query
      connection
      "SELECT id FROM tokens WHERE kind = 'user' AND expires_at <= ?"
      (Only (utcToEpoch now)) ::
      IO [Only Text]
  pure [owner | Only raw <- rows, Just owner <- [ownerFromText raw]]

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
rowToStored (rawId, rawOwner, filename, sizeOriginal, sizeStored, passwordHash, createdAt, expiresAt) =
  case (mkFileId rawId, ownerFromText rawOwner) of
    (Left err, _) -> throwIO (userError ("corrupt file id in database: " <> T.unpack err))
    (_, Nothing) -> throwIO (userError "corrupt owner id in database")
    (Right fileId, Just owner) ->
      pure
        StoredFile
          { sfId = fileId,
            sfOwnerId = owner,
            sfFilename = filename,
            sfSize = sizeOriginal,
            sfStoredSize = sizeStored,
            sfPasswordHash = passwordHash,
            sfCreatedAt = epochToUtc createdAt,
            sfExpiresAt = epochToUtc expiresAt
          }

ownerFromText :: Text -> Maybe OwnerId
ownerFromText raw =
  let owner = OwnerId raw
   in if isValidOwnerId owner then Just owner else Nothing

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
