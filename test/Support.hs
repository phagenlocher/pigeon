{-# LANGUAGE OverloadedStrings #-}

{- | Shared fixtures for the Pigeon suite: tokens, temporary data directories,
and in-process servers on ephemeral ports.
-}
module Support (
  testToken,
  testPassword,
  withTempDataDir,
  withTestServer,
  withRawServer,
  testClientEnv,
  authHeader,
  authHeaderFor,
  uploadRaw,
  uploadGzip,
  uploadGzipRaw,
  uploadWithPassword,
  uploadWithExpires,
  uploadWithExpiresEither,
  uploadSlow,
  uploadWithToken,
  listFiles,
  listFilesWith,
  deleteFile,
  deleteFileWith,
  createToken,
  createTokenWith,
  listTokensWith,
  deleteTokenWith,
  deleteFileResultWith,
  deleteTokenResultWith,
  listTokensResultWith,
  listFilesResultWith,
  download,
  postForm,
  requestWith,
  testConfig,
  bodyOf,
  statusOf,
  encodePassword,
) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (Async, async, cancel, waitCatch)
import Control.Exception.Safe (bracket, finally)
import Control.Monad (void)
import Control.Monad.IO.Class (liftIO)
import Data.Base64.Types (extractBase64)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base64.URL qualified as B64URL
import Data.ByteString.Lazy qualified as LBS
import Data.Conduit (yield, (.|))
import Data.Conduit.Zlib (gzip)
import Data.Int (Int64)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import Network.HTTP.Client (
  Request (..),
  RequestBody (..),
  Response,
  defaultManagerSettings,
  httpLbs,
  managerResponseTimeout,
  newManager,
  parseRequest,
  responseBody,
  responseStatus,
  responseTimeoutMicro,
 )
import Network.HTTP.Types (Header, Method, Status, hAcceptEncoding)
import Network.HTTP.Types qualified as HTTP
import Network.Wai.Handler.Warp qualified as Warp
import Servant.API ((:<|>) (..))
import Servant.Client (
  BaseUrl (..),
  ClientEnv,
  ClientM,
  Scheme (..),
  mkClientEnv,
  runClientM,
 )
import Servant.Client qualified as SC
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

import Pigeon.API (PigeonAPI, UploadBody)
import Pigeon.Server (closeAppEnv, mkApp, mkAppEnv)
import Pigeon.Server.Config (ServerConfig (..), TlsMode (..), defaultServerConfig)
import Pigeon.Server.Env (AppEnv (..))
import Pigeon.Types (CreatedToken, FileId (..), FileInfo, OwnerId, TokenInfo, mkSecret)

testToken :: Text
testToken = "test-token-at-least-16-chars"

testPassword :: Text
testPassword = "correct horse battery staple"

-- | Run an action with a fresh temporary directory.
withTempDataDir :: (FilePath -> IO a) -> IO a
withTempDataDir = withSystemTempDirectory "pigeon-test"

testConfig :: FilePath -> Warp.Port -> ServerConfig
testConfig dir port =
  defaultServerConfig
    { scDataDir = dir,
      scDbPath = dir </> "pigeon.db",
      scToken = mkSecret testToken,
      scTlsMode = TlsDisabled,
      scPublicUrl = "http://127.0.0.1:" <> T.pack (show port),
      scDefaultExpiry = 3600,
      scMaxExpiry = 7 * 86400,
      scSweepInterval = 1,
      scPasswordHashIterations = 100000,
      scQuiet = True,
      scVerbose = False
    }

-- | Run a real Warp server on an ephemeral port with a fresh data directory.
withTestServer :: (ServerConfig -> Warp.Port -> IO a) -> IO a
withTestServer action = withTempDataDir $ \dir -> do
  (port, socket) <- Warp.openFreePort
  let cfg = testConfig dir port
  bracket (mkAppEnv cfg) closeAppEnv $ \env -> do
    server <- async (Warp.runSettingsSocket Warp.defaultSettings socket (mkApp env))
    threadDelay 100000
    action cfg port `finally` stopServer server
 where
  stopServer :: Async () -> IO ()
  stopServer server = do
    cancel server
    void (waitCatch server)

{- | A server whose application and environment are exposed for lower-level
tests.
-}
withRawServer :: (AppEnv -> Warp.Port -> IO a) -> IO a
withRawServer action = withTempDataDir $ \dir -> do
  (port, socket) <- Warp.openFreePort
  let cfg = testConfig dir port
  bracket (mkAppEnv cfg) closeAppEnv $ \env -> do
    server <- async (Warp.runSettingsSocket Warp.defaultSettings socket (mkApp env))
    threadDelay 100000
    action env port `finally` (cancel server >> void (waitCatch server))

testClientEnv :: Warp.Port -> IO ClientEnv
testClientEnv port = do
  manager <-
    newManager
      defaultManagerSettings
        { managerResponseTimeout = responseTimeoutMicro 30000000
        }
  pure (mkClientEnv manager (BaseUrl Http "127.0.0.1" port ""))

authHeader :: Text
authHeader = "Bearer " <> testToken

uploadRaw :: ClientEnv -> Text -> ByteString -> IO FileInfo
uploadRaw env filename bytes =
  expectRight
    =<< runClientM
      (uploadCall (Just authHeader) (Just filename) Nothing Nothing Nothing (yield bytes))
      env

uploadGzip :: ClientEnv -> Text -> ByteString -> IO FileInfo
uploadGzip env filename bytes =
  expectRight
    =<< runClientM
      ( uploadCall
          (Just authHeader)
          (Just filename)
          Nothing
          (Just "gzip")
          Nothing
          (yield bytes .| gzip)
      )
      env

{- | Send an already-compressed body with @Content-Encoding: gzip@.

Unlike 'uploadGzip', the bytes are not compressed again, so callers can send a
specific gzip stream, including a deliberately corrupt one.
-}
uploadGzipRaw :: ClientEnv -> Text -> ByteString -> IO FileInfo
uploadGzipRaw env filename bytes =
  expectRight
    =<< runClientM
      (uploadCall (Just authHeader) (Just filename) Nothing (Just "gzip") Nothing (yield bytes))
      env

uploadWithExpires :: ClientEnv -> Text -> Int64 -> ByteString -> IO FileInfo
uploadWithExpires env filename expires bytes =
  expectRight
    =<< runClientM
      (uploadCall (Just authHeader) (Just filename) (Just expires) Nothing Nothing (yield bytes))
      env

{- | Upload a body that pauses between chunks. Used to verify that the expiry
clock starts when the body finishes rather than when the request starts.
-}
uploadSlow :: ClientEnv -> Text -> Int64 -> Int -> ByteString -> IO FileInfo
uploadSlow env filename expires microseconds bytes =
  expectRight
    =<< runClientM
      ( uploadCall
          (Just authHeader)
          (Just filename)
          (Just expires)
          Nothing
          Nothing
          (yield bytes >> liftIO (threadDelay microseconds) >> yield bytes)
      )
      env

uploadWithExpiresEither :: ClientEnv -> Text -> Int64 -> IO (Either Int FileInfo)
uploadWithExpiresEither env filename expires = do
  result <-
    runClientM
      (uploadCall (Just authHeader) (Just filename) (Just expires) Nothing Nothing (yield "x"))
      env
  pure $ case result of
    Right info -> Right info
    Left (SC.FailureResponse _ response) -> Left (HTTP.statusCode (SC.responseStatusCode response))
    Left _ -> Left 0

listFiles :: ClientEnv -> IO [FileInfo]
listFiles env =
  expectRight
    =<< runClientM
      ( do
          let (_upload :<|> list :<|> _delete :<|> _createToken :<|> _listTokens :<|> _deleteToken :<|> _health) =
                SC.client (Proxy :: Proxy PigeonAPI)
          list (Just authHeader)
      )
      env

deleteFile :: ClientEnv -> FileId -> IO ()
deleteFile env fileId =
  void $
    expectRight
      =<< runClientM
        ( do
            let (_upload :<|> _list :<|> delete :<|> _createToken :<|> _listTokens :<|> _deleteToken :<|> _health) =
                  SC.client (Proxy :: Proxy PigeonAPI)
            delete fileId (Just authHeader)
        )
        env

-- | Authentication header for an arbitrary token.
authHeaderFor :: Text -> Text
authHeaderFor token = "Bearer " <> token

createToken :: ClientEnv -> Maybe Int64 -> IO CreatedToken
createToken env = createTokenWith env testToken

createTokenWith :: ClientEnv -> Text -> Maybe Int64 -> IO CreatedToken
createTokenWith env token expires =
  expectRight
    =<< runClientM
      ( do
          let (_upload :<|> _list :<|> _delete :<|> create :<|> _listTokens :<|> _deleteToken :<|> _health) =
                SC.client (Proxy :: Proxy PigeonAPI)
          create (Just (authHeaderFor token)) expires
      )
      env

listTokensWith :: ClientEnv -> Text -> IO [TokenInfo]
listTokensWith env token =
  expectRight
    =<< runClientM
      ( do
          let (_upload :<|> _list :<|> _delete :<|> _createToken :<|> listTokens :<|> _deleteToken :<|> _health) =
                SC.client (Proxy :: Proxy PigeonAPI)
          listTokens (Just (authHeaderFor token))
      )
      env

deleteTokenWith :: ClientEnv -> Text -> OwnerId -> IO ()
deleteTokenWith env token owner =
  void $
    expectRight
      =<< runClientM
        ( do
            let (_upload :<|> _list :<|> _delete :<|> _createToken :<|> _listTokens :<|> deleteToken :<|> _health) =
                  SC.client (Proxy :: Proxy PigeonAPI)
            deleteToken owner (Just (authHeaderFor token))
        )
        env

uploadWithToken :: ClientEnv -> Text -> Text -> ByteString -> IO FileInfo
uploadWithToken env token filename bytes =
  expectRight
    =<< runClientM
      (uploadCall (Just (authHeaderFor token)) (Just filename) Nothing Nothing Nothing (yield bytes))
      env

listFilesWith :: ClientEnv -> Text -> IO [FileInfo]
listFilesWith env token =
  expectRight
    =<< runClientM
      ( do
          let (_upload :<|> list :<|> _delete :<|> _createToken :<|> _listTokens :<|> _deleteToken :<|> _health) =
                SC.client (Proxy :: Proxy PigeonAPI)
          list (Just (authHeaderFor token))
      )
      env

deleteFileWith :: ClientEnv -> Text -> FileId -> IO ()
deleteFileWith env token fileId =
  void $
    expectRight
      =<< runClientM
        ( do
            let (_upload :<|> _list :<|> delete :<|> _createToken :<|> _listTokens :<|> _deleteToken :<|> _health) =
                  SC.client (Proxy :: Proxy PigeonAPI)
            delete fileId (Just (authHeaderFor token))
        )
        env

-- | Delete a file, returning the HTTP status on failure.
deleteFileResultWith :: ClientEnv -> Text -> FileId -> IO (Either Int ())
deleteFileResultWith env token fileId = do
  result <-
    runClientM
      ( do
          let (_upload :<|> _list :<|> delete :<|> _createToken :<|> _listTokens :<|> _deleteToken :<|> _health) =
                SC.client (Proxy :: Proxy PigeonAPI)
          delete fileId (Just (authHeaderFor token))
      )
      env
  pure (either (Left . clientErrorStatus) (const (Right ())) result)

-- | List files, returning the HTTP status on failure.
listFilesResultWith :: ClientEnv -> Text -> IO (Either Int [FileInfo])
listFilesResultWith env token = do
  result <-
    runClientM
      ( do
          let (_upload :<|> list :<|> _delete :<|> _createToken :<|> _listTokens :<|> _deleteToken :<|> _health) =
                SC.client (Proxy :: Proxy PigeonAPI)
          list (Just (authHeaderFor token))
      )
      env
  pure (either (Left . clientErrorStatus) Right result)

-- | List tokens, returning the HTTP status on failure.
listTokensResultWith :: ClientEnv -> Text -> IO (Either Int [TokenInfo])
listTokensResultWith env token = do
  result <-
    runClientM
      ( do
          let (_upload :<|> _list :<|> _delete :<|> _createToken :<|> listTokens :<|> _deleteToken :<|> _health) =
                SC.client (Proxy :: Proxy PigeonAPI)
          listTokens (Just (authHeaderFor token))
      )
      env
  pure (either (Left . clientErrorStatus) Right result)

-- | Delete a token, returning the HTTP status on failure.
deleteTokenResultWith :: ClientEnv -> Text -> OwnerId -> IO (Either Int ())
deleteTokenResultWith env token owner = do
  result <-
    runClientM
      ( do
          let (_upload :<|> _list :<|> _delete :<|> _createToken :<|> _listTokens :<|> deleteToken :<|> _health) =
                SC.client (Proxy :: Proxy PigeonAPI)
          deleteToken owner (Just (authHeaderFor token))
      )
      env
  pure (either (Left . clientErrorStatus) (const (Right ())) result)

-- | HTTP status carried by a Servant client error, or 0 for transport errors.
clientErrorStatus :: SC.ClientError -> Int
clientErrorStatus (SC.FailureResponse _ response) =
  HTTP.statusCode (SC.responseStatusCode response)
clientErrorStatus _ = 0

uploadWithPassword :: ClientEnv -> Text -> Text -> ByteString -> IO FileInfo
uploadWithPassword env filename password bytes =
  expectRight
    =<< runClientM
      ( uploadCall
          (Just authHeader)
          (Just filename)
          Nothing
          Nothing
          (Just (encodePassword password))
          (yield bytes)
      )
      env

uploadCall ::
  Maybe Text ->
  Maybe Text ->
  Maybe Int64 ->
  Maybe Text ->
  Maybe Text ->
  UploadBody ->
  ClientM FileInfo
uploadCall auth filename expires encoding password body =
  let (upload :<|> _list :<|> _delete :<|> _createToken :<|> _listTokens :<|> _deleteToken :<|> _health) =
        SC.client (Proxy :: Proxy PigeonAPI)
   in upload auth filename expires encoding password body

encodePassword :: Text -> Text
encodePassword = extractBase64 . B64URL.encodeBase64Unpadded . encodeUtf8

expectRight :: (Show e) => Either e a -> IO a
expectRight (Right value) = pure value
expectRight (Left err) = fail ("unexpected client error: " <> show err)

download :: Warp.Port -> FileId -> [Header] -> IO (Response LBS.ByteString)
download port fileId headers =
  requestWith port ("/f/" <> T.unpack (unFileId fileId)) "GET" headers BS.empty

postForm :: Warp.Port -> FileId -> ByteString -> IO (Response LBS.ByteString)
postForm port fileId =
  requestWith
    port
    ("/f/" <> T.unpack (unFileId fileId))
    "POST"
    [("Content-Type", "application/x-www-form-urlencoded")]

{- | Send one raw HTTP request with a strict body.

The helper defaults @Accept-Encoding@ to @identity@, because http-client adds
@gzip@ when the header is absent, and disables http-client's transparent
decompression. A gzip passthrough body is therefore returned byte-exact unless
the caller asks for gzip and decodes it itself.
-}
requestWith ::
  Warp.Port -> String -> Method -> [Header] -> ByteString -> IO (Response LBS.ByteString)
requestWith port path method headers body = do
  manager <- newManager defaultManagerSettings
  request <- parseRequest ("http://127.0.0.1:" <> show port <> path)
  let
    headers' :: [Header]
    headers' =
      if any ((== hAcceptEncoding) . fst) headers
        then headers
        else (hAcceptEncoding, "identity") : headers
    request' :: Request
    request' =
      request
        { method = method,
          requestHeaders = headers',
          requestBody = RequestBodyBS body,
          redirectCount = 0,
          decompress = const False
        }
  httpLbs request' manager

bodyOf :: Response LBS.ByteString -> LBS.ByteString
bodyOf = responseBody

statusOf :: Response body -> Status
statusOf = responseStatus
