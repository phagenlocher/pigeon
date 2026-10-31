-- | Filesystem blob storage, temp files, and the upload pipeline.
module Pigeon.Server.Storage (
  Storage (..),
  StorageHooks (..),
  DirSyncResult (..),
  defaultStorageHooks,
  StoreRequest (..),
  StorageError (..),
  initStorage,
  storeUpload,
  openBlob,
  blobPath,
  blobExists,
  deleteBlob,
  listBlobIds,
  listTempFiles,
  removeIfExists,
  renderStorageError,
) where

import Control.Exception.Safe (
  IOException,
  SomeException,
  bracket,
  catch,
  fromException,
  onException,
  throwIO,
  try,
 )
import Control.Monad (void, when)
import Crypto.Random (getRandomBytes)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as B8
import Data.Char (isAsciiUpper)
import Data.Conduit
import Data.Conduit.Combinators (sinkHandle, sinkNull)
import Data.Conduit.Internal (zipSinks)
import Data.IORef
import Data.Int (Int64)
import Data.List (isSuffixOf)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, addUTCTime, getCurrentTime)
import Database.SQLite.Simple (SQLError)
import GHC.IO.Exception (IOErrorType (..))
import System.Directory (
  doesFileExist,
  getFileSize,
  listDirectory,
  makeAbsolute,
  removeFile,
  renameFile,
 )
import System.FilePath (normalise, takeExtension, (</>))
import System.IO (Handle, hClose, hSetBinaryMode)
import System.IO.Error (
  ioeGetErrorString,
  ioeGetErrorType,
  isDoesNotExistError,
 )
import System.Posix.Files (deviceID, getFdStatus)
import System.Posix.IO (
  OpenFileFlags (..),
  OpenMode (ReadOnly, WriteOnly),
  closeFd,
  defaultFileFlags,
  fdToHandle,
  openFd,
 )
import System.Posix.Types (Fd)
import System.Posix.Unistd (fileSynchronise)
import Text.Printf (printf)

import Pigeon.API (UploadBody)
import Pigeon.Server.Db
import Pigeon.Server.PathSafety (
  ensurePrivateDirectoryTree,
  ensurePrivateSubdirectory,
 )
import Pigeon.Streaming (
  UploadTooLarge (..),
  countBytesLimited,
  gzipConduit,
  ungzipConduit,
 )
import Pigeon.Types (FileId (..), StoredFile (..), generateFileId, mkFileId)

{- | Outcome of synchronising a directory. Only a filesystem that explicitly
reports that directory fsync is unsupported yields 'DirSyncUnsupported'
(STORE-067); every other failure is thrown.
-}
data DirSyncResult = DirSyncSucceeded | DirSyncUnsupported
  deriving (Eq, Show)

{- | Filesystem and logging primitives used by the upload pipeline. They are a
record so tests can inject synchronization failures deterministically instead
of depending on a particular filesystem (TEST-154, TEST-155, TEST-156).
-}
data StorageHooks = StorageHooks
  { -- | fsync a file and close it; failures propagate (STORE-065).
    shSyncFile :: FilePath -> IO (),
    -- | fsync a directory; only unsupported platforms return a value.
    shSyncDir :: FilePath -> IO DirSyncResult,
    -- | remove a blob during post-rename cleanup.
    shRemoveBlob :: FilePath -> IO (),
    -- | warning sink, for example a recognised unsupported directory fsync.
    shWarn :: Text -> IO (),
    -- | error sink for the detailed server-side cause.
    shError :: Text -> IO ()
  }

-- | Production hooks: real syscalls and silent log sinks.
defaultStorageHooks :: StorageHooks
defaultStorageHooks =
  StorageHooks
    { shSyncFile = synchroniseFile,
      shSyncDir = synchroniseDirectoryOutcome,
      shRemoveBlob = removeFile,
      shWarn = const (pure ()),
      shError = const (pure ())
    }

-- | Resolved storage locations. All paths are absolute.
data Storage = Storage
  { stRoot :: FilePath,
    stFilesDir :: FilePath,
    stTmpDir :: FilePath,
    stHooks :: StorageHooks,
    -- | whether the unsupported-directory-fsync warning was already emitted.
    stDirSyncWarned :: IORef Bool
  }

-- | Everything needed to store one upload.
data StoreRequest = StoreRequest
  { srFilename :: Text,
    srContentType :: Text,
    srExpiresAt :: UTCTime,
    srPasswordHash :: Maybe Text,
    srContentEncoding :: Maybe ByteString,
    srMaxUploadSize :: Int64,
    srBody :: UploadBody
  }

-- | Failures mapped to HTTP responses by the handler layer.
data StorageError
  = StorageTooLarge
  | StorageBadGzip
  | StorageIdCollision
  | StorageIo Text
  | StorageCorrupt Text
  deriving (Eq, Show)

renderStorageError :: StorageError -> Text
renderStorageError = \case
  StorageTooLarge -> "upload is too large"
  StorageBadGzip -> "request body is not valid gzip"
  StorageIdCollision -> "could not allocate a unique file id"
  StorageIo _ -> "storage failure"
  StorageCorrupt _ -> "storage corruption"

{- | Create the data directory and its subdirectories, and verify that
@files/@ and @tmp/@ live on the same filesystem. Symlink components are
rejected before any permission change is made.
-}
initStorage :: StorageHooks -> FilePath -> IO Storage
initStorage hooks root = do
  absoluteRoot <- normalise <$> makeAbsolute root
  let filesDir = absoluteRoot </> "files"
      tmpDir = absoluteRoot </> "tmp"
  bracket (ensurePrivateDirectoryTree absoluteRoot) closeFd $ \rootFd ->
    bracket (ensurePrivateSubdirectory rootFd absoluteRoot "files") closeFd $ \filesFd ->
      bracket (ensurePrivateSubdirectory rootFd absoluteRoot "tmp") closeFd $ \tmpFd -> do
        filesStatus <- getFdStatus filesFd
        tmpStatus <- getFdStatus tmpFd
        when (deviceID filesStatus /= deviceID tmpStatus) $
          throwIO (userError "files/ and tmp/ must be on the same filesystem")
        warned <- newIORef False
        pure
          Storage
            { stRoot = absoluteRoot,
              stFilesDir = filesDir,
              stTmpDir = tmpDir,
              stHooks = hooks,
              stDirSyncWarned = warned
            }

-- * Paths

blobPath :: Storage -> FileId -> FilePath
blobPath storage fileId = stFilesDir storage </> T.unpack (unFileId fileId) <> ".gz"

tempPath :: Storage -> FileId -> ByteString -> FilePath
tempPath storage fileId suffix =
  stTmpDir storage
    </> T.unpack (unFileId fileId)
      <> "."
      <> B8.unpack suffix
      <> ".part"

blobExists :: Storage -> FileId -> IO Bool
blobExists storage fileId = doesFileExist (blobPath storage fileId)

deleteBlob :: Storage -> FileId -> IO ()
deleteBlob storage fileId =
  removeIfExists (blobPath storage fileId)

removeIfExists :: FilePath -> IO ()
removeIfExists path = removeFile path `catch` \(_ :: IOException) -> pure ()

-- * Upload

storeUpload :: Storage -> Db -> StoreRequest -> IO (Either StorageError StoredFile)
storeUpload storage db request = do
  now <- getCurrentTime
  let createdAt = clampCreatedAt now (srExpiresAt request)
  result <- try (doStore storage db request createdAt) :: IO (Either SomeException StoredFile)
  pure $ case result of
    Right stored -> Right stored
    Left err -> Left (classify err)

clampCreatedAt :: UTCTime -> UTCTime -> UTCTime
clampCreatedAt now expiresAt =
  let latest = addUTCTime (-1) expiresAt
   in if now >= expiresAt then latest else now

classify :: SomeException -> StorageError
classify err
  | isJust (fromException err :: Maybe UploadTooLarge) = StorageTooLarge
  | isJust (fromException err :: Maybe IOException) = StorageIo "filesystem error"
  | isJust (fromException err :: Maybe SQLError) = StorageIo "database error"
  | otherwise = StorageBadGzip

{- | Write, validate, sync, and rename one upload before its metadata row is
committed.

The ordering is deliberate: a temp-file fsync failure aborts before the rename
(STORE-065), and after the rename only a recognised unsupported platform may
continue past the directory sync.
-}
doStore :: Storage -> Db -> StoreRequest -> UTCTime -> IO StoredFile
doStore storage db StoreRequest{..} createdAt = do
  fileId <- pickFreshId db
  suffix <- randomSuffix
  let temp = tempPath storage fileId suffix
      final = blobPath storage fileId
      hooks = stHooks storage

  ( do
      originalRef <- newIORef 0
      storedRef <- newIORef 0

      case contentEncoding of
        Just "gzip" ->
          writeGzipBody srBody temp srMaxUploadSize storedRef originalRef
        _ -> do
          writeIdentityBody srBody temp srMaxUploadSize originalRef
          storedBytes <- getFileSize temp
          writeIORef storedRef (fromIntegral storedBytes)

      shSyncFile hooks temp
      sizeStored <- fromIntegral <$> getFileSize temp
      sizeOriginal <- readIORef originalRef

      renameFile temp final

      dirOutcome <- shSyncDir hooks (stFilesDir storage)
      case dirOutcome of
        DirSyncSucceeded -> pure ()
        DirSyncUnsupported -> warnUnsupportedDirSync storage

      let stored :: StoredFile
          stored =
            StoredFile
              { sfId = fileId,
                sfFilename = srFilename,
                sfContentType = srContentType,
                sfSize = sizeOriginal,
                sfStoredSize = sizeStored,
                sfPasswordHash = srPasswordHash,
                sfCreatedAt = createdAt,
                sfExpiresAt = srExpiresAt
              }

      insertFile db stored
      pure stored
    )
    `onException` removeIfExists temp
    `onException` removeOrphanBlob storage fileId
    `catch` \(err :: IOException) -> do
      logUploadIoFailure storage fileId err
      throwIO err
 where
  contentEncoding :: Maybe ByteString
  contentEncoding = fmap (B8.map lowerAscii) srContentEncoding

  lowerAscii :: Char -> Char
  lowerAscii c
    | isAsciiUpper c = toEnum (fromEnum c + 32)
    | otherwise = c

-- | Emit the unsupported-directory-fsync warning at most once per process.
warnUnsupportedDirSync :: Storage -> IO ()
warnUnsupportedDirSync storage = do
  firstTime <- atomicModifyIORef' (stDirSyncWarned storage) (\warned -> (True, not warned))
  when firstTime
    $ ignoreHookErrors
    $ shWarn
      (stHooks storage)
      ( "filesystem does not support directory fsync;"
          <> " crash durability for new blobs is reduced"
      )

-- | Log the detailed cause of an upload I/O failure without exposing it to clients.
logUploadIoFailure :: Storage -> FileId -> IOException -> IO ()
logUploadIoFailure storage fileId err =
  ignoreHookErrors $
    shError
      (stHooks storage)
      ( "upload i/o failure id="
          <> unFileId fileId
          <> " cause="
          <> T.pack (show (ioeGetErrorType err))
          <> " "
          <> T.pack (ioeGetErrorString err)
      )

{- | Remove the blob of a failed upload. A missing blob is not an error; any
other removal failure is logged so the orphan sweeper can retry it later. This
never throws, so it cannot mask the original upload failure (STORE-126).
-}
removeOrphanBlob :: Storage -> FileId -> IO ()
removeOrphanBlob storage fileId =
  ignoreHookErrors
    (shRemoveBlob (stHooks storage) (blobPath storage fileId) `catch` handleFailure)
 where
  handleFailure :: IOException -> IO ()
  handleFailure err
    | isDoesNotExistError err = pure ()
    | otherwise =
        shWarn
          (stHooks storage)
          ( "failed to remove orphan blob id="
              <> unFileId fileId
              <> "; the sweeper will retry"
          )

-- | Run a logging hook without letting a logger failure mask a real error.
ignoreHookErrors :: IO () -> IO ()
ignoreHookErrors action =
  action `catch` \(_ :: SomeException) -> pure ()

-- | For identity uploads, count original bytes, compress, and write.
writeIdentityBody :: UploadBody -> FilePath -> Int64 -> IORef Int64 -> IO ()
writeIdentityBody body temp limit originalRef =
  bracket (openTemp temp) safeClose $ \handle ->
    runConduitRes $
      body
        .| countBytesLimited limit originalRef
        .| gzipConduit
        .| sinkHandle handle

{- | Write a gzip upload as received while validating the stream and counting
the decompressed size in the same pass (STORE-062).

Each received chunk is written to the temp file and fed to the inflater before
the next chunk is read, so the stored bytes stay exactly as received, memory
stays constant, and a corrupt stream is rejected as soon as it is detected
rather than after the whole body has been written.
-}
writeGzipBody :: UploadBody -> FilePath -> Int64 -> IORef Int64 -> IORef Int64 -> IO ()
writeGzipBody body temp limit storedRef originalRef =
  bracket (openTemp temp) safeClose $ \handle ->
    void
      $ runConduitRes
      $ body
        .| zipSinks
          (countBytesLimited limit storedRef .| sinkHandle handle)
          (ungzipConduit .| countBytesLimited limit originalRef .| sinkNull)

-- * Helpers

pickFreshId :: Db -> IO FileId
pickFreshId db = go (5 :: Int)
 where
  go :: Int -> IO FileId
  go 0 = throwIO (userError "could not allocate a unique file id")
  go attempts = do
    candidate <- generateFileId
    existing <- lookupFile db candidate
    case existing of
      Nothing -> pure candidate
      Just _ -> go (attempts - 1)

randomSuffix :: IO ByteString
randomSuffix = do
  bytes <- getRandomBytes 8
  pure (B8.pack (concatMap (printf "%02x") (BS.unpack bytes)))

openTemp :: FilePath -> IO Handle
openTemp path = do
  fd <-
    openFd
      path
      WriteOnly
      defaultFileFlags
        { exclusive = True,
          trunc = True,
          nofollow = True,
          creat = Just 0o600
        }
  handle <- fdToHandle fd
  hSetBinaryMode handle True
  pure handle

safeClose :: Handle -> IO ()
safeClose handle = hClose handle `catch` \(_ :: IOException) -> pure ()

synchroniseFile :: FilePath -> IO ()
synchroniseFile path = do
  fd <- openFd path ReadOnly defaultFileFlags{nofollow = True}
  syncAndClose fd

{- | fsync a directory and report whether the platform supports it. A failure
to open the directory is never treated as unsupported; it propagates.
-}
synchroniseDirectoryOutcome :: FilePath -> IO DirSyncResult
synchroniseDirectoryOutcome path = do
  fd <- openFd path ReadOnly defaultFileFlags{directory = True}
  syncResult <- try (fileSynchronise fd) :: IO (Either IOException ())
  closeResult <- try (closeFd fd) :: IO (Either IOException ())
  case syncResult of
    Left err
      | isUnsupportedDirSync err -> pure DirSyncUnsupported
      | otherwise -> throwIO err
    Right () -> either throwIO (const (pure DirSyncSucceeded)) closeResult

{- | Only errors that explicitly mean "this filesystem does not support
directory fsync" may take the warn-and-continue path (STORE-067).
'IOErrorType' comes from @GHC.IO.Exception@ because its constructors are
exported only from that internal module.
-}
isUnsupportedDirSync :: IOException -> Bool
isUnsupportedDirSync err =
  ioeGetErrorType err `elem` [InvalidArgument, UnsupportedOperation]

{- | Synchronise and close a descriptor. A close error is reported only when
the synchronisation succeeded, so it can never mask the sync failure.
-}
syncAndClose :: Fd -> IO ()
syncAndClose fd = do
  syncResult <- try (fileSynchronise fd) :: IO (Either IOException ())
  closeResult <- try (closeFd fd) :: IO (Either IOException ())
  case syncResult of
    Left err -> throwIO err
    Right () -> either throwIO pure closeResult

-- * Download

-- | Open a blob read-only with @O_NOFOLLOW@. The caller owns the handle.
openBlob :: Storage -> FileId -> IO Handle
openBlob storage fileId = do
  fd <-
    openFd
      (blobPath storage fileId)
      ReadOnly
      defaultFileFlags{nofollow = True}
  handle <- fdToHandle fd
  hSetBinaryMode handle True
  pure handle

-- * Cleanup helpers

listBlobIds :: Storage -> IO [FileId]
listBlobIds storage = do
  names <- listDirectory (stFilesDir storage)
  pure
    [ fileId
    | name <- names,
      ".gz" `isSuffixOf` name,
      Right fileId <- [mkFileId (T.pack (take (length name - 3) name))]
    ]

listTempFiles :: Storage -> IO [FilePath]
listTempFiles storage = do
  names <- listDirectory (stTmpDir storage)
  pure [stTmpDir storage </> name | name <- names, takeExtension name == ".part"]
