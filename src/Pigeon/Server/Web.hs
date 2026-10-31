-- | Public browser routes: file downloads and the password form.
module Pigeon.Server.Web (
  webHandler,
  robotsHandler,
  htmlError,
) where

import Control.Exception.Safe (IOException, catch, try)
import Control.Monad (when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ask)
import Control.Monad.Trans.Resource (ResourceT, runResourceT)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Char8 qualified as B8
import Data.ByteString.Lazy qualified as LBS
import Data.Conduit
import Data.Conduit.Combinators (sourceHandle)
import Data.Conduit.Combinators qualified as CC
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Text (Text)
import Data.Text.Encoding (decodeUtf8', encodeUtf8)
import Data.Time (getCurrentTime)
import Network.HTTP.Types (
  ResponseHeaders,
  Status,
  hAcceptEncoding,
  hAllow,
  hCacheControl,
  hContentEncoding,
  hContentLength,
  hContentType,
  mkStatus,
  status200,
  status401,
  status404,
  status405,
  status406,
  status413,
  status415,
  status500,
 )
import Network.HTTP.Types.URI qualified as URI
import Network.Wai (
  Application,
  Request,
  Response,
  getRequestBodyChunk,
  requestHeaders,
  requestMethod,
  responseLBS,
  responseStream,
 )
import Servant.Server (ServerError (..))
import System.IO (Handle, hClose)
import Text.Blaze.Html.Renderer.Utf8 (renderHtml)
import Text.Blaze.Html5 (Html, toHtml, (!))
import Text.Blaze.Html5 qualified as H
import Text.Blaze.Html5.Attributes qualified as A

import Pigeon.Password (parseStoredPasswordHash, validatePassword, verifyPassword)
import Pigeon.Server.App (App, MonadLogger (..), runApp)
import Pigeon.Server.Db (lookupFile)
import Pigeon.Server.Env (AppEnv (..))
import Pigeon.Server.Log (logError, logWarn)
import Pigeon.Server.Storage (openBlob)
import Pigeon.Streaming (AcceptEncoding (..), parseAcceptEncoding, ungzipConduit)
import Pigeon.Types (
  FileId (..),
  StoredFile (..),
  contentDisposition,
  isValidFileId,
  sanitizeContentType,
  sanitizeFilename,
 )

-- | The raw application behind @\/f\/:id@. Each request runs in 'App'.
webHandler :: AppEnv -> FileId -> Application
webHandler env fileId request respond =
  runApp env (handleRequest fileId request) >>= \case
    Right response -> respond response
    Left serverError -> respond (serverErrorResponse serverError)

handleRequest :: FileId -> Request -> App Response
handleRequest fileId request
  | not (isValidFileId fileId) = pure notFoundResponse
  | otherwise = case requestMethod request of
      "GET" -> handleGet fileId False request
      "HEAD" -> handleGet fileId True request
      "POST" -> handlePost fileId request
      _ -> pure methodNotAllowedResponse

-- | @robots.txt@ disallowing all crawling.
robotsHandler :: App Text
robotsHandler = pure "User-agent: *\nDisallow: /\n"

-- * GET / HEAD

handleGet :: FileId -> Bool -> Request -> App Response
handleGet fileId isHead request = do
  row <- lookupLive fileId
  case row of
    Nothing -> pure notFoundResponse
    Just stored
      | isJust (sfPasswordHash stored) -> pure (formResponse status200 stored False isHead)
      | otherwise -> serveFile stored request isHead

handlePost :: FileId -> Request -> App Response
handlePost fileId request = do
  let contentType = fromMaybe "" (lookup hContentType (requestHeaders request))
  if not ("application/x-www-form-urlencoded" `B8.isPrefixOf` contentType)
    then pure (htmlError status415 "Unsupported form content type.")
    else do
      bodyResult <- liftIO (readFormBody request)
      case bodyResult of
        Left () -> pure (htmlError status413 "Form submission is too large.")
        Right body -> do
          row <- lookupLive fileId
          case row of
            Nothing -> pure notFoundResponse
            Just stored
              | isNothing (sfPasswordHash stored) ->
                  serveFile stored request False
              | otherwise -> case parsePasswordField body of
                  Nothing -> pure (formResponse status401 stored True False)
                  Just password -> case validatePassword password of
                    Left _ -> pure (formResponse status401 stored True False)
                    Right () ->
                      case sfPasswordHash stored >>= either (const Nothing) Just . parseStoredPasswordHash of
                        Nothing -> do
                          logger <- askLogger
                          liftIO (logError logger ("corrupt password hash for id=" <> unFileId fileId))
                          pure (htmlError status500 "The stored file could not be read.")
                        Just storedHash
                          | verifyPassword password storedHash -> serveFile stored request False
                          | otherwise -> pure (formResponse status401 stored True False)

lookupLive :: FileId -> App (Maybe StoredFile)
lookupLive fileId = do
  env <- ask
  now <- liftIO getCurrentTime
  row <- liftIO (lookupFile (aeDb env) fileId)
  pure $ case row of
    Just stored | sfExpiresAt stored > now -> Just stored
    _ -> Nothing

-- * File streaming

serveFile :: StoredFile -> Request -> Bool -> App Response
serveFile stored request isHead =
  case chosenEncoding request of
    NotAcceptable -> pure (htmlError status406 "No acceptable response encoding.")
    encoding -> do
      env <- ask
      opened <- liftIO (try (openBlob (aeStorage env) (sfId stored))) :: App (Either IOException Handle)
      case opened of
        Left _ -> do
          logger <- askLogger
          liftIO (logWarn logger ("blob missing for id=" <> unFileId (sfId stored)))
          pure notFoundResponse
        Right handle
          | isHead -> do
              liftIO (closeHandle handle)
              pure (responseLBS status200 (fileHeaders stored encoding) "")
          | otherwise ->
              pure $
                responseStream status200 (fileHeaders stored encoding) $ \send flush -> do
                  runResourceT
                    $ runConduit
                    $ sourceHandle handle
                      .| (case encoding of AcceptGzip -> passThrough; _ -> ungzipConduit)
                      .| CC.mapM_ (\chunk -> liftIO (send (Builder.byteString chunk) >> flush))

passThrough :: ConduitT BS.ByteString BS.ByteString (ResourceT IO) ()
passThrough = awaitForever yield

chosenEncoding :: Request -> AcceptEncoding
chosenEncoding request =
  maybe
    AcceptIdentity
    parseAcceptEncoding
    (lookup hAcceptEncoding (requestHeaders request))

fileHeaders :: StoredFile -> AcceptEncoding -> ResponseHeaders
fileHeaders stored encoding =
  [ (hContentType, encodeUtf8 (sanitizeContentType (sfContentType stored))),
    ("Content-Disposition", contentDisposition (sfFilename stored)),
    ("X-Content-Type-Options", "nosniff"),
    (hCacheControl, "no-store"),
    ("Referrer-Policy", "no-referrer"),
    ("X-Robots-Tag", "noindex, nofollow"),
    ("X-Frame-Options", "DENY"),
    ("Vary", "Accept-Encoding")
  ]
    ++ case encoding of
      AcceptGzip ->
        [ (hContentEncoding, "gzip"),
          (hContentLength, B8.pack (show (sfStoredSize stored)))
        ]
      _ -> []

-- * Responses

notFoundResponse :: Response
notFoundResponse = htmlError status404 "File not found or expired."

methodNotAllowedResponse :: Response
methodNotAllowedResponse =
  htmlErrorWithHeaders
    status405
    [(hAllow, "GET, HEAD, POST")]
    "Method not allowed."

htmlError :: Status -> Text -> Response
htmlError status = htmlErrorWithHeaders status []

htmlErrorWithHeaders :: Status -> ResponseHeaders -> Text -> Response
htmlErrorWithHeaders status extra message =
  responseLBS
    status
    (extra ++ htmlHeaders)
    (renderHtml (simplePage message))

formResponse :: Status -> StoredFile -> Bool -> Bool -> Response
formResponse status stored showError isHead =
  let bodyBytes :: LBS.ByteString
      bodyBytes =
        renderHtml
          ( htmlPage
              (Just (sanitizeFilename (sfFilename stored)))
              showError
              "Enter the password to download this file."
          )
   in responseLBS
        status
        htmlHeaders
        (if isHead then "" else bodyBytes)

serverErrorResponse :: ServerError -> Response
serverErrorResponse err =
  responseLBS
    (mkStatus (errHTTPCode err) (B8.pack (errReasonPhrase err)))
    (errHeaders err)
    (errBody err)

htmlHeaders :: ResponseHeaders
htmlHeaders =
  [ (hContentType, "text/html; charset=utf-8"),
    (hCacheControl, "no-store"),
    ( "Content-Security-Policy",
      "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'"
    ),
    ("X-Content-Type-Options", "nosniff"),
    ("X-Frame-Options", "DENY"),
    ("Referrer-Policy", "no-referrer"),
    ("X-Robots-Tag", "noindex, nofollow")
  ]

simplePage :: Text -> Html
simplePage message =
  H.docType
    <> H.html
      ( do
          H.head $ do
            H.title "Pigeon"
            H.meta ! A.charset "utf-8"
            H.meta ! A.name "viewport" ! A.content "width=device-width, initial-scale=1"
            H.style (toHtml styleSheet)
          H.body $
            H.div ! A.class_ "card" $ do
              H.h1 "Pigeon"
              H.p (toHtml message)
      )

htmlPage :: Maybe Text -> Bool -> Text -> Html
htmlPage mFilename showError message =
  H.docType
    <> H.html
      ( do
          H.head $ do
            H.title "Pigeon"
            H.meta ! A.charset "utf-8"
            H.meta ! A.name "viewport" ! A.content "width=device-width, initial-scale=1"
            H.style (toHtml styleSheet)
          H.body $ do
            H.div ! A.class_ "card" $ do
              H.h1 (maybe "Pigeon file" toHtml mFilename)
              when showError $ H.p ! A.class_ "error" $ toHtml ("Incorrect password." :: Text)
              H.form ! A.method "post" ! A.action "" $ do
                H.p (toHtml message)
                H.input
                  ! A.type_ "password"
                  ! A.name "password"
                  ! A.required "required"
                  ! A.autofocus "autofocus"
                  ! A.autocomplete "current-password"
                  ! A.maxlength "1024"
                H.button ! A.type_ "submit" $ toHtml ("Download" :: Text)
      )

styleSheet :: Text
styleSheet =
  "body{font-family:system-ui,sans-serif;background:#111;color:#eee;margin:0;min-height:100vh;display:grid;place-items:center}"
    <> ".card{background:#1c1c1c;border:1px solid #333;border-radius:12px;padding:2rem;max-width:26rem;width:calc(100% - 3rem)}"
    <> "h1{font-size:1.25rem;margin:0 0 1rem;overflow-wrap:anywhere}"
    <> "p{margin:0 0 1rem;color:#bbb}"
    <> ".error{color:#ff8a8a}"
    <> "input{box-sizing:border-box;width:100%;padding:.7rem;border-radius:8px;border:1px solid #444;background:#111;color:#eee;margin-bottom:.75rem}"
    <> "button{width:100%;padding:.7rem;border:0;border-radius:8px;background:#4f8cff;color:#fff;font-weight:600;cursor:pointer}"

-- * Form parsing

readFormBody :: Request -> IO (Either () ByteString)
readFormBody request = go 0 []
 where
  limit :: Int
  limit = 8192
  go :: Int -> [ByteString] -> IO (Either () ByteString)
  go total chunks = do
    chunk <- getRequestBodyChunk request
    if BS.null chunk
      then pure (Right (BS.concat (reverse chunks)))
      else
        let total' = total + BS.length chunk
         in if total' > limit
              then pure (Left ())
              else go total' (chunk : chunks)

parsePasswordField :: ByteString -> Maybe Text
parsePasswordField body =
  case [value | (name, Just value) <- URI.parseQuery body, name == "password"] of
    [value] -> either (const Nothing) Just (decodeUtf8' value)
    _ -> Nothing

closeHandle :: Handle -> IO ()
closeHandle handle = hClose handle `catch` \(_ :: IOException) -> pure ()
