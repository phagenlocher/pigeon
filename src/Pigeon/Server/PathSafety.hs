{-# LANGUAGE OverloadedStrings #-}

{- | POSIX path checks used before Pigeon opens its database or storage
directories.

The server must never follow a symlink while opening the database, a blob, or
a storage directory. These helpers reject symlink components, create missing
directories with restrictive permissions, and apply permissions through open
file descriptors rather than through path-based chmod calls.
-}
module Pigeon.Server.PathSafety (
  UnsafePath (..),
  FileIdentity (..),
  ensurePrivateDirectoryTree,
  ensureSafeParentDirectory,
  ensurePrivateSubdirectory,
  prepareDatabaseFile,
  verifyFileIdentity,
) where

import Control.Exception.Safe (
  Exception,
  IOException,
  catch,
  onException,
  throwIO,
  try,
 )
import Control.Monad (unless, when)
import Data.Bits ((.&.))
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory (makeAbsolute)
import System.FilePath (normalise, splitDirectories, (</>))
import System.IO.Error (isAlreadyExistsError, isDoesNotExistError)
import System.Posix.Directory (createDirectory)
import System.Posix.Files (
  FileStatus,
  deviceID,
  fileID,
  fileMode,
  fileOwner,
  getFdStatus,
  getSymbolicLinkStatus,
  groupWriteMode,
  isDirectory,
  isRegularFile,
  isSymbolicLink,
  otherWriteMode,
  setFdMode,
 )
import System.Posix.IO (
  OpenFileFlags (..),
  OpenMode (ReadOnly, ReadWrite),
  closeFd,
  defaultFileFlags,
  openFd,
  openFdAt,
 )
import System.Posix.Types (DeviceID, Fd, FileID)
import System.Posix.User (getEffectiveUserID)

-- | A path that cannot be used safely for Pigeon storage.
newtype UnsafePath = UnsafePath Text
  deriving (Eq, Show)

instance Exception UnsafePath

-- | Identity of the database file checked before and after SQLite opens it.
data FileIdentity = FileIdentity
  { fiDevice :: DeviceID,
    fiFile :: FileID
  }
  deriving (Eq, Show)

directoryFlags :: OpenFileFlags
directoryFlags = defaultFileFlags{directory = True, nofollow = True}

databaseFlags :: OpenFileFlags
databaseFlags = defaultFileFlags{nofollow = True, creat = Just 0o600}

{- | Create or validate the data directory and return an open descriptor for
its final component. Existing components must be real directories; missing
components are created with mode @0700@.
-}
ensurePrivateDirectoryTree :: FilePath -> IO Fd
ensurePrivateDirectoryTree = ensureDirectoryTree True False

{- | Create or validate a parent directory for the SQLite database. Existing
parents must not be writable by group or other users, because SQLite creates
journal files beside the database by path.
-}
ensureSafeParentDirectory :: FilePath -> IO Fd
ensureSafeParentDirectory = ensureDirectoryTree False True

{- | Create or validate a direct child directory of an already-open and trusted
parent directory. The returned descriptor is opened with @O_NOFOLLOW@.
-}
ensurePrivateSubdirectory :: Fd -> FilePath -> FilePath -> IO Fd
ensurePrivateSubdirectory parentFd parentPath name = do
  let path = parentPath </> name
  ensureDirectoryEntry path name
  fd <- openChild parentFd name
  ( do
      status <- getFdStatus fd
      ensureDirectoryStatus path status
      ensureOwnedByCurrentUser path status
      setFdMode fd 0o700
      pure fd
    )
    `onException` closeFd fd

{- | Securely create or open the database file in an already-validated parent
directory. The caller must verify the returned identity after SQLite opens the
path.
-}
prepareDatabaseFile :: Fd -> FilePath -> IO FileIdentity
prepareDatabaseFile parentFd name = do
  fd <-
    openFdAt (Just parentFd) name ReadWrite databaseFlags
      `catch` \(err :: IOException) ->
        throwIO (UnsafePath (openFailure name err))
  identity <-
    ( do
        status <- getFdStatus fd
        unless (isRegularFile status) $
          throwIO (UnsafePath ("database path is not a regular file: " <> T.pack name))
        ensureOwnedByCurrentUser name status
        setFdMode fd 0o600
        secured <- getFdStatus fd
        pure
          FileIdentity
            { fiDevice = deviceID secured,
              fiFile = fileID secured
            }
    )
      `onException` closeFd fd
  closeFd fd
  pure identity

-- | Check that a path still refers to the database file we inspected.
verifyFileIdentity :: FilePath -> FileIdentity -> IO Bool
verifyFileIdentity path expected = do
  result <- try (getSymbolicLinkStatus path) :: IO (Either IOException FileStatus)
  pure $ case result of
    Left _ -> False
    Right status ->
      isRegularFile status
        && deviceID status == fiDevice expected
        && fileID status == fiFile expected

-- * Directory handling

ensureDirectoryTree :: Bool -> Bool -> FilePath -> IO Fd
ensureDirectoryTree privateFinal strictParents path = do
  absolute <- normalise <$> makeAbsolute path
  ensureComponents absolute
  fd <-
    openFd absolute ReadOnly directoryFlags
      `catch` \(err :: IOException) ->
        throwIO (UnsafePath (openFailure absolute err))
  ( do
      status <- getFdStatus fd
      ensureDirectoryStatus absolute status
      if privateFinal
        then do
          ensureOwnedByCurrentUser absolute status
          setFdMode fd 0o700
        else do
          ensureOwnedByCurrentUserOrRoot absolute status
          if strictParents
            then ensureNotWritableByOthers absolute status
            else ensureTrustedParent absolute status
      pure fd
    )
    `onException` closeFd fd
 where
  ensureComponents :: FilePath -> IO ()
  ensureComponents absolute = do
    let prefixes = scanl1 (</>) (splitDirectories absolute)
    mapM_ (ensureComponent absolute) prefixes

  ensureComponent :: FilePath -> FilePath -> IO ()
  ensureComponent absolute prefix = do
    status <- statusOrCreate prefix
    if isSymbolicLink status
      then throwIO (UnsafePath ("refusing symlink in path: " <> T.pack prefix))
      else
        unless (isDirectory status) $
          throwIO (UnsafePath ("path component is not a directory: " <> T.pack prefix))
    when (prefix /= absolute) $
      ensureTrustedParent prefix status

  statusOrCreate :: FilePath -> IO FileStatus
  statusOrCreate prefix = do
    result <- try (getSymbolicLinkStatus prefix) :: IO (Either IOException FileStatus)
    case result of
      Right status -> pure status
      Left err
        | isDoesNotExistError err -> do
            createDirectory prefix 0o700
              `catch` \(createErr :: IOException) ->
                unless (isAlreadyExistsError createErr) $
                  throwIO (UnsafePath (openFailure prefix createErr))
            getSymbolicLinkStatus prefix
        | otherwise -> throwIO (UnsafePath (openFailure prefix err))

ensureDirectoryEntry :: FilePath -> FilePath -> IO ()
ensureDirectoryEntry path name = do
  result <- try (getSymbolicLinkStatus path) :: IO (Either IOException FileStatus)
  case result of
    Right status
      | isSymbolicLink status ->
          throwIO (UnsafePath ("refusing symlink in path: " <> T.pack path))
      | not (isDirectory status) ->
          throwIO (UnsafePath ("path is not a directory: " <> T.pack path))
      | otherwise -> pure ()
    Left err
      | isDoesNotExistError err -> do
          createDirectory path 0o700
            `catch` \(createErr :: IOException) ->
              unless (isAlreadyExistsError createErr) $
                throwIO (UnsafePath (openFailure path createErr))
          status <- getSymbolicLinkStatus path
          ensureDirectoryStatus path status
      | otherwise -> throwIO (UnsafePath (T.pack ("cannot inspect " <> name <> ": " <> show err)))

openChild :: Fd -> FilePath -> IO Fd
openChild parentFd name =
  openFdAt (Just parentFd) name ReadOnly directoryFlags
    `catch` \(err :: IOException) ->
      throwIO (UnsafePath (openFailure name err))

ensureDirectoryStatus :: FilePath -> FileStatus -> IO ()
ensureDirectoryStatus path status =
  unless (isDirectory status) $
    throwIO (UnsafePath ("path is not a directory: " <> T.pack path))

-- | A directory used for storage must belong to the service account.
ensureOwnedByCurrentUser :: FilePath -> FileStatus -> IO ()
ensureOwnedByCurrentUser path status = do
  owner <- getEffectiveUserID
  unless (fileOwner status == owner) $
    throwIO (UnsafePath ("path is not owned by the service user: " <> T.pack path))

-- | Ancestors may be owned by root, as usual for system directories.
ensureOwnedByCurrentUserOrRoot :: FilePath -> FileStatus -> IO ()
ensureOwnedByCurrentUserOrRoot path status = do
  owner <- getEffectiveUserID
  unless (fileOwner status == owner || fileOwner status == 0) $
    throwIO (UnsafePath ("path has an untrusted owner: " <> T.pack path))

{- | Reject a parent that a different user could use to replace its children.
A root-owned sticky directory such as @\/tmp@ is acceptable while the service
owns the child it created.
-}
ensureTrustedParent :: FilePath -> FileStatus -> IO ()
ensureTrustedParent path status = do
  ensureOwnedByCurrentUserOrRoot path status
  when (writableByOthers status && not (stickyAndRootOwned status)) $
    throwIO (UnsafePath ("path is writable by other users: " <> T.pack path))

-- | Database parents must not allow any other user to create journal files.
ensureNotWritableByOthers :: FilePath -> FileStatus -> IO ()
ensureNotWritableByOthers path status =
  when (writableByOthers status) $
    throwIO (UnsafePath ("database directory is writable by other users: " <> T.pack path))

writableByOthers :: FileStatus -> Bool
writableByOthers status =
  let mode = fileMode status
   in mode .&. groupWriteMode /= 0 || mode .&. otherWriteMode /= 0

stickyAndRootOwned :: FileStatus -> Bool
stickyAndRootOwned status =
  fileOwner status == 0 && fileMode status .&. 0o1000 /= 0

openFailure :: FilePath -> IOException -> Text
openFailure path err =
  "cannot securely open " <> T.pack path <> ": " <> T.pack (show err)
