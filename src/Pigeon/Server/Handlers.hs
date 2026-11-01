-- | Authenticated metadata API handlers.
module Pigeon.Server.Handlers (
  uploadHandler,
  listHandler,
  deleteHandler,
  healthHandler,
  apiError,
  invalidRequest,
  notFound,
  unauthorized,
) where

import Control.Monad (unless)
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

import Pigeon.API (UploadBody)
import Pigeon.Password (
  StoredPasswordHash (..),
  hashPassword,
  validatePassword,
 )
import Pigeon.Server.App (App, MonadLogger (..))
import Pigeon.Server.Auth (checkBearer)
import Pigeon.Server.Config (ServerConfig (..))
import Pigeon.Server.Db
import Pigeon.Server.Env (AppEnv (..))
import Pigeon.Server.Log (logInfo)
import Pigeon.Server.Storage (
  StorageError (..),
  StoreRequest (..),
  deleteBlob,
  storeUpload,
 )
import Pigeon.Types (
  ApiError (..),
  ApiErrorEnvelope (..),
  FileId (..),
  FileInfo (..),
  Health (..),
  StoredFile (..),
  isValidFileId,
  pigeonVersion,
  sanitizeContentType,
  sanitizeFilename,
 )

-- * Upload

uploadHandler ::
  -- | @Authorization: Bearer@ header carrying the upload token.
  Maybe Text ->
  -- | @filename@ query parameter; defaults to a generated name.
  Maybe Text ->
  -- | @expires_in@ query parameter in seconds; defaults to the server lifetime.
  Maybe Int64 ->
  -- | @content_type@ query parameter; sanitised before storage.
  Maybe Text ->
  -- | @Content-Encoding@ header; @identity@ or @gzip@.
  Maybe Text ->
  -- | @X-Pigeon-Password@ header; protects the download.
  Maybe Text ->
  UploadBody ->
  App FileInfo
uploadHandler auth rawFilename rawExpires rawContentType rawEncoding rawPassword body = do
  requireAuth auth
  cfg <- asks aeConfig
  now <- liftIO getCurrentTime

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

  storedContentType <- case rawContentType of
    Nothing -> pure "application/octet-stream"
    Just value
      | T.null value -> pure "application/octet-stream"
      | sanitizeContentType value == value -> pure value
      | otherwise -> throwError (invalidRequest "content_type contains invalid characters")

  passwordHash <- case rawPassword of
    Nothing -> pure Nothing
    Just header -> Just . unStoredPasswordHash <$> decodeAndHashPassword header

  encoding <- case fmap (T.toLower . T.strip) rawEncoding of
    Nothing -> pure Nothing
    Just "identity" -> pure Nothing
    Just "gzip" -> pure (Just "gzip")
    Just _ -> throwError (apiError err415 "unsupported_media_type" "unsupported Content-Encoding")

  let expiresAt = addUTCTime (fromIntegral lifetime) now
      request =
        StoreRequest
          { srFilename = filename,
            srContentType = storedContentType,
            srExpiresAt = expiresAt,
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

  logger <- askLogger
  liftIO
    $ logInfo logger
    $ "upload id="
      <> unFileId (sfId stored)
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
  requireAuth auth
  env <- ask
  now <- liftIO getCurrentTime
  files <- liftIO (listLiveFiles (aeDb env) now)
  cfg <- asks aeConfig
  pure (map (storedToFileInfo cfg) files)

deleteHandler :: FileId -> Maybe Text -> App NoContent
deleteHandler fileId auth = do
  requireAuth auth
  unless (isValidFileId fileId) $
    throwError (invalidRequest "malformed file id")
  env <- ask
  deleted <- liftIO (deleteFileRow (aeDb env) fileId)
  if not deleted
    then throwError notFound
    else do
      liftIO (deleteBlob (aeStorage env) fileId)
      logger <- askLogger
      liftIO $ logInfo logger ("delete id=" <> unFileId fileId)
      pure NoContent

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
      fiFilename = sfFilename,
      fiSize = sfSize,
      fiContentType = sfContentType,
      fiCreatedAt = sfCreatedAt,
      fiExpiresAt = sfExpiresAt,
      fiHasPassword = isJust sfPasswordHash,
      fiUrl = scPublicUrl cfg <> "/f/" <> unFileId sfId
    }

requireAuth :: Maybe Text -> App ()
requireAuth auth = do
  token <- asks (scToken . aeConfig)
  case checkBearer token auth of
    Right () -> pure ()
    Left _ -> throwError unauthorized

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

storageError :: StorageError -> ServerError
storageError = \case
  StorageTooLarge -> apiError err413 "payload_too_large" "upload is too large"
  StorageBadGzip -> invalidRequest "request body is not valid gzip"
  StorageIdCollision -> apiError err503 "unavailable" "could not allocate a file id"
  StorageIo _ -> apiError err500 "internal_error" "internal storage failure"
