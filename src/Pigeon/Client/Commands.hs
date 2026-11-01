-- | Upload, list, and delete command implementations.
module Pigeon.Client.Commands (
  runClient,
)
where

import Control.Exception.Safe (IOException, bracket, catch, finally, try)
import Control.Monad (forM, forM_, when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Resource (ResourceT)
import Data.Aeson (eitherDecode, encode)
import Data.Base64.Types (extractBase64)
import Data.ByteString qualified as BS
import Data.ByteString.Base64.URL qualified as B64URL
import Data.ByteString.Lazy qualified as LBS
import Data.Conduit
import Data.IORef
import Data.Int (Int64)
import Data.List (nub)
import Data.Maybe (fromMaybe)
import Data.Text (Text, dropWhileEnd)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import Data.Text.IO qualified as TIO
import Data.Time (UTCTime, diffUTCTime, getCurrentTime)
import Network.HTTP.Types.Status (statusCode)
import Servant.Client (ClientError (..), responseBody, responseStatusCode)
import Servant.Client.Core.Response (Response)
import System.Directory (doesFileExist, getFileSize)
import System.Exit (ExitCode (..))
import System.FilePath (takeFileName)
import System.IO (
  Handle,
  IOMode (ReadMode),
  hClose,
  hFlush,
  hGetEcho,
  hIsTerminalDevice,
  hSetEcho,
  openBinaryFile,
  stderr,
  stdin,
 )
import System.Posix.Files (FileStatus, getFileStatus, isRegularFile)

import Pigeon.Client.Api (ApiClient (..), ClientApi (..), mkClientApi, runApi)
import Pigeon.Client.Config (
  ClientCommand (..),
  ClientConfig (..),
  DeleteOptions (..),
  PasswordSource (..),
  UploadOptions (..),
 )
import Pigeon.Client.Output (
  deleteResultJson,
  formatFileInfo,
  formatFileTable,
  formatSize,
 )
import Pigeon.Password (validatePassword)
import Pigeon.Streaming (countBytes, parallelGzipConduit, passThrough, sourceHandleChunked)
import Pigeon.Types (
  ApiError (..),
  ApiErrorEnvelope (..),
  FileId (..),
  FileInfo (..),
  epochToUtc,
  secretText,
 )

-- | Failure with a CLI exit code and a user-facing message.
data Failure = Failure
  { failureExit :: Int,
    failureCode :: Text,
    failureMessage :: Text
  }

-- | Run one client command, returning its process exit code.
runClient :: ClientConfig -> IO ExitCode
runClient cfg = do
  clientApi <- mkClientApi cfg
  code <- case ccCommand cfg of
    Upload options -> runUpload cfg clientApi options
    List -> runList cfg clientApi
    Delete options -> runDelete cfg clientApi options
  pure (if code == 0 then ExitSuccess else ExitFailure code)

-- * Upload

runUpload :: ClientConfig -> ClientApi -> UploadOptions -> IO Int
runUpload cfg clientApi options = do
  ready <- checkInputFile (uoFile options)
  case ready of
    Left failure -> reportFailure cfg failure
    Right () -> do
      password <- resolvePassword (uoPassword options)
      case password of
        Left failure -> reportFailure cfg failure
        Right passwordHeader -> do
          let filename = fromMaybe (T.pack (takeFileName (uoFile options))) (uoName options)
              contentType = fromMaybe "application/octet-stream" (uoContentType options)
              compression = if uoNoCompress options then Nothing else Just "gzip"
              authorization = Just ("Bearer " <> secretText (ccToken cfg))
          uploaded <-
            try
              ( withInputFile
                  (uoFile options)
                  (performUpload cfg clientApi options filename contentType compression passwordHeader authorization)
              )
          case uploaded :: Either IOException (Either ClientError FileInfo) of
            Left _ -> reportFailure cfg (Failure 7 "file_error" ("cannot read file: " <> T.pack (uoFile options)))
            Right (Left err) -> reportFailure cfg (mapClientError err)
            Right (Right info) -> do
              now <- getCurrentTime
              if ccJson cfg
                then LBS.putStr (encode info) >> putStrLn ""
                else TIO.putStr (formatFileInfo now info)
              pure 0

{- | Bytes read from the input file per chunk. Larger reads cut syscall and
conduit-step overhead; the tradeoff is coarser progress updates on slow links.
-}
uploadChunkSize :: Int
uploadChunkSize = 128 * 1024

performUpload ::
  ClientConfig ->
  ClientApi ->
  UploadOptions ->
  Text ->
  Text ->
  Maybe Text ->
  Maybe Text ->
  Maybe Text ->
  Handle ->
  IO (Either ClientError FileInfo)
performUpload cfg clientApi options filename contentType compression passwordHeader authorization handle = do
  totalSize <- fromIntegral <$> getFileSize (uoFile options)
  counter <- newIORef 0
  showProgress <- shouldShowProgress cfg
  logVerbose cfg $
    "upload start path="
      <> T.pack (uoFile options)
      <> " filename="
      <> filename
      <> " size="
      <> T.pack (show totalSize)
      <> " server="
      <> ccServerText cfg
      <> " content_type="
      <> contentType
      <> " compression="
      <> maybe "identity" (const "gzip") compression
  started <- getCurrentTime
  let body :: ConduitT () BS.ByteString (ResourceT IO) ()
      body =
        sourceHandleChunked uploadChunkSize handle
          .| countBytes counter
          .| progressConduit showProgress filename totalSize counter
          .| (if uoNoCompress options then passThrough else parallelGzipConduit)
  result <-
    runApi
      clientApi
      ( acUpload
          (caApi clientApi)
          authorization
          (Just filename)
          (uoExpiresIn options)
          (Just contentType)
          compression
          passwordHeader
          body
      )
      `finally` when (showProgress && totalSize > 0) clearProgress
  finished <- getCurrentTime
  let elapsedMs = round ((realToFrac (diffUTCTime finished started) :: Double) * 1000) :: Int
  case result of
    Right info ->
      logVerbose cfg $
        "upload done id="
          <> unFileId (fiId info)
          <> " size="
          <> T.pack (show (fiSize info))
          <> " duration_ms="
          <> T.pack (show elapsedMs)
    Left _ ->
      logVerbose cfg ("upload failed duration_ms=" <> T.pack (show elapsedMs))
  pure result

checkInputFile :: FilePath -> IO (Either Failure ())
checkInputFile path = do
  exists <- doesFileExist path
  if not exists
    then pure (Left (Failure 7 "file_error" ("file not found: " <> T.pack path)))
    else do
      result <- try (getFileStatus path) :: IO (Either IOException FileStatus)
      pure $ case result of
        Left _ -> Left (Failure 7 "file_error" ("cannot read file: " <> T.pack path))
        Right status
          | isRegularFile status -> Right ()
          | otherwise -> Left (Failure 7 "file_error" ("not a regular file: " <> T.pack path))

withInputFile :: FilePath -> (Handle -> IO a) -> IO a
withInputFile path action = do
  handle <- openBinaryFile path ReadMode
  action handle `finally` (hClose handle `catch` \(_ :: IOException) -> pure ())

resolvePassword :: PasswordSource -> IO (Either Failure (Maybe Text))
resolvePassword NoPassword = pure (Right Nothing)
resolvePassword StdinPassword = do
  lineResult <- try TIO.getLine :: IO (Either IOException Text)
  case lineResult of
    Left _ -> pure (Left (Failure 2 "usage_error" "could not read password from stdin"))
    Right line ->
      pure $ do
        password <- validatePasswordInput (dropTrailingCR line)
        Right (Just (encodePassword password))
resolvePassword PromptPassword = do
  terminal <- hIsTerminalDevice stdin
  if not terminal
    then pure (Left (Failure 2 "usage_error" "the --password prompt requires an interactive terminal"))
    else do
      password <- promptPassword
      pure $ do
        validated <- validatePasswordInput password
        Right (Just (encodePassword validated))

validatePasswordInput :: Text -> Either Failure Text
validatePasswordInput password =
  case validatePassword password of
    Left message -> Left (Failure 2 "usage_error" message)
    Right () -> Right password

encodePassword :: Text -> Text
encodePassword = extractBase64 . B64URL.encodeBase64Unpadded . encodeUtf8

promptPassword :: IO Text
promptPassword =
  bracket (hGetEcho stdin) (hSetEcho stdin) $ \_ -> do
    hSetEcho stdin False
    TIO.hPutStr stderr "Password: "
    hFlush stderr
    password <- TIO.getLine
    TIO.hPutStrLn stderr ""
    pure (dropTrailingCR password)

dropTrailingCR :: Text -> Text
dropTrailingCR = dropWhileEnd (== '\r')

-- * List

runList :: ClientConfig -> ClientApi -> IO Int
runList cfg clientApi = do
  result <-
    runApi clientApi $
      acList (caApi clientApi) (Just ("Bearer " <> secretText (ccToken cfg)))
  case result of
    Left err -> reportFailure cfg (mapClientError err)
    Right files -> do
      if ccJson cfg
        then LBS.putStr (encode files) >> putStrLn ""
        else do
          now <- getCurrentTime
          TIO.putStr (formatFileTable now files)
      pure 0

-- * Delete

runDelete :: ClientConfig -> ClientApi -> DeleteOptions -> IO Int
runDelete cfg clientApi options = do
  confirmed <- confirmDelete cfg (doYes options) (length (doIds options))
  case confirmed of
    Left code -> pure code
    Right () -> do
      let ids = map FileId (doIds options)
      outcomes <-
        forM ids $ \fileId -> do
          result <-
            runApi clientApi $
              acDelete (caApi clientApi) fileId (Just ("Bearer " <> secretText (ccToken cfg)))
          pure (fileId, result)
      let deleted = [unFileId fileId | (fileId, Right _) <- outcomes]
          failed =
            [ (unFileId fileId, mapClientError err)
            | (fileId, Left err) <- outcomes
            ]
      if ccJson cfg
        then do
          LBS.putStr
            ( encode
                ( deleteResultJson
                    deleted
                    [(fileId, failureCode failure, failureMessage failure) | (fileId, failure) <- failed]
                )
            )
          putStrLn ""
        else do
          forM_ deleted $ \fileId -> TIO.putStrLn ("Deleted " <> fileId)
          forM_ failed $ \(fileId, failure) ->
            TIO.hPutStrLn stderr ("error: " <> fileId <> ": " <> failureMessage failure)
      pure (deleteExitCode failed)

confirmDelete :: ClientConfig -> Bool -> Int -> IO (Either Int ())
confirmDelete cfg assumeYes count
  | assumeYes = pure (Right ())
  | otherwise = do
      terminal <- hIsTerminalDevice stdin
      if not terminal
        then do
          code <-
            reportFailure
              cfg
              (Failure 2 "usage_error" "confirmation requires --yes when stdin is not a terminal")
          pure (Left code)
        else do
          TIO.hPutStr stderr ("Delete " <> T.pack (show count) <> " files? [y/N] ")
          hFlush stderr
          answer <- TIO.getLine
          pure $
            if T.toLower (T.strip answer) `elem` ["y", "yes"]
              then Right ()
              else Left 8

deleteExitCode :: [(Text, Failure)] -> Int
deleteExitCode [] = 0
deleteExitCode failed =
  case nub (map (failureExit . snd) failed) of
    [code] -> code
    _ -> 1

-- * Errors and output

reportFailure :: ClientConfig -> Failure -> IO Int
reportFailure cfg failure = do
  if ccJson cfg
    then do
      LBS.hPutStr
        stderr
        (encode (ApiErrorEnvelope (ApiError (failureCode failure) (failureMessage failure))))
      TIO.hPutStrLn stderr ""
    else TIO.hPutStrLn stderr ("error: " <> failureMessage failure)
  pure (failureExit failure)

mapClientError :: ClientError -> Failure
mapClientError = \case
  FailureResponse _ response ->
    let status = statusCode (responseStatusCode response)
        apiError = decodeApiError response
        (exitCode, defaultCode, defaultMessage) = statusDefaults status
        message = maybe defaultMessage aeMessage apiError
        code = maybe defaultCode aeCode apiError
     in Failure exitCode code message
  ConnectionError _ ->
    Failure 5 "network_error" "network request failed"
  DecodeFailure _ _ -> Failure 1 "unexpected_response" "the server returned an unexpected response"
  UnsupportedContentType _ _ -> Failure 1 "unexpected_response" "the server returned an unsupported content type"
  InvalidContentTypeHeader _ -> Failure 1 "unexpected_response" "the server returned an invalid content type"
 where
  decodeApiError :: Response -> Maybe ApiError
  decodeApiError response =
    either (const Nothing) Just (eitherDecode (responseBody response))
  statusDefaults :: Int -> (Int, Text, Text)
  statusDefaults status
    | status == 401 || status == 403 = (3, "unauthorized", "authentication failed")
    | status == 404 = (4, "not_found", "file not found")
    | status >= 500 = (6, "internal_error", "server error")
    | otherwise = (1, "invalid_request", "request failed")

-- * Progress

shouldShowProgress :: ClientConfig -> IO Bool
shouldShowProgress cfg
  | ccQuiet cfg = pure False
  | ccJson cfg = pure False
  | otherwise = hIsTerminalDevice stderr

{- | Emit a diagnostic line when @--verbose@ is set. Never includes the token,
the password, or file contents.
-}
logVerbose :: ClientConfig -> Text -> IO ()
logVerbose cfg message =
  when (ccVerbose cfg) $ TIO.hPutStrLn stderr ("verbose: " <> message)

-- | Minimum interval between progress redraws, in milliseconds (CLI-083).
progressIntervalMs :: Double
progressIntervalMs = 75

-- | Return to column 0 and erase the entire current line.
eraseLine :: Text
eraseLine = "\r\ESC[2K"

progressConduit ::
  Bool -> Text -> Int64 -> IORef Int64 -> ConduitT BS.ByteString BS.ByteString (ResourceT IO) ()
progressConduit enabled filename total counter
  | not enabled = awaitForever yield
  | otherwise = go (epochToUtc 0)
 where
  go :: UTCTime -> ConduitT BS.ByteString BS.ByteString (ResourceT IO) ()
  go lastPrint =
    await >>= \case
      Nothing -> pure ()
      Just chunk -> do
        now <- liftIO getCurrentTime
        let elapsed :: Double
            elapsed = realToFrac $ diffUTCTime now lastPrint
            shouldPrintProgress :: Bool
            shouldPrintProgress = elapsed * 1000 >= progressIntervalMs
        when shouldPrintProgress $ do
          current <- liftIO (readIORef counter)
          liftIO (printProgress filename total current)
        yield chunk
        go (if shouldPrintProgress then now else lastPrint)

printProgress :: Text -> Int64 -> Int64 -> IO ()
printProgress filename total current = do
  let percentage :: Int
      percentage
        | total <= 0 = 100
        | otherwise = min 100 (fromIntegral ((current * 100) `div` total))
      detail :: Text
      detail
        | total <= 0 = formatSize current
        | otherwise =
            formatSize current
              <> " / "
              <> formatSize total
              <> " ("
              <> T.pack (show percentage)
              <> "%)"
  TIO.hPutStr stderr (eraseLine <> "Uploading " <> filename <> ": " <> detail)
  hFlush stderr

{- | Erase the in-place progress line so only the command result remains
(CLI-083). Callers skip this for zero-byte uploads, which never draw a progress
line because the body has no chunks (CLI-084).
-}
clearProgress :: IO ()
clearProgress = do
  TIO.hPutStr stderr eraseLine
  hFlush stderr
