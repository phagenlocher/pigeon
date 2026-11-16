-- | Filesystem blob storage, temp files, and the upload pipeline.
module Pigeon.Server.Storage (
  Storage (..),
  StorageHooks (..),
  DirSyncResult (..),
  defaultStorageHooks,
  StoreRequest (..),
  StorageError (..),
  initStorage,
  ensureOwnerDir,
  ownerDir,
  storeUpload,
  openBlob,
  blobPath,
  blobExists,
  deleteBlob,
  listBlobIds,
  listTempFiles,
  removeIfExists,
) where

import Control.Exception.Safe (
  Exception,
  IOException,
  SomeException,
  bracket,
  catch,
  fromException,
  onException,
  throwIO,
  try,
 )
import Control.Monad (unless, void, when)
import Crypto.Random (getRandomBytes)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as B8
import Data.Conduit
import Data.Conduit.Combinators (sinkHandle, sinkNull)
import Data.Conduit.Internal (zipSinks)
import Data.IORef
import Data.Int (Int64)
import Data.List (isSuffixOf)
import Data.Streaming.Zlib (ZlibException)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (addUTCTime, getCurrentTime)
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
import System.Posix.Files (
  FileStatus,
  deviceID,
  getFdStatus,
  getSymbolicLinkStatus,
  isDirectory,
  isSymbolicLink,
 )
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
  BadGzip,
  UploadTooLarge (..),
  countBytesLimited,
  parallelGzipConduit,
  ungzipConduit,
 )
import Pigeon.Types (
  FileId (..),
  OwnerId (..),
  StoredFile (..),
  generateFileId,
  isValidOwnerId,
  lowerAsciiChar,
  mkFileId,
 )

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
    -- | fsync a directory
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
  { srOwnerId :: OwnerId,
    srFilename :: Text,
    srLifetime :: Int64,
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
  deriving (Eq, Show)

{- | Allow the upload pipeline to carry a typed storage failure through
'doStore' without losing it to the generic exception classifier.
-}
instance Exception StorageError

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
        adminFd <- ensurePrivateSubdirectory filesFd filesDir "admin"
        closeFd adminFd
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

-- | Directory holding all blobs owned by one owner.
ownerDir :: Storage -> OwnerId -> FilePath
ownerDir storage owner = stFilesDir storage </> T.unpack (unOwnerId owner)

{- | Create or validate an owner directory with mode @0700@. The owner id is
validated before it is used as a path component, and the directory is opened
with @O_NOFOLLOW@ through the trusted @files/@ descriptor.
-}
ensureOwnerDir :: Storage -> OwnerId -> IO ()
ensureOwnerDir storage owner = do
  unless (isValidOwnerId owner) $
    throwIO (StorageIo "invalid owner id")
  bracket openFilesDir closeFd $ \filesFd ->
    bracket
      (ensurePrivateSubdirectory filesFd (stFilesDir storage) (T.unpack (unOwnerId owner)))
      closeFd
      (const (pure ()))
 where
  openFilesDir :: IO Fd
  openFilesDir =
    openFd
      (stFilesDir storage)
      ReadOnly
      defaultFileFlags{directory = True, nofollow = True}

blobPath :: Storage -> OwnerId -> FileId -> FilePath
blobPath storage owner fileId =
  ownerDir storage owner </> T.unpack (unFileId fileId) <> ".gz"

tempPath :: Storage -> FileId -> ByteString -> FilePath
tempPath storage fileId suffix =
  stTmpDir storage
    </> T.unpack (unFileId fileId)
      <> "."
      <> B8.unpack suffix
      <> ".part"

blobExists :: Storage -> OwnerId -> FileId -> IO Bool
blobExists storage owner fileId = doesFileExist (blobPath storage owner fileId)

deleteBlob :: Storage -> OwnerId -> FileId -> IO ()
deleteBlob storage owner fileId =
  removeIfExists (blobPath storage owner fileId)

removeIfExists :: FilePath -> IO ()
removeIfExists path = removeFile path `catch` \(_ :: IOException) -> pure ()

-- * Upload

storeUpload :: Storage -> Db -> StoreRequest -> IO (Either StorageError StoredFile)
storeUpload storage db request = do
  result <- try (doStore storage db request) :: IO (Either SomeException StoredFile)
  pure $ case result of
    Right stored -> Right stored
    Left err -> Left (classify err)

classify :: SomeException -> StorageError
classify err
  | Just (storageError :: StorageError) <- fromException err = storageError
  | Just (_ :: UploadTooLarge) <- fromException err = StorageTooLarge
  | Just (_ :: BadGzip) <- fromException err = StorageBadGzip
  | Just (_ :: ZlibException) <- fromException err = StorageBadGzip
  | Just (_ :: IOException) <- fromException err = StorageIo "filesystem error"
  | Just (_ :: SQLError) <- fromException err = StorageIo "database error"
  | otherwise = StorageIo "unexpected storage failure"

{- | Write, validate, sync, and rename one upload before its metadata row is
committed.

The ordering is deliberate: a temp-file fsync failure aborts before the rename
(STORE-065), and after the rename only a recognised unsupported platform may
continue past the directory sync.
-}
doStore :: Storage -> Db -> StoreRequest -> IO StoredFile
doStore storage db StoreRequest{..} = do
  fileId <- pickFreshId db
  suffix <- randomSuffix
  let temp = tempPath storage fileId suffix
      final = blobPath storage srOwnerId fileId
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

      ensureOwnerDir storage srOwnerId
      renameFile temp final

      ownerOutcome <- shSyncDir hooks (ownerDir storage srOwnerId)
      when (ownerOutcome == DirSyncUnsupported) $ warnUnsupportedDirSync storage
      filesOutcome <- shSyncDir hooks (stFilesDir storage)
      when (filesOutcome == DirSyncUnsupported) $ warnUnsupportedDirSync storage

      finishedAt <- getCurrentTime
      let expiresAt = addUTCTime (fromIntegral srLifetime) finishedAt
          stored :: StoredFile
          stored =
            StoredFile
              { sfId = fileId,
                sfOwnerId = srOwnerId,
                sfFilename = srFilename,
                sfSize = sizeOriginal,
                sfStoredSize = sizeStored,
                sfPasswordHash = srPasswordHash,
                sfCreatedAt = finishedAt,
                sfExpiresAt = expiresAt
              }

      insertFile db stored
      pure stored
    )
    `onException` removeIfExists temp
    `onException` removeOrphanBlob storage srOwnerId fileId
    `catch` \(err :: IOException) -> do
      logUploadIoFailure storage fileId err
      throwIO err
 where
  contentEncoding :: Maybe ByteString
  contentEncoding = fmap (B8.map lowerAsciiChar) srContentEncoding

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
removeOrphanBlob :: Storage -> OwnerId -> FileId -> IO ()
removeOrphanBlob storage owner fileId =
  ignoreHookErrors
    (shRemoveBlob (stHooks storage) (blobPath storage owner fileId) `catch` handleFailure)
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
        .| parallelGzipConduit
        .| sinkHandle handle

{- | Write a gzip upload as received while validating the stream and counting
the decompressed size in the same pass (STORE-062).

Each received chunk is written to the temp file and fed to the inflater before
the next chunk is read, so the stored bytes stay exactly as received, memory
stays constant, and a corrupt stream is rejected as soon as it is detected
rather than after the whole body has been written. The body must be exactly
one complete gzip member: a member that never reaches its trailer and any
bytes after it are rejected instead of being stored.
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
  go 0 = throwIO StorageIdCollision
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
      | isUnsupportedDirSyncException err -> pure DirSyncUnsupported
      | otherwise -> throwIO err
    Right () -> either throwIO (const (pure DirSyncSucceeded)) closeResult

{- | Only errors that explicitly mean "this filesystem does not support
directory fsync" may take the warn-and-continue path (STORE-067).
'IOErrorType' comes from @GHC.IO.Exception@ because its constructors are
exported only from that internal module.
-}
isUnsupportedDirSyncException :: IOException -> Bool
isUnsupportedDirSyncException err =
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
openBlob :: Storage -> OwnerId -> FileId -> IO Handle
openBlob storage owner fileId = do
  unless (isValidOwnerId owner) $
    throwIO (userError "invalid owner id")
  fd <-
    openFd
      (blobPath storage owner fileId)
      ReadOnly
      defaultFileFlags{nofollow = True}
  handle <- fdToHandle fd
  hSetBinaryMode handle True
  pure handle

-- * Cleanup helpers

{- | List every stored blob as an @(owner, file id)@ pair. Only real owner
directories are inspected; symlinks and unknown entries are ignored so orphan
cleanup never follows a path outside @files/@.
-}
listBlobIds :: Storage -> IO [(OwnerId, FileId)]
listBlobIds storage = do
  names <- listDirectory (stFilesDir storage)
  fmap concat . mapM listOwnerDir $ names
 where
  listOwnerDir :: FilePath -> IO [(OwnerId, FileId)]
  listOwnerDir name
    | T.length rawName /= 16 && rawName /= "admin" = pure []
    | otherwise = do
        let path = stFilesDir storage </> name
        status <- getSymbolicLinkStatus path
        if not (isDirectory status) || isSymlink status
          then pure []
          else do
            entries <- listDirectory path
            pure
              [ (owner, fileId)
              | entry <- entries,
                ".gz" `isSuffixOf` entry,
                Just owner <- [mkOwnerId rawName],
                Right fileId <- [mkFileId (T.pack (take (length entry - 3) entry))]
              ]
   where
    rawName :: Text
    rawName = T.pack name

  isSymlink :: FileStatus -> Bool
  isSymlink = isSymbolicLink

  mkOwnerId :: Text -> Maybe OwnerId
  mkOwnerId raw =
    let owner = OwnerId raw
     in if isValidOwnerId owner then Just owner else Nothing

listTempFiles :: Storage -> IO [FilePath]
listTempFiles storage = do
  names <- listDirectory (stTmpDir storage)
  pure [stTmpDir storage </> name | name <- names, takeExtension name == ".part"]
