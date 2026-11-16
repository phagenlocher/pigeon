-- | Authenticated metadata API handlers.
module Pigeon.Server.Handlers (
  uploadHandler,
  listHandler,
  deleteHandler,
  createTokenHandler,
  listTokensHandler,
  deleteTokenHandler,
  healthHandler,
  apiError,
  invalidRequest,
  notFound,
  unauthorized,
  forbidden,
) where

import Control.Exception.Safe (SomeException, catch, try)
import Control.Monad (unless, when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ask, asks)
import Data.Aeson (encode)
import Data.ByteString.Base64.URL qualified as B64URL
import Data.Int (Int64)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8', encodeUtf8)
import Data.Time (addUTCTime, getCurrentTime)
import Servant
import System.Directory (removeDirectory)

import Pigeon.API (UploadBody)
import Pigeon.Password (
  StoredPasswordHash (..),
  hashPassword,
  validatePassword,
 )
import Pigeon.Server.App (App)
import Pigeon.Server.Auth (PigeonUser (..), authenticate)
import Pigeon.Server.Config (ServerConfig (..))
import Pigeon.Server.Db
import Pigeon.Server.Env (AppEnv (..))
import Pigeon.Server.Log (logError, logInfo)
import Pigeon.Server.Storage (
  Storage,
  StorageError (..),
  StoreRequest (..),
  deleteBlob,
  ensureOwnerDir,
  ownerDir,
  storeUpload,
 )
import Pigeon.Token (generateUserToken)
import Pigeon.Types (
  ApiError (..),
  ApiErrorEnvelope (..),
  CreatedToken (..),
  FileId (..),
  FileInfo (..),
  Health (..),
  OwnerId (..),
  StoredFile (..),
  StoredToken (..),
  TokenInfo,
  adminOwnerId,
  generateOwnerId,
  isAdminOwner,
  isValidFileId,
  isValidOwnerId,
  mkSecret,
  pigeonVersion,
  sanitizeFilename,
 )

-- * Upload

uploadHandler ::
  -- | @Authorization: Bearer@ header carrying an admin or user token.
  Maybe Text ->
  -- | @filename@ query parameter; defaults to a generated name.
  Maybe Text ->
  -- | @expires_in@ query parameter in seconds; defaults to the server lifetime.
  Maybe Int64 ->
  -- | @Content-Encoding@ header; @identity@ or @gzip@.
  Maybe Text ->
  -- | @X-Pigeon-Password@ header; protects the download.
  Maybe Text ->
  UploadBody ->
  App FileInfo
uploadHandler auth rawFilename rawExpires rawEncoding rawPassword body = do
  user <- authenticateRequest auth
  cfg <- asks aeConfig

  lifetime <- case rawExpires of
    Nothing -> pure (scDefaultExpiry cfg)
    Just seconds
      | seconds >= 1 && seconds <= scMaxExpiry cfg -> pure seconds
      | otherwise ->
          throwError
            ( invalidRequest
                ("expires_in must be an integer between 1 and " <> T.pack (show (scMaxExpiry cfg)) <> " seconds")
            )

  let filename = maybe "file" sanitizeFilename rawFilename

  passwordHash <- case rawPassword of
    Nothing -> pure Nothing
    Just header -> Just . unStoredPasswordHash <$> decodeAndHashPassword header

  encoding <- case fmap (T.toLower . T.strip) rawEncoding of
    Nothing -> pure Nothing
    Just "identity" -> pure Nothing
    Just "gzip" -> pure (Just "gzip")
    Just _ -> throwError (apiError err415 "unsupported_media_type" "unsupported Content-Encoding")

  let request =
        StoreRequest
          { srOwnerId = ownerOf user,
            srFilename = filename,
            srLifetime = lifetime,
            srPasswordHash = passwordHash,
            srContentEncoding = fmap encodeUtf8 encoding,
            srMaxUploadSize = scMaxUploadSize cfg,
            srBody = body
          }

  env <- ask
  result <- liftIO (storeUpload (aeStorage env) (aeDb env) request)
  stored <- case result of
    Left err -> throwError (storageError err)
    Right value -> pure value

  logInfo $
    "upload id="
      <> unFileId (sfId stored)
      <> " owner="
      <> unOwnerId (sfOwnerId stored)
      <> " size_original="
      <> T.pack (show (sfSize stored))
      <> " size_stored="
      <> T.pack (show (sfStoredSize stored))
      <> " expires_at="
      <> T.pack (show (sfExpiresAt stored))
      <> " password="
      <> (if isJust (sfPasswordHash stored) then "yes" else "no")

  pure (storedToFileInfo cfg stored)

decodeAndHashPassword :: Text -> App StoredPasswordHash
decodeAndHashPassword header =
  case B64URL.decodeBase64UnpaddedUntyped (encodeUtf8 header) of
    Left _ -> throwError (invalidRequest "X-Pigeon-Password is not valid unpadded base64url")
    Right bytes -> case decodeUtf8' bytes of
      Left _ -> throwError (invalidRequest "password is not valid UTF-8")
      Right password -> case validatePassword password of
        Left message -> throwError (invalidRequest message)
        Right () -> do
          iterations <- asks (scPasswordHashIterations . aeConfig)
          liftIO (hashPassword iterations password)

-- * List, delete, health

listHandler :: Maybe Text -> App [FileInfo]
listHandler auth = do
  user <- authenticateRequest auth
  env <- ask
  now <- liftIO getCurrentTime
  files <- liftIO $ case user of
    PigeonAdmin -> listLiveFiles (aeDb env) now
    PigeonTokenUser owner -> listLiveFilesForOwner (aeDb env) owner now
  cfg <- asks aeConfig
  pure (map (storedToFileInfo cfg) files)

deleteHandler :: FileId -> Maybe Text -> App NoContent
deleteHandler fileId auth = do
  user <- authenticateRequest auth
  unless (isValidFileId fileId) $
    throwError (invalidRequest "malformed file id")
  env <- ask
  row <- liftIO (lookupFile (aeDb env) fileId)
  case row of
    Nothing -> throwError notFound
    Just stored -> do
      let owner = sfOwnerId stored
      case user of
        PigeonTokenUser tokenOwner
          | tokenOwner /= owner -> throwError notFound
        _ -> pure ()
      deleted <- liftIO $ case user of
        PigeonAdmin -> deleteFileRow (aeDb env) fileId
        PigeonTokenUser tokenOwner -> deleteFileRowOwnedBy (aeDb env) tokenOwner fileId
      if not deleted
        then throwError notFound
        else do
          liftIO (deleteBlob (aeStorage env) owner fileId)
          liftIO (removeOwnerDirIfEmpty (aeStorage env) owner)
          logInfo ("delete id=" <> unFileId fileId)
          pure NoContent

-- * Token management (admin only)

createTokenHandler :: Maybe Text -> Maybe Int64 -> App CreatedToken
createTokenHandler auth rawExpires = do
  _ <- requireAdmin auth
  cfg <- asks aeConfig
  lifetime <- case rawExpires of
    Nothing -> pure Nothing
    Just seconds
      | seconds >= 1 && seconds <= scMaxExpiry cfg -> pure (Just seconds)
      | otherwise ->
          throwError
            ( invalidRequest
                ("expires_in must be an integer between 1 and " <> T.pack (show (scMaxExpiry cfg)) <> " seconds")
            )
  env <- ask
  now <- liftIO getCurrentTime
  maybeOwner <- liftIO (pickFreshOwnerId (aeDb env))
  owner <- case maybeOwner of
    Nothing -> throwError (apiError err503 "unavailable" "could not allocate a token id")
    Just value -> pure value
  (rawToken, digest) <- liftIO (generateUserToken owner)
  let expiresAt = fmap (\seconds -> addUTCTime (fromIntegral seconds) now) lifetime
      stored =
        StoredToken
          { stId = owner,
            stHash = digest,
            stCreatedAt = now,
            stExpiresAt = expiresAt
          }
  liftIO (insertToken (aeDb env) stored)
  created <- liftIO (try (ensureOwnerDir (aeStorage env) owner) :: IO (Either SomeException ()))
  case created of
    Left err -> do
      logError
        ("token directory creation failed owner=" <> unOwnerId owner <> " cause=" <> T.pack (show err))
      _ <- liftIO (deleteTokenAndFiles (aeDb env) owner)
      throwError (apiError err500 "internal_error" "internal storage failure")
    Right () -> do
      logInfo $
        "token create id="
          <> unOwnerId owner
          <> " expires_at="
          <> maybe "never" (T.pack . show) expiresAt
      pure
        CreatedToken
          { ctId = owner,
            ctToken = mkSecret rawToken,
            ctCreatedAt = now,
            ctExpiresAt = expiresAt
          }

listTokensHandler :: Maybe Text -> App [TokenInfo]
listTokensHandler auth = do
  _ <- requireAdmin auth
  env <- ask
  now <- liftIO getCurrentTime
  liftIO (listLiveUserTokens (aeDb env) now)

deleteTokenHandler :: OwnerId -> Maybe Text -> App NoContent
deleteTokenHandler owner auth = do
  _ <- requireAdmin auth
  unless (isValidOwnerId owner) $
    throwError (invalidRequest "malformed token id")
  when (isAdminOwner owner) $
    throwError (invalidRequest "the admin token cannot be deleted")
  env <- ask
  deleted <- liftIO (deleteTokenAndFiles (aeDb env) owner)
  case deleted of
    Nothing -> throwError (apiError err404 "not_found" "Token not found")
    Just fileIds -> do
      liftIO $ mapM_ (deleteBlob (aeStorage env) owner) fileIds
      liftIO (removeOwnerDirIfEmpty (aeStorage env) owner)
      logInfo ("token delete id=" <> unOwnerId owner <> " files=" <> T.pack (show (length fileIds)))
      pure NoContent

-- * Health

healthHandler :: App Health
healthHandler = do
  env <- ask
  healthy <- liftIO (pingDb (aeDb env))
  if healthy
    then pure (Health "ok" pigeonVersion)
    else
      throwError
        ( (apiError err503 "unavailable" "database is unavailable")
            { errBody = encode (Health "unavailable" pigeonVersion)
            }
        )

-- * Helpers

storedToFileInfo :: ServerConfig -> StoredFile -> FileInfo
storedToFileInfo cfg StoredFile{..} =
  FileInfo
    { fiId = sfId,
      fiOwner = sfOwnerId,
      fiFilename = sfFilename,
      fiSize = sfSize,
      fiCreatedAt = sfCreatedAt,
      fiExpiresAt = sfExpiresAt,
      fiHasPassword = isJust sfPasswordHash,
      fiUrl = scPublicUrl cfg <> "/f/" <> unFileId sfId
    }

-- | Authenticate a request, returning the resolved user.
authenticateRequest :: Maybe Text -> App PigeonUser
authenticateRequest auth = do
  env <- ask
  cfg <- asks aeConfig
  now <- liftIO getCurrentTime
  result <- liftIO (authenticate (scToken cfg) (aeDb env) now auth)
  case result of
    Right user -> pure user
    Left _ -> throwError unauthorized

-- | Require the configured admin token.
requireAdmin :: Maybe Text -> App PigeonUser
requireAdmin auth = do
  user <- authenticateRequest auth
  case user of
    PigeonAdmin -> pure user
    PigeonTokenUser _ -> throwError forbidden

-- | The owner that receives files uploaded by a user.
ownerOf :: PigeonUser -> OwnerId
ownerOf PigeonAdmin = adminOwnerId
ownerOf (PigeonTokenUser owner) = owner

-- | Generate an owner id that is not already used by a user token.
pickFreshOwnerId :: Db -> IO (Maybe OwnerId)
pickFreshOwnerId db = go (5 :: Int)
 where
  go :: Int -> IO (Maybe OwnerId)
  go 0 = pure Nothing
  go attempts = do
    candidate <- generateOwnerId
    existing <- lookupToken db candidate
    case existing of
      Nothing -> pure (Just candidate)
      Just _ -> go (attempts - 1)

-- | Remove an owner directory when no blobs remain. Best effort.
removeOwnerDirIfEmpty :: Storage -> OwnerId -> IO ()
removeOwnerDirIfEmpty storage owner =
  removeDirectory (ownerDir storage owner)
    `catch` \(_ :: SomeException) -> pure ()

-- | Build a JSON error response.
apiError :: ServerError -> Text -> Text -> ServerError
apiError base code message =
  base
    { errBody = encode (ApiErrorEnvelope (ApiError code message)),
      errHeaders =
        ("Content-Type", "application/json; charset=utf-8")
          : ("Cache-Control", "no-store")
          : errHeaders base
    }

invalidRequest :: Text -> ServerError
invalidRequest = apiError err400 "invalid_request"

notFound :: ServerError
notFound = apiError err404 "not_found" "File not found"

unauthorized :: ServerError
unauthorized =
  (apiError err401 "unauthorized" "Missing or invalid bearer token")
    { errHeaders = ("WWW-Authenticate", "Bearer realm=\"pigeon\"") : errHeaders base
    }
 where
  base :: ServerError
  base = apiError err401 "unauthorized" "Missing or invalid bearer token"

forbidden :: ServerError
forbidden = apiError err403 "forbidden" "Admin token required"

storageError :: StorageError -> ServerError
storageError = \case
  StorageTooLarge -> apiError err413 "payload_too_large" "upload is too large"
  StorageBadGzip -> invalidRequest "request body is not valid gzip"
  StorageIdCollision -> apiError err503 "unavailable" "could not allocate a file id"
  StorageIo _ -> apiError err500 "internal_error" "internal storage failure"
